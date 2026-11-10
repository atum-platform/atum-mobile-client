import Foundation
import XCTest
@testable import AtumNativeAPI

@MainActor final class ApplePurchaseCoordinatorTests: XCTestCase {
    private let id = "com.atum.mobile.protons.100k"

    private func settled(_ condition: @escaping @MainActor () -> Bool,
                         file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Purchase state did not settle", file: file, line: line)
    }

    private func make(_ store: PurchaseStoreStub, _ api: PurchaseAPIStub,
                      environment: ApplePurchaseEnvironment = .production,
                      refresh: @escaping @MainActor () async -> Void = {},
                      sleep: @escaping @MainActor (UInt64) async throws -> Void = { _ in
                          try await Task.sleep(nanoseconds: 60_000_000_000)
                      }) async -> ApplePurchaseCoordinator {
        let c = ApplePurchaseCoordinator(store: store, environment: environment,
                                         sleep: sleep, refreshWallet: refresh)
        c.start(); c.bind(accountID: "synthetic-account-a", api: api)
        await settled { !c.products.isEmpty || c.state == .closed || c.state == .unavailable }
        return c
    }

    func testVerifiedPurchaseUsesTokenAndFinishesOnlyAfterDurableAcknowledgment() async throws {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        var finishes = 0; var refreshes = 0
        store.result = .verified(transaction { finishes += 1 })
        let c = await make(store, api, refresh: { refreshes += 1 })
        await c.purchase(id)
        await settled { finishes == 1 }
        XCTAssertEqual(api.posts, 1); XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(c.state, .succeeded); XCTAssertEqual(c.purchaseStates[id], .succeeded)
        XCTAssertEqual(store.tokens, [api.token]); XCTAssertEqual(api.tokenReads, 1)
        // A second purchase in the same account/environment reuses the token.
        store.result = .cancelled; await c.purchase(id)
        XCTAssertEqual(api.tokenReads, 1)
        c.bind(accountID: nil, api: nil)
    }

    func testFalseFinishDoesNotFinishAndAmbiguousReplyRetriesWithBackoff() async throws {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        var finishes = 0; var delays: [UInt64] = []
        api.replies = [try api.reply(finish: false), nil, try api.reply()]
        store.result = .verified(transaction { finishes += 1 })
        let c = await make(store, api, sleep: { delay in
            XCTAssertEqual(finishes, 0)
            delays.append(delay)
            await Task.yield()
        })
        await c.purchase(id)
        await settled { finishes == 1 }
        XCTAssertEqual(api.posts, 3); XCTAssertEqual(delays, [2, 4])
        c.bind(accountID: nil, api: nil)
    }

    func testUnfinishedReplayAndUpdatesDeduplicateAndRefresh() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        var finishes = 0
        let t = transaction { finishes += 1 }
        store.queue = [t]
        let c = await make(store, api)
        await settled { finishes == 1 }
        store.continuation?.yield(t)
        await c.replayUnfinished(); await Task.yield()
        XCTAssertEqual(finishes, 1); XCTAssertEqual(api.posts, 1)
        c.bind(accountID: nil, api: nil)
    }

    func testAccountSwitchCancelsOldRetriesAndRejectsLateResponse() async throws {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        var finishes = 0
        api.blockPost = true
        store.result = .verified(transaction { finishes += 1 })
        let c = await make(store, api)
        await c.purchase(id)
        await settled { api.posts == 1 }
        let second = PurchaseAPIStub()
        c.bind(accountID: "synthetic-account-b", api: second)
        api.blocked?.resume(returning: try api.reply()); api.blocked = nil
        await settled { c.state == .ready }
        XCTAssertEqual(finishes, 0); XCTAssertEqual(second.posts, 0)
        // A new account fetches its own binding token.
        await c.purchase(id)
        await settled { finishes == 1 }
        XCTAssertEqual(second.tokenReads, 1)
        c.bind(accountID: nil, api: nil)
    }

    func testSignOutStopsRetryPosting() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        api.replies = [nil]
        store.result = .verified(transaction {})
        var retrySleeping = false
        let c = await make(store, api, sleep: { _ in
            retrySleeping = true
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })
        await c.purchase(id); await settled { retrySleeping }
        c.bind(accountID: nil, api: nil)
        await c.replayUnfinished()
        XCTAssertEqual(api.posts, 1); XCTAssertFalse(c.canPurchase)
    }

    func testClosedCheckoutAndStoreFailureExposeNoPurchaseAuthority() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub(); api.closed = true
        let c = await make(store, api)
        XCTAssertFalse(c.checkoutOpen); XCTAssertFalse(c.canPurchase); XCTAssertTrue(c.products.isEmpty)
        await c.purchase(id)
        XCTAssertEqual(store.purchaseCalls, 0); XCTAssertEqual(store.productReads, 0)
        api.closed = false; store.failProducts = true
        await c.load()
        XCTAssertEqual(c.state, .unavailable); XCTAssertFalse(c.canPurchase)
        c.bind(accountID: nil, api: nil)
    }

    func testPendingCancelledAndUnverifiedSendNothing() async {
        for result in [AppleStorePurchaseResult.pending, .cancelled, .unverified] {
            let store = PurchaseStoreStub(); let api = PurchaseAPIStub(); store.result = result
            let c = await make(store, api)
            await c.purchase(id)
            XCTAssertEqual(api.posts, 0)
            XCTAssertTrue([.pending, .cancelled, .unavailable].contains(c.state))
            c.bind(accountID: nil, api: nil)
        }
    }

    func testPendingApprovalArrivesThroughLongLivedUpdatesListener() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        store.result = .pending
        var finishes = 0
        let c = await make(store, api)
        await c.purchase(id)
        XCTAssertEqual(c.purchaseState(for: id), .pending); XCTAssertEqual(api.posts, 0)
        store.continuation?.yield(transaction { finishes += 1 })
        await settled { c.purchaseState(for: self.id) == .succeeded }
        XCTAssertEqual(api.posts, 1); XCTAssertEqual(finishes, 1)
        c.bind(accountID: nil, api: nil)
    }

    func testNeedsSupportFinishesAndCarriesTransactionID() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        api.sample = .transactionNeedsSupport
        var finishes = 0
        store.result = .verified(transaction(id: "2000000123456790") { finishes += 1 })
        let c = await make(store, api)
        await c.purchase(id); await settled { c.state == .needsSupport("2000000123456790") }
        XCTAssertEqual(finishes, 1)
        c.bind(accountID: nil, api: nil)
    }

    func testAllowlistedSandboxCatalogueOnProductionSubmitsPromoCreditAndFinishes() async throws {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        api.catalogData = try ApplePurchaseV12TestData.data("allowlisted-products.response")
        api.replyData = try ApplePurchaseV12TestData.data("sandbox-credited.response")
        var finishes = 0; var refreshes = 0
        store.queue = [transaction { finishes += 1 }]
        let c = await make(store, api, refresh: { refreshes += 1 })
        await settled { c.state == .succeeded }
        XCTAssertEqual(c.acceptedEnvironment, .sandbox)
        XCTAssertEqual(c.packs.count, 2); XCTAssertEqual(store.productReads, 1)
        XCTAssertEqual(api.posts, 1); XCTAssertEqual(finishes, 1); XCTAssertEqual(refreshes, 1)
        XCTAssertTrue(c.canPurchase)
        c.bind(accountID: nil, api: nil)
    }

    func testSandboxReplayAcknowledgmentFinishesWithoutAnotherCredit() async throws {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        api.catalogData = try ApplePurchaseV12TestData.data("allowlisted-products.response")
        api.replyData = try ApplePurchaseV12TestData.data("sandbox-replayed.response")
        var finishes = 0
        store.result = .verified(transaction { finishes += 1 })
        let c = await make(store, api)
        await c.purchase(id); await settled { c.state == .succeeded }
        XCTAssertEqual(api.posts, 1); XCTAssertEqual(finishes, 1)
        c.bind(accountID: nil, api: nil)
    }

    func testSandboxCapRefusalDoesNotFinishOrRetryAndExplicitRestoreCanSettle() async throws {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        api.catalogData = try ApplePurchaseV12TestData.data("allowlisted-products.response")
        api.postError = try NativeAPI.decode(ApplePurchaseError.self,
            from: ApplePurchaseV12TestData.data("sandbox-cap.error"))
        var finishes = 0; var refreshes = 0; var delays: [UInt64] = []
        let unfinished = transaction { finishes += 1 }
        store.result = .verified(unfinished)
        let c = await make(store, api, refresh: { refreshes += 1 }, sleep: { delays.append($0) })
        await c.purchase(id); await settled { c.state == .sandboxCapExceeded }
        XCTAssertEqual(c.purchaseState(for: id), .sandboxCapExceeded)
        XCTAssertFalse(c.canPurchase); XCTAssertFalse(c.checkoutOpen)
        XCTAssertEqual(api.posts, 1); XCTAssertEqual(finishes, 0); XCTAssertEqual(refreshes, 0)
        XCTAssertTrue(delays.isEmpty)
        await c.purchase(id); XCTAssertEqual(store.purchaseCalls, 1)
        // An operator may raise the cap; StoreKit still owns the same transaction.
        api.postError = nil
        api.replyData = try ApplePurchaseV12TestData.data("sandbox-credited.response")
        store.queue = [unfinished]
        await c.restore(); await settled { c.state == .succeeded }
        XCTAssertEqual(api.posts, 2); XCTAssertEqual(finishes, 1)
        await c.replayUnfinished(); XCTAssertEqual(api.posts, 2)
        c.bind(accountID: nil, api: nil)
    }

    func testAccountTokenCacheIsScopedToServerSelectedEnvironment() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        let sandboxToken = api.token
        let c = await make(store, api)
        await c.purchase(id)
        api.catalogEnvironment = .production
        api.token = UUID(uuidString: "00000000-0000-4000-8000-0000000000bb")!
        await c.load(); await c.purchase(id)
        XCTAssertEqual(c.acceptedEnvironment, .production)
        XCTAssertEqual(api.tokenReads, 2)
        XCTAssertEqual(store.tokens, [sandboxToken, api.token])
        api.catalogEnvironment = .sandbox
        await c.load(); await c.purchase(id)
        XCTAssertEqual(api.tokenReads, 2)
        XCTAssertEqual(store.tokens.last, sandboxToken)
        c.bind(accountID: nil, api: nil)
        XCTAssertNil(c.acceptedEnvironment)
    }

    func testCatalogueRefreshDoesNotStrandAnAdmittedTransaction() async throws {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        api.blockPost = true
        var finishes = 0
        store.result = .verified(transaction { finishes += 1 })
        let c = await make(store, api)
        await c.purchase(id); await settled { api.blocked != nil }
        api.blockCatalog = true
        let reload = Task { await c.load() }
        await settled { api.catalogBlocked != nil }
        XCTAssertFalse(c.canPurchase)
        api.blocked?.resume(returning: try api.reply()); api.blocked = nil
        await settled { finishes == 1 }
        api.catalogBlocked?.resume(returning: try NativeAPI.decode(AppleProductsResponse.self,
            from: ApplePurchaseV12TestData.data("allowlisted-products.response")))
        api.catalogBlocked = nil
        await reload.value
        XCTAssertTrue(c.canPurchase); XCTAssertEqual(api.posts, 1)
        c.bind(accountID: nil, api: nil)
    }

    func testProductionCatalogueStillPurchasesCreditsAndFinishesProductionOnly() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        api.catalogEnvironment = .production
        var finishes = 0; var refreshes = 0
        store.queue = [transaction { finishes += 1 }]
        store.result = .verified(transaction(environment: .production) { finishes += 1 })
        let c = await make(store, api, refresh: { refreshes += 1 })
        await c.replayUnfinished()
        XCTAssertEqual(c.acceptedEnvironment, .production)
        XCTAssertEqual(api.posts, 0); XCTAssertEqual(finishes, 0)
        await c.purchase(id); await settled { c.state == .succeeded }
        XCTAssertEqual(api.posts, 1); XCTAssertEqual(finishes, 1); XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(store.tokens, [api.token]); XCTAssertTrue(c.canPurchase)
        c.bind(accountID: nil, api: nil)
    }

    func testNonAllowlistedProductionCatalogueRemainsClosedAndRejectsSandboxUpdates() async throws {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        api.catalogData = try ApplePurchaseV12TestData.data("production-closed.response")
        var finishes = 0
        store.queue = [transaction { finishes += 1 }]
        let c = await make(store, api)
        store.continuation?.yield(transaction { finishes += 1 })
        await c.replayUnfinished(); await Task.yield()
        XCTAssertEqual(c.state, .closed); XCTAssertEqual(c.acceptedEnvironment, .production)
        XCTAssertFalse(c.canPurchase); XCTAssertEqual(store.productReads, 0)
        XCTAssertEqual(api.posts, 0); XCTAssertEqual(finishes, 0)
        c.bind(accountID: nil, api: nil)
    }

    func testSandboxDeploymentCannotAcceptProductionCatalogue() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        api.catalogEnvironment = .production
        let c = await make(store, api, environment: .sandbox)
        XCTAssertEqual(c.state, .unavailable); XCTAssertNil(c.acceptedEnvironment)
        XCTAssertEqual(store.productReads, 0); XCTAssertFalse(c.canPurchase)
        c.bind(accountID: nil, api: nil)
    }

    func testEveryDurableTerminalStateAllowsAnotherPurchaseInTheSameSession() async {
        for state in [AppleTransactionResponse.State.credited, .alreadyCredited, .needsSupport,
                      .creditedToOtherAccount, .revoked] {
            let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
            api.replyState = state
            var finishes = 0
            store.result = .verified(transaction { finishes += 1 })
            let c = await make(store, api)
            await c.purchase(id)
            await settled { c.purchaseState(for: self.id) != .retrying }
            XCTAssertEqual(finishes, 1)
            XCTAssertTrue(c.canPurchase, "Terminal state \(state) stranded checkout")
            store.result = .cancelled
            await c.purchase(id)
            XCTAssertEqual(store.purchaseCalls, 2)
            c.bind(accountID: nil, api: nil)
        }
    }

    func testRestoreRefreshesWalletAndReplaysEvenWhenCheckoutClosed() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub(); api.closed = true
        var finishes = 0; var refreshes = 0
        let c = await make(store, api, refresh: { refreshes += 1 })
        store.queue = [transaction { finishes += 1 }]
        await c.restore(); await settled { finishes == 1 }
        XCTAssertEqual(api.posts, 1); XCTAssertEqual(refreshes, 2)
        XCTAssertFalse(c.canPurchase)
        c.bind(accountID: nil, api: nil)
    }

    func testWrongTransactionIDOrEnvironmentCannotFinish() async throws {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        var finishes = 0
        store.queue = [.init(id: "4", productID: id, environment: nil, accountToken: nil,
                            signedTransaction: "a.b.c", finish: { finishes += 1 })]
        var retrySleeping = false
        let c = await make(store, api, sleep: { _ in
            retrySleeping = true
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })
        XCTAssertEqual(api.posts, 0)
        store.queue = [.init(id: "4", productID: id, environment: .sandbox, accountToken: nil,
                            signedTransaction: "a.b.c", finish: { finishes += 1 })]
        await c.replayUnfinished(); await settled { retrySleeping }
        XCTAssertEqual(api.posts, 1)
        XCTAssertEqual(finishes, 0)
        c.bind(accountID: nil, api: nil)
    }

    private func transaction(id transactionID: String = "2000000123456789",
                             environment: ApplePurchaseEnvironment = .sandbox,
                             _ finish: @escaping @MainActor @Sendable () async -> Void) -> AppleVerifiedTransaction {
        .init(id: transactionID, productID: id, environment: environment, accountToken: nil,
              signedTransaction: "synthetic.payload.signature", finish: finish)
    }
}

@MainActor private final class PurchaseStoreStub: ApplePurchaseStore {
    var continuation: AsyncStream<AppleVerifiedTransaction>.Continuation?
    var queue: [AppleVerifiedTransaction] = []
    var result: AppleStorePurchaseResult = .cancelled
    var tokens: [UUID] = []
    var purchaseCalls = 0; var productReads = 0; var failProducts = false
    func products(ids: Set<String>) async throws -> [AppleStoreProduct] {
        productReads += 1
        if failProducts { throw ContractViolation.invalidValue }
        return ids.map { .init(id: $0, displayPrice: "synthetic-price") }
    }
    func purchase(id: String, accountToken: UUID) async throws -> AppleStorePurchaseResult {
        purchaseCalls += 1; tokens.append(accountToken); return result
    }
    func updates() -> AsyncStream<AppleVerifiedTransaction> {
        AsyncStream { continuation = $0 }
    }
    func unfinished() async -> [AppleVerifiedTransaction] { queue }
}

@MainActor private final class PurchaseAPIStub: ApplePurchasesAPI {
    var posts = 0; var tokenReads = 0; var closed = false
    var token = UUID(uuidString: "00000000-0000-4000-8000-0000000000aa")!
    var sample = ApplePurchaseTestData.Case.transactionCredited
    var catalogData: Data?
    var blockCatalog = false
    var catalogBlocked: CheckedContinuation<AppleProductsResponse, Never>?
    var catalogEnvironment = ApplePurchaseEnvironment.sandbox
    var replyData: Data?
    var replyState: AppleTransactionResponse.State?
    var postError: ApplePurchaseError?
    var replies: [AppleTransactionResponse?] = []
    var blockPost = false
    var blocked: CheckedContinuation<AppleTransactionResponse, Never>?
    func appleProducts() async throws -> AppleProductsResponse {
        if blockCatalog { return await withCheckedContinuation { catalogBlocked = $0 } }
        if let catalogData { return try NativeAPI.decode(AppleProductsResponse.self, from: catalogData) }
        var value = ApplePurchaseTestData.object(closed ? .productsClosed : .productsOpen, ownerProducts: true)
        value["environment"] = catalogEnvironment.rawValue
        return try NativeAPI.decode(AppleProductsResponse.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func appleAccountToken() async throws -> AppleAccountTokenResponse {
        tokenReads += 1
        return try NativeAPI.decode(AppleAccountTokenResponse.self,
            from: JSONSerialization.data(withJSONObject: ["appAccountToken": token.uuidString.lowercased()]))
    }
    func appleTransaction(_ request: AppleTransactionRequest) async throws -> AppleTransactionResponse {
        posts += 1
        if let postError { throw postError }
        if blockPost { return await withCheckedContinuation { blocked = $0 } }
        if !replies.isEmpty {
            guard let result = replies.removeFirst() else { throw NativeDomainClientFailure.transportUnavailable }
            return result
        }
        return try reply()
    }
    func reply(finish: Bool = true) throws -> AppleTransactionResponse {
        if let replyData { return try NativeAPI.decode(AppleTransactionResponse.self, from: replyData) }
        var value = ApplePurchaseTestData.object(sample)
        if let replyState {
            value["state"] = replyState.rawValue
            if replyState != .credited { value["credited"] = NSNull(); value["balances"] = NSNull() }
        }
        value["finish"] = finish
        return try NativeAPI.decode(AppleTransactionResponse.self,
                                    from: JSONSerialization.data(withJSONObject: value))
    }
}
