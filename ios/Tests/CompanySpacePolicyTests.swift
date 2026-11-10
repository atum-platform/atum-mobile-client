import AtumChat
import Foundation
import XCTest
@testable import AtumNativeAPI

/// Wave 2 Team Space structure (TS-6..TS-10): the rules are the desktop's at atum-app `050ede8edf5`.
final class CompanySpacePolicyTests: XCTestCase {
    private let en = Locale(identifier: "en")

    // MARK: Tabs (TS-10)

    func testTabsAreChatAndBoardThenMarketplaceWhenTheStoreAnswers() {
        XCTAssertEqual(CompanySpaceTabs.ids(marketplaceAvailable: false), [.chat, .board])
        XCTAssertEqual(CompanySpaceTabs.ids(marketplaceAvailable: true), [.chat, .board, .marketplace])
    }

    func testARememberedPageThatIsGoneOpensChat() {
        XCTAssertEqual(CompanySpaceTabs.effective(.marketplace, marketplaceAvailable: false), .chat)
        XCTAssertEqual(CompanySpaceTabs.effective(.marketplace, marketplaceAvailable: true), .marketplace)
        XCTAssertEqual(CompanySpaceTabs.effective(.board, marketplaceAvailable: false), .board)
        XCTAssertEqual(CompanySpaceTabs.effective(nil, marketplaceAvailable: true), .chat)
    }

    // MARK: Company menu (TS-8)

    func testAMemberSeesOverviewMembersAndLeaveOnly() {
        let allowed = CompanyMenuAllowed.resolve(companySelected: true, snapshotLoaded: true, viewerIsAdmin: false,
                                                 inviteAvailable: true, teamAdminAvailable: true,
                                                 walletAvailable: true, canCreate: false, canLeave: true)
        XCTAssertEqual(allowed, CompanyMenuAllowed(overview: true, members: true, leave: true))
        XCTAssertTrue(allowed.inCompany)
        XCTAssertTrue(allowed.exits)
    }

    func testAnAdminGetsOnlyWhatThePhoneCanOpen() {
        let phoneToday = CompanyMenuAllowed.resolve(companySelected: true, snapshotLoaded: true, viewerIsAdmin: true,
                                                    inviteAvailable: false, teamAdminAvailable: false,
                                                    walletAvailable: false, canCreate: true, canLeave: true)
        XCTAssertEqual(phoneToday, CompanyMenuAllowed(overview: true, members: true, create: true, leave: true))
        let everything = CompanyMenuAllowed.resolve(companySelected: true, snapshotLoaded: true, viewerIsAdmin: true,
                                                    inviteAvailable: true, teamAdminAvailable: true,
                                                    walletAvailable: true, canCreate: true, canLeave: true)
        XCTAssertEqual(everything, CompanyMenuAllowed(overview: true, wallet: true, invite: true, settings: true,
                                                      members: true, create: true, leave: true))
    }

    func testNothingAboutACompanyBeforeOneIsOpen() {
        let allowed = CompanyMenuAllowed.resolve(companySelected: false, snapshotLoaded: false, viewerIsAdmin: true,
                                                 inviteAvailable: true, teamAdminAvailable: true,
                                                 walletAvailable: true, canCreate: true, canLeave: true)
        XCTAssertEqual(allowed, CompanyMenuAllowed(create: true))
        XCTAssertFalse(allowed.inCompany)
    }

    // MARK: Sidebar (TS-6)

    func testUtilityRowsAppearOnlyWithSomethingToOpen() {
        XCTAssertEqual(TeamSpaceSidebarEntries(threads: 0, saved: 0, drafts: 0),
                       TeamSpaceSidebarEntries(threads: 0, saved: 0, drafts: 0))
        let entries = TeamSpaceSidebarEntries(threads: 2, saved: 0, drafts: 1)
        XCTAssertTrue(entries.threads)
        XCTAssertFalse(entries.saved)
        XCTAssertTrue(entries.drafts)
    }

    func testSearchTrimsLowercasesAndMatchesAnyWord() {
        XCTAssertNil(TeamSpaceSearch.needle("   ", locale: en))
        let needle = TeamSpaceSearch.needle("  Gen ", locale: en)
        XCTAssertEqual(needle, "gen")
        XCTAssertTrue(TeamSpaceSearch.matches(["general"], needle: needle, locale: en))
        XCTAssertTrue(TeamSpaceSearch.matches(["You", "Your personal notes"], needle: "notes", locale: en))
        XCTAssertFalse(TeamSpaceSearch.matches(["design"], needle: needle, locale: en))
        XCTAssertTrue(TeamSpaceSearch.matches(["design"], needle: nil, locale: en))
        XCTAssertTrue(TeamSpaceSearch.matches(["Thiết kế"], needle: TeamSpaceSearch.needle("THIẾT", locale: en),
                                              locale: en))
    }

    // MARK: Saved messages (TS-6)

    func testSavedMessagesReadTheDesktopRecordNewestFirst() {
        XCTAssertEqual(CompanySavedMessages.accountDataType, "com.atum.saved_messages")
        XCTAssertEqual(CompanySavedMessages.parse(nil), [])
        let json = """
        {"version":1,"messages":[
          {"room_id":"!a:atum.test","event_id":"$1","saved_at":10},
          {"room_id":"!b:atum.test","event_id":"$2","saved_at":30}
        ]}
        """
        XCTAssertEqual(CompanySavedMessages.parse(json)?.map(\.eventID), ["$2", "$1"])
    }

    func testAnUnreadableOrNewerSavedRecordIsNotGuessed() {
        XCTAssertNil(CompanySavedMessages.parse("{\"version\":2,\"messages\":[]}"))
        XCTAssertNil(CompanySavedMessages.parse("{\"version\":1,\"messages\":[{\"room_id\":\"a\",\"event_id\":\"$1\",\"saved_at\":1}]}"))
        XCTAssertNil(CompanySavedMessages.parse("{\"version\":1,\"messages\":[{\"room_id\":\"!a:x\",\"event_id\":\"$1\",\"saved_at\":1.5}]}"))
        let duplicate = "{\"version\":1,\"messages\":[{\"room_id\":\"!a:x\",\"event_id\":\"$1\",\"saved_at\":1},"
            + "{\"room_id\":\"!a:x\",\"event_id\":\"$1\",\"saved_at\":2}]}"
        XCTAssertNil(CompanySavedMessages.parse(duplicate))
        XCTAssertNil(CompanySavedMessages.parse("not json"))
    }

    // MARK: Activity (TS-7)

    private func notification(room: String, event: String, sender: String = "@lan:atum.test", ts: Int = 1,
                              read: Bool = false, highlight: Bool = false, thread: String? = nil,
                              mentions: [String]? = nil, type: String = "m.room.message") -> [String: Any] {
        var content: [String: Any] = ["msgtype": "m.text", "body": "hello " + event]
        if let thread { content["m.relates_to"] = ["rel_type": "m.thread", "event_id": thread] }
        if let mentions { content["m.mentions"] = ["user_ids": mentions] }
        let actions: [Any] = highlight ? ["notify", ["set_tweak": "highlight"]] : ["notify"]
        return ["room_id": room, "read": read, "ts": ts, "actions": actions,
                "event": ["event_id": event, "sender": sender, "type": type, "origin_server_ts": ts,
                          "content": content]]
    }

    private func data(_ notifications: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["notifications": notifications])
    }

    func testActivityKeepsMentionsAndThreadRepliesInTheCompanyOnly() throws {
        let me = "@me:atum.test"
        let feed = data([
            notification(room: "!c:atum.test", event: "$m", ts: 5, highlight: true),
            notification(room: "!c:atum.test", event: "$t", ts: 7, thread: "$root"),
            notification(room: "!c:atum.test", event: "$plain", ts: 9),
            notification(room: "!other:atum.test", event: "$x", ts: 11, highlight: true),
            notification(room: "!c:atum.test", event: "$own", sender: me, ts: 12, highlight: true),
            notification(room: "!c:atum.test", event: "$pill", ts: 3, mentions: [me]),
            notification(room: "!c:atum.test", event: "$state", ts: 13, highlight: true, type: "m.room.member"),
        ])
        let items = try XCTUnwrap(CompanyActivityFeed.parse(notificationsJSON: feed, ownUserID: me,
                                                            roomIDs: ["!c:atum.test"]))
        XCTAssertEqual(items.map(\.eventID), ["$t", "$m", "$pill"])
        XCTAssertEqual(items.map(\.kind), [.threadReply, .mention, .mention])
        XCTAssertEqual(items.first?.threadRootID, "$root")
        XCTAssertEqual(CompanyActivityFeed.filtered(items, by: .mentions).map(\.eventID), ["$m", "$pill"])
    }

    func testActivityBadgeIsUnreadMentionsElseADotForUnreadReplies() throws {
        let me = "@me:atum.test"
        func items(_ list: [[String: Any]]) throws -> [CompanyActivityItem] {
            try XCTUnwrap(CompanyActivityFeed.parse(notificationsJSON: data(list), ownUserID: me,
                                                    roomIDs: ["!c:atum.test"]))
        }
        XCTAssertEqual(CompanyActivityFeed.badge(try items([
            notification(room: "!c:atum.test", event: "$1", highlight: true),
            notification(room: "!c:atum.test", event: "$2", read: true, highlight: true),
            notification(room: "!c:atum.test", event: "$3", thread: "$r"),
        ])), .mention(1))
        XCTAssertEqual(CompanyActivityFeed.badge(try items([
            notification(room: "!c:atum.test", event: "$3", thread: "$r"),
        ])), .dot)
        XCTAssertEqual(CompanyActivityFeed.badge(try items([
            notification(room: "!c:atum.test", event: "$3", read: true, thread: "$r"),
        ])), .none)
        XCTAssertNil(CompanyActivityFeed.parse(notificationsJSON: Data("[]".utf8), ownUserID: me, roomIDs: []))
    }
}
