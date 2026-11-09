import Foundation

/// The hotfix's per-room send-queue rules (plan B8, B9; `fix/ios-chat-hotfix`
/// `LiveMatrixSession.sendText`, `retrySend`, `abortSend`), above the
/// timeline-source seam so they run unchanged on the SDK's source and on the
/// scripted one, and so `swift test` proves them.
///
/// The SDK disables a room's send queue after a recoverable failure and only
/// `Room.enableSendQueue(enable: true)` wakes it again. Three moments need
/// that wake-up, or later messages stay "sending" for ever:
/// 1. Before each send: a disabled queue is woken first, so it resends the
///    earlier message before this one and order holds (`before_send`).
/// 2. "Thử lại" follows the failure kind (`MobileSendRecoveryPolicy.retryAction`,
///    mirrored by `Delivery.retry(for:)`): a recoverable failure wakes the
///    queue; a parked request is retried by its own ID, then the queue is
///    woken if it is still disabled (`retry`). "Xóa" aborts the request and
///    then wakes a disabled queue: removing the head of a disabled queue does
///    not wake it, and what waited behind it would stay sending (`after_abort`).
/// 3. A request parked on a rejected access token is retried once per session
///    on the renewed one. That rule needs the SDK's failure detail
///    (`QueueWedgeError.expiredAccessToken`), which the contract does not
///    carry, so it lives in the SDK source (`SDKTimelineSource`), with
///    `MobileSendRecoveryPolicy.autoRetriesAfterRenewal` deciding.
public enum SendQueueRules {
    /// Why a disabled room queue was woken; closed log codes (the hotfix's
    /// `atum.send_queue stage=room_enabled outcome=…` line).
    public enum Wake: String, Equatable, Sendable {
        case beforeSend = "before_send"
        /// "Thử lại" on a recoverable failure, and after a parked request was
        /// retried while the queue was disabled.
        case retry
        case afterAbort = "after_abort"
    }

    /// Rule 1. `woke` is called for each wake-up, for the log line.
    public static func send(text: String, replyTo eventID: String?,
                            mentions: OutgoingMentions = .none, on source: any ChatTimelineSource,
                            woke: @Sendable (Wake) -> Void = { _ in }) async throws {
        await wakeIfDisabled(source, .beforeSend, woke)
        if mentions.isEmpty {
            try await source.send(text: text, replyTo: eventID)
        } else {
            try await source.send(text: text, replyTo: eventID, mentions: mentions)
        }
    }

    public static func send(attachment: OutgoingChatAttachment, caption: String?,
                            replyTo eventID: String?, on source: any ChatTimelineSource,
                            woke: @Sendable (Wake) -> Void = { _ in }) async throws {
        await wakeIfDisabled(source, .beforeSend, woke)
        try await source.send(attachment: attachment, caption: caption, replyTo: eventID)
    }

    /// Rule 2, "Thử lại".
    public static func repair(_ repair: SendRepair, on source: any ChatTimelineSource,
                              woke: @Sendable (Wake) -> Void = { _ in }) async throws {
        switch repair {
        case .enableRoomQueue:
            await source.enableSendQueue()
            woke(.retry)
        case let .retryParkedRequest(ref):
            try await source.retrySend(ref)
            // Unparking wakes the room, but a queue the SDK disabled stays
            // asleep.
            await wakeIfDisabled(source, .retry, woke)
        }
    }

    /// Rule 2, "Xóa": the request never went out; nothing is kept on the
    /// phone.
    public static func abort(_ ref: ChatEventRef, on source: any ChatTimelineSource,
                             woke: @Sendable (Wake) -> Void = { _ in }) async throws {
        try await source.abortSend(ref)
        await wakeIfDisabled(source, .afterAbort, woke)
    }

    private static func wakeIfDisabled(_ source: any ChatTimelineSource, _ reason: Wake,
                                       _ woke: @Sendable (Wake) -> Void) async {
        guard await !source.isSendQueueEnabled() else { return }
        await source.enableSendQueue()
        woke(reason)
    }
}
