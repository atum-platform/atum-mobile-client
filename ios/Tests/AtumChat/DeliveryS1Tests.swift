import XCTest
@testable import AtumChat

/// Plan S1 T for B7, B8 and B10, updated for §9.1: a clock on every pending
/// item and a warning on failure; Seen where each reader's receipt sits (the
/// Element X model); "Đã gửi" only under my last unread settled message;
/// "Đã xem · N" in groups; the failure mapping by `isRecoverable`; the
/// two-minute no-answer rule with an injected clock.
final class DeliveryS1Tests: XCTestCase {
    private func read(_ item: ChatItem, by users: String...) -> ChatItem {
        var copy = item
        copy.receiptUserIDs = users.sorted()
        return copy
    }

    private func marks(_ items: [ChatItem], _ context: RoomContext = F.assistantRoom()) -> [DeliveryMark] {
        Projection.rows(items, context: context, options: .s1).filter { $0.item.kind.isEventContent }.map(\.delivery)
    }

    // MARK: B7

    /// Desktop `send-state.tsx`: Sent is `latest && message.sent`, `latest`
    /// being my newest message whatever its state (`latestOwnId`).
    func testOnlyMyNewestMessageShowsSentOnceSettledAndPendingOnesKeepTheirClock() {
        let items = [F.mine("q1"), F.echo("q2", delivery: .sent(eventID: "$q2")), F.echo("q3"), F.echo("q4")]
        XCTAssertEqual(marks(items), [.none, .none, .sending, .sending],
                       "older settled messages show nothing while newer ones send; three quick sends show three clocks")
        let settled = [F.mine("q1"), F.echo("q2", delivery: .sent(eventID: "$q2"))]
        XCTAssertEqual(marks(settled), [.none, .sent])
    }

    func testAFailedNewestSendShowsOnlyItsWarning() {
        let items = [F.mine("q1"), F.echo("q2", delivery: .failed(isRecoverable: true))]
        XCTAssertEqual(marks(items), [.none, .failed], "desktop: no Sent above a failed newest message")
    }

    // MARK: §9.1 Seen faces

    func testReadersComeInReceiptOrderWithTheProfileTheirMessagesCarry() {
        var lan = F.text("t", from: F.other)
        lan.senderName = "Lan"
        lan.senderAvatarURI = "mxc://example.test/lan"
        var item = F.mine("q")
        item.receiptUserIDs = [F.friend, F.me, F.other, F.friend]
        let group = RoomContext(kind: .group, ownUserID: F.me)
        let rows = Projection.rows([lan, item], context: group, options: .s1)
        let mine = rows.first { $0.id == "q" }
        XCTAssertEqual(mine?.delivery, .seen(readerCount: 2))
        XCTAssertEqual(mine?.readers, [ChatReader(userID: F.friend),
                                       ChatReader(userID: F.other, name: "Lan",
                                                  avatarURI: "mxc://example.test/lan")],
                       "my own receipt is dropped, each reader once, in the SDK's order")
        XCTAssertEqual(rows.first { $0.id == "t" }?.readers, [], "only a Seen row carries readers")
    }

    func testReceiptOrderIsDesktopsEarliestFirstThenByUserID() {
        XCTAssertEqual(Delivery.receiptOrder(["@c:x": 30, "@a:x": 20, "@b:x": 20, "@d:x": nil]),
                       ["@d:x", "@a:x", "@b:x", "@c:x"])
    }

    func testSeenSitsOnTheMessageWhoseReceiptItIs() {
        XCTAssertEqual(marks([read(F.mine("q"), by: F.agent)]), [.seen(readerCount: 1)])
        let answered = [F.mine("q"), read(F.text("a", from: F.agent), by: F.agent)]
        XCTAssertEqual(marks(answered), [.sent, .none],
                       "the reader's receipt sits on the answer, not on my earlier message")
        let older = [read(F.mine("q0"), by: F.agent), F.mine("q1")]
        XCTAssertEqual(marks(older), [.seen(readerCount: 1), .sent],
                       "each reader's avatar appears under the message their receipt names")
    }

    func testMyOwnReceiptsFromTheMacNeverCountAsSeen() {
        XCTAssertEqual(marks([read(F.mine("q"), by: F.me)]), [.sent])
    }

    func testAReceiptOnAHiddenRowIsNotMyMessagesReceipt() {
        let items = [F.mine("q"), read(ChatItem(id: "topic", kind: .roomState, sender: F.agent), by: F.agent)]
        XCTAssertEqual(marks(items), [.sent],
                       "a receipt on a later hidden row does not move back to my message")
    }

    func testGroupsCountEachReaderOncePeopleRoomsShowNoSent() {
        let group = RoomContext(kind: .group, ownUserID: F.me)
        let items = [read(F.mine("q"), by: F.other, F.friend), read(F.text("t", from: F.other), by: F.other)]
        XCTAssertEqual(marks(items, group), [.seen(readerCount: 2), .none])
        XCTAssertEqual(marks([F.mine("q")], F.personRoom()), [.sent],
                       "§9.1: Sent sits under the last unread message in every room")
        XCTAssertEqual(marks([read(F.mine("q"), by: F.friend)], F.personRoom()), [.seen(readerCount: 1)])
        XCTAssertEqual(marks([F.mine("q")], F.botRoom()), [.sent], "bot chats show Sent like assistants")
    }

    func testSettledMeansSentOrRemoteAndNoticesOrPlaceholdersNeverCarryIt() {
        var deleted = F.mine("d")
        deleted.kind = .placeholder(.redacted)
        XCTAssertEqual(marks([F.mine("q"), deleted]), [.sent, .none])
        XCTAssertEqual(marks([F.echo("q", delivery: .failed(isRecoverable: false))]), [.failed])
    }

    func testS1aOptionsStillEmitOnlyTheClockAndTheWarning() {
        let items = [F.mine("q1"), read(F.mine("q2"), by: F.agent), F.echo("q3")]
        XCTAssertEqual(Projection.rows(items, context: F.assistantRoom()).map(\.delivery), [.none, .none, .sending])
    }

    // MARK: B8

    func testRetryMapsRecoverableFailuresToTheRoomQueueAndParkedOnesToTheirRequest() {
        XCTAssertEqual(Delivery.retry(for: F.echo("e", delivery: .failed(isRecoverable: true))), .enableRoomQueue)
        XCTAssertEqual(Delivery.retry(for: F.echo("e", delivery: .failed(isRecoverable: false))),
                       .retryParkedRequest(.transaction("txn-e")))
        XCTAssertNil(Delivery.retry(for: F.echo("e")), "a pending send has nothing to retry")
        XCTAssertNil(Delivery.retry(for: F.mine("m")))
        var theirs = F.text("t", from: F.friend)
        theirs.delivery = .failed(isRecoverable: true)
        XCTAssertNil(Delivery.retry(for: theirs), "never someone else's message")
    }

    func testDeleteAbortsOnlyAFailedSendOfMine() {
        XCTAssertEqual(Delivery.abortTarget(for: F.echo("e", delivery: .failed(isRecoverable: true))),
                       .transaction("txn-e"))
        XCTAssertNil(Delivery.abortTarget(for: F.echo("e")))
        XCTAssertNil(Delivery.abortTarget(for: F.mine("m")))
    }

    // MARK: B10

    private func mine(_ id: String, minute: Int) -> ChatItem { F.mine(id, minute: minute) }

    func testNoAnswerShowsUnderMyNewestMessageAfterTwoMinutes() {
        let items = [mine("q", minute: 0)]
        let room = F.assistantRoom()
        XCTAssertNil(Delivery.noAnswerItemID(items, context: room, now: F.at(1)))
        XCTAssertEqual(Delivery.noAnswerItemID(items, context: room, now: F.at(2)), "q")
        XCTAssertEqual(Delivery.noAnswerDeadline(items, context: room, now: F.at(1)), F.at(2))
        XCTAssertNil(Delivery.noAnswerDeadline(items, context: room, now: F.at(2)), "already past")
    }

    func testAnAnswerClearsItButAWorkingOrWaitStateLineDoesNot() {
        let room = F.assistantRoom()
        let answered = [mine("q", minute: 0), F.text("a", from: F.agent, minute: 1)]
        XCTAssertNil(Delivery.noAnswerItemID(answered, context: room, now: F.at(30)))
        let working = [mine("q", minute: 0), F.notice("n", from: F.agent, "offline", replyTo: "$q")]
        XCTAssertEqual(Delivery.noAnswerItemID(working, context: room, now: F.at(30)), "q")
        let newerQuestion = [mine("q1", minute: 0), F.text("a", from: F.agent, minute: 1), mine("q2", minute: 2)]
        XCTAssertEqual(Delivery.noAnswerItemID(newerQuestion, context: room, now: F.at(12)), "q2")
    }

    func testNoAnswerOnlyInMyAssistantsChatAndOnlyForASettledMessage() {
        XCTAssertNil(Delivery.noAnswerItemID([mine("q", minute: 0)], context: F.personRoom(), now: F.at(60)))
        XCTAssertNil(Delivery.noAnswerItemID([F.echo("e")], context: F.assistantRoom(), now: F.at(60)),
                     "a message still sending shows its clock instead")
        XCTAssertNil(Delivery.noAnswerItemID([F.echo("e", delivery: .failed(isRecoverable: true))],
                                             context: F.assistantRoom(), now: F.at(60)))
    }

    func testTheProjectionSetsTheFlagOnlyWithAClockAndTheOption() {
        let items = [mine("q", minute: 0)]
        let flagged = Projection.rows(items, context: F.assistantRoom(), options: .s1, now: F.at(11))
        XCTAssertEqual(flagged.filter(\.showsNoAnswer).map(\.id), ["q"])
        XCTAssertEqual(flagged.first?.delivery, .sent, "Sent and the no-answer line show together")
        XCTAssertFalse(Projection.rows(items, context: F.assistantRoom(), options: .s1).contains(where: \.showsNoAnswer),
                       "no clock, no flag")
        XCTAssertFalse(Projection.rows(items, context: F.assistantRoom(), now: F.at(11)).contains(where: \.showsNoAnswer),
                       "S1a options never set it")
    }
}
