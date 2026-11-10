import AtumDesign
import Foundation
import XCTest
@testable import AtumNativeAPI

final class StoreCommerceContractTests: XCTestCase {
    private var fixtures: URL { Bundle.module.url(forResource: "store-v1.1", withExtension: nil)! }
    func testPinnedWireFixtures() throws {
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures.appendingPathComponent("manifest.json"))) as! [String: Any]
        for fixture in manifest["fixtures"] as! [[String: Any]] {
            let file = fixture["file"] as! String
            let data = try Data(contentsOf: fixtures.appendingPathComponent(file))
            let decode = {
                switch fixture["message"] as! String {
                case "catalog.response": _ = try StoreWire.decode(StoreCatalogResponse.self, from: data)
                case "entitlements.response": _ = try StoreWire.decode(StoreEntitlementsResponse.self, from: data)
                case "purchases.response": _ = try StoreWire.decode(StorePurchasesResponse.self, from: data)
                case "purchase.request": _ = try StoreWire.decode(StorePurchaseIntent.self, from: data)
                case "purchase.result": _ = try StoreWire.decode(StorePurchaseResult.self, from: data)
                case "cancel.result": _ = try StoreWire.decode(StoreEntitlement.self, from: data)
                default: XCTFail(file)
                }
            }
            if fixture["expect"] as? String == "accept" { XCTAssertNoThrow(try decode(), file) }
            else { XCTAssertThrowsError(try decode(), file) }
        }
    }

    func testStoreCopyIsPresentAndNotTopUpInEveryLocale() throws {
        let copy = try AtumCopy()
        let keys = ["desktop.atum.discover.buyFor", "desktop.atum.discover.availableBalance",
                    "desktop.atum.discover.protons", "desktop.atum.discover.checkPurchase",
                    "desktop.atum.discover.insufficientProtons", "desktop.atum.discover.purchaseUncertain",
                    "desktop.atum.discover.owned", "desktop.common.confirm", "desktop.common.cancel",
                    "src.matrix.mobile-device-copy.mobileDeviceCopy.storeDetailTitle",
                    "src.matrix.mobile-device-copy.mobileDeviceCopy.storeReviewTitle",
                    "src.matrix.mobile-device-copy.mobileDeviceCopy.storeReviewBody",
                    "src.matrix.mobile-device-copy.mobileDeviceCopy.storeReviewRows2Label",
                    "src.matrix.mobile-device-copy.mobileDeviceCopy.storePurchasedStatesCancelledRenewalText",
                    "src.matrix.mobile-device-copy.mobileDeviceCopy.storeDeliveryStatesDeliveredText"]
        for locale in copy.locales {
            for key in keys {
                let arguments: [AtumCopy.Argument] = ["buyFor", "availableBalance", "protons"].contains(key.split(separator: ".").last.map(String.init)!) ? [.text("24")] : []
                XCTAssertFalse(try copy.text(key, locale: locale, arguments: arguments).isEmpty)
            }
        }
    }
}

final class StoreFormattingAndVisibilityTests: XCTestCase {
    private func item(_ file: String, change: (inout [String: Any]) -> Void = { _ in }) throws -> StoreCatalogItem {
        let url = Bundle.module.url(forResource: "store-v1.1", withExtension: nil)!
            .appendingPathComponent(file + ".json")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var row = (catalog["items"] as! [[String: Any]])[0]
        change(&row)
        return try StoreWire.decode(StoreCatalogItem.self, from: JSONSerialization.data(withJSONObject: row))
    }

    func testBalancesFloorWithoutLosingPricePrecision() {
        for (micro, expected) in [(Int64(0), "0"), (1, "0"), (999_999, "0"),
                                  (1_000_000, "1"), (1_999_999, "1"),
                                  (12_345_678_912, "12,345"), (-1, "0"),
                                  (NativeAPI.maximumInteger, "9,007,199,254")] {
            XCTAssertEqual(MicroProtonFormat.balance(micro, locale: "en"), expected)
        }
        XCTAssertEqual(MicroProtonFormat.balance(12_345_999_999, locale: "vi"), "12.345")
        XCTAssertEqual(MicroProtonFormat.string(12_345_678_912, locale: "en"), "12,345.678912")
        XCTAssertEqual(MicroProtonFormat.string(1, locale: "en"), "0.000001")
    }

    func testMonthlyPricePartsKeepBothExactAmounts() throws {
        let monthly = try item("catalog-monthly-agent") { row in
            var offer = row["offer"] as! [String: Any]
            offer["priceMicroProtons"] = 19_000_123_456
            offer["renewalPriceMicroProtons"] = 39_000_654_321
            row["offer"] = offer
        }
        XCTAssertEqual(monthly.offer?.priceParts, [.firstMonth(19_000_123_456), .thenMonthly(39_000_654_321)])
        let freeFirst = try item("catalog-monthly-agent") { row in
            var offer = row["offer"] as! [String: Any]
            offer["priceMicroProtons"] = 0
            offer["renewalPriceMicroProtons"] = 39_000_000_000
            row["offer"] = offer
        }
        XCTAssertEqual(freeFirst.offer?.priceParts, [.freeFirstMonth, .thenMonthly(39_000_000_000)])
    }

    func testEqualMonthlyPriceAndOneTimePricesMatchDesktop() throws {
        for value: Int64 in [0, 1, 39_000_000_000] {
            let monthly = try item("catalog-monthly-agent") { row in
                var offer = row["offer"] as! [String: Any]
                offer["priceMicroProtons"] = value
                offer["renewalPriceMicroProtons"] = value
                row["offer"] = offer
            }
            XCTAssertEqual(monthly.offer?.priceParts, value == 0 ? [.free] : [.monthly(value)])
            let oneTime = try item("catalog-pet") { row in
                var offer = row["offer"] as! [String: Any]
                offer["priceMicroProtons"] = value
                row["offer"] = offer
            }
            XCTAssertEqual(oneTime.offer?.priceParts, value == 0 ? [.free] : [.amount(value)])
        }
    }

    func testOfferlessAndUnavailableItemsStayOutWhileHubAndMonthlyStayVisible() throws {
        XCTAssertFalse(try item("catalog-null-offer").isVisibleInStore)
        XCTAssertFalse(try item("v11-catalog-unavailable").isVisibleInStore)
        XCTAssertFalse(try item("catalog-pet") { $0["deliverable"] = false }.isVisibleInStore)
        XCTAssertTrue(try item("v11-catalog-hub-skill").isVisibleInStore)
        XCTAssertTrue(try item("catalog-pet").isVisibleInStore)
        XCTAssertTrue(try item("catalog-monthly-agent").isVisibleInStore)
        XCTAssertTrue(try item("v11-catalog-gift-owned").isVisibleInStore)
    }
}

@MainActor final class StoreAcquisitionTests: XCTestCase {
    final class Journal: StoreAttemptJournal {
        var values = [String: [StorePurchaseAttempt]]()
        var fails = false
        func attempts(account: String) throws -> [StorePurchaseAttempt] {
            if fails { throw ContractViolation.invalidValue }
            return values[account] ?? []
        }
        func save(_ attempt: StorePurchaseAttempt, account: String) throws {
            if fails { throw ContractViolation.invalidValue }
            values[account, default: []].append(attempt)
        }
        func remove(_ attempt: StorePurchaseAttempt, account: String) throws {
            values[account]?.removeAll { $0.idempotencyKey == attempt.idempotencyKey }
        }
    }
    private func fixture(_ file: String) throws -> Data {
        let url = Bundle.module.url(forResource: "store-v1.1", withExtension: nil)!
        return try Data(contentsOf: url.appendingPathComponent(file + ".json"))
    }
    private func quote(balance: Int64 = 100_000_000_000) throws -> StoreAcquireQuote {
        let item = try StoreWire.decode(StoreCatalogResponse.self, from: fixture("catalog-pet")).items[0]
        return try StoreAcquireQuote(item: item, assistantID: nil, balance: balance)
    }
    private func completed(_ attempt: StorePurchaseAttempt, state: String? = nil) throws -> StorePurchaseResult {
        var value = try JSONSerialization.jsonObject(with: fixture("result-completed")) as! [String: Any]
        var purchase = value["purchase"] as! [String: Any]
        if let state { purchase["state"] = state }
        purchase["idempotencyKey"] = attempt.idempotencyKey.rawValue
        purchase["offerId"] = attempt.offerID.rawValue; purchase["offerVersion"] = attempt.offerVersion
        value["purchase"] = purchase
        return try StoreWire.decode(StorePurchaseResult.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testSuccessPersistsBeforeSendAndRefreshRetryUsesSameKey() async throws {
        let journal = Journal(); var calls = [StorePurchaseAttempt]()
        let machine = StoreAcquisition(account: "synthetic-a", journal: journal) { attempt in
            XCTAssertEqual(try journal.attempts(account: "synthetic-a").first, attempt)
            calls.append(attempt)
            return try self.completed(attempt)
        }
        let q = try quote()
        XCTAssertEqual(q.resultingBalance, q.balance - q.price)
        let first = await machine.confirm(q, online: true)
        guard case .result(.purchased) = first else { return XCTFail("expected committed purchase") }
        _ = await machine.confirm(q, online: true)
        XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[0], calls[1])
    }
    func testInsufficientBalanceMakesNoRequest() async throws {
        var calls = 0
        let journal = Journal()
        let machine = StoreAcquisition(account: "synthetic-a", journal: journal) { _ in
            calls += 1; return .refused(.insufficientProtons)
        }
        let state = await machine.confirm(try quote(balance: 0), online: true)
        XCTAssertEqual(state, .insufficientBalance); XCTAssertEqual(calls, 0)
        XCTAssertTrue(try journal.attempts(account: "synthetic-a").isEmpty)
    }
    func testServerInsufficientBalanceIsDefiniteAndRetiresIntent() async throws {
        let journal = Journal()
        let machine = StoreAcquisition(account: "synthetic-a", journal: journal) { _ in .refused(.insufficientProtons) }
        let state = await machine.confirm(try quote(), online: true)
        XCTAssertEqual(state, .result(.refused(.insufficientProtons)))
        XCTAssertTrue(try journal.attempts(account: "synthetic-a").isEmpty)
    }
    func testAmbiguousResponseAndRestartReplayNeverDoubleSpend() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = StoreFileJournal(directory: directory)
        var charged = Set<NativeID>(); var calls = [StorePurchaseAttempt]()
        let first = StoreAcquisition(account: "synthetic-a", journal: journal) { attempt in
            charged.insert(attempt.idempotencyKey); calls.append(attempt)
            throw NativeDomainClientFailure.transportUnavailable // server committed; reply lost
        }
        let state = await first.confirm(try quote(), online: true)
        XCTAssertEqual(state, .uncertain)
        let reopened = StoreAcquisition(account: "synthetic-a", journal: StoreFileJournal(directory: directory)) { attempt in
            charged.insert(attempt.idempotencyKey); calls.append(attempt)
            return try self.completed(attempt)
        }
        let pending = try XCTUnwrap(try reopened.attempt(itemID: calls[0].itemID, assistantID: nil))
        let answer = await reopened.retry(pending, online: true)
        guard case .result(.purchased) = answer else { return XCTFail("expected replay") }
        XCTAssertEqual(charged.count, 1); XCTAssertEqual(calls[0], calls[1])
        XCTAssertTrue(try journal.attempts(account: "synthetic-b").isEmpty)
    }
    func testReversedAttemptIsRetiredSoTheItemCanBeBoughtAgain() async throws {
        let journal = Journal(); var calls = [StorePurchaseAttempt]()
        var reply: (StorePurchaseAttempt) throws -> StorePurchaseResult = { _ in
            throw NativeDomainClientFailure.transportUnavailable // committed; reply lost
        }
        let machine = StoreAcquisition(account: "synthetic-a", journal: journal) { attempt in
            calls.append(attempt); return try reply(attempt)
        }
        let q = try quote()
        let lost = await machine.confirm(q, online: true)
        XCTAssertEqual(lost, .uncertain)
        let saved = try XCTUnwrap(try machine.attempt(itemID: q.item.itemID, assistantID: nil))
        guard case .purchased(let pending, _) = try completed(saved, state: "delivery_pending"),
              case .purchased(let done, _) = try completed(saved),
              case .purchased(let reversed, _) = try completed(saved, state: "reversed") else { return XCTFail("fixture") }

        // Missing, pending and completed history keep the key so Check status
        // can replay it; a completion is never taken as settled just because
        // ownership hasn't shown up yet (that could charge twice).
        try machine.retireReversed(by: [])
        try machine.retireReversed(by: [pending])
        try machine.retireReversed(by: [done])
        XCTAssertNotNil(try machine.attempt(itemID: q.item.itemID, assistantID: nil))

        // History shows it reversed: the attempt is retired, and a new
        // confirmation mints a new key instead of staying blocked.
        try machine.retireReversed(by: [reversed])
        XCTAssertNil(try machine.attempt(itemID: q.item.itemID, assistantID: nil))
        reply = { try self.completed($0) }
        let again = await machine.confirm(q, online: true)
        guard case .result(.purchased) = again else {
            return XCTFail("expected a new purchase")
        }
        XCTAssertEqual(calls.count, 2); XCTAssertNotEqual(calls[0].idempotencyKey, calls[1].idempotencyKey)
    }
    func testOfflineBeforeSendAndJournalFailureDoNotWrite() async throws {
        let journal = Journal(); var calls = 0
        let machine = StoreAcquisition(account: "synthetic-a", journal: journal) { _ in calls += 1; return .refused(.forbidden) }
        let offline = await machine.confirm(try quote(), online: false)
        XCTAssertEqual(offline, .offline); XCTAssertTrue(journal.values.isEmpty)
        journal.fails = true
        let unavailable = await machine.confirm(try quote(), online: true)
        XCTAssertEqual(unavailable, .unavailable); XCTAssertEqual(calls, 0)
    }
    func testForbiddenIsHonestAndUnresolvedIntentRetained() async throws {
        let journal = Journal()
        let failure = try NativeHTTPFailure(status: 403, headers: [:], body: Data("{\"error\":\"matrix_403\"}".utf8))
        let machine = StoreAcquisition(account: "synthetic-a", journal: journal) { _ in throw NativeDomainClientFailure.http(failure) }
        let state = await machine.confirm(try quote(), online: true)
        XCTAssertEqual(state, .forbidden)
        XCTAssertEqual(try journal.attempts(account: "synthetic-a").count, 1)
    }
    func testMismatchRemainsUncertainAndCannotReplaceKey() async throws {
        let journal = Journal()
        let result = try StoreWire.decode(StorePurchaseResult.self, from: fixture("result-completed"))
        let machine = StoreAcquisition(account: "synthetic-a", journal: journal) { _ in result }
        let state = await machine.confirm(try quote(), online: true)
        XCTAssertEqual(state, .uncertain)
        XCTAssertEqual(try journal.attempts(account: "synthetic-a").count, 1)
    }
}

extension StoreAcquisitionTests {
    func testConcurrentConfirmIsSingleFlight() async throws {
        let journal = Journal()
        var continuation: CheckedContinuation<StorePurchaseResult, Never>?
        var calls = 0
        let machine = StoreAcquisition(account: "synthetic-a", journal: journal) { _ in
            calls += 1
            return await withCheckedContinuation { continuation = $0 }
        }
        let q = try quote()
        let first = Task { await machine.confirm(q, online: true) }
        while continuation == nil { await Task.yield() }
        let duplicate = await machine.confirm(q, online: true)
        XCTAssertEqual(duplicate, .working); XCTAssertEqual(calls, 1)
        continuation?.resume(returning: .refused(.featureUnavailable))
        _ = await first.value
    }

    func testOfferChangedRequiresANewConfirmationAndNewKey() async throws {
        let journal = Journal(); let q = try quote()
        let changed = try StoreWire.decode(StorePurchaseResult.self, from: fixture("result-offer-changed"))
        var ids = [NativeID]()
        let machine = StoreAcquisition(account: "synthetic-a", journal: journal) { attempt in
            ids.append(attempt.idempotencyKey)
            return changed
        }
        let result = await machine.confirm(q, online: true)
        XCTAssertEqual(result, .result(changed))
        XCTAssertTrue(try journal.attempts(account: "synthetic-a").isEmpty)
        _ = await machine.confirm(q, online: true)
        XCTAssertEqual(ids.count, 2); XCTAssertNotEqual(ids[0], ids[1])
    }

    func testPolicyRejectsAssistantHiresAndWrongRecipientScopes() throws {
        let hire = try StoreWire.decode(StoreCatalogResponse.self, from: fixture("catalog-monthly-agent")).items[0]
        XCTAssertThrowsError(try StoreAcquireQuote(item: hire, assistantID: nil, balance: NativeAPI.maximumInteger))
        let pet = try quote().item
        XCTAssertThrowsError(try StoreAcquireQuote(item: pet,
            assistantID: NativeID("10000000-0000-4000-8000-000000000005"), balance: NativeAPI.maximumInteger))
    }

    func testCorruptDurableJournalFailsClosed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = StoreFileJournal(directory: folder)
        let q = try quote()
        let attempt = try StorePurchaseAttempt(item: q.item, assistantID: nil,
            idempotencyKey: NativeID("10000000-0000-4000-8000-000000000005"))
        try journal.save(attempt, account: "synthetic-a")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        try Data("corrupt synthetic intent".utf8).write(to: file)
        var calls = 0
        let machine = StoreAcquisition(account: "synthetic-a", journal: journal) { _ in calls += 1; return .refused(.forbidden) }
        let state = await machine.confirm(q, online: true)
        XCTAssertEqual(state, .unavailable); XCTAssertEqual(calls, 0)
    }
}
