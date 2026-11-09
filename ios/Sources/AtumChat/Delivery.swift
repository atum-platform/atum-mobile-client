import Foundation

/// The small mark under one of my messages (B7). Every case is declared in
/// S0 so row views switch over the full set; the S1a projection emits only
/// `none`, `sending` and `failed`, and the S1 projection
/// (`ProjectionOptions.marksSentAndSeen`) adds `sent` and `seen`.
public enum DeliveryMark: Equatable, Hashable, Sendable {
    case none
    /// A clock on every message that is still sending, so three quick sends
    /// show three clocks. Accessibility label "Đang gửi" (exported copy).
    case sending
    /// A warning glyph on a failed send, with "Chưa gửi được", "Thử lại" and
    /// "Xóa" (B8). Whether the failure is recoverable picks the retry call,
    /// not the mark: `Delivery.retry(for:)` reads it from `ChatItem.delivery`.
    case failed
    /// "Đã gửi" with a check, only on my newest settled message in an
    /// assistant or bot chat.
    case sent
    /// "Đã xem" once another member's receipt sits on this item or a later
    /// one. `readerCount` is how many other members have read it; groups show
    /// "Đã xem · N", other rooms ignore the number.
    case seen(readerCount: Int)
}

/// What "Thử lại" does for a failed send (B8). The SDK decides the failure's
/// kind; the phone keeps no second copy of the text.
public enum SendRepair: Equatable, Hashable, Sendable {
    /// `isRecoverable == true`: the SDK disabled the room's send queue.
    /// `Room.enableSendQueue(enable: true)` resends the room's queue in order,
    /// this message first; later messages wait behind it, as intended.
    case enableRoomQueue
    /// `isRecoverable == false`: the SDK parked this one request.
    /// `Timeline.retrySend(itemId:target: .event)` with this ID unparks it.
    case retryParkedRequest(ChatEventRef)
}

public enum Delivery {
    /// B10: how long my newest message in an agent room waits for an answer
    /// before the quiet "Chưa có câu trả lời." line shows (desktop
    /// `cloudQuietMs`). Only assistant rooms reach this rule; every other
    /// room kind returns nil from `noAnswerItemID`.
    public static let noAnswerAfter: TimeInterval = 2 * 60

    /// The S1a mark for one row. Only messages sent by this account carry
    /// one: a clock while sending, a warning on failure, nothing else.
    public static func mark(for item: ChatItem) -> DeliveryMark {
        guard item.isOwn, item.kind.isEventContent else { return .none }
        switch item.delivery {
        case .sending: return .sending
        case .failed: return .failed
        case .remote, .sent: return .none
        }
    }

    /// B7 and §9.1, keyed by item ID, for the whole buffer:
    /// - a clock on every pending message of mine, a warning on every failed
    ///   one (`mark(for:)`);
    /// - every settled message of mine shows "Đã xem" where another member's
    ///   receipt sits on that very item (the Element X model: the reader's
    ///   avatar appears under the message their receipt names), counting each
    ///   reader once;
    /// - "Đã gửi" only under my last settled message while nobody has read it
    ///   yet, in every room kind (§9.1: never under older unread messages);
    /// - older unread settled messages show nothing.
    ///
    /// My own account's receipts (the Mac) never count.
    public static func marks(for items: [ChatItem], context: RoomContext) -> [String: DeliveryMark] {
        var marks = [String: DeliveryMark]()
        for item in items where item.isOwn {
            let mark = mark(for: item)
            if mark != .none { marks[item.id] = mark }
            guard isMessageLike(item.kind) else { continue }
            var readers = Set(item.receiptUserIDs)
            readers.remove(context.ownUserID)
            if !readers.isEmpty {
                marks[item.id] = .seen(readerCount: readers.count)
            }
        }
        guard let newest = items.lastIndex(where: { isSettledOwnMessage($0) }),
              marks[items[newest].id] == nil else { return marks }
        marks[items[newest].id] = .sent
        return marks
    }

    /// B10: the ID of my newest message in my assistant's chat when it has
    /// waited `after` seconds (or longer) at `now` with no answer, else nil.
    /// An answer is anything the room's agent (or anyone but me) sent after
    /// it except notices: a working or wait-state line is not an answer.
    /// A message still sending or failed shows its own mark instead.
    public static func noAnswerItemID(_ items: [ChatItem], context: RoomContext, now: Date,
                                      after: TimeInterval = noAnswerAfter) -> String? {
        guard let waiting = unanswered(items, context: context) else { return nil }
        return now.timeIntervalSince(waiting.timestamp) >= after ? waiting.id : nil
    }

    /// When `noAnswerItemID` will next change on its own, with no new item:
    /// the moment my unanswered newest message reaches `after`. Nil when it
    /// is already past, or nothing is waiting. The store re-projects then.
    public static func noAnswerDeadline(_ items: [ChatItem], context: RoomContext, now: Date,
                                        after: TimeInterval = noAnswerAfter) -> Date? {
        guard let waiting = unanswered(items, context: context) else { return nil }
        let deadline = waiting.timestamp.addingTimeInterval(after)
        return deadline > now ? deadline : nil
    }

    /// B8: what "Thử lại" does for this item, or nil when it is not a failed
    /// send of mine. A parked request needs its ID (the transaction ID while
    /// it is a local echo).
    public static func retry(for item: ChatItem) -> SendRepair? {
        guard item.isOwn, case let .failed(isRecoverable) = item.delivery else { return nil }
        if isRecoverable { return .enableRoomQueue }
        guard let id = item.eventOrTransactionId else { return nil }
        return .retryParkedRequest(id)
    }

    /// B8: the request "Xóa" aborts (`Timeline.abortSend(itemId:target:
    /// .event)`), or nil when the item is not a failed send of mine.
    public static func abortTarget(for item: ChatItem) -> ChatEventRef? {
        guard item.isOwn, case .failed = item.delivery else { return nil }
        return item.eventOrTransactionId
    }

    // MARK: Private

    private static func isMessageLike(_ kind: ChatItem.Kind) -> Bool {
        switch kind {
        case .message, .image, .file: true
        default: false
        }
    }

    private static func isSettledOwnMessage(_ item: ChatItem) -> Bool {
        guard item.isOwn, isMessageLike(item.kind) else { return false }
        switch item.delivery {
        case .remote, .sent: return true
        case .sending, .failed: return false
        }
    }

    /// My newest message in an assistant chat, settled and with no answer
    /// after it.
    private static func unanswered(_ items: [ChatItem], context: RoomContext) -> ChatItem? {
        guard context.kind == .assistant,
              let newest = items.lastIndex(where: { $0.isOwn && isMessageLike($0.kind) }),
              isSettledOwnMessage(items[newest]) else { return nil }
        let answered = items[(newest + 1)...].contains { item in
            guard !item.isOwn, item.kind.isEventContent, !item.interim else { return false }
            switch item.kind {
            case .notice, .roomState: return false
            default: return true
            }
        }
        return answered ? nil : items[newest]
    }
}
