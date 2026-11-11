@testable import AtumMobile
import AtumDesign
import AtumNativeAPI
import Foundation
import XCTest

/// Wave 3: every Proton amount on the Store and in Settings comes from one
/// formatter, in the app's display language, so the balance chip and the row
/// prices never disagree on digit grouping (the chip once read "105.449"
/// beside rows reading "8,000").
final class ProtonAmountFormatTests: XCTestCase {
    /// Desktop `Intl.NumberFormat(locale, { maximumFractionDigits: 0 })` of
    /// `wholeProtons(105_449_999_999)` in each exported language.
    func testBalanceMatchesDesktopWholeProtonsInEveryExportLocale() {
        let micro: Int64 = 105_449_999_999
        XCTAssertEqual(ProtonAmountFormat.balance(micro, locale: "en"), "105,449")
        XCTAssertEqual(ProtonAmountFormat.balance(micro, locale: "vi"), "105.449")
        XCTAssertEqual(ProtonAmountFormat.balance(micro, locale: "ja"), "105,449")
        XCTAssertEqual(ProtonAmountFormat.balance(micro, locale: "zh"), "105,449")
        XCTAssertEqual(ProtonAmountFormat.balance(micro, locale: "zh-Hant"), "105,449")
        // Floored, never negative.
        XCTAssertEqual(ProtonAmountFormat.balance(999_999, locale: "en"), "0")
        XCTAssertEqual(ProtonAmountFormat.balance(-5_000_000, locale: "en"), "0")
    }

    /// Desktop `microProtons`: prices keep every micro-Proton digit.
    func testPriceKeepsMicroPrecisionInTheSameGrouping() {
        XCTAssertEqual(ProtonAmountFormat.price(8_000_000_000, locale: "en"), "8,000")
        XCTAssertEqual(ProtonAmountFormat.price(8_000_000_000, locale: "vi"), "8.000")
        XCTAssertEqual(ProtonAmountFormat.price(19_000_123_456, locale: "en"), "19,000.123456")
        XCTAssertEqual(ProtonAmountFormat.price(19_000_123_456, locale: "vi"), "19.000,123456")
    }

    /// The chip (a balance) and a row (a price) on one screen share one
    /// grouping separator, whatever the device region is.
    func testChipAndRowShareOneGroupingInEveryLocale() throws {
        let copy = try AtumCopy()
        for locale in copy.locales {
            let chip = ProtonAmountFormat.balance(105_449_000_000, locale: locale)
            let row = ProtonAmountFormat.price(8_000_000_000, locale: locale)
            XCTAssertEqual(chip.filter { !$0.isNumber }, row.filter { !$0.isNumber }, locale)
        }
    }

    /// The Store read carries micro-Protons; the Store chip and Settings both
    /// draw it through the shared formatter.
    func testStoreReadWalletTextUsesTheSharedFormatter() {
        let read = LiveProductStoreRead(availability: .ready, walletMicroProtons: 12_400_750_000)
        XCTAssertEqual(read.walletText(locale: "vi"), "12.400")
        XCTAssertEqual(read.walletText(locale: "en"), "12,400")
        XCTAssertNil(LiveProductStoreRead(availability: .loading).walletText(locale: "en"))
    }

    /// The monthly price line formats both amounts with the same formatter.
    func testMonthlyPricePartsUseTheSharedFormatter() throws {
        let json = #"{"id":"11111111-1111-4111-8111-111111111111","version":1,"priceMicroProtons":19000000000,"renewalPriceMicroProtons":39000000000,"scope":"account","billingInterval":"month","delivery":"cloud"}"#
        let offer = try StoreWire.decode(StoreCatalogOffer.self, from: Data(json.utf8))
        let parts = StorePricePresentation.parts(offer, locale: "vi") { _, arguments in arguments.joined() }
        XCTAssertEqual(parts, [ProtonAmountFormat.price(19_000_000_000, locale: "vi"),
                               ProtonAmountFormat.price(39_000_000_000, locale: "vi")])
        XCTAssertEqual(StoreOutcomePresentation.protons(19_000_000_000, locale: "vi"), "19.000")
    }
}
