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
}
