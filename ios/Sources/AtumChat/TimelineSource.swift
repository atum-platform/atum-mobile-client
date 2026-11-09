import Foundation

/// One room's timeline as the store sees it (plan §2.3 data flow, §2.10):
/// the SDK's timeline in the app (`SDKTimelineSource`), the scripted one in
/// Debug UI tests (`ScriptedTimelineSource`). Both mirror the SDK one to one,
/// on plain values, so the store, the projector and every rule above them run
/// unchanged on either (contract amendment, S1 day 1).
///
/// Rules that the U tests must catch live above this seam, never inside a
/// source: the hotfix's send-queue wake-ups (before a send, after "Thử lại"
/// on a parked request, after "Xóa"), the read rule, pagination, follow.
/// A source only does what the SDK call it mirrors does.
public protocol ChatTimelineSource: AnyObject, Sendable {
    /// Every output in order, for one consumer (the store's timeline
    /// controller). The first is the open's `reset` with whatever the SDK
    /// has cached (§2.3 rule 7).
    var outputs: AsyncStream<ChatTimelineOutput> { get }

    /// Starts listening (the SDK's timeline and back-pagination listeners)
    /// or the scenario's clock. Idempotent.
    func start() async
    /// Stops: no more outputs.
    func stop() async

    /// `Timeline.send` / `sendReply` with plain text exactly as typed
    /// (`formatted: nil`, never markdown; B6). It only queues: the local echo
    /// arrives as a diff.
    func send(text: String, replyTo eventID: String?) async throws
    /// The same send for a message that mentions people: `m.mentions.user_ids`
    /// and the pill HTML ride with the text. A source that cannot carry them
    /// sends the plain text.
    func send(text: String, replyTo eventID: String?, mentions: OutgoingMentions) async throws
    /// S4: enqueue one already-prepared attachment. Paths are app-owned,
    /// temporary and opaque to the pure module.
    func send(attachment: OutgoingChatAttachment, caption: String?, replyTo eventID: String?) async throws
    /// `Timeline.edit(eventOrTransactionId:newContent:)`, plain text (B20).
    func edit(_ item: ChatEventRef, text: String) async throws
    /// `Timeline.redactEvent(eventOrTransactionId:reason: nil)` (B20).
    func redact(_ item: ChatEventRef) async throws
    /// `Timeline.toggleReaction(itemId:key:)`, local echoes included (B22).
    func toggleReaction(_ item: ChatEventRef, key: String) async throws
    /// `Room.isSendQueueEnabled()`.
    func isSendQueueEnabled() async -> Bool
    /// `Room.enableSendQueue(enable: true)`: resends the room's queue in
    /// order (B8 recoverable failures, B9).
    func enableSendQueue() async
    /// `Timeline.retrySend(itemId:target: .event)` on a parked request (B8).
    func retrySend(_ item: ChatEventRef) async throws
    /// `Timeline.abortSend(itemId:target: .event)` (B8 "Xóa").
    func abortSend(_ item: ChatEventRef) async throws
    /// `Timeline.paginateBackwards(numEvents:)`: true at the start of the
    /// room (B5).
    func paginateBackwards(numEvents: UInt16) async throws -> Bool
    /// B13 and B15.
    func sendReceipt(_ receipt: ChatReceipt) async throws
    /// `Timeline.fetchDetailsForEvent(eventId:)` for a reply whose original
    /// is not loaded (B21). Its details arrive as ordinary `set` diffs.
    func fetchReplyDetails(eventID: String) async
}

public enum ChatTimelineMediaError: Error, Equatable, Sendable {
    case unsupported
}

public extension ChatTimelineSource {
    func send(text: String, replyTo eventID: String?, mentions _: OutgoingMentions) async throws {
        try await send(text: text, replyTo: eventID)
    }

    /// Older test sources that do not exercise S4 fail closed until they opt
    /// into media sends; text behavior remains source-compatible.
    func send(attachment _: OutgoingChatAttachment, caption _: String?, replyTo _: String?) async throws {
        throw ChatTimelineMediaError.unsupported
    }
}

/// One output of a timeline source.
public enum ChatTimelineOutput: Equatable, Sendable {
    /// One SDK diff batch on plain values.
    case batch(ChatTimelineBatch)
    /// Typing user IDs (B10, B11), only from a source that also stands in for
    /// the room's typing listener (the scripted one). The SDK source never
    /// emits it: live typing comes from `TypingController`.
    case typing(userIDs: [String])
    /// SDK `PaginationStatus` (B5).
    case pagination(PaginationState)
}

/// One SDK `[TimelineDiff]` batch, mapped.
public struct ChatTimelineBatch: Equatable, Sendable {
    /// The SDK's diffs, verbatim (§2.3 rule 4).
    public var diffs: [ChatDiff]
    /// B21: the quote details of the inserted or set items that reply to an
    /// event, by item ID. An inserted or set item with no entry has none, so
    /// an older entry for its ID goes.
    public var replyDetails: [String: ChatReplyDetails]
    /// Event ID → display ID of my phone-sent messages after this batch
    /// (`DisplayIdentityTable.aliases`). The store hands them to the next
    /// timeline. Empty from a source whose IDs are fixed.
    public var echoAliases: [String: String]

    public init(diffs: [ChatDiff], replyDetails: [String: ChatReplyDetails] = [:],
                echoAliases: [String: String] = [:]) {
        self.diffs = diffs
        self.replyDetails = replyDetails
        self.echoAliases = echoAliases
    }
}

/// The receipts the store sends.
public enum ChatReceipt: Equatable, Hashable, Sendable {
    /// The owner shares activity (the default): `Timeline.markAsRead(
    /// receiptType: .read)`, a public `m.read`, on the latest event; only
    /// while the bottom is visible. The SDK source also clears a
    /// marked-unread flag (`Room.setUnreadFlag(newValue: false)`), which
    /// `markAsRead` leaves alone.
    case readPublic
    /// The owner turned sharing off: `Timeline.markAsRead(receiptType:
    /// .readPrivate)`, on the latest event; only while the bottom is visible.
    /// The SDK source also clears a marked-unread flag
    /// (`Room.setUnreadFlag(newValue: false)`), which `markAsRead` leaves
    /// alone.
    case readPrivate
    /// B15: `Timeline.sendReadReceipt(receiptType: .fullyRead, eventId:)` on
    /// leaving, for the newest event the person read. Never
    /// `markAsRead(receiptType: .fullyRead)`: that marks the latest event,
    /// including messages that arrived while the person was scrolled up
    /// (pinned bindings `matrix_sdk_ffi.swift:18641-18657`, `:18742`).
    case fullyRead(eventID: String)
}
