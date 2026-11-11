/// The kind of an open chat (plan §2.7). The app decides it from the existing
/// tested policies (`MobileAgentRoomPolicy` + `io.atum.conversation`,
/// `MobileAppBotRoomPolicy`, direct rooms, member counts). Old encrypted
/// agent and bot rooms are never opened, so they have no case here.
public enum RoomKind: String, Equatable, Hashable, Sendable, CaseIterable {
    /// The person's own assistant: the primary agent or another agent.
    case assistant
    /// Moon, Andy or another catalog app bot.
    case appBot
    /// A direct room with one other human.
    case person
    /// More than two members.
    case group

    /// B16 and §2.7: only groups show the sender's name, at the start of a
    /// run. A 1:1 chat (a person, my assistant, an app) shows no name: there
    /// is only one other sender (coordinator decision on the S0 open point,
    /// 2026-10-10: §2.7 wins over B16's S1a text). App chats showed the app's
    /// name until the owner's 2026-11-05 rule: "app chat matches agent chat
    /// and person chat - we want consistency". The header already names the
    /// app.
    public var showsSenderLine: Bool { self == .group }

    /// Only groups show the sender's face, beside the last bubble of a run
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
    /// need - we know who we're talking to)"). A 1:1 people chat, my
    /// assistant's chat and an app's chat draw no face and no face gutter.
    public var showsSenderFace: Bool { self == .group }

    /// Whether the room's agent or app wears the room's own face (the photo
    /// Home shows for the chat) when it sends or reads. True in 1:1 chats,
    /// where the room's face is the other sender's. In a group the room's
    /// face is the group's, so every member, an app or an assistant
    /// included, wears its own face.
    public var senderWearsRoomFace: Bool { self != .group }

    /// B12: only people rooms send typing notices; agent and bot rooms send
    /// nothing, as on desktop.
    public var sendsTypingNotices: Bool { self == .person || self == .group }
}

/// Who is who in one room, for the projection's rules.
public struct RoomContext: Equatable, Sendable {
    public var kind: RoomKind
    /// This account's Matrix user ID.
    public var ownUserID: String
    /// The room's agent or bot users: their text answers are results, and
    /// their notices that a result supersedes are hidden (B17, B21).
    public var agentUserIDs: Set<String>
    /// The platform's company-private CoS view binds this room to this account
    /// (`CompanyRoomClassification.privateCos`): only here is the Chief of
    /// Staff greeting's pill and board link projected (desktop proves the same
    /// room from its `io.atum.company_private_cos` state).
    public var isCompanyPrivateCos: Bool

    public init(kind: RoomKind, ownUserID: String, agentUserIDs: Set<String> = [],
                isCompanyPrivateCos: Bool = false) {
        self.kind = kind
        self.ownUserID = ownUserID
        self.agentUserIDs = agentUserIDs
        self.isCompanyPrivateCos = isCompanyPrivateCos
    }
}
