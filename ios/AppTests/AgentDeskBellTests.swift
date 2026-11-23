import AtumChat
import AtumDesign
import AtumNativeAPI
import XCTest
@testable import AtumMobile

/// W4-E3: the agent's desk (desktop #51) and Home's bell (desktop #48) take
/// every word from the pinned export, in every locale, with no pending table.
final class AgentDeskBellTests: XCTestCase {
    private let deskKeys = ["desk", "working", "minutes", "steerHint", "queueHint", "files", "sentHere",
                            "save", "saveShort", "more", "less", "onItsComputer", "back", "controls",
                            "notifications", "moreControls", "routines", "paused", "nextRun", "allSettings",
                            "pause", "controlFailed", "computerOff"]

    private func arguments(_ name: String) -> [AtumCopy.Argument] {
        switch name {
        case "desk", "save", "nextRun": [.text("X")]
        case "minutes": [.number(4)]
        default: []
        }
    }

    func testEveryDeskWordIsInThePinForEveryLocale() throws {
        let pin = try AtumCopy()
        for name in deskKeys {
            let key = AgentDeskCopy.key(name)
            XCTAssertTrue(pin.contains(key), key)
            for locale in pin.locales {
                let value = try pin.text(key, locale: locale, arguments: arguments(name))
                XCTAssertFalse(value.isEmpty, "\(key) \(locale)")
            }
        }
        // Pending: when a repin carries it, move it into `deskKeys` and drop the guard.
        for name in AgentDeskCopy.pendingKeys {
            XCTAssertFalse(pin.contains(AgentDeskCopy.key(name)), "\(name) is exported now: stop treating it as pending")
        }
        XCTAssertEqual(try pin.text(AgentDeskCopy.key("minutes"), locale: "en", arguments: [.number(4)]), "4 min")
        XCTAssertEqual(try pin.text(AgentDeskCopy.key("desk"), locale: "vi", arguments: [.text("Luna")]),
                       "Bàn làm việc của Luna")
    }

    func testEveryBellWordIsInThePinForEveryLocale() throws {
        let pin = try AtumCopy()
        let keys = [AttentionBellPolicy.notificationsKey, AttentionBellPolicy.nothingKey,
                    AttentionBellPolicy.prefixKey] + AttentionBellPolicy.Kind.allCases.map(AttentionBellPolicy.labelKey)
        for key in keys {
            XCTAssertTrue(pin.contains(key), key)
            for locale in pin.locales { XCTAssertFalse(try pin.text(key, locale: locale).isEmpty, "\(key) \(locale)") }
        }
        XCTAssertEqual(try pin.text(AttentionBellPolicy.countKey, locale: "vi", arguments: [.number(2)]), "2 việc cần bạn")
        XCTAssertEqual(try pin.text(AttentionBellPolicy.labelKey(.protons), locale: "en"), "Out of Protons")
    }

    func testTheDeskNamesASentFileByItsOwnNameAndTimesShortly() {
        let item = ChatItem(id: "f", kind: .file(name: "plan.pdf"), body: "plan.pdf",
                            media: ChatMedia(sourceHandle: "mxc://f", filename: "Q4 plan.pdf"))
        XCTAssertEqual(AgentDeskPage.fileName(item), "Q4 plan.pdf")
        XCTAssertEqual(AgentDeskPage.fileName(ChatItem(id: "g", kind: .file(name: "a.txt"), body: "x")), "a.txt")
        XCTAssertFalse(AgentDeskPage.when(Date(), locale: "vi").isEmpty)
        XCTAssertFalse(AgentDeskPage.nextRun(Date(), locale: "en").isEmpty)
    }
}
