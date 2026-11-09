import Foundation

/// Settings > Assistants lists the assistants Home lists, in Home's order, then
/// any whose chat has not reached this phone yet ("being prepared"). Names and
/// photos are the roster rows' own, so an assistant looks the same in both
/// places; nothing here asks the network for anything.
enum AccountAssistantRoster {
    /// - Parameters:
    ///   - readyRoomIDs: the room IDs of Home's assistant rows, in Home's order.
    ///   - rooms: the product rooms the roster was built from.
    ///   - titles: the one-line title each assistant was given, by agent ID.
    static func summaries(readyRoomIDs: [String],
                          rooms: [LiveProductRoom],
                          titles: [String: String]) -> [AccountAssistantSummary] {
        var byID = [String: LiveProductRoom]()
        for room in rooms where byID[room.id] == nil { byID[room.id] = room }

        var listed = Set<String>()
        var result = [AccountAssistantSummary]()
        for id in readyRoomIDs {
            guard listed.insert(id).inserted, let room = byID[id] else { continue }
            result.append(summary(room, isReady: true, titles: titles))
        }
        // An active assistant whose room has not arrived yet: listed so the
        // page tells the truth, but there is no card to open.
        for room in rooms where room.kind == .agent && room.isAwaitingRoom && !room.isAppBotRoom {
            guard listed.insert(room.id).inserted else { continue }
            result.append(summary(room, isReady: false, titles: titles))
        }
        return result
    }

    private static func summary(_ room: LiveProductRoom, isReady: Bool,
                                titles: [String: String]) -> AccountAssistantSummary {
        let photo: URL? = if case let .photo(url, _)? = room.avatar { url } else { nil }
        return AccountAssistantSummary(
            roomID: room.id,
            name: room.title,
            title: room.assistant.flatMap { titles[$0.id] },
            matrixAvatarURL: room.matrixAvatarURL,
            avatarURL: photo,
            avatarSHA256: room.avatarSHA256,
            isAtum: room.avatar == .eclipse,
            isPrimary: room.assistant?.isDefault == true,
            botHandle: room.assistant?.botHandle,
            isReady: isReady
        )
    }
}
