import AtumChat
import AtumNativeAPI
import Foundation
import MatrixRustSDK

// One open room's timeline as the store uses it (plan §2.2, §2.3), over any
// `ChatTimelineSource`: the SDK's (`SDKTimelineSource`) in the app, the
// scripted one in Debug UI tests. Everything here is the same for both, so a
// U test against the scripted source exercises the real pipeline and the
// hotfix's send-queue rules.
//
// Data flow (§2.3):
//   source outputs, in order (mapped batches, pagination, scripted typing)
//     → `TimelinePipeline` actor (off main): TimelineProjector (buffer +
//       projection), reply details, the markdown parse cache
//     → main actor: `onPublication`, awaited before the next output, so
//       publications arrive in SDK order.

/// What one projector pass hands the main actor.
struct TimelinePublication: Sendable {
    /// The rows carry their run layout and quote details (`ChatRow`).
    let projected: ProjectedTimeline
    /// Parsed markdown keyed by row ID, with the body it was parsed from
    /// (the contract's parse cache: once per `(id, body)`, off the main
    /// actor). Only rows whose text renders as markdown: everything but my
    /// own messages, which show literally.
    let parsedBodies: [String: ParsedBody]
    /// Event ID → display ID of my phone-sent messages. The store hands it
    /// to the next timeline, so a renewal keeps their rows' IDs.
    let echoAliases: [String: String]
}

struct ParsedBody: Equatable, Sendable {
    let body: String
    /// What was parsed: `ChatItem.markdownBody` (the greeting's projection or the body).
    let markdownBody: String
    let botAPIFormattedBody: String?
    let isBotAPI: Bool
    let attributed: AttributedString
}

/// The projector task's state for one timeline, whatever its source.
actor TimelinePipeline {
    private let roomID: String
    private var projector: TimelineProjector
    private var parsedBodies = [String: ParsedBody]()
    private var echoAliases = [String: String]()

    init(roomID: String, context: RoomContext, generation: UInt64, calendar: Calendar,
         echoAliases: [String: String]) {
        self.roomID = roomID
        self.echoAliases = echoAliases
        projector = TimelineProjector(generation: generation, context: context, options: .s1, calendar: calendar)
    }

    /// Applies one source batch. Throws (state unchanged) on an index error.
    func apply(_ batch: ChatTimelineBatch, now: Date) throws -> TimelinePublication {
        let touched = batch.diffs.flatMap(\.carriedItems)
        let detailsBefore = projector.replyDetails
        for item in touched { projector.replyDetails[item.id] = batch.replyDetails[item.id] }
        let before = projector.buffer.items.count
        let projected: ProjectedTimeline
        do {
            projected = try projector.apply(batch.diffs, now: now)
        } catch {
            projector.replyDetails = detailsBefore
            throw error
        }
        echoAliases = batch.echoAliases.isEmpty ? echoAliases : batch.echoAliases
        absorb(touched)
        if ProbeLog.isEnabled, touched.contains(where: \.isLocalEcho) {
            ProbeLog.mark(.timelineBatch, id: LiveFlowLog.fingerprint(roomID),
                          fields: ["ops": ChatDiff.probeShape(batch.diffs), "before": String(before),
                                   "change": String(describing: projected.snapshot.change)])
        }
        return publication(projected)
    }

    func setTyping(_ names: [String], now: Date) -> TimelinePublication {
        projector.typingNames = names
        return publication(projector.project(now: now))
    }

    func setLoadingEarlier(_ loading: Bool, now: Date) -> TimelinePublication? {
        guard projector.isLoadingEarlier != loading else { return nil }
        projector.isLoadingEarlier = loading
        return publication(projector.project(now: now))
    }

    /// The clock moved past a no-answer deadline (B10).
    func tick(now: Date) -> TimelinePublication {
        publication(projector.project(now: now))
    }

    /// The parse cache for the items a batch carried, then forget rows that
    /// left the buffer (one pass over plain values). Reply details left
    /// behind for a gone row are dropped here too; the pass that just ran
    /// never looked them up.
    private func absorb(_ touched: [ChatItem]) {
        for item in touched {
            if item.isOwn || !Self.rendersMarkdown(item.kind) {
                parsedBodies[item.id] = nil
            } else if parsedBodies[item.id]?.body != item.body
                        || parsedBodies[item.id]?.markdownBody != item.markdownBody
                        || parsedBodies[item.id]?.botAPIFormattedBody != item.botAPI?.formattedBody
                        || parsedBodies[item.id]?.isBotAPI != (item.botAPI != nil) {
                let attributed: AttributedString
                if let botAPI = item.botAPI {
                    attributed = botAPI.formattedBody.map {
                        MessageMarkup.parseBotAPIHTML($0, fallback: item.body)
                    } ?? MessageMarkup.parsePlain(item.body)
                } else {
                    attributed = MessageMarkup.parse(item.markdownBody)
                }
                parsedBodies[item.id] = ParsedBody(
                    body: item.body,
                    markdownBody: item.markdownBody,
                    botAPIFormattedBody: item.botAPI?.formattedBody,
                    isBotAPI: item.botAPI != nil,
                    attributed: attributed
                )
            }
        }
        let live = Set(projector.buffer.items.lazy.map(\.id))
        parsedBodies = parsedBodies.filter { live.contains($0.key) }
        projector.replyDetails = projector.replyDetails.filter { live.contains($0.key) }
    }

    private func publication(_ projected: ProjectedTimeline) -> TimelinePublication {
        TimelinePublication(projected: projected, parsedBodies: parsedBodies, echoAliases: echoAliases)
    }

    private static func rendersMarkdown(_ kind: ChatItem.Kind) -> Bool {
        switch kind {
        case .message, .notice, .image, .file: true
        default: false
        }
    }
}

/// One room's timeline on one session. Closing it (or replacing the
/// session) ends it; the store builds a new one on the next session.
@MainActor
final class TimelineController {
    let roomID: String
    let generation: UInt64
    private let source: any ChatTimelineSource
    private let pipeline: TimelinePipeline
    private let clock: @Sendable () -> Date
    private var consumer: Task<Void, Never>?
    private var isClosed = false
    private enum PageSignal { case boundary, idle, timeout }
    /// Installed on the main actor before invoking the source. Its consumer
    /// cannot observe this call's early statuses before tracking exists.
    private var pagePublication: (id: UUID, started: Bool, idle: Bool,
                                  completion: AsyncStream<PageSignal>.Continuation)?
    private var pageRequest: Task<Bool, Error>?
    private var outputEnded = false
    private var paginationState = PaginationState.idle(hitTimelineStart: false)
    private let pagePublicationTimeout: Duration

    /// Called on the main actor, in source order.
    var onPublication: ((TimelinePublication) -> Void)?
    var onPaginationStatus: ((PaginationState) -> Void)?
    /// Typing user IDs from a source that also stands in for the room's
    /// typing listener (the scripted one). The SDK source never sends them:
    /// live typing comes from `TypingController`.
    var onTypingUserIDs: (([String]) -> Void)?
    /// The timeline is unusable (an out-of-order batch); rebuild it.
    var onFailure: (() -> Void)?

    /// The room's SDK timeline. The caller sets the callbacks, then calls
    /// `start()`, so the first batch (the SDK's cache) cannot be published
    /// to nobody. `aliases`: the previous timeline's `echoAliases`.
    static func make(room: Room, mapperRoom: ItemMapperRoom, generation: UInt64,
                     aliases: [String: String], calendar: Calendar = .current, threadRootID: String? = nil,
                     clock: @escaping @Sendable () -> Date) async throws -> TimelineController {
        let source = try await SDKTimelineSource.make(room: room, mapperRoom: mapperRoom, aliases: aliases,
                                                      calendar: calendar, threadRootID: threadRootID)
        return TimelineController(source: source, roomID: mapperRoom.roomID, context: mapperRoom.context,
                                  generation: generation, echoAliases: aliases, calendar: calendar, clock: clock)
    }

    /// The room's encryption state for the mapper (rule 10).
    static func encryption(of room: Room) async -> Bool? {
        await SDKTimelineSource.encryption(of: room)
    }

    /// Any source: the scripted one in Debug UI tests, the SDK's via `make`.
    init(source: any ChatTimelineSource, roomID: String, context: RoomContext, generation: UInt64,
         echoAliases: [String: String] = [:], calendar: Calendar = .current,
         clock: @escaping @Sendable () -> Date,
         pagePublicationTimeout: Duration = .seconds(5)) {
        self.pagePublicationTimeout = pagePublicationTimeout
        self.roomID = roomID
        self.generation = generation
        self.source = source
        self.clock = clock
        pipeline = TimelinePipeline(roomID: roomID, context: context, generation: generation, calendar: calendar,
                                    echoAliases: echoAliases)
    }

    /// Starts the source and consumes its outputs in order.
    func start() async {
        guard !isClosed, consumer == nil else { return }
        let outputs = source.outputs
        consumer = Task { [weak self, pipeline, clock] in
            for await output in outputs {
                guard let self, !self.isClosed else { return }
                switch output {
                case let .batch(batch):
                    do {
                        let publication = try await pipeline.apply(batch, now: clock())
                        guard !self.isClosed else { return }
                        self.onPublication?(publication)
                    } catch {
                        guard !self.isClosed else { return }
                        self.outputEnded = true
                        self.pagePublication?.completion.finish()
                        self.onFailure?()
                        return
                    }
                case let .pagination(state):
                    self.paginationState = state
                    if state == .paginating {
                        self.pagePublication?.started = true
                        self.pagePublication?.idle = false
                    }
                    self.onPaginationStatus?(state)
                    if let publication = await pipeline.setLoadingEarlier(state == .paginating, now: clock()),
                       !self.isClosed {
                        self.onPublication?(publication)
                    }
                    if state != .paginating {
                        self.pagePublication?.idle = true
                        self.pagePublication?.completion.yield(.idle)
                    }
                case let .outputBoundary(id):
                    if id == self.pagePublication?.id {
                        self.pagePublication?.completion.yield(.boundary)
                    }
                case let .typing(userIDs):
                    self.onTypingUserIDs?(userIDs)
                }
            }
            self?.outputEnded = true
            self?.pagePublication?.completion.finish()
        }
        await source.start()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pageRequest?.cancel()
        pagePublication?.completion.finish()
        consumer?.cancel()
        consumer = nil
        onPublication = nil
        onPaginationStatus = nil
        onTypingUserIDs = nil
        onFailure = nil
        let source = source
        Task { await source.stop() }
    }

    // MARK: Non-diff inputs

    func setTyping(_ names: [String]) async {
        let publication = await pipeline.setTyping(names, now: clock())
        guard !isClosed else { return }
        onPublication?(publication)
    }

    func tick() async {
        let publication = await pipeline.tick(now: clock())
        guard !isClosed else { return }
        onPublication?(publication)
    }

    // MARK: Actions

    /// B6. `send` only queues; the local echo arrives as a diff. A queue the
    /// SDK disabled after a recoverable failure is woken first, so it resends
    /// the earlier message before this one and order holds (the hotfix's
    /// `before_send` rule, `SendQueueRules`).
    func send(text: String, replyToEventID: String?, mentions: OutgoingMentions = .none) async throws {
        try await SendQueueRules.send(text: text, replyTo: replyToEventID, mentions: mentions,
                                      on: source, woke: logWake)
    }

    func send(attachment: OutgoingChatAttachment, caption: String?,
              replyToEventID: String?) async throws {
        try await SendQueueRules.send(attachment: attachment, caption: caption,
                                      replyTo: replyToEventID, on: source, woke: logWake)
    }

    /// B20: people chats only (the core checks).
    func edit(_ ref: ChatEventRef, text: String) async throws {
        try await source.edit(ref, text: text)
    }

    func redact(_ ref: ChatEventRef) async throws {
        try await source.redact(ref)
    }

    func toggleReaction(_ ref: ChatEventRef, key: String) async throws {
        try await source.toggleReaction(ref, key: key)
    }

    /// B8 "Thử lại": by the failure kind, then a disabled queue is woken
    /// (`SendQueueRules`).
    func repair(_ repair: SendRepair) async throws {
        try await SendQueueRules.repair(repair, on: source, woke: logWake)
    }

    /// B8 "Xóa": the request never went out; nothing is kept on the phone. A
    /// disabled queue is woken afterwards, or what waited behind the aborted
    /// request would stay sending (`SendQueueRules`).
    func abort(_ ref: ChatEventRef) async throws {
        try await SendQueueRules.abort(ref, on: source, woke: logWake)
    }

    /// B5. The core owns the page slot for search, scrolling and background
    /// loading. Coalesce unexpected concurrent callers instead of converting
    /// a scroll load into a failure or issuing a second SDK request.
    func paginateBackwards(events: UInt16) async throws -> Bool {
        guard !isClosed else { throw CancellationError() }
        if let pageRequest { return try await pageRequest.value }
        let request = Task { try await self.performPage(events: events) }
        pageRequest = request
        defer { pageRequest = nil }
        return try await request.value
    }

    private func performPage(events: UInt16) async throws -> Bool {
        let id = UUID()
        let (published, completion) = AsyncStream.makeStream(of: PageSignal.self)
        pagePublication = (id, false, false, completion)
        defer { completion.finish(); pagePublication = nil }
        let hitStart = try await source.paginateBackwards(numEvents: events)
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
        if !outputEnded {
            // Flush queued outputs before deciding whether loading was seen.
            // The marker itself and idle are both covered by the same bound.
            let marker = Task { [source] in
                if !(await source.markOutputBoundary(id)), self.outputEnded { completion.finish() }
            }
            let timeout = Task { [pagePublicationTimeout] in
                do { try await Task.sleep(for: pagePublicationTimeout) } catch { return }
                completion.yield(.timeout)
                completion.finish()
            }
            defer { marker.cancel(); timeout.cancel() }
            var flushed = false
            for await signal in published {
                guard !isClosed, !Task.isCancelled else { throw CancellationError() }
                switch signal {
                case .boundary: flushed = true
                case .idle: break
                case .timeout:
                    #if DEBUG
                    UITestProbe.append("search.page.timeout bound=\(pagePublicationTimeout)",
                                       to: "search-placement.txt")
                    #endif
                    await finishPageStatusIfNeeded(hitStart: hitStart)
                    return hitStart
                }
                if flushed, pagePublication?.started == false || pagePublication?.idle == true { break }
            }
        }
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
        await finishPageStatusIfNeeded(hitStart: hitStart)
        return hitStart
    }

    /// A missing idle must not leave the core/pager at `.paginating` after
    /// the call completed: that would make the next search wait forever too.
    private func finishPageStatusIfNeeded(hitStart: Bool) async {
        guard paginationState == .paginating else { return }
        paginationState = .idle(hitTimelineStart: hitStart)
        onPaginationStatus?(paginationState)
        if let publication = await pipeline.setLoadingEarlier(false, now: clock()), !isClosed {
            onPublication?(publication)
        }
    }

    /// B13 (`.readPublic` / `.readPrivate`) and B15 (`.fullyRead(eventID:)`).
    func sendReceipt(_ receipt: ChatReceipt) async throws {
        try await source.sendReceipt(receipt)
    }

    /// B21: loads the original of a reply that is not in the timeline.
    func fetchReplyDetails(eventID: String) async {
        await source.fetchReplyDetails(eventID: eventID)
    }

    // MARK: Private

    /// The hotfix's content-free line for each room queue woken.
    private var logWake: @Sendable (SendQueueRules.Wake) -> Void {
        let roomID = roomID
        return { wake in LiveFlowLog.sendQueue(.roomEnabled, outcome: wake.rawValue, roomID: roomID) }
    }
}
