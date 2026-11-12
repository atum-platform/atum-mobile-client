import XCTest
@testable import AtumChat

/// Desktop b4506a4e7: matrix-transient-lines.test.ts plus app.tsx's
/// transcript/working-footer composition, tested together through projection.
final class WorkingLineParityTests: XCTestCase {
    private func line(_ id: String = "work", sender: String = F.agent,
                      body: String = "Running…", phase: ChatProgress.Phase = .working) -> ChatItem {
        ChatItem(id: id, kind: .notice, sender: sender, eventOrTransactionId: .event("$" + id),
                 body: body, isEdited: true, replyTo: "$q", progress: ChatProgress(phase: phase))
    }

    func testAllFiveLocalesAndHistoricalWaitCopyAreTransient() {
        let copy = [
            "Waiting for your Mac.", "Waited for your Mac.",
            "Đang chờ máy Mac của bạn.", "Đã chờ máy Mac của bạn.",
            "Macを待っています。", "Macを待ちました。",
            "正在等待你的 Mac。", "已等待你的 Mac。",
            "Waiting for you on your Mac.", "Waited for you on your Mac.",
            "Đang chờ bạn trả lời trên máy Mac.", "Đã chờ bạn trả lời trên máy Mac.",
            "Macでの応答を待っています。", "Macでの応答を待ちました。",
            "正在等待你在 Mac 上回复。", "已等待你在 Mac 上回复。",
            "正在等待你在 Mac 上回覆。", "已等待你在 Mac 上回覆。"
        ]
        XCTAssertEqual(Set(copy), TransientLines.retiredWaitLines)
        for body in copy {
            let wait = F.notice("wait", from: F.agent, " \n" + body + "\n ")
            let live = Projection.rows([F.mine("q"), wait], context: F.assistantRoom())
            XCTAssertEqual(live.map(\.id), ["q", Projection.typingRowID], body)
            XCTAssertEqual(live.last?.item.body, wait.body)
            XCTAssertEqual(Projection.rows([wait, F.text("a", from: F.agent)],
                                           context: F.assistantRoom()).map(\.id), ["a"], body)
        }
    }

    func testOnlyNewestLineAppearsAndItIsNotATranscriptEvent() {
        let rows = Projection.rows([F.mine("q"), line("old"), line("new", body: "Reading…")],
                                   context: F.assistantRoom(), typingNames: ["Atum"], options: .s1)
        XCTAssertEqual(rows.map(\.id), ["q", Projection.typingRowID])
        let footer = rows.last!
        XCTAssertEqual(footer.item.body, "Reading…")
        XCTAssertEqual(footer.item.kind, .typing(names: ["Atum"]))
        XCTAssertFalse(footer.item.kind.isEventContent)
        XCTAssertFalse(footer.item.countsAsNewMessage)
        XCTAssertFalse(footer.item.isEdited)
        XCTAssertNil(footer.item.eventID)
        XCTAssertNil(footer.item.replyTo)
        XCTAssertFalse(footer.showsQuote)
        XCTAssertFalse(footer.isLatest)
        XCTAssertEqual(footer.delivery, .none)
        XCTAssertEqual(footer.grouping, .none)
        XCTAssertTrue(rows[0].isLatest)
    }

    func testPendingFailedUndecryptableAndInterimRepliesDoNotEndWorking() {
        var interim = F.text("interim", from: F.agent, replyTo: "$q")
        interim.interim = true
        var pending = F.text("pending", from: F.agent, replyTo: "$q")
        pending.delivery = .sending()
        var failed = F.text("failed", from: F.agent, replyTo: "$q")
        failed.delivery = .failed(isRecoverable: false)
        let unreadable = ChatItem(id: "encrypted", kind: .placeholder(.undecryptable), sender: F.agent)
        let oldUnreadable = ChatItem(id: "oldEncrypted", kind: .placeholder(.undecryptableOldHistory), sender: F.agent)
        for later in [interim, pending, failed, unreadable, oldUnreadable] {
            let rows = Projection.rows([F.mine("q"), line(), later], context: F.assistantRoom())
            XCTAssertEqual(rows.map(\.id), ["q", later.id, Projection.typingRowID], later.id)
        }
    }

    func testSettledAndLaterOutcomesEndLinesWithoutReplyCorrelation() {
        XCTAssertTrue(Projection.rows([line(phase: .settled)], context: F.assistantRoom()).isEmpty)
        for outcome in [F.text("answer", from: F.agent), F.notice("outcome", from: F.agent, "Stopped.")] {
            let rows = Projection.rows([line(), outcome], context: F.assistantRoom())
            XCTAssertEqual(rows.map(\.id), [outcome.id])
        }
    }

    func testOrdinaryOutcomeNoticeIsNotRemovedByLaterAnswer() {
        let outcome = F.notice("outcome", from: F.agent, "Stopped.", replyTo: "$q")
        let rows = Projection.rows([F.mine("q"), line(), outcome, F.text("a", from: F.agent, replyTo: "$q")],
                                   context: F.assistantRoom())
        XCTAssertEqual(rows.map(\.id), ["q", "outcome", "a"])
    }

    func testOnlyTheSelectedAssistantSuppliesThePrivateWorkingLine() {
        let context = RoomContext(kind: .assistant, ownUserID: F.me, agentUserIDs: [F.agent],
                                  knownAgentUserIDs: [F.agent, F.other])
        let rows = Projection.rows([line("mine"), line("theirs", sender: F.other, body: "Other agent")], context: context)
        XCTAssertEqual(rows.map(\.id), [Projection.typingRowID])
        XCTAssertEqual(rows.last?.item.body, "Running…")
        XCTAssertTrue(Projection.rows([line(sender: F.other)], context: context).isEmpty)
        let otherAnswer = F.text("a", from: F.other)
        XCTAssertEqual(Projection.rows([line(), otherAnswer], context: context).map(\.id),
                       ["a", Projection.typingRowID])
    }

    func testGroupsCompanyAndBotRoomsDoNotShowThePrivateWorkingFooter() {
        for kind in [RoomKind.group, .person, .appBot] {
            let context = RoomContext(kind: kind, ownUserID: F.me, knownAgentUserIDs: [F.agent])
            let status = F.notice("status", from: F.agent, "Waiting for approval on another device.")
            let retired = F.notice("retired", from: F.agent, "Waiting for your Mac.")
            let removed = ChatItem(id: "removed", kind: .placeholder(.redacted), sender: F.agent)
            let rows = Projection.rows([line(), status, retired, removed], context: context, typingNames: ["Atum"])
            XCTAssertEqual(rows.map(\.id), ["status"], kind.rawValue)
            XCTAssertEqual(TypingNames.presentation(kind: kind, names: ["Atum"]).line, .names(["Atum"]))
        }
    }

    func testHumansAndCatalogBotsDoNotBecomeWorkingLinesByCopyOrMarker() {
        var own = line(sender: F.me)
        own.isOwn = true
        for notice in [own, line(sender: F.friend), line(sender: F.bot),
                       F.notice("personWait", from: F.friend, "Waited for your Mac.")] {
            let rows = Projection.rows([notice], context: F.assistantRoom())
            XCTAssertEqual(rows.map(\.id), [notice.id])
            XCTAssertEqual(rows.first?.item.kind, .notice)
        }
        XCTAssertEqual(Projection.rows([line(sender: F.bot)], context: F.botRoom()).map(\.id), ["work"])
    }

    func testAgentRedactionsDisappearInSharedRoomsWithoutHidingHumanTombstones() {
        let context = RoomContext(kind: .group, ownUserID: F.me, knownAgentUserIDs: [F.agent])
        let agent = ChatItem(id: "agent", kind: .placeholder(.redacted), sender: F.agent)
        let human = ChatItem(id: "human", kind: .placeholder(.redacted), sender: F.friend)
        XCTAssertEqual(Projection.rows([agent, human], context: context).map(\.id), ["human"])
        var edited = F.text("interim", from: F.agent)
        edited.interim = true
        edited.isEdited = true
        XCTAssertFalse(Grouping.showsEdited(edited, context: context))
    }

    func testFooterIdentitySurvivesTypingProgressEditsAndRedaction() throws {
        var projector = TimelineProjector(generation: 1, context: F.assistantRoom())
        projector.typingNames = ["Atum"]
        let initial = try projector.apply([.reset([F.mine("q")])], now: F.at(1))
        XCTAssertEqual(initial.snapshot.rows.last?.id, Projection.typingRowID)
        let inserted = try projector.apply([.pushBack(line())], now: F.at(1))
        XCTAssertEqual(inserted.snapshot.rows.last?.id, Projection.typingRowID)
        projector.typingNames = []
        let edited = try projector.apply([.set(index: 1, item: line(body: "Reading…\n✔ Done\n◦ Next"))], now: F.at(1))
        XCTAssertEqual(edited.snapshot.rows.last?.id, Projection.typingRowID)
        XCTAssertEqual(edited.snapshot.rows.last?.item.body, "Reading…\n✔ Done\n◦ Next")
        let redacted = ChatItem(id: "work", kind: .placeholder(.redacted), sender: F.agent)
        XCTAssertEqual(try projector.apply([.set(index: 1, item: redacted)], now: F.at(2)).snapshot.rows.map(\.id), ["q"])
    }

    func testStepCardParsesBothChecksBothBulletsAndUnmarkedLines() {
        let text = WorkingLineText(body: " \n Current \r\n ✓ Done\n✔ Also done\n• Next\n◦ Later\n Plain \n\n")
        XCTAssertEqual(text.current, "Current")
        XCTAssertEqual(text.steps, [.init(text: "Done", done: true), .init(text: "Also done", done: true),
                                    .init(text: "Next", done: false), .init(text: "Later", done: false),
                                    .init(text: "Plain", done: false)])
        XCTAssertEqual(WorkingLineText(body: "Current\n✔️ Done").steps,
                       [.init(text: "️ Done", done: true)])
        XCTAssertEqual(WorkingLineText(body: "Current\rstill current").current, "Current\rstill current",
                       "Desktop splits on LF, not every Unicode newline")
    }

    func testFooterDoesNotKeepEmptyDayOrTrailingReadMarkerAlive() {
        let rows = Projection.rows([F.mine("q"), F.divider("onlyWork"), line(), F.readMarker()],
                                   context: F.assistantRoom(), options: .s1)
        XCTAssertEqual(rows.map(\.id), ["q", Projection.typingRowID])
    }

    func testWorkingFooterPreservesExistingStopAndGrowingSignals() {
        var interim = F.text("interim", from: F.agent)
        interim.interim = true
        let rows = Projection.rows([F.mine("q"), interim, line()], context: F.assistantRoom())
        XCTAssertEqual(AssistantTurnSignal.read(rows, kind: .assistant), .init(unanswered: "$q", working: true))
        XCTAssertEqual(MessageFold.growingIDs(in: rows), ["interim"])
    }
    func testLateAgentIdentityRebuildRecognizesTheSameCachedEvent() throws {
        let raw = #"{"type":"m.room.message","sender":"@agent:example.test","content":{"msgtype":"m.notice","body":"Đang chạy tác vụ…","io.atum.progress":{"phase":"working","revision":0}}}"#
        let cold = RoomContext(kind: .person, ownUserID: F.me, knownAgentUserIDs: [])
        let ready = RoomContext(kind: .assistant, ownUserID: F.me, agentUserIDs: [F.agent],
                                knownAgentUserIDs: [F.agent])
        func mapped(_ context: RoomContext) -> ChatItem {
            let markers = context.transientAgentUserIDs.contains(F.agent)
                ? AtumTurnMarkers.parse(json: raw) : AtumTurnMarkers()
            return ChatItem(id: "work", kind: .notice, sender: F.agent, body: "Đang chạy tác vụ…",
                            progress: markers.progress)
        }
        let before = mapped(cold)
        XCTAssertNil(before.progress)
        XCTAssertEqual(Projection.rows([before], context: cold).first?.item.kind, .notice)
        // Merely changing projection context cannot recover discarded markers.
        XCTAssertEqual(Projection.rows([before], context: ready).first?.item.kind, .notice)
        let after = Projection.rows([mapped(ready)], context: ready)
        XCTAssertEqual(after.map(\.id), [Projection.typingRowID])
        XCTAssertEqual(after.first?.item.body, "Đang chạy tác vụ…")
        var core = ConversationCore(context: cold, draft: "Unsent draft")
        core.updateContext(ready)
        XCTAssertEqual(core.kind, .assistant)
        XCTAssertEqual(core.draft, "Unsent draft")
        core.updateContext(RoomContext(kind: .group, ownUserID: F.other))
        XCTAssertEqual(core.context, ready, "a context refresh cannot cross accounts")
    }

    func testGeneratedHistoricalWorkingNoticesAreExplicitlySettled() throws {
        let env = ScriptedEnvironment(reference: F.at(100))
        var checked = 0
        for scenario in [ScriptedScenario.chatKeyboard, .chatSend, .chatReplyAtBottom, .chatLong] {
            let script = try XCTUnwrap(ScriptedScenarios.selection(named: scenario.rawValue, environment: env)?.chat)
            for item in script.initial + script.olderPages.flatMap({ $0 })
                where item.kind == .notice && item.body == "Đang xử lý…" {
                checked += 1
                XCTAssertEqual(item.progress?.phase, .settled, scenario.rawValue)
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testReadingActivityRemainsPublisherWordingBesideTheInterimReply() throws {
        let env = ScriptedEnvironment(reference: F.at(100))
        let script = try XCTUnwrap(ScriptedScenarios.selection(named: "chat.timeline-reading", environment: env)?.chat)
        let rows = ScriptedScenarios.rows(script, after: 9, environment: env, options: .s1)
        XCTAssertEqual(rows.last?.id, Projection.typingRowID)
        XCTAssertEqual(rows.last?.item.body, "Đang đọc…")
        XCTAssertTrue(rows.dropLast().last?.item.interim == true)
        XCTAssertFalse(rows.contains { $0.item.kind == .notice && $0.item.body == "Đang đọc…" })
    }

}
