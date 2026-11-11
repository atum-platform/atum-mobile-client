import Foundation

// The decisions of one open chat, on plain values (plan §2.6
// `ConversationStore`). The app's `@MainActor @Observable` store holds one
// `ConversationCore`, feeds it the projector's output and the view's inputs,
// and runs the `ConversationEffect`s it returns against the SDK. Keeping the
// decisions here means `swift test` proves them; the store is glue.

/// How earlier history loads beyond §2.3 rule 7's first page.
public enum HistoryLoading: Equatable, Sendable {
    /// B5: near the top (`PaginationPolicy` decides), one page at a time.
    /// Needs a transcript that holds the row being read when rows are added
    /// above it (WS2's `TranscriptView` measures and restores the anchor).
    case onScroll
    /// For a transcript without that anchor (the interim host): up to
    /// `pages` pages per timeline, only while the view follows the bottom,
    /// where rows added above do not move what the person sees; never on
    /// scroll. The hotfix loaded the same depth at open.
    case whileFollowing(pages: Int)
}

// The two WS3 policies the core runs (plan §5.3: WS3 delivers them, WS1's
// store consumes them): `ReadPolicy` (B13, B15) and `PaginationPolicy` (B5).
// They count time in seconds; the core passes `Date.timeIntervalSinceReferenceDate`
// and turns their deadlines back into dates for the store's wake-ups.

// MARK: - Effects

/// What the core asks the app to do with the SDK.
public enum ConversationEffect: Equatable, Sendable {
    /// `Timeline.send` (plain text, `formatted: nil`), or `sendReply` when
    /// `replyToEventID` is set.
    case send(text: String, replyToEventID: String?)
    /// `Timeline.edit(eventOrTransactionId:newContent:)` with plain text.
    case edit(ChatEventRef, text: String)
    /// `Timeline.redactEvent(eventOrTransactionId:reason: nil)`.
    case redact(ChatEventRef)
    /// `Timeline.toggleReaction(itemId:key:)`.
    case toggleReaction(ChatEventRef, key: String)
    /// B8 "Thử lại".
    case repair(SendRepair)
    /// B8 "Xóa" on a failed send: `Timeline.abortSend(itemId:target: .event)`.
    case abortSend(ChatEventRef)
    /// `Timeline.paginateBackwards(numEvents:)`.
    case paginateBackwards(events: UInt16)
    /// B13: `ChatReceipt.readPrivate` (`ReadPolicy.Call.privateReceipt`;
    /// the SDK source also clears a marked-unread flag). The store reports
    /// the result with `receiptFinished(succeeded:now:)`.
    case markReadPrivate
    /// B15: `ChatReceipt.fullyRead(eventID:)` on leaving, for the last event
    /// a private receipt acknowledged on this visit (`ReadPolicy.leave()`).
    case markFullyRead(eventID: String)
    /// Call `readWakeDue(now:)` at this time (the read policy's settle, its
    /// 2 s cap, or a retry after a failed receipt).
    case wakeReadGate(at: Date)
    /// Call `paginationWakeDue(now:)` at this time (the pagination policy's
    /// 0.1 s throttle or its backoff after a failed page).
    case wakePagination(at: Date)
    /// B21: `Timeline.fetchDetailsForEvent(eventId:)` for a reply whose
    /// original is not loaded.
    case fetchReplyDetails(eventID: String)
}

// MARK: - Message action rules (B20)

/// Which long-press actions a row allows. The menu (WS3) shows them; the
/// core enforces them.
public enum ChatItemRules {
    /// Something a person sent that still exists.
    private static func isActionable(_ item: ChatItem) -> Bool {
        guard item.kind.isEventContent else { return false }
        switch item.kind {
        case .roomState, .placeholder(.redacted): return false
        default: return item.eventOrTransactionId != nil
        }
    }

    /// "Trả lời": the original must be on the server (an event ID).
    public static func canReply(_ item: ChatItem) -> Bool {
        isActionable(item) && item.eventID != nil
    }

    /// The reaction row: also works on a local echo.
    public static func canReact(_ item: ChatItem) -> Bool {
        isActionable(item)
    }

    /// "Xóa" on my own messages.
    public static func canDelete(_ item: ChatItem) -> Bool {
        isActionable(item) && item.isOwn
    }

    /// "Sửa" on my own text messages in people chats only: editing a prompt
    /// does not re-run an agent. A failed send is retried or deleted, not
    /// edited.
    public static func canEdit(_ item: ChatItem, in kind: RoomKind) -> Bool {
        guard kind == .person || kind == .group, isActionable(item), item.isOwn, item.kind == .message else {
            return false
        }
        if case .failed = item.delivery { return false }
        return true
    }
}

// MARK: - The core

public struct ConversationCore: Sendable {
    /// Events per back-pagination request (B5, `EX` page size).
    public static let pageSize: UInt16 = PaginationPolicy.pageSize
    /// After a failed background page (rule 7, a handover, the interim
    /// depth), background loading waits this long. Pages asked for by
    /// scrolling back off by `PaginationPolicy`'s own schedule.
    public static let pageRetryDelay: TimeInterval = 5
    /// A held send handed to the SDK keeps its row until its local echo
    /// shows, at most this long.
    public static let handingGrace: TimeInterval = 5
    /// IDs of held sends' rows (`atum.` is never an SDK-derived ID).
    public static let heldRowPrefix = "atum.held."

    public let context: RoomContext
    public var kind: RoomKind { context.kind }
    public let history: HistoryLoading
    /// Kept per room while the app runs (B25).
    public var draft: String
    /// The event a reply will answer (B21).
    public private(set) var replyTarget: String?
    /// The row "Sửa" loaded into the composer (B20, people chats).
    public private(set) var editTarget: String?
    public private(set) var follow = FollowPolicy()
    public private(set) var scrollRequest = ScrollRequest.initial
    public private(set) var projected: ProjectedTimeline?
    public private(set) var pagination = PaginationState.idle(hitTimelineStart: false)
    public private(set) var typingNames = [String]()
    public private(set) var bottomVisible = false
    /// A timeline is open on the current session. False before the first
    /// one and while the session is renewed.
    public private(set) var isAttached = false

    /// Sends tapped while no timeline is attached (a token renewal swaps the
    /// runtime for a second or two; an offline renewal can take longer).
    /// Each shows as my own row with a clock (B6, B9) and goes out in tap
    /// order on attach. Leaving the chat, or an attach that fails, puts
    /// their text back in the composer (B8: never lost).
    public private(set) var pendingSends = [PendingSend]()

    /// B13, B15: WS3's read policy, one per open chat (a visit); kept across
    /// session renewals, so a renewed timeline does not acknowledge again.
    public private(set) var read = ReadPolicy()
    /// B5: WS3's pagination policy for pages asked for by scrolling; a new
    /// one per timeline.
    public private(set) var pager = PaginationPolicy()
    /// The one back-pagination request in flight, whoever asked for it.
    private var pageInFlight: PageRequest?
    private var pageFailedAt: Date?
    private var prefetchedPages = 0
    private var requestedReplyFetches = Set<String>()
    private var receivedFirstProjection = false
    /// The composer's text before "Sửa" replaced it; it comes back when the
    /// edit is sent, cancelled or replaced.
    private var draftBeforeEdit: String?
    /// Held sends flushed on attach: their rows stay until their local
    /// echoes show (or `handingGrace`), so nothing blinks out.
    private var handing = [PendingSend]()
    private var handingSince: Date?
    /// Local echoes already on screen when the held sends were flushed.
    private var knownEchoIDs = Set<String>()
    /// Where the next send that lost its timeline mid-flight goes back in
    /// `pendingSends`: before sends tapped later.
    private var requeueIndex = 0
    private var heldSequence: UInt64 = 0
    /// Rows on screen when the session was replaced (`SessionHandover`).
    private var handoverRows: [ChatRow]?
    /// The handover's merged rows while it runs.
    private var mergedRows: [ChatRow]?
    /// The change of a step that altered the rows without a projection
    /// (a held send); cleared by the next projection.
    private var localChange: SnapshotChange?
    /// Failed sends "Thử lại" re-enabled the room's queue for (U5, D8;
    /// coordinator decision 9): they show the clock until the source sends
    /// its next state for them. Re-enabling a queue emits no update in the
    /// pinned SDK, so without this the row would keep "Chưa gửi được" while
    /// it is in fact going out again.
    public private(set) var retryingIDs = Set<String>()

    /// Who asked for the page in flight: `PaginationPolicy` (scrolling) or
    /// the core's own background loading.
    private enum PageRequest: Equatable, Sendable {
        case scroll
        case background
        /// HC-6: a page the chat's search asked for (`startSearchPage`).
        case search
    }

    public struct PendingSend: Equatable, Sendable {
        public var id: String
        public var text: String
        public var replyToEventID: String?
        public var timestamp: Date
    }

    public init(context: RoomContext, draft: String = "", history: HistoryLoading = .onScroll) {
        self.context = context
        self.history = history
        self.draft = draft
    }

    public init(kind: RoomKind, draft: String = "", history: HistoryLoading = .onScroll) {
        self.init(context: RoomContext(kind: kind, ownUserID: ""), draft: draft, history: history)
    }

    /// What the transcript shows: the projection (or, during a handover,
    /// the older rows above it), then held sends, then the typing row. Rows
    /// the projection did not lay out together get their run layout here
    /// (`ChatRow.grouping`); sender lines stay as projected.
    public var snapshot: Snapshot {
        let base = projected?.snapshot ?? .empty
        let held = heldRows
        guard mergedRows != nil || !held.isEmpty || localChange != nil || !retryingIDs.isEmpty else { return base }
        var rows = mergedRows ?? base.rows
        if !retryingIDs.isEmpty {
            for index in rows.indices where retryingIDs.contains(rows[index].id) && rows[index].delivery == .failed {
                rows[index].delivery = .sending
            }
        }
        if !held.isEmpty {
            let end: Int
            if case .typing? = rows.last?.item.kind { end = rows.count - 1 } else { end = rows.count }
            rows.insert(contentsOf: held, at: end)
        }
        if mergedRows != nil || !held.isEmpty {
            rows = Grouping.apply(to: rows, context: context, groupsRuns: false)
        }
        return Snapshot(rows: rows, change: localChange ?? (mergedRows != nil ? .inPlace : base.change),
                        generation: base.generation)
    }

    /// The display row for an ID, if it is on screen (handover rows and held
    /// sends included).
    public func row(_ id: String) -> ChatRow? {
        snapshot.rows.first { $0.id == id }
    }

    // MARK: Timeline

    /// One projection pass from the attached timeline. Runs the handover,
    /// the follow rule on its change, the read rule on new content, fetches
    /// missing reply details and loads history in the background: one page
    /// for a chat with nothing cached (§2.3 rule 7), pages until a handover
    /// caught up, and the `whileFollowing` depth.
    public mutating func receive(_ projection: ProjectedTimeline, now: Date) -> [ConversationEffect] {
        projected = projection
        localChange = nil
        let rows = projection.snapshot.rows
        if !retryingIDs.isEmpty {
            // The source's next state for a retried send ends its clock:
            // sending, sent (then "Đã gửi"), failed again, or gone.
            retryingIDs.subtract(projection.touchedItemIDs)
            let shown = Set(rows.lazy.map(\.id))
            retryingIDs.formIntersection(shown)
        }
        if let old = handoverRows {
            if let merged = SessionHandover.rows(displayed: old, incoming: rows, following: follow.isFollowing) {
                mergedRows = merged
            } else {
                handoverRows = nil
                mergedRows = nil
            }
        }
        settleHanding(rows, now: now)
        apply(follow.handle(FollowInput.from(projection.snapshot.change)))

        var effects = readStep(now: now)
        for eventID in ChatReplyDetails.fetchRequests(rows: rows, alreadyRequested: requestedReplyFetches) {
            requestedReplyFetches.insert(eventID)
            effects.append(.fetchReplyDetails(eventID: eventID))
        }
        if !receivedFirstProjection {
            receivedFirstProjection = true
            if !rows.contains(where: { $0.item.kind.isEventContent }), let page = startBackgroundPage(now: now) {
                effects.append(page)
            }
        }
        if let page = backgroundPage(now: now) { effects.append(page) }
        return effects
    }

    /// The SDK's back-pagination status (B5). While a background page of the
    /// core's own is in flight the pagination policy is not told: it stays
    /// blocked until that page finishes (`paginationFinished`), so it never
    /// asks for a second page at the same time.
    @discardableResult
    public mutating func paginationChanged(_ state: PaginationState, now: Date) -> [ConversationEffect] {
        pagination = state
        guard usesPager, pageInFlight != .background, pageInFlight != .search else { return [] }
        return pageEffects(pager.statusChanged(state, now: Self.seconds(now)))
    }

    /// Our own `paginateBackwards` call returned (`hitTimelineStart`) or
    /// failed (nil). A page asked for by scrolling reports to
    /// `PaginationPolicy`, which may ask again (more rows still needed) or
    /// back off after a failure (1 s, 4 s, 15 s, then until a scroll or
    /// `resumePagination`). A background page continues background loading,
    /// or pauses it for `pageRetryDelay` after a failure.
    @discardableResult
    public mutating func paginationFinished(hitTimelineStart: Bool?, now: Date) -> [ConversationEffect] {
        let finished = pageInFlight
        pageInFlight = nil
        if hitTimelineStart == true { pagination = .idle(hitTimelineStart: true) }
        var effects = [ConversationEffect]()
        switch finished {
        case .scroll?:
            let seconds = Self.seconds(now)
            let decision = hitTimelineStart.map { pager.requestFinished(hitTimelineStart: $0, now: seconds) }
                ?? pager.requestFailed(now: seconds)
            effects = pageEffects(decision)
        case .background?:
            pageFailedAt = hitTimelineStart == nil ? now : nil
            if usesPager { effects = pageEffects(pager.statusChanged(pagination, now: Self.seconds(now))) }
        case .search?:
            if usesPager { effects = pageEffects(pager.statusChanged(pagination, now: Self.seconds(now))) }
        case nil:
            break
        }
        if effects.isEmpty, let page = backgroundPage(now: now) { effects.append(page) }
        return effects
    }

    /// HC-6: the chat's search may load one older page now: a timeline is
    /// attached, no other page is in flight and the start is not reached.
    /// True claims the page; the caller runs `paginateBackwards` itself and
    /// reports through `paginationFinished`. Scrolling's policy is held at
    /// `.paginating` meanwhile, so it never asks at the same time.
    public mutating func startSearchPage(now: Date) -> Bool {
        guard isAttached, pageInFlight == nil, pagination == .idle(hitTimelineStart: false) else { return false }
        pageInFlight = .search
        if usesPager { _ = pager.statusChanged(.paginating, now: Self.seconds(now)) }
        return true
    }

    /// The room's first event is loaded: no older page exists.
    public var reachedTimelineStart: Bool { pagination == .idle(hitTimelineStart: true) }

    /// A `wakePagination` time came: the throttle or a backoff step ended.
    public mutating func paginationWakeDue(now: Date) -> [ConversationEffect] {
        if let page = backgroundPage(now: now) { return [page] }
        guard usesPager else { return [] }
        return pageEffects(pager.decide(now: Self.seconds(now)))
    }

    /// The network may be back: sync recovered after being offline, or the
    /// app returned to the foreground. Every pagination backoff ends and the
    /// last geometry is checked again (`PaginationPolicy.resume`).
    public mutating func resumePagination(now: Date) -> [ConversationEffect] {
        pageFailedAt = nil
        if let page = backgroundPage(now: now) { return [page] }
        guard usesPager else { return [] }
        return pageEffects(pager.resume(now: Self.seconds(now)))
    }

    /// A timeline is open (first open, or after a session renewal): it
    /// starts fresh, and sends tapped meanwhile go out in tap order.
    public mutating func attached(now: Date) -> [ConversationEffect] {
        isAttached = true
        receivedFirstProjection = false
        requestedReplyFetches.removeAll()
        pagination = .idle(hitTimelineStart: false)
        pageInFlight = nil
        pager = PaginationPolicy()
        pageFailedAt = nil
        prefetchedPages = 0
        requeueIndex = 0
        guard !pendingSends.isEmpty else { return [] }
        let flushed = pendingSends
        pendingSends.removeAll()
        if handing.isEmpty { knownEchoIDs = Set(displayRows.filter(\.item.isLocalEcho).map(\.id)) }
        handing += flushed
        handingSince = now
        return flushed.map { .send(text: $0.text, replyToEventID: $0.replyToEventID) }
    }

    /// The session is being replaced: the timeline is gone until `attached`.
    /// The rows on screen stay (`SessionHandover`).
    public mutating func detached() {
        if isAttached || handoverRows == nil { handoverRows = displayRows }
        isAttached = false
        pageInFlight = nil
        requeueIndex = 0
        // Nothing is acknowledged while no timeline is attached (B13).
        // Hiding cancels the policy's timer and never reads the time.
        read.setBottomVisible(false, now: 0)
    }

    /// The timeline could not be opened: held sends go back to the composer
    /// rather than wait for an attach that may never come.
    public mutating func attachFailed() {
        returnHeldSends()
    }

    /// A send handed to the store lost its timeline before reaching the SDK
    /// (the session was replaced mid-flight): it is held again, before
    /// sends tapped later. If a timeline is attached by now, it goes out.
    public mutating func requeue(text: String, replyToEventID: String?, now: Date) -> [ConversationEffect] {
        if isAttached { return [.send(text: text, replyToEventID: replyToEventID)] }
        var held = newHeld(text: text, replyToEventID: replyToEventID, now: now)
        if let index = handing.firstIndex(where: { $0.text == text }) { held = handing.remove(at: index) }
        pendingSends.insert(held, at: min(requeueIndex, pendingSends.count))
        requeueIndex += 1
        localChange = .inPlace
        return []
    }

    /// The SDK refused a send and the store put its text back in the
    /// composer: its held row, if any, goes.
    public mutating func sendRefused(text: String) {
        guard let index = handing.firstIndex(where: { $0.text == text }) else { return }
        handing.remove(at: index)
        localChange = .inPlace
    }

    /// Leaving the chat (B15). An unfinished edit is abandoned (the earlier
    /// draft comes back) and held sends go back to the composer, so the
    /// draft the app keeps for this room holds them. The fully-read marker
    /// moves to the last event a private receipt acknowledged on this visit
    /// (`ReadPolicy.leave()`), by event ID: a chat left while scrolled up
    /// keeps newer messages unread.
    public mutating func leaving() -> [ConversationEffect] {
        endEdit()
        returnHeldSends()
        guard case let .fullyRead(eventID)? = read.leave(), isAttached else { return [] }
        return [.markFullyRead(eventID: eventID)]
    }

    /// Whoever is typing, my own user already dropped (B10, B11).
    public mutating func typingChanged(_ names: [String]) {
        let appeared = typingNames.isEmpty && !names.isEmpty
        typingNames = names
        if appeared { apply(follow.handle(.typingShown)) }
    }

    // MARK: View

    /// Geometry, phase, visibility, keyboard and composer events (§2.5).
    /// `.geometry` also drives history loading (B5): `PaginationPolicy`
    /// (two screens from the top, one request in flight, 0.1 s throttle).
    public mutating func handle(_ input: FollowInput, now: Date) -> [ConversationEffect] {
        apply(follow.handle(input))
        guard case let .geometry(_, distanceFromTop, viewportHeight, _) = input else { return [] }
        if let page = backgroundPage(now: now) { return [page] }
        guard usesPager else { return [] }
        return pageEffects(pager.geometry(distanceFromTop: distanceFromTop, viewportHeight: viewportHeight,
                                          now: Self.seconds(now)))
    }

    /// Set by the view (B13).
    public mutating func setBottomVisible(_ visible: Bool, now: Date) -> [ConversationEffect] {
        bottomVisible = visible
        return readStep(now: now)
    }

    /// The live room list observed `RoomInfo.isMarkedUnread` change (B13).
    /// This is separate from timeline diffs: another device can mark the
    /// room unread while this phone remains at the bottom, and the next
    /// private receipt must clear that explicit flag even when no message
    /// arrived meanwhile.
    public mutating func markedUnreadChanged(_ marked: Bool, now: Date) -> [ConversationEffect] {
        read.setMarkedUnread(marked, now: Self.seconds(now))
        return readStep(now: now)
    }

    /// A `wakeReadGate` time came.
    public mutating func readWakeDue(now: Date) -> [ConversationEffect] {
        readStep(now: now)
    }

    /// The private receipt finished. A failure (offline at the bottom)
    /// acknowledges nothing; `ReadPolicy` asks again after 1 s, 4 s and 15 s
    /// (B13, D5). A success may be followed by another receipt when a newer
    /// event arrived meanwhile.
    public mutating func receiptFinished(succeeded: Bool, now: Date) -> [ConversationEffect] {
        read.finished(succeeded: succeeded, now: Self.seconds(now))
        return readDue(now: now)
    }

    // MARK: Composer and actions

    /// B6: the trimmed draft goes out as plain text and the draft clears in
    /// the same step; while no timeline is attached it is held (a row with a
    /// clock). With a reply target, a reply (B21). With an edit target, the
    /// edit (B20) and never a new message: while detached the composer keeps
    /// the edit until the timeline is back; when the message can no longer
    /// be edited (deleted, gone), the edit ends and the text stays in the
    /// composer.
    public mutating func send(now: Date = Date()) -> [ConversationEffect] {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if let editTarget {
            guard isAttached else { return [] }
            guard let item = row(editTarget)?.item, ChatItemRules.canEdit(item, in: kind),
                  let ref = item.eventOrTransactionId else {
                self.editTarget = nil
                draft = Self.joined([draftBeforeEdit ?? "", draft])
                draftBeforeEdit = nil
                return []
            }
            self.editTarget = nil
            draft = draftBeforeEdit ?? ""
            draftBeforeEdit = nil
            return [.edit(ref, text: text)]
        }
        draft = ""
        let reply = replyTarget
        replyTarget = nil
        guard isAttached else {
            pendingSends.append(newHeld(text: text, replyToEventID: reply, now: now))
            localChange = .appendedAtEnd(count: 0, localEcho: true)
            apply(follow.handle(.appended(count: 0, localEcho: true)))
            return []
        }
        return [.send(text: text, replyToEventID: reply)]
    }

    /// S4: the composer owns the attachment values, while the pure core owns
    /// the draft/reply semantics. Consume them atomically so the first
    /// attachment receives both and no separate text event is produced.
    public mutating func takeMediaCaption() -> (caption: String?, replyToEventID: String?)? {
        guard editTarget == nil else { return nil }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        let reply = replyTarget
        replyTarget = nil
        return (text.isEmpty ? nil : text, reply)
    }

    /// "Trả lời" (B21). Replaces an edit in progress.
    @discardableResult
    public mutating func reply(to itemID: String) -> Bool {
        guard let item = row(itemID)?.item, ChatItemRules.canReply(item), let eventID = item.eventID else {
            return false
        }
        endEdit()
        replyTarget = eventID
        return true
    }

    public mutating func cancelReply() { replyTarget = nil }

    /// The protocol's settable `replyTarget` (an event ID). Setting one
    /// replaces an edit in progress.
    public mutating func setReplyTarget(_ eventID: String?) {
        if eventID != nil { endEdit() }
        replyTarget = eventID
    }

    /// "Sửa" (B20): loads my message into the composer; the draft that was
    /// there comes back afterwards.
    @discardableResult
    public mutating func beginEdit(_ itemID: String) -> Bool {
        guard let item = row(itemID)?.item, ChatItemRules.canEdit(item, in: kind) else { return false }
        replyTarget = nil
        if editTarget == nil { draftBeforeEdit = draft }
        editTarget = itemID
        draft = item.body
        return true
    }

    public mutating func cancelEdit() { endEdit() }

    /// "Thử lại" on a failed send (B8). A recoverable failure re-enables the
    /// room's queue, which resends every recoverable failure in the room in
    /// order and tells the timeline nothing until each one's next state; those
    /// rows show the clock again until then (U5, decision 9). A parked request
    /// needs no help: `retrySend` makes the SDK show it sending.
    public mutating func retry(_ itemID: String) -> [ConversationEffect] {
        guard let item = row(itemID)?.item, let repair = Delivery.retry(for: item) else { return [] }
        if repair == .enableRoomQueue {
            let resent = displayRows.lazy
                .filter { $0.item.isOwn && $0.item.delivery == .failed(isRecoverable: true) }
                .map(\.id)
            retryingIDs.formUnion(resent)
            localChange = .inPlace
        }
        return [.repair(repair)]
    }

    /// "Xóa" on a failed send (B8), or on a held send (it never left).
    public mutating func abort(_ itemID: String) -> [ConversationEffect] {
        if removeHeld(itemID) { return [] }
        guard let item = row(itemID)?.item, let ref = Delivery.abortTarget(for: item) else { return [] }
        return [.abortSend(ref)]
    }

    /// "Xóa" on my message (B20): a held send is dropped, a failed send
    /// aborted, anything else redacted.
    public mutating func delete(_ itemID: String) -> [ConversationEffect] {
        if removeHeld(itemID) { return [] }
        guard let item = row(itemID)?.item else { return [] }
        if let ref = Delivery.abortTarget(for: item) { return [.abortSend(ref)] }
        guard ChatItemRules.canDelete(item), let ref = item.eventOrTransactionId else { return [] }
        return [.redact(ref)]
    }

    /// A reaction chip or the palette (B22).
    public func toggleReaction(_ itemID: String, key: String) -> [ConversationEffect] {
        guard let item = row(itemID)?.item, ChatItemRules.canReact(item),
              let ref = item.eventOrTransactionId, !key.isEmpty else { return [] }
        return [.toggleReaction(ref, key: key)]
    }

    // MARK: Private

    private mutating func apply(_ command: FollowCommand) {
        guard command != .none else { return }
        scrollRequest = ScrollRequest(sequence: scrollRequest.sequence &+ 1, command: command)
    }

    /// The rows the timeline side shows, without held sends.
    private var displayRows: [ChatRow] { mergedRows ?? projected?.snapshot.rows ?? [] }

    private var heldRows: [ChatRow] {
        (handing + pendingSends).map { held in
            ChatRow(item: ChatItem(id: held.id, kind: .message, sender: context.ownUserID, isOwn: true,
                                   isLocalEcho: true, timestamp: held.timestamp, delivery: .sending(),
                                   body: held.text, replyTo: held.replyToEventID),
                    delivery: .sending)
        }
    }

    private mutating func newHeld(text: String, replyToEventID: String?, now: Date) -> PendingSend {
        heldSequence &+= 1
        return PendingSend(id: Self.heldRowPrefix + String(heldSequence), text: text,
                           replyToEventID: replyToEventID, timestamp: now)
    }

    private mutating func removeHeld(_ itemID: String) -> Bool {
        guard let index = pendingSends.firstIndex(where: { $0.id == itemID }) else { return false }
        pendingSends.remove(at: index)
        localChange = .inPlace
        return true
    }

    /// Held texts back into the composer, before what is typed there (or
    /// before the pre-edit draft while an edit is open).
    private mutating func returnHeldSends() {
        guard !pendingSends.isEmpty else { return }
        let texts = pendingSends.map(\.text)
        pendingSends.removeAll()
        localChange = .inPlace
        if editTarget != nil {
            draftBeforeEdit = Self.joined(texts + [draftBeforeEdit ?? ""])
        } else {
            draft = Self.joined(texts + [draft])
        }
    }

    private mutating func endEdit() {
        guard editTarget != nil else { return }
        editTarget = nil
        draft = draftBeforeEdit ?? ""
        draftBeforeEdit = nil
    }

    /// Held rows handed to the SDK leave as their local echoes arrive.
    private mutating func settleHanding(_ rows: [ChatRow], now: Date) {
        guard !handing.isEmpty else { return }
        let fresh = Set(rows.lazy.filter { $0.item.isOwn && $0.item.isLocalEcho }.map(\.id)).subtracting(knownEchoIDs)
        knownEchoIDs.formUnion(fresh)
        handing.removeFirst(min(fresh.count, handing.count))
        if let handingSince, now >= handingSince.addingTimeInterval(Self.handingGrace) { handing.removeAll() }
        if handing.isEmpty { handingSince = nil }
    }

    /// The two policies count seconds.
    private static func seconds(_ date: Date) -> TimeInterval { date.timeIntervalSinceReferenceDate }

    /// Pages asked for by scrolling go through `PaginationPolicy`, on an
    /// attached timeline with a transcript that holds the row being read.
    private var usesPager: Bool { history == .onScroll && isAttached }

    /// One of `PaginationPolicy`'s decisions as effects. Every call that can
    /// return `.request` happens only when no background page is in flight
    /// (the policy is held at `.paginating` meanwhile), so a request is
    /// always the only one.
    private mutating func pageEffects(_ decision: PaginationPolicy.Decision) -> [ConversationEffect] {
        switch decision {
        case .none:
            return []
        case let .retry(at):
            return [.wakePagination(at: Date(timeIntervalSinceReferenceDate: at))]
        case .request:
            pageInFlight = .scroll
            return [.paginateBackwards(events: PaginationPolicy.pageSize)]
        }
    }

    /// A page nobody scrolled for (rule 7, a handover, the interim depth).
    /// `PaginationPolicy` is held at `.paginating` until it finishes.
    private mutating func startBackgroundPage(now: Date) -> ConversationEffect? {
        guard isAttached, pageInFlight == nil, pagination == .idle(hitTimelineStart: false) else { return nil }
        pageInFlight = .background
        if usesPager { _ = pager.statusChanged(.paginating, now: Self.seconds(now)) }
        return .paginateBackwards(events: Self.pageSize)
    }

    /// History loading nobody scrolled for: until a handover caught up, and
    /// the `whileFollowing` depth while the view follows the bottom. A failed
    /// background page pauses it for `pageRetryDelay`.
    private mutating func backgroundPage(now: Date) -> ConversationEffect? {
        guard isAttached, pageInFlight == nil, pagination == .idle(hitTimelineStart: false) else { return nil }
        if let pageFailedAt, now < pageFailedAt.addingTimeInterval(Self.pageRetryDelay) { return nil }
        if mergedRows != nil { return startBackgroundPage(now: now) }
        guard case let .whileFollowing(pages) = history, follow.isFollowing, prefetchedPages < pages else {
            return nil
        }
        prefetchedPages += 1
        return startBackgroundPage(now: now)
    }

    /// Feeds `ReadPolicy` the current inputs (the bottom visible on an
    /// attached timeline, the newest settled event on screen) and runs what
    /// is due. Held sends carry no event ID, so they never count.
    private mutating func readStep(now: Date) -> [ConversationEffect] {
        let seconds = Self.seconds(now)
        read.setBottomVisible(bottomVisible && isAttached, now: seconds)
        read.latestEventChanged(ReadPolicy.latestSettledEventID(in: displayRows.map(\.item)), now: seconds)
        return readDue(now: now)
    }

    /// The private receipt when `ReadPolicy`'s timer is due, else a wake-up
    /// at its deadline.
    private mutating func readDue(now: Date) -> [ConversationEffect] {
        guard let deadline = read.nextDeadline else { return [] }
        let seconds = Self.seconds(now)
        guard seconds >= deadline else { return [.wakeReadGate(at: Date(timeIntervalSinceReferenceDate: deadline))] }
        guard case .privateReceipt? = read.tick(now: seconds) else { return [] }
        return [.markReadPrivate]
    }

    private static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

// MARK: - Publishing the follow state

extension FollowPolicy {
    /// Whether a store must replace the copy of the policy it publishes to
    /// views with this one: only when what a view shows from it changes, the
    /// follow state or the pill (`detached(0)` shows its arrow only beyond one
    /// screen up, so the pill can change while the state does not). The
    /// policy also records the raw scroll distances, which change on every
    /// scroll frame. The transcript reports geometry from inside the hosting
    /// view's layout pass, and UIKit tracks observable reads made there:
    /// republishing on every frame laid the screen out again, which reported
    /// geometry again, an endless layout loop (WS3's "Observation tracking
    /// feedback loop", S1 checkpoint 1 §4).
    public func needsPublishing(over published: FollowPolicy) -> Bool {
        state != published.state || pill != published.pill
    }
}

// MARK: - Session handover

/// The phone renews its 300 s Matrix token about every four minutes in the
/// foreground, which rebuilds the client and so the open chat's timeline. The
/// new timeline starts with only what the SDK loads first and pages older
/// history in (the core pages it back in the background). While a person is
/// reading further up, the rows already on screen that are older than
/// everything the new timeline has stay above it, so the transcript neither
/// shrinks nor moves (the hotfix's `MobileTimelineHandoverPolicy`, on
/// display rows).
public enum SessionHandover {
    /// The rows to show during a handover, or nil once it is over: the new
    /// timeline reaches back as far as the old rows did, shares no event
    /// with them, or the view follows the bottom (older rows do not matter
    /// there). A new timeline with no event row yet keeps the old rows,
    /// following or not: it never blanks the transcript. Overlap is judged
    /// on the first event row of `incoming` (display IDs are stable across
    /// timelines, `DisplayIdentityTable`); leading virtual rows of
    /// `incoming` are dropped when older rows stay above, and an older row
    /// whose ID the new timeline also shows (a read marker) is dropped, so
    /// no ID shows twice.
    public static func rows(displayed: [ChatRow], incoming: [ChatRow], following: Bool = false) -> [ChatRow]? {
        let displayed = displayed.filter { !$0.item.kind.isSynthetic }
        guard let firstEvent = incoming.firstIndex(where: { $0.item.kind.isEventContent }) else {
            return displayed.contains(where: { $0.item.kind.isEventContent }) ? displayed : nil
        }
        guard !following else { return nil }
        guard let overlap = displayed.firstIndex(where: { $0.id == incoming[firstEvent].id }) else { return nil }
        let tail = incoming[firstEvent...]
        let tailIDs = Set(tail.map(\.id))
        let older = displayed[..<overlap].filter { !tailIDs.contains($0.id) }
        guard older.contains(where: { $0.item.kind.isEventContent }) else { return nil }
        return older + tail
    }
}
