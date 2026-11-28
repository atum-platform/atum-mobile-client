public enum RoomUpgradeDestination: Equatable, Sendable {
    case join(roomID: String)
    case open(roomID: String)
    case waitingForState
    case unavailable
}

public struct RoomUpgradeContinuity: Equatable, Sendable {
    public var successor: RoomUpgradeDestination?
    public var earlierRoomID: String?

    public init(successor: RoomUpgradeDestination? = nil, earlierRoomID: String? = nil) {
        self.successor = successor
        self.earlierRoomID = earlierRoomID
    }
}

public enum RoomUpgradeRules {
    public static func isRoomID(_ value: String) -> Bool {
        value.first == "!" && (2...512).contains(value.utf8.count)
            && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    public static func links(old: String, replacement: String, predecessor: String?) -> Bool {
        old != replacement && isRoomID(old) && isRoomID(replacement) && predecessor == old
    }

    public static func successor(old: String, replacement: String, joined: Bool,
                                 hasCreateState: Bool, predecessor: String?) -> RoomUpgradeDestination {
        guard isRoomID(old), isRoomID(replacement), old != replacement else { return .unavailable }
        if hasCreateState, !links(old: old, replacement: replacement, predecessor: predecessor) {
            return .unavailable
        }
        if !joined { return .join(roomID: replacement) }
        return hasCreateState ? .open(roomID: replacement) : .waitingForState
    }

    /// Suppresses a verified predecessor only when its successor is also a
    /// visible joined chat. Keep any cyclic chain reachable.
    public static func hiddenPredecessors(verifiedLinks: [String: String]) -> Set<String> {
        Set(verifiedLinks.keys.filter { old in
            var visited = Set<String>()
            var cursor = old
            while let successor = verifiedLinks[cursor] {
                guard visited.insert(cursor).inserted else { return false }
                cursor = successor
            }
            return true
        })
    }
}
