import Foundation
import XCTest
@testable import AtumNativeAPI

final class StoreShelvesTests: XCTestCase {
    func testSearchIsAccentDAndCaseInsensitiveWithCollapsedSpaces() {
        XCTAssertEqual(StoreSearch.normalized("  Đặt   LỊCH  họp "), "dat lich hop")
        XCTAssertTrue(StoreSearch.matches("dat lich", fields: ["skill", "Đặt lịch họp", "Tóm tắt"]))
        XCTAssertTrue(StoreSearch.matches("TOM TAT", fields: ["skill", "Đặt lịch họp", "Tóm tắt"]))
        XCTAssertTrue(StoreSearch.matches("pet", fields: ["pet", "Gigi", ""]))
        XCTAssertFalse(StoreSearch.matches("moon", fields: ["skill", "Nova", "A synthetic skill"]))
        XCTAssertTrue(StoreSearch.matches("   ", fields: ["anything"]))
    }

    func testGlyphMapsEachCatalogEmojiAndFallsBackToTheKind() {
        XCTAssertEqual(StoreGlyphs.alias(glyph: "🛍", kind: .skill), "StoreShoppingBag")
        // Variation selectors never change which glyph is meant.
        XCTAssertEqual(StoreGlyphs.alias(glyph: "✍\u{FE0F}", kind: .skill), "StorePenNib")
        XCTAssertEqual(StoreGlyphs.alias(glyph: " 🗓\u{FE0F} ", kind: .skill), "StoreCalendarBlank")
        XCTAssertEqual(StoreGlyphs.alias(glyph: "🧑‍🏫", kind: .skill), "StoreChalkboardTeacher")
        XCTAssertEqual(StoreGlyphs.alias(glyph: "◉", kind: .skill), "StoreSparkle")
        XCTAssertEqual(StoreGlyphs.alias(glyph: "A", kind: .agent), "StoreRobot")
        XCTAssertEqual(StoreGlyphs.alias(glyph: "?", kind: .pet), "StorePawPrint")
        XCTAssertEqual(StoreGlyphs.emoji.count, 49, "desktop store-card.tsx STORE_GLYPH_ICON has 49 entries")
    }

    /// Every alias the Store can draw is in the vendored Phosphor map (the app
    /// test `KitGlyphTests` then proves each map entry is a compiled symbol).
    func testEveryStoreGlyphAliasIsInThePhosphorMap() throws {
        let map = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/AtumKitIcons/phosphor-map.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: map)) as? [String: Any]
        let aliases = try XCTUnwrap(object?["aliases"] as? [String: Any])
        for alias in StoreGlyphs.allAliases {
            XCTAssertNotNil(aliases[alias], alias)
        }
    }
}
