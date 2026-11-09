import AtumDesign
import XCTest
@testable import AtumMobile

/// The disclosure copy a catalog app's start flow shows. Moon and Andy keep
/// their pinned terms pages; an app the phone has never heard of (`acme`) gets
/// the same consent, connecting and failure lines from the export, a terms link
/// only when the export ships `<slug>TermsURL`, and no Moon-shaped intake copy.
final class AppOnboardingCopyTests: XCTestCase {
    private let termsRoot = "src.matrix.mobile-copy.mobileChatCopy.appBot.onboarding."

    func testMoonAndAndyKeepTheirPinnedTermsAndIntakeCopy() throws {
        let catalog = try AtumCopy()
        let moon = try XCTUnwrap(AppOnboardingCopy(catalog: catalog, locale: "en", slug: "moon",
                                                   appName: "Moon"))
        XCTAssertEqual(moon.termsURL?.host, "moon.atumplatform.com")
        XCTAssertEqual(Set(moon.fieldLabels.keys),
                       ["preferred_name", "dob", "birth_time", "birth_city", "gender"])
        XCTAssertNotNil(moon.birthTimeHelper)

        let andy = try XCTUnwrap(AppOnboardingCopy(catalog: catalog, locale: "en", slug: "andy",
                                                   appName: "Andy"))
        XCTAssertEqual(andy.termsURL?.host, "andy.atumplatform.com")
        XCTAssertTrue(andy.fieldLabels.isEmpty)
    }

    func testANewAppReadsTheGenericDisclosureInEveryLocaleWithoutATermsPage() throws {
        let catalog = try AtumCopy()
        for locale in catalog.locales {
            let acme = try XCTUnwrap(AppOnboardingCopy(catalog: catalog, locale: locale,
                                                       slug: "acme", appName: "Acme"),
                                     "acme has no disclosure copy in \(locale)")
            XCTAssertTrue(acme.consent.contains("Acme"), "\(locale): the consent names the app")
            XCTAssertTrue(acme.connecting.contains("Acme"), locale)
            XCTAssertFalse(acme.failure.isEmpty, locale)
            XCTAssertNil(acme.termsURL, "no terms page is invented for an app the export does not carry")
            XCTAssertTrue(acme.fieldLabels.isEmpty)
            XCTAssertNil(acme.birthTimeHelper)
        }
    }

    /// Ships `acme`'s terms through the export alone: no Swift knows the app.
    func testANewAppsTermsPageComesFromTheExportWhenItShipsOne() throws {
        let catalogData = try AtumDesign.data(for: "Localizable.xcstrings")
        let contractData = try AtumDesign.data(for: "copy-contract.json")
        let locales = Set(try AtumDesign.manifest().locales)
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
        var strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
        let key = termsRoot + "acmeTermsURL"

        func localizations(_ url: String) -> [String: Any] {
            ["localizations": Dictionary(uniqueKeysWithValues: locales.map {
                ($0, ["stringUnit": ["state": "translated", "value": url]])
            })]
        }
        var contract = try XCTUnwrap(JSONSerialization.jsonObject(with: contractData) as? [String: Any])
        var parameters = try XCTUnwrap(contract["parameters"] as? [String: Any])
        parameters[key] = []
        contract["parameters"] = parameters

        func copy(url: String) throws -> AtumCopy {
            strings[key] = localizations(url)
            catalog["strings"] = strings
            return try AtumCopy(
                catalogData: JSONSerialization.data(withJSONObject: catalog),
                contractData: JSONSerialization.data(withJSONObject: contract),
                locales: locales
            )
        }

        let shipped = try XCTUnwrap(AppOnboardingCopy(
            catalog: try copy(url: "https://acme.atumplatform.com/terms"),
            locale: "en", slug: "acme", appName: "Acme"))
        XCTAssertEqual(shipped.termsURL?.absoluteString, "https://acme.atumplatform.com/terms")

        // A terms page that is not a plain https URL refuses the whole bundle.
        for bad in ["http://acme.atumplatform.com/terms", "https://u:p@acme.atumplatform.com/t",
                    "https://acme.atumplatform.com/t#x", "not a url"] {
            XCTAssertNil(AppOnboardingCopy(catalog: try copy(url: bad), locale: "en",
                                           slug: "acme", appName: "Acme"), bad)
        }
    }

    func testAnIntakeFieldWithoutExportCopyIsNeverShownAsARawIdentifier() {
        XCTAssertEqual(AppOnboardingCopy.readableName("birth_city"), "Birth city")
        XCTAssertEqual(AppOnboardingCopy.readableName("company"), "Company")
        XCTAssertEqual(AppOnboardingCopy.readableName(""), "")
    }
}
