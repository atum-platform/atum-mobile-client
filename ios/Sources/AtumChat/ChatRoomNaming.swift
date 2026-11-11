import Foundation

/// HC-7 (lane 1 S7): your own name for a chat, private to you, as desktop
/// keeps it: the room account data event `io.atum.title` with content
/// `{"title": "…"}` (`{}` once cleared). Desktop `conversations.ts`
/// `MATRIX_TITLE_ACCOUNT_DATA` / `matrixChatTitle(value)`, `sdk.ts` `chatTitle`.
public enum ChatPrivateTitle {
    public static let eventType = "io.atum.title"
    /// Desktop `MATRIX_CHAT_TITLE_MAX`.
    public static let maximumLength = 80
    private static let maximumEventBytes = 4 * 1_024

    /// One line: control characters as spaces, runs of space as one, trimmed.
    public static func normalized(_ value: String) -> String {
        let spaced = String(String.UnicodeScalarView(value.unicodeScalars.map {
            $0.properties.generalCategory == .control ? " " : $0
        }))
        return spaced.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A stored name, as one bounded line; anything else is no name.
    public static func title(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let title = normalized(value)
        return !title.isEmpty && title.count <= maximumLength ? title : nil
    }

    /// The name in the SDK's raw room account data event
    /// (`{"type": "io.atum.title", "content": {"title": "…"}}`).
    public static func title(eventJSON: String?) -> String? {
        guard let eventJSON, eventJSON.utf8.count <= maximumEventBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(eventJSON.utf8)) as? [String: Any],
              object["type"] as? String == eventType,
              let content = object["content"] as? [String: Any] else { return nil }
        return title(content["title"])
    }

    /// The content to save: `{"title": …}`, or `{}` to clear the name.
    public static func content(_ input: String) -> [String: String] {
        let title = normalized(input)
        return title.isEmpty ? [:] : ["title": title]
    }

    /// Whether Save may run: a private name may be cleared (empty), a shared
    /// group name may not (desktop `empty = shared && !name.trim()`).
    public static func canSave(_ input: String, shared: Bool) -> Bool {
        let title = normalized(input)
        if title.count > maximumLength { return false }
        return !(shared && title.isEmpty)
    }
}

/// A group's topic, as desktop edits it (`group-details.tsx`,
/// `matrixGroupTopic`): one line, at most `maximumLength` characters.
public enum ChatGroupTopic {
    /// Desktop `MATRIX_GROUP_TOPIC_MAX`.
    public static let maximumLength = 500

    public static func normalized(_ value: String) -> String {
        String(ChatPrivateTitle.normalized(value).prefix(maximumLength))
    }
}

/// Which chats offer which menu items (desktop `roster-model.ts`
/// `personalChatActions`, `personalGroupDetails`, `RosterRoomMenu`).
public enum ChatMenuPolicy {
    public enum Room: Equatable, Sendable {
        case person
        case group
        case founder
        case notesSelf
        case assistant
        case appBot
        case teamSpace
    }

    /// Rename: a person or group chat. The Founder's and your notes' names
    /// are the app's; assistants are renamed on their card (lane 3).
    public static func offersRename(_ room: Room) -> Bool {
        room == .person || room == .group
    }

    /// Rename names the group for everyone (`m.room.name`) when its power
    /// levels let you; otherwise it is your own private name.
    public static func renamesForEveryone(_ room: Room, canName: Bool) -> Bool {
        room == .group && canName
    }

    /// Block: the other person of a person chat, never yourself; the
    /// Founder's chat is the Founder's own to keep.
    public static func blockablePeer(_ room: Room, memberUserIDs: [String], ownUserID: String,
                                     nonPersonUserIDs: Set<String>) -> String? {
        guard room == .person || room == .founder else { return nil }
        let others = memberUserIDs.filter { $0 != ownUserID }
        guard others.count == 1, let peer = others.first, !nonPersonUserIDs.contains(peer) else { return nil }
        return peer
    }
}
