import Combine
import Foundation

public struct AppleStoreProduct: Equatable, Sendable, Identifiable {
    public let id, displayPrice: String
    public init(id: String, displayPrice: String) { self.id = id; self.displayPrice = displayPrice }
}

/// Constructed only for device-verified StoreKit results by the live adapter.
public struct AppleVerifiedTransaction: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id, productID: String
    public let environment: ApplePurchaseEnvironment?
    public let accountToken: UUID?
    let signedTransaction: String
    let finish: @MainActor @Sendable () async -> Void
    public var description: String { "AppleVerifiedTransaction(id: \(id))" }
    public var debugDescription: String { description }
    public init(id: String, productID: String, environment: ApplePurchaseEnvironment?, accountToken: UUID?,
                signedTransaction: String, finish: @escaping @MainActor @Sendable () async -> Void) {
        self.id = id; self.productID = productID; self.environment = environment
        self.accountToken = accountToken; self.signedTransaction = signedTransaction; self.finish = finish
    }
}

public enum AppleStorePurchaseResult: Sendable {
    case verified(AppleVerifiedTransaction), pending, cancelled, unverified
}

@MainActor public protocol ApplePurchaseStore: AnyObject {
    func products(ids: Set<String>) async throws -> [AppleStoreProduct]
    func purchase(id: String, accountToken: UUID) async throws -> AppleStorePurchaseResult
    func updates() -> AsyncStream<AppleVerifiedTransaction>
    func unfinished() async -> [AppleVerifiedTransaction]
}

/// No local crediting or persisted signed payloads. StoreKit owns the durable queue.
@MainActor public final class ApplePurchaseCoordinator: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle, loading, unavailable, closed, ready, purchasing, pending, cancelled, retrying
        case succeeded, needsSupport(String), otherAccount, revoked
    }
    public static let productIDs: Set<String> = ["com.atum.mobile.protons.100k", "com.atum.mobile.protons.500k"]
    @Published public private(set) var state: State = .idle
    @Published public private(set) var packs: [AppleProductsResponse.Pack] = []
    @Published public private(set) var products: [AppleStoreProduct] = []
    public var canPurchase: Bool {
        checkoutOpen && !products.isEmpty && [.ready, .cancelled, .succeeded].contains(state)
            && !purchaseStates.values.contains { [.purchasing, .pending, .retrying].contains($0) }
    }
    public func purchaseState(for productID: String) -> State { purchaseStates[productID] ?? .idle }

    private let store: any ApplePurchaseStore
    private let environment: ApplePurchaseEnvironment
    private let sleep: @MainActor (UInt64) async throws -> Void
    private let refreshWallet: @MainActor () async -> Void
    private var api: (any ApplePurchasesAPI)?
    private var accountID: String?
    private var generation = UUID()
    private var tokens: [String: UUID] = [:]
    @Published public private(set) var checkoutOpen = false
    /// Latest state by product ID; transaction identity is carried by needsSupport.
    @Published public private(set) var purchaseStates: [String: State] = [:]
    private var listener: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var submissions: [String: Task<Void, Never>] = [:]
    private var finished = Set<String>()

    public init(store: any ApplePurchaseStore, environment: ApplePurchaseEnvironment,
                sleep: @escaping @MainActor (UInt64) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                }, refreshWallet: @escaping @MainActor () async -> Void) {
        self.store = store; self.environment = environment; self.sleep = sleep
        self.refreshWallet = refreshWallet
    }

    /// Starts once at app launch, including while signed out.
    public func start() {
        guard listener == nil else { return }
        let stream = store.updates()
        listener = Task { [weak self] in
            for await transaction in stream {
                guard !Task.isCancelled else { return }
                self?.enqueue(transaction)
            }
        }
    }

    /// Call synchronously before old account authority is withdrawn. Cancels in-flight
    /// HTTP and retries; generation checks also refuse late replies from old authority.
    public func bind(accountID: String?, api: (any ApplePurchasesAPI)?) {
        generation = UUID(); loadTask?.cancel()
        submissions.values.forEach { $0.cancel() }; submissions.removeAll()
        let switchedAccount = self.accountID != accountID
        self.accountID = accountID; self.api = api
        checkoutOpen = false; products = []; packs = []; purchaseStates = [:]; state = .idle
        // Re-fetch after every account switch; don't strand token-bound transactions.
        if switchedAccount { tokens.removeAll() }
        guard accountID != nil, api != nil else { return }
        let scope = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.load()
            guard self.generation == scope, !Task.isCancelled else { return }
            await self.replayUnfinished()
        }
    }

    public func load() async {
        guard let api, accountID != nil else { return }
        let scope = generation
        state = .loading; checkoutOpen = false; products = []
        do {
            let catalog = try await api.appleProducts()
            guard isCurrent(scope) else { return }
            guard catalog.environment == environment else { state = .unavailable; return }
            guard catalog.checkoutOpen else { state = .closed; return }
            let ids = Set(catalog.products.map(\.productId)).intersection(Self.productIDs)
            guard !ids.isEmpty else { state = .unavailable; return }
            let loaded = try await store.products(ids: ids)
            guard isCurrent(scope) else { return }
            guard Set(loaded.map(\.id)) == ids, loaded.count == ids.count,
                  loaded.allSatisfy({ !$0.displayPrice.isEmpty }) else { state = .unavailable; return }
            packs = catalog.products.filter { ids.contains($0.productId) }
            products = loaded.sorted { $0.id < $1.id }; checkoutOpen = true; state = .ready
        } catch {
            guard isCurrent(scope) else { return }
            state = .unavailable
        }
    }

    public func purchase(_ id: String) async {
        guard canPurchase, products.contains(where: { $0.id == id }), let api, let accountID else { return }
        let scope = generation
        state = .purchasing; purchaseStates[id] = .purchasing
        do {
            let key = accountID + ":" + environment.rawValue
            let token: UUID
            if let cached = tokens[key] { token = cached }
            else {
                token = try await api.appleAccountToken().appAccountToken
                guard isCurrent(scope) else { return }
                tokens[key] = token
            }
            guard isCurrent(scope) else { return }
            let result = try await store.purchase(id: id, accountToken: token)
            guard isCurrent(scope) else { return }
            switch result {
            case let .verified(transaction):
                guard transaction.productID == id, transaction.environment == environment else {
                    state = .unavailable; purchaseStates[id] = .unavailable
                    return
                }
                enqueue(transaction)
            case .pending: state = .pending; purchaseStates[id] = .pending
            case .cancelled: state = .cancelled; purchaseStates[id] = .cancelled
            case .unverified: state = .unavailable; purchaseStates[id] = .unavailable
            }
        } catch {
            guard isCurrent(scope) else { return }
            state = .unavailable; purchaseStates[id] = .unavailable
        }
    }

    public func replayUnfinished() async {
        let scope = generation
        guard api != nil, accountID != nil else { return }
        let transactions = await store.unfinished()
        guard isCurrent(scope) else { return }
        for transaction in transactions { enqueue(transaction) }
    }

    public func restore() async {
        let scope = generation
        guard api != nil else { return }
        await refreshWallet()
        guard isCurrent(scope) else { return }
        await replayUnfinished()
    }

    private func isCurrent(_ scope: UUID) -> Bool { generation == scope && !Task.isCancelled }

    private func enqueue(_ transaction: AppleVerifiedTransaction) {
        guard let api, accountID != nil, transaction.environment == environment,
              Self.productIDs.contains(transaction.productID), submissions[transaction.id] == nil,
              !finished.contains(transaction.id) else { return }
        let scope = generation
        state = .retrying; purchaseStates[transaction.productID] = .retrying
        submissions[transaction.id] = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == scope { self.submissions[transaction.id] = nil } }
            var delay: UInt64 = 2
            while self.isCurrent(scope) {
                do {
                    let request = try AppleTransactionRequest(signedTransaction: transaction.signedTransaction)
                    let result = try await api.appleTransaction(request)
                    guard self.isCurrent(scope) else { return }
                    guard result.transactionId == transaction.id, result.finish else { throw ContractViolation.invariant }
                    await transaction.finish()
                    guard self.isCurrent(scope) else { return }
                    self.finished.insert(transaction.id)
                    switch result.state {
                    case .credited, .alreadyCredited:
                        self.state = .succeeded
                        await self.refreshWallet()
                    case .needsSupport: self.state = .needsSupport(transaction.id)
                    case .creditedToOtherAccount: self.state = .otherAccount
                    case .revoked:
                        self.state = .revoked
                        await self.refreshWallet()
                    }
                    guard self.isCurrent(scope) else { return }
                    self.purchaseStates[transaction.productID] = self.state
                    return
                } catch {
                    guard self.isCurrent(scope) else { return }
                    if let error = error as? ApplePurchaseError, error.error == .closed {
                        self.checkoutOpen = false; self.products = []; self.state = .closed
                    } else { self.state = .retrying }
                    self.purchaseStates[transaction.productID] = self.state
                    do { try await self.sleep(delay) } catch { return }
                    delay = min(delay * 2, 300)
                }
            }
        }
    }
}
