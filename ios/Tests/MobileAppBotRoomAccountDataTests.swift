import XCTest
@testable import AtumNativeAPI

final class MobileAppBotRoomAccountDataTests: XCTestCase {
    private let appID = "00000000-0000-4000-8000-14d24c0754e9"
    private let botID = "@app-moon:atumplatform.com"

    private func hidden(_ content: String, type: String = "io.atum.app_bot.hidden") -> String {
        #"{"type":"\#(type)","content":\#(content),"sender":"@owner:atum.test"}"#
    }

    private func moved(_ content: String) -> String {
        #"{"type":"io.atum.app_bot.legacy_moved","content":\#(content)}"#
    }

    func testHiddenAtReadsTheDesktopDeleteChatTime() {
        XCTAssertEqual(MobileAppBotRoomAccountData.hiddenAt(eventJSON: hidden(#"{"v":1,"at":1760000000000}"#)),
                       1_760_000_000_000)
    }

    func testClearedWrongVersionAndMalformedHiddenEventsCarryNoAuthority() {
        let contents = [
            "{}",                             // Show chat clears with an empty object
            #"{"v":2,"at":5}"#,
            #"{"v":1}"#,
            #"{"v":1,"at":0}"#,
            #"{"v":1,"at":-4}"#,
            #"{"v":1,"at":"5"}"#,
            #"{"v":1,"at":1.5}"#,
            #"{"v":1,"at":true}"#,
            #"{"v":1,"at":5,"extra":1}"#,        // extra keys carry no authority
            #"{"v":1,"at":9007199254740992}"#, // beyond a safe integer
            "[]",
            "null",
        ]
        for content in contents {
            XCTAssertNil(MobileAppBotRoomAccountData.hiddenAt(eventJSON: hidden(content)), content)
        }
        XCTAssertNil(MobileAppBotRoomAccountData.hiddenAt(eventJSON: nil))
        XCTAssertNil(MobileAppBotRoomAccountData.hiddenAt(eventJSON: ""))
        XCTAssertNil(MobileAppBotRoomAccountData.hiddenAt(eventJSON: "not json"))
        XCTAssertNil(MobileAppBotRoomAccountData.hiddenAt(
            eventJSON: hidden(#"{"v":1,"at":5}"#, type: "io.atum.app_bot.legacy_moved")),
            "another event type is never read as Delete chat")
        XCTAssertNil(MobileAppBotRoomAccountData.hiddenAt(
            eventJSON: hidden(#"{"v":1,"at":5,"pad":""# + String(repeating: "a", count: 5_000) + #""}"#)),
            "an oversized event is refused")
    }

    func testDeletedChatStaysHiddenUntilAMessageNewerThanTheDeleteTime() {
        XCTAssertFalse(MobileAppBotRoomAccountData.isHidden(hiddenAt: nil, lastMessageAt: 0))
        XCTAssertTrue(MobileAppBotRoomAccountData.isHidden(hiddenAt: 1_000, lastMessageAt: 0))
        XCTAssertTrue(MobileAppBotRoomAccountData.isHidden(hiddenAt: 1_000, lastMessageAt: 1_000))
        XCTAssertFalse(MobileAppBotRoomAccountData.isHidden(hiddenAt: 1_000, lastMessageAt: 1_001))
    }

    func testLegacyMoveRequiresTheExactDesktopShape() {
        let valid = #"{"v":1,"app_id":"\#(appID)","bot_user_id":"\#(botID)","moved_at":1760000000000}"#
        XCTAssertEqual(MobileAppBotRoomAccountData.legacyMove(eventJSON: moved(valid)),
                       MobileLegacyAppBotMove(appID: appID, botUserID: botID, movedAt: 1_760_000_000_000))

        let invalid = [
            #"{"v":1,"app_id":"\#(appID)","bot_user_id":"\#(botID)","moved_at":5,"extra":1}"#,
            #"{"v":1,"app_id":"\#(appID)","bot_user_id":"\#(botID)"}"#,
            #"{"v":2,"app_id":"\#(appID)","bot_user_id":"\#(botID)","moved_at":5}"#,
            #"{"v":1,"app_id":"not-a-uuid","bot_user_id":"\#(botID)","moved_at":5}"#,
            #"{"v":1,"app_id":"\#(appID)","bot_user_id":"app-moon","moved_at":5}"#,
            #"{"v":1,"app_id":"\#(appID)","bot_user_id":"\#(botID)","moved_at":-1}"#,
            #"{"v":1,"app_id":"\#(appID)","bot_user_id":"\#(botID)","moved_at":"5"}"#,
            "{}",
        ]
        for content in invalid {
            XCTAssertNil(MobileAppBotRoomAccountData.legacyMove(eventJSON: moved(content)), content)
        }
        XCTAssertNil(MobileAppBotRoomAccountData.legacyMove(eventJSON: nil))
        XCTAssertNil(MobileAppBotRoomAccountData.legacyMove(
            eventJSON: hidden(valid, type: "io.atum.app_bot.hidden")),
            "another event type is never read as a moved note")
    }
}
