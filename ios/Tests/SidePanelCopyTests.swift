import AtumDesign
import XCTest

/// Exercise the panel's dynamic key prefixes through the actual pinned catalog
/// and formatting contract; source-literal scans cannot check these prefixes.
final class SidePanelCopyTests: XCTestCase {
    func testPanelLabelsResolveInEveryExportedLocale() throws {
        let copy = try AtumCopy()
        let labels = ["conversationInfo", "groupInfo", "showInfo", "closeInfo", "teamSpaces",
                      "conversation", "encrypted", "notEncrypted", "muteNotifications", "lowPriority",
                      "back", "loading", "failed", "tryAgain"]
        for locale in copy.locales {
            for label in labels {
                XCTAssertFalse(try copy.text("src.matrix.person-info-copy.copy." + label, locale: locale).isEmpty)
            }
            for label in ["blockPerson", "blockPersonTitle", "blockPersonBody", "unblockPerson"] {
                XCTAssertFalse(try copy.text("src.matrix.chat-copy.copies." + label, locale: locale).isEmpty)
            }
        }
    }

    func testMembersAcceptsZeroOneAndPluralCountsInEveryLocale() throws {
        let copy = try AtumCopy()
        for locale in copy.locales {
            let key = "src.matrix.person-info-copy.copy.members"
            for count: Int64 in [0, 1, 2, 42] {
                let text = try copy.text(key, locale: locale, arguments: [.number(count)])
                XCTAssertFalse(text.isEmpty)
                XCTAssertFalse(text.contains("%@"))
            }
            XCTAssertThrowsError(try copy.text(key, locale: locale, arguments: [.text("2")]))
        }
    }

    func testStartedSubstitutesTheProvidedDateInEveryLocale() throws {
        let copy = try AtumCopy()
        for locale in copy.locales {
            let text = try copy.text("src.matrix.person-info-copy.copy.started", locale: locale,
                                     arguments: [.text("2026-11-10")])
            XCTAssertTrue(text.contains("2026-11-10"))
        }
    }
}
