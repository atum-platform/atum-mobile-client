/// Which basic Matrix chat exits a row or a chat's info offers (owner,
/// 2026-11-04: "we should have all basic functionalities of chat from Matrix";
/// the desktop gains the same set in parallel).
///
/// - A person's DM: "Delete chat" (leave, then forget: gone from every device
///   of yours; the other person keeps their copy).
/// - A group: "Leave group" (leave; you stop getting its new messages).
/// - Ignoring a person (Matrix `m.ignored_user_list`): beside them in a
///   person chat or a group's people list, as on the desktop.
/// - Never: assistant chats (one conversation per assistant), app-bot chats
///   (their own Delete hides the bot chat; unlinking is the app's), team space
///   channels and conversations (the team space contract), the Founder chat
///   while you are the Founder, system rooms and invitations.
public enum ChatExitAction: String, Equatable, Sendable {
    case deleteChat
    case leaveGroup
}

public enum ChatExitPolicy {
    public enum Room: Equatable, Sendable {
        case person
        case group
        case assistant
        case appBot
        case teamSpace
        case founder
        case system
        case invitation
    }

    public static func action(for room: Room, viewerIsFounder: Bool) -> ChatExitAction? {
        switch room {
        case .person: .deleteChat
        case .group: .leaveGroup
        case .founder: viewerIsFounder ? nil : .deleteChat
        case .assistant, .appBot, .teamSpace, .system, .invitation: nil
        }
    }

    /// Whether a member may be ignored from this room's people: a person (never
    /// an assistant or yourself) in a person chat or a group.
    public static func mayIgnore(memberIsAssistant: Bool, memberIsSelf: Bool,
                                 in room: Room, viewerIsFounder: Bool) -> Bool {
        guard !memberIsAssistant, !memberIsSelf else { return false }
        switch room {
        case .person, .group: return true
        case .founder: return !viewerIsFounder
        case .assistant, .appBot, .teamSpace, .system, .invitation: return false
        }
    }
}
