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
                      refresh: @escaping @MainActor () async -> Void = {},
                      sleep: @escaping @MainActor (UInt64) async throws -> Void = { _ in
                          try await Task.sleep(nanoseconds: 60_000_000_000)
                      }) async -> ApplePurchaseCoordinator {
        let c = ApplePurchaseCoordinator(store: store, environment: .sandbox,
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

    private func transaction(id transactionID: String = "2000000123456789", _ finish: @escaping @MainActor @Sendable () async -> Void) -> AppleVerifiedTransaction {
        .init(id: transactionID, productID: id, environment: .sandbox, accountToken: nil,
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
    var replies: [AppleTransactionResponse?] = []
    var blockPost = false
    var blocked: CheckedContinuation<AppleTransactionResponse, Never>?
    func appleProducts() async throws -> AppleProductsResponse {
        try NativeAPI.decode(AppleProductsResponse.self, from: ApplePurchaseTestData.data(
            closed ? .productsClosed : .productsOpen, ownerProducts: true))
    }
    func appleAccountToken() async throws -> AppleAccountTokenResponse {
        tokenReads += 1
        return try NativeAPI.decode(AppleAccountTokenResponse.self,
            from: JSONSerialization.data(withJSONObject: ["appAccountToken": token.uuidString.lowercased()]))
    }
    func appleTransaction(_ request: AppleTransactionRequest) async throws -> AppleTransactionResponse {
        posts += 1
        if blockPost { return await withCheckedContinuation { blocked = $0 } }
        if !replies.isEmpty {
            guard let result = replies.removeFirst() else { throw NativeDomainClientFailure.transportUnavailable }
            return result
        }
        return try reply()
    }
    func reply(finish: Bool = true) throws -> AppleTransactionResponse {
        var value = ApplePurchaseTestData.object(sample)
        value["finish"] = finish
        return try NativeAPI.decode(AppleTransactionResponse.self,
                                    from: JSONSerialization.data(withJSONObject: value))
    }
}
