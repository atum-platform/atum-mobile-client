import Foundation

/// The desktop's per-person room account data for an official bot's chat,
/// read on the phone through the SDK's cached, read-only
/// `Room.accountDataRaw(eventType:)`. The phone never writes either event:
/// its own "Delete chat" stays in `MobileHiddenRoomLedger`.
///
/// Both parsers take the raw event JSON the SDK returns (`{"type", "content",
/// ...}`), require exactly the desktop's content keys, and are as strict as
/// the desktop's readers
/// (atum-app `apps/desktop/src/matrix/app-bot-dm.ts` `appBotDmHiddenAt` and
/// `conversations.ts` `legacyAppBotMoved`). Anything else carries no authority,
/// so a malformed, oversized or cleared (`{}`) event leaves the room visible.
public enum MobileAppBotRoomAccountData {
    /// Delete chat on the desktop: `{v: 1, at}` with `at` in Matrix milliseconds.
    public static let hiddenType = "io.atum.app_bot.hidden"
    /// The "moved" note on a retired official bot chat:
    /// `{v: 1, app_id, bot_user_id, moved_at}`.
    public static let legacyMovedType = "io.atum.app_bot.legacy_moved"

    private static let maximumEventBytes = 4 * 1_024
    private static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    /// When the person deleted this bot chat on the desktop, if they did.
    public static func hiddenAt(eventJSON: String?) -> UInt64? {
        guard let envelope = envelope(eventJSON, type: hiddenType),
              envelope.keyCount == 2,
              let version = envelope.integer("v"), version == 1,
              let at = envelope.integer("at"), at > 0, at <= maximumSafeInteger
        else { return nil }
        return UInt64(at)
    }

    /// The desktop's rule: the deleted chat stays out of sight until a message
    /// is newer than the time it was deleted. `lastMessageAt` is 0 for a room
    /// nobody has written in.
    public static func isHidden(hiddenAt: UInt64?, lastMessageAt: UInt64) -> Bool {
        guard let hiddenAt else { return false }
        return lastMessageAt <= hiddenAt
    }

    /// The retired official bot chat this room is, if the note is valid.
    public static func legacyMove(eventJSON: String?) -> MobileLegacyAppBotMove? {
        guard let envelope = envelope(eventJSON, type: legacyMovedType),
              envelope.keyCount == 4,
              let version = envelope.integer("v"), version == 1,
              let appID = envelope.string("app_id"), isAppID(appID),
              let botUserID = envelope.string("bot_user_id"), isUserID(botUserID),
              let movedAt = envelope.integer("moved_at"), movedAt >= 0, movedAt <= maximumSafeInteger
        else { return nil }
        return MobileLegacyAppBotMove(appID: appID, botUserID: botUserID, movedAt: UInt64(movedAt))
    }

    // MARK: - Parsing

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    /// The event's content as a keyed container, with the event type already
    /// checked. Scalar lookups decode on demand, so a wrong-typed field (a
    /// string where a number belongs, a float, a boolean) is simply absent.
    private struct Envelope: Decodable {
        let type: String
        let content: Content

        var keyCount: Int { content.keys.count }
        func integer(_ key: String) -> Int64? { content.integer(key) }
        func string(_ key: String) -> String? { content.string(key) }

        struct Content: Decodable {
            let keys: [AnyKey]
            private let container: KeyedDecodingContainer<AnyKey>

            init(from decoder: Decoder) throws {
                container = try decoder.container(keyedBy: AnyKey.self)
                keys = container.allKeys
            }

            func integer(_ key: String) -> Int64? {
                AnyKey(stringValue: key).flatMap { try? container.decode(Int64.self, forKey: $0) }
            }

            func string(_ key: String) -> String? {
                AnyKey(stringValue: key).flatMap { try? container.decode(String.self, forKey: $0) }
            }
        }
    }

    private static func envelope(_ json: String?, type: String) -> Envelope? {
        guard let json,
              let data = json.data(using: .utf8),
              data.count <= maximumEventBytes,
              let value = try? JSONDecoder().decode(Envelope.self, from: data),
              value.type == type
        else { return nil }
        return value
    }

    private static func isAppID(_ value: String) -> Bool {
        value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$",
                    options: .regularExpression) != nil
    }

    private static func isUserID(_ value: String) -> Bool {
        value.range(of: "^@[^:\\s]+:[^\\s]+$", options: .regularExpression) != nil
    }
}

/// A valid `io.atum.app_bot.legacy_moved` note: the room is a retired official
/// bot chat and is never offered as that bot's chat.
public struct MobileLegacyAppBotMove: Equatable, Sendable {
    public let appID: String
    public let botUserID: String
    public let movedAt: UInt64

    public init(appID: String, botUserID: String, movedAt: UInt64) {
        self.appID = appID
        self.botUserID = botUserID
        self.movedAt = movedAt
    }
}
