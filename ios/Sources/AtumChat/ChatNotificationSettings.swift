import Foundation

/// Effective Matrix room mode. An inherited mode can have the same value as an explicit one.
public enum ChatNotificationMode: Equatable, Sendable {
    case all
    case mentionsAndKeywords
    case off
}

/// The native writer also removes conditional rules associated with the room.
/// Refuse changes that would erase a rule created for a separate purpose.
public enum RoomPushRulePolicy {
    public static func canChangeMode(rawRules: String?, roomID: String) -> Bool {
        guard let rawRules else { return true }
        guard let content = try? JSONSerialization.jsonObject(with: Data(rawRules.utf8)) as? [String: Any],
              let global = content["global"] as? [String: Any] else { return false }
        for kind in ["override", "underride"] {
            guard let raw = global[kind] else { continue }
            guard let rules = raw as? [[String: Any]] else { return false }
            for rule in rules {
                let conditions = rule["conditions"] as? [[String: Any]] ?? []
                let matchesRoom = conditions.contains {
                    $0["kind"] as? String == "event_match"
                        && $0["key"] as? String == "room_id"
                        && $0["pattern"] as? String == roomID
                }
                guard rule["rule_id"] as? String == roomID || matchesRoom else { continue }
                guard kind == "override", matchesRoom, conditions.count == 1,
                      let actions = rule["actions"] as? [String], actions.isEmpty || actions == ["dont_notify"]
                else { return false }
            }
        }
        return true
    }
}

public enum ChatNotificationChoice: Equatable, Sendable {
    case set(ChatNotificationMode)
    case restoreDefault
}

public struct ChatNotificationSettings: Equatable, Sendable {
    public let effectiveMode: ChatNotificationMode
    public let isInherited: Bool
    public let hasEncryptedMentionCaveat: Bool

    public init(effectiveMode: ChatNotificationMode, isInherited: Bool,
                hasEncryptedMentionCaveat: Bool) {
        self.effectiveMode = effectiveMode
        self.isInherited = isInherited
        self.hasEncryptedMentionCaveat = hasEncryptedMentionCaveat
    }

    public var selection: ChatNotificationChoice {
        isInherited ? .restoreDefault : .set(effectiveMode)
    }
}
