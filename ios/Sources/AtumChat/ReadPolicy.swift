import Foundation

/// Mark as read when seen (plan B13, B15). One per open chat, owned by the
/// store and fed from `ConversationStore.bottomVisible`.
///
/// - The view sets `bottomVisible` only while the app is active, the chat is
///   on screen and its bottom is within 24 pt. While it is false nothing is
///   sent: not while scrolled up, not in the background, not while covered.
/// - Once the bottom is visible and the newest settled event is not yet
///   acknowledged, a private receipt goes out after a 300 ms settle. Each new
///   event postpones it a little, never past 2 s after the first one, so a
///   burst becomes one receipt and a steady stream is still acknowledged.
/// - One request at a time. When the newest event changed while one was in
///   flight, the next one is scheduled when it finishes. A failed request is
///   retried after 1 s, 4 s and 15 s, then waits for the next change.
/// - Leaving the chat moves the fully-read marker to the last acknowledged
///   event (B15: `.fullyRead` is sent only on leaving), by event ID: never
///   `markAsRead(.fullyRead)`, which marks the latest event whether or not
///   the person saw it.
///
/// These are desktop's rules (`D194: apps/desktop/src/matrix/read-receipts.ts`,
/// `READ_SETTLE_MS`, `READ_MAX_WAIT_MS`, `READ_RETRY_MS`), with visibility
/// narrowed to "the bottom is visible": `Timeline.markAsRead` acknowledges the
/// latest event, so it must run only when that event is on screen.
///
/// Times are monotonic seconds, injected. The store calls `tick(now:)` at
/// `nextDeadline`.
public struct ReadPolicy: Equatable, Sendable {
    public static let settleSeconds: TimeInterval = 0.3
    public static let maximumWaitSeconds: TimeInterval = 2
    public static let retrySeconds: [TimeInterval] = [1, 4, 15]

    /// The SDK call to make now.
    public enum Call: Equatable, Hashable, Sendable {
        /// `Timeline.markAsRead(receiptType: .readPrivate)`; then, when
        /// `clearsUnreadFlag`, `Room.setUnreadFlag(newValue: false)`, because
        /// a receipt does not clear a room marked unread. Report the result
        /// with `finished(succeeded:now:)`.
        case privateReceipt(eventID: String, clearsUnreadFlag: Bool)
        /// `Timeline.sendReadReceipt(receiptType: .fullyRead, eventId:
        /// eventID)`, on leaving (B15). By event ID: the person may have
        /// scrolled up while newer messages arrived, and those stay unread
        /// ("Tin nhắn mới" still shows above them next time).
        case fullyRead(eventID: String)
    }

    public private(set) var bottomVisible = false
    /// The newest settled event (`latestSettledEventID(in:)`).
    public private(set) var latestEventID: String?
    /// `RoomInfo.isMarkedUnread`.
    public private(set) var markedUnread = false
    /// The event the request in flight acknowledges.
    public private(set) var inFlight: String?
    /// The last event a private receipt acknowledged in this chat.
    public private(set) var acknowledgedEventID: String?
    /// When `tick(now:)` must run next, or nil when nothing is scheduled.
    public private(set) var nextDeadline: TimeInterval?
    private var burstStart: TimeInterval?
    private var failures = 0
    private var fullyReadEventID: String?
    /// The request in flight also clears the marked-unread flag.
    private var inFlightClearsUnreadFlag = false
    /// The room was marked unread again while a request was in flight; that
    /// request does not clear it.
    private var markedUnreadDuringFlight = false

    public init() {}

    /// Whether a receipt is owed right now (ignoring the settle timer).
    public var isDue: Bool {
        guard bottomVisible, inFlight == nil, let latestEventID else { return false }
        return latestEventID != acknowledgedEventID || markedUnread
    }

    /// The view's `bottomVisible` changed.
    public mutating func setBottomVisible(_ visible: Bool, now: TimeInterval) {
        guard visible != bottomVisible else { return }
        bottomVisible = visible
        if visible {
            failures = 0
            if isDue { schedule(Self.settleSeconds, now: now) }
        } else {
            cancelTimer()
        }
    }

    /// The newest settled event changed: a message arrived, or my send got
    /// its event ID.
    public mutating func latestEventChanged(_ eventID: String?, now: TimeInterval) {
        guard eventID != latestEventID else { return }
        latestEventID = eventID
        if isDue { schedule(Self.settleSeconds, now: now) }
    }

    /// `RoomInfo.isMarkedUnread` changed (the person marked it unread on the
    /// Mac while reading here, or a receipt cleared it).
    public mutating func setMarkedUnread(_ marked: Bool, now: TimeInterval) {
        guard marked != markedUnread else { return }
        markedUnread = marked
        if marked, inFlight != nil { markedUnreadDuringFlight = true }
        if isDue { schedule(Self.settleSeconds, now: now) }
    }

    /// The timer fired. Returns the receipt to send, if one is still owed.
    public mutating func tick(now: TimeInterval) -> Call? {
        guard let nextDeadline, now >= nextDeadline else { return nil }
        cancelTimer()
        guard isDue, let latestEventID else { return nil }
        inFlight = latestEventID
        inFlightClearsUnreadFlag = markedUnread
        markedUnreadDuringFlight = false
        return .privateReceipt(eventID: latestEventID, clearsUnreadFlag: markedUnread)
    }

    /// The receipt request finished. Only a request that cleared the
    /// marked-unread flag forgets it, and only when the room was not marked
    /// unread again meanwhile; otherwise a follow-up receipt clears it.
    public mutating func finished(succeeded: Bool, now: TimeInterval) {
        guard let target = inFlight else { return }
        inFlight = nil
        let cleared = succeeded && inFlightClearsUnreadFlag && !markedUnreadDuringFlight
        inFlightClearsUnreadFlag = false
        markedUnreadDuringFlight = false
        if succeeded {
            failures = 0
            acknowledgedEventID = target
            if cleared { markedUnread = false }
            if isDue { schedule(Self.settleSeconds, now: now) }
        } else {
            failures += 1
            if failures <= Self.retrySeconds.count, isDue {
                schedule(Self.retrySeconds[failures - 1], now: now)
            }
        }
    }

    /// The person left the chat. Returns the fully-read call for what they
    /// read here, once per event.
    public mutating func leave() -> Call? {
        bottomVisible = false
        cancelTimer()
        guard let acknowledgedEventID, acknowledgedEventID != fullyReadEventID else { return nil }
        fullyReadEventID = acknowledgedEventID
        return .fullyRead(eventID: acknowledgedEventID)
    }

    /// The newest event the server has given the timeline: event content
    /// with a server event ID that is not still on its way (remote, or my
    /// send once the server accepted it). Local echoes never count: a receipt
    /// must name an event the server knows. Virtual and synthetic rows never
    /// count.
    public static func latestSettledEventID(in items: [ChatItem]) -> String? {
        for item in items.reversed() where item.kind.isEventContent {
            switch item.delivery {
            case .remote, .sent:
                if let eventID = item.eventID { return eventID }
            case .sending, .failed:
                continue
            }
        }
        return nil
    }

    /// Each change postpones the receipt by `delay`, never past the burst's
    /// deadline (desktop `schedule`).
    private mutating func schedule(_ delay: TimeInterval, now: TimeInterval) {
        if nextDeadline == nil { burstStart = now }
        let start = burstStart ?? now
        nextDeadline = min(now + delay, start + max(delay, Self.maximumWaitSeconds))
    }

    private mutating func cancelTimer() {
        nextDeadline = nil
        burstStart = nil
    }
}
