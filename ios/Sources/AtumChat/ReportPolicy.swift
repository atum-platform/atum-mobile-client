import Foundation

/// Report a person or a message (App Review guideline 1.2: report beside
/// block for user content), as on the desktop:
///
/// - Report person (`roster-model.ts` `reportablePerson`): offered where Block
///   is, in a personal chat or group you can delete or leave, never for
///   yourself, an assistant or an app's bot, a Team Space room, or the Founder
///   chat while you are the Founder.
/// - Report message (`app.tsx` `reportMenu`): a person's message the server
///   has, never your own, an assistant's or an app bot's.
///
/// The report carries only identifiers and the person's own optional reason,
/// never message text (desktop `reportMatrixEvent`).
public enum ReportPolicy {
    /// Desktop `MATRIX_REPORT_REASON_MAX`, in characters.
    public static let reasonLimit = 500
    /// The reason the desktop's SDK sends when the person gives none
    /// (`MATRIX_REPORT_DEFAULT_REASON`). Protocol data, never shown.
    public static let defaultReason = "abuse"

    /// Who someone in the chat is.
    public enum Member: Equatable, Sendable {
        case person
        case assistant
        case app
    }

    /// Whether this member may be reported from the panel or the Members
    /// page: a person, never yourself, in a chat that offers Delete chat or
    /// Leave group (`ChatExitPolicy.action` is the desktop's
    /// `personalChatActions(...).end`).
    public static func mayReportPerson(_ member: Member, isSelf: Bool, in room: ChatExitPolicy.Room,
                                       viewerIsFounder: Bool) -> Bool {
        guard member == .person, !isSelf else { return false }
        return ChatExitPolicy.action(for: room, viewerIsFounder: viewerIsFounder) != nil
    }

    /// Whether the long-press menu offers Report on this row: a person's
    /// message, image or file in a person chat or group, with its server
    /// event. `nonPersonSenders` holds every assistant and app bot the phone
    /// knows (the room's agent, the account's agents and the catalog bots).
    public static func mayReportMessage(_ item: ChatItem, in kind: RoomKind,
                                        nonPersonSenders: Set<String>) -> Bool {
        switch kind {
        case .person, .group: break
        case .assistant, .appBot: return false
        }
        guard !item.isOwn, !item.sender.isEmpty, !nonPersonSenders.contains(item.sender) else { return false }
        return reportableEventID(item) != nil
    }

    /// The event a report of this row names: a message, image or file the
    /// server has (an event ID, never a local echo or a failed send).
    public static func reportableEventID(_ item: ChatItem) -> String? {
        switch item.kind {
        case .message, .image, .file: break
        default: return nil
        }
        switch item.delivery {
        case .remote, .sent: break
        case .sending, .failed: return nil
        }
        guard case let .event(eventID) = item.eventOrTransactionId, eventID.hasPrefix("$") else { return nil }
        return eventID
    }

    /// The person's words, as the desktop sends them (`ipc-policy.ts`):
    /// control characters become spaces, runs of white space become one, the
    /// ends are trimmed and it is held to `reasonLimit` characters. Nil when
    /// nothing is left.
    public static func reason(_ text: String) -> String? {
        let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) }
        let words = String(scalars).split(whereSeparator: { $0.isWhitespace })
        let joined = words.joined(separator: " ")
        guard !joined.isEmpty else { return nil }
        return String(joined.prefix(reasonLimit))
    }

    /// What one report asks the homeserver.
    public struct Request: Equatable, Sendable {
        public enum Target: Equatable, Sendable {
            /// `POST /rooms/{roomId}/report/{eventId}` (SDK `Room.reportContent`).
            case event(String)
            /// `POST /rooms/{roomId}/report` (SDK `Room.reportRoom`).
            case room
        }

        public let roomID: String
        public let target: Target
        /// Always set: the person's reason, else `defaultReason`.
        public let reason: String

        public init(roomID: String, target: Target, reason: String) {
            self.roomID = roomID
            self.target = target
            self.reason = reason
        }
    }

    /// Report one message, if the menu may offer it.
    public static func messageRequest(roomID: String, item: ChatItem, kind: RoomKind,
                                      nonPersonSenders: Set<String>, reason: String?) -> Request? {
        guard mayReportMessage(item, in: kind, nonPersonSenders: nonPersonSenders),
              let eventID = reportableEventID(item) else { return nil }
        return Request(roomID: roomID, target: .event(eventID), reason: Self.reason(reason ?? "") ?? defaultReason)
    }

    /// Report a person in this chat. The phone's Matrix SDK has no user
    /// report (MSC4260), so this is the desktop's own fallback for a
    /// homeserver without one: the latest message they sent here that the
    /// chat has loaded. A person chat with no such message reports the chat
    /// itself, which is only theirs and yours; a group never does (it would
    /// name everyone in it). Nil: nothing can be reported.
    public static func personRequest(roomID: String, userID: String, ownUserID: String, kind: RoomKind,
                                     items: [ChatItem], reason: String?) -> Request? {
        guard !userID.isEmpty, userID != ownUserID else { return nil }
        let reason = Self.reason(reason ?? "") ?? defaultReason
        if let latest = items.last(where: { $0.sender == userID && !$0.isOwn && reportableEventID($0) != nil }),
           let eventID = reportableEventID(latest) {
            return Request(roomID: roomID, target: .event(eventID), reason: reason)
        }
        return kind == .person ? Request(roomID: roomID, target: .room, reason: reason) : nil
    }
}

/// PENDING-COPY: report words the design export does not carry yet. The
/// desktop has them (`chat-copy.ts`); the wave 1 copy worker is adding them
/// to the export. Until the pin has a key, the phone reads the closest
/// exported key, `fallback`, so a build never shows a raw key or fails.
public enum ReportPendingCopy: String, CaseIterable, Sendable {
    /// "Report person" / "Báo cáo người này".
    case reportPerson = "src.matrix.chat-copy.copies.reportPerson"
    /// "Report this person?" / "Báo cáo người này?".
    case reportPersonTitle = "src.matrix.chat-copy.copies.reportPersonTitle"
    /// "Atum's moderators get the report. They aren't blocked." /
    /// "Đội kiểm duyệt của Atum sẽ nhận báo cáo. Người này không bị chặn.".
    case reportPersonBody = "src.matrix.chat-copy.copies.reportPersonBody"
    /// "Reason (optional)" / "Lý do (không bắt buộc)".
    case reportReason = "src.matrix.chat-copy.copies.reportReason"

    public var fallback: ChatCopyKey {
        switch self {
        case .reportPerson, .reportPersonTitle: .report
        case .reportPersonBody: .reportBody
        case .reportReason: .reportNote
        }
    }
}
