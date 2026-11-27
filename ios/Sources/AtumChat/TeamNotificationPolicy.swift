import CryptoKit
import Foundation

/// Desktop's per-account presentation preferences. Matrix push rules make the
/// delivery decision first. These preferences can only suppress an admitted event.
public struct TeamNotificationPolicy: Sendable {
    public static let legacyType = "io.atum.notifications.v1"
    private static let targetPrefix = "io.atum.notification.v2."

    public static func applies(toRoomType type: String?) -> Bool {
        type == "io.atum.company_channel.v1" || type == "io.atum.company_conversation.v1"
    }

    /// Extract only intentional mentions from the SDK-fetched event. Keyword
    /// highlights and plain-text name matches belong to Matrix's room rules.
    public static func intentionalMentions(eventJSON: String, ownUserID: String) -> (direct: Bool, room: Bool) {
        struct Event: Decodable {
            struct Content: Decodable {
                struct Mentions: Decodable {
                    let user_ids: [String]?
                    let room: Bool?
                }
                let mentions: Mentions?
                enum CodingKeys: String, CodingKey { case mentions = "m.mentions" }
            }
            let content: Content
        }
        let mentions = (try? JSONDecoder().decode(Event.self, from: Data(eventJSON.utf8)))?.content.mentions
        return (mentions?.user_ids?.contains(ownUserID) == true, mentions?.room == true)
    }

    public enum Level: String, Codable, Sendable {
        case all, mentions, nothing
    }

    public enum Target: Sendable {
        case account, quietHours
        case channel(String)
        case thread(roomID: String, rootID: String)

        public var eventType: String {
            let key = switch self {
            case .account: "account"
            case .quietHours: "quiet-hours"
            case let .channel(roomID): "channel\u{0}" + roomID
            case let .thread(roomID, rootID): "thread\u{0}" + roomID + "\u{0}" + rootID
            }
            return TeamNotificationPolicy.targetPrefix + SHA256.hash(data: Data(key.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    public struct QuietHours: Decodable, Sendable {
        let enabled: Bool
        let startMinute: Int
        let endMinute: Int
        let timeZone: String

        var isValid: Bool {
            (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute)
                && (1...100).contains(timeZone.utf8.count) && TimeZone(identifier: timeZone) != nil
        }

        func contains(_ date: Date) -> Bool {
            guard enabled, startMinute != endMinute, let zone = TimeZone(identifier: timeZone) else { return false }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let time = calendar.dateComponents([.hour, .minute], from: date)
            guard let hour = time.hour, let minute = time.minute else { return false }
            let value = hour * 60 + minute
            if startMinute < endMinute { return value >= startMinute && value < endMinute }
            return value >= startMinute || value < endMinute
        }
    }

    public struct Legacy: Decodable, Sendable {
        let version: Int
        let accountLevel: Level
        let quietHours: QuietHours
        let channelOverrides: [String: Level]
        let threadOverrides: [String: [String: Level]]

        public static func parse(_ json: String) -> Legacy? {
            guard let value = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
                  value.version == 1, value.quietHours.isValid,
                  value.channelOverrides.count <= 500, value.threadOverrides.count <= 500,
                  value.channelOverrides.keys.allSatisfy({ validID($0, prefix: "!") }),
                  value.threadOverrides.values.reduce(0, { $0 + $1.count }) <= 1_000,
                  value.threadOverrides.allSatisfy({ roomID, threads in
                      validID(roomID, prefix: "!") && threads.keys.allSatisfy { validID($0, prefix: "$") }
                  })
            else { return nil }
            return value
        }
    }

    public struct Record: Decodable, Sendable {
        public let revision: Int
        let version: Int
        let expected_revision: Int
        let change: Change

        struct Change: Decodable, Sendable {
            let scope: String
            let roomId: String?
            let rootId: String?
            let level: String?
            let quietHours: QuietHours?
        }

        public static func parse(_ json: String, for target: Target) -> Record? {
            guard let value = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)),
                  value.version == 2, (1...9_007_199_254_740_991).contains(value.revision),
                  value.expected_revision == value.revision - 1 else { return nil }
            let change = value.change
            switch target {
            case .account:
                guard change.scope == "account", value.level != nil else { return nil }
            case .quietHours:
                guard change.scope == "quietHours", change.quietHours?.isValid == true else { return nil }
            case let .channel(roomID):
                guard change.scope == "channel", change.roomId == roomID, validID(roomID, prefix: "!"),
                      value.level != nil || value.isInherited else { return nil }
            case let .thread(roomID, rootID):
                guard change.scope == "thread", change.roomId == roomID, change.rootId == rootID,
                      validID(roomID, prefix: "!"), validID(rootID, prefix: "$"),
                      value.level != nil || value.isInherited else { return nil }
            }
            return value
        }

        var level: Level? { change.level.flatMap(Level.init(rawValue:)) }
        public var isInherited: Bool { change.level == "inherit" }

        /// A channel tombstone shadows the legacy aggregate across devices.
        public static func retiringChannel(_ roomID: String, previousRevision: Int) throws -> String {
            struct Retirement: Encodable {
                struct Change: Encodable {
                    let scope = "channel"
                    let level = "inherit"
                    let roomId: String
                }
                let version = 2
                let revision: Int
                let expected_revision: Int
                let change: Change
            }
            guard validID(roomID, prefix: "!"), (0..<9_007_199_254_740_991).contains(previousRevision)
            else { throw RecordError.invalid }
            let retirement = Retirement(revision: previousRevision + 1, expected_revision: previousRevision,
                                        change: .init(roomId: roomID))
            return String(decoding: try JSONEncoder().encode(retirement), as: UTF8.self)
        }

        private enum RecordError: Error { case invalid }
    }

    private let account: Level
    private let quietHours: QuietHours?
    public let legacyChannel: Level?
    private let thread: Level?
    private let appliesThreadDefault: Bool

    public init(roomID: String, rootID: String? = nil, legacy: Legacy?, account: Record? = nil,
                quietHours: Record? = nil, channel: Record? = nil, thread: Record? = nil) {
        self.account = account?.level ?? legacy?.accountLevel ?? .mentions
        self.quietHours = quietHours?.change.quietHours ?? legacy?.quietHours
        legacyChannel = channel == nil ? legacy?.channelOverrides[roomID] : channel?.level
        self.thread = if let rootID {
            thread == nil ? legacy?.threadOverrides[roomID]?[rootID] : thread?.level
        } else { nil }
        appliesThreadDefault = rootID != nil
    }

    /// Only an inherited room mode is narrowed by pre-parity channel data.
    /// Thread and quiet-hours preferences apply independently of the room mode.
    public func suppressesAdmittedNotification(roomIsInherited: Bool, hasAttention: Bool,
                                               now: Date = .now) -> Bool {
        if quietHours?.contains(now) == true { return true }
        let channel = roomIsInherited ? legacyChannel : nil
        let thread = appliesThreadDefault ? (thread ?? account) : nil
        return [channel, thread].contains { $0 == .nothing || ($0 == .mentions && !hasAttention) }
    }

    private static func validID(_ value: String, prefix: Character) -> Bool {
        value.first == prefix && (2...1_024).contains(value.unicodeScalars.count)
            && !value.unicodeScalars.contains { "\n\r\u{2028}\u{2029}".unicodeScalars.contains($0) }
    }
}
