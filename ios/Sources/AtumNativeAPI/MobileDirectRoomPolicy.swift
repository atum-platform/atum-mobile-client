import Foundation

/// m.direct classifies rooms; current membership independently authorizes reuse.
/// Stable ordering keeps repeated picker opens on the same existing conversation.
public enum MobileDirectRoomPolicy {
    public static func roomIDs(accountData: String?, userID: String) throws -> [String] {
        guard let accountData else { return [] }
        let entries = try JSONDecoder().decode([String: [String]].self, from: Data(accountData.utf8))
        return Array(Set(entries[userID] ?? [])).sorted()
    }

    public static func canReuse(isJoined: Bool, isSpace: Bool, activeMemberCount: UInt64,
                                activeMemberIDs: [String], target: String,
                                hasCustomRoomType: Bool) -> Bool {
        isJoined && !isSpace && !hasCustomRoomType && activeMemberCount <= 2
            && activeMemberIDs.contains(target)
    }
}
