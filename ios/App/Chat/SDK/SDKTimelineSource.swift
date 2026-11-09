import AtumChat
import AtumNativeAPI
import Foundation
import MatrixRustSDK

// One room's SDK timeline behind the contract's `ChatTimelineSource` (plan
// §2.2, §2.3). With `ItemMapper` and `SDKValueMapping`, the only place that
// touches SDK timeline types. It does what each SDK call does and nothing
// more: the rules the U tests must catch (the hotfix's queue wake-ups, the
// read rule, pagination) live above it, in `TimelineController` and the
// store, so they run unchanged on the scripted source.
//
// Data flow (§2.3):
//   SDK listener callbacks (any thread)
//     → one ordered AsyncStream of SDK inputs (diff batches, pagination)
//     → this actor (off main): ItemMapper maps only inserted or set values
//     → `outputs`, in SDK order.

/// What the SDK listeners hand the source, in one ordered stream, so a
/// pagination status never overtakes the batch it belongs with.
private enum SDKTimelineInput: Sendable {
    case diffs([TimelineDiff])
    case pagination(PaginationState)
}

actor SDKTimelineSource: ChatTimelineSource {
    /// §2.3 rule 1: live, with membership and profile changes filtered out
    /// before the SDK builds its list (so they never take an index), daily
    /// date dividers, read receipts on message-like events.
    static let configuration = TimelineConfiguration(
        focus: .live(hideThreadedEvents: false),
        filter: .eventFilter(filter: .exclude([.membershipChange(.any), .profileChange])),
        internalIdPrefix: nil,
        dateDividerMode: .daily,
        trackReadReceipts: .messageLikeEvents,
        reportUtds: false
    )

    nonisolated let outputs: AsyncStream<ChatTimelineOutput>

    private let roomID: String
    private let room: Room
    private let timeline: Timeline
    private let mapper: ItemMapper
    private let outputContinuation: AsyncStream<ChatTimelineOutput>.Continuation
    private let inputs: AsyncStream<SDKTimelineInput>
    private let inputContinuation: AsyncStream<SDKTimelineInput>.Continuation
    private var consumer: Task<Void, Never>?
    private var listenerHandle: TaskHandle?
    private var paginationHandle: TaskHandle?
    private var paginationListener: TimelinePaginationListener?
    private var isStopped = false
    /// Requests parked on a rejected token already retried on this timeline.
    private var autoRetried = Set<ChatEventRef>()
    /// Rows hidden by the plaintext rule; the count is logged on change.
    private var hiddenPlaintext = Set<String>()
    /// The identity probe's last line per row, so receipt updates do not
    /// repeat it.
    private var probedIdentities = [String: String]()
    /// Failed sends already logged, so receipt updates do not repeat the
    /// line; a send that leaves the failed state and fails again is logged
    /// again.
    private var loggedFailures = Set<String>()

    /// Builds the room's timeline. Rule 7: whatever the SDK has cached shows
    /// at once; nothing here waits for history. `aliases`: the previous
    /// timeline's `echoAliases`.
    static func make(room: Room, mapperRoom: ItemMapperRoom, aliases: [String: String],
                     calendar: Calendar = .current) async throws -> SDKTimelineSource {
        let timeline = try await room.timelineWithConfiguration(configuration: configuration)
        return SDKTimelineSource(roomID: mapperRoom.roomID, room: room, timeline: timeline,
                                 mapper: ItemMapper(room: mapperRoom, aliases: aliases, calendar: calendar))
    }

    /// The room's encryption state for the mapper (rule 10).
    static func encryption(of room: Room) async -> Bool? {
        switch try? await room.latestEncryptionState() {
        case .encrypted?: true
        case .notEncrypted?: false
        case .unknown?, nil: nil
        }
    }

    private init(roomID: String, room: Room, timeline: Timeline, mapper: ItemMapper) {
        self.roomID = roomID
        self.room = room
        self.timeline = timeline
        self.mapper = mapper
        (outputs, outputContinuation) = AsyncStream.makeStream(of: ChatTimelineOutput.self)
        (inputs, inputContinuation) = AsyncStream.makeStream(of: SDKTimelineInput.self)
    }

    // MARK: Lifecycle

    func start() async {
        guard !isStopped, listenerHandle == nil else { return }
        let inputs = inputs
        consumer = Task { [weak self] in
            for await input in inputs {
                guard let self else { return }
                await self.handle(input)
            }
        }
        listenerHandle = await timeline.addListener(listener: TimelineDiffListener(continuation: inputContinuation))
        let listener = TimelinePaginationListener(continuation: inputContinuation)
        paginationListener = listener
        paginationHandle = try? await timeline.subscribeToBackPaginationStatus(listener: listener)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        listenerHandle?.cancel()
        listenerHandle = nil
        paginationHandle?.cancel()
        paginationHandle = nil
        paginationListener = nil
        inputContinuation.finish()
        consumer?.cancel()
        consumer = nil
        outputContinuation.finish()
    }

    private func handle(_ input: SDKTimelineInput) {
        guard !isStopped else { return }
        switch input {
        case let .diffs(diffs):
            outputContinuation.yield(.batch(map(diffs)))
        case let .pagination(state):
            outputContinuation.yield(.pagination(state))
        }
    }

    /// One SDK batch onto plain values: only inserted or set values cross
    /// the mapper (rule 3).
    private func map(_ diffs: [TimelineDiff]) -> ChatTimelineBatch {
        let isReset = diffs.contains { diff in
            switch diff {
            case .reset, .clear: true
            default: false
            }
        }
        if isReset { mapper.beginReset() }
        var mapped = [MappedItem]()
        let chatDiffs = diffs.map { diff in
            ChatDiff(diff) { item in
                let value = mapper.map(item)
                mapped.append(value)
                return value.item
            }
        }
        mapper.finishBatch()
        var replyDetails = [String: ChatReplyDetails]()
        for value in mapped {
            if let details = value.replyDetails { replyDetails[value.item.id] = details }
            note(value)
        }
        return ChatTimelineBatch(diffs: chatDiffs, replyDetails: replyDetails, echoAliases: mapper.aliases)
    }

    /// The SDK-only facts of one mapped item: the token-parked retry, the
    /// plaintext and failure log lines, the identity probe.
    private func note(_ value: MappedItem) {
        let id = value.item.id
        if value.isTokenParked, let ref = value.item.eventOrTransactionId { retryTokenParked(ref) }
        let hiddenBefore = hiddenPlaintext.count
        if value.isHiddenPlaintext { hiddenPlaintext.insert(id) } else { hiddenPlaintext.remove(id) }
        if hiddenPlaintext.count != hiddenBefore {
            LiveFlowLog.timeline(outcome: hiddenPlaintext.isEmpty ? "plaintext_none" : "plaintext_hidden",
                                 roomID: roomID, count: hiddenPlaintext.count)
        }
        // One content-free line per failed send of mine: failure class and
        // whether the SDK disabled the queue or parked the request (how stuck
        // sends are diagnosed; the hotfix's line).
        if let failure = value.sendFailureClass {
            if loggedFailures.insert(id).inserted {
                LiveFlowLog.sendQueue(.sendFailed, outcome: failure, roomID: roomID)
            }
        } else {
            loggedFailures.remove(id)
        }
        if ProbeLog.isEnabled, value.item.isOwn,
           value.item.isLocalEcho || value.item.isEdited || id.hasPrefix(DisplayIdentityTable.localPrefix) {
            markIdentity(value)
        }
    }

    /// The S0 `uniqueId` probe (§2.3 rule 2, §2.10): the SDK's unique ID and
    /// `eventOrTransactionId` of my sends before and after their remote
    /// echo, and of edits, next to the display ID the phone kept. IDs only,
    /// never content; each distinct line once.
    private func markIdentity(_ value: MappedItem) {
        let item = value.item
        let phase = item.isEdited ? "edit" : (item.isLocalEcho ? "local" : "remote")
        let ref: String = switch item.eventOrTransactionId {
        case let .event(id)?: "event:" + id
        case let .transaction(id)?: "transaction:" + id
        case nil: "none"
        }
        let line = [value.uniqueID, ref, phase].joined(separator: "|")
        guard probedIdentities[item.id] != line else { return }
        probedIdentities[item.id] = line
        ProbeLog.mark(.itemIdentity, id: LiveFlowLog.fingerprint(roomID),
                      fields: ["uniqueId": value.uniqueID, "eventOrTransactionId": ref, "phase": phase,
                               "displayId": item.id])
    }

    /// Requests parked on a rejected token are only unparked by the SDK's own
    /// token refresh, which the phone does not use. Each is retried once per
    /// timeline (one timeline per session), so a still-rejected token cannot
    /// loop (`MobileSendRecoveryPolicy.autoRetriesAfterRenewal`).
    private func retryTokenParked(_ ref: ChatEventRef) {
        guard MobileSendRecoveryPolicy.autoRetriesAfterRenewal(
            failureIsExpiredToken: true, isRecoverable: false, alreadyRetried: autoRetried.contains(ref)
        ) else { return }
        autoRetried.insert(ref)
        let timeline = timeline
        let roomID = roomID
        Task {
            let retried = (try? await timeline.retrySend(itemId: ref.sdk, target: .event)) ?? false
            LiveFlowLog.sendQueue(.autoRetry, outcome: retried ? "token_parked_retried" : "token_parked_failed",
                                  roomID: roomID)
        }
    }

    // MARK: Actions (one SDK call each)

    /// B6: plain text exactly as typed (`formatted: nil`), never
    /// `messageEventContentFromMarkdown`.
    func send(text: String, replyTo eventID: String?) async throws {
        try await send(text: text, replyTo: eventID, mentions: .none)
    }

    /// Mentions: the typed text stays the body; the pills ride as the HTML
    /// body and `m.mentions.user_ids` (Matrix 1.7), so the mentioned people
    /// are notified even when their client ignores the HTML.
    func send(text: String, replyTo eventID: String?, mentions: OutgoingMentions) async throws {
        let content = try Self.message(text, mentions: mentions)
        if let eventID {
            _ = try await timeline.sendReply(msg: content, eventId: eventID)
        } else {
            _ = try await timeline.send(msg: content)
        }
    }

    func send(attachment: OutgoingChatAttachment, caption: String?,
              replyTo eventID: String?) async throws {
        let source = UploadSource.file(filename: attachment.filePath)
        let parameters = UploadParameters(source: source,
                                          caption: caption,
                                          formattedCaption: nil,
                                          mentions: nil,
                                          inReplyTo: eventID)
        let kind: AttachmentKind
        switch attachment.kind {
        case let .image(width, height, isAnimated):
            let thumbnailSource = attachment.thumbnailPath.map { UploadSource.file(filename: $0) }
            let thumbnailInfo = attachment.thumbnailPath.flatMap { path -> ThumbnailInfo? in
                guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
                else { return nil }
                return ThumbnailInfo(height: nil, width: nil, mimetype: "image/jpeg",
                                     size: size.uint64Value)
            }
            kind = .image(
                imageInfo: ImageInfo(height: height, width: width,
                                     mimetype: attachment.mimetype, size: attachment.byteSize,
                                     thumbnailInfo: thumbnailInfo, thumbnailSource: nil,
                                     blurhash: nil, isAnimated: isAnimated),
                thumbnailSource: thumbnailSource
            )
        case .file:
            kind = .file(fileInfo: FileInfo(mimetype: attachment.mimetype,
                                            size: attachment.byteSize,
                                            thumbnailInfo: nil,
                                            thumbnailSource: nil))
        }
        let handle = try timeline.sendAttachment(params: parameters, attachment: kind)
        let paths = [attachment.filePath, attachment.thumbnailPath].compactMap { $0 }
        Task.detached {
            do {
                try await handle.join()
                for path in paths { try? FileManager.default.removeItem(atPath: path) }
            } catch {
                // The failed local echo still owns these staging files for
                // preview/share and queue retry. Launch cleanup is the final
                // fallback if the person never retries or deletes the row.
            }
        }
    }

    func edit(_ item: ChatEventRef, text: String) async throws {
        try await timeline.edit(eventOrTransactionId: item.sdk,
                                newContent: .roomMessage(content: Self.plainText(text)))
    }

    func redact(_ item: ChatEventRef) async throws {
        try await timeline.redactEvent(eventOrTransactionId: item.sdk, reason: nil)
    }

    func toggleReaction(_ item: ChatEventRef, key: String) async throws {
        _ = try await timeline.toggleReaction(itemId: item.sdk, key: key)
    }

    func isSendQueueEnabled() -> Bool {
        room.isSendQueueEnabled()
    }

    func enableSendQueue() {
        room.enableSendQueue(enable: true)
    }

    func retrySend(_ item: ChatEventRef) async throws {
        _ = try await timeline.retrySend(itemId: item.sdk, target: .event)
    }

    func abortSend(_ item: ChatEventRef) async throws {
        _ = try await timeline.abortSend(itemId: item.sdk, target: .event)
    }

    func paginateBackwards(numEvents: UInt16) async throws -> Bool {
        try await timeline.paginateBackwards(numEvents: numEvents)
    }

    func sendReceipt(_ receipt: ChatReceipt) async throws {
        switch receipt {
        case .readPublic:
            try await timeline.markAsRead(receiptType: .read)
            guard let info = try? await room.roomInfo(), info.isMarkedUnread else { return }
            try? await room.setUnreadFlag(newValue: false)
        case .readPrivate:
            try await timeline.markAsRead(receiptType: .readPrivate)
            guard let info = try? await room.roomInfo(), info.isMarkedUnread else { return }
            try? await room.setUnreadFlag(newValue: false)
        case let .fullyRead(eventID):
            try await timeline.sendReadReceipt(receiptType: .fullyRead, eventId: eventID)
        }
    }

    func fetchReplyDetails(eventID: String) async {
        try? await timeline.fetchDetailsForEvent(eventId: eventID)
    }

    private static func plainText(_ text: String) throws -> RoomMessageEventContentWithoutRelation {
        try messageEventContentNew(msgtype: .text(content: TextMessageContent(body: text, formatted: nil)))
    }

    private static func message(_ text: String,
                                mentions: OutgoingMentions) throws -> RoomMessageEventContentWithoutRelation {
        guard !mentions.isEmpty else { return try plainText(text) }
        let formatted = mentions.formattedHTML.map { FormattedBody(format: .html, body: $0) }
        let content = try messageEventContentNew(msgtype: .text(
            content: TextMessageContent(body: text, formatted: formatted)))
        return content.withMentions(mentions: Mentions(userIds: mentions.userIDs, room: false))
    }
}

/// Plain values → SDK values for the calls this source makes.
private extension ChatEventRef {
    var sdk: EventOrTransactionId {
        switch self {
        case let .event(id): .eventId(eventId: id)
        case let .transaction(id): .transactionId(transactionId: id)
        }
    }
}

private final class TimelineDiffListener: TimelineListener {
    private let continuation: AsyncStream<SDKTimelineInput>.Continuation

    init(continuation: AsyncStream<SDKTimelineInput>.Continuation) {
        self.continuation = continuation
    }

    func onUpdate(diff: [TimelineDiff]) {
        continuation.yield(.diffs(diff))
    }
}

private final class TimelinePaginationListener: PaginationStatusListener {
    private let continuation: AsyncStream<SDKTimelineInput>.Continuation

    init(continuation: AsyncStream<SDKTimelineInput>.Continuation) {
        self.continuation = continuation
    }

    func onUpdate(status: PaginationStatus) {
        let state: PaginationState = switch status {
        case let .idle(hitTimelineStart): .idle(hitTimelineStart: hitTimelineStart)
        case .paginating: .paginating
        }
        continuation.yield(.pagination(state))
    }
}
