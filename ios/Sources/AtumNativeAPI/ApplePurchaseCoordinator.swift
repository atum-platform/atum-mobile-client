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
    let isRevoked: Bool
    let signedTransaction: String
    let finish: @MainActor @Sendable () async -> Void
    public var description: String { "AppleVerifiedTransaction(id: \(id))" }
    public var debugDescription: String { description }
    public init(id: String, productID: String, environment: ApplePurchaseEnvironment?, accountToken: UUID?,
                signedTransaction: String, isRevoked: Bool = false, finish: @escaping @MainActor @Sendable () async -> Void) {
        self.id = id; self.productID = productID; self.environment = environment
        self.accountToken = accountToken; self.signedTransaction = signedTransaction; self.finish = finish
        self.isRevoked = isRevoked
    }
}

public enum AppleStorePurchaseResult: Sendable {
    case verified(AppleVerifiedTransaction), pending, cancelled, unverified
}

@MainActor public protocol ApplePurchaseStore: AnyObject {
    /// Verified runtime environment; nil means local testing or unknown.
    func purchaseEnvironment() async throws -> ApplePurchaseEnvironment?
    func products(ids: Set<String>) async throws -> [AppleStoreProduct]
    func purchase(id: String, accountToken: UUID) async throws -> AppleStorePurchaseResult
    func updates() -> AsyncStream<AppleVerifiedTransaction>
    func unfinished() async -> [AppleVerifiedTransaction]
}

public extension ApplePurchaseStore {
    /// Custom adapters without runtime evidence must keep checkout unavailable.
    func purchaseEnvironment() async throws -> ApplePurchaseEnvironment? { nil }
}

/// No local crediting or persisted signed payloads. StoreKit owns the durable queue.
@MainActor public final class ApplePurchaseCoordinator: ObservableObject {
    public enum State: Equatable, Sendable {
        case idle, loading, unavailable, closed, ready, purchasing, pending, cancelled, retrying
        case succeeded, needsSupport(String), otherAccount, revoked, sandboxCapExceeded
    }
    public struct TransactionOutcome: Equatable, Sendable {
        public let productID: String
        public let state: AppleTransactionResponse.State
        public var isCredited: Bool { state == .credited || state == .alreadyCredited }
    }
    public static let productIDs: Set<String> = ["com.atum.mobile.protons.100k", "com.atum.mobile.protons.500k"]
    @Published public private(set) var state: State = .idle
    @Published public private(set) var packs: [AppleProductsResponse.Pack] = []
    @Published public private(set) var products: [AppleStoreProduct] = []
    public var canPurchase: Bool {
        guard checkoutOpen, let acceptedEnvironment, deviceEnvironment == acceptedEnvironment, !products.isEmpty,
              !purchaseInProgress, awaitingPurchaseProductID == nil, unresolvedTransactions.isEmpty
        else { return false }
        switch state {
        case .ready, .cancelled, .succeeded, .needsSupport, .otherAccount, .revoked: return true
        default: return false
        }
    }
    public func purchaseState(for productID: String) -> State { purchaseStates[productID] ?? .idle }

    private let store: any ApplePurchaseStore
    private var deviceEnvironment: ApplePurchaseEnvironment?
    /// The account's catalogue environment, admitted only after a runtime match.
    @Published public private(set) var acceptedEnvironment: ApplePurchaseEnvironment?
    private let sleep: @MainActor (UInt64) async throws -> Void
    private let refreshWallet: @MainActor () async -> Void
    private var api: (any ApplePurchasesAPI)?
    private var accountID: String?
    private var generation = UUID()
    private var tokens: [String: UUID] = [:]
    @Published public private(set) var checkoutOpen = false
    /// Latest state by product ID; transaction identity is carried by needsSupport.
    @Published public private(set) var purchaseStates: [String: State] = [:]
    /// Acknowledged outcomes by StoreKit transaction ID, scoped like settled row feedback.
    @Published public private(set) var transactionOutcomes: [String: TransactionOutcome] = [:]
    private var acknowledgementOrder = 0
    private var rowAcknowledgements: [String: Int] = [:]
    private var listener: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    @Published private var purchaseInProgress = false
    // Set before StoreKit can deliver an approval on either purchase path.
    private var awaitingPurchaseProductID: String?
    @Published private var unresolvedTransactions = Set<String>()
    private var submissions: [String: Task<Void, Never>] = [:]
    // Track credits for this account after the sheet drops their feedback.
    private var acknowledgedCredits = Set<String>()
    private var unresolvedRefunds = Set<String>()
    private var finished = Set<String>()

    /// `environment` is retained for source compatibility with build-origin callers.
    /// Only the store's verified runtime environment authorizes purchases.
    public init(store: any ApplePurchaseStore, environment _: ApplePurchaseEnvironment,
                sleep: @escaping @MainActor (UInt64) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                }, refreshWallet: @escaping @MainActor () async -> Void) {
        self.store = store; self.sleep = sleep
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
        purchaseInProgress = false; awaitingPurchaseProductID = nil; unresolvedTransactions.removeAll()
        acknowledgedCredits.removeAll(); unresolvedRefunds.removeAll()
        let switchedAccount = self.accountID != accountID
        self.accountID = accountID; self.api = api
        acceptedEnvironment = nil
        transactionOutcomes = [:]; rowAcknowledgements = [:]; acknowledgementOrder = 0
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
            if deviceEnvironment == nil {
                let detected = try await store.purchaseEnvironment()
                guard isCurrent(scope) else { return }
                deviceEnvironment = deviceEnvironment ?? detected
            }
            // API origin and account allowlisting cannot establish the device's
            // StoreKit environment. TestFlight's verified environment is Sandbox.
            guard let deviceEnvironment, catalog.environment == deviceEnvironment else {
                acceptedEnvironment = nil; state = .unavailable; return
            }
            acceptedEnvironment = catalog.environment
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
        guard canPurchase, products.contains(where: { $0.id == id }), let api, let accountID,
              let environment = acceptedEnvironment else { return }
        let scope = generation
        purchaseInProgress = true
        awaitingPurchaseProductID = id
        var awaitingApproval = false
        defer {
            if generation == scope {
                if !awaitingApproval { awaitingPurchaseProductID = nil }
                purchaseInProgress = false
            }
        }
        state = .purchasing; purchaseStates[id] = .purchasing
        do {
            let key = accountID + ":" + environment.rawValue
            let token: UUID
            if let cached = tokens[key] { token = cached }
            else {
                token = try await api.appleAccountToken().appAccountToken
            }
            guard isCurrent(scope) else { return }
            guard checkoutOpen, acceptedEnvironment == environment, deviceEnvironment == environment else {
                purchaseStates[id] = .unavailable
                return
            }
            tokens[key] = token
            let result = try await store.purchase(id: id, accountToken: token)
            guard isCurrent(scope) else { return }
            switch result {
            case let .verified(transaction):
                guard transaction.productID == id, transaction.environment == environment,
                      transaction.environment == acceptedEnvironment else {
                    state = .unavailable; purchaseStates[id] = .unavailable
                    return
                }
                enqueue(transaction)
            case .pending:
                // The listener or unfinished replay may already have admitted the approval.
                guard awaitingPurchaseProductID == id else { return }
                awaitingApproval = true
                state = .pending; purchaseStates[id] = .pending
            case .cancelled: state = .cancelled; purchaseStates[id] = .cancelled
            case .unverified: state = .unavailable; purchaseStates[id] = .unavailable
            }
        } catch {
            guard isCurrent(scope) else { return }
            state = .unavailable; purchaseStates[id] = .unavailable
        }
    }

    /// Forget outcomes the person has already seen, so the next pack sheet
    /// starts from the packs. In-flight states (purchasing, Ask to Buy pending,
    /// retrying), a sandbox cap pause and needs-support (it carries the
    /// transaction ID) are kept. A failed purchase attempt on an open catalogue
    /// returns to ready; nothing is reloaded, credited or finished here.
    public func clearSettledOutcomes() {
        let visibleSupportIDs = purchaseStates.compactMapValues { state -> String? in
            if case let .needsSupport(id) = state { return id }
            return nil
        }
        rowAcknowledgements = rowAcknowledgements.filter { visibleSupportIDs[$0.key] != nil }
        transactionOutcomes = transactionOutcomes.filter { id, outcome in
            visibleSupportIDs[outcome.productID] == id
        }
        purchaseStates = purchaseStates.filter { _, value in
            switch value {
            case .purchasing, .pending, .retrying, .needsSupport, .sandboxCapExceeded: true
            default: false
            }
        }
        guard checkoutOpen, !products.isEmpty else { return }
        switch state {
        case .succeeded, .cancelled, .otherAccount, .revoked, .unavailable: state = .ready
        default: break
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
        guard let api, accountID != nil, let environment = acceptedEnvironment,
              transaction.environment == environment,
              Self.productIDs.contains(transaction.productID) else { return }
        let scope = generation
        let id = transaction.id
        if transaction.isRevoked, acknowledgedCredits.remove(id) != nil {
            // StoreKit verified a refund for a credit we already processed.
            // Invalidate it before refreshing, including when its first refresh is still running.
            acknowledgementOrder += 1
            let outcome = TransactionOutcome(productID: transaction.productID, state: .revoked)
            publishOutcome(outcome, transactionID: id, state: .revoked, order: acknowledgementOrder)
            Task { [weak self] in
                guard let self, self.isCurrent(scope) else { return }
                await self.refreshWallet()
            }
            return
        }
        guard !finished.contains(id) else { return }
        if transaction.isRevoked { unresolvedRefunds.insert(id) }
        guard submissions[id] == nil else { return }
        if awaitingPurchaseProductID == transaction.productID { awaitingPurchaseProductID = nil }
        unresolvedTransactions.insert(id)
        state = .retrying; purchaseStates[transaction.productID] = .retrying
        submissions[id] = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == scope { self.submissions[id] = nil } }
            var delay: UInt64 = 2
            while self.isCurrent(scope) {
                do {
                    let request = try AppleTransactionRequest(signedTransaction: transaction.signedTransaction)
                    let result = try await api.appleTransaction(request)
                    guard self.isCurrent(scope) else { return }
                    guard result.transactionId == id, result.finish else { throw ContractViolation.invariant }
                    self.acknowledgementOrder += 1
                    let order = self.acknowledgementOrder
                    await transaction.finish()
                    guard self.isCurrent(scope) else { return }
                    self.finished.insert(id)
                    // Keep Buy disabled until the wallet and row have settled.
                    defer {
                        if self.generation == scope { self.unresolvedTransactions.remove(id) }
                    }
                    let terminalState: State
                    switch result.state {
                    case .credited, .alreadyCredited: terminalState = .succeeded
                    case .needsSupport: terminalState = .needsSupport(id)
                    case .creditedToOtherAccount: terminalState = .otherAccount
                    case .revoked: terminalState = .revoked
                    }
                    let hasVerifiedRefund = self.unresolvedRefunds.remove(id) != nil
                    let refundOverridesCredit = hasVerifiedRefund && terminalState == .succeeded
                    let outcome = TransactionOutcome(
                        productID: transaction.productID, state: refundOverridesCredit ? .revoked : result.state)
                    if outcome.isCredited { self.acknowledgedCredits.insert(id) }
                    self.state = terminalState
                    if terminalState == .succeeded || terminalState == .revoked { await self.refreshWallet() }
                    guard self.isCurrent(scope), !outcome.isCredited || self.acknowledgedCredits.contains(id) else {
                        return
                    }
                    self.publishOutcome(outcome, transactionID: id,
                                        state: refundOverridesCredit ? .revoked : terminalState, order: order)
                    return
                } catch {
                    guard self.isCurrent(scope) else { return }
                    if let error = error as? ApplePurchaseError, error.reason == .sandboxCapExceeded {
                        // No durable outcome: keep StoreKit's transaction unfinished.
                        // A later explicit restore/replay can settle after a cap raise.
                        self.checkoutOpen = false; self.state = .sandboxCapExceeded
                        self.purchaseStates[transaction.productID] = self.state
                        return
                    }
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

    private func publishOutcome(_ outcome: TransactionOutcome, transactionID: String, state: State, order: Int) {
        transactionOutcomes[transactionID] = outcome
        let productID = outcome.productID
        // Wallet refresh and StoreKit finish can resume out of acknowledgement order.
        if order > rowAcknowledgements[productID, default: 0] {
            rowAcknowledgements[productID] = order
            let hasCredit = state == .revoked && transactionOutcomes.values.contains {
                $0.productID == productID && $0.isCredited
            }
            purchaseStates[productID] = hasCredit ? .succeeded : state
        } else if state == .succeeded, purchaseStates[productID] == .revoked {
            // A credit can also finish refreshing after a newer refund for this pack.
            purchaseStates[productID] = .succeeded
        }
    }
}
