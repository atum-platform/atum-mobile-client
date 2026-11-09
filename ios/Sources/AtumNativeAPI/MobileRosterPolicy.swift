import Foundation

/// One joined room with a given agent or app bot, as this phone sees it.
/// `encrypted` comes from the SDK's room info; nil means the SDK has not
/// learned the room's encryption state yet.
public struct MobileAgentRoomCandidate: Equatable, Sendable {
    public let roomID: String
    public let encrypted: Bool?
    public let latestTimestamp: UInt64?

    public init(roomID: String, encrypted: Bool?, latestTimestamp: UInt64?) {
        self.roomID = roomID
        self.encrypted = encrypted
        self.latestTimestamp = latestTimestamp
    }
}

/// One room in the chat list's input, in the SDK's room-list order.
/// `agentKey` names the agent or bot whose chat this room may be (the same key
/// for every room with that agent or bot); nil for people and group rooms.
public struct MobileRosterRoomEntry: Equatable, Sendable {
    public let roomID: String
    public let agentKey: String?
    public let encrypted: Bool?
    public let latestTimestamp: UInt64?

    public init(roomID: String, agentKey: String?, encrypted: Bool?, latestTimestamp: UInt64?) {
        self.roomID = roomID
        self.agentKey = agentKey
        self.encrypted = encrypted
        self.latestTimestamp = latestTimestamp
    }
}

/// What the chat list shows: every people and group room, plus exactly one
/// room per agent or bot, in the input order. `choices` holds the room chosen
/// for each agent key and the rooms left out for it. A key with more than one
/// known plain room has no choice; `duplicatePlainRoomCounts` records that
/// invariant failure so callers can diagnose it without selecting a room.
public struct MobileRosterListing: Equatable, Sendable {
    public let listedRoomIDs: [String]
    public let choices: [String: MobileAgentRoomChoice]
    public let duplicatePlainRoomCounts: [String: Int]
}

/// The one room the phone lists for an agent or bot, and the rooms it does
/// not list. Unlisted rooms stay on the server untouched; the phone just does
/// not show them anywhere.
public struct MobileAgentRoomChoice: Equatable, Sendable {
    public enum Reason: String, Sendable {
        /// The chat is a room without encryption (0.20 agent and bot rooms).
        case plain
        /// No room without encryption is known yet; the most recent room is
        /// the chat (the account has not moved to 0.20 rooms yet).
        case noPlainRoom = "no_plain_room"
    }

    public let chatRoomID: String
    public let hiddenRoomIDs: [String]
    public let reason: Reason
}

/// 0.20: one conversation per agent or bot. Among the rooms with the same
/// agent, the room without encryption is the agent's chat and the only one
/// listed; every other room with that agent (rooms with encryption, rooms
/// whose state is not known yet) is not listed. More than one plain room is
/// an invariant failure: none is guessed from activity, because sending to a
/// retired duplicate would make that wrong room newest and keep the phone
/// stuck there. With no plain room yet, the most recent room is the chat.
/// This reads only the room's encryption state, so no new server contract is
/// needed.
public enum MobileAgentRoomPolicy {
    /// The user IDs that may make a room an agent's or bot's chat. Only a
    /// room with the owner plus one other member (joined or invited) can be
    /// one; a bigger room is always a people or group row, whoever spoke last.
    /// The SDK's heroes are not a member count: the server leaves them out of
    /// any room that has a name and caps them at five, so they never decide
    /// the size of a room on their own.
    public static func candidateUserIDs(memberCount: UInt64, heroes: [String],
                                        latestSenderID: String?) -> [String] {
        guard memberCount <= 2, heroes.count <= 1 else { return [] }
        return heroes + [latestSenderID].compactMap { $0 }
    }

    public static func choose(_ rooms: [MobileAgentRoomCandidate]) -> MobileAgentRoomChoice? {
        guard !rooms.isEmpty else { return nil }
        let plain = rooms.filter { $0.encrypted == false }
        guard plain.count <= 1 else { return nil }
        let reason: MobileAgentRoomChoice.Reason = plain.isEmpty ? .noPlainRoom : .plain
        guard let chat = mostRecent(plain.isEmpty ? rooms : plain) else { return nil }
        let hidden = rooms.filter { $0.roomID != chat.roomID }
            .sorted { order($0, before: $1) }
            .map(\.roomID)
        return MobileAgentRoomChoice(chatRoomID: chat.roomID, hiddenRoomIDs: hidden, reason: reason)
    }

    /// The rooms the chat list shows. People and group rooms are all listed;
    /// for each agent or bot only its chosen room is listed, at that room's
    /// place in the input order. The other rooms with that agent or bot are
    /// not listed anywhere. A room ID that repeats is listed once.
    public static func listing(_ rooms: [MobileRosterRoomEntry]) -> MobileRosterListing {
        var groups = [String: [MobileAgentRoomCandidate]]()
        for room in rooms {
            guard let key = room.agentKey else { continue }
            groups[key, default: []].append(MobileAgentRoomCandidate(
                roomID: room.roomID, encrypted: room.encrypted, latestTimestamp: room.latestTimestamp
            ))
        }
        var choices = [String: MobileAgentRoomChoice]()
        var duplicatePlainRoomCounts = [String: Int]()
        for (key, candidates) in groups {
            if let choice = choose(candidates) {
                choices[key] = choice
            } else {
                let plainCount = candidates.count { $0.encrypted == false }
                if plainCount > 1 { duplicatePlainRoomCounts[key] = plainCount }
            }
        }
        var seen = Set<String>()
        let listed = rooms.compactMap { room -> String? in
            guard seen.insert(room.roomID).inserted else { return nil }
            guard let key = room.agentKey else { return room.roomID }
            return choices[key]?.chatRoomID == room.roomID ? room.roomID : nil
        }
        return MobileRosterListing(listedRoomIDs: listed, choices: choices,
                                   duplicatePlainRoomCounts: duplicatePlainRoomCounts)
    }

    private static func mostRecent(_ rooms: [MobileAgentRoomCandidate]) -> MobileAgentRoomCandidate? {
        rooms.sorted { order($0, before: $1) }.first
    }

    /// Newest first; a stable room-ID tie break keeps the list from jumping.
    private static func order(_ left: MobileAgentRoomCandidate, before right: MobileAgentRoomCandidate) -> Bool {
        let l = left.latestTimestamp ?? 0
        let r = right.latestTimestamp ?? 0
        return l == r ? left.roomID < right.roomID : l > r
    }
}

/// The name shown above someone else's message. A known agent or bot uses
/// its server-authored name; anyone else uses their profile display name.
/// A profile name that matches a known agent or bot name (ignoring case and
/// width) is not shown for anyone but that agent or bot, so a person cannot
/// look like the owner's agent in a group.
/// The raw Matrix ID is never shown: without a usable name there is no label.
public enum MobileSenderLabelPolicy {
    /// `knownNames` maps each known agent and bot user ID to its name.
    public static func label(senderID: String, profileDisplayName: String?,
                             knownNames: [String: String]) -> String? {
        if let name = usable(knownNames[senderID], senderID: senderID) { return name }
        guard let profile = usable(profileDisplayName, senderID: senderID) else { return nil }
        let folded = fold(profile)
        let collides = knownNames.contains { userID, name in
            userID != senderID && fold(name) == folded
        }
        return collides ? nil : profile
    }

    private static func usable(_ value: String?, senderID: String) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed != senderID,
              !looksLikeMatrixID(trimmed),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return trimmed
    }

    /// NFKC folds full-width and compatibility forms; whitespace runs collapse.
    private static func fold(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func looksLikeMatrixID(_ value: String) -> Bool {
        value.hasPrefix("@") && value.contains(":")
    }
}

/// Agents and bots invite the owner to their rooms. The phone accepts an
/// invite on its own only when the inviter is one of the owner's agents
/// (`/agents`) or a catalog bot (`/apps`); every other invite waits.
public enum MobileInvitePolicy {
    /// An invitation to a room whose create event claims the company conversation type is never
    /// accepted on an inviter's say-so: only directory-confirmed conversation convergence joins one.
    public static func shouldAutoAccept(inviterID: String?, knownAgentAndBotUserIDs: Set<String>,
                                        roomType: String? = nil) -> Bool {
        guard !ConversationTypeGuard.excludedFromBotAndAgent(roomType: roomType) else { return false }
        guard let inviterID, !inviterID.isEmpty else { return false }
        return knownAgentAndBotUserIDs.contains(inviterID)
    }
}

/// No downgrade on the phone. A message sent without encryption into a room
/// that has encryption is not shown: anyone able to slip events into the room
/// could otherwise post a normal-looking bubble. Rooms without encryption
/// (0.20 agent, bot, people and group rooms) are unaffected. An unknown room
/// state keeps the refusal.
public enum MobilePlaintextEventPolicy {
    public static func shows(roomEncrypted: Bool?, sentInClear: Bool) -> Bool {
        roomEncrypted == false || !sentInClear
    }
}
