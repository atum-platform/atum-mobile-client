/// What the long-press menu offers on one row (plan B20–B22, §2.7, §3.5).
///
/// The menu view shows exactly these items, in this order; the store still
/// enforces each action (`ChatItemRules`), so a stale menu can never do more
/// than the row allows.
public enum MessageMenuItem: Equatable, Hashable, Sendable {
    /// The reaction palette (B22), the desktop set.
    case react
    /// "Trả lời" (B21).
    case reply
    /// "Reply in thread": Team Space channels and conversations only, on a
    /// message that is not itself in a thread (desktop `onThread`; nested
    /// threads are never made).
    case replyInThread
    /// "Sao chép": the raw text, as sent.
    case copy
    /// "Chọn văn bản": answers only; opens the select-text sheet.
    case selectText
    /// "Sửa": my text messages in people chats only.
    case edit
    /// "Báo cáo": a person's message, never mine, an assistant's or an app
    /// bot's (`ReportPolicy.mayReportMessage`; desktop `message-actions.tsx`).
    case report
    /// "Xóa": my own messages (destructive, last).
    case delete
}

/// One button of the reaction palette.
public struct ReactionChoice: Equatable, Hashable, Sendable {
    public var key: String
    /// I already reacted with this key: tapping removes it (a toggle).
    public var isSelected: Bool

    public init(key: String, isSelected: Bool) {
        self.key = key
        self.isSelected = isSelected
    }
}

public enum MessageMenuRules {
    /// Desktop's `MATRIX_QUICK_REACTIONS` (atum-app
    /// `apps/desktop/src/matrix/message-actions.tsx`), in its order. Data,
    /// not copy.
    public static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    /// The menu for `item` in a room of `kind`, in display order: the
    /// palette first, then reply, copy, select text, edit, report, delete. Empty
    /// means the row has no menu: notices (B17: no action), placeholders,
    /// room state, virtual and synthetic rows.
    ///
    /// §2.7 per room kind:
    /// - my assistant: copy, select (answers), reply, react, delete own;
    /// - Moon or Andy: copy, select (answers) only;
    /// - a person or a group: copy, reply, react, edit and delete own, and
    ///   report on someone else's.
    ///
    /// Report needs `nonPersonSenders` (every assistant and app bot the
    /// phone knows): without it the menu cannot tell a person from an
    /// assistant in a group, so it offers no Report.
    public static func items(for item: ChatItem, in kind: RoomKind,
                             nonPersonSenders: Set<String>? = nil,
                             threads: Bool = false) -> [MessageMenuItem] {
        switch item.kind {
        case .message, .image, .file: break
        default: return []
        }
        let isText = item.kind == .message
        let hasText = isText && !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isBotRoom = kind == .appBot
        var items: [MessageMenuItem] = []
        if !isBotRoom, ChatItemRules.canReact(item) { items.append(.react) }
        if !isBotRoom, ChatItemRules.canReply(item) { items.append(.reply) }
        if threads, !isBotRoom, threadRootID(for: item) != nil { items.append(.replyInThread) }
        if hasText { items.append(.copy) }
        if hasText, isAnswer(item, in: kind) { items.append(.selectText) }
        if ChatItemRules.canEdit(item, in: kind) { items.append(.edit) }
        if let nonPersonSenders, ReportPolicy.mayReportMessage(item, in: kind, nonPersonSenders: nonPersonSenders) {
            items.append(.report)
        }
        if !isBotRoom, ChatItemRules.canDelete(item) || isHeldSend(item) { items.append(.delete) }
        return items
    }

    /// The thread root a "Reply in thread" on `item` opens: the message's own
    /// server event ID, when it is a server message and not itself a thread
    /// reply (desktop: `actionable && !message.thread`). Nil otherwise.
    public static func threadRootID(for item: ChatItem) -> String? {
        switch item.kind {
        case .message, .image, .file: break
        default: return nil
        }
        guard item.threadRoot == nil, ChatItemRules.canReply(item),
              let eventID = item.eventID, eventID.hasPrefix("$") else { return nil }
        return eventID
    }

    /// A send tapped while no timeline was attached (a session renewal): it
    /// has no request yet, so only "Xóa" (which drops it) and "Sao chép"
    /// apply.
    public static func isHeldSend(_ item: ChatItem) -> Bool {
        item.isOwn && item.eventOrTransactionId == nil && item.id.hasPrefix(ConversationCore.heldRowPrefix)
    }

    /// B20: "on answers also Chọn văn bản": a message from the room's agent or
    /// bot, never my own and never a person's.
    public static func isAnswer(_ item: ChatItem, in kind: RoomKind) -> Bool {
        guard item.kind == .message, !item.isOwn else { return false }
        switch kind {
        case .assistant, .appBot: return true
        case .person, .group: return false
        }
    }

    /// The palette, each key marked when I already reacted with it, so the
    /// menu shows what a tap will do. `ownUserID` nil: nothing is marked
    /// (the toggle itself is the SDK's).
    public static func reactionChoices(for item: ChatItem, ownUserID: String?) -> [ReactionChoice] {
        quickReactions.map { key in
            let mine = ownUserID.map { own in item.reactions.contains { $0.key == key && $0.includes(own) } } ?? false
            return ReactionChoice(key: key, isSelected: mine)
        }
    }

    /// "Xóa" asks first ("Xóa với mọi người?", as desktop does) when the
    /// message may have reached the others. A failed send never left this
    /// phone and a held send has no request yet: those go at once.
    public static func deleteNeedsConfirmation(_ item: ChatItem) -> Bool {
        if case .failed = item.delivery { return false }
        return item.eventOrTransactionId != nil
    }
}
