/// What the long-press menu offers on one row (plan B20–B22, §2.7, §3.5).
///
/// The menu view shows exactly these items, in this order; the store still
/// enforces each action (`ChatItemRules`), so a stale menu can never do more
/// than the row allows.
///
/// Display order (chat parity M2; ML6 extends it, see
/// `docs/implementation/chat-parity-ml1-threads-pins.md`, "Menu contract"):
/// react · reply · replyInThread · copy · selectText · pin/unpin ·
/// forward · edit · report · delete. Navigation and sharing actions
/// come before the editing and destructive ones.
public enum MessageMenuItem: Equatable, Hashable, Sendable {
    /// The reaction palette (B22), the desktop set.
    case react
    /// "Trả lời" (B21).
    case reply
    /// "Reply in thread" on a root in a thread-enabled room.
    case replyInThread
    /// "Sao chép": the raw text, as sent.
    case copy
    /// "Chọn văn bản": answers only; opens the select-text sheet.
    case selectText
    /// "Pin": adds the message to the room's shared `m.room.pinned_events`
    /// (S5). Offered only with current write power on an eligible chat.
    case pin
    /// "Unpin": the same message is already in the shared list.
    case unpin
    /// Sends a fresh copy in another chat after choosing a destination.
    case forward
    /// "Sửa": my text messages in people chats only.
    case edit
    /// "Báo cáo": another sender's message, including assistants and app
    /// bots, never mine (`ReportPolicy.mayReportMessage`).
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

/// What the open chat's shared pins allow, from the latest `RoomPinSnapshot`
/// (S5). The menu never decides from a list it drew earlier: each change is a
/// single intent the SDK applies to current room state.
public struct PinMenuContext: Equatable, Sendable {
    public var scope: MessageMenuRules.SharedChatActions
    public var pinnedEventIDs: Set<String>
    /// Current `m.room.pinned_events` state-event power. False after demotion.
    public var canChange: Bool
    /// A local write is in flight or has not reached sync yet: pin and unpin
    /// show but are disabled until the next snapshot.
    public var awaitingSync: Bool

    public init(scope: MessageMenuRules.SharedChatActions, pinnedEventIDs: Set<String>,
                canChange: Bool, awaitingSync: Bool) {
        self.scope = scope
        self.pinnedEventIDs = pinnedEventIDs
        self.canChange = canChange
        self.awaitingSync = awaitingSync
    }
}

public struct ForwardMenuContext: Equatable, Sendable {
    public let canOpenPicker: Bool

    public init(canOpenPicker: Bool) {
        self.canOpenPicker = canOpenPicker
    }
}

public enum MessageMenuRules {
    /// Availability for already-classified chats. The caller supplies the
    /// roster's direct-chat distinction for ordinary personal rooms.
    public enum SharedChatActions: Equatable, Sendable {
        case unavailable, peopleDM, peopleGroup, teamSpace

        public init(kind: RoomKind, isDirect: Bool, activeMemberCount: UInt64,
                    isOrdinaryRoom: Bool, isTeamSpace: Bool = false) {
            if isTeamSpace {
                self = .teamSpace
            } else if !isOrdinaryRoom || kind == .assistant || kind == .appBot || activeMemberCount == 0 {
                self = .unavailable
            } else {
                self = isDirect && activeMemberCount <= 2 ? .peopleDM : .peopleGroup
            }
        }

        public var offersThreads: Bool { self == .peopleGroup || self == .teamSpace }
        public var offersPins: Bool { self != .unavailable }
    }

    /// Desktop's `MATRIX_QUICK_REACTIONS` (atum-app
    /// `apps/desktop/src/matrix/message-actions.tsx`), in its order. Data,
    /// not copy.
    public static let quickReactions = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    /// The menu for `item` in a room of `kind`, in display order: the
    /// palette first, then reply, copy, select text, edit, report, delete. Empty
    /// means the row has no menu: notices outside app-bot rooms (B17), placeholders,
    /// room state, virtual and synthetic rows.
    ///
    /// §2.7 per room kind:
    /// - my assistant: copy, select (answers), reply, react, report answers, delete own;
    /// - Moon or Andy: copy, select (answers), report their messages;
    /// - a person or a group: copy, reply, react, edit and delete own, and
    ///   report on someone else's.
    ///
    /// Text/media report eligibility is independent of room and sender kind;
    /// app-bot room notices also qualify.
    public static func items(for item: ChatItem, in kind: RoomKind,
                             threads: Bool = false, pins: PinMenuContext? = nil,
                             forward: ForwardMenuContext? = nil) -> [MessageMenuItem] {
        switch item.kind {
        case .message, .image, .file: break
        case .notice where kind == .appBot && ReportPolicy.mayReportMessage(item, in: kind): break
        default: return []
        }
        let isText = item.kind == .message || item.kind == .notice
        let hasText = isText && !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isBotRoom = kind == .appBot
        var items: [MessageMenuItem] = []
        if !isBotRoom, ChatItemRules.canReact(item) { items.append(.react) }
        if !isBotRoom, ChatItemRules.canReply(item) { items.append(.reply) }
        if threads, !isBotRoom, threadRootID(for: item) != nil { items.append(.replyInThread) }
        if hasText { items.append(.copy) }
        if hasText, isAnswer(item, in: kind) { items.append(.selectText) }
        if !isBotRoom, let pins, let pinItem = pinItem(for: item, pins: pins) { items.append(pinItem) }
        if forward != nil, forwardEventID(for: item) != nil { items.append(.forward) }
        if ChatItemRules.canEdit(item, in: kind) { items.append(.edit) }
        if ReportPolicy.mayReportMessage(item, in: kind) {
            items.append(.report)
        }
        if !isBotRoom, ChatItemRules.canDelete(item) || isHeldSend(item) { items.append(.delete) }
        return items
    }

    /// Only settled messages with a source event can be inspected by the SDK.
    /// The SDK adapter checks the original event and its displayed revision.
    public static func forwardEventID(for item: ChatItem) -> String? {
        guard ChatItemRules.canReply(item), let eventID = item.eventID, isPinEventID(eventID) else { return nil }
        switch item.kind {
        case .message, .notice, .image, .file: return eventID
        default: return nil
        }
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

    /// A pin acts on a settled message event, including a thread reply.
    /// A state snapshot and the current room powers determine the action.
    public static func pinEventID(for item: ChatItem, in scope: SharedChatActions,
                                  canChange: Bool) -> String? {
        guard scope.offersPins, canChange, ChatItemRules.canReply(item),
              let eventID = item.eventID, isPinEventID(eventID) else { return nil }
        switch item.kind {
        case .message, .notice, .image, .file: return eventID
        default: return nil
        }
    }

    /// "Pin" or "Unpin" for a settled message, or nil when the chat has no
    /// shared pins, the account lacks power, or the row is not a valid target.
    public static func pinItem(for item: ChatItem, pins: PinMenuContext) -> MessageMenuItem? {
        guard let eventID = pinEventID(for: item, in: pins.scope, canChange: pins.canChange) else { return nil }
        return pins.pinnedEventIDs.contains(eventID) ? .unpin : .pin
    }

    /// Whether a shown item can run now. Pin and unpin wait for the previous
    /// write to reach sync, so a stale list is never written.
    public static func isEnabled(_ menuItem: MessageMenuItem, pins: PinMenuContext?,
                                 forward: ForwardMenuContext? = nil) -> Bool {
        switch menuItem {
        case .pin, .unpin: pins.map { $0.canChange && !$0.awaitingSync } ?? false
        case .forward: forward?.canOpenPicker == true
        default: true
        }
    }

    public static func isPinEventID(_ value: String) -> Bool {
        value.first == "$" && (2...512).contains(value.utf8.count)
            && value.utf8.allSatisfy { (33...126).contains($0) }
    }

    /// A send tapped while no timeline was attached (a session renewal): it
    /// has no request yet, so only "Xóa" (which drops it) and "Sao chép"
    /// apply.
    public static func isHeldSend(_ item: ChatItem) -> Bool {
        item.isOwn && item.eventOrTransactionId == nil && item.id.hasPrefix(ConversationCore.heldRowPrefix)
    }

    /// B20: "on answers also Chọn văn bản": a message from the room's agent or
    /// bot (including app-bot notices), never my own and never a person's.
    public static func isAnswer(_ item: ChatItem, in kind: RoomKind) -> Bool {
        guard !item.isOwn else { return false }
        guard item.kind == .message || (item.kind == .notice && kind == .appBot) else { return false }
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
