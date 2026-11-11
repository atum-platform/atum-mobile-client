import AtumDesign
import AtumNativeAPI
import XCTest
@testable import AtumMobile

/// The model picker's words. `LiveDesign.text` stops the app on a key the pin
/// does not carry, so the picker asks the pin first and falls back to the table
/// of keys the desktop lane `desktop-model-picker-t3-layout` has added and the
/// pin does not carry yet. These tests hold the two together.
final class PhoneModelPickerCopyTests: XCTestCase {
    /// The arguments the view passes with each key.
    private func arguments(for key: PhonePickerCopyKey) -> [AtumCopy.Argument] {
        switch key {
        case .planAccount, .filterWith: [.text("X")]
        default: []
        }
    }

    func testEveryKeyThePickerAsksForIsInThePinOrThePendingTable() throws {
        let pin = try AtumCopy()
        let pending = Set(PhoneModelPickerPendingCopy.keys)
        for key in PhonePickerCopyKey.allCases {
            XCTAssertTrue(pin.contains(key.rawValue) || pending.contains(key),
                          "\(key) is in neither the pin nor the pending table")
        }
        for key in PhoneModelPickerStateCopyKey.allCases {
            XCTAssertTrue(pin.contains(key.rawValue), "\(key) must come from the pin")
        }
    }

    /// Cloud-only: a cloud assistant's last line comes from the pin in every
    /// locale and no longer says the cloud can use Atum's models only.
    func testTheCloudAssistantLineNamesTheAssistantWithoutAnAtumOnlyLimit() throws {
        let pin = try AtumCopy()
        let key = PhoneModelPickerList.contextKey(.cloudAssistant)
        let conversation = PhoneModelPickerList.contextKey(.conversation)
        XCTAssertTrue(pin.contains(key.rawValue))
        for locale in pin.locales {
            let line = try pin.text(key.rawValue, locale: locale)
            XCTAssertFalse(line.isEmpty, locale)
            XCTAssertNotEqual(line, try pin.text(conversation.rawValue, locale: locale), locale)
        }
        XCTAssertFalse(try pin.text(key.rawValue, locale: "en").contains("only"))
    }

    func testPendingCopyIsWrittenInEveryLocaleThePinSupports() throws {
        let locales = try AtumCopy().locales
        XCTAssertEqual(Set(PhoneModelPickerPendingCopy.locales), locales)
        for locale in locales {
            for key in PhoneModelPickerPendingCopy.keys {
                let value = PhoneModelPickerPendingCopy.text(key, arguments: arguments(for: key), locale: locale)
                XCTAssertFalse(value.isEmpty, "\(locale) \(key)")
                XCTAssertNotEqual(value, key.rawValue, "\(locale) \(key) fell through to its key")
                XCTAssertFalse(value.contains("%1$@"), "\(locale) \(key) kept its placeholder")
            }
        }
    }

    func testTheFilterButtonNamesWhatItIsFilteringBy() {
        XCTAssertEqual(PhoneModelPickerPendingCopy.text(.filterWith, arguments: [.text("Yêu thích, Atum")],
                                                        locale: "vi"),
                       "Lọc: Yêu thích, Atum")
        XCTAssertEqual(PhoneModelPickerPendingCopy.text(.filterWith, arguments: [.text("Atum")], locale: "en"),
                       "Filter: Atum")
        XCTAssertEqual(PhoneModelPickerPendingCopy.text(.filter, locale: "vi"), "Lọc")
    }

    func testTheLineUpTaglinesAreTheDesktopWords() {
        XCTAssertEqual(PhoneModelPickerPendingCopy.text(.taglineEveryday, locale: "vi"),
                       "Phù hợp tác vụ hàng ngày")
        XCTAssertEqual(PhoneModelPickerPendingCopy.text(.taglineHard, locale: "vi"),
                       "Phù hợp với tác vụ khó khăn")
        XCTAssertEqual(PhoneModelPickerPendingCopy.text(.taglineFlagship, locale: "vi"),
                       "Mô hình quyền năng nhất")
        XCTAssertEqual(PhoneModelPickerPendingCopy.text(.subscriptions, locale: "vi"),
                       "Gói đăng ký")
        XCTAssertEqual(PhoneModelPickerPendingCopy.text(.taglineEveryday, locale: "en"),
                       "Good for everyday tasks")
        // No model row ever carries the old relative-cost line.
        for key in PhonePickerCopyKey.allCases {
            XCTAssertFalse(PhoneModelPickerPendingCopy.text(key, locale: "vi").contains("20×"))
        }
    }

    func testALocaleWithoutATableReadsEnglishNeverTheKey() {
        XCTAssertEqual(PhoneModelPickerPendingCopy.text(.defaultsAndFavorites, locale: "fr"),
                       "Defaults & favorites")
    }

    func testAPendingKeyThePinLaterCarriesSaysTheSameThing() throws {
        // True of nothing until the next `export:mobile` pin; from then on it
        // is the proof that replacing the table changed no wording.
        let pin = try AtumCopy()
        for key in PhoneModelPickerPendingCopy.keys where pin.contains(key.rawValue) {
            for locale in pin.locales {
                XCTAssertEqual(
                    PhoneModelPickerPendingCopy.text(key, arguments: arguments(for: key), locale: locale),
                    try pin.text(key.rawValue, locale: locale, arguments: arguments(for: key)),
                    "\(locale) \(key)")
            }
        }
    }

    @MainActor
    func testTheLiveCopyResolvesEveryKeyWithoutStoppingTheApp() throws {
        let design = try LiveDesign()
        let copy = PhoneModelPickerCopy(design: design)
        for key in PhonePickerCopyKey.allCases {
            XCTAssertFalse(copy.text(key, arguments(for: key)).isEmpty, "\(key)")
        }
        for key in PhoneModelPickerStateCopyKey.allCases {
            XCTAssertFalse(copy.state(key).isEmpty, "\(key)")
        }
        // The thinking levels, named and explained, in the pin's own words.
        for level in ManagedModelEffort.allCases {
            XCTAssertFalse(copy.effortName(level).isEmpty, "\(level)")
            XCTAssertFalse(copy.effortHelp(level).isEmpty, "\(level)")
        }
        // The words the section headers and read-only rows borrow from the pin.
        for key in ["desktop.common.expand", "desktop.common.collapse",
                    "src.matrix.workbench-copy.copy.viewOnly"] {
            XCTAssertFalse(design.text(key).isEmpty, key)
        }
    }
}
