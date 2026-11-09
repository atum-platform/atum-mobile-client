import XCTest
@testable import AtumDesign

final class AtumCopyTests: XCTestCase {
    func testEveryCommittedPlainStringRemainsLiteral() throws {
        let copy = try AtumCopy()
        let raw = try JSONSerialization.jsonObject(with: AtumDesign.data(for: "Localizable.xcstrings")) as! [String: Any]
        let strings = raw["strings"] as! [String: [String: Any]]
        let contract = try JSONSerialization.jsonObject(with: AtumDesign.data(for: "copy-contract.json")) as! [String: Any]
        let parameters = contract["parameters"] as! [String: [[String: Any]]]
        for (key, signature) in parameters where signature.isEmpty {
            let localizations = strings[key]!["localizations"] as! [String: [String: Any]]
            for locale in copy.locales {
                let expected = (localizations[locale]!["stringUnit"] as! [String: String])["value"]!
                XCTAssertEqual(try copy.text(key, locale: locale), expected)
            }
        }
    }

    func testCommittedPhoneSourceLoadsExactlyInAllLocales() throws {
        let copy = try AtumCopy()
        let raw = try JSONSerialization.jsonObject(with: AtumDesign.data(for: "Localizable.xcstrings")) as! [String: Any]
        let strings = raw["strings"] as! [String: [String: Any]]
        let keys = strings.keys.filter { $0.hasPrefix("src.matrix.mobile-device-copy.mobileDeviceCopy.") }
        XCTAssertFalse(keys.isEmpty)
        for key in keys {
            let localizations = strings[key]!["localizations"] as! [String: [String: Any]]
            for locale in copy.locales {
                let expected = (localizations[locale]!["stringUnit"] as! [String: String])["value"]!
                XCTAssertEqual(try copy.text(key, locale: locale), expected, "\(locale): \(key)")
            }
        }
    }

    func testExactNumericBranchesAndLiteralPercentPreserveSource() throws {
        let copy = try AtumCopy()
        for locale in copy.locales {
            for count: Int64 in [0, 1, 2, 42, 12345] {
                let text = try copy.text("desktop.atum.agents.photoUploading", locale: locale, arguments: [.number(count)])
                XCTAssertTrue(text.contains("\(count)%"), "\(locale), \(count): \(text)")
            }
        }
    }

    func testTypedArgumentsAndMissingLocaleFailInsteadOfEnglishFallback() throws {
        let copy = try AtumCopy()
        XCTAssertThrowsError(try copy.text("desktop.atum.agents.photoUploading", locale: "vi", arguments: [.text("42")]))
        XCTAssertThrowsError(try copy.text("desktop.atum.agents.photoUploading", locale: "vi"))
        XCTAssertThrowsError(try copy.text("desktop.atum.nav.home", locale: "fr"))
        XCTAssertThrowsError(try copy.text("missing.copy", locale: "vi"))
    }
}
