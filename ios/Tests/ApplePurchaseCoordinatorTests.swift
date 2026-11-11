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

    func testTestFlightSandboxCatalogueOnProductionBuildSubmitsPromoCreditAndFinishes() async throws {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        api.catalogData = try ApplePurchaseV12TestData.data("allowlisted-products.response")
        api.replyData = try ApplePurchaseV12TestData.data("sandbox-credited.response")
        var finishes = 0; var refreshes = 0
        store.result = .verified(transaction { finishes += 1 })
        let c = await make(store, api, refresh: { refreshes += 1 })
        XCTAssertTrue(c.canPurchase)
        await c.purchase(id)
        await settled { c.state == .succeeded }
        XCTAssertEqual(c.acceptedEnvironment, .sandbox)
        XCTAssertEqual(c.packs.count, 2); XCTAssertEqual(store.productReads, 1)
        XCTAssertEqual(api.posts, 1); XCTAssertEqual(finishes, 1); XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(store.purchaseCalls, 1)
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

    func testRuntimeEnvironmentIsCachedAcrossReloadAndAccountSwitch() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        let c = await make(store, api)
        await c.purchase(id)
        await c.load(); await c.purchase(id)
        XCTAssertEqual(store.environmentReads, 1); XCTAssertEqual(api.tokenReads, 1)
        XCTAssertEqual(store.tokens, [api.token, api.token])

        // Account selection can change the catalogue, never the device environment.
        let second = PurchaseAPIStub(); second.catalogEnvironment = .production
        c.bind(accountID: "synthetic-account-b", api: second)
        await settled { c.state == .unavailable }
        await c.purchase(id)
        XCTAssertEqual(store.environmentReads, 1)
        XCTAssertNil(c.acceptedEnvironment); XCTAssertEqual(second.tokenReads, 0)
        XCTAssertEqual(store.purchaseCalls, 2)
        c.bind(accountID: nil, api: nil)
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
        api.catalogEnvironment = .production; store.environment = .production
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
        store.environment = .production
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

    func testSandboxDeviceCannotAcceptProductionCatalogue() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        api.catalogEnvironment = .production
        let c = await make(store, api)
        XCTAssertEqual(c.state, .unavailable); XCTAssertNil(c.acceptedEnvironment)
        XCTAssertEqual(store.productReads, 0); XCTAssertFalse(c.canPurchase)
        await c.purchase(id)
        XCTAssertEqual(store.purchaseCalls, 0); XCTAssertEqual(api.tokenReads, 0)
        c.bind(accountID: nil, api: nil)
    }

    func testAppStoreDeviceCannotBuyAllowlistedSandboxCatalogue() async throws {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        store.environment = .production
        api.catalogData = try ApplePurchaseV12TestData.data("allowlisted-products.response")
        let c = await make(store, api)
        XCTAssertEqual(c.state, .unavailable); XCTAssertNil(c.acceptedEnvironment)
        XCTAssertFalse(c.checkoutOpen); XCTAssertFalse(c.canPurchase)
        XCTAssertTrue(c.products.isEmpty); XCTAssertTrue(c.packs.isEmpty)
        c.clearSettledOutcomes()
        await c.purchase(id)
        XCTAssertEqual(store.productReads, 0); XCTAssertEqual(store.purchaseCalls, 0)
        XCTAssertEqual(api.tokenReads, 0); XCTAssertEqual(api.posts, 0)
        c.bind(accountID: nil, api: nil)
    }

    func testRuntimeProductionMatchOverridesSandboxBuildConfiguration() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        store.environment = .production; api.catalogEnvironment = .production
        let c = await make(store, api, environment: .sandbox)
        XCTAssertTrue(c.canPurchase)
        await c.purchase(id)
        XCTAssertEqual(store.purchaseCalls, 1)
        c.bind(accountID: nil, api: nil)
    }

    func testEnvironmentLookupFailureKeepsCheckoutUnavailableAndCanRetry() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        store.failEnvironment = true
        let c = await make(store, api)
        XCTAssertEqual(c.state, .unavailable); XCTAssertNil(c.acceptedEnvironment)
        XCTAssertFalse(c.checkoutOpen); XCTAssertFalse(c.canPurchase)
        await c.purchase(id)
        XCTAssertEqual(store.purchaseCalls, 0); XCTAssertEqual(store.productReads, 0)
        XCTAssertEqual(api.tokenReads, 0)
        store.failEnvironment = false
        await c.load()
        XCTAssertEqual(store.environmentReads, 2); XCTAssertTrue(c.canPurchase)
        c.bind(accountID: nil, api: nil)
    }

    func testUnknownEnvironmentNeverOffersBuyAndIsNotCached() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        store.environment = nil
        let c = await make(store, api)
        XCTAssertEqual(c.state, .unavailable); XCTAssertFalse(c.canPurchase)
        XCTAssertNil(c.acceptedEnvironment); XCTAssertFalse(c.checkoutOpen)
        c.clearSettledOutcomes(); await c.purchase(id)
        XCTAssertEqual(store.purchaseCalls, 0); XCTAssertEqual(api.tokenReads, 0)
        store.environment = .sandbox
        await c.load()
        XCTAssertEqual(store.environmentReads, 2); XCTAssertTrue(c.canPurchase)
        c.bind(accountID: nil, api: nil)
    }

    func testSlowEnvironmentLookupSuspendsWithoutOfferingBuy() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        store.blockEnvironment = true
        let c = ApplePurchaseCoordinator(store: store, environment: .production, refreshWallet: {})
        c.bind(accountID: "synthetic-account-a", api: api)
        await settled { store.environmentBlocked != nil }
        XCTAssertEqual(c.state, .loading); XCTAssertFalse(c.canPurchase)
        await c.purchase(id)
        XCTAssertEqual(store.purchaseCalls, 0); XCTAssertEqual(store.productReads, 0)
        store.environmentBlocked?.resume(returning: .sandbox); store.environmentBlocked = nil
        await settled { c.state == .ready }
        XCTAssertTrue(c.canPurchase)
        c.bind(accountID: nil, api: nil)
    }

    func testAccountSwitchRejectsLateEnvironmentLookup() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        store.blockEnvironment = true
        let c = ApplePurchaseCoordinator(store: store, environment: .production, refreshWallet: {})
        c.bind(accountID: "synthetic-account-a", api: api)
        await settled { store.environmentBlocked != nil }
        c.bind(accountID: nil, api: nil)
        store.environmentBlocked?.resume(returning: .sandbox); store.environmentBlocked = nil
        await Task.yield()
        XCTAssertEqual(c.state, .idle); XCTAssertNil(c.acceptedEnvironment)
        XCTAssertFalse(c.canPurchase); XCTAssertEqual(store.productReads, 0)
        store.blockEnvironment = false
        c.bind(accountID: "synthetic-account-b", api: api)
        await settled { c.state == .ready }
        XCTAssertEqual(store.environmentReads, 2)
        c.bind(accountID: nil, api: nil)
    }

    func testOverlappingLookupCannotDiscardASuccessfullyCachedEnvironment() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        store.blockEnvironment = true
        let c = ApplePurchaseCoordinator(store: store, environment: .production, refreshWallet: {})
        c.bind(accountID: "synthetic-account-a", api: api)
        await settled { store.environmentBlocked != nil }
        let first = store.environmentBlocked; store.environmentBlocked = nil
        let reload = Task { await c.load() }
        await settled { store.environmentBlocked != nil }
        let second = store.environmentBlocked; store.environmentBlocked = nil
        first?.resume(returning: .sandbox)
        await settled { c.state == .ready }
        second?.resume(returning: nil)
        await reload.value
        XCTAssertTrue(c.canPurchase); XCTAssertEqual(c.acceptedEnvironment, .sandbox)
        store.blockEnvironment = false
        await c.load()
        XCTAssertEqual(store.environmentReads, 2); XCTAssertTrue(c.canPurchase)
        c.bind(accountID: nil, api: nil)
    }

    func testMismatchingRefreshRevokesPreviouslyAvailableCheckout() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        let c = await make(store, api)
        XCTAssertTrue(c.canPurchase)
        api.catalogEnvironment = .production
        await c.load()
        c.clearSettledOutcomes(); await c.purchase(id)
        XCTAssertEqual(c.state, .unavailable); XCTAssertNil(c.acceptedEnvironment)
        XCTAssertFalse(c.canPurchase); XCTAssertFalse(c.checkoutOpen)
        XCTAssertEqual(store.purchaseCalls, 0); XCTAssertEqual(api.tokenReads, 0)
        XCTAssertEqual(store.environmentReads, 1)
        c.bind(accountID: nil, api: nil)
    }

    func testCatalogueMismatchWhileTokenLoadsCannotReachStorePurchase() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        let c = await make(store, api)
        api.blockToken = true
        let purchase = Task { await c.purchase(id) }
        await settled { api.tokenBlocked != nil }
        api.catalogEnvironment = .production
        await c.load()
        api.tokenBlocked?.resume(); api.tokenBlocked = nil
        await purchase.value
        XCTAssertEqual(c.state, .unavailable); XCTAssertFalse(c.canPurchase)
        XCTAssertEqual(store.purchaseCalls, 0)
        api.catalogEnvironment = .sandbox
        await c.load()
        XCTAssertTrue(c.canPurchase)
        api.blockToken = false
        await c.purchase(id)
        XCTAssertEqual(api.tokenReads, 2); XCTAssertEqual(store.purchaseCalls, 1)
        c.bind(accountID: nil, api: nil)
    }

    func testPostPurchaseEnvironmentCheckStillRejectsWrongTransaction() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        var finishes = 0
        store.result = .verified(transaction(environment: .production) { finishes += 1 })
        let c = await make(store, api)
        await c.purchase(id)
        XCTAssertEqual(c.state, .unavailable)
        XCTAssertEqual(store.purchaseCalls, 1); XCTAssertEqual(api.posts, 0)
        XCTAssertEqual(finishes, 0)
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

    func testPackRowsSumPaidAndBonusIntoOneTotalWithStoreKitPrice() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        let c = await make(store, api)
        // Owner ruling 1: one total per pack, never the paid/bonus parts.
        XCTAssertEqual(c.packRows, [
            .init(id: "com.atum.mobile.protons.100k", totalMicroProtons: 100_000_000_000,
                  displayPrice: "synthetic-price"),
            .init(id: "com.atum.mobile.protons.500k", totalMicroProtons: 500_000_000_000,
                  displayPrice: "synthetic-price"),
        ])
        c.bind(accountID: nil, api: nil)
        XCTAssertTrue(c.packRows.isEmpty)
    }

    func testPackRowsSkipUnpricedProductsAndSortByTotal() throws {
        func pack(_ id: String, _ paid: Int64, _ bonus: Int64) throws -> AppleProductsResponse.Pack {
            try NativeAPI.decode(AppleProductsResponse.Pack.self, from: JSONSerialization.data(withJSONObject: [
                "productId": id, "packId": "p", "paidMicroProtons": paid, "bonusMicroProtons": bonus]))
        }
        let rows = AppleProtonPackRow.rows(
            packs: [try pack("com.atum.mobile.protons.500k", 400, 100),
                    try pack("com.atum.mobile.protons.100k", 90, 10),
                    try pack("com.atum.mobile.protons.unpriced", 1, 0)],
            products: [.init(id: "com.atum.mobile.protons.100k", displayPrice: "A"),
                       .init(id: "com.atum.mobile.protons.500k", displayPrice: "B")])
        XCTAssertEqual(rows.map(\.id), ["com.atum.mobile.protons.100k", "com.atum.mobile.protons.500k"])
        XCTAssertEqual(rows.map(\.totalMicroProtons), [100, 500])
    }

    func testClearingSettledOutcomesReopensPacksButKeepsInFlightAndSupportStates() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub()
        store.result = .unverified
        let c = await make(store, api)
        await c.purchase(id)
        XCTAssertEqual(c.state, .unavailable); XCTAssertFalse(c.canPurchase)
        c.clearSettledOutcomes()
        XCTAssertEqual(c.state, .ready); XCTAssertTrue(c.canPurchase)
        XCTAssertEqual(c.purchaseState(for: id), .idle)

        store.result = .pending
        await c.purchase(id)
        c.clearSettledOutcomes()
        XCTAssertEqual(c.purchaseState(for: id), .pending); XCTAssertFalse(c.canPurchase)
        c.bind(accountID: nil, api: nil)

        // needs_support keeps its transaction ID for the person to quote.
        let supportStore = PurchaseStoreStub(); let supportAPI = PurchaseAPIStub()
        supportAPI.sample = .transactionNeedsSupport
        supportStore.result = .verified(transaction(id: "2000000123456790") {})
        let s = await make(supportStore, supportAPI)
        await s.purchase(id)
        await settled { s.state == .needsSupport("2000000123456790") }
        s.clearSettledOutcomes()
        XCTAssertEqual(s.purchaseState(for: id), .needsSupport("2000000123456790"))
        s.bind(accountID: nil, api: nil)
    }

    func testClearingSettledOutcomesNeverReopensAClosedCheckout() async {
        let store = PurchaseStoreStub(); let api = PurchaseAPIStub(); api.closed = true
        let c = await make(store, api)
        c.clearSettledOutcomes()
        XCTAssertEqual(c.state, .closed); XCTAssertFalse(c.canPurchase)
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
    var environment: ApplePurchaseEnvironment? = .sandbox
    var environmentReads = 0; var failEnvironment = false; var blockEnvironment = false
    var environmentBlocked: CheckedContinuation<ApplePurchaseEnvironment?, Never>?
    func purchaseEnvironment() async throws -> ApplePurchaseEnvironment? {
        environmentReads += 1
        if failEnvironment { throw ContractViolation.invalidValue }
        if blockEnvironment { return await withCheckedContinuation { environmentBlocked = $0 } }
        return environment
    }
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
    var blockToken = false
    var tokenBlocked: CheckedContinuation<Void, Never>?
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
        if blockToken { await withCheckedContinuation { tokenBlocked = $0 } }
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
