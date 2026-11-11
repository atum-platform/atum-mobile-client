import AtumChat
import AtumNativeAPI
import Foundation
import MatrixRustSDK
import Observation
import UIKit

// One open chat (plan §2.6): the frozen `ConversationStore` protocol on the
// SDK. The decisions live in `AtumChat.ConversationCore` (tested); this
// class mirrors its state for SwiftUI, owns the room's `TimelineController`
// and runs the core's effects. It holds its own `Room`, so a chat no longer
// depends on the roster rows, and it survives the session renewal that
// rebuilds the client every few minutes (`detach` / `attach`).

/// The facts the store needs to open a chat, decided by the app's room
/// classification (§2.7) when the person taps the row.
struct ConversationRoomInfo: Sendable {
    let roomID: String
    let title: String
    let context: RoomContext
    /// Server-authored names for agents and catalog bots (sender labels).
    let knownNames: [String: String]
    /// Catalog bot identities remain explicit even in a group room, where
    /// `RoomContext.agentUserIDs` is intentionally empty.
    let catalogBotUserIDs: Set<String>
    /// The app's copy language (`LiveDesign.locale`): a catalog bot's
    /// two-language notice shows the line in it (§4.2 item 3).
    let languageCode: String
    /// The authoritative encryption fact used by both the SDK mapper and the
    /// final app-bot action projection. Unknown fails closed.
    var roomIsEncrypted: Bool? = nil
    /// `RoomInfo.isMarkedUnread` when the chat opens. Subsequent room-list
    /// publications feed the store through `markedUnreadChanged`.
    var isMarkedUnread = false
    /// The owner's `io.atum.desktop.share_activity` at open (default true):
    /// public receipts and typing, or private receipts and no typing.
    var shareActivity = true
}

/// Builds the room's typing controller (WS3's `TypingController`, B10–B12)
/// on each session's `Room`: a token renewal replaces the client, so the
/// store makes a new one on every attach. Real signals only: the names come
/// from the room's typing listener.
typealias ConversationTypingFactory = @MainActor (Room) -> any TypingControlling

/// Per-room local media identity that survives closing and reopening the
/// screen while SDK local echoes are still converging. It matches on the
/// attachment facts the echo carries; ambiguous same-kind items are never
/// paired by kind alone.
@MainActor
final class ConversationLocalMediaDraft {
    private var pending = [OutgoingChatAttachment]()
    private(set) var filesByDisplayID = [String: URL]()

    func append(_ values: [OutgoingChatAttachment]) { pending.append(contentsOf: values) }

    func removePending(ids: Set<String>) {
        pending.removeAll { ids.contains($0.id) }
    }

    func match(rows: [ChatRow]) -> [String: URL] {
        for row in rows where row.item.isLocalEcho && row.item.media != nil
            && filesByDisplayID[row.id] == nil {
            let candidates = pending.indices.filter { kindMatches(pending[$0], row: row) }
            let exact = candidates.filter { factsMatch(pending[$0], row: row) }
            let index: Int? = if exact.count == 1 {
                exact[0]
            } else if candidates.count == 1 {
                candidates[0]
            } else if !exact.isEmpty {
                // Exact duplicates render the same bytes; deterministic queue
                // order is safe while kind-only ambiguity is not.
                exact[0]
            } else {
                nil
            }
            guard let index else { continue }
            let value = pending.remove(at: index)
            filesByDisplayID[row.id] = URL(fileURLWithPath: value.filePath)
        }
        // A newly rebuilt timeline may publish an empty loading snapshot
        // before cached rows arrive. Do not erase the navigation handoff in
        // that gap; a real non-empty publication performs normal pruning.
        if !rows.isEmpty {
            let live = Set(rows.map(\.id))
            filesByDisplayID = filesByDisplayID.filter { live.contains($0.key) }
        }
        return filesByDisplayID
    }

    private func kindMatches(_ pending: OutgoingChatAttachment, row: ChatRow) -> Bool {
        switch (pending.kind, row.item.kind) {
        case (.image, .image), (.file, .file): true
        default: false
        }
    }

    private func factsMatch(_ pending: OutgoingChatAttachment, row: ChatRow) -> Bool {
        guard let media = row.item.media else { return false }
        var compared = false
        if let filename = media.filename, !filename.isEmpty {
            compared = true
            if filename != pending.filename { return false }
        }
        if let mimetype = media.mimetype, !mimetype.isEmpty {
            compared = true
            if mimetype != pending.mimetype { return false }
        }
        if let byteSize = media.byteSize {
            compared = true
            if byteSize != pending.byteSize { return false }
        }
        return compared
    }
}

@MainActor
@Observable
final class LiveConversationStore: ConversationStore {
    let roomID: String
    let kind: RoomKind
    let title: String
    let ownUserID: String
    let roomIsEncrypted: Bool?
    let mediaComposer: ChatMediaComposerState
    /// The room's agent or bot users; the environment uses it for faces and
    /// the transient-line rule.
    let agentUserIDs: Set<String>
    /// The owner's activity switch (§9.1); changes while the chat is open.
    private(set) var shareActivity: Bool

    // MARK: Published state (mirrors of the core, set only on change)

    private(set) var snapshot = Snapshot.empty
    /// Set only when its state or pill changes (`publishFollow()`).
    private(set) var follow = FollowPolicy()
    private(set) var scrollRequest = ScrollRequest.initial
    private(set) var typingNames = [String]()
    /// B11: people and group rooms show typing here, above the composer.
    private(set) var typingLine = TypingLine.nobody
    private(set) var pagination = PaginationState.idle(hitTimelineStart: false)
    private(set) var actions = ChatActions.none
    /// B20: the row "Sửa" loaded into the composer.
    private(set) var editTarget: String?
    /// Parsed markdown by row ID; `parsedBody(for:)` checks the body.
    private(set) var parsedBodies = [String: ParsedBody]()
    private(set) var localMediaFiles = [String: URL]()
    private(set) var mediaRetryGeneration: UInt64 = 0
    private var draftValue: String
    private var replyTargetValue: String?
    private var bottomVisibleValue = false

    /// The composer's text. Setting it is the person editing (B12: the only
    /// thing that sends a typing notice); the store's own restores go through
    /// `restoreDraft(_:)`.
    var draft: String {
        get { draftValue }
        set {
            guard newValue != draftValue else { return }
            draftValue = newValue
            core.draft = newValue
            mentionPicks.draftChanged(to: newValue)
            mediaComposer.draftDidChange()
            lastDraftEditAt = ProcessInfo.processInfo.systemUptime
            typing?.draftChanged(newValue)
        }
    }

    /// HC-4: a starter chip was picked in the empty assistant chat. Its words
    /// fill the composer (desktop `composer.edit`), the keyboard comes up, and
    /// nothing is sent.
    private(set) var composerFocusRequest: UInt64 = 0

    func pickStarter(_ text: String) {
        draft = text
        composerFocusRequest &+= 1
    }

    // MARK: Mentions

    /// People the composer can mention here: the room's joined members, with
    /// the company roster's names in a company channel. Set by the app once
    /// the members are known; empty until then and in rooms that offer no
    /// mention picker.
    private(set) var mentionCandidates = [MentionCandidate]()
    /// The picks of the draft being typed, and of each message on its way.
    /// A pick lives only while its text is in the draft; a sent message takes
    /// its picks with it (a refused send gives them back), so a name typed by
    /// hand later mentions nobody.
    @ObservationIgnored private var mentionPicks = MentionLedger()

    func setMentionCandidates(_ candidates: [MentionCandidate]) {
        guard candidates != mentionCandidates else { return }
        mentionCandidates = candidates
    }

    /// The suggestions for the `@word` being typed at the end of the draft.
    var mentionSuggestions: [MentionCandidate] {
        guard editTarget == nil, ComposerRules.offersMentions(kind: kind),
              let query = MentionRules.activeQuery(in: draftValue) else { return [] }
        return MentionRules.suggestions(for: query, in: mentionCandidates)
    }

    /// Puts the pick into the draft (an edit by the person) and remembers who
    /// the inserted text stands for.
    func pickMention(_ candidate: MentionCandidate) {
        guard let inserted = MentionRules.insert(candidate, among: mentionCandidates, into: draftValue)
        else { return }
        draft = inserted.draft
        mentionPicks.register(token: inserted.token, userID: candidate.userID)
    }

    /// Text the store puts back (a refused send): not an edit, so no typing
    /// notice goes out for it.
    private func restoreDraft(_ text: String) {
        guard text != draftValue else { return }
        draftValue = text
        core.draft = text
        mentionPicks.draftChanged(to: text)
    }

    /// W4 E3: the open chat shows messages this phone could not open and the
    /// account offers recovery, so the chat's info offers the quiet recovery
    /// row (`RecoveryOffer.inChat`; the app sets `accountOffersRecovery`).
    private(set) var offersRecovery = false
    @ObservationIgnored var accountOffersRecovery = false {
        didSet { if accountOffersRecovery != oldValue { sync() } }
    }

    var replyTarget: String? {
        get { replyTargetValue }
        set {
            core.setReplyTarget(newValue)
            sync()
        }
    }

    var bottomVisible: Bool {
        get { bottomVisibleValue }
        set {
            guard newValue != bottomVisibleValue else { return }
            bottomVisibleValue = newValue
            run(core.setBottomVisible(newValue, now: clock()))
        }
    }

    /// A room-list publication from this same live session. The read policy
    /// owns the in-flight race and schedules a follow-up receipt when the Mac
    /// marks the room unread while this phone is reading at the bottom.
    func markedUnreadChanged(_ marked: Bool) {
        run(core.markedUnreadChanged(marked, now: clock()))
    }

    /// A send refused after the chat closed: the app keeps its text in the
    /// room's draft (B8: never lost).
    @ObservationIgnored var onUnsentAfterClose: (@MainActor (String) -> Void)?
    /// One accepted send, for the app's first-message product event.
    @ObservationIgnored var onMessageSent: (@MainActor () -> Void)?

    // MARK: Private

    @ObservationIgnored private var core: ConversationCore
    @ObservationIgnored private let info: ConversationRoomInfo
    @ObservationIgnored private let makeTyping: ConversationTypingFactory?
    @ObservationIgnored private let localMediaDraft: ConversationLocalMediaDraft
    /// The room's typing controller on the current session; nil while
    /// detached and on a scripted source (its typing comes as outputs).
    @ObservationIgnored private var typing: (any TypingControlling)?
    /// The owner changed Settings › Privacy while this chat was open.
    func setShareActivity(_ sharing: Bool) {
        shareActivity = sharing
        typing?.setShareActivity(sharing)
    }
    /// The person's last edit of the draft (monotonic seconds), for B12's
    /// replay into a new session's typing controller.
    @ObservationIgnored private var lastDraftEditAt: TimeInterval?
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private var controller: TimelineController?
    /// The timeline of a closed chat, kept until the sends tapped before
    /// Back reach the SDK.
    @ObservationIgnored private var closingController: TimelineController?
    /// Display IDs of my phone-sent messages, handed from each timeline to
    /// the next (`DisplayIdentityTable`).
    @ObservationIgnored private var identityAliases = [String: String]()
    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var lastSequence: UInt64 = 0
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var sendTail: Task<Void, Never>?
    @ObservationIgnored private var readWake: Task<Void, Never>?
    @ObservationIgnored private var pageWake: Task<Void, Never>?
    @ObservationIgnored private var noAnswerWake: Task<Void, Never>?
    @ObservationIgnored private var noAnswerDeadline: Date?
    @ObservationIgnored private var rebuildsAfterFailure = 0
    // Probe log (Debug builds only record): the last send tap's ID.
    @ObservationIgnored private var lastTapID: String?
    @ObservationIgnored private var tapRowShown = false
    @ObservationIgnored private var tapTypingShown = false
    @ObservationIgnored private var tapSeenShown = false
    @ObservationIgnored private var publishedFirstSnapshot = false

    /// `history`: `.onScroll` needs a transcript that holds the row being
    /// read when rows are added above (WS2's `TranscriptView`); the interim
    /// host passes `.whileFollowing`. Read and pagination follow WS3's
    /// `ReadPolicy` and `PaginationPolicy`, run by the core.
    init(info: ConversationRoomInfo, draft: String = "", history: HistoryLoading = .onScroll,
         mediaComposer: ChatMediaComposerState = ChatMediaComposerState(),
         localMediaDraft: ConversationLocalMediaDraft = ConversationLocalMediaDraft(),
         makeTyping: ConversationTypingFactory? = nil,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        roomID = info.roomID
        kind = info.context.kind
        title = info.title
        ownUserID = info.context.ownUserID
        roomIsEncrypted = info.roomIsEncrypted
        agentUserIDs = info.context.agentUserIDs
        shareActivity = info.shareActivity
        self.info = info
        self.mediaComposer = mediaComposer
        self.localMediaDraft = localMediaDraft
        self.makeTyping = makeTyping
        self.clock = clock
        draftValue = draft
        localMediaFiles = localMediaDraft.filesByDisplayID
        core = ConversationCore(context: info.context, draft: draft, history: history)
        _ = core.markedUnreadChanged(info.isMarkedUnread, now: clock())
        actions = ChatActions(
            retrySend: { [weak self] id in self?.retrySend(id) },
            deleteSend: { [weak self] id in self?.deleteSend(id) },
            copy: { [weak self] id in self?.copy(id) },
            reply: { [weak self] id in self?.reply(to: id) },
            toggleReaction: { [weak self] id, key in self?.toggleReaction(id, key: key) },
            // Link taps (B17) are the chat screen's: `ChatLinkRouter` puts
            // its `LinkPolicy` gate into the actions the rows read.
            delete: { [weak self] id in self?.delete(id) },
            edit: { [weak self] id in self?.beginEdit(id) },
            report: { [weak self] id, reason in await self?.report(id, reason: reason) ?? false }
        )
        ProbeLog.mark(.chatOpened, id: LiveFlowLog.fingerprint(info.roomID))
    }

    // MARK: Protocol

    func handle(_ input: FollowInput) {
        run(core.handle(input, now: clock()))
        // Follow state and scroll requests change on geometry alone (the
        // pill); the rows do not, so only these two are mirrored here.
        publishFollow()
        if core.scrollRequest != scrollRequest { scrollRequest = core.scrollRequest }
    }

    /// `follow` is republished only when what a view shows from it changes
    /// (the state or the pill), never for the raw distances a geometry update
    /// carries: the transcript sends geometry from inside a layout pass, and a
    /// write there to a value it read laid the screen out again, forever
    /// (`FollowPolicy.needsPublishing(over:)`). Its distances may lag; views
    /// read only its state and pill.
    private func publishFollow() {
        if core.follow.needsPublishing(over: follow) { follow = core.follow }
    }

    /// B6: the draft clears in the same frame; the SDK queues the text.
    func send() {
        if editTarget == nil, let attachments = mediaComposer.takeReadyAttachments(),
           let payload = core.takeMediaCaption() {
            typing?.messageSent()
            sync()
            enqueueAttachments(attachments, caption: payload.caption,
                               replyToEventID: payload.replyToEventID)
            return
        }
        let outgoing = core.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outgoing.isEmpty else { return }
        let isEdit = editTarget != nil
        let effects = core.send(now: clock())
        if !isEdit { mentionPicks.stage(text: outgoing) }
        typing?.messageSent()
        if ProbeLog.isEnabled {
            let tapID = UUID().uuidString
            lastTapID = tapID
            tapRowShown = false
            tapTypingShown = false
            tapSeenShown = false
            ProbeLog.mark(.sendTapped, id: tapID)
        }
        sync()
        run(effects)
    }

    // MARK: Composer and row actions (the protocol's, and `ChatActions`')

    func reply(to itemID: String) {
        core.reply(to: itemID)
        sync()
    }

    func cancelReply() {
        core.cancelReply()
        sync()
    }

    /// B20 "Sửa" (people chats).
    func beginEdit(_ itemID: String) {
        guard core.beginEdit(itemID) else { return }
        sync()
    }

    func cancelEdit() {
        core.cancelEdit()
        sync()
    }

    /// B8 "Thử lại". A recoverable failure shows the clock again until the
    /// source's next state for it (U5, decision 9: `ConversationCore.retry`).
    func retrySend(_ itemID: String) {
        run(core.retry(itemID))
        sync()
    }

    /// B8 "Xóa" on a failed send, or on a held one.
    func deleteSend(_ itemID: String) {
        run(core.abort(itemID))
        sync()
    }

    /// B20 "Xóa" on my message.
    func delete(_ itemID: String) {
        run(core.delete(itemID))
        sync()
    }

    /// B22.
    func toggleReaction(_ itemID: String, key: String) { run(core.toggleReaction(itemID, key: key)) }

    /// A send refused after a previous visit closed, while this one is open.
    func restoreUnsent(_ text: String) {
        restoreDraft(MobileComposerDraftPolicy.draftAfterRefusedSend(currentDraft: draftValue, sentBody: text,
                                                                     sameRoomOpen: true).draft)
    }

    /// B20 "Sao chép": the raw text, as sent.
    func copy(_ itemID: String) {
        guard let body = core.row(itemID)?.item.body, !body.isEmpty else { return }
        UIPasteboard.general.string = body
    }

    // MARK: Report (HC-2)

    /// Every assistant and app bot this chat knows: the room's agent or bot,
    /// the account's agents and the catalog apps' bots (by user ID). Their
    /// messages and they themselves get no Report (`ReportPolicy`).
    var nonPersonSenders: Set<String> {
        agentUserIDs.union(info.knownNames.keys).union(info.catalogBotUserIDs)
    }

    /// "Báo cáo" on someone else's message: `Room.reportContent` with the
    /// event's ID and the person's reason, never its text. The row is checked
    /// again here, so a stale menu never reports my own message or a bot's.
    func report(_ itemID: String, reason: String?) async -> Bool {
        guard let item = core.row(itemID)?.item,
              let request = ReportPolicy.messageRequest(roomID: roomID, item: item, kind: kind,
                                                        nonPersonSenders: nonPersonSenders, reason: reason) else {
            return false
        }
        return await send(request)
    }

    /// Report person, from the panel or a group's Members page: the latest
    /// message they sent here (or, in a person chat with none loaded, the
    /// chat), as `ReportPolicy.personRequest` decides.
    func reportPerson(_ userID: String, reason: String?) async -> Bool {
        guard !nonPersonSenders.contains(userID),
              let request = ReportPolicy.personRequest(roomID: roomID, userID: userID, ownUserID: ownUserID,
                                                       kind: kind, items: core.snapshot.rows.map(\.item),
                                                       reason: reason) else {
            return false
        }
        return await send(request)
    }

    private func send(_ request: ReportPolicy.Request) async -> Bool {
        guard !isClosed, let room, request.roomID == roomID else { return false }
        do {
            switch request.target {
            case let .event(eventID): try await room.reportContent(eventId: eventID, reason: request.reason)
            case .room: try await room.reportRoom(reason: request.reason)
            }
            return true
        } catch {
            return false
        }
    }

    /// HC-6: one older page for the chat's search (desktop
    /// `loadTimelineHistoryPage` + `waitForTimelineProjection`). Waits, a
    /// little, for a page scrolling already has in flight; then loads
    /// `ChatHistorySearch.pageEvents` events and waits until they are rows.
    func loadOlderPageForSearch() async -> ChatHistorySearch.Page {
        for _ in 0..<40 {
            if isClosed || Task.isCancelled { return .failed }
            if core.reachedTimelineStart { return .loaded(hasMore: false) }
            if core.startSearchPage(now: clock()) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let controller, !core.reachedTimelineStart else {
            return core.reachedTimelineStart ? .loaded(hasMore: false) : .failed
        }
        let generation = generation
        let before = snapshot.rows.count
        let hitStart = try? await controller.paginateBackwards(events: ChatHistorySearch.pageEvents)
        guard generation == self.generation, !isClosed else { return .failed }
        run(core.paginationFinished(hitTimelineStart: hitStart, now: clock()))
        sync()
        guard let hitStart else { return .failed }
        // The page's events reach the rows through the projector: wait for
        // them (bounded), so the next match check reads them.
        for _ in 0..<20 where snapshot.rows.count == before {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return .loaded(hasMore: !hitStart)
    }

    /// The parsed markdown for a row, if its body has not changed since.
    func parsedBody(for row: ChatRow) -> AttributedString? {
        guard let parsed = parsedBodies[row.id], parsed.body == row.item.body else { return nil }
        return parsed.attributed
    }

    // MARK: Lifecycle

    /// Opens the room's timeline on the current session. Called on open and
    /// after every session renewal; a previous timeline is closed first.
    func attach(room: Room) async {
        guard !isClosed else { return }
        detach()
        self.room = room
        generation &+= 1
        let generation = generation
        let isEncrypted = await TimelineController.encryption(of: room)
        guard generation == self.generation, !isClosed else { return }
        let mapperRoom = ItemMapperRoom(roomID: roomID, context: info.context, isEncrypted: isEncrypted,
                                        knownNames: info.knownNames,
                                        catalogBotUserIDs: info.catalogBotUserIDs,
                                        languageCode: info.languageCode)
        do {
            let controller = try await TimelineController.make(room: room, mapperRoom: mapperRoom,
                                                               generation: generation, aliases: identityAliases,
                                                               clock: clock)
            guard generation == self.generation, !isClosed else {
                controller.close()
                return
            }
            startTyping(on: room)
            await install(controller, generation: generation)
        } catch {
            guard generation == self.generation, !isClosed else { return }
            attachFailed(outcome: "open_failed")
        }
    }

    /// Opens the chat on any timeline source: the scripted one in Debug UI
    /// tests (`-AtumScripted`), so they run this store, its core and the real
    /// pipeline unchanged. There is no room behind it, so a failed timeline
    /// is not rebuilt.
    func attach(source: any ChatTimelineSource) async {
        guard !isClosed else { return }
        detach()
        room = nil
        generation &+= 1
        let controller = TimelineController(source: source, roomID: roomID, context: info.context,
                                            generation: generation, echoAliases: identityAliases, clock: clock)
        await install(controller, generation: generation)
    }

    private func install(_ controller: TimelineController, generation: UInt64) async {
        guard generation == self.generation, !isClosed else {
            controller.close()
            return
        }
        self.controller = controller
        lastSequence = 0
        controller.onPublication = { [weak self] publication in self?.receive(publication) }
        controller.onPaginationStatus = { [weak self] state in self?.paginationChanged(state) }
        controller.onTypingUserIDs = { [weak self] userIDs in self?.sourceTypingChanged(userIDs) }
        controller.onFailure = { [weak self] in self?.timelineFailed() }
        // Attached before listening, so the first batch (the cache) is
        // handled as attached; sends held meanwhile go out now.
        run(core.attached(now: clock()))
        sync()
        await controller.start()
        guard generation == self.generation, !isClosed else { return }
        if !core.typingNames.isEmpty { await controller.setTyping(core.typingNames) }
    }

    /// The timeline cannot be opened (the room is missing on this session,
    /// or the SDK refused): held sends go back to the composer instead of
    /// waiting for an attach that may never come. The next session tries
    /// again.
    func attachFailed(outcome: String = "open_no_room") {
        LiveFlowLog.timeline(outcome: outcome, roomID: roomID, count: core.pendingSends.count)
        core.attachFailed()
        sync()
        mentionPicks.restoreStaged(in: draftValue)
    }

    /// After a recovery key opened old history: rebuild the timeline so
    /// undecryptable rows are mapped again. (Rule 10 prefers
    /// `Timeline.retryDecryption(sessionIds:)`; a rebuild needs no session
    /// IDs and recovery is rare. Follow-up if it proves slow.)
    func reloadAfterRecovery() async {
        guard let room else { return }
        await attach(room: room)
    }

    /// The session is being replaced: keep the rows on screen, drop the
    /// timeline. Sends tapped meanwhile wait in the core. A new generation
    /// drops an attach still in flight on the session being suspended. The
    /// typing listener goes with the session's room: the dots clear rather
    /// than linger on a signal nobody is listening to (never faked, B10).
    func detach() {
        generation &+= 1
        closeTimeline()
        stopTyping()
        core.detached()
        sync()
    }

    /// The network may be back (sync recovered after being offline) or the
    /// app returned to the foreground: earlier history stops backing off
    /// (`PaginationPolicy.resume`).
    func resumeAfterReconnect() {
        mediaRetryGeneration &+= 1
        run(core.resumePagination(now: clock()))
    }

    /// Leaving the chat (B15, B12): `.fullyRead` if the person reached the
    /// bottom, typing out stops, the timeline is freed (§2.3 rule 8).
    /// Held sends go back into `draft` here, so the app keeps them with the
    /// room's draft. Sends already handed over still reach the SDK: the
    /// timeline is closed only after them (B6: Back works while a message
    /// sends; B8: never lost).
    func close() {
        guard !isClosed else { return }
        let leaving = core.leaving()
        isClosed = true
        sync()
        stopTyping()
        readWake?.cancel()
        pageWake?.cancel()
        noAnswerWake?.cancel()
        let controller = controller
        self.controller = nil
        guard let controller else { return }
        closingController = controller
        let pendingSends = sendTail
        Task { @MainActor [self] in
            await pendingSends?.value
            for case let .markFullyRead(eventID) in leaving {
                try? await controller.sendReceipt(.fullyRead(eventID: eventID))
            }
            controller.close()
            if closingController === controller { closingController = nil }
        }
    }

    // MARK: Timeline callbacks

    private func receive(_ publication: TimelinePublication) {
        let projected = publication.projected
        guard projected.snapshot.generation == generation, projected.sequence > lastSequence else { return }
        lastSequence = projected.sequence
        identityAliases = publication.echoAliases
        rebuildsAfterFailure = 0
        if parsedBodies.mapValues(\.body) != publication.parsedBodies.mapValues(\.body) {
            parsedBodies = publication.parsedBodies
        }
        let effects = core.receive(projected, now: clock())
        matchLocalMedia(in: projected.snapshot.rows)
        sync()
        run(effects)
        scheduleNoAnswer(projected.nextNoAnswerChange)
        markProbes(projected.snapshot)
    }

    private func paginationChanged(_ state: PaginationState) {
        run(core.paginationChanged(state, now: clock()))
        sync()
    }

    // MARK: Typing (B10–B12)

    /// One typing controller per session's room.
    private func startTyping(on room: Room) {
        stopTyping()
        guard let makeTyping else { return }
        let controller = makeTyping(room)
        controller.setShareActivity(shareActivity)
        controller.onTypingNamesChange = { [weak self] names in self?.typingChanged(names) }
        typing = controller
        if !controller.typingNames.isEmpty { typingChanged(controller.typingNames) }
        // B12: a new session's controller hears the draft only while the
        // person is still typing it; an untouched saved draft sends nothing.
        if DraftTypingReplay.replays(draft: draftValue, lastEditAt: lastDraftEditAt,
                                     now: ProcessInfo.processInfo.systemUptime) {
            controller.draftChanged(draftValue)
        }
    }

    /// Typing out stops and the listener goes; the dots clear.
    private func stopTyping() {
        guard let typing else { return }
        self.typing = nil
        typing.onTypingNamesChange = nil
        typing.close()
        if !typingNames.isEmpty { typingChanged([]) }
    }

    /// Whoever is typing (display names, my own user dropped). §2.7: agents
    /// and bots get the dots as the last row; people and groups get the line
    /// above the composer and no row (`TypingNames.presentation`).
    private func typingChanged(_ names: [String]) {
        let presentation = TypingNames.presentation(kind: kind, names: names)
        if names != typingNames { typingNames = names }
        if presentation.line != typingLine { typingLine = presentation.line }
        core.typingChanged(presentation.rowNames)
        sync()
        if ProbeLog.isEnabled, !names.isEmpty, let tapID = lastTapID, !tapTypingShown {
            tapTypingShown = true
            ProbeLog.mark(.typingShown, id: tapID)
        }
        guard let controller else { return }
        let rowNames = presentation.rowNames
        Task { await controller.setTyping(rowNames) }
    }

    /// Typing user IDs from a scripted source (the live source never sends
    /// them), named with the chat's own rule.
    private func sourceTypingChanged(_ userIDs: [String]) {
        let knownNames = info.knownNames
        typingChanged(TypingNames.displayNames(userIDs, ownUserID: info.context.ownUserID, kind: kind,
                                               roomTitle: title, name: { knownNames[$0] }))
    }

    /// An out-of-order batch: rebuild the timeline, at most twice in a row.
    private func timelineFailed() {
        LiveFlowLog.timeline(outcome: "rebuild_after_failure", roomID: roomID, count: rebuildsAfterFailure)
        guard rebuildsAfterFailure < 2, let room else { return }
        rebuildsAfterFailure += 1
        detach()
        Task { await attach(room: room) }
    }

    // MARK: Effects

    private func run(_ effects: [ConversationEffect]) {
        for effect in effects { perform(effect) }
        if !effects.isEmpty { sync() }
    }

    private func perform(_ effect: ConversationEffect) {
        switch effect {
        case let .send(text, replyToEventID):
            enqueueSend(text: text, replyToEventID: replyToEventID)
        case let .edit(ref, text):
            act("edit") { try await $0.edit(ref, text: text) }
        case let .redact(ref):
            act("redact") { try await $0.redact(ref) }
        case let .toggleReaction(ref, key):
            act("reaction") { try await $0.toggleReaction(ref, key: key) }
        case let .repair(repair):
            act("retry") { try await $0.repair(repair) }
        case let .abortSend(ref):
            act("abort") { try await $0.abort(ref) }
        case let .paginateBackwards(events):
            guard let controller else {
                run(core.paginationFinished(hitTimelineStart: nil, now: clock()))
                return
            }
            let generation = generation
            Task { [weak self] in
                let hitStart = try? await controller.paginateBackwards(events: events)
                guard let self, generation == self.generation else { return }
                self.run(self.core.paginationFinished(hitTimelineStart: hitStart, now: self.clock()))
                self.sync()
            }
        case let .wakePagination(at):
            pageWake?.cancel()
            pageWake = Task { [weak self, clock] in
                try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSince(clock()))))
                guard !Task.isCancelled, let self else { return }
                self.run(self.core.paginationWakeDue(now: self.clock()))
            }
        case .markReadPrivate:
            receipt()
        case let .markFullyRead(eventID):
            act("fully_read") { try await $0.sendReceipt(.fullyRead(eventID: eventID)) }
        case let .wakeReadGate(at):
            readWake?.cancel()
            readWake = Task { [weak self, clock] in
                let delay = max(0, at.timeIntervalSince(clock()))
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.run(self.core.readWakeDue(now: self.clock()))
            }
        case let .fetchReplyDetails(eventID):
            guard let controller else { return }
            Task { await controller.fetchReplyDetails(eventID: eventID) }
        }
    }

    /// Sends run one after another in tap order; each only hands the text to
    /// the SDK's persistent per-room queue. The tail holds the store until
    /// it is done, so Back never cancels a send. A send whose timeline went
    /// away (a session renewal) is held again in the core and goes out on
    /// the next timeline; one the SDK refused puts its text back in the
    /// composer (the hotfix rule), or in the room's draft after Back.
    private func enqueueSend(text: String, replyToEventID: String?) {
        let mentions = mentionPicks.mentions(for: text)
        let previous = sendTail
        let roomID = roomID
        let roomKind = info.context.kind.rawValue
        sendTail = Task { @MainActor [self] in
            await previous?.value
            guard let controller = controller ?? closingController else {
                sendLostTimeline(text, replyToEventID: replyToEventID, roomKind: roomKind)
                return
            }
            do {
                try await controller.send(text: text, replyToEventID: replyToEventID, mentions: mentions)
                mentionPicks.delivered(text: text)
                onMessageSent?()
                LiveFlowLog.send(outcome: replyToEventID == nil ? "queued" : "queued_reply", roomKind: roomKind,
                                 roomID: roomID)
            } catch {
                if !isClosed, self.controller !== controller {
                    sendLostTimeline(text, replyToEventID: replyToEventID, roomKind: roomKind)
                } else {
                    sendRefused(text, roomKind: roomKind)
                }
            }
        }
    }

    private func enqueueAttachments(_ attachments: [OutgoingChatAttachment],
                                    caption: String?, replyToEventID: String?) {
        localMediaDraft.append(attachments)
        let previous = sendTail
        let roomID = roomID
        let roomKind = info.context.kind.rawValue
        sendTail = Task { @MainActor [self] in
            await previous?.value
            guard let controller = controller ?? closingController else {
                restoreAttachments(attachments, caption: caption,
                                   replyToEventID: replyToEventID, outcome: "media_no_timeline")
                return
            }
            for (index, attachment) in attachments.enumerated() {
                do {
                    try await controller.send(attachment: attachment,
                                              caption: index == 0 ? caption : nil,
                                              replyToEventID: index == 0 ? replyToEventID : nil)
                } catch {
                    let remainingIDs = Set(attachments[index...].map(\.id))
                    localMediaDraft.removePending(ids: remainingIDs)
                    restoreAttachments(Array(attachments[index...]),
                                       caption: index == 0 ? caption : nil,
                                       replyToEventID: index == 0 ? replyToEventID : nil,
                                       outcome: "media_refused")
                    return
                }
            }
            onMessageSent?()
            LiveFlowLog.send(outcome: "media_queued", roomKind: roomKind,
                             roomID: roomID)
        }
    }

    private func matchLocalMedia(in rows: [ChatRow]) {
        let next = localMediaDraft.match(rows: rows)
        if next != localMediaFiles { localMediaFiles = next }
    }

    private func restoreAttachments(_ attachments: [OutgoingChatAttachment],
                                    caption: String?, replyToEventID: String?, outcome: String) {
        localMediaDraft.removePending(ids: Set(attachments.map(\.id)))
        mediaComposer.restore(attachments)
        if let caption, !caption.isEmpty {
            let restored = MobileComposerDraftPolicy.draftAfterRefusedSend(
                currentDraft: draftValue, sentBody: caption, sameRoomOpen: true
            ).draft
            restoreDraft(restored)
        }
        if replyTargetValue == nil, let replyToEventID { core.setReplyTarget(replyToEventID) }
        LiveFlowLog.send(outcome: outcome, roomKind: info.context.kind.rawValue,
                         roomID: roomID)
        sync()
    }

    private func sendLostTimeline(_ text: String, replyToEventID: String?, roomKind: String) {
        guard !isClosed else {
            sendRefused(text, roomKind: roomKind)
            return
        }
        LiveFlowLog.send(outcome: "held_after_renewal", roomKind: roomKind, roomID: roomID)
        run(core.requeue(text: text, replyToEventID: replyToEventID, now: clock()))
        sync()
    }

    private func sendRefused(_ text: String, roomKind: String) {
        guard !isClosed else {
            LiveFlowLog.send(outcome: "refused_kept_in_draft", roomKind: roomKind, roomID: roomID)
            onUnsentAfterClose?(text)
            return
        }
        let outcome = MobileComposerDraftPolicy.draftAfterRefusedSend(currentDraft: draftValue, sentBody: text,
                                                                     sameRoomOpen: true)
        LiveFlowLog.send(outcome: "refused_restored", roomKind: roomKind, roomID: roomID)
        core.sendRefused(text: text)
        restoreDraft(outcome.draft)
        mentionPicks.refused(text: text, draft: draftValue)
        sync()
    }

    /// B13: the owner's receipt (public by default, private when sharing is
    /// off); `ReadPolicy` hears how it went (a failure is retried after 1 s,
    /// 4 s and 15 s).
    private func receipt() {
        guard let controller else {
            run(core.receiptFinished(succeeded: false, now: clock()))
            return
        }
        let roomID = roomID
        let roomKind = info.context.kind.rawValue
        let receipt = ShareActivityPreference.receipt(sharing: shareActivity)
        Task { @MainActor [weak self] in
            var succeeded = true
            do {
                try await controller.sendReceipt(receipt)
            } catch {
                succeeded = false
                LiveFlowLog.send(outcome: "read_failed", roomKind: roomKind, roomID: roomID)
            }
            // Always reported, also after a renewal replaced the timeline:
            // the policy holds one request in flight until it hears back.
            guard let self else { return }
            self.run(self.core.receiptFinished(succeeded: succeeded, now: self.clock()))
        }
    }

    /// One SDK call on the attached timeline; failures are logged by class.
    private func act(_ name: String, onFailure: (@MainActor () -> Void)? = nil,
                     _ call: @escaping @MainActor (TimelineController) async throws -> Void) {
        guard let controller else {
            LiveFlowLog.send(outcome: name + "_no_timeline", roomKind: info.context.kind.rawValue, roomID: roomID)
            onFailure?()
            return
        }
        let roomID = roomID
        let roomKind = info.context.kind.rawValue
        Task { @MainActor in
            do {
                try await call(controller)
            } catch {
                LiveFlowLog.send(outcome: name + "_failed", roomKind: roomKind, roomID: roomID)
                onFailure?()
            }
        }
    }

    private func scheduleNoAnswer(_ deadline: Date?) {
        guard deadline != noAnswerDeadline else { return }
        noAnswerDeadline = deadline
        noAnswerWake?.cancel()
        guard let deadline, let controller else { return }
        noAnswerWake = Task { [weak self, clock] in
            try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSince(clock()))))
            guard !Task.isCancelled, self != nil else { return }
            await controller.tick()
        }
    }

    private func closeTimeline() {
        controller?.close()
        controller = nil
        readWake?.cancel()
        pageWake?.cancel()
        noAnswerWake?.cancel()
        noAnswerDeadline = nil
    }

    // MARK: Mirrors

    /// Copies the core's state into the observed properties that changed, so
    /// a keystroke never re-renders the transcript.
    /// The core composes the rows: the projection, the renewal handover's
    /// older rows (`SessionHandover`) and held sends.
    private func sync() {
        let next = core.snapshot
        if next != snapshot { snapshot = next }
        publishFollow()
        if core.scrollRequest != scrollRequest { scrollRequest = core.scrollRequest }
        if core.pagination != pagination { pagination = core.pagination }
        if core.editTarget != editTarget { editTarget = core.editTarget }
        if core.replyTarget != replyTargetValue { replyTargetValue = core.replyTarget }
        if core.draft != draftValue {
            draftValue = core.draft
            mentionPicks.draftChanged(to: core.draft)
        }
        if core.bottomVisible != bottomVisibleValue { bottomVisibleValue = core.bottomVisible }
        let offers = RecoveryOffer.inChat(kind: kind, rows: next.rows, accountOffersRecovery: accountOffersRecovery)
        if offers != offersRecovery { offersRecovery = offers }
    }

    private func markProbes(_ snapshot: Snapshot) {
        guard ProbeLog.isEnabled else { return }
        if !publishedFirstSnapshot {
            publishedFirstSnapshot = true
            ProbeLog.mark(.firstSnapshot, id: LiveFlowLog.fingerprint(roomID))
        }
        guard let tapID = lastTapID else { return }
        if !tapRowShown {
            switch snapshot.change {
            case .appendedAtEnd(_, true), .mixed(_, true):
                tapRowShown = true
                ProbeLog.mark(.sendRowShown, id: tapID)
            default:
                break
            }
        }
        if !tapSeenShown, snapshot.rows.contains(where: { if case .seen = $0.delivery { true } else { false } }) {
            tapSeenShown = true
            ProbeLog.mark(.seenShown, id: tapID)
        }
    }
}
