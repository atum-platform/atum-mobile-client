import AtumDesign
import Foundation
import XCTest

final class AtumStoreArtCatalogTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    func testDeclaredItemIDResolvesToItsInstalledResource() throws {
        let catalog = try AtumStoreArtCatalog.decode(Data("""
        {
          "schemaVersion": 1,
          "items": {
            "pet/example": {
              "resource": "store/pets/example.png",
              "sha256": "\(digest)"
            }
          }
        }
        """.utf8))

        XCTAssertEqual(catalog.resource(for: "pet/example"), "store/pets/example.png")
        XCTAssertNil(catalog.resource(for: "pet/not-declared"))
    }

    func testProducerMetadataDoesNotBecomeAConsumerRequirement() throws {
        let catalog = try AtumStoreArtCatalog.decode(Data("""
        {"schemaVersion":1,"items":{
          "pet/future":{"resource":"store/pets/future.png","sha256":"\(digest)",
            "source":"another-producer/art.avif","sourceSha256":"not-a-consumer-field"}
        }}
        """.utf8))
        XCTAssertEqual(catalog.resource(for: "pet/future"), "store/pets/future.png")
    }

    func testUnsafeOrDuplicateResourcesAreRejected() throws {
        func body(resource: String, secondResource: String? = nil) -> Data {
            let second = secondResource.map {
                ",\n\"pet/two\": {\"resource\": \"\($0)\", \"sha256\": \"\(digest)\"}"
            } ?? ""
            return Data("""
            {"schemaVersion":1,"items":{
              "pet/one":{"resource":"\(resource)","sha256":"\(digest)"}
              \(second)
            }}
            """.utf8)
        }

        XCTAssertThrowsError(try AtumStoreArtCatalog.decode(body(resource: "../one.png")))
        XCTAssertThrowsError(try AtumStoreArtCatalog.decode(body(
            resource: "store/pets/shared.png", secondResource: "store/pets/shared.png"
        )))
    }
}
