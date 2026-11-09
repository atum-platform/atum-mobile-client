import XCTest
@testable import AtumNativeAPI

final class MobileRoomTypePolicyTests: XCTestCase {
    func testAgentTaskRoomTypeComesFromBoundedCreateContent() {
        XCTAssertEqual(
            MobileRoomTypePolicy.roomType(
                createContentJSON: #"{"creator":"@owner:atum.test","type":"io.atum.agent_task.v1","room_version":"11"}"#
            ),
            MobileRoomTypePolicy.agentTask
        )
        XCTAssertTrue(MobileRoomTypePolicy.isAgentTask(MobileRoomTypePolicy.agentTask))
        XCTAssertFalse(MobileRoomTypePolicy.isAgentTask(nil))
    }

    /// The desktop's notes-to-self room type (atum-app `MATRIX_NOTES_SELF_ROOM_TYPE`) is read
    /// from create content and kept out of Chats, like agent task rooms; nothing else is.
    func testNotesSelfAndAgentTaskRoomsAreHiddenFromChatsAndNothingElse() {
        let notes = MobileRoomTypePolicy.roomType(
            createContentJSON: #"{"creator":"@owner:atum.test","type":"com.atum.notes.self","room_version":"11"}"#
        )
        XCTAssertEqual(notes, MobileRoomTypePolicy.notesSelf)
        XCTAssertTrue(MobileRoomTypePolicy.isHiddenFromChats(notes))
        XCTAssertTrue(MobileRoomTypePolicy.isHiddenFromChats(MobileRoomTypePolicy.agentTask))
        for other in [nil, "m.space", "io.atum.assistant", "com.atum.notes.self.v2"] as [String?] {
            XCTAssertFalse(MobileRoomTypePolicy.isHiddenFromChats(other), String(describing: other))
        }
    }

    func testMissingMalformedAndUnboundedRoomTypesCarryNoAuthority() {
        for content in [nil, "", "[]", "{}", #"{"type":4}"#,
                        #"{"type":""}"#, #"{"type":"a\u0000b"}"#] as [String?] {
            XCTAssertNil(MobileRoomTypePolicy.roomType(createContentJSON: content),
                         String(describing: content))
        }
        let oversized = #"{"type":""# + String(repeating: "a", count: 16 * 1_024) + #""}"#
        XCTAssertNil(MobileRoomTypePolicy.roomType(createContentJSON: oversized))
    }
}
