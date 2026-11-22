import XCTest
@testable import AtumChat

/// Review C1: the composer's working state and its Stop. Which turn is in
/// progress (the desktop's `matrixCloudStopTarget` fallback) and the stop
/// state machine (in progress → stopping → stopped or failed; a retry re-sends
/// the same idempotency key).
final class AssistantTurnSignalTests: XCTestCase {
    private func rows(_ items: [ChatItem]) -> [ChatRow] { items.map { ChatRow(item: $0) } }
    private let typing = ChatItem(id: "atum.typing", kind: .typing(names: ["Atum"]))

    private func working(_ id: String, replyTo: String, phase: ChatProgress.Phase = .working) -> ChatItem {
        var item = F.notice(id, from: F.agent, "Đang tìm", replyTo: replyTo)
        item.progress = ChatProgress(phase: phase)
        return item
    }

    func testMyUnansweredQuestionWhileTheAgentTypesIsATurnInProgress() {
        let signal = AssistantTurnSignal.read(rows([F.mine("q1"), typing]), kind: .assistant)
        XCTAssertEqual(signal, AssistantTurnSignal(unanswered: "$q1", working: true))
    }

    func testALiveWorkingLineIsWorkingAndASettledOneIsNot() {
        XCTAssertTrue(AssistantTurnSignal.read(rows([F.mine("q1"), working("w", replyTo: "$q1")]),
                                               kind: .assistant).working)
        XCTAssertFalse(AssistantTurnSignal.read(rows([F.mine("q1"), working("w", replyTo: "$q1", phase: .settled)]),
                                                kind: .assistant).working)
    }

    func testTheAnswerOrAStatusLineNamingTheQuestionEndsIt() {
        let answered = AssistantTurnSignal.read(
            rows([F.mine("q1"), F.text("a1", from: F.agent, "Đây", replyTo: "$q1")]), kind: .assistant)
        XCTAssertNil(answered.unanswered)
        let noticed = AssistantTurnSignal.read(
            rows([F.mine("q1"), F.notice("n1", from: F.agent, "Đã dừng", replyTo: "$q1")]), kind: .assistant)
        XCTAssertNil(noticed.unanswered)
    }

    func testAnInterimRemarkOrAWorkingLineDoesNotEndIt() {
        var interim = F.text("i1", from: F.agent, "Một lát", replyTo: "$q1")
        interim.interim = true
        let signal = AssistantTurnSignal.read(rows([F.mine("q1"), interim, working("w", replyTo: "$q1")]),
                                              kind: .assistant)
        XCTAssertEqual(signal, AssistantTurnSignal(unanswered: "$q1", working: true))
    }

    func testOnlyMyNewestTopLevelSentQuestionCounts() {
        // A send still on its way has no event ID yet: nothing to name.
        XCTAssertNil(AssistantTurnSignal.read(rows([F.mine("q1"), F.echo("q2"), typing]), kind: .assistant).unanswered)
        // An answer to an older question does not answer the newer one.
        let newer = AssistantTurnSignal.read(
            rows([F.mine("q1"), F.text("a1", from: F.agent, replyTo: "$q1"), F.mine("q2"), typing]), kind: .assistant)
        XCTAssertEqual(newer.unanswered, "$q2")
        // A thread message starts no turn.
        var threaded = F.mine("t1")
        threaded.threadRoot = "$root"
        XCTAssertEqual(AssistantTurnSignal.read(rows([F.mine("q1"), threaded, typing]), kind: .assistant).unanswered,
                       "$q1")
    }

    func testAnAgentMessageWithNoReplyAfterTheQuestionHidesStop() {
        let signal = AssistantTurnSignal.read(rows([F.mine("q1"), F.text("a1", from: F.agent), typing]),
                                              kind: .assistant)
        XCTAssertNil(signal.unanswered)
    }

    func testOnlyMyAssistantsChatHasTurns() {
        for kind in [RoomKind.person, .group, .appBot] {
            XCTAssertEqual(AssistantTurnSignal.read(rows([F.mine("q1"), typing]), kind: kind), .idle, "\(kind)")
        }
    }
}

final class AssistantTurnStopTests: XCTestCase {
    private let working = AssistantTurnSignal(unanswered: "$q1", working: true)

    private func inProgress() -> AssistantTurnStop {
        var stop = AssistantTurnStop()
        stop.observe(working)
        return stop
    }

    func testNoTurnNoStop() {
        var stop = AssistantTurnStop()
        stop.observe(.idle)
        XCTAssertEqual(stop.phase, .idle)
        XCTAssertFalse(stop.offersStop)
        XCTAssertNil(stop.beginStop(newRequestID: "r1"))
        // An unanswered question with no sign of work is not a turn in progress.
        stop.observe(AssistantTurnSignal(unanswered: "$q1", working: false))
        XCTAssertEqual(stop.phase, .idle)
    }

    func testInProgressThenStoppingThenStopped() {
        var stop = inProgress()
        XCTAssertEqual(stop.phase, .working)
        XCTAssertTrue(stop.offersStop)
        let intent = stop.beginStop(newRequestID: "r1")
        XCTAssertEqual(intent, AssistantTurnStopIntent(eventID: "$q1", requestID: "r1"))
        XCTAssertEqual(intent.map { String(describing: $0.eventID) }, "$q1",
                       "legacy event-only probes keep the unwrapped ID")
        XCTAssertEqual(stop.phase, .stopping)
        XCTAssertFalse(stop.offersStop, "no second request while one is out")
        XCTAssertNil(stop.beginStop(newRequestID: "r2"))
        stop.resolve(.stopped, for: intent!)
        XCTAssertEqual(stop.phase, .stopped)
        XCTAssertTrue(stop.isWorking, "the turn stays shown until the room ends it")
        // The agent's stopped line names the question: the turn is over.
        stop.observe(.idle)
        XCTAssertEqual(stop.phase, .idle)
    }

    func testStopRequestedStaysStoppingUntilTheTurnEnds() {
        var stop = inProgress()
        let intent = stop.beginStop(newRequestID: "r1")!
        stop.resolve(.stopRequested, for: intent)
        XCTAssertEqual(stop.phase, .stopping, "never shown as stopped on stop_requested")
        stop.observe(AssistantTurnSignal(unanswered: "$q1", working: false))
        XCTAssertEqual(stop.phase, .stopping)
        stop.observe(.idle)
        XCTAssertEqual(stop.phase, .idle)
    }

    func testCompletedMeansNothingWasStopped() {
        var stop = inProgress()
        let intent = stop.beginStop(newRequestID: "r1")!
        stop.resolve(.completed, for: intent)
        XCTAssertEqual(stop.phase, .finishing)
        XCTAssertFalse(stop.offersStop)
    }

    func testAFailureIsReportedAndTheRetryResendsTheSameKey() {
        var stop = inProgress()
        let first = stop.beginStop(newRequestID: "r1")!
        stop.resolve(.failed, for: first)
        XCTAssertEqual(stop.phase, .failed, "not stopped")
        XCTAssertTrue(stop.isWorking, "the turn is still shown as in progress")
        XCTAssertTrue(stop.offersStop)
        let retry = stop.beginStop(newRequestID: "r2")
        XCTAssertEqual(retry, first, "idempotent on (owner, requestId)")
        stop.resolve(.stopped, for: retry!)
        XCTAssertEqual(stop.phase, .stopped)
    }

    func testTheLatchKeepsStopAfterTypingLapses() {
        var stop = inProgress()
        stop.observe(AssistantTurnSignal(unanswered: "$q1", working: false))
        XCTAssertEqual(stop.phase, .working)
        XCTAssertEqual(stop.target, "$q1")
    }

    func testANewQuestionIsANewTurnWithANewKey() {
        var stop = inProgress()
        let first = stop.beginStop(newRequestID: "r1")!
        stop.resolve(.failed, for: first)
        stop.observe(AssistantTurnSignal(unanswered: "$q2", working: true))
        XCTAssertEqual(stop.phase, .working)
        XCTAssertNil(stop.requestID)
        XCTAssertEqual(stop.beginStop(newRequestID: "r3"), AssistantTurnStopIntent(eventID: "$q2", requestID: "r3"))
    }

    func testALateReplyForAnEarlierTurnChangesNothing() {
        var stop = inProgress()
        let first = stop.beginStop(newRequestID: "r1")!
        stop.observe(AssistantTurnSignal(unanswered: "$q2", working: true))
        stop.resolve(.stopped, for: first)
        XCTAssertEqual(stop.phase, .working)
        XCTAssertEqual(stop.target, "$q2")
    }

    /// `atum.agent-turns/1` `client-stopped.sequence.json`: sent → working →
    /// stopping → stopped, through this machine's phases.
    func testFollowsTheClientStoppedFixture() {
        var stop = AssistantTurnStop()
        stop.observe(working)                                  // turn_state_claimed_or_dispatched
        XCTAssertEqual(stop.phase, .working)
        let intent = stop.beginStop(newRequestID: "r1")!        // stop_sent
        XCTAssertEqual(stop.phase, .stopping)
        stop.resolve(.stopped, for: intent)                    // stop_result_or_outcome_stopped
        XCTAssertEqual(stop.phase, .stopped)
    }
}

final class MessageMenuLayoutTests: XCTestCase {
    private let bounds = 60.0...800.0
    private let reactions = 52.0, menu = 140.0, gap = 8.0

    /// The three parts never overlap and stay inside the band.
    private func assertSeparate(_ layout: MessageMenuLayout, file: StaticString = #filePath, line: UInt = #line) {
        var spans = [(layout.previewTop, layout.previewTop + layout.previewHeight)]
        if let top = layout.reactionsTop { spans.append((top, top + reactions)) }
        spans.append((layout.menuTop, layout.menuTop + menu))
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.0, bounds.lowerBound - 0.001, "above the band", file: file, line: line)
            XCTAssertLessThanOrEqual(span.1, bounds.upperBound + 0.001, "below the band", file: file, line: line)
        }
        let sorted = spans.sorted { $0.0 < $1.0 }
        for (upper, lower) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(upper.1, lower.0 + 0.001, "overlap \(upper) \(lower)", file: file, line: line)
        }
    }

    func testAMessageMidScreenStaysInPlaceWithTheCapsuleAboveAndTheMenuBelow() {
        let layout = MessageMenuLayout.place(sourceTop: 300, bounds: bounds, reactions: reactions,
                                             preview: 80, menu: menu, gap: gap)
        XCTAssertEqual(layout.arrangement, .reactionsAbove)
        XCTAssertEqual(layout.previewTop, 300)
        XCTAssertEqual(layout.reactionsTop, 300 - gap - reactions)
        XCTAssertEqual(layout.menuTop, 380 + gap)
        assertSeparate(layout)
    }

    func testAMessageLowOnTheScreenFlipsInsteadOfMoving() {
        let layout = MessageMenuLayout.place(sourceTop: 680, bounds: bounds, reactions: reactions,
                                             preview: 60, menu: menu, gap: gap)
        XCTAssertEqual(layout.arrangement, .menuAbove)
        XCTAssertEqual(layout.previewTop, 680, "the message keeps its place")
        XCTAssertEqual(layout.reactionsTop, 740 + gap)
        assertSeparate(layout)
    }

    func testAMessageUnderTheBarMovesDownOnlyAsFarAsItMust() {
        let layout = MessageMenuLayout.place(sourceTop: 20, bounds: bounds, reactions: reactions,
                                             preview: 80, menu: menu, gap: gap)
        XCTAssertEqual(layout.arrangement, .reactionsAbove)
        XCTAssertEqual(layout.reactionsTop, bounds.lowerBound)
        assertSeparate(layout)
    }

    func testATallMessageIsCutSoTheStackFits() {
        let layout = MessageMenuLayout.place(sourceTop: 100, bounds: bounds, reactions: reactions,
                                             preview: 2_000, menu: menu, gap: gap)
        XCTAssertEqual(layout.previewHeight, (bounds.upperBound - bounds.lowerBound) - reactions - menu - 2 * gap)
        assertSeparate(layout)
    }

    func testNoCapsuleWhenTheMessageOffersNoReactions() {
        let layout = MessageMenuLayout.place(sourceTop: 300, bounds: bounds, reactions: nil,
                                             preview: 80, menu: menu, gap: gap)
        XCTAssertNil(layout.reactionsTop)
        XCTAssertEqual(layout.previewTop, 300)
        assertSeparate(layout)
    }

    func testEveryPositionOnTheScreenKeepsThePartsApart() {
        for sourceTop in stride(from: -100.0, through: 900.0, by: 10) {
            for preview in [40.0, 200.0, 420.0, 900.0] {
                assertSeparate(MessageMenuLayout.place(sourceTop: sourceTop, bounds: bounds, reactions: reactions,
                                                       preview: preview, menu: menu, gap: gap))
            }
        }
    }
}

extension AssistantTurnSignalTests {
    func testDesktop75NativeThreadInterimSurvivesFinalWithoutEndingTheRoomTurn() {
        // Desktop #75 forwards reply_to=$reply and thread_id=$thread to Matrix
        // adapter.py, which emits this unmarked text and thread fallback.
        let interimWire = #"""
        {"msgtype":"m.text","body":"Checking the calendar.","m.relates_to":{
          "rel_type":"m.thread","event_id":"$thread","is_falling_back":true,
          "m.in_reply_to":{"event_id":"$reply"}}}
        """#
        var interim = F.text("native", from: F.agent, "Checking the calendar.", replyTo: "$reply", threadRoot: "$thread")
        AtumTurnMarkers.parse(json: interimWire).apply(to: &interim)
        XCTAssertFalse(interim.interim)
        let question = F.mine("reply")
        let status = working("work", replyTo: "$reply")
        let context = F.assistantRoom()
        let live = Projection.rows([question, status, interim], context: context)
        XCTAssertEqual(F.ids(live), ["reply", "native", Projection.typingRowID])
        XCTAssertEqual(AssistantTurnSignal.read(live, kind: .assistant),
                       AssistantTurnSignal(unanswered: "$reply", working: true))

        let finalWire = #"{"msgtype":"m.text","body":"Checking the calendar.","m.relates_to":{"m.in_reply_to":{"event_id":"$reply"}}}"#
        var final = F.text("final", from: F.agent, interim.body, replyTo: "$reply")
        AtumTurnMarkers.parse(json: finalWire).apply(to: &final)
        let settled = Projection.rows([question, status, interim, final], context: context)
        XCTAssertEqual(F.ids(settled), ["reply", "native", "final"])
        XCTAssertEqual(AssistantTurnSignal.read(settled, kind: .assistant), .idle)
    }

    func testUnmarkedTopLevelTextHasTheSameShapeAsAFinalAnswer() {
        let native = #"{"msgtype":"m.text","body":"Checking the calendar.","m.relates_to":{"m.in_reply_to":{"event_id":"$reply"}}}"#
        let final = #"{"msgtype":"m.text","body":"Calendar checked.","m.relates_to":{"m.in_reply_to":{"event_id":"$reply"}}}"#
        XCTAssertEqual(AtumTurnMarkers.parse(json: native), AtumTurnMarkers.parse(json: final))
    }

    func testExactScheduleFooterOutlivesAnotherExecutionsAnswer() throws {
        var scheduled = working("cron", replyTo: "$unrelated")
        scheduled.progress?.isScheduled = true
        let execution = try XCTUnwrap(ChatScheduleExecution(job: "job", execution: "run-a"))
        scheduled.progress?.schedule = execution
        let rows = Projection.rows([F.mine("question"), scheduled, F.text("other", from: F.agent)],
                                   context: F.assistantRoom())
        XCTAssertEqual(AssistantTurnSignal.read(rows, kind: .assistant).scheduled, execution)
        XCTAssertEqual(F.ids(rows), ["question", "other", Projection.typingRowID])

        scheduled.delivery = .sending()
        let local = Projection.rows([F.mine("question"), scheduled], context: F.assistantRoom())
        let unavailable = AssistantTurnSignal.read(local, kind: .assistant)
        XCTAssertNil(unavailable.scheduled)
        XCTAssertTrue(unavailable.hasScheduledWork)
        XCTAssertNil(unavailable.unanswered)
    }
}

extension AssistantTurnStopTests {
    func testScheduledStopSelectsTheExactExecutionAndIgnoresLateReceipts() throws {
        let a = try XCTUnwrap(ChatScheduleExecution(job: "job", execution: "run-a"))
        let b = try XCTUnwrap(ChatScheduleExecution(job: "job", execution: "run-b"))
        var stop = inProgress()
        stop.observe(.init(unanswered: "$question", working: true, scheduled: a))
        let first = try XCTUnwrap(stop.beginStop(newRequestID: "first"))
        XCTAssertEqual(first.target, .schedule(a))
        stop.retryPendingSchedule(for: first)
        XCTAssertEqual(stop.phase, .stopping, "still in flight")
        stop.resolve(.failed, for: first)
        XCTAssertEqual(stop.phase, .failed)
        XCTAssertEqual(stop.beginStop(newRequestID: "retry"), first)
        stop.resolve(.stopRequested, for: first)
        XCTAssertEqual(stop.phase, .stopping)
        stop.retryPendingSchedule(for: first)
        XCTAssertEqual(stop.phase, .working)
        XCTAssertEqual(stop.beginStop(newRequestID: "after pending"), first)

        stop.observe(.init(unanswered: "$question", working: true, scheduled: b))
        stop.retryPendingSchedule(for: first)
        stop.resolve(.stopped, for: first)
        XCTAssertEqual(stop.phase, .working)
        let second = try XCTUnwrap(stop.beginStop(newRequestID: "second"))
        XCTAssertEqual(second.target, .schedule(b))
        stop.resolve(.completed, for: second)
        XCTAssertEqual(stop.phase, .finishing)

        stop.observe(.init(unanswered: "$question", working: true, hasScheduledWork: true))
        XCTAssertNil(stop.selection)
        XCTAssertEqual(stop.phase, .working)
        XCTAssertFalse(stop.offersStop)
        XCTAssertNil(stop.beginStop(newRequestID: "unresolved"))
    }
}
