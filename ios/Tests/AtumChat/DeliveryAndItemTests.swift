import XCTest
@testable import AtumChat

/// Plan S1a T: a clock on every pending item, a warning on failure (B7), and
/// the plain-value rules the SDK mapper relies on.
final class DeliveryAndItemTests: XCTestCase {
    func testEveryPendingMessageShowsAClockSoThreeQuickSendsShowThree() {
        let rows = Projection.rows([F.echo("e1"), F.echo("e2"), F.echo("e3")], context: F.assistantRoom())
        XCTAssertEqual(rows.map(\.delivery), [.sending, .sending, .sending])
    }

    func testAFailedSendShowsAWarningWhateverItsRecoverability() {
        XCTAssertEqual(Delivery.mark(for: F.echo("e", delivery: .failed(isRecoverable: true))), .failed)
        XCTAssertEqual(Delivery.mark(for: F.echo("e", delivery: .failed(isRecoverable: false))), .failed)
    }

    func testSettledAndOtherPeoplesMessagesShowNothingInS1a() {
        XCTAssertEqual(Delivery.mark(for: F.echo("e", delivery: .sent(eventID: "$e"))), .none)
        XCTAssertEqual(Delivery.mark(for: F.mine("m")), .none)
        var theirs = F.text("t", from: F.friend)
        theirs.delivery = .sending()
        XCTAssertEqual(Delivery.mark(for: theirs), .none, "only my own messages carry a mark")
        XCTAssertEqual(Delivery.mark(for: ChatItem(id: "d", kind: .dayDivider(F.at(0)), isOwn: true,
                                                   delivery: .sending())), .none)
    }

    func testAnItemWithNoLocalSendStateIsSettledOnlyWhenRemote() {
        XCTAssertEqual(ChatDelivery.resolve(nil, isRemote: true), .remote)
        XCTAssertEqual(ChatDelivery.resolve(nil, isRemote: false), .sending())
        XCTAssertEqual(ChatDelivery.resolve(.failed(isRecoverable: false), isRemote: false), .failed(isRecoverable: false))
        XCTAssertEqual(ChatDelivery.resolve(.sent(eventID: "$x"), isRemote: true), .sent(eventID: "$x"))
    }

    func testResultForIsATextAnswerFromTheRoomsAgentOrBot() {
        let agents: Set<String> = [F.agent]
        XCTAssertEqual(ChatItem.resultFor(kind: .message, sender: F.agent, replyTo: "$q", agentUserIDs: agents), "$q")
        XCTAssertNil(ChatItem.resultFor(kind: .notice, sender: F.agent, replyTo: "$q", agentUserIDs: agents))
        XCTAssertNil(ChatItem.resultFor(kind: .message, sender: F.friend, replyTo: "$q", agentUserIDs: agents))
        XCTAssertNil(ChatItem.resultFor(kind: .message, sender: F.agent, replyTo: nil, agentUserIDs: agents))
    }

    func testLocalEchoComesFromThisDeviceNeverFromIsOwnAlone() {
        XCTAssertTrue(ChatItem.isLocalEcho(originIsLocal: true, hasLocalSendState: false, hasTransactionID: false))
        XCTAssertTrue(ChatItem.isLocalEcho(originIsLocal: false, hasLocalSendState: true, hasTransactionID: false))
        XCTAssertTrue(ChatItem.isLocalEcho(originIsLocal: false, hasLocalSendState: false, hasTransactionID: true))
        XCTAssertFalse(ChatItem.isLocalEcho(originIsLocal: false, hasLocalSendState: false, hasTransactionID: false))
    }

    func testThePillCountsContentFromAnyoneButThisDeviceAndNoNotices() {
        XCTAssertTrue(F.text("t", from: F.agent).countsAsNewMessage)
        XCTAssertTrue(F.mine("m").countsAsNewMessage, "my message from the Mac counts")
        XCTAssertFalse(F.echo("e").countsAsNewMessage)
        XCTAssertFalse(F.notice("n", from: F.agent).countsAsNewMessage)
        XCTAssertFalse(F.divider("d").countsAsNewMessage)
        XCTAssertTrue(ChatItem(id: "i", kind: .image(width: 10, height: 10), sender: F.friend).countsAsNewMessage)
    }

    func testEventIDOnlyOnceTheServerHasIt() {
        XCTAssertEqual(F.mine("m").eventID, "$m")
        XCTAssertNil(F.echo("e").eventID)
        XCTAssertNil(F.echo("e", delivery: .failed(isRecoverable: true)).eventID)
        XCTAssertEqual(F.echo("e", delivery: .sent(eventID: "$e")).eventID, "$e",
                       "accepted by the server, not yet replaced by its remote copy")
    }

    func testS1aNeverEmitsTheS1bMarks() {
        let items = [F.echo("e1"), F.echo("e2", delivery: .sent(eventID: "$e2")), F.mine("m"),
                     F.echo("e3", delivery: .failed(isRecoverable: false))]
        let marks = Projection.rows(items, context: F.assistantRoom()).map(\.delivery)
        XCTAssertEqual(marks, [.sending, .none, .none, .failed])
        XCTAssertFalse(Projection.rows(items, context: F.assistantRoom()).contains(where: \.showsNoAnswer))
    }
}
