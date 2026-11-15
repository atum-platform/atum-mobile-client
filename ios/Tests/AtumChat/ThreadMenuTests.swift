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
}
