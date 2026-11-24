@testable import AtumMobile
import AtumChat
import XCTest

/// Wave 2 HC-3/HC-5: Home's live-only row facts.
@MainActor
final class HomeChatsWave2StateTests: XCTestCase {
    private let rows = [
        HomeRow(id: "!atum", kind: .atum, name: "Atum"),
        HomeRow(id: "!lan", kind: .person, name: "Lan"),
        HomeRow(id: "!team", kind: .group, name: "Team"),
        HomeRow(id: "!moon", kind: .app, name: "Moon"),
    ]

    func testOnlyAssistantRowsShowTheWorkingAtom() {
        let live = HomeRow.applyingLive(rows, workingRoomIDs: ["!atum", "!lan", "!moon"], memberCounts: [:])
        XCTAssertEqual(live.filter(\.isWorking).map(\.id), ["!atum"])
    }

    func testMemberCountsReachGroupsOnly() {
        let live = HomeRow.applyingLive(rows, workingRoomIDs: [], memberCounts: ["!team": 4, "!lan": 2])
        XCTAssertEqual(live.first { $0.id == "!team" }?.memberCount, 4)
        XCTAssertNil(live.first { $0.id == "!lan" }?.memberCount)
    }

    /// A cold launch paints the cached list: the working state is never in it.
    func testTheWorkingStateIsNeverCached() {
        let live = HomeRow.applyingLive(rows, workingRoomIDs: ["!atum"], memberCounts: ["!team": 4])
        let restored = live.map { HomeRow(snapshot: $0.snapshotRow) }
        XCTAssertFalse(restored.contains(where: \.isWorking))
        XCTAssertTrue(restored.allSatisfy { $0.memberCount == nil })
    }

    func testTheWorkingAtomClearsWhenTypingStops() {
        let working = HomeRow.applyingLive(rows, workingRoomIDs: ["!atum"], memberCounts: [:])
        let idle = HomeRow.applyingLive(working, workingRoomIDs: [], memberCounts: ["!team": 3])
        XCTAssertFalse(idle.contains(where: \.isWorking))
    }

    /// HC-4: a starter fills the composer and asks for the keyboard; it never sends.
    func testAStarterFillsTheDraftWithoutSending() {
        let store = LiveConversationStore(info: ConversationRoomInfo(
            roomID: "!atum:atum.test", title: "Atum",
            context: RoomContext(kind: .assistant, ownUserID: "@me:atum.test"),
            knownNames: [:], catalogBotUserIDs: [], languageCode: "en",
            roomIsEncrypted: false
        ))
        let before = store.composerFocusRequest
        store.pickStarter("Help me plan a trip to ")
        XCTAssertEqual(store.draft, "Help me plan a trip to ")
        XCTAssertEqual(store.composerFocusRequest, before &+ 1)
        XCTAssertTrue(store.snapshot.rows.isEmpty)
    }
    /// A room opened before `/agents` is classified as a person. Receiving
    /// the directory must request a fresh mapper, even with no new event.
    func testLateAgentIdentityRefreshesAnOpenChatAndItsCachedWorkingLine() async throws {
        let owner = "@me:atum.test", agent = "@luna:atum.test"
        let cold = RoomContext(kind: .person, ownUserID: owner, knownAgentUserIDs: [])
        let ready = RoomContext(kind: .assistant, ownUserID: owner, agentUserIDs: [agent],
                                knownAgentUserIDs: [agent])
        func info(_ context: RoomContext) -> ConversationRoomInfo {
            ConversationRoomInfo(roomID: "!luna:atum.test", title: "Luna", context: context,
                                 knownNames: [agent: "Luna"], catalogBotUserIDs: [], languageCode: "vi", roomIsEncrypted: false)
        }
        let raw = #"{"type":"m.room.message","content":{"msgtype":"m.notice","body":"Đang chạy tác vụ…","io.atum.progress":{"phase":"working"}}}"#
        func cachedSource(_ context: RoomContext) -> ScriptedTimelineSource {
            let marker = context.transientAgentUserIDs.contains(agent) ? AtumTurnMarkers.parse(json: raw).progress : nil
            let item = ChatItem(id: "same-cached-event", kind: .notice, sender: agent,
                                body: "Đang chạy tác vụ…", progress: marker)
            return ScriptedTimelineSource(script: ScriptedScript(name: "identity-race", title: "Luna",
                context: context, initial: [item], startsAfterOlderPages: false,
                steps: [ScriptedStep(at: 0.1, .typing([agent]))], names: [agent: "Luna"]))
        }
        let store = LiveConversationStore(info: info(cold), draft: "Keep my draft")
        defer { store.close() }
        await store.attach(source: cachedSource(cold))
        for _ in 0..<100 where store.snapshot.rows.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.snapshot.rows.first?.item.kind, .notice)
        for _ in 0..<200 where store.typingLine != .names(["Luna"]) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.typingLine, .names(["Luna"]), "cold identity initially uses the person typing line")
        XCTAssertFalse(store.snapshot.rows.contains { $0.id == Projection.typingRowID })
        XCTAssertTrue(store.updateRoomInfo(info(ready)), "the app must reattach/remap on directory arrival")
        XCTAssertEqual(store.kind, .assistant)
        XCTAssertEqual(store.agentUserIDs, [agent])
        XCTAssertEqual(store.draft, "Keep my draft")
        // Same production sequence as refreshConversationIdentity: keep the
        // store, reopen its source, and remap the SDK cache with the new facts.
        await store.attach(source: cachedSource(ready))
        for _ in 0..<200 where store.snapshot.rows.last?.item.body != "Đang chạy tác vụ…" {
            try await Task.sleep(for: .milliseconds(10))
        }
        let displayedContent = store.snapshot.rows.filter {
            $0.item.kind.isEventContent || $0.id == Projection.typingRowID
        }
        XCTAssertEqual(displayedContent.map(\.id), [Projection.typingRowID])
        XCTAssertEqual(store.snapshot.rows.last?.item.body, "Đang chạy tác vụ…")
        XCTAssertEqual(store.typingLine, .nobody, "assistant typing leaves the composer and uses the atom footer")
        XCTAssertFalse(store.updateRoomInfo(info(ready)), "unchanged room publications must not reopen the timeline")
        XCTAssertEqual(store.draft, "Keep my draft")
    }

}

@MainActor
final class ConversationStopStateTests: XCTestCase {
    private let owner = "@me:atum.test"
    private let agent = "@agent:atum.test"
    private let room = "!assistant:atum.test"

    func testReopeningKeepsTheExactPendingAndStoppedAttemptInItsRoomAndAccount() async throws {
        let model = LiveAppModel()
        let controller = model.turnStopController(roomID: room, ownUserID: owner)
        let original = makeStore(controller)
        defer { original.close() }
        await open(original, with: workingTurn("$question"))
        try await waitUntil { original.snapshot.rows.contains { $0.item.eventID == "$question" } }
        XCTAssertEqual(controller.stop.selection, .turn(eventID: "$question"))

        let (receipts, reply) = AsyncStream<AssistantTurnStopResult>.makeStream()
        defer { reply.finish() }
        var sent = [AssistantTurnStopIntent]()
        let send: @MainActor (AssistantTurnStopIntent) async -> AssistantTurnStopResult = { intent in
            sent.append(intent)
            for await receipt in receipts { return receipt }
            return .failed
        }
        let pending = try XCTUnwrap(original.turnStop.tap(newRequestID: "original", send: send))
        try await waitUntil { sent.count == 1 }
        original.close()

        let reopened = makeStore(model.turnStopController(roomID: room, ownUserID: owner))
        defer { reopened.close() }
        await open(reopened, with: [])
        try await waitUntil { reopened.snapshot.generation > 0 }
        XCTAssertFalse(reopened.canPresentTurnStop)
        XCTAssertEqual(reopened.turnStop.stop.phase, .stopping)
        await open(reopened, with: workingTurn("$question"))
        try await waitUntil { reopened.snapshot.rows.contains { $0.item.eventID == "$question" } }
        XCTAssertTrue(reopened.canPresentTurnStop)
        XCTAssertNil(reopened.turnStop.tap(newRequestID: "duplicate", send: send))

        reply.yield(.stopped)
        await pending.value
        XCTAssertEqual(reopened.turnStop.stop.phase, .stopped)
        reopened.close()

        let settled = makeStore(model.turnStopController(roomID: room, ownUserID: owner))
        defer { settled.close() }
        await open(settled, with: workingTurn("$question"))
        try await waitUntil { settled.snapshot.rows.contains { $0.item.eventID == "$question" } }
        XCTAssertNil(settled.turnStop.tap(newRequestID: "duplicate", send: send))
        XCTAssertEqual(sent, [AssistantTurnStopIntent(eventID: "$question", requestID: "original")])

        XCTAssertFalse(model.turnStopController(roomID: "!other:atum.test", ownUserID: owner) === controller)
        XCTAssertFalse(model.turnStopController(roomID: room, ownUserID: "@other:atum.test") === controller)
        await open(settled, with: workingTurn("$newer"))
        try await waitUntil { settled.snapshot.rows.contains { $0.item.eventID == "$newer" } }
        XCTAssertEqual(settled.turnStop.stop.selection, .turn(eventID: "$newer"))
        XCTAssertTrue(settled.turnStop.stop.offersStop)
        XCTAssertNil(settled.turnStop.stop.requestID)
    }

    func testPublishedNewerReplyRejectsAnOlderScheduledReceiptWithoutAView() async throws {
        let execution = try XCTUnwrap(ChatScheduleExecution(job: "job", execution: "run"))
        let controller = AssistantTurnStopController()
        let store = makeStore(controller)
        defer { store.close() }
        var progress = ChatProgress(phase: .working)
        progress.isScheduled = true
        progress.schedule = execution
        let marker = ChatItem(id: "$schedule", kind: .notice, sender: agent,
                              timestamp: Date(), eventOrTransactionId: .event("$schedule"),
                              progress: progress)
        await open(store, with: [marker])
        try await waitUntil { store.snapshot.rows.last?.item.progress?.schedule == execution }
        XCTAssertEqual(controller.stop.selection, .schedule(execution))

        let (receipts, reply) = AsyncStream<AssistantTurnStopResult>.makeStream()
        defer { reply.finish() }
        var announcements = [AssistantTurnStopController.Announcement]()
        store.setTurnStopAnnouncement { announcements.append($0) }
        let pending = try XCTUnwrap(controller.tap(newRequestID: "scheduled", send: { _ in
            for await receipt in receipts { return receipt }
            return .failed
        }))
        await open(store, with: workingTurn("$newer"))
        try await waitUntil { store.snapshot.rows.contains { $0.item.eventID == "$newer" } }
        XCTAssertEqual(controller.stop.selection, .turn(eventID: "$newer"))
        reply.yield(.stopped)
        await pending.value
        XCTAssertEqual(announcements, [.stopping])
        XCTAssertNil(controller.stop.notice)
        XCTAssertEqual(controller.stop.selection, .turn(eventID: "$newer"))
    }

    private func makeStore(_ controller: AssistantTurnStopController) -> LiveConversationStore {
        LiveConversationStore(info: ConversationRoomInfo(
            roomID: room, title: "Atum",
            context: RoomContext(kind: .assistant, ownUserID: owner, agentUserIDs: [agent]),
            knownNames: [:], catalogBotUserIDs: [], languageCode: "en"
        ), turnStop: controller)
    }

    private func open(_ store: LiveConversationStore, with items: [ChatItem]) async {
        let context = RoomContext(kind: .assistant, ownUserID: owner, agentUserIDs: [agent])
        let script = ScriptedScript(name: "stop", title: "Atum", context: context, initial: items)
        await store.attach(source: ScriptedTimelineSource(script: script))
    }

    private func workingTurn(_ eventID: String) -> [ChatItem] {
        [
            ChatItem(id: eventID, kind: .message, sender: owner, isOwn: true,
                     eventOrTransactionId: .event(eventID), body: "Question"),
            ChatItem(id: "$progress", kind: .notice, sender: agent,
                     replyTo: eventID, progress: ChatProgress(phase: .working)),
        ]
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                           _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(ready(), "timed out waiting for the test condition", file: file, line: line)
    }
}

/// Home search's People section (`docs/ports/home-search-people.md`).
final class HomePeopleSearchPolicyTests: XCTestCase {
    /// Home search's People (desktop roster global search): two characters
    /// before asking, and only people with no chat yet, each once.
    func testHomePeopleSearchAsksFromTwoCharactersAndListsOnlyNewPeople() {
        XCTAssertNil(HomePeopleSearchPolicy.term("@"))
        XCTAssertNil(HomePeopleSearchPolicy.term("  a "))
        XCTAssertEqual(HomePeopleSearchPolicy.term(" @s "), "@s")
        XCTAssertEqual(HomePeopleSearchPolicy.term("Đỗ"), "Đỗ")
        let found = [
            HomeGroupCandidate(id: "@new:atum.test", name: "New", kind: .person, handle: "new"),
            HomeGroupCandidate(id: "@lan:atum.test", name: "Lan", kind: .person),
            HomeGroupCandidate(id: "@bot:atum.test", name: "Bot", kind: .assistant),
            HomeGroupCandidate(id: "@new:atum.test", name: "New", kind: .person),
        ]
        XCTAssertEqual(HomePeopleSearchPolicy.shown(found) { $0 == "@lan:atum.test" }.map(\.id),
                       ["@new:atum.test"])
    }
}

/// The verified-handle bindings on Home, Start chat, the pickers and chat info
/// (desktop `person-handle-line.tsx`, `person-name.ts`, `roster-model.ts`).
@MainActor
final class PersonHandleBindingTests: XCTestCase {
    private let handles = ["@lan:atum.test": "lannguyen", "@self:atum.test": "self_named"]

    func testALineIsTheAtHandleUnlessItRepeatsTheName() {
        XCTAssertEqual(PersonHandleText.line("lannguyen", name: "Lan"), "@lannguyen")
        XCTAssertNil(PersonHandleText.line("lannguyen", name: " @lannguyen "))
        XCTAssertNil(PersonHandleText.line(nil, name: "Lan"))
        // Only a handle the directory could issue is ever shown.
        XCTAssertNil(PersonHandleText.line("Lan.Nguyen", name: "Lan"))
        XCTAssertNil(PersonHandleText.line("@lannguyen", name: "Lan"))
    }

    /// Desktop `chatRowHandle`: the second line until anyone writes, and always while searching.
    func testAChatRowShowsTheHandleOnlyWhileEmptyOrSearching() {
        XCTAssertEqual(PersonHandleText.chatRow("lannguyen", name: "Lan", hasMessages: false, searching: false),
                       "@lannguyen")
        XCTAssertNil(PersonHandleText.chatRow("lannguyen", name: "Lan", hasMessages: true, searching: false))
        XCTAssertEqual(PersonHandleText.chatRow("lannguyen", name: "Lan", hasMessages: true, searching: true),
                       "@lannguyen")
    }

    /// Desktop `matrixPersonLabel`: someone with no name is called by their handle.
    func testAMemberWithoutANameIsCalledByTheirHandle() {
        let unnamed = "Someone"
        XCTAssertEqual(PersonHandleText.member(name: "Lan", handle: "lannguyen", unnamed: unnamed).line, "@lannguyen")
        let nameless = PersonHandleText.member(name: unnamed, handle: "lannguyen", unnamed: unnamed)
        XCTAssertEqual(nameless.name, "@lannguyen")
        XCTAssertNil(nameless.line)
        let noHandle = PersonHandleText.member(name: unnamed, handle: nil, unnamed: unnamed)
        XCTAssertEqual(noHandle.name, unnamed)
        XCTAssertNil(noHandle.line)
    }

    /// Desktop `filterMatrixRoster`: a chat is found by its verified handle, a leading @ ignored.
    func testSearchMatchesAVerifiedHandle() {
        XCTAssertTrue(PersonHandleText.matches("lannguyen", needle: "nguyen"))
        XCTAssertTrue(PersonHandleText.matches("lannguyen", needle: "@lann"))
        XCTAssertFalse(PersonHandleText.matches("lannguyen", needle: "@"))
        XCTAssertFalse(PersonHandleText.matches(nil, needle: "lan"))
    }

    /// Only a real person's one-to-one row takes its partner's handle; never a
    /// group, an assistant or the Founder, and never anything cached.
    func testOnlyOneToOnePersonRowsTakeTheirPartnersHandle() {
        let rows = [
            HomeRow(id: "!lan", kind: .person, name: "Lan"),
            HomeRow(id: "!founder", kind: .person, name: "Founder", isFounder: true),
            HomeRow(id: "!team", kind: .group, name: "Team"),
            HomeRow(id: "!atum", kind: .atum, name: "Atum"),
        ]
        let partners = ["!lan": "@lan:atum.test", "!founder": "@self:atum.test",
                        "!team": "@lan:atum.test", "!atum": "@lan:atum.test"]
        let live = HomeRow.applyingLive(rows, workingRoomIDs: [], memberCounts: [:], partners: partners,
                                        handle: { self.handles[$0] })
        XCTAssertEqual(live.first { $0.id == "!lan" }?.handle, "lannguyen")
        XCTAssertEqual(live.first { $0.id == "!lan" }?.partnerUserID, "@lan:atum.test")
        XCTAssertEqual(live.filter { $0.handle != nil }.map(\.id), ["!lan"])
        let restored = live.map { HomeRow(snapshot: $0.snapshotRow) }
        XCTAssertTrue(restored.allSatisfy { $0.handle == nil && $0.partnerUserID == nil })
    }
}
