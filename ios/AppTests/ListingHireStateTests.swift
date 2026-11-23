import AtumChat
@testable import AtumMobile
import AtumNativeAPI
import XCTest

/// W4-E1: hiring the Researcher from the New assistant sheet (desktop PR #100,
/// `listing-hire.tsx` `useListingHire`). The flow's phases, its moves and the
/// request ledger that keeps one hire one hire.
@MainActor final class ListingHireStateTests: XCTestCase {
    private func listing(paid: Bool = false) throws -> OpenAgentListing {
        try OpenAgentListing(listingID: "open/agents/researcher", displayName: "Researcher",
                             title: ["en": "Researcher", "vi": "Nhà nghiên cứu"],
                             summary: ["en": "Finds sources."], glyph: "🔎",
                             seatPriceProtons: 60_000, hireRequired: paid)
    }

    /// A scripted run: answers in order, records what it was asked.
    @MainActor private final class Runs {
        var answers: [ListingHireResult]
        var calls: [(name: String, confirmed: Bool)] = []
        init(_ answers: [ListingHireResult]) { self.answers = answers }
        func run(_ listing: OpenAgentListing, _ name: String, _ confirmed: Bool) async -> ListingHireResult {
            calls.append((name, confirmed))
            return answers.isEmpty ? .hired : answers.removeFirst()
        }
    }

    private func settle(_ flow: ListingHireFlow, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<50 where flow.isHiring { await Task.yield() }
        XCTAssertFalse(flow.isHiring, "the hire never answered", file: file, line: line)
    }

    func testAFreeSeatHiresInOnePressWithNoPrice() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.hired])
        flow.pick(try listing(), name: "Researcher", run: runs.run)
        XCTAssertEqual(flow.hire?.phase, .hiring)
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .done)
        XCTAssertEqual(runs.calls.count, 1)
        XCTAssertEqual(runs.calls.first?.confirmed, false)
        flow.reset()
        XCTAssertNil(flow.hire)
    }

    func testAThirdAssistantShowsThePriceOnceThenHiresConfirmed() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.hired])
        flow.pick(try listing(paid: true), name: "Researcher", run: runs.run)
        XCTAssertEqual(flow.hire?.phase, .confirm(priceProtons: 60_000))
        XCTAssertTrue(runs.calls.isEmpty, "nothing is hired before the price is confirmed")
        flow.confirm()
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .done)
        XCTAssertEqual(runs.calls.map(\.confirmed), [true])
    }

    func testAStaleQuoteLeadsToTheConfirmStepWithThePlatformsPrice() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.refused(.hireRequired(priceProtons: 61_000)), .hired])
        flow.pick(try listing(), name: "Researcher", run: runs.run)
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .confirm(priceProtons: 61_000))
        flow.confirm()
        await settle(flow)
        XCTAssertEqual(runs.calls.map(\.confirmed), [false, true])
        XCTAssertEqual(flow.hire?.phase, .done)
    }

    func testRetryReusesTheConfirmationAndFinalRefusalsOfferNoRetry() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.refused(.retry), .hired])
        flow.pick(try listing(paid: true), name: "Researcher", run: runs.run)
        flow.confirm()
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .failed(nil))
        flow.retry()
        await settle(flow)
        XCTAssertEqual(runs.calls.map(\.confirmed), [true, true])
        XCTAssertEqual(flow.hire?.phase, .done)

        for (refusal, phase) in [(OpenAgentHireRefusal.name, ListingHirePhase.failed(.name)),
                                 (.limit, .failed(.limit)), (.account, .failed(.account))] {
            let other = ListingHireFlow()
            let refused = Runs([.refused(refusal)])
            other.pick(try listing(), name: "Researcher", run: refused.run)
            await settle(other)
            XCTAssertEqual(other.hire?.phase, phase)
            other.retry()
            XCTAssertEqual(refused.calls.count, 1, "a final refusal is never retried")
        }
    }

    func testAShortWalletOffersTopUpThenTheSamePrice() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.refused(.short)])
        flow.pick(try listing(paid: true), name: "Researcher", run: runs.run)
        flow.confirm()
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .short(priceProtons: 60_000))
        flow.toppedUp()
        XCTAssertEqual(flow.hire?.phase, .confirm(priceProtons: 60_000))
    }

    func testAHireUnderWayOutlivesTheSheetAndIgnoresBackAndOtherPicks() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.hired])
        flow.pick(try listing(), name: "Researcher", run: runs.run)
        flow.sheetClosed()
        flow.reset()
        flow.pick(try listing(paid: true), name: "Researcher 2", run: runs.run)
        XCTAssertEqual(flow.hire?.name, "Researcher")
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .done)
        // Closing on any other state lets it go.
        flow.sheetClosed()
        XCTAssertNil(flow.hire)
    }

    func testTheHiredNameIsTheLocalTitleNumberedPastTakenNames() throws {
        let researcher = try listing()
        XCTAssertEqual(ListingAssistantName.name(for: researcher, locale: "vi", others: ["Atum"]), "Nhà nghiên cứu")
        XCTAssertEqual(ListingAssistantName.name(for: researcher, locale: "en", others: ["Atum", "researcher"]),
                       "Researcher 2")
        XCTAssertEqual(ListingAssistantName.name(for: researcher, locale: "ja", others: []), "Researcher")
    }

    func testAPricedSeatFollowsTheStoreSpendGate() {
        XCTAssertTrue(ListingHireGate.allowsHire(priceProtons: 0, checkoutOpen: false))
        XCTAssertFalse(ListingHireGate.allowsHire(priceProtons: 60_000, checkoutOpen: false))
        XCTAssertTrue(ListingHireGate.allowsHire(priceProtons: 60_000, checkoutOpen: true))
    }

    func testTheRequestLedgerKeepsOneRequestPerListingUntilItsOwnAnswerClearsIt() throws {
        let suite = "ListingHireStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LiveListingHireStore(matrixUserID: "@owner:atum.test", defaults: defaults)
        let id = "open/agents/researcher"
        XCTAssertNil(store.pending(id))
        store.save(.init(requestID: "00000000-0000-4000-8000-000000000001", name: "Researcher",
                         hireConfirmed: false), for: id)
        var pending = try XCTUnwrap(store.pending(id))
        pending.hireConfirmed = true
        store.save(pending, for: id)
        // Another account never sees it.
        XCTAssertNil(LiveListingHireStore(matrixUserID: "@other:atum.test", defaults: defaults).pending(id))
        // Only the request it observed is cleared.
        store.clear(id, requestID: "00000000-0000-4000-8000-000000000002")
        XCTAssertEqual(store.pending(id)?.hireConfirmed, true)
        store.clear(id, requestID: pending.requestID)
        XCTAssertNil(store.pending(id))
    }

    func testEveryHireWordIsInThePinnedExportInBothLanguages() throws {
        let copy = try LiveDesign().copy
        for locale in ["en", "vi"] {
            for key in [ListingHireCopy.readyToHire, ListingHireCopy.hire, ListingHireCopy.short,
                        ListingHireCopy.nameRefused, ListingHireCopy.limitRefused, ListingHireCopy.accountRefused,
                        ListingHireCopy.back, ListingHireCopy.retry, ListingHireCopy.done,
                        ListingHireCopy.purchasesClosed, ListingHireCopy.newAssistant,
                        "src.matrix.roster-create-copy.copies.createAssistant"] {
                XCTAssertFalse(try copy.text(key, locale: locale, arguments: []).isEmpty, key)
            }
            for key in [ListingHireCopy.price, ListingHireCopy.hiring, ListingHireCopy.hired, ListingHireCopy.failed] {
                XCTAssertTrue(try copy.text(key, locale: locale, arguments: [.text("X")]).contains("X"), key)
            }
        }
        XCTAssertEqual(try copy.text(ListingHireCopy.price, locale: "en",
                                     arguments: [.text(ProtonAmountFormat.price(60_000_000_000, locale: "en"))]),
                       "60,000 Protons/month")
        XCTAssertEqual(try copy.text(ListingHireCopy.price, locale: "vi",
                                     arguments: [.text(ProtonAmountFormat.price(60_000_000_000, locale: "vi"))]),
                       "60.000 Proton/tháng")
    }
}
