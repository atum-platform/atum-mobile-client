import AtumChat
import Observation
import SwiftUI
import UIKit

/// The transcript: the one scroll-aware view (plan §2.4, "The seam"). Stores,
/// policies and row views are the same under any scrolling technology; Plan B
/// would replace only this file.
///
/// Pure SwiftUI: a stack in a scroll view, opened at the bottom
/// (`defaultScrollAnchor(.bottom, for: .initialOffset)`), driven by the
/// store's `FollowPolicy`. The view reports geometry and scroll phase
/// (`ConversationStore.handle`), sets `bottomVisible` (B13) and applies the
/// store's scroll commands. While I read, the row being read is held where
/// it is whenever rows above it change height (older pages, the loading
/// row, a quote's details, reactions, Dynamic Type): every row reports its
/// top, and the view moves by exactly as much as that row moved
/// (`holdAnchor`). While I drag or fling a detached chat, the rows on screen
/// do not change at all (`heldRows`, §2.4 "hold incoming diffs while the
/// user drags"): a scroll view in motion does not reliably take a
/// correction, so whatever arrived lands once the scroll stops, and is held
/// then. It never diffs rows itself.
struct TranscriptView: View {
    let store: LiveConversationStore
    /// What the screen around the transcript shows (the pill), published only
    /// when it changes.
    let chrome: ChatChrome
    /// Something covers the chat (the in-app Safari page, an alert or a
    /// dialog over it): the bottom does not count as visible, so no receipt
    /// goes out (B13).
    var covered = false
    /// HC-6: the open search's highlights and the match to bring into view.
    var search: ChatSearchSession? = nil

    @Environment(\.chatTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var position = ScrollPosition(edge: .bottom)
    /// The follow state, mirrored from the store only when it changes, so the
    /// body does not depend on the store's per-frame geometry (its
    /// `FollowPolicy` records every scroll distance).
    @State private var followState = FollowState.following
    /// The rows on screen while I drag or fling a detached chat: the store's
    /// rows as they were when the motion began (nil otherwise).
    @State private var heldRows: [ChatRow]?
    /// Per-frame bookkeeping the body never reads (not observed).
    @State private var scratch = TranscriptScratch()
    @State private var tuning = TranscriptTuning.current

    var body: some View {
        let rows = heldRows ?? store.snapshot.rows
        // The scroll view is made when the first rows arrive, so its initial
        // offset is the bottom of real content (B1). Made earlier, it would
        // lay out empty, show the top of the first batch for a frame, and ask
        // for older history it does not need.
        if rows.isEmpty {
            Color.clear
                .accessibilityElement()
                .accessibilityIdentifier(AccessibilityID.transcript)
                .accessibilityValue(AccessibilityID.transcriptValue(followState))
        } else {
            transcript(rows)
        }
    }

    @ViewBuilder private func transcript(_ rows: [ChatRow]) -> some View {
        let following = followState == .following
        // The newest answer in an assistant or app chat carries its actions
        // (FlowPhone › Chat); people chats and groups have none.
        let latestAnswerID = store.kind == .assistant || store.kind == .appBot
            ? rows.last { $0.item.kind == .message && !$0.item.isOwn }?.id : nil
        // Messages the agent may still be writing never fold (`MessageFold`).
        let growing = MessageFold.growingIDs(in: rows)
        ScrollView {
            // An eager stack: every loaded row is laid out. A lazy stack
            // estimates rows it has not laid out, and with rows as different
            // as one-liners and 40-line code blocks its estimates flip-flopped
            // between two content heights forever after a fling, hanging the
            // main thread (G-scroll record).
            VStack(spacing: 0) {
                ForEach(rows) { row in
                    ChatRowView(row: row, kind: store.kind, roomTitle: store.title,
                                parsedBody: store.parsedBody(for: row), isLatestAnswer: row.id == latestAnswerID,
                                searchHighlight: search?.highlights[row.id], isGrowing: growing.contains(row.id))
                        .equatable()
                        // Each row's top in the content (it changes only when
                        // something above it changes height, never on scroll).
                        .onGeometryChange(for: Double.self) { proxy in
                            TranscriptGeometry.half(proxy.frame(in: .named(Self.contentSpace)).minY)
                        } action: { minY in
                            rowMoved(row.id, minY: minY)
                        }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, ChatLayout.sideMargin)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .coordinateSpace(.named(Self.contentSpace))
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(sizeChangeAnchor(following: following), for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        // Telegram and Messages: a tap anywhere on the transcript, or a drag
        // towards older messages, puts the keyboard away. Both recognizers
        // run beside every other touch (links, media, quotes, Show more, the
        // long-press menu) and cancel none; the draft stays in the composer.
        .gesture(TranscriptKeyboardDismissal.Tap())
        .gesture(TranscriptKeyboardDismissal.Pan())
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .onScrollPhaseChange { _, phase in
            scratch.motion = ScrollMotion(phase)
            if scratch.motion == .user {
                scratch.pendingHold = nil
                stopSearchPlacement()
            }
            updateHeldRows()
        }
        .onScrollGeometryChange(for: TranscriptGeometry.self) { TranscriptGeometry($0) } action: { old, new in
            geometryChanged(from: old, to: new)
        }
        .onChange(of: search?.focus) { _, focus in
            guard let focus else {
                stopSearchPlacement()
                // Find released its anchor: normal holds/following learn
                // the settled position even if no further geometry arrives.
                scheduleSettle(after: Self.settleSeconds)
                return
            }
            showSearchMatch(focus.rowID)
        }
        .onChange(of: store.scrollRequest) { _, request in
            apply(request.command)
            syncFollowState()
        }
        .onChange(of: store.snapshot) { old, new in
            snapshotChanged(from: old, to: new)
            syncFollowState()
        }
        .onChange(of: rows.map(\.id)) { old, new in
            rowsShown(from: old, to: new)
        }
        .onChange(of: growing) { _, new in
            scratch.growing = new
            noteReading()
        }
        .onChange(of: dynamicTypeSize) { _, _ in
            // Every row changes height at once. While following, the bottom
            // stays pinned on its own; while I read, the row being read keeps
            // its place (`holdAnchor`, G-scroll check 6), and the passes in
            // between are not my position: one clamped at the bottom would
            // re-attach the chat.
            guard !store.follow.isFollowing else { return }
            scratch.quietUntil = Date().addingTimeInterval(1)
            scheduleSettle(after: 1.05)
        }
        .onChange(of: scenePhase) { _, _ in updateBottomVisible() }
        .onChange(of: covered) { _, _ in updateBottomVisible() }
        .onAppear {
            scratch.growing = growing
            scratch.rowOrder = rows.map(\.id)
            scratch.isOnScreen = true
            updateBottomVisible()
            store.handle(.opened)
            syncFollowState()
            markMemory("chat.open")
        }
        .onDisappear {
            stopSearchPlacement()
            scratch.isOnScreen = false
            updateBottomVisible()
            noteReading()
        }
        .environment(\.chatRowInteractions.showOriginal, { id in showOriginal(id) })
        .environment(\.chatRowInteractions.opening, { id in rowOpening(id) })
        .environment(\.chatRowInteractions.folded, { id in rowFolded(id) })
        .accessibilityIdentifier(AccessibilityID.transcript)
        .accessibilityValue(AccessibilityID.transcriptValue(followState))
    }

    // MARK: Following (§2.4, §2.5)

    /// Mechanism (a) switches the size-change anchor with the follow state;
    /// mechanism (b) sets none and relies on the store's unanimated
    /// scroll-to-bottom on every change while following (G-scroll check 9
    /// picks one; `docs/decisions/2026-10-11-g-scroll.md`).
    private func sizeChangeAnchor(following: Bool) -> UnitPoint? {
        switch tuning.mechanism {
        case .switchingAnchor: following ? .bottom : .top
        case .scrollCommands: nil
        }
    }

    private func geometryChanged(from old: TranscriptGeometry, to new: TranscriptGeometry) {
        scratch.geometry = new
        defer { noteReading() }
        let contentChanged = abs(new.contentHeight - old.contentHeight) > 0.5
        #if DEBUG
        scratch.holdProbe?.observe(new, contentChanged: contentChanged)
        scratch.holdProbe?.inset(new.insetTop)
        #endif
        if scratch.placingSearchMatch {
            // The first layout can still be at the bottom after search has
            // detached it. Feeding that transient pass to FollowPolicy would
            // reattach and pin the transcript before the match is placed.
            if contentChanged || new.viewportHeight != old.viewportHeight || new.insetTop != old.insetTop {
                scratch.searchAttempts = 0
            }
            scheduleSearchPlacement()
            updateBottomVisible()
            return
        }
        if retryPendingHold() { return }
        // Rows change only while the scroll is still (`heldRows`), so where
        // the row being read sat when it was chosen is where it goes back to.
        if holdAnchor() { return }
        if let quiet = scratch.quietUntil {
            if Date() < quiet { return }
            scratch.quietUntil = nil
        }
        if !contentChanged { chooseAnchor(new) }
        if contentChanged, !store.follow.isFollowing {
            // Content changed while I read: rows above are held by their
            // tops (here, or as their new tops arrive), growth below moves
            // nothing. This pass is not where I scrolled to, so the follow
            // state sees the settled position instead.
            updateBottomVisible()
            scheduleSettle(after: Self.settleSeconds)
            return
        }
        store.handle(.geometry(distanceFromBottom: new.distanceFromBottom, distanceFromTop: new.distanceFromTop,
                               viewportHeight: new.viewportHeight, motion: scratch.motion))
        syncFollowState()
        updateBottomVisible()
    }

    // MARK: Holding the row being read (§2.4 "Prepend", B4, B5)

    /// The topmost row whose top is in view (a row taller than the view
    /// counts when no row starts in it): the row being read. Chosen only
    /// from passes where nothing changed size, when every row's top is
    /// current.
    private func chooseAnchor(_ geometry: TranscriptGeometry) {
        let top = geometry.offsetY + geometry.insetTop
        let bottom = top + geometry.viewportHeight
        var covering: (id: String, minY: Double)?
        var chosen: (id: String, minY: Double)?
        for id in scratch.rowOrder {
            guard let minY = scratch.rowMinY[id] else { continue }
            if minY >= top - 0.5 {
                chosen = minY < bottom ? (id, minY) : (covering ?? (id, minY))
                break
            }
            covering = (id, minY)
        }
        guard let anchor = chosen ?? covering else { return }
        scratch.anchor = TranscriptAnchor(id: anchor.id, minY: anchor.minY, viewportY: anchor.minY - top)
    }

    /// A row's top moved in the content: something above it changed height.
    private func rowMoved(_ id: String, minY: Double) {
        scratch.rowMinY[id] = minY
        if id == scratch.searchRowID {
            scratch.searchAttempts = 0
            recordSearchPlacement("row", minY: minY)
            scheduleSearchPlacement()
        }
        if id == scratch.anchor?.id { holdAnchor() }
    }

    /// While I read, puts the row being read back where it was on screen
    /// after rows above it changed height. Absolute, from where the row sat
    /// below the visible top, so it does not matter whether the rows' new
    /// tops or the scroll geometry arrive first, or whether the offset was
    /// clamped.
    @discardableResult
    private func holdAnchor() -> Bool {
        guard !store.follow.isFollowing, !scratch.placingSearchMatch, var anchor = scratch.anchor,
              let minY = scratch.rowMinY[anchor.id], abs(minY - anchor.minY) > 0.5 else { return false }
        let geometry = scratch.geometry
        let target = minY - geometry.insetTop - anchor.viewportY
        #if DEBUG
        scratch.holdProbe?.held(anchor.id, from: geometry.offsetY, to: target, moving: scratch.motion != .idle)
        #endif
        anchor.minY = minY
        scratch.anchor = anchor
        scratch.pendingHold = (target: target, attempts: 0)
        // `scrollTo(y:)` takes the point at the top of the visible area,
        // below the navigation bar; the offset includes the bar's inset.
        position.scrollTo(y: target + geometry.insetTop)
        scheduleSettle(after: Self.settleSeconds)
        return true
    }

    /// Once the rows stop changing, the row being read is chosen again from
    /// where things now are (a change can bring rows above it into view
    /// without the scroll moving again), and the follow state learns the
    /// settled position.
    private func scheduleSettle(after delay: TimeInterval) {
        scratch.settleGeneration &+= 1
        let generation = scratch.settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard generation == scratch.settleGeneration else { return }
            settle()
        }
    }

    private func settle() {
        guard !scratch.placingSearchMatch else { return }
        if retryPendingHold() { return }
        if let quiet = scratch.quietUntil, Date() < quiet {
            return scheduleSettle(after: quiet.timeIntervalSinceNow + 0.05)
        }
        scratch.quietUntil = nil
        let geometry = scratch.geometry
        chooseAnchor(geometry)
        store.handle(.geometry(distanceFromBottom: geometry.distanceFromBottom, distanceFromTop: geometry.distanceFromTop,
                               viewportHeight: geometry.viewportHeight, motion: scratch.motion))
        syncFollowState()
        updateBottomVisible()
    }

    static let settleSeconds: TimeInterval = 0.3

    /// A size-change scroll command can be ignored while SwiftUI is still
    /// relaying out the transcript. Retry the same absolute hold briefly;
    /// user motion clears it in `onScrollPhaseChange`, so this never fights a
    /// person's drag or fling.
    private func retryPendingHold() -> Bool {
        guard var pending = scratch.pendingHold else { return false }
        let geometry = scratch.geometry
        if abs(geometry.offsetY - pending.target) <= 0.5 {
            scratch.pendingHold = nil
            return false
        }
        guard pending.attempts < 8 else {
            scratch.pendingHold = nil
            return false
        }
        pending.attempts += 1
        scratch.pendingHold = pending
        position.scrollTo(y: pending.target + geometry.insetTop)
        scheduleSettle(after: 0.1)
        return true
    }

    /// Mirrors what views show from the store's `FollowPolicy` only when it
    /// changes. The policy records every scroll distance; a view that read it
    /// directly re-rendered on every geometry update, and the pill's re-render
    /// moved the bottom bar by a fraction of a point, which fed the next
    /// geometry update: an endless layout loop (G-scroll record).
    private func syncFollowState() {
        let state = store.follow.state
        if state != followState {
            followState = state
            updateHeldRows()
        }
        let pill = store.follow.pill
        if pill != chrome.pill { chrome.pill = pill }
        noteReading()
    }

    private func apply(_ command: FollowCommand) {
        switch command {
        case .none:
            break
        case let .scrollToBottom(animated):
            if scratch.placingSearchMatch {
                // A queued command from before detaching must not win over
                // search. An explicit jump reattaches the store and cancels
                // placement, so the person's newer action still wins.
                guard store.follow.isFollowing else { return }
                stopSearchPlacement()
            }
            if animated {
                withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) }
            } else {
                position.scrollTo(edge: .bottom)
            }
        }
    }

    /// §2.4: while I drag or fling a detached chat, nothing on screen
    /// changes; the rows that arrived meanwhile land when the scroll stops.
    private func updateHeldRows() {
        let holds = scratch.motion == .user && !store.follow.isFollowing
        if holds, heldRows == nil {
            heldRows = store.snapshot.rows
        } else if !holds, heldRows != nil {
            heldRows = nil
        }
    }

    private func snapshotChanged(from old: Snapshot, to new: Snapshot) {
        if store.pagination == .idle(hitTimelineStart: true),
           new.rows.contains(where: { $0.item.kind == .timelineStart }),
           !old.rows.contains(where: { $0.item.kind == .timelineStart }) {
            markMemory("timeline.start")
        }
        announceIncoming(in: new)
    }

    /// The rows on screen changed. If the row being read was removed
    /// (redacted, or hidden by a newer one), the next row below it that stays
    /// takes its place, from its top before the change. Tops of rows that
    /// are gone are forgotten.
    private func rowsShown(from old: [String], to new: [String]) {
        scratch.rowOrder = new
        let ids = Set(new)
        if let rowID = scratch.searchRowID, !ids.contains(rowID) {
            stopSearchPlacement()
            scheduleSettle(after: Self.settleSeconds)
        }
        if let anchor = scratch.anchor, !ids.contains(anchor.id),
           let index = old.firstIndex(of: anchor.id) {
            scratch.anchor = old[(index + 1)...].lazy
                .compactMap { id -> TranscriptAnchor? in
                    guard ids.contains(id), let minY = scratch.rowMinY[id] else { return nil }
                    return TranscriptAnchor(id: id, minY: minY, viewportY: anchor.viewportY + (minY - anchor.minY))
                }
                .first
        }
        if scratch.rowMinY.count > ids.count { scratch.rowMinY = scratch.rowMinY.filter { ids.contains($0.key) } }
    }

    // MARK: B13: the bottom is visible

    private func updateBottomVisible() {
        let geometry = scratch.geometry
        let visible = scratch.isOnScreen && scenePhase == .active && !covered
            && geometry.viewportHeight > 0 && geometry.distanceFromBottom <= FollowPolicy.nearBottomPoints
        if store.bottomVisible != visible { store.bottomVisible = visible }
    }

    // MARK: B21: tapping a quote

    private func showOriginal(_ eventID: String) {
        guard let row = store.snapshot.rows.first(where: { $0.item.eventID == eventID }) else { return }
        withAnimation(.smooth(duration: 0.35)) { position.scrollTo(id: row.id, anchor: .center) }
    }

    /// Show more keeps the message where it is on screen (owner,
    /// 2026-11-12; Slack and Telegram expand in place): its top, its first
    /// lines and the toggle stay put and the revealed text extends below.
    /// The reader is reading now, so the chat stops following the bottom
    /// (the jump pill shows as for any detached chat), which turns the
    /// size-change anchor to the top before the row grows, and the toggled
    /// row becomes the row being read. The current offset is also held as an
    /// absolute target, should a pass pinned to the bottom land first.
    private func rowOpening(_ rowID: String) {
        let geometry = scratch.geometry
        guard scratch.isOnScreen, geometry.viewportHeight > 0 else { return }
        if store.follow.isFollowing {
            store.handle(.geometry(distanceFromBottom: max(geometry.distanceFromBottom, FollowPolicy.nearBottomPoints + 1),
                                   distanceFromTop: geometry.distanceFromTop,
                                   viewportHeight: geometry.viewportHeight, motion: .user))
            syncFollowState()
        }
        if let minY = scratch.rowMinY[rowID] {
            let top = geometry.offsetY + geometry.insetTop
            scratch.anchor = TranscriptAnchor(id: rowID, minY: minY, viewportY: minY - top)
        }
        scratch.pendingHold = (target: geometry.offsetY, attempts: 0)
        scheduleSettle(after: Self.settleSeconds)
    }

    /// Show less on a long message whose top has scrolled out of view: the
    /// fold would leave the reader below it, so its top comes back into view
    /// (Telegram does the same). While following, the bottom stays pinned and
    /// the folded message is already in view.
    private func rowFolded(_ rowID: String) {
        guard !store.follow.isFollowing, let minY = scratch.rowMinY[rowID],
              minY < scratch.geometry.distanceFromTop else { return }
        scratch.anchor = nil
        scratch.pendingHold = nil
        withAnimation(.smooth(duration: 0.3)) { position.scrollTo(id: rowID, anchor: .top) }
    }

    /// A long message folds once it is final (owner, 2026-11-12), unless
    /// I am reading its text below the fold line in a chat scrolled away
    /// from the bottom: then it stays open (`MessageFoldBook.readerSees`).
    /// Told on every pass for the messages still growing, so what is on
    /// screen when one turns final decides. While following, the bottom
    /// stays pinned as it folds; otherwise the row being read is above it
    /// or is held (`holdAnchor`). The fold line is put at 12 body lines
    /// below the row's top (its quote and padding put the real one lower),
    /// so a line that may be on screen counts as being read. Reads only
    /// the scratch; the book is not observed, so nothing re-renders.
    private func noteReading() {
        let growing = scratch.growing
        guard !growing.isEmpty else { return }
        var reading = Set<String>()
        if scratch.isOnScreen, !store.follow.isFollowing {
            let geometry = scratch.geometry
            let top = geometry.offsetY + geometry.insetTop
            let bottom = top + geometry.viewportHeight
            let foldLine = Double(MessageFoldMeasure.lineHeight(dynamicTypeSize)) * Double(MessageFold.foldedLines)
            let order = scratch.rowOrder
            for id in growing {
                guard let minY = scratch.rowMinY[id] else { continue }
                var end = geometry.contentHeight
                if let index = order.lastIndex(of: id), index + 1 < order.count,
                   let next = scratch.rowMinY[order[index + 1]] {
                    end = next
                }
                if max(minY + foldLine, top) < min(end, bottom) { reading.insert(id) }
            }
        }
        MessageFoldStore.session.readerSees(reading, among: growing)
    }

    // MARK: HC-6: bringing a search match into view

    /// The person asked for this match, so the chat leaves the bottom first
    /// (the follow rule would otherwise pin it back). One scroll is not
    /// enough: a walk's rows have only just landed, and they still change
    /// height (layout, parsed markdown), so the row is placed from its
    /// measured top. Keep that row as the anchor after the first successful
    /// placement too: a page's remaining layout can arrive afterwards. A
    /// drag, jump, new query or closing search ends it.
    private func showSearchMatch(_ rowID: String) {
        guard store.snapshot.rows.contains(where: { $0.id == rowID }) else { return }
        let geometry = scratch.geometry
        store.handle(.geometry(distanceFromBottom: max(geometry.distanceFromBottom, FollowPolicy.nearBottomPoints + 1),
                               distanceFromTop: geometry.distanceFromTop,
                               viewportHeight: geometry.viewportHeight, motion: .user))
        syncFollowState()
        scratch.pendingHold = nil
        scratch.anchor = nil
        stopSearchPlacement()
        scratch.searchRowID = rowID
        recordSearchPlacement("request")
        scheduleSearchPlacement()
    }

    private func stopSearchPlacement() {
        recordSearchPlacement("cancel")
        scratch.searchGeneration &+= 1
        scratch.searchRowID = nil
        scratch.searchAttempts = 0
        scratch.searchHasScrolled = false
        scratch.searchTickScheduled = false
    }

    /// Coalesce layout and scroll callbacks. Missing row geometry waits for
    /// a real layout event instead of consuming a wall-clock retry budget.
    private func scheduleSearchPlacement(after delay: TimeInterval = 0) {
        guard let rowID = scratch.searchRowID, !scratch.searchTickScheduled else { return }
        scratch.searchTickScheduled = true
        let generation = scratch.searchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard generation == scratch.searchGeneration else { return }
            scratch.searchTickScheduled = false
            placeSearchMatch(rowID, generation: generation)
        }
    }

    private func placeSearchMatch(_ rowID: String, generation: UInt64) {
        guard generation == scratch.searchGeneration else { return }
        guard scratch.isOnScreen, scratch.motion != .user,
              search?.isOpen == true, search?.focus?.rowID == rowID else {
            stopSearchPlacement()
            return
        }
        let geometry = scratch.geometry
        if let minY = scratch.rowMinY[rowID], geometry.viewportHeight > 0,
           geometry.contentHeight >= minY {
            // A third of the way down the visible area, so the start of a
            // long message shows above the search bar.
            let desired = max(0, minY - geometry.viewportHeight * 0.3)
            let current = geometry.offsetY + geometry.insetTop
            let atEnd = geometry.distanceFromBottom <= 0.5 && current < desired
                && minY >= current && minY < current + geometry.viewportHeight
            if scratch.searchHasScrolled, abs(current - desired) <= 2 || atEnd {
                recordSearchPlacement("placed", minY: minY, desired: desired)
                // One matching geometry sample is not the end of layout.
                // Keep the requested row as the anchor, without a polling
                // timer, so later row/viewport measurements can correct it.
                // Choosing an ordinary reading anchor here can select a
                // different row from a still-stale page layout.
                // Find owns the reading position until cancelled. Even a
                // transient bottom sample must not reattach following.
                store.handle(.geometry(distanceFromBottom: max(geometry.distanceFromBottom,
                                                               FollowPolicy.nearBottomPoints + 1),
                                       distanceFromTop: geometry.distanceFromTop,
                                       viewportHeight: geometry.viewportHeight, motion: scratch.motion))
                syncFollowState()
                updateBottomVisible()
                return
            }
            // Bound repeated commands against unchanged geometry, but retain
            // the request. A late row/viewport layout wakes it again.
            guard scratch.searchAttempts < Self.searchPlacementAttempts else {
                recordSearchPlacement("waiting", minY: minY, desired: desired)
                return
            }
            recordSearchPlacement("scroll", minY: minY, desired: desired)
            scratch.searchAttempts += 1
            scratch.pendingHold = nil
            let animate = !scratch.searchHasScrolled
            scratch.searchHasScrolled = true
            if animate {
                withAnimation(.smooth(duration: 0.25)) { position.scrollTo(y: desired) }
            } else {
                position.scrollTo(y: desired)
            }
            scheduleSearchPlacement(after: animate ? 0.3 : 0.12)
        }
    }

    private static let searchPlacementAttempts = 14

    /// Retained only for scripted Debug runs, like the existing hold probe.
    private func recordSearchPlacement(_ event: String, minY: Double? = nil, desired: Double? = nil) {
        #if DEBUG
        guard UITestProbe.folder != nil, let rowID = scratch.searchRowID else { return }
        let geometry = scratch.geometry
        let value = "search.\(event) row=\(rowID) focus=\(search?.focus?.rowID ?? "nil")"
            + " open=\(search?.isOpen == true) motion=\(scratch.motion) following=\(store.follow.isFollowing)"
            + " minY=\(minY.map(String.init(describing:)) ?? "nil") desired=\(desired.map(String.init(describing:)) ?? "nil")"
            + " current=\(geometry.offsetY + geometry.insetTop) viewport=\(geometry.viewportHeight)"
            + " content=\(geometry.contentHeight) bottom=\(geometry.distanceFromBottom) attempts=\(scratch.searchAttempts)"
        guard value != scratch.searchProbeValue else { return }
        scratch.searchProbeValue = value
        UITestProbe.append(value, to: "search-placement.txt")
        #endif
    }

    // MARK: B3: VoiceOver announces incoming messages while following

    private func announceIncoming(in snapshot: Snapshot) {
        let latestID = snapshot.rows.last(where: \.isLatest)?.id
        defer { scratch.announcedLatestID = latestID }
        guard voiceOver, store.follow.isFollowing, let theme, let previous = scratch.announcedLatestID,
              latestID != previous, Self.appendsAtEnd(snapshot.change),
              let start = snapshot.rows.firstIndex(where: { $0.id == previous }) else { return }
        for row in snapshot.rows[(start + 1)...] where row.item.countsAsNewMessage {
            let text = theme.copy.text(.incomingAnnouncement,
                                       .text(ChatRowText.senderName(row, roomTitle: store.title, copy: theme.copy)),
                                       .text(ChatRowText.spokenBody(row, copy: theme.copy)))
            AccessibilityNotification.Announcement(text).post()
        }
    }

    /// New messages at the end, alone or in a batch that also moved or
    /// removed rows.
    private static func appendsAtEnd(_ change: SnapshotChange) -> Bool {
        switch change {
        case .appendedAtEnd: true
        case let .mixed(appended, _): appended > 0
        case .reset, .prependedAtStart, .inPlace: false
        }
    }

    // MARK: Helpers

    nonisolated static let contentSpace = "transcript.content"

    private func markMemory(_ label: String) {
        #if DEBUG
        ProbeLog.markMemoryFootprint(label: label)
        #endif
    }
}

/// What the follow and pagination rules need from the scroll geometry.
struct TranscriptGeometry: Equatable {
    /// From the visible bottom edge to the end of the content, including the
    /// composer and keyboard insets.
    var distanceFromBottom: Double
    /// From the start of the content to the visible top edge.
    var distanceFromTop: Double
    var viewportHeight: Double
    var contentHeight: Double
    var offsetY: Double
    /// The navigation bar's inset.
    var insetTop: Double

    static let zero = TranscriptGeometry(distanceFromBottom: 0, distanceFromTop: 0, viewportHeight: 0,
                                         contentHeight: 0, offsetY: 0, insetTop: 0)

    init(distanceFromBottom: Double, distanceFromTop: Double, viewportHeight: Double, contentHeight: Double,
         offsetY: Double, insetTop: Double) {
        self.distanceFromBottom = distanceFromBottom
        self.distanceFromTop = distanceFromTop
        self.viewportHeight = viewportHeight
        self.contentHeight = contentHeight
        self.offsetY = offsetY
        self.insetTop = insetTop
    }

    /// Values are kept to half a point, so sub-point layout noise never
    /// counts as a change.
    static func half(_ value: CGFloat) -> Double { (Double(value) * 2).rounded() / 2 }

    init(_ geometry: ScrollGeometry) {
        let half = Self.half
        // The visible rect runs under the navigation bar and the bottom bar
        // (offset to offset + container + both insets); at the bottom its end
        // is the content's end plus the bottom inset. (Offset + container
        // alone stops short by the top inset: the view never read as at the
        // bottom, so a detached chat never re-attached.)
        distanceFromBottom = half(geometry.contentSize.height + geometry.contentInsets.bottom
                                  - geometry.visibleRect.maxY)
        distanceFromTop = half(geometry.contentOffset.y + geometry.contentInsets.top)
        viewportHeight = half(geometry.containerSize.height)
        contentHeight = half(geometry.contentSize.height)
        offsetY = half(geometry.contentOffset.y)
        insetTop = half(geometry.contentInsets.top)
    }
}

/// What the chat screen draws around the transcript from the follow state:
/// set by the transcript only when it changes (`syncFollowState`).
@MainActor
@Observable
final class ChatChrome {
    var pill = JumpPill.hidden
}

/// Per-frame state of the transcript that no body reads: a plain class, so
/// writing it never re-renders anything.
private final class TranscriptScratch {
    var motion = ScrollMotion.idle
    var geometry = TranscriptGeometry.zero
    var isOnScreen = false
    /// Every row's top in the content, by row ID.
    var rowMinY: [String: Double] = [:]
    /// The IDs of the rows on screen, top to bottom.
    var rowOrder: [String] = []
    /// The messages still growing (`MessageFold.growingIDs`) in the rows on
    /// screen.
    var growing: Set<String> = []
    /// The row being read (§2.4 "Prepend").
    var anchor: TranscriptAnchor?
    /// A hold whose `ScrollPosition` command has not landed yet.
    var pendingHold: (target: Double, attempts: Int)?
    /// The newest event row VoiceOver has been told about (B3).
    var announcedLatestID: String?
    /// After a Dynamic Type change while detached: holds go on, the follow
    /// state sees nothing.
    var quietUntil: Date?
    /// The latest `scheduleSettle` (older ones do nothing).
    var settleGeneration: UInt64 = 0
    /// HC-6: the explicitly requested match owns the anchor until cancelled.
    var placingSearchMatch: Bool { searchRowID != nil }
    var searchRowID: String?
    var searchAttempts = 0
    var searchHasScrolled = false
    var searchTickScheduled = false
    /// The latest `showSearchMatch` (older ones stop).
    var searchGeneration: UInt64 = 0
    #if DEBUG
    var searchProbeValue: String?
    /// `-AtumUITestProbeDir`: how each hold landed, for G-scroll check 4.
    var holdProbe: HoldProbe? = UITestProbe.folder == nil ? nil : HoldProbe()
    #endif
}

/// The row being read: its top in the content, and how far below the
/// visible top it sits.
private struct TranscriptAnchor {
    var id: String
    var minY: Double
    var viewportY: Double
}

#if DEBUG
/// Debug only (`-AtumUITestProbeDir`): how each hold landed, written to
/// `holds.txt` for the UI tests (XCUITest cannot look mid-fling, it waits
/// for the app to be idle). For a hold issued at offset `o0` that moves the
/// view by `shift`, the first pass afterwards with no size change has offset
/// `o1`: `residual = o1 - (o0 + shift)`. A held row has a residual of 0, or
/// of the fling's own motion since (`motion`, from the velocity before the
/// hold); a hold the scroll view ignored has a residual of minus the shift.
private final class HoldProbe {
    private var samples: [(time: CFTimeInterval, offset: Double)] = []
    private var pending: (time: CFTimeInterval, offset: Double, shift: Double, velocity: Double, moving: Bool)?

    func observe(_ geometry: TranscriptGeometry, contentChanged: Bool) {
        let now = CACurrentMediaTime()
        if let hold = pending, !contentChanged {
            pending = nil
            let residual = geometry.offsetY - (hold.offset + hold.shift)
            let motion = hold.velocity * (now - hold.time)
            let kept = abs(residual) <= 4 || abs(residual - motion) <= 4
            UITestProbe.append(String(format: "hold moving=%d shift=%.1f residual=%.1f motion=%.1f kept=%d",
                                      hold.moving ? 1 : 0, hold.shift, residual, motion, kept ? 1 : 0),
                               to: "holds.txt")
        }
        samples.append((now, geometry.offsetY))
        if samples.count > 2 { samples.removeFirst() }
    }

    /// The top of the transcript's visible area (`contentInsets.top`, below
    /// the navigation bar), where `chooseAnchor` starts looking for the row
    /// being read; G-scroll check 6 picks the same row (`geometry.txt`).
    func inset(_ insetTop: Double) {
        guard insetTop != loggedInsetTop else { return }
        loggedInsetTop = insetTop
        UITestProbe.append(String(format: "insetTop=%.1f", insetTop), to: "geometry.txt")
    }

    private var loggedInsetTop: Double?

    func held(_ rowID: String, from offset: Double, to target: Double, moving: Bool) {
        UITestProbe.append("held row=\(rowID)", to: "geometry.txt")
        var velocity = 0.0
        if samples.count == 2, samples[1].time > samples[0].time {
            velocity = (samples[1].offset - samples[0].offset) / (samples[1].time - samples[0].time)
        }
        pending = (CACurrentMediaTime(), offset, target - offset, moving ? velocity : 0, moving)
    }
}
#endif

/// The G-scroll choice (§2.4): mechanism (a), recorded in
/// `docs/decisions/2026-10-11-g-scroll.md`. Debug builds accept
/// `-AtumTranscriptMechanism b` to fall back to mechanism (b) on a device
/// build without a code change.
struct TranscriptTuning: Equatable {
    enum Mechanism: Equatable {
        /// (a) `.defaultScrollAnchor(following ? .bottom : .top, for: .sizeChanges)`.
        case switchingAnchor
        /// (b) no size-change anchor; the store scrolls to the bottom on every
        /// change while following.
        case scrollCommands
    }

    var mechanism: Mechanism

    static let decided = TranscriptTuning(mechanism: .switchingAnchor)

    static let current: TranscriptTuning = {
        var tuning = decided
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-AtumTranscriptMechanism"), index + 1 < arguments.count {
            switch arguments[index + 1] {
            case "a": tuning.mechanism = .switchingAnchor
            case "b": tuning.mechanism = .scrollCommands
            default: break
            }
        }
        #endif
        return tuning
    }()
}

private extension ScrollMotion {
    /// The person touching or flinging is `.user`; an animated scroll is
    /// `.animating` (FollowPolicy tells the pill's own animation apart).
    init(_ phase: ScrollPhase) {
        switch phase {
        case .idle: self = .idle
        case .animating: self = .animating
        case .tracking, .interacting, .decelerating: self = .user
        }
    }
}

/// Puts the keyboard away from the transcript, as Telegram and Messages do
/// (owner, 2026-11-11). UIKit recognizers rather than SwiftUI gestures, so
/// they can be told to recognise beside every other gesture and to cancel no
/// touch: a tap on a link, a photo, a quote, Show more or the jump pill still
/// does what it does, and the long-press menu still opens. Resigning the
/// first responder only hides the keyboard; the composer keeps its draft.
/// While following, the transcript's bottom anchor keeps the newest row at
/// the bottom as the keyboard goes; while reading, the rows on screen stay.
enum TranscriptKeyboardDismissal {
    @MainActor static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// Recognises beside everything; never delays or cancels a touch.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The pan already put the keyboard away during this drag.
        var dismissedThisDrag = false

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }

    /// A tap anywhere on the transcript.
    struct Tap: UIGestureRecognizerRepresentable {
        func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

        func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
            let recognizer = UITapGestureRecognizer()
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = context.coordinator
            return recognizer
        }

        func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
            if recognizer.state == .ended { TranscriptKeyboardDismissal.dismiss() }
        }
    }

    /// A drag towards older messages (the finger moving down) of more than
    /// `distance` points, Telegram's rule. `.scrollDismissesKeyboard(
    /// .interactively)` alone hides it only once the finger reaches the
    /// keyboard. A drag towards newer messages keeps it up.
    struct Pan: UIGestureRecognizerRepresentable {
        static let distance: CGFloat = 24

        func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

        func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
            let recognizer = UIPanGestureRecognizer()
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = context.coordinator
            return recognizer
        }

        func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
            let coordinator = context.coordinator
            switch recognizer.state {
            case .began:
                coordinator.dismissedThisDrag = false
            case .changed:
                guard !coordinator.dismissedThisDrag,
                      recognizer.translation(in: recognizer.view).y > Self.distance else { return }
                coordinator.dismissedThisDrag = true
                TranscriptKeyboardDismissal.dismiss()
            default:
                break
            }
        }
    }
}
