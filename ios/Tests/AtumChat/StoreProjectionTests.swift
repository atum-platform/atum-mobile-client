import XCTest
@testable import AtumChat

final class StoreProjectionTests: XCTestCase {
    func testSectionsUseTheSpecifiedOrderWithoutDuplicatingFeaturedItems() {
        let sections = StoreProjection.sections([
            .init(id: "skill-featured", kind: .skill, featured: true),
            .init(id: "app-moon", kind: .app),
            .init(id: "agent", kind: .assistant),
            .init(id: "skill", kind: .skill),
            .init(id: "pet", kind: .pet),
        ])

        XCTAssertEqual(sections.map(\.kind), [.featured, .apps, .assistants, .skills, .pets])
        XCTAssertEqual(sections.map(\.entryIDs), [
            ["skill-featured"], ["app-moon"], ["agent"], ["skill"], ["pet"],
        ])
    }

    func testEmptySectionsAreOmitted() {
        XCTAssertEqual(StoreProjection.sections([.init(id: "app", kind: .app)]), [
            .init(kind: .apps, entryIDs: ["app"]),
        ])
        XCTAssertTrue(StoreProjection.sections([]).isEmpty)
    }
}

