import XCTest
@testable import AtumDesign

final class AtumDesignTests: XCTestCase {
    func testCommittedResourcesLoadWithoutProducerCheckout() throws {
        let manifest = try AtumDesign.manifest()
        XCTAssertEqual(manifest.developmentLanguage, "vi")
        XCTAssertEqual(Set(manifest.locales), Set(["en", "vi", "ja", "zh", "zh-Hant"]))
        for path in manifest.files.keys {
            XCTAssertFalse(try AtumDesign.data(for: path).isEmpty, path)
        }
    }

    func testUnlistedResourceFailsClosed() {
        XCTAssertThrowsError(try AtumDesign.data(for: "../outside.json"))
    }

    func testIncompatibleSchemaReportsItsVersion() {
        let data = Data(#"{"schemaVersion":999,"developmentLanguage":"vi","locales":[],"files":{}}"#.utf8)
        XCTAssertThrowsError(try AtumDesign.decodeManifest(data)) { error in
            guard case AtumDesign.ResourceError.unsupportedSchema(999) = error else {
                return XCTFail("Expected unsupported schema, got \(error)")
            }
        }
    }
}
