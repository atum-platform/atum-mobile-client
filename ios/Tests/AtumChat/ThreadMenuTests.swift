import XCTest
@testable import AtumChat

/// TS-6b: "Reply in thread" (desktop `onThread`) is offered only where the room
/// has threads, only on a server message, and never on a thread reply.
final class ThreadMenuTests: XCTestCase {
    func testTeamSpaceRoomsOfferReplyInThreadAfterReply() {
        let message = F.text("t", from: F.friend, "Chào")
        XCTAssertEqual(MessageMenuRules.items(for: message, in: .group, threads: true),
                       [.react, .reply, .replyInThread, .copy, .report])
        XCTAssertEqual(MessageMenuRules.items(for: F.mine("m", "Ok"), in: .group, threads: true),
                       [.react, .reply, .replyInThread, .copy, .edit, .delete])
        XCTAssertEqual(MessageMenuRules.threadRootID(for: message), "$t")
    }

    func testOtherRoomsNeverOfferIt() {
        let message = F.text("t", from: F.friend, "Chào")
        XCTAssertEqual(MessageMenuRules.items(for: message, in: .group), [.react, .reply, .copy, .report])
        XCTAssertFalse(MessageMenuRules.items(for: F.text("a", from: F.bot, "Hi"), in: .appBot, threads: true)
            .contains(.replyInThread))
    }

    func testPersonalRoomThreadAndPinScope() {
        typealias Scope = MessageMenuRules.SharedChatActions
        let group = Scope(kind: .group, isDirect: false, activeMemberCount: 3, isOrdinaryRoom: true)
        XCTAssertTrue(group.offersThreads)
        XCTAssertTrue(group.offersPins)
        let invitedAssistant = F.text("answer", from: F.agent, "Reply here")
        XCTAssertTrue(MessageMenuRules.items(for: invitedAssistant, in: .group, threads: group.offersThreads)
            .contains(.replyInThread))

        // Use the roster's direct distinction even for a two-person group
        // or a former direct room that now has a third (invited) member.
        XCTAssertEqual(Scope(kind: .person, isDirect: false, activeMemberCount: 2, isOrdinaryRoom: true), .peopleGroup)
        XCTAssertEqual(Scope(kind: .group, isDirect: true, activeMemberCount: 3, isOrdinaryRoom: true), .peopleGroup)
        let person = Scope(kind: .person, isDirect: true, activeMemberCount: 2, isOrdinaryRoom: true)
        XCTAssertFalse(person.offersThreads)
        XCTAssertTrue(person.offersPins)
        for kind in [RoomKind.assistant, .appBot] {
            XCTAssertEqual(Scope(kind: kind, isDirect: true, activeMemberCount: 2, isOrdinaryRoom: true), .unavailable)
        }
        XCTAssertEqual(Scope(kind: .person, isDirect: false, activeMemberCount: 1, isOrdinaryRoom: false), .unavailable)
        XCTAssertEqual(Scope(kind: .person, isDirect: true, activeMemberCount: 2,
                             isOrdinaryRoom: false, isTeamSpace: true), .teamSpace)
    }

    func testSharedPinsRequireEligibleRoomPowerAndSettledMessage() {
        let reply = F.text("reply", from: F.agent, "Reply", threadRoot: "$root")
        XCTAssertEqual(MessageMenuRules.pinEventID(for: reply, in: .peopleGroup, canChange: true), "$reply")
        XCTAssertEqual(MessageMenuRules.pinEventID(for: F.mine("own", "Decision"), in: .peopleDM, canChange: true), "$own")
        XCTAssertNil(MessageMenuRules.pinEventID(for: reply, in: .peopleGroup, canChange: false))
        XCTAssertNil(MessageMenuRules.pinEventID(for: reply, in: .unavailable, canChange: true))
        XCTAssertNil(MessageMenuRules.pinEventID(for: F.echo("local"), in: .peopleGroup, canChange: true))
        XCTAssertTrue(MessageMenuRules.isPinEventID("$history:example.test"))
        for invalid in ["$", "$contains a space", "$contains\na newline", "local"] {
            XCTAssertFalse(MessageMenuRules.isPinEventID(invalid))
        }
    }

    func testReportOfAThreadReplyTargetsTheReplyEvent() {
        for sender in [F.friend, F.agent, F.bot] {
            let reply = F.text("reply", from: sender, "Trong chuỗi", replyTo: "$quoted", threadRoot: "$root")
            XCTAssertTrue(ReportPolicy.mayReportMessage(reply))
            XCTAssertTrue(MessageMenuRules.items(for: reply, in: .group, threads: true).contains(.report))
            XCTAssertEqual(ReportPolicy.messageRequest(roomID: "!thread:example.test", item: reply, reason: "spam"),
                           ReportPolicy.Request(roomID: "!thread:example.test", target: .event("$reply"), reason: "spam"),
                           "report the reply, not its thread root or quoted event")
        }
        var own = F.mine("own", "Trong chuỗi")
        own.threadRoot = "$root"
        XCTAssertFalse(ReportPolicy.mayReportMessage(own))
        XCTAssertNil(ReportPolicy.messageRequest(roomID: "!thread:example.test", item: own, reason: nil))
    }

    func testNoNestedThreadsAndNoLocalEchoRoots() {
        let reply = F.text("r", from: F.friend, "Trong chuỗi", threadRoot: "$root")
        XCTAssertNil(MessageMenuRules.threadRootID(for: reply))
        XCTAssertFalse(MessageMenuRules.items(for: reply, in: .group, threads: true).contains(.replyInThread))
        XCTAssertNil(MessageMenuRules.threadRootID(for: F.echo("e")), "a send the server has not taken")
        XCTAssertNil(MessageMenuRules.threadRootID(for: F.notice("n", from: F.friend)))
        let sent = F.echo("s", delivery: .sent(eventID: "$sent"))
        XCTAssertEqual(MessageMenuRules.threadRootID(for: sent), "$sent", "my phone's message once the server has it")
    }

    // MARK: S5 menu contract (ML1 UI; ML6 inserts forward after pin/unpin)

    private func pins(_ ids: Set<String> = [], scope: MessageMenuRules.SharedChatActions = .peopleGroup,
                      canChange: Bool = true, awaitingSync: Bool = false) -> PinMenuContext {
        PinMenuContext(scope: scope, pinnedEventIDs: ids, canChange: canChange, awaitingSync: awaitingSync)
    }

    func testGroupMenuOrderMatchesM2() {
        let answer = F.text("answer", from: F.agent, "Three that fit")
        XCTAssertEqual(MessageMenuRules.items(for: answer, in: .group, threads: true, pins: pins()),
                       [.react, .reply, .replyInThread, .copy, .pin, .report])
        XCTAssertEqual(MessageMenuRules.items(for: F.mine("m", "Ok"), in: .group, threads: true,
                                              pins: pins(["$m"])),
                       [.react, .reply, .replyInThread, .copy, .unpin, .edit, .delete])
    }

    func testPeopleDMOffersPinsButNoThreads() {
        let message = F.text("t", from: F.friend, "Chào")
        XCTAssertEqual(MessageMenuRules.items(for: message, in: .person, pins: pins(scope: .peopleDM)),
                       [.react, .reply, .copy, .pin, .report])
    }

    func testDemotedOrIneligibleChatsLoseThePinAction() {
        let message = F.text("t", from: F.friend, "Chào")
        XCTAssertFalse(MessageMenuRules.items(for: message, in: .group, threads: true, pins: pins(canChange: false))
            .contains(.pin), "read-only after demotion")
        XCTAssertFalse(MessageMenuRules.items(for: message, in: .assistant, pins: pins(scope: .unavailable))
            .contains(.pin), "assistant DMs stay flat")
        XCTAssertFalse(MessageMenuRules.items(for: F.text("a", from: F.bot, "Hi"), in: .appBot,
                                              pins: pins(scope: .peopleGroup)).contains(.pin))
        XCTAssertFalse(MessageMenuRules.items(for: F.echo("local"), in: .group, pins: pins()).contains(.pin),
                       "an unsent row has no event to pin")
        XCTAssertFalse(MessageMenuRules.items(for: message, in: .group).contains(.pin), "no snapshot yet")
    }

    func testPendingPinWriteDisablesOnlyPinActions() {
        let pending = pins(awaitingSync: true)
        let message = F.text("t", from: F.friend, "Chào")
        XCTAssertTrue(MessageMenuRules.items(for: message, in: .group, pins: pending).contains(.pin),
                      "still shown, so the menu does not jump")
        XCTAssertFalse(MessageMenuRules.isEnabled(.pin, pins: pending))
        XCTAssertFalse(MessageMenuRules.isEnabled(.unpin, pins: pending))
        XCTAssertTrue(MessageMenuRules.isEnabled(.pin, pins: pins()))
        XCTAssertFalse(MessageMenuRules.isEnabled(.pin, pins: nil))
        XCTAssertTrue(MessageMenuRules.isEnabled(.reply, pins: pending))
    }

    func testThreadReplyPinsTheReplyNotItsRoot() {
        let reply = F.text("reply", from: F.agent, "Proof promised", threadRoot: "$root")
        XCTAssertEqual(MessageMenuRules.pinItem(for: reply, pins: pins(["$root"])), .pin)
        XCTAssertEqual(MessageMenuRules.pinItem(for: reply, pins: pins(["$reply"])), .unpin)
        XCTAssertFalse(MessageMenuRules.items(for: reply, in: .group, threads: true, pins: pins())
            .contains(.replyInThread))
    }
}
