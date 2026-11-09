import XCTest
@testable import AtumChat

/// Plan S1a T for the projection: hidden virtual items, a `set` after a
/// hidden row, superseded working lines (B17), `showsQuote` judged after
/// hiding (B21), the sender line (B16, S1a form), typing and loading rows.
final class ProjectionTests: XCTestCase {
    // MARK: Hiding

    func testS1aHidesEveryVirtualItem() {
        let items = [F.start(), F.divider("d1"), F.mine("q"), F.readMarker(), F.text("a", from: F.agent)]
        XCTAssertEqual(F.ids(Projection.rows(items, context: F.assistantRoom())), ["q", "a"])
    }

    func testS1bOptionsShowVirtualItemsButNeverATrailingReadMarker() {
        let all = ProjectionOptions(showsDayDividers: true, showsReadMarker: true, showsTimelineStart: true)
        let items = [F.start(), F.divider("d1"), F.mine("q"), F.readMarker(), F.text("a", from: F.agent)]
        XCTAssertEqual(F.ids(Projection.rows(items, context: F.assistantRoom(), options: all)),
                       ["start", "d1", "q", "read-marker", "a"])
        let trailing = [F.mine("q"), F.readMarker()]
        XCTAssertEqual(F.ids(Projection.rows(trailing, context: F.assistantRoom(), options: all)), ["q"],
                       "B15: the read marker is hidden when it would be the last row")
        XCTAssertEqual(F.ids(Projection.rows(trailing, context: F.assistantRoom(), typingNames: ["Atum"], options: all)),
                       ["q", Projection.typingRowID], "the typing row does not keep a trailing marker alive")
    }

    func testADayWhoseRowsAreAllHiddenShowsNoDivider() {
        let all = ProjectionOptions(showsDayDividers: true, showsReadMarker: true, showsTimelineStart: true)
        let created = ChatItem(id: "create", kind: .roomState, sender: F.agent)
        let items = [F.start(), F.divider("d1"), created, F.divider("d2"), F.mine("m")]
        XCTAssertEqual(F.ids(Projection.rows(items, context: F.assistantRoom(), options: all)), ["start", "d2", "m"])
        let superseded = [F.divider("d1"), F.mine("q"), F.divider("d2"),
                          F.notice("n", from: F.agent, replyTo: "$q"), F.readMarker(),
                          F.divider("d3"), F.text("a", from: F.agent, replyTo: "$q")]
        XCTAssertEqual(F.ids(Projection.rows(superseded, context: F.assistantRoom(), options: all)),
                       ["d1", "q", "read-marker", "d3", "a"],
                       "a day holding only a hidden working line and the marker loses its divider")
        XCTAssertEqual(F.ids(Projection.rows([F.mine("q"), F.divider("d"), F.readMarker()],
                                             context: F.assistantRoom(), options: all)), ["q"],
                       "an empty trailing day takes the trailing marker with it")
    }

    func testRoomStateEventsAreAlwaysHiddenButKeepTheirIndex() throws {
        let all = ProjectionOptions(showsDayDividers: true, showsReadMarker: true, showsTimelineStart: true)
        var buffer = TimelineBuffer()
        try buffer.apply([.reset([ChatItem(id: "create", kind: .roomState, sender: F.agent), F.mine("q"),
                                  ChatItem(id: "topic", kind: .roomState, sender: F.agent),
                                  F.text("a", from: F.agent, "v1")])])
        XCTAssertEqual(F.ids(Projection.rows(buffer.items, context: F.assistantRoom(), options: all)), ["q", "a"])
        try buffer.apply([.set(index: 3, item: F.text("a", from: F.agent, "v2"))])
        XCTAssertEqual(Projection.rows(buffer.items, context: F.assistantRoom()).last?.item.body, "v2")
        XCTAssertFalse(ChatItem(id: "s", kind: .roomState, sender: F.agent).countsAsNewMessage)
    }

    func testASetAfterAHiddenRowUpdatesTheRightRow() throws {
        var buffer = TimelineBuffer()
        try buffer.apply([.reset([F.mine("q"), F.divider("d"), F.notice("n", from: F.agent, replyTo: "$q"),
                                  F.text("a", from: F.agent, "first", replyTo: "$q")])])
        let before = Projection.rows(buffer.items, context: F.assistantRoom())
        XCTAssertEqual(F.ids(before), ["q", "a"])

        try buffer.apply([.set(index: 3, item: F.text("a", from: F.agent, "second", replyTo: "$q"))])
        let after = Projection.rows(buffer.items, context: F.assistantRoom())
        XCTAssertEqual(F.ids(after), ["q", "a"])
        XCTAssertEqual(after[1].item.body, "second")
        XCTAssertEqual(after[0], before[0], "the row before the hidden ones is untouched")
    }

    // MARK: Superseded working lines (B17)

    func testAWorkingNoticeIsHiddenOnceTheSameAgentsAnswerToTheSameMessageArrives() {
        let working = [F.mine("q"), F.notice("n", from: F.agent, "Đang xử lý…", replyTo: "$q")]
        XCTAssertEqual(F.ids(Projection.rows(working, context: F.assistantRoom())), ["q", "n"],
                       "while the agent works, the line shows")
        let answered = working + [F.text("a", from: F.agent, replyTo: "$q")]
        XCTAssertEqual(F.ids(Projection.rows(answered, context: F.assistantRoom())), ["q", "a"])
    }

    func testAWaitStateLineWithNoAnswerStays() {
        let items = [F.mine("q1"), F.notice("wait", from: F.agent, "offline", replyTo: "$q1"),
                     F.mine("q2"), F.text("a2", from: F.agent, replyTo: "$q2")]
        XCTAssertEqual(F.ids(Projection.rows(items, context: F.assistantRoom())), ["q1", "wait", "q2", "a2"])
        XCTAssertFalse(Projection.isSuperseded(items[1], in: items, context: F.assistantRoom()))
    }

    func testTheRuleIsStructuralNotByText() {
        let room = F.assistantRoom()
        let q = F.mine("q")
        // Another sender's answer, a notice answer, an answer to another
        // event, or a notice that replies to nothing: the line stays.
        let cases: [[ChatItem]] = [
            [q, F.notice("n", from: F.agent, replyTo: "$q"), F.text("a", from: F.friend, replyTo: "$q")],
            [q, F.notice("n", from: F.agent, replyTo: "$q"), F.notice("a", from: F.agent, replyTo: "$q")],
            [q, F.notice("n", from: F.agent, replyTo: "$q"), F.text("a", from: F.agent, replyTo: "$other")],
            [q, F.notice("n", from: F.agent), F.text("a", from: F.agent, replyTo: "$q")],
        ]
        for items in cases {
            XCTAssertTrue(F.ids(Projection.rows(items, context: room)).contains("n"), "\(F.ids(items))")
        }
    }

    func testNoticesFromSomeoneWhoIsNotTheRoomsAgentAreNeverHidden() {
        let items = [F.mine("q"), F.notice("n", from: F.friend, replyTo: "$q"),
                     F.text("a", from: F.friend, replyTo: "$q")]
        XCTAssertEqual(F.ids(Projection.rows(items, context: F.personRoom())), ["q", "n", "a"])
    }

    func testABotsWorkingLineIsHiddenToo() {
        let items = [F.mine("q"), F.notice("n", from: F.bot, replyTo: "$q"), F.text("a", from: F.bot, replyTo: "$q")]
        XCTAssertEqual(F.ids(Projection.rows(items, context: F.botRoom())), ["q", "a"])
    }

    // MARK: showsQuote (B21, desktop's rule after hiding)

    private func quote(_ id: String, in rows: [ChatRow]) -> Bool {
        rows.first(where: { $0.id == id })!.showsQuote
    }

    func testAnAgentAnswerDirectlyUnderItsQuestionShowsNoQuote() {
        let rows = Projection.rows([F.mine("q"), F.text("a", from: F.agent, replyTo: "$q")], context: F.assistantRoom())
        XCTAssertFalse(quote("a", in: rows))
    }

    func testDirectlyUnderIsJudgedAfterTheWorkingLineIsHidden() {
        let items = [F.mine("q"), F.notice("n", from: F.agent, replyTo: "$q"), F.text("a", from: F.agent, replyTo: "$q")]
        XCTAssertFalse(quote("a", in: Projection.rows(items, context: F.assistantRoom())))
    }

    func testAVisibleRowInBetweenBringsTheQuoteBack() {
        let items = [F.mine("q1"), F.mine("q2"), F.text("a", from: F.agent, replyTo: "$q1")]
        XCTAssertTrue(quote("a", in: Projection.rows(items, context: F.assistantRoom())))
        let afterWaitLine = [F.mine("q"), F.notice("wait", from: F.agent, replyTo: "$other"),
                             F.text("a", from: F.agent, replyTo: "$q")]
        XCTAssertTrue(quote("a", in: Projection.rows(afterWaitLine, context: F.assistantRoom())))
    }

    func testVirtualRowsInBetweenDoNotCount() {
        let all = ProjectionOptions(showsDayDividers: true, showsReadMarker: true, showsTimelineStart: true)
        let items = [F.mine("q"), F.divider("d"), F.readMarker(), F.text("a", from: F.agent, replyTo: "$q")]
        XCTAssertFalse(quote("a", in: Projection.rows(items, context: F.assistantRoom(), options: all)))
    }

    func testAnAnswerUnderMyAcceptedEchoShowsNoQuote() {
        // The echo still has its transaction ID, but `.sent` carries the event ID.
        let echo = F.echo("q", delivery: .sent(eventID: "$q"))
        let rows = Projection.rows([echo, F.text("a", from: F.agent, replyTo: "$q")], context: F.assistantRoom())
        XCTAssertFalse(quote("a", in: rows))
    }

    func testAPersonsReplyAlwaysShowsItsQuote() {
        let items = [F.mine("q"), F.text("r", from: F.friend, replyTo: "$q")]
        XCTAssertTrue(quote("r", in: Projection.rows(items, context: F.personRoom())))
        let mine = [F.text("t", from: F.friend), F.mine("m", replyTo: "$t")]
        XCTAssertTrue(quote("m", in: Projection.rows(mine, context: F.personRoom())))
    }

    func testAThreadMessageAlwaysShowsItsQuote() {
        let items = [F.mine("q"), F.text("a", from: F.agent, replyTo: "$q", threadRoot: "$q")]
        XCTAssertTrue(quote("a", in: Projection.rows(items, context: F.assistantRoom())))
    }

    func testDeletedOrUndecryptableRowsAndRowsWithoutAReplyNeverQuote() {
        var redacted = F.text("x", from: F.friend, replyTo: "$q1")
        redacted.kind = .placeholder(.redacted)
        var utd = F.text("y", from: F.friend, replyTo: "$q1")
        utd.kind = .placeholder(.undecryptable)
        let items = [F.mine("q1"), F.mine("q2"), redacted, utd, F.text("z", from: F.friend)]
        let rows = Projection.rows(items, context: F.personRoom())
        XCTAssertFalse(quote("x", in: rows))
        XCTAssertFalse(quote("y", in: rows))
        XCTAssertFalse(quote("z", in: rows))
    }

    // MARK: Sender line (B16, S1a form)

    private func senders(_ rows: [ChatRow]) -> [String] {
        rows.filter(\.showsSender).map(\.id)
    }

    func testTheOwnAssistantChatNeverShowsASenderLine() {
        let items = [F.mine("q"), F.text("a", from: F.agent), F.mine("q2"), F.text("a2", from: F.agent)]
        XCTAssertEqual(senders(Projection.rows(items, context: F.assistantRoom())), [])
    }

    func testGroupRoomsShowItWhereTheSenderChangesAndAnAppsChatNever() {
        let bot = [F.text("b1", from: F.bot), F.text("b2", from: F.bot), F.mine("q"), F.text("b3", from: F.bot)]
        XCTAssertEqual(senders(Projection.rows(bot, context: F.groupWithApp())), ["b1", "b3"])
        XCTAssertEqual(senders(Projection.rows(bot, context: F.botRoom())), [],
                       "owner, 2026-11-05: an app's chat matches a person's and my assistant's")
        let group = RoomContext(kind: .group, ownUserID: F.me)
        let items = [F.text("f1", from: F.friend), F.text("o1", from: F.other), F.text("o2", from: F.other),
                     F.text("f2", from: F.friend)]
        XCTAssertEqual(senders(Projection.rows(items, context: group)), ["f1", "o1", "f2"])
    }

    /// Coordinator decision 3 (2026-10-10): §2.7 wins over B16's S1a text. A
    /// 1:1 people chat has one other sender, so its left bubbles carry no
    /// name, with or without runs.
    func testAOneToOnePeopleChatNeverShowsASenderLine() {
        let items = [F.text("f1", from: F.friend), F.mine("q"), F.text("f2", from: F.friend, minute: 30)]
        XCTAssertEqual(senders(Projection.rows(items, context: F.personRoom())), [])
        XCTAssertEqual(senders(Projection.rows(items, context: F.personRoom(), options: .s1)), [])
        XCTAssertEqual(RoomKind.allCases.filter(\.showsSenderLine), [.group])
    }

    func testNoticesNeitherShowNorBreakTheLineAndADayDividerRestartsIt() {
        let all = ProjectionOptions(showsDayDividers: true, showsReadMarker: false, showsTimelineStart: false)
        let items = [F.text("b1", from: F.bot), F.notice("n", from: F.bot), F.text("b2", from: F.bot),
                     F.divider("d"), F.text("b3", from: F.bot)]
        XCTAssertEqual(senders(Projection.rows(items, context: F.groupWithApp(), options: all)), ["b1", "b3"])
    }

    // MARK: Synthetic rows and markers

    func testTypingIsTheLastRowAndLoadingTheFirst() {
        let rows = Projection.rows([F.mine("q")], context: F.assistantRoom(), typingNames: ["Atum"],
                                   isLoadingEarlier: true)
        XCTAssertEqual(F.ids(rows), [Projection.loadingEarlierRowID, "q", Projection.typingRowID])
        XCTAssertEqual(rows.last?.item.kind, .typing(names: ["Atum"]))
        XCTAssertEqual(rows.last?.accessibilityID, AccessibilityID.rowTyping)
        XCTAssertEqual(F.ids(Projection.rows([F.mine("q")], context: F.assistantRoom())), ["q"])
    }

    func testTheNewestEventRowIsLatestNotTheTypingRow() {
        let rows = Projection.rows([F.mine("q"), F.text("a", from: F.agent)], context: F.assistantRoom(),
                                   typingNames: ["Atum"])
        XCTAssertEqual(rows.filter(\.isLatest).map(\.id), ["a"])
        XCTAssertEqual(rows.map(\.accessibilityID), ["row.q", AccessibilityID.rowLatest, AccessibilityID.rowTyping])
    }

    func testEachRowCarriesItsDeliveryMark() {
        let rows = Projection.rows([F.echo("e1"), F.echo("e2", delivery: .failed(isRecoverable: true)), F.mine("m")],
                                   context: F.assistantRoom())
        XCTAssertEqual(rows.map(\.delivery), [.sending, .failed, .none])
    }

    func testSnapshotCarriesTheBuffersChangeAndGeneration() throws {
        var buffer = TimelineBuffer()
        let change = try buffer.apply([.reset([F.mine("q")])])
        let snapshot = Projection.snapshot(buffer: buffer, change: change, generation: 7, context: F.assistantRoom())
        XCTAssertEqual(snapshot.change, .reset)
        XCTAssertEqual(snapshot.generation, 7)
        XCTAssertEqual(F.ids(snapshot.rows), ["q"])
    }
}
