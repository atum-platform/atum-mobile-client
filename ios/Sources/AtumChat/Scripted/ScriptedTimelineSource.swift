#if DEBUG
import Foundation

/// A scripted chat on real time: the stand-in for one room's SDK timeline,
/// typing listener and pagination status in Debug builds (plan §2.10,
/// `-AtumScripted <scenario>`). It is a `ChatTimelineSource`, so the real
/// store and projector run on it exactly as on the SDK: the store consumes
/// `outputs` in order and calls the same actions the SDK offers.
/// `ScriptedTimelinePlayer` holds every rule; this only runs its clock and
/// translates plain-value refs to the player's item IDs.
public actor ScriptedTimelineSource: ChatTimelineSource {
    /// `paginateBackwards` takes this long, so the loading row shows.
    public static let paginationSeconds: TimeInterval = 0.4

    public nonisolated let script: ScriptedScript
    /// Every SDK-like event in order: the open's `reset` first. Diff batches
    /// carry the reply details the SDK would (`ScriptedTimelinePlayer.replyDetails`).
    public nonisolated let outputs: AsyncStream<ChatTimelineOutput>

    private let continuation: AsyncStream<ChatTimelineOutput>.Continuation
    private var player: ScriptedTimelinePlayer
    private let clock = ContinuousClock()
    private var origin: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?

    public init(script: ScriptedScript, reference: Date = Date(), calendar: Calendar = .current) {
        self.script = script
        player = ScriptedTimelinePlayer(script: script, reference: reference, calendar: calendar)
        (outputs, continuation) = AsyncStream.makeStream(of: ChatTimelineOutput.self)
    }

    /// Opens the chat and starts the scenario's clock. Idempotent.
    public func start() {
        guard origin == nil else { return }
        origin = clock.now
        emit(player.open())
        rearm()
    }

    /// Closes the chat: no more outputs.
    public func stop() {
        timer?.cancel()
        timer = nil
        continuation.finish()
    }

    /// `Timeline.send` / `sendReply`. Returns the echo's item ID (for tests;
    /// the SDK returns no such thing, so the protocol's `send` does not).
    @discardableResult
    public func sendEcho(text: String, replyTo: String? = nil) -> String {
        catchUp()
        let result = player.send(text: text, replyTo: replyTo)
        emit(result.outputs)
        rearm()
        return result.itemID
    }

    /// `Room.enableSendQueue(enable: true)`.
    public func enableSendQueue() {
        catchUp()
        emit(player.enableSendQueue())
        rearm()
    }

    /// `Timeline.retrySend`.
    @discardableResult
    public func retrySend(itemID: String) -> Bool {
        catchUp()
        let result = player.retrySend(itemID: itemID)
        emit(result.outputs)
        rearm()
        return result.retried
    }

    /// `Timeline.abortSend`.
    @discardableResult
    public func abortSend(itemID: String) -> Bool {
        catchUp()
        let result = player.abortSend(itemID: itemID)
        emit(result.outputs)
        rearm()
        return result.removed
    }

    /// `Timeline.toggleReaction`.
    public func toggleReaction(itemID: String, key: String) {
        catchUp()
        emit(player.toggleReaction(itemID: itemID, key: key))
    }

    /// `Timeline.redactEvent`.
    public func redact(itemID: String) {
        catchUp()
        emit(player.redact(itemID: itemID))
    }

    /// `Timeline.edit`.
    public func edit(itemID: String, text: String) {
        catchUp()
        emit(player.edit(itemID: itemID, text: text))
    }

    /// `Timeline.paginateBackwards(numEvents:)`: true at the start of the
    /// room. Scripted pages are slices of the scenario, whatever `numEvents`.
    public func paginateBackwards(numEvents _: UInt16 = PaginationPolicy.pageSize) async -> Bool {
        catchUp()
        let began = player.beginPagination()
        emit(began)
        if !began.isEmpty {
            try? await Task.sleep(for: .seconds(Self.paginationSeconds))
            catchUp()
        }
        let result = player.servePage()
        emit(result.outputs)
        rearm()
        return result.hitTimelineStart
    }

    public func markOutputBoundary(_ id: UUID) -> Bool {
        if case .terminated = continuation.yield(.outputBoundary(id)) { return false }
        return true
    }

    // MARK: ChatTimelineSource

    public func send(text: String, replyTo eventID: String?) {
        sendEcho(text: text, replyTo: eventID)
    }

    public func send(attachment: OutgoingChatAttachment, caption: String?, replyTo eventID: String?) {
        catchUp()
        let result = player.send(attachment: attachment, caption: caption, replyTo: eventID)
        emit(result.outputs)
        rearm()
    }

    public func edit(_ item: ChatEventRef, text: String) throws {
        edit(itemID: try itemID(item), text: text)
    }

    public func redact(_ item: ChatEventRef) throws {
        redact(itemID: try itemID(item))
    }

    public func toggleReaction(_ item: ChatEventRef, key: String) throws {
        toggleReaction(itemID: try itemID(item), key: key)
    }

    public func isSendQueueEnabled() -> Bool {
        player.isSendQueueEnabled
    }

    /// `Timeline.retrySend`: the SDK throws for an item it does not know.
    public func retrySend(_ item: ChatEventRef) throws {
        guard retrySend(itemID: try itemID(item)) else { throw ScriptedTimelineError.notAFailedSend }
    }

    /// `Timeline.abortSend`.
    public func abortSend(_ item: ChatEventRef) throws {
        abortSend(itemID: try itemID(item))
    }

    /// Scripted rooms have no server: receipts change nothing (the scenario
    /// scripts the other members' receipts).
    public func sendReceipt(_: ChatReceipt) {}

    /// Scripted replies to unknown originals stay unavailable.
    public func fetchReplyDetails(eventID _: String) {}

    private func itemID(_ ref: ChatEventRef) throws -> String {
        catchUp()
        guard let id = player.itemID(for: ref) else { throw ScriptedTimelineError.unknownItem }
        return id
    }

    // MARK: Clock

    private var elapsed: TimeInterval {
        guard let origin else { return 0 }
        let components = (clock.now - origin).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    private func catchUp() {
        guard origin != nil else { return }
        emit(player.advance(to: elapsed))
    }

    private func emit(_ values: [ScriptedTimelinePlayer.Output]) {
        for value in values { continuation.yield(output(value)) }
    }

    /// The player's output as the SDK source would send it. Reply details
    /// are judged on the player's list after the call that produced the
    /// output, where every original precedes its replies.
    private func output(_ value: ScriptedTimelinePlayer.Output) -> ChatTimelineOutput {
        switch value {
        case let .diffs(diffs):
            var details = [String: ChatReplyDetails]()
            for item in diffs.flatMap(\.carriedItems) {
                if let detail = player.replyDetails(for: item) { details[item.id] = detail }
            }
            return .batch(ChatTimelineBatch(diffs: diffs, replyDetails: details))
        case let .typing(userIDs):
            return .typing(userIDs: userIDs)
        case let .pagination(state):
            return .pagination(state)
        }
    }

    /// Sleeps until the next scheduled event; any command re-arms, because it
    /// may have scheduled an earlier one.
    private func rearm() {
        timer?.cancel()
        guard let next = player.nextEventTime else {
            timer = nil
            return
        }
        let delay = max(0, next - elapsed)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    private func fire() {
        catchUp()
        rearm()
    }
}
/// What a scripted call throws where the SDK would.
public enum ScriptedTimelineError: Error, Equatable, Sendable {
    case unknownItem
    case notAFailedSend
}

#endif
