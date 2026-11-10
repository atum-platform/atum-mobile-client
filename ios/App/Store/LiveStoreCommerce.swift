import AtumNativeAPI
import Foundation
import Observation

/// Observable UI state, separated from the bearer client and durable purchase
/// state machine. Each session generation discards late answers after sign-out.
@MainActor @Observable final class LiveStoreCommerce {
    struct Target: Identifiable, Equatable {
        let id: NativeID
        let principal: NativeID
        let name: String
        let roomID: String?
    }
    private(set) var catalog: [StoreCatalogItem] = []
    private(set) var entitlements: [StoreEntitlement] = []
    private(set) var purchases: [StorePurchase] = []
    private(set) var savedAttempts: [StorePurchaseAttempt] = []
    private(set) var journalReady = false
    private(set) var wallet: WalletResponse?
    private(set) var targets: [Target] = []
    private(set) var paidTargets = Set<NativeID>()
    enum ReadState: Equatable { case unavailable, loading, ready, offline, forbidden }
    enum CancellationState: Equatable {
        case idle, working(NativeID), cancelled(StoreEntitlement), uncertain(NativeID), forbidden(NativeID)
    }
    private(set) var readState: ReadState = .unavailable
    private(set) var cancellationState: CancellationState = .idle
    private(set) var ready = false
    private(set) var busy = false
    private(set) var refreshing = false
    private(set) var state: StoreAcquireState = .idle
    private(set) var operationAssistantID: NativeID?
    private(set) var operationItemID: String?
    private(set) var cancelFailed = false
    private(set) var cancelled = Set<NativeID>()
    @ObservationIgnored private var client: (any StoreCommerceAPI)?
    @ObservationIgnored private var acquisition: StoreAcquisition?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var account: String?
    @ObservationIgnored private let journal: any StoreAttemptJournal

    init(journal: (any StoreAttemptJournal)? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.journal = journal ?? StoreFileJournal(directory: base.appendingPathComponent("StoreAttempts", isDirectory: true))
    }

    func configure(account: String, client: any StoreCommerceAPI, targets: [Target]) {
        if self.account != account || self.client !== client {
            reset()
            self.account = account; self.client = client
            acquisition = StoreAcquisition(account: account, journal: journal) { attempt in
                try await client.acquireStoreItem(attempt)
            }
        }
        self.targets = targets
        loadSavedAttempts(account: account)
    }

    func reset() {
        generation = UUID(); client = nil; acquisition = nil; account = nil
        catalog = []; entitlements = []; purchases = []; savedAttempts = []; wallet = nil; targets = []
        readState = .unavailable; cancellationState = .idle
        paidTargets = []; ready = false; busy = false; refreshing = false; state = .idle
        journalReady = false
        operationAssistantID = nil; operationItemID = nil; cancelled = []; cancelFailed = false
    }

    func refresh() async { await reload(allowWhileBusy: false) }

    private func reload(allowWhileBusy: Bool) async {
        guard !refreshing, (!busy || allowWhileBusy), let client else { return }
        let token = generation
        refreshing = true; ready = false; readState = .loading; paidTargets = []; wallet = nil
        defer { if generation == token { refreshing = false } }
        do {
            // Sequential on the main actor: the client is main-actor isolated and
            // not Sendable, so Swift 6 rejects concurrent `async let` sends of it.
            let values = (try await client.storeCatalog(), try await client.storeEntitlements(),
                          try await client.storePurchases(), try await client.wallet())
            guard generation == token else { return }
            catalog = values.0.items; entitlements = values.1.entitlements
            purchases = values.2.purchases; wallet = values.3
            if let account { loadSavedAttempts(account: account) }
            var eligible = Set<NativeID>()
            for target in targets {
                // An own-key/subscription destination must not buy protected
                // content that cannot reach its model. Unknown fails closed.
                if let choices = try? await client.managedModelDestinations(agentPrincipal: target.principal),
                   choices.choices.allSatisfy({ $0.source == .atum }) {
                    eligible.insert(target.id)
                }
                guard generation == token else { return }
            }
            paidTargets = eligible; ready = true; readState = .ready
        } catch {
            guard generation == token else { return }
            ready = false; wallet = nil; paidTargets = []
            switch error {
            case NativeDomainClientFailure.transportUnavailable: readState = .offline
            case NativeDomainClientFailure.authenticationRefused: readState = .forbidden
            case NativeDomainClientFailure.http(let failure) where failure.response.error == .denied:
                readState = .forbidden
            default: readState = .unavailable
            }
        }
    }

    private func loadSavedAttempts(account: String) {
        do {
            savedAttempts = try journal.attempts(account: account)
            journalReady = true
        } catch {
            savedAttempts = []; journalReady = false
        }
    }

    var unresolvedAttempts: [StorePurchaseAttempt] {
        savedAttempts.filter { attempt in
            if let purchase = purchases.first(where: { attempt.matches($0) }) {
                return purchase.state == .deliveryPending
            }
            return !entitlements.contains { $0.itemID == attempt.itemID && $0.assistantID == attempt.assistantID && $0.isOwned }
        }
    }

    func owned(_ item: StoreCatalogItem, assistant: NativeID?) -> Bool {
        if entitlements.contains(where: { $0.itemID == item.itemID && $0.isOwned
            && (item.kind != .skill || $0.assistantID == assistant) }) { return true }
        guard let ownership = item.ownership, ownership.state == .owned else { return false }
        return item.kind != .skill || assistant.map(ownership.assistantIDs.contains) == true
    }

    func attempt(itemID: String, assistant: NativeID?) -> StorePurchaseAttempt? {
        try? acquisition?.attempt(itemID: itemID, assistantID: assistant)
    }

    enum ReviewFailure: Error { case unavailable, alreadyOwned, unresolvedPurchase, noEligibleAssistant, insufficientBalance }

    /// UI asks for a fresh immutable quote before presenting its confirmation.
    /// The displayed quote is passed back verbatim to confirm; no request ID is
    /// minted and no journal is written until that explicit confirmation.
    func review(itemID: String, assistant: NativeID?) throws -> StoreAcquireQuote {
        guard ready, journalReady, !busy, let balance = wallet?.balances.available,
              let item = catalog.first(where: { $0.itemID == itemID }) else { throw ReviewFailure.unavailable }
        if item.kind == .skill && (assistant == nil || !paidTargets.contains(assistant!)) {
            throw ReviewFailure.noEligibleAssistant
        }
        guard !owned(item, assistant: assistant) else { throw ReviewFailure.alreadyOwned }
        guard try acquisition?.attempt(itemID: itemID, assistantID: assistant) == nil else {
            throw ReviewFailure.unresolvedPurchase
        }
        let quote = try StoreAcquireQuote(item: item, assistantID: assistant, balance: balance)
        guard quote.resultingBalance >= 0 else { throw ReviewFailure.insufficientBalance }
        return quote
    }

    func confirm(_ quote: StoreAcquireQuote) async {
        guard !busy, !refreshing, let acquisition else { return }
        guard ready, journalReady, catalog.contains(where: { $0.itemID == quote.item.itemID && $0.offer == quote.item.offer }) else {
            state = .unavailable; operationItemID = quote.item.itemID; return
        }
        if quote.item.kind == .skill, !paidTargets.contains(quote.assistantID!) { return }
        let token = generation
        busy = true; state = .working; operationItemID = quote.item.itemID; operationAssistantID = quote.assistantID
        let result = await acquisition.confirm(quote, online: ready)
        guard generation == token else { return }
        state = result
        await reconcile(result, token: token)
    }

    func retry(_ attempt: StorePurchaseAttempt) async {
        guard !busy, !refreshing, let acquisition else { return }
        let token = generation
        busy = true; state = .working; operationItemID = attempt.itemID; operationAssistantID = attempt.assistantID
        let result = await acquisition.retry(attempt, online: client != nil)
        guard generation == token else { return }
        state = result
        await reconcile(result, token: token)
    }

    private func reconcile(_ result: StoreAcquireState, token: UUID) async {
        // A pre-spend balance must never survive an uncertain/committed write.
        wallet = nil; ready = false
        if let account { loadSavedAttempts(account: account) }
        if case .result(let answer) = result {
            let entitlement: StoreEntitlement?
            switch answer {
            case .alreadyOwned(let value): entitlement = value
            case .purchased(_, let value): entitlement = value
            default: entitlement = nil
            }
            if let entitlement {
                entitlements.removeAll { $0.id == entitlement.id }
                entitlements.append(entitlement)
            }
        }
        await reload(allowWhileBusy: true)
        guard generation == token else { return }
        busy = false
    }

    func cancel(_ entitlement: StoreEntitlement) async {
        guard !busy, !refreshing, ready, entitlement.canCancel,
              entitlements.contains(where: { $0.id == entitlement.id && $0.canCancel }), let client else { return }
        let token = generation
        busy = true; cancelFailed = false; cancellationState = .working(entitlement.id)
        do {
            let value = try await client.cancelStoreSubscription(entitlement.id)
            guard generation == token else { return }
            entitlements.removeAll { $0.id == value.id }; entitlements.append(value)
            cancelled.insert(value.id); cancellationState = .cancelled(value)
        } catch {
            guard generation == token else { return }
            cancelFailed = true
            if (error as? NativeDomainClientFailure) == .authenticationRefused {
                cancellationState = .forbidden(entitlement.id)
            } else if case NativeDomainClientFailure.http(let failure) = error, failure.response.error == .denied {
                cancellationState = .forbidden(entitlement.id)
            } else {
                cancellationState = .uncertain(entitlement.id)
            }
        }
        await reload(allowWhileBusy: true)
        guard generation == token else { return }
        busy = false
    }
}
