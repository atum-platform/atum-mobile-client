@testable import AtumMobile
import AtumDesign
import AtumNativeAPI
import Foundation
import XCTest

final class StoreCommercePresentationTests: XCTestCase {
    /// Every word the Store UI shows is an existing export, in all five locales,
    /// and none of it offers a Proton purchase or top-up (Guideline 3.1.1).
    func testEveryStoreKeyExistsInEveryLocaleWithoutTopUp() throws {
        let copy = try AtumCopy()
        XCTAssertEqual(copy.locales.count, 5)
        XCTAssertFalse(StoreCopyKey.all.contains("desktop.atum.discover.topUp"))
        XCTAssertFalse(StoreCopyKey.all.contains { $0.hasPrefix("src.matrix.mobile-copy.mobilePhoneCopy.purchase") })
        for locale in copy.locales {
            for key in StoreCopyKey.all {
                let arguments: [AtumCopy.Argument] = [StoreCopyKey.buyFor, StoreCopyKey.protons,
                                                      StoreCopyKey.tryExample].contains(key) ? [.text("24")] : []
                XCTAssertFalse(try copy.text(key, locale: locale, arguments: arguments).isEmpty, "\(locale) \(key)")
            }
        }
    }

    func testMonthlyPriceFormattingUsesDesktopKeysAndBothPreciseAmounts() throws {
        let json = #"{"id":"11111111-1111-4111-8111-111111111111","version":1,"priceMicroProtons":19000123456,"renewalPriceMicroProtons":39000654321,"scope":"account","billingInterval":"month","delivery":"cloud"}"#
        let offer = try StoreWire.decode(StoreCatalogOffer.self, from: Data(json.utf8))
        var keys = [String]()
        let parts = StorePricePresentation.parts(offer, locale: "en") { key, arguments in
            keys.append(key)
            if key == StorePricePresentation.CopyKey.monthlyFirst { return "\(arguments[0]) Protons first month" }
            if key == StorePricePresentation.CopyKey.monthlyThen { return "then \(arguments[0])/mo" }
            XCTFail("Unexpected key: \(key)")
            return key
        }
        XCTAssertEqual(keys, [StorePricePresentation.CopyKey.monthlyFirst, StorePricePresentation.CopyKey.monthlyThen])
        XCTAssertEqual(parts.joined(separator: " · "), "19,000.123456 Protons first month · then 39,000.654321/mo")
    }

    @MainActor func testMonthlyPresentationRetainsBothAmountsWithPinnedExport() throws {
        let json = #"{"id":"11111111-1111-4111-8111-111111111111","version":1,"priceMicroProtons":19000123456,"renewalPriceMicroProtons":39000654321,"scope":"account","billingInterval":"month","delivery":"cloud"}"#
        let offer = try StoreWire.decode(StoreCatalogOffer.self, from: Data(json.utf8))
        let design = try LiveDesign()
        let text = StorePricePresentation.text(offer, design: design)
        XCTAssertTrue(text.contains(MicroProtonFormat.string(offer.priceMicroProtons, locale: design.locale)))
        XCTAssertTrue(text.contains(MicroProtonFormat.string(offer.renewalPriceMicroProtons!, locale: design.locale)))
    }

    func testUnansweredWritesNeverClaimNothingWasCharged() {
        let uncharged = [StoreCopyKey.failed, StoreCopyKey.purchaseUnavailable]
        for state in [StoreAcquireState.uncertain, .forbidden, .offline] {
            let notice = StoreOutcomePresentation.notice(for: state, kind: .pet)
            XCTAssertFalse(uncharged.contains(notice?.key ?? ""), "\(state)")
        }
        XCTAssertEqual(StoreOutcomePresentation.outcome(for: .uncertain, hasSavedAttempt: true), .recover)
        XCTAssertEqual(StoreOutcomePresentation.outcome(for: .forbidden, hasSavedAttempt: true), .recover)
        XCTAssertEqual(StoreOutcomePresentation.outcome(for: .offline, hasSavedAttempt: true), .recover)
        XCTAssertEqual(StoreOutcomePresentation.outcome(for: .offline, hasSavedAttempt: false), .stopped)
    }

    func testDefiniteRefusalsAndInsufficientBalanceStopWithoutTopUp() {
        XCTAssertEqual(StoreOutcomePresentation.notice(for: .insufficientBalance, kind: .pet)?.key,
                       StoreCopyKey.insufficient)
        XCTAssertEqual(StoreOutcomePresentation.notice(for: .result(.refused(.insufficientProtons)), kind: .pet)?.key,
                       StoreCopyKey.insufficient)
        XCTAssertEqual(StoreOutcomePresentation.notice(for: .result(.refused(.forbidden)), kind: .pet)?.key,
                       StoreCopyKey.failed)
        XCTAssertEqual(StoreOutcomePresentation.notice(for: .result(.refused(.offerUnavailable)), kind: .pet)?.key,
                       StoreCopyKey.purchaseUnavailable)
        XCTAssertEqual(StoreOutcomePresentation.outcome(for: .result(.refused(.insufficientProtons)),
                                                        hasSavedAttempt: false), .stopped)
        XCTAssertEqual(StoreOutcomePresentation.notice(for: .insufficientBalance, kind: .skill,
                                                       hasEligibleAssistant: true).key, StoreCopyKey.insufficient)
        XCTAssertEqual(StoreOutcomePresentation.notice(for: .noEligibleAssistant, kind: .skill,
                                                       hasEligibleAssistant: false).key, StoreCopyKey.recipientNone)
    }

    func testPurchaseStatesSpeakOfDelivery() {
        XCTAssertEqual(StoreOutcomePresentation.purchaseKey(.deliveryPending), StoreCopyKey.deliveryPending)
        XCTAssertEqual(StoreOutcomePresentation.purchaseKey(.deliveryPending, detail: true), StoreCopyKey.detailPending)
        XCTAssertEqual(StoreOutcomePresentation.purchaseKey(.completed), StoreCopyKey.deliveryDelivered)
        XCTAssertEqual(StoreOutcomePresentation.purchaseKey(.reversed), StoreCopyKey.deliveryRefunded)
    }

    /// REL-15: Protons are spent on a paid item only while Apple checkout is
    /// open; free items never wait on it.
    func testStoreGateHidesPaidSpendWhileCheckoutIsClosed() throws {
        XCTAssertFalse(StorePurchaseGate.allowsSpend(priceMicroProtons: 90_000_000, checkoutOpen: false))
        XCTAssertFalse(StorePurchaseGate.allowsSpend(priceMicroProtons: 1, checkoutOpen: false))
        XCTAssertTrue(StorePurchaseGate.allowsSpend(priceMicroProtons: 90_000_000, checkoutOpen: true))
        XCTAssertTrue(StorePurchaseGate.allowsSpend(priceMicroProtons: 0, checkoutOpen: false))
        XCTAssertTrue(StorePurchaseGate.allowsSpend(priceMicroProtons: 0, checkoutOpen: true))
        // The closed line is the pack sheet's existing export, plain in English.
        XCTAssertEqual(try AtumCopy().text(StoreCopyKey.purchasesClosed, locale: "en", arguments: []),
                       "Purchases are not available yet")
    }

    func testStoreTimestampsParseWithMicroseconds() throws {
        let data = Data(#"["2026-10-04T08:00:00.123456+00:00"]"#.utf8)
        let value = try JSONDecoder().decode([NativeTimestamp].self, from: data)[0]
        XCTAssertNotNil(StoreOutcomePresentation.date(value))
    }

    // MARK: Proton top-up (ST-4 / ST-5)

    /// The pack sheet's words exist in all five locales, and none of them is a
    /// paid/bonus split, a saving or a rate (owner ruling 1).
    func testEveryTopUpAndShelfKeyExistsInEveryLocaleWithoutEconomicMath() throws {
        let copy = try AtumCopy()
        let twoArguments = [ProtonTopUpCopyKey.packLabel]
        let oneArgument = [ProtonTopUpCopyKey.protons, StoreShelfCopyKey.getWithPrice]
        for locale in copy.locales {
            for key in ProtonTopUpCopyKey.all + StoreShelfCopyKey.all {
                let arguments: [AtumCopy.Argument] = twoArguments.contains(key) ? [.text("100,000"), .text("95,000 ₫")]
                    : oneArgument.contains(key) ? [.text("24")] : []
                let value = try copy.text(key, locale: locale, arguments: arguments)
                XCTAssertFalse(value.isEmpty, "\(locale) \(key)")
                if locale == "en" {
                    for banned in ["bonus", "paid", "save", "rate", "vnd", "per proton"] {
                        XCTAssertFalse(value.lowercased().contains(banned), "\(key): \(value)")
                    }
                }
            }
        }
    }

    func testPackSheetBodyFollowsRowsThenCatalogueState() {
        XCTAssertEqual(ProtonTopUpPresentation.body(state: .ready, hasRows: true), .packs)
        XCTAssertEqual(ProtonTopUpPresentation.body(state: .sandboxCapExceeded, hasRows: true), .packs)
        XCTAssertEqual(ProtonTopUpPresentation.body(state: .idle, hasRows: false), .loading)
        XCTAssertEqual(ProtonTopUpPresentation.body(state: .loading, hasRows: false), .loading)
        XCTAssertEqual(ProtonTopUpPresentation.body(state: .closed, hasRows: false), .closed)
        XCTAssertEqual(ProtonTopUpPresentation.body(state: .sandboxCapExceeded, hasRows: false), .closed)
        XCTAssertEqual(ProtonTopUpPresentation.body(state: .unavailable, hasRows: false), .unavailable)
        XCTAssertTrue(ProtonTopUpPresentation.showsClosedBanner(checkoutOpen: false, hasRows: true))
        XCTAssertFalse(ProtonTopUpPresentation.showsClosedBanner(checkoutOpen: true, hasRows: true))
    }

    func testEveryPackStateHasItsExportedNotice() {
        typealias Key = ProtonTopUpCopyKey
        let expected: [(ApplePurchaseCoordinator.State, String?)] = [
            (.idle, nil), (.loading, nil), (.ready, nil), (.purchasing, nil),
            (.pending, Key.pending), (.cancelled, Key.cancelled), (.retrying, Key.creditPending),
            (.succeeded, Key.complete), (.needsSupport("2000000123456790"), Key.creditPending),
            (.otherAccount, Key.otherAccount), (.revoked, Key.refunded), (.unavailable, Key.failed),
            (.closed, Key.closedTitle), (.sandboxCapExceeded, Key.closedTitle),
        ]
        for (state, key) in expected {
            XCTAssertEqual(ProtonTopUpPresentation.notice(for: state)?.key, key, "\(state)")
        }
        // A failed or unanswered purchase never says nothing was charged.
        XCTAssertNotEqual(ProtonTopUpPresentation.notice(for: .unavailable)?.key, StoreCopyKey.failed)
        XCTAssertTrue(ProtonTopUpPresentation.finished(["a": .cancelled, "b": .succeeded]))
        XCTAssertFalse(ProtonTopUpPresentation.finished(["a": .pending, "b": .retrying]))
        XCTAssertTrue(ProtonTopUpPresentation.isOut(999_999))
        XCTAssertFalse(ProtonTopUpPresentation.isOut(1_000_000))
    }

    // MARK: Shelves (ST-6)

    private func item(_ id: String, _ kind: LiveProductStoreItemKind, featured: Bool = false,
                      title: String = "", summary: String = "", offer: StoreCatalogOffer? = nil,
                      ownership: StoreOwnership? = nil) -> LiveProductStoreItem {
        LiveProductStoreItem(id: id, kind: kind, title: title.isEmpty ? id : title, summary: summary,
                             glyph: "✦", featured: featured, price: offer.map { String($0.priceMicroProtons) },
                             offer: offer, ownership: ownership)
    }

    private func offer(_ price: Int64, id: String = "11111111-1111-4111-8111-111111111111") throws -> StoreCatalogOffer {
        try StoreWire.decode(StoreCatalogOffer.self, from: Data(#"{"id":"\#(id)","version":1,"priceMicroProtons":\#(price),"scope":"account","billingInterval":"one_time","delivery":"bundled"}"#.utf8))
    }

    func testShelvesFollowDesktopOrderAndFeaturedItemsStayInTheirKind() {
        let plan = StoreShelfPlan(items: [item("skill/a", .skill, featured: true), item("agent/b", .agent),
                                          item("pet/c", .pet), item("skill/d", .skill)],
                                  apps: [], query: "")
        XCTAssertEqual(plan.featured.map(\.id), ["skill/a"])
        XCTAssertEqual(plan.skills.map(\.id), ["skill/a", "skill/d"])
        XCTAssertEqual(plan.assistants.map(\.id), ["agent/b"])
        XCTAssertEqual(plan.pets.map(\.id), ["pet/c"])
        XCTAssertFalse(plan.searching)
    }

    func testSearchMatchesKindTitleAndSummaryIgnoringAccents() {
        let items = [item("skill/a", .skill, title: "Đặt lịch", summary: "Lên lịch họp"),
                     item("pet/b", .pet, title: "Gigi", summary: "Một người bạn")]
        let apps = [LiveProductStoreApp(id: "moon", title: "Moon", subtitle: "Trò chuyện",
                                        avatarCandidates: [], accent: nil, isAvailable: true,
                                        isVerified: true, verification: .official, roomID: nil)]
        XCTAssertEqual(StoreShelfPlan(items: items, apps: apps, query: "dat lich").skills.map(\.id), ["skill/a"])
        XCTAssertEqual(StoreShelfPlan(items: items, apps: apps, query: "PET").pets.map(\.id), ["pet/b"])
        let app = StoreShelfPlan(items: items, apps: apps, query: "tro chuyen")
        XCTAssertEqual(app.apps.map(\.id), ["moon"]); XCTAssertTrue(app.skills.isEmpty)
        let none = StoreShelfPlan(items: items, apps: apps, query: "zzz")
        XCTAssertTrue(none.searching); XCTAssertTrue(none.isEmpty)
    }

    func testHatchRowsFoldIntoOneCardAtTheFirstHatchPrice() throws {
        let regular = item("pet/hatch", .pet, title: "Hatch", summary: "Make a pet",
                           offer: try offer(30_000_000, id: "22222222-2222-4222-8222-222222222222"))
        let first = item("pet/hatch-first", .pet, featured: true, title: "First",
                         offer: try offer(10_000_000))
        let listings = StoreShelfPlan.listings([item("pet/gigi", .pet), regular, item("skill/x", .skill), first])
        XCTAssertEqual(listings.map(\.id), ["pet/gigi", "pet/hatch-first", "skill/x"])
        let card = try XCTUnwrap(listings.first { $0.id == "pet/hatch-first" })
        // The card quotes the first-hatch offer and wears the regular words.
        XCTAssertEqual(card.item.offer?.priceMicroProtons, 10_000_000)
        XCTAssertEqual(card.item.title, "Hatch"); XCTAssertEqual(card.item.summary, "Make a pet")
        XCTAssertTrue(card.item.featured)
        XCTAssertEqual(card.regularOffer?.priceMicroProtons, 30_000_000)
    }

    func testHatchRowsStayApartWithoutAFirstHatchOfferAndNoStrikeWhenNotCheaper() throws {
        let regular = item("pet/hatch", .pet, offer: try offer(30_000_000))
        XCTAssertEqual(StoreShelfPlan.listings([regular]).map(\.id), ["pet/hatch"])
        let unpriced = item("pet/hatch-first", .pet)
        XCTAssertEqual(StoreShelfPlan.listings([regular, unpriced]).map(\.id), ["pet/hatch", "pet/hatch-first"])
        let same = item("pet/hatch-first", .pet, offer: try offer(30_000_000))
        let folded = StoreShelfPlan.listings([regular, same])
        XCTAssertEqual(folded.map(\.id), ["pet/hatch-first"]); XCTAssertNil(folded[0].regularOffer)
    }

    func testRequirementsShowOnlyExportedTokensOnce() {
        XCTAssertEqual(StoreRequirementPresentation.keys(for: ["Atum", "internet", "runs-scripts", "internet"]),
                       ["desktop.atum.discover.needsInternet", "desktop.atum.discover.needsScripts"])
        XCTAssertTrue(StoreRequirementPresentation.keys(for: ["Atum"]).isEmpty)
    }
}
