import Foundation
import XCTest
@testable import AtumNativeAPI

/// The card's Pet row value, decided the way desktop's `useAgentPetName`
/// decides whether a sprite (and so a name) exists.
final class AgentPetNameTests: XCTestCase {
    private func selection(_ json: String) throws -> AgentPetSelection {
        try JSONDecoder().decode(AgentPetSelection.self, from: Data("""
        {"owner":"o","agent":"a","revision":1,"provenance":\(json == "null" ? "null" : "\"explicit\""),
         "access":null,"visitEndsAt":null,"serverTime":"2026-11-11T00:00:00Z","pet":\(json)}
        """.utf8))
    }

    private let gigiOwned = AgentPetCatalog(agent: "a", items: [
        .init(ref: .bundled(slug: "gigi"), name: "Gigi", access: .owned),
    ], personal: [])

    func testABundledPetIsNamedFromItsAssetWithoutTheCatalog() throws {
        let value = try selection(#"{"ref":{"kind":"bundled","slug":"cookie"},"enabled":true,"scale":1}"#)
        XCTAssertFalse(AgentPetName.needsCatalog(value, isPrimary: false))
        XCTAssertEqual(AgentPetName.resolve(value, catalog: nil, isPrimary: false), "Cookie")
    }

    func testAHiddenOrNoCompanionChoiceSaysChoose() throws {
        let hidden = try selection(#"{"ref":{"kind":"bundled","slug":"mochi"},"enabled":false,"scale":1}"#)
        XCTAssertNil(AgentPetName.resolve(hidden, catalog: gigiOwned, isPrimary: true))
        let none = try selection(#"{"ref":null,"enabled":true,"scale":1}"#)
        XCTAssertNil(AgentPetName.resolve(none, catalog: gigiOwned, isPrimary: true))
        XCTAssertFalse(AgentPetName.needsCatalog(none, isPrimary: true))
    }

    func testAPersonalPetNeedsTheFreshLibrary() throws {
        let value = try selection(#"{"ref":{"kind":"personal","pet_id":"p-9"},"enabled":true,"scale":1}"#)
        XCTAssertTrue(AgentPetName.needsCatalog(value, isPrimary: false))
        XCTAssertNil(AgentPetName.resolve(value, catalog: nil, isPrimary: false))
        let library = AgentPetCatalog(agent: "a", items: [], personal: [
            .init(petID: "p-9", displayName: "Pip"),
        ])
        XCTAssertEqual(AgentPetName.resolve(value, catalog: library, isPrimary: false), "Pip")
        let deleted = AgentPetCatalog(agent: "a", items: [], personal: [
            .init(petID: "p-9", displayName: "Pip", deletedAt: "2026-11-01T00:00:00Z"),
        ])
        XCTAssertNil(AgentPetName.resolve(value, catalog: deleted, isPrimary: false))
    }

    func testUnknownPetKindsSayChoose() throws {
        let value = try selection(#"{"ref":{"kind":"petdex","slug":"x"},"enabled":true,"scale":1}"#)
        XCTAssertNil(AgentPetName.resolve(value, catalog: gigiOwned, isPrimary: false))
    }

    func testOnlyThePrimaryGetsGigiAsAnUnsavedStandIn() throws {
        let unsaved = try selection("null")
        XCTAssertTrue(AgentPetName.needsCatalog(unsaved, isPrimary: true))
        XCTAssertFalse(AgentPetName.needsCatalog(unsaved, isPrimary: false))
        XCTAssertEqual(AgentPetName.resolve(unsaved, catalog: gigiOwned, isPrimary: true), "Gigi")
        XCTAssertNil(AgentPetName.resolve(unsaved, catalog: gigiOwned, isPrimary: false))
        let offered = AgentPetCatalog(agent: "a", items: [
            .init(ref: .bundled(slug: "gigi"), name: "Gigi", access: .available),
        ], personal: [])
        XCTAssertNil(AgentPetName.resolve(unsaved, catalog: offered, isPrimary: true))
        XCTAssertNil(AgentPetName.resolve(unsaved, catalog: nil, isPrimary: true))
    }
}
