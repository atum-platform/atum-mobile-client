import Foundation

/// Display-safe room-type parsing from the SDK's cached `m.room.create`
/// state. Room creation is already part of the room-list required state, so
/// this does not add a second Matrix request path.
public enum MobileRoomTypePolicy {
    public static let agentTask = "io.atum.agent_task.v1"
    private static let maximumCreateContentBytes = 16 * 1_024

    private struct CreateContent: Decodable {
        let type: String?
    }

    public static func roomType(createContentJSON: String?) -> String? {
        guard let createContentJSON,
              let data = createContentJSON.data(using: .utf8),
              data.count <= maximumCreateContentBytes,
              let value = try? JSONDecoder().decode(CreateContent.self, from: data),
              let type = value.type,
              (1...255).contains(type.utf8.count),
              !type.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return type
    }

    public static func isAgentTask(_ roomType: String?) -> Bool {
        roomType == agentTask
    }

    /// The desktop's notes-to-self room (atum-app `shared/matrix-notes-self.ts`,
    /// `MATRIX_NOTES_SELF_ROOM_TYPE`): the owner alone, so the SDK names it
    /// "Empty Room". The desktop keeps every such room out of the Chats roster
    /// (`roster-model.ts`, `matrixNotesSelfKnownRoom`) and opens personal notes
    /// from the Team space instead.
    public static let notesSelf = "com.atum.notes.self"

    public static func isNotesSelf(_ roomType: String?) -> Bool {
        roomType == notesSelf
    }

    /// Rooms that are never a Chats row on any Atum client: agent task rooms
    /// and notes-to-self rooms.
    public static func isHiddenFromChats(_ roomType: String?) -> Bool {
        isAgentTask(roomType) || isNotesSelf(roomType)
    }
}
