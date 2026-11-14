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
