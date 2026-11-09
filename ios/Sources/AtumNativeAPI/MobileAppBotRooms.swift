import Foundation

/// Moon, Andy and later app bots each have one conversation per person. The
/// phone never leaves or forgets that room: leaving would make the desktop
/// create a fresh, empty room on the next open (0.19.3 diagnosis §2.1). The
/// phone's "Delete chat" therefore only hides the room on this phone.
public enum MobileAppBotRoomPolicy {
    /// Official bot localparts, used when the server app catalog has not loaded.
    /// The catalog's bot user IDs remain the primary source.
    public static let officialBotLocalparts: Set<String> = ["app-moon", "app-andy"]

    public static func isAppBotUser(_ userID: String, catalogBotUserIDs: Set<String>) -> Bool {
        if catalogBotUserIDs.contains(userID) { return true }
        guard userID.hasPrefix("@"), let separator = userID.firstIndex(of: ":") else { return false }
        let localpart = userID[userID.index(after: userID.startIndex)..<separator]
        return officialBotLocalparts.contains(String(localpart))
    }

    /// Returns the bot's user ID when the room is the owner's one-to-one room
    /// with an app bot. A group that merely contains a bot is not a bot room.
    public static func botUserID(heroes: [String],
                                 latestSenderID: String?,
                                 isDirect: Bool,
                                 catalogBotUserIDs: Set<String>) -> String? {
        if heroes.count == 1, let only = heroes.first,
           isAppBotUser(only, catalogBotUserIDs: catalogBotUserIDs) {
            return only
        }
        if heroes.isEmpty, isDirect, let latestSenderID,
           isAppBotUser(latestSenderID, catalogBotUserIDs: catalogBotUserIDs) {
            return latestSenderID
        }
        return nil
    }

    /// Account-data type of the desktop's durable pointer to the one room per
    /// person for this app (`{v: 1, room_id, bot_user_id}`).
    public static func pointerEventType(appID: String) -> String {
        "io.atum.app_bot.dm.\(appID)"
    }

    /// Room-state type the desktop puts in a bot chat it creates
    /// (atum.app-bots/1 §4.1), so every device recognises the room.
    public static let markerEventType = "io.atum.app_bot.dm"

    /// `{v:1, app_id, bot_user_id}`: the marker content, in the desktop's shape.
    public static func markerContentJSON(appID: String, botUserID: String) -> String? {
        encoded(["v": 1, "app_id": appID, "bot_user_id": botUserID])
    }

    /// `{v:1, room_id, bot_user_id}`: the account-data pointer content, the
    /// same shape `pointerRoomID` reads back.
    public static func pointerContentJSON(roomID: String, botUserID: String) -> String? {
        guard roomID.hasPrefix("!") else { return nil }
        return encoded(["v": 1, "room_id": roomID, "bot_user_id": botUserID])
    }

    private static func encoded(_ value: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The room the desktop pointer names for this bot, or nil when the
    /// pointer is missing, malformed, another version, or for another bot.
    public static func pointerRoomID(contentJSON: String?, botUserID: String) -> String? {
        struct Pointer: Decodable {
            let v: Int
            let room_id: String
            let bot_user_id: String
        }
        guard let data = contentJSON?.data(using: .utf8),
              let pointer = try? JSONDecoder().decode(Pointer.self, from: data),
              pointer.v == 1,
              pointer.bot_user_id == botUserID,
              pointer.room_id.hasPrefix("!") else { return nil }
        return pointer.room_id
    }

    /// The bot's one chat on this phone, in desktop's order (`chooseAppBotDm`,
    /// atum-app `apps/desktop/src/matrix/app-bot-dm.ts`), used for both the
    /// chat list and reopening from the app row so the phone and the Mac open
    /// the same room (revamp plan §4.2 item 2). Since 0.20 the bot's chat is
    /// a plain room: a room with encryption, or one whose encryption state is
    /// not known yet, is never chosen.
    /// 1. a plain room the bot invited the person back to, when no working
    ///    plain room has a message (a working room with messages wins: the
    ///    person is already talking there);
    /// 2. the pointer's room, when it works and is plain, unless it is empty
    ///    and another working plain room has messages;
    /// 3. the working plain room with the most recent message, else the most
    ///    recently active one.
    /// Desktop's remaining steps create or move a room; those stay on the
    /// Mac. With no choice, the phone lists no row for the bot and opens
    /// nothing (§4.2 item 1).
    public static func chooseChat(pointerRoomID: String?,
                                  candidates: [MobileAppBotChatCandidate]) -> MobileAppBotChatChoice? {
        let pointer = pointerRoomID.flatMap { id in candidates.first { $0.roomID == id } }
        let working = candidates.filter { $0.isWorking && $0.encrypted == false }.sorted(by: byHistory)
        let talked = working.contains { $0.lastMessageAt > 0 }

        let invitedOrder = (pointer.map { [$0] } ?? [])
            + candidates.filter { $0.roomID != pointer?.roomID }.sorted(by: byHistory)
        if !talked, let invited = invitedOrder.first(where: {
            $0.membership == .invited && $0.invitedByBot && $0.encrypted == false
        }) {
            return MobileAppBotChatChoice(roomID: invited.roomID, action: .join, reason: .invited)
        }
        if let pointer, pointer.isWorking, pointer.encrypted == false, pointer.lastMessageAt > 0 || !talked {
            return MobileAppBotChatChoice(roomID: pointer.roomID, action: .open, reason: .pointer)
        }
        if let best = working.first {
            return MobileAppBotChatChoice(roomID: best.roomID, action: .open, reason: .mostHistory)
        }
        return nil
    }

    /// The room with the most history first: the latest message, then the
    /// latest activity, then the room ID (desktop `byHistory`).
    private static func byHistory(_ left: MobileAppBotChatCandidate, _ right: MobileAppBotChatCandidate) -> Bool {
        if left.lastMessageAt != right.lastMessageAt { return left.lastMessageAt > right.lastMessageAt }
        if left.lastActiveAt != right.lastActiveAt { return left.lastActiveAt > right.lastActiveAt }
        return left.roomID < right.roomID
    }

    /// The one line a catalog bot's notice shows from S1 (§4.2 item 3). A
    /// bot notice body is "vi line, newline, en line" (the cloud controller's
    /// app-bot pipeline). When the sender is the catalog bot, the message is a
    /// notice and the body has exactly two non-empty lines, the line in the
    /// phone's language is shown (Vietnamese for `vi`, English otherwise);
    /// anything else shows the whole body. S5 replaces this with the notice's
    /// metadata and a real button.
    public static func noticeLine(body: String, senderIsCatalogBot: Bool, isNotice: Bool,
                                  languageCode: String) -> String {
        guard senderIsCatalogBot, isNotice else { return body }
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.count == 2, lines.allSatisfy({ !$0.isEmpty }) else { return body }
        return languageCode.lowercased().hasPrefix("vi") ? lines[0] : lines[1]
    }
}

/// One room this phone holds with a given app bot (desktop
/// `AppBotDmCandidate`, without rooms the phone no longer holds: those can
/// only matter to the Mac's create step).
public struct MobileAppBotChatCandidate: Equatable, Sendable {
    public enum Membership: String, Sendable {
        case joined
        case invited
    }

    public let roomID: String
    public let membership: Membership
    /// Joined and the person's one-to-one room with this bot
    /// (`MobileAppBotRoomPolicy.botUserID` names this bot).
    public let isOneToOneWithBot: Bool
    /// An invitation sent by the bot itself, the only one accepted on the
    /// person's behalf.
    public let invitedByBot: Bool
    /// The room has encryption. Nil while the SDK does not know yet: never
    /// treated as plain.
    public let encrypted: Bool?
    /// Matrix milliseconds of the latest message; 0 when nobody has written.
    public let lastMessageAt: UInt64
    /// Matrix milliseconds of the latest activity of any kind.
    public let lastActiveAt: UInt64

    public init(roomID: String, membership: Membership, isOneToOneWithBot: Bool, invitedByBot: Bool,
                encrypted: Bool?, lastMessageAt: UInt64, lastActiveAt: UInt64) {
        self.roomID = roomID
        self.membership = membership
        self.isOneToOneWithBot = isOneToOneWithBot
        self.invitedByBot = invitedByBot
        self.encrypted = encrypted
        self.lastMessageAt = lastMessageAt
        self.lastActiveAt = lastActiveAt
    }

    /// Works as the bot's chat now: joined, and only the person and the bot.
    var isWorking: Bool { membership == .joined && isOneToOneWithBot }
}

/// The room the phone lists and opens for an app bot.
public struct MobileAppBotChatChoice: Equatable, Sendable {
    public enum Action: String, Sendable {
        /// Open the joined room.
        case open
        /// Accept the bot's invitation, then open the room.
        case join
    }

    /// Closed log codes (desktop `AppBotDmReason` subset).
    public enum Reason: String, Sendable {
        case invited
        case pointer
        case mostHistory = "most_history"
    }

    public let roomID: String
    public let action: Action
    public let reason: Reason

    public init(roomID: String, action: Action, reason: Reason) {
        self.roomID = roomID
        self.action = action
        self.reason = reason
    }
}

/// Rooms hidden from this phone's list: an explicit bot-chat delete, or a
/// Founder race loser that could not be safely left and forgotten. The value is the hide time:
/// the later of the room's latest message time and the phone's clock when it
/// was hidden. Only a message after that brings the room back, like deleting a
/// chat in Telegram; an older event that only becomes readable later (old
/// history unlocked, or the latest event loading after a restart) does not.
/// Opening the bot again also brings back the same room. Room IDs are local
/// list state, not secrets.
public struct MobileHiddenRoomLedger: Codable, Equatable, Sendable {
    public private(set) var hiddenAt: [String: UInt64]

    public init(hiddenAt: [String: UInt64] = [:]) {
        self.hiddenAt = hiddenAt
    }

    /// `nowMillis` is the phone's clock in Matrix milliseconds, passed in so
    /// the rule stays deterministic.
    public mutating func hide(roomID: String, latestTimestamp: UInt64?, nowMillis: UInt64) {
        hiddenAt[roomID] = max(latestTimestamp ?? 0, nowMillis)
    }

    @discardableResult
    public mutating func unhide(roomID: String) -> Bool {
        hiddenAt.removeValue(forKey: roomID) != nil
    }

    public func isHidden(roomID: String, latestTimestamp: UInt64?) -> Bool {
        guard let mark = hiddenAt[roomID] else { return false }
        return (latestTimestamp ?? 0) <= mark
    }

    /// Drops entries whose room now has a newer message and returns those room
    /// IDs, sorted. Rooms missing from `latestTimestamps` keep their entry: the
    /// room list may still be loading.
    public mutating func pruneRevealed(latestTimestamps: [String: UInt64?]) -> [String] {
        var revealed = [String]()
        for roomID in Array(hiddenAt.keys) {
            guard let latest = latestTimestamps[roomID] else { continue }
            if !isHidden(roomID: roomID, latestTimestamp: latest) {
                hiddenAt.removeValue(forKey: roomID)
                revealed.append(roomID)
            }
        }
        return revealed.sorted()
    }
}
