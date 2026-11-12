import XCTest
@testable import AtumChat

/// `atum.agent-turns/1.4` §3 (A7): the phone port of desktop's
/// `matrix-transient-lines.ts`. Synthetic values only.
final class TransientLinesTests: XCTestCase {
    private let agents: Set<String> = [F.agent]

    private func progress(_ id: String = "p", _ body: String = "Đang đọc…",
                          phase: ChatProgress.Phase = .working,
                          minute: Int = 1) -> ChatItem {
        ChatItem(id: id, kind: .notice, sender: F.agent, timestamp: F.at(minute),
                 eventOrTransactionId: .event("$" + id), body: body,
                 progress: ChatProgress(phase: phase))
    }

    private func message(_ id: String, _ body: String = "A", interim: Bool = false,
                         minute: Int = 2) -> ChatItem {
        ChatItem(id: id, kind: .message, sender: F.agent, timestamp: F.at(minute),
                 eventOrTransactionId: .event("$" + id), body: body, interim: interim)
    }

    private func notice(_ id: String, _ body: String, minute: Int) -> ChatItem {
        ChatItem(id: id, kind: .notice, sender: F.agent, timestamp: F.at(minute),
                 eventOrTransactionId: .event("$" + id), body: body)
    }

    private func own(_ id: String = "q", _ body: String = "Q", minute: Int = 0) -> ChatItem {
        ChatItem(id: id, kind: .message, sender: F.me, isOwn: true, timestamp: F.at(minute),
                 eventOrTransactionId: .event("$" + id), body: body)
    }

    private func ids(_ items: [ChatItem]) -> [String] { items.map(\.id) }

    func testKeepsTheLineWhileTheTurnWorksAndHidesItOnceTheAnswerArrives() {
        XCTAssertEqual(ids(TransientLines.visibleItems([own(), progress()], agents: agents)), ["q", "p"])
        XCTAssertEqual(ids(TransientLines.visibleItems([own(), progress(), message("a")], agents: agents)),
                       ["q", "a"])
    }

    func testAnInterimRemarkIsARealMessageThatDoesNotEndTheTurn() {
        let turn = [own(), message("i", interim: true, minute: 2), progress(minute: 3)]
        XCTAssertEqual(ids(TransientLines.visibleItems(turn, agents: agents)), ["q", "i", "p"])
        let answered = turn + [message("a", minute: 4)]
        XCTAssertEqual(ids(TransientLines.visibleItems(answered, agents: agents)), ["q", "i", "a"])
    }

    func testHidesSettledLinesAndRetiredFixedWaitLines() {
        let history = [
            own("q1"),
            progress("p", "Sắp xong.", phase: .settled, minute: 1),
            message("a1", minute: 2),
            own("q2", minute: 3),
            notice("w1", "Đã chờ máy Mac của bạn.", minute: 4),
            notice("w2", "Waited for your Mac.", minute: 5),
            message("a2", minute: 6)
        ]
        XCTAssertEqual(ids(TransientLines.visibleItems(history, agents: agents)), ["q1", "a1", "q2", "a2"])
    }

    func testARetiredWaitLineIsHiddenOnlyWhenEnded() {
        let live = [own(), notice("w", "Đang chờ máy Mac của bạn.", minute: 1)]
        XCTAssertEqual(ids(TransientLines.visibleItems(live, agents: agents)), ["q", "w"])
        XCTAssertNotNil(TransientLines.workingLine(live, agents: agents))
    }

    func testRealOutcomeNoticesPersistAndEndTheTurn() {
        let away = notice("away", "MacBook mẫu đang tắt hoặc đã khoá.", minute: 4)
        let turn = [own(), progress(minute: 1), away]
        XCTAssertEqual(ids(TransientLines.visibleItems(turn, agents: agents)), ["q", "away"])
    }

    func testARedactedAgentMessageShowsNothingButAPersonsDoes() {
        let removed = ChatItem(id: "r", kind: .placeholder(.redacted), sender: F.agent)
        let person = ChatItem(id: "pr", kind: .placeholder(.redacted), sender: F.friend)
        let mine = ChatItem(id: "mr", kind: .placeholder(.redacted), sender: F.me, isOwn: true)
        XCTAssertEqual(ids(TransientLines.visibleItems([removed, person, mine], agents: agents)),
                       ["pr", "mr"])
    }

    func testOneAgentAnsweringDoesNotEndAnotherAgentsTurnAndAStrangerIsNeverHidden() {
        let other = "@other:example.test"
        let both: Set<String> = [F.agent, other]
        let turn = [own(), progress(minute: 1), F.text("answer", from: other, minute: 2)]
        XCTAssertEqual(ids(TransientLines.visibleItems(turn, agents: both)), ["q", "p", "answer"])

        let stranger = F.notice("s", from: F.friend, "Waited for your Mac.")
        XCTAssertEqual(ids(TransientLines.visibleItems([stranger, message("a", minute: 4)], agents: agents)),
                       ["s", "a"])
    }

    func testAPendingOrFailedAgentMessageHasNotEndedTheTurn() {
        var pending = message("a", minute: 2)
        pending.delivery = .sending()
        var failed = message("b", minute: 3)
        failed.delivery = .failed(isRecoverable: false)
        XCTAssertEqual(ids(TransientLines.visibleItems([own(), progress(), pending, failed], agents: agents)),
                       ["q", "p", "a", "b"])
    }

    func testDoesNotMutateItsInputAndKeepsOrder() {
        let input = [own(), progress(), message("a")]
        let copy = input
        _ = TransientLines.visibleItems(input, agents: agents)
        XCTAssertEqual(input, copy)
    }

    // MARK: The working line under the typing bubble

    func testTheWorkingLineIsTheNewestLiveProgressLine() {
        let worker = progress()
        XCTAssertEqual(TransientLines.workingLine([own(), worker], agents: agents)?.id, "p")
    }

    func testTheWorkingLineIsGoneOnceTheAnswerLands() {
        XCTAssertNil(TransientLines.workingLine([own(), progress(), message("a")], agents: agents))
    }

    func testAnInterimRemarkDoesNotHideTheWorkingLine() {
        XCTAssertEqual(TransientLines.workingLine([own(), progress(), message("i", interim: true)], agents: agents)?.id,
                       "p")
    }

    func testTheWorkingLineCanBelongToTheChatsOwnAgent() {
        let other = "@other:example.test"
        let theirs = ChatItem(id: "op", kind: .notice, sender: other, body: "Đang đọc…",
                              progress: ChatProgress(phase: .working))
        let both: Set<String> = [F.agent, other]
        XCTAssertNil(TransientLines.workingLine([own(), theirs], agents: both, sender: F.agent))
        XCTAssertEqual(TransientLines.workingLine([own(), theirs], agents: both, sender: other)?.id, "op")
    }

    func testAPersonsOrOutcomeNoticeIsNeverTheWorkingLine() {
        let away = F.notice("away", from: F.agent, "MacBook mẫu đang tắt hoặc đã khoá.")
        XCTAssertNil(TransientLines.workingLine([own(), away], agents: agents))
        let stranger = F.notice("s", from: F.friend, "Đang chờ máy Mac của bạn.")
        XCTAssertNil(TransientLines.workingLine([stranger], agents: agents))
    }

    // MARK: Projection and the rest of the chat

    /// Desktop `MatrixAgentWorking`: one last row while the agent works; the
    /// live line stands for the typing row (the atom, then the line).
    func testProjectionPutsTheLiveWorkingLineLastInPlaceOfTheTypingRow() {
        let items = [own(), progress(minute: 1), message("i", interim: true, minute: 2)]
        let rows = Projection.rows(items, context: F.assistantRoom(), typingNames: ["Atum"], options: .s1)
        XCTAssertEqual(rows.map(\.id), ["q", "i", "p"])
        let idle = Projection.rows(items, context: F.assistantRoom(), options: .s1)
        XCTAssertEqual(idle.map(\.id), ["q", "i", "p"], "the line shows while typing pauses too")
        let typingOnly = Projection.rows([own()], context: F.assistantRoom(), typingNames: ["Atum"], options: .s1)
        XCTAssertEqual(typingOnly.map(\.id), ["q", Projection.typingRowID], "no line yet: the atom alone")
    }

    func testDesktopStatusLineWaitsAreRetiredWorkingText() {
        for body in ["Đang chờ bạn trả lời trên máy Mac.", "Đã chờ bạn trả lời trên máy Mac.",
                     "Waiting for you on your Mac.", "Waited for you on your Mac."] {
            XCTAssertTrue(TransientLines.isTransientLine(notice("w", body, minute: 1), agents: agents), body)
        }
        let items = [own(), notice("w", "Đã chờ bạn trả lời trên máy Mac.", minute: 1), message("a", minute: 2)]
        XCTAssertEqual(Projection.rows(items, context: F.assistantRoom(), options: .s1).map(\.id), ["q", "a"])
    }

    func testWorkingLineTextSplitsTheStepFromItsChecklist() {
        let text = WorkingLineText(body: "Đang chạy tác vụ…\n✓ Đọc tệp\n•  Viết báo cáo\n\n◦ Gửi")
        XCTAssertEqual(text.current, "Đang chạy tác vụ…")
        XCTAssertEqual(text.steps, [.init(text: "Đọc tệp", done: true), .init(text: "Viết báo cáo", done: false),
                                    .init(text: "Gửi", done: false)])
        XCTAssertEqual(WorkingLineText(body: "Đang tra cứu trên web…"),
                       WorkingLineText(current: "Đang tra cứu trên web…", steps: []))
        XCTAssertNil(WorkingLineText(body: " \n ").current)
    }

    func testProjectionHidesAnEndedWorkingLineAndRetiredWaitLines() {
        let items = [own(), progress(), message("a"), own("q2", minute: 3),
                     notice("w", "Đã chờ máy Mac của bạn.", minute: 4),
                     message("a2", minute: 5)]
        let rows = Projection.rows(items, context: F.assistantRoom(), options: .s1)
        XCTAssertEqual(rows.map(\.id), ["q", "a", "q2", "a2"])
    }

    func testProjectionRendersNoTombstoneForAnAgentRedaction() {
        let items = [own(), ChatItem(id: "r", kind: .placeholder(.redacted), sender: F.agent, timestamp: F.at(2))]
        XCTAssertEqual(Projection.rows(items, context: F.assistantRoom(), options: .s1).map(\.id), ["q"])
    }

    func testAnInterimRemarkDoesNotSuppressTheNoAnswerLine() {
        let room = F.assistantRoom()
        let items = [own(minute: 0), message("i", "Để mình xem.", interim: true, minute: 1)]
        XCTAssertEqual(Delivery.noAnswerItemID(items, context: room, now: F.at(2)), "q")
    }
}
