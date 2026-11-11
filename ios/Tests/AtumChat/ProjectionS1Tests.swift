import XCTest
@testable import AtumChat

/// Plan S1 T for the projection's S1 options and the projector: virtual items
/// shown, the read-marker position kept, the sender line at a run's start,
/// the projector's change, generation, sequence and no-answer deadline, and
/// the reply-detail states.
final class ProjectionS1Tests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testS1ShowsEveryVirtualItemAndTheReadMarkerKeepsItsPosition() throws {
        var buffer = TimelineBuffer()
        try buffer.apply([.reset([F.start(), F.divider("d"), F.mine("q", minute: 0), F.readMarker(),
                                  F.text("a", from: F.agent, minute: 1)])])
        let rows = Projection.rows(buffer.items, context: F.assistantRoom(), options: .s1, calendar: utc)
        XCTAssertEqual(F.ids(rows), ["start", "d", "q", "read-marker", "a"])
        // New messages arrive below the marker: it stays where the SDK put it.
        try buffer.apply([.pushBack(F.text("b", from: F.agent, minute: 2)), .pushBack(F.text("c", from: F.agent, minute: 3))])
        let later = Projection.rows(buffer.items, context: F.assistantRoom(), options: .s1, calendar: utc)
        XCTAssertEqual(F.ids(later), ["start", "d", "q", "read-marker", "a", "b", "c"])
    }

    func testWithRunsTheSenderLineFollowsTheFiveMinuteGapNotOnlyASenderChange() {
        let items = [F.text("b1", from: F.bot, minute: 0), F.text("b2", from: F.bot, minute: 2),
                     F.text("b3", from: F.bot, minute: 30)]
        let s1a = Projection.rows(items, context: F.groupWithApp(), calendar: utc)
        XCTAssertEqual(s1a.filter(\.showsSender).map(\.id), ["b1"], "S1a: only where the sender changes")
        let s1 = Projection.rows(items, context: F.groupWithApp(), options: .s1, calendar: utc)
        XCTAssertEqual(s1.filter(\.showsSender).map(\.id), ["b1", "b3"], "S1: at the start of every run")
    }

    func testEveryRowCarriesItsRunLayoutIncludingSyntheticOnes() {
        let items = [F.mine("q", minute: 0), F.text("a", from: F.agent, minute: 1)]
        let rows = Projection.rows(items, context: F.assistantRoom(), typingNames: ["Atum"],
                                   isLoadingEarlier: true, options: .s1, calendar: utc)
        XCTAssertEqual(rows.map(\.grouping.position), [nil, .single, .single, nil])
        XCTAssertEqual(rows.map(\.grouping), Grouping.layout(rows, context: F.assistantRoom(), calendar: utc),
                       "the row's layout is Grouping's, on the display rows")
    }

    func testWithRunsTheSenderLineIsTheLayoutsAndTheRunTimeRidesOnItsRow() {
        let items = [F.text("b1", from: F.bot, minute: 0), F.text("b2", from: F.bot, minute: 2),
                     F.text("b3", from: F.bot, minute: 90)]
        let rows = Projection.rows(items, context: F.groupWithApp(), options: .s1, calendar: utc)
        XCTAssertEqual(rows.map(\.showsSender), rows.map(\.grouping.showsSender))
        XCTAssertEqual(rows.map(\.showsSender), [true, false, true])
        XCTAssertEqual(rows.map(\.grouping.position), [.first, .last, .single])
        XCTAssertEqual(rows.map(\.grouping.showsTime), [false, true, true], "under each run's last bubble")
    }

    // MARK: TimelineProjector

    func testTheProjectorCarriesTheChangeGenerationAndAGrowingSequence() throws {
        var projector = TimelineProjector(generation: 3, context: F.assistantRoom(), calendar: utc)
        let first = try projector.apply([.reset([F.mine("q", minute: 0)])], now: F.at(1))
        XCTAssertEqual(first.snapshot.change, .reset)
        XCTAssertEqual(first.snapshot.generation, 3)
        let second = try projector.apply([.pushBack(F.text("a", from: F.agent, minute: 1))], now: F.at(1))
        XCTAssertEqual(second.snapshot.change, .appendedAtEnd(count: 1, localEcho: false))
        XCTAssertGreaterThan(second.sequence, first.sequence)
        XCTAssertEqual(F.ids(second.snapshot.rows), ["q", "a"])
    }

    func testAFailedBatchLeavesTheProjectorAsItWas() throws {
        var projector = TimelineProjector(generation: 1, context: F.assistantRoom(), calendar: utc)
        _ = try projector.apply([.reset([F.mine("q")])], now: F.at(0))
        XCTAssertThrowsError(try projector.apply([.pushBack(F.mine("x")), .remove(index: 9)], now: F.at(0)))
        XCTAssertEqual(F.ids(projector.buffer.items), ["q"])
    }

    func testTypingAndLoadingReprojectInPlace() throws {
        var projector = TimelineProjector(generation: 1, context: F.assistantRoom(), calendar: utc)
        _ = try projector.apply([.reset([F.mine("q", minute: 0)])], now: F.at(0))
        projector.typingNames = ["Atum"]
        projector.isLoadingEarlier = true
        let pass = projector.project(now: F.at(0))
        XCTAssertEqual(pass.snapshot.change, .inPlace)
        XCTAssertEqual(F.ids(pass.snapshot.rows), [Projection.loadingEarlierRowID, "q", Projection.typingRowID])
    }

    func testTheProjectorReportsWhenTheNoAnswerFlagWillFlip() throws {
        var projector = TimelineProjector(generation: 1, context: F.assistantRoom(), calendar: utc)
        let waiting = try projector.apply([.reset([F.mine("q", minute: 0)])], now: F.at(1))
        XCTAssertEqual(waiting.nextNoAnswerChange, F.at(2))
        XCTAssertFalse(waiting.snapshot.rows.contains(where: \.showsNoAnswer))
        let flipped = projector.project(now: F.at(2))
        XCTAssertEqual(flipped.snapshot.rows.filter(\.showsNoAnswer).map(\.id), ["q"])
        XCTAssertNil(flipped.nextNoAnswerChange)
        let answered = try projector.apply([.pushBack(F.text("a", from: F.agent, minute: 3))], now: F.at(3))
        XCTAssertFalse(answered.snapshot.rows.contains(where: \.showsNoAnswer))
    }

    /// B10: dots come only from a real `m.typing` (the typing names the
    /// room's listener reports), never from time passing or an unanswered
    /// message; the two-minute line is the only thing time adds, and it gives
    /// way while someone is typing. The dots still show after the line would
    /// have appeared, as on desktop (`cloudQuietMs`: "real m.typing from the
    /// agent still shows").
    func testDotsComeOnlyFromRealTypingNeverFromTimePassing() throws {
        var projector = TimelineProjector(generation: 1, context: F.assistantRoom(), calendar: utc)
        _ = try projector.apply([.reset([F.mine("q", minute: 0)])], now: F.at(0))
        for minute in [0, 1, 2, 5, 15, 60] {
            let pass = projector.project(now: F.at(minute))
            XCTAssertFalse(pass.snapshot.rows.contains { if case .typing = $0.item.kind { true } else { false } },
                           "no invented dots at minute \(minute)")
            XCTAssertEqual(pass.snapshot.rows.contains(where: \.showsNoAnswer), minute >= 2, "minute \(minute)")
        }
        projector.typingNames = ["Atum"]
        let typing = projector.project(now: F.at(15))
        XCTAssertEqual(typing.snapshot.rows.last?.item.kind, .typing(names: ["Atum"]))
        XCTAssertFalse(typing.snapshot.rows.contains(where: \.showsNoAnswer), "the line waits for the dots to end")
        XCTAssertNil(typing.nextNoAnswerChange, "no flip while typing")
        projector.typingNames = []
        let ended = projector.project(now: F.at(16))
        XCTAssertNotEqual(ended.snapshot.rows.last?.id, Projection.typingRowID,
                          "the dots go when the signal ends")
        XCTAssertEqual(ended.snapshot.rows.filter(\.showsNoAnswer).map(\.id), ["q"],
                       "the line returns once typing ends")
    }

    // MARK: Reply details (B21)

    func testOnlyUnavailableDetailsOfRemoteItemsAreFetchedOnceEach() {
        let reply = F.text("r", from: F.friend, replyTo: "$q")
        var echo = F.echo("e")
        echo.replyTo = "$q"
        let ready = F.text("ok", from: F.friend, replyTo: "$q")
        let details: [String: ChatReplyDetails] = [
            "r": ChatReplyDetails(eventID: "$q", state: .unavailable),
            "e": ChatReplyDetails(eventID: "$q", state: .unavailable),
            "ok": ChatReplyDetails(eventID: "$q", state: .ready(sender: F.me, senderName: nil, preview: .text("x"))),
        ]
        let rows = Projection.rows([reply, echo, ready], context: F.personRoom(), replyDetails: details)
        XCTAssertEqual(ChatReplyDetails.fetchRequests(rows: rows, alreadyRequested: []), ["$r"],
                       "a local echo cannot be fetched for; a ready one needs nothing")
        XCTAssertEqual(ChatReplyDetails.fetchRequests(rows: rows, alreadyRequested: ["$r"]), [])
        for state: ChatReplyDetails.State in [.pending, .error] {
            XCTAssertFalse(ChatReplyDetails(eventID: "$q", state: state).needsFetch)
        }
        XCTAssertTrue(ChatReplyDetails(eventID: "$q", state: .unavailable).needsFetch)
    }

    func testTheProjectionPutsReplyDetailsOnlyOnRowsThatReply() {
        let original = F.text("q", from: F.friend)
        let reply = F.text("r", from: F.friend, replyTo: "$q")
        let ready = ChatReplyDetails(eventID: "$q", state: .ready(sender: F.friend, senderName: nil, preview: .text("q")))
        let stale = ChatReplyDetails(eventID: "$x", state: .pending)
        let rows = Projection.rows([original, reply], context: F.personRoom(),
                                   replyDetails: ["r": ready, "q": stale])
        XCTAssertNil(rows[0].replyDetails, "a row that replies to nothing draws no quote details")
        XCTAssertEqual(rows[1].replyDetails, ready)
    }

    func testTheProjectorCarriesReplyDetailsOntoItsRows() throws {
        var projector = TimelineProjector(generation: 1, context: F.personRoom(), calendar: utc)
        let detail = ChatReplyDetails(eventID: "$q", state: .unavailable)
        projector.replyDetails = ["r": detail]
        let projected = try projector.apply([.reset([F.text("q", from: F.friend),
                                                     F.text("r", from: F.friend, replyTo: "$q")])], now: F.at(1))
        XCTAssertEqual(projected.snapshot.rows.last?.replyDetails, detail)
    }

    func testTheQuotePreviewFollowsTheRowKind() {
        XCTAssertEqual(ReplyPreview(kind: .message, body: "*hi*"), .text("*hi*"), "raw, never parsed")
        XCTAssertEqual(ReplyPreview(kind: .notice, body: "n"), .text("n"))
        XCTAssertEqual(ReplyPreview(kind: .image(width: 1, height: 1), body: ""), .image)
        XCTAssertEqual(ReplyPreview(kind: .file(name: "a.pdf"), body: ""), .file(name: "a.pdf"))
        XCTAssertEqual(ReplyPreview(kind: .placeholder(.redacted), body: ""), .placeholder(.redacted))
        XCTAssertEqual(ReplyPreview(kind: .roomState, body: ""), .unsupported)
    }
}
