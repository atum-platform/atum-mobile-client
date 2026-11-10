import XCTest
@testable import AtumChat

/// HC-2: Report person and Report message beside Block (App Review 1.2),
/// as on the desktop (`roster-model.ts` `reportablePerson`, `app.tsx`
/// `reportMenu`, `sdk.ts` `reportEvent` / `reportUser`).
final class ReportPolicyTests: XCTestCase {
    private let room = "!room:example.test"
    private let bots: Set<String> = [F.agent, F.bot]

    private func image(_ id: String, from sender: String) -> ChatItem {
        ChatItem(id: id, kind: .image(width: 400, height: 300), sender: sender,
                 eventOrTransactionId: .event("$" + id))
    }

    // MARK: Report person

    func testOnlyAPersonWhoIsNotYouMayBeReported() {
        for room in [ChatExitPolicy.Room.person, .group] {
            XCTAssertTrue(ReportPolicy.mayReportPerson(.person, isSelf: false, in: room, viewerIsFounder: false))
            XCTAssertFalse(ReportPolicy.mayReportPerson(.person, isSelf: true, in: room, viewerIsFounder: false),
                           "never yourself")
            XCTAssertFalse(ReportPolicy.mayReportPerson(.assistant, isSelf: false, in: room, viewerIsFounder: false),
                           "never an assistant")
            XCTAssertFalse(ReportPolicy.mayReportPerson(.app, isSelf: false, in: room, viewerIsFounder: false),
                           "never an app's bot")
        }
    }

    func testReportPersonIsOfferedWhereTheChatCanBeDeletedOrLeft() {
        XCTAssertTrue(ReportPolicy.mayReportPerson(.person, isSelf: false, in: .founder, viewerIsFounder: false),
                      "anyone may report the Founder")
        XCTAssertFalse(ReportPolicy.mayReportPerson(.person, isSelf: false, in: .founder, viewerIsFounder: true),
                       "the Founder's own Founder chat offers neither Delete nor Report")
        for room in [ChatExitPolicy.Room.assistant, .appBot, .teamSpace, .system, .invitation] {
            XCTAssertFalse(ReportPolicy.mayReportPerson(.person, isSelf: false, in: room, viewerIsFounder: false),
                           "\(room)")
        }
    }

    func testTheMembersPageOffersReportAfterBlockAndBeforeModeration() {
        let admin = ChatMemberModeration(ownPower: 100, kickLevel: 50, banLevel: 50)
        XCTAssertEqual(admin.actions(targetPower: 0, membership: .joined, isSelf: false,
                                     mayBlock: true, isBlocked: false, mayReport: true),
                       [.block, .report, .remove, .ban])
        XCTAssertEqual(admin.actions(targetPower: 0, membership: .joined, isSelf: false,
                                     mayBlock: true, isBlocked: true, mayReport: false),
                       [.unblock, .remove, .ban], "an assistant or app: no Report")
        XCTAssertEqual(admin.actions(targetPower: 100, membership: .joined, isSelf: true,
                                     mayBlock: true, isBlocked: false, mayReport: true), [])
        XCTAssertEqual(ChatMemberModeration.personalActions(isSelf: false, mayBlock: true, isBlocked: false,
                                                            mayReport: true), [.block, .report],
                       "without power levels: Block and Report only")
        XCTAssertEqual(ChatMemberModeration.personalActions(isSelf: true, mayBlock: true, isBlocked: false,
                                                            mayReport: true), [])
    }

    // MARK: Report message

    func testSomeoneElsesMessageInAPeopleChatMayBeReportedButNeverMine() {
        for kind in [RoomKind.person, .group] {
            XCTAssertTrue(ReportPolicy.mayReportMessage(F.text("t", from: F.friend), in: kind, nonPersonSenders: bots))
            XCTAssertTrue(ReportPolicy.mayReportMessage(image("i", from: F.friend), in: kind, nonPersonSenders: bots))
            XCTAssertFalse(ReportPolicy.mayReportMessage(F.mine("m"), in: kind, nonPersonSenders: bots), "\(kind)")
            XCTAssertFalse(ReportPolicy.mayReportMessage(F.echo("e"), in: kind, nonPersonSenders: bots))
        }
    }

    func testAssistantsAndAppBotsAreNeverReported() {
        XCTAssertFalse(ReportPolicy.mayReportMessage(F.text("a", from: F.agent), in: .group, nonPersonSenders: bots),
                       "an assistant in a group")
        XCTAssertFalse(ReportPolicy.mayReportMessage(F.text("b", from: F.bot), in: .group, nonPersonSenders: bots),
                       "an app bot in a group")
        XCTAssertFalse(ReportPolicy.mayReportMessage(F.text("a", from: F.agent), in: .assistant, nonPersonSenders: []),
                       "an assistant's chat, even unnamed")
        XCTAssertFalse(ReportPolicy.mayReportMessage(F.text("b", from: F.bot), in: .appBot, nonPersonSenders: []))
    }

    func testOnlyAMessageTheServerHasIsReported() {
        var pending = F.text("p", from: F.friend)
        pending.delivery = .sending()
        XCTAssertFalse(ReportPolicy.mayReportMessage(pending, in: .person, nonPersonSenders: []))
        var local = F.text("l", from: F.friend)
        local.eventOrTransactionId = .transaction("txn-l")
        XCTAssertFalse(ReportPolicy.mayReportMessage(local, in: .person, nonPersonSenders: []))
        let rows: [ChatItem] = [
            F.notice("n", from: F.friend),
            ChatItem(id: "x", kind: .placeholder(.redacted), sender: F.friend, eventOrTransactionId: .event("$x")),
            ChatItem(id: "u", kind: .placeholder(.undecryptable), sender: F.friend, eventOrTransactionId: .event("$u")),
            ChatItem(id: "s", kind: .roomState, sender: F.friend, eventOrTransactionId: .event("$s"))
        ]
        for item in rows {
            XCTAssertFalse(ReportPolicy.mayReportMessage(item, in: .group, nonPersonSenders: []), item.id)
        }
    }

    func testTheMenuOffersReportBeforeDeleteOnlyWhenItKnowsWhoIsAPerson() {
        let friend = F.text("t", from: F.friend, "Chào")
        XCTAssertEqual(MessageMenuRules.items(for: friend, in: .group, nonPersonSenders: bots),
                       [.react, .reply, .copy, .report])
        XCTAssertEqual(MessageMenuRules.items(for: friend, in: .group), [.react, .reply, .copy],
                       "a host that cannot tell an assistant from a person offers no Report")
        XCTAssertEqual(MessageMenuRules.items(for: F.mine("m", "Ok"), in: .person, nonPersonSenders: bots),
                       [.react, .reply, .copy, .edit, .delete], "never on my own")
        XCTAssertEqual(MessageMenuRules.items(for: F.text("a", from: F.agent, "Kết quả"), in: .assistant,
                                              nonPersonSenders: bots),
                       [.react, .reply, .copy, .selectText])
        XCTAssertEqual(MessageMenuRules.items(for: F.text("b", from: F.bot, "Chào"), in: .appBot,
                                              nonPersonSenders: bots), [.copy, .selectText])
    }

    // MARK: Requests

    func testTheReasonIsCleanedAsTheDesktopSendsIt() {
        XCTAssertNil(ReportPolicy.reason(""))
        XCTAssertNil(ReportPolicy.reason("  \n\t "))
        XCTAssertEqual(ReportPolicy.reason("  spam\n\nlinks\u{0007}again  "), "spam links again")
        XCTAssertEqual(ReportPolicy.reason(String(repeating: "a", count: 600))?.count, ReportPolicy.reasonLimit)
    }

    func testAMessageReportNamesTheEventAndTheReasonNeverTheText() {
        let item = F.text("t", from: F.friend, "nội dung riêng")
        XCTAssertEqual(ReportPolicy.messageRequest(roomID: room, item: item, kind: .group, nonPersonSenders: bots,
                                                   reason: "  spam  "),
                       ReportPolicy.Request(roomID: room, target: .event("$t"), reason: "spam"))
        XCTAssertEqual(ReportPolicy.messageRequest(roomID: room, item: item, kind: .person, nonPersonSenders: bots,
                                                   reason: nil)?.reason, ReportPolicy.defaultReason,
                       "no reason: the desktop's fixed protocol value")
        XCTAssertNil(ReportPolicy.messageRequest(roomID: room, item: F.mine("m"), kind: .person,
                                                 nonPersonSenders: bots, reason: nil))
        XCTAssertNil(ReportPolicy.messageRequest(roomID: room, item: F.text("a", from: F.agent), kind: .group,
                                                 nonPersonSenders: bots, reason: nil))
    }

    func testAPersonReportNamesTheirLatestMessageHere() {
        var failed = F.text("f", from: F.friend)
        failed.delivery = .failed(isRecoverable: true)
        let items = [F.text("1", from: F.friend), F.text("2", from: F.other), image("3", from: F.friend),
                     F.mine("4"), F.notice("5", from: F.friend), failed]
        XCTAssertEqual(ReportPolicy.personRequest(roomID: room, userID: F.friend, ownUserID: F.me, kind: .group,
                                                  items: items, reason: "rude"),
                       ReportPolicy.Request(roomID: room, target: .event("$3"), reason: "rude"))
        XCTAssertEqual(ReportPolicy.personRequest(roomID: room, userID: F.other, ownUserID: F.me, kind: .group,
                                                  items: items, reason: nil)?.target, .event("$2"))
    }

    func testAPersonWithNothingLoadedIsReportedByTheirChatOnlyOneToOne() {
        XCTAssertEqual(ReportPolicy.personRequest(roomID: room, userID: F.friend, ownUserID: F.me, kind: .person,
                                                  items: [F.mine("m")], reason: nil),
                       ReportPolicy.Request(roomID: room, target: .room, reason: ReportPolicy.defaultReason))
        XCTAssertNil(ReportPolicy.personRequest(roomID: room, userID: F.friend, ownUserID: F.me, kind: .group,
                                                items: [F.mine("m")], reason: nil),
                     "a group report would name everyone in it")
        XCTAssertNil(ReportPolicy.personRequest(roomID: room, userID: F.me, ownUserID: F.me, kind: .person,
                                                items: [F.mine("m")], reason: nil), "never yourself")
    }

    // MARK: Copy

    func testEveryPendingKeyHasAStandInFromTheExport() {
        XCTAssertEqual(ReportPendingCopy.allCases.count, 4)
        for key in ReportPendingCopy.allCases {
            XCTAssertTrue(key.rawValue.hasPrefix("src.matrix.chat-copy.copies.report"), key.rawValue)
            XCTAssertTrue(ChatCopyKey.allCases.contains(key.fallback), key.rawValue)
        }
    }
}
