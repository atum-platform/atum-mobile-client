import XCTest
@testable import AtumChat

/// HC-2 and bot content reports (App Review 1.2 and 4.7.1): person-report
/// restrictions remain separate from message-report eligibility.
final class ReportPolicyTests: XCTestCase {
    private let room = "!room:example.test"

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

    func testPersonAssistantAndAppMessagesMayBeReportedInEveryRoomKind() {
        for sender in [F.friend, F.agent, F.bot] {
            let items = [F.text("t", from: sender), image("i", from: sender),
                         ChatItem(id: "f", kind: .file(name: "file.pdf"), sender: sender,
                                  eventOrTransactionId: .event("$f"))]
            for item in items {
                XCTAssertTrue(ReportPolicy.mayReportMessage(item), "\(sender): \(item.id)")
                for kind in RoomKind.allCases {
                    XCTAssertTrue(MessageMenuRules.items(for: item, in: kind).contains(.report),
                                  "\(sender): \(item.id) in \(kind)")
                }
            }
        }
    }

    func testOwnMessagesNeverOfferReportInAnyRoomKind() {
        let sent = F.echo("s", delivery: .sent(eventID: "$sent"))
        for item in [F.mine("m"), F.echo("e"), sent] {
            XCTAssertFalse(ReportPolicy.mayReportMessage(item))
            XCTAssertNil(ReportPolicy.messageRequest(roomID: room, item: item, reason: nil))
            for kind in RoomKind.allCases {
                XCTAssertFalse(MessageMenuRules.items(for: item, in: kind).contains(.report), "\(kind)")
            }
        }
    }

    func testOnlyAMessageTheServerHasIsReported() {
        for sender in [F.friend, F.agent, F.bot] {
            var item = F.text("t", from: sender)
            for delivery in [ChatDelivery.sending(), .failed(isRecoverable: true)] {
                item.delivery = delivery
                assertUnreportable(item)
            }
            item.delivery = .remote
            item.eventOrTransactionId = .transaction("txn-t")
            assertUnreportable(item)
            item.eventOrTransactionId = nil
            assertUnreportable(item)
            item.eventOrTransactionId = .event("not-a-server-event")
            assertUnreportable(item)
        }
        assertUnreportable(F.text("empty", from: ""))
    }

    func testNonContentRowsNeverOfferReport() {
        for sender in [F.friend, F.agent, F.bot] {
            let rows: [ChatItem] = [
                ChatItem(id: "x", kind: .placeholder(.redacted), sender: sender, eventOrTransactionId: .event("$x")),
                ChatItem(id: "u", kind: .placeholder(.undecryptable), sender: sender, eventOrTransactionId: .event("$u")),
                ChatItem(id: "s", kind: .roomState, sender: sender, eventOrTransactionId: .event("$s"))
            ]
            for item in rows { assertUnreportable(item) }
        }
    }

    func testAppBotNoticesNeedAnIncomingServerEvent() {
        var notice = F.notice("n", from: F.bot)
        XCTAssertTrue(ReportPolicy.mayReportMessage(notice, in: .appBot))
        XCTAssertEqual(ReportPolicy.messageRequest(roomID: room, item: notice, reason: nil, in: .appBot),
                       ReportPolicy.Request(roomID: room, target: .event("$n"), reason: "abuse"))
        for kind in [RoomKind.assistant, .person, .group] {
            XCTAssertFalse(ReportPolicy.mayReportMessage(notice, in: kind))
        }
        var excluded = [ChatItem]()
        notice.isOwn = true
        excluded.append(notice)
        notice.isOwn = false
        notice.isLocalEcho = true
        excluded.append(notice)
        notice.isLocalEcho = false
        for delivery in [ChatDelivery.sending(), .failed(isRecoverable: true)] {
            notice.delivery = delivery
            excluded.append(notice)
        }
        notice.delivery = .remote
        for ref in [ChatEventRef.transaction("local"), .event("invalid")] {
            notice.eventOrTransactionId = ref
            excluded.append(notice)
        }
        notice.eventOrTransactionId = nil
        excluded.append(notice)
        for item in excluded {
            XCTAssertFalse(ReportPolicy.mayReportMessage(item, in: .appBot))
            XCTAssertNil(ReportPolicy.messageRequest(roomID: room, item: item, reason: nil, in: .appBot))
            XCTAssertEqual(MessageMenuRules.items(for: item, in: .appBot), [])
        }
    }

    private func assertUnreportable(_ item: ChatItem, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(ReportPolicy.mayReportMessage(item), item.id, file: file, line: line)
        XCTAssertNil(ReportPolicy.messageRequest(roomID: room, item: item, reason: nil), file: file, line: line)
        for kind in RoomKind.allCases {
            XCTAssertFalse(ReportPolicy.mayReportMessage(item, in: kind), file: file, line: line)
            XCTAssertNil(ReportPolicy.messageRequest(roomID: room, item: item, reason: nil, in: kind), file: file, line: line)
            XCTAssertFalse(MessageMenuRules.items(for: item, in: kind).contains(.report),
                           "\(item.id) in \(kind)", file: file, line: line)
        }
    }

    func testTheMenuOffersReportForPeopleAssistantAnswersAndAppMessages() {
        let friend = F.text("t", from: F.friend, "Chào")
        XCTAssertEqual(MessageMenuRules.items(for: friend, in: .group),
                       [.react, .reply, .copy, .report])
        XCTAssertEqual(MessageMenuRules.items(for: F.mine("m", "Ok"), in: .person),
                       [.react, .reply, .copy, .edit, .delete], "never on my own")
        XCTAssertEqual(MessageMenuRules.items(for: F.text("a", from: F.agent, "Kết quả"), in: .assistant),
                       [.react, .reply, .copy, .selectText, .report])
        XCTAssertEqual(MessageMenuRules.items(for: F.text("b", from: F.bot, "Chào"), in: .appBot),
                       [.copy, .selectText, .report])
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
        XCTAssertEqual(ReportPolicy.messageRequest(roomID: room, item: item, reason: "  spam  "),
                       ReportPolicy.Request(roomID: room, target: .event("$t"), reason: "spam"))
        XCTAssertEqual(ReportPolicy.messageRequest(roomID: room, item: item, reason: nil)?.reason, ReportPolicy.defaultReason,
                       "no reason: the desktop's fixed protocol value")
        for sender in [F.agent, F.bot] {
            let message = F.text("bot-reply", from: sender, "private output")
            XCTAssertEqual(ReportPolicy.messageRequest(roomID: room, item: message, reason: "  unsafe  "),
                           ReportPolicy.Request(roomID: room, target: .event("$bot-reply"), reason: "unsafe"))
            XCTAssertEqual(ReportPolicy.messageRequest(roomID: room, item: message, reason: nil),
                           ReportPolicy.Request(roomID: room, target: .event("$bot-reply"), reason: ReportPolicy.defaultReason))
        }
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
