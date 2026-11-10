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

    func testStoreTimestampsParseWithMicroseconds() throws {
        let data = Data(#"["2026-10-04T08:00:00.123456+00:00"]"#.utf8)
        let value = try JSONDecoder().decode([NativeTimestamp].self, from: data)[0]
        XCTAssertNotNil(StoreOutcomePresentation.date(value))
    }
}
