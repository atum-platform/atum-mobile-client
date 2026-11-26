import AtumChat
import Observation
import SwiftUI
import UIKit

/// The scroll seam. UIKit lays out and reuses the cells, while the store
/// still owns follow state, pagination and the timeline projection.
struct TranscriptView: View {
    let store: LiveConversationStore
    let chrome: ChatChrome
    var covered = false
    var search: ChatSearchSession? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { viewport in
            let visible = viewport.frame(in: .global)
            GeometryReader { surface in
                let full = surface.frame(in: .global)
                collection(insets: UIEdgeInsets(top: max(0, visible.minY - full.minY), left: 0,
                                                 bottom: max(0, full.maxY - visible.maxY), right: 0))
            }
            // UIKit can draw under the glass while its content insets keep
            // reading, following and pagination inside the unobscured area.
            .ignoresSafeArea(.container, edges: .vertical)
        }
    }

    private func collection(insets: UIEdgeInsets) -> some View {
        TranscriptCollection(
            store: store, chrome: chrome, snapshot: store.snapshot,
            request: store.scrollRequest, followState: store.follow.state,
            covered: covered, pagination: store.pagination, generation: store.timelineGeneration,
            route: store.searchTargetEventID, focus: search?.focus, highlights: search?.highlights ?? [:],
            insets: insets, dynamicTypeSize: dynamicTypeSize
        )
        .gesture(TranscriptKeyboardDismissal.Tap())
    }
}

/// What the chat screen draws around the transcript.
@MainActor
@Observable
final class ChatChrome {
    var pill = JumpPill.hidden
}

private struct TranscriptCollection: UIViewRepresentable {
    let store: LiveConversationStore
    let chrome: ChatChrome
    let snapshot: Snapshot
    let request: ScrollRequest
    let followState: FollowState
    let covered: Bool
    let pagination: PaginationState
    let generation: UInt64
    let route: String?
    let focus: ChatSearchSession.Focus?
    let highlights: [String: ChatSearchHighlight]
    let insets: UIEdgeInsets
    let dynamicTypeSize: DynamicTypeSize

    func makeCoordinator() -> TranscriptEngine { TranscriptEngine(store: store, chrome: chrome) }

    func makeUIView(context: Context) -> TranscriptList {
        context.coordinator.makeList()
    }

    func updateUIView(_ view: TranscriptList, context: Context) {
        context.coordinator.update(self, environment: context.environment)
    }

    static func dismantleUIView(_ uiView: TranscriptList, coordinator: TranscriptEngine) {
        coordinator.close()
    }
}

/// A one-column compositional list with the same margins as the transcript.
/// A measured cell can change the geometry of the rows after it. UIKit
/// applies the corresponding offset change in that same invalidation.
private final class TranscriptLayout: UICollectionViewCompositionalLayout {
    enum Pin {
        case none
        case bottom
        case row(IndexPath)
    }

    var pin = Pin.none

    init() {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(76))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: ChatLayout.sideMargin,
                                                        bottom: 12, trailing: ChatLayout.sideMargin)
        super.init(section: section)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init()") }

    override func invalidationContext(forPreferredLayoutAttributes preferred: UICollectionViewLayoutAttributes,
                                      withOriginalAttributes original: UICollectionViewLayoutAttributes)
        -> UICollectionViewLayoutInvalidationContext {
        let context = super.invalidationContext(forPreferredLayoutAttributes: preferred, withOriginalAttributes: original)
        let delta = preferred.frame.height - original.frame.height
        switch pin {
        case .bottom:
            context.contentOffsetAdjustment.y = delta
        case let .row(path) where original.indexPath.item < path.item:
            context.contentOffsetAdjustment.y = delta
        case .row:
            context.contentOffsetAdjustment.y = 0
        case .none:
            break
        }
        return context
    }
}

private final class TranscriptList: UICollectionView {
    var willLayout: (() -> Void)?
    var didLayout: (() -> Void)?
    var windowChanged: (() -> Void)?

    override func layoutSubviews() {
        willLayout?()
        super.layoutSubviews()
        didLayout?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        windowChanged?()
    }
}

@MainActor
@Observable
private final class TranscriptRowPresentation {
    var environment = EnvironmentValues()
    var routeHighlight: String?
    var highlights: [String: ChatSearchHighlight] = [:]
    var growing: Set<String> = []
    var latestAnswer: String?
}

/// The hosted root preserves per-row SwiftUI state on a reconfiguration
/// and scopes that state to the stable row ID when a cell is reused.
private struct TranscriptHostedRow: View {
    let row: ChatRow
    let store: LiveConversationStore
    let presentation: TranscriptRowPresentation

    var body: some View {
        let environment = presentation.environment
        let highlight = presentation.routeHighlight == row.id
            ? (environment.chatTheme?.color("ink", environment.colorScheme).opacity(0.12) ?? .clear) : .clear
        ChatRowView(row: row, kind: store.kind, roomTitle: store.title,
                    parsedBody: store.parsedBody(for: row), isLatestAnswer: row.id == presentation.latestAnswer,
                    searchHighlight: presentation.highlights[row.id],
                    isGrowing: presentation.growing.contains(row.id))
            .equatable()
            .background(RoundedRectangle(cornerRadius: 8).fill(highlight))
            // The hosting cell owns its own SwiftUI view graph and gesture
            // machinery. Copy in only the chat values a row reads.
            .transformEnvironment(\.self) { target in
                // SwiftUI applies the transform during its main-thread update.
                MainActor.assumeIsolated { TranscriptRowEnvironment.forward(environment, into: &target) }
            }
            .id(row.id)
    }
}

/// The chat screen's environment values that a hosted row reads. A cell's
/// SwiftUI graph does not inherit them, so each key listed in `forwarded`
/// is copied into it. A key a row reads but this list omits silently falls
/// back to its default inside the transcript, so every chat `@Entry` must
/// appear here or in the exemptions of
/// `tests/test_transcript_row_environment.py`, which checks this list.
///
/// `same` decides whether a change re-renders the visible rows: equatable
/// values compare by value and references by identity. Closure values
/// (actions, loaders, `openURL`) are rebuilt by every chat screen body while
/// staying bound to session-stable objects, so on their own they never
/// re-render rows; they refresh with the next compared change.
@MainActor
private enum TranscriptRowEnvironment {
    struct Key {
        let name: String
        let same: (EnvironmentValues, EnvironmentValues) -> Bool
        let copy: (inout EnvironmentValues, EnvironmentValues) -> Void
    }

    static func value<V: Equatable>(_ path: WritableKeyPath<EnvironmentValues, V>, _ name: String) -> Key {
        Key(name: name, same: { $0[keyPath: path] == $1[keyPath: path] },
            copy: { $0[keyPath: path] = $1[keyPath: path] })
    }

    static func object<V: AnyObject>(_ path: WritableKeyPath<EnvironmentValues, V?>, _ name: String) -> Key {
        Key(name: name, same: { $0[keyPath: path] === $1[keyPath: path] },
            copy: { $0[keyPath: path] = $1[keyPath: path] })
    }

    static func stable<V>(_ path: WritableKeyPath<EnvironmentValues, V>, _ name: String) -> Key {
        Key(name: name, same: { _, _ in true }, copy: { $0[keyPath: path] = $1[keyPath: path] })
    }

    // forwarded-keys:begin
    static let forwarded: [Key] = [
        Key(name: "atum", same: { $0.atum?.design === $1.atum?.design },
            copy: { $0[keyPath: \.atum] = $1[keyPath: \.atum] }),
        // Derived from `atum`'s design.
        stable(\.atumKit, "atumKit"),
        Key(name: "chatTheme", same: { $0.chatTheme?.design === $1.chatTheme?.design
                                         && $0.chatTheme?.locale == $1.chatTheme?.locale },
            copy: { $0[keyPath: \.chatTheme] = $1[keyPath: \.chatTheme] }),
        stable(\.chatActions, "chatActions"),
        object(\.messageActions, "messageActions"),
        value(\.chatOwnUserID, "chatOwnUserID"),
        value(\.chatRoomAvatar, "chatRoomAvatar"),
        value(\.chatRoomFace, "chatRoomFace"),
        value(\.chatMembers, "chatMembers"),
        value(\.chatToday, "chatToday"),
        value(\.chatReducesMotion, "chatReducesMotion"),
        value(\.chatFlatRuns, "chatFlatRuns"),
        // Built once by the engine (`TranscriptEngine.interactions`).
        stable(\.chatRowInteractions, "chatRowInteractions"),
        value(\.atumAvatarBrandInset, "atumAvatarBrandInset"),
        value(\.colorScheme, "colorScheme"),
        value(\.dynamicTypeSize, "dynamicTypeSize"),
        value(\.locale, "locale"),
        value(\.layoutDirection, "layoutDirection"),
        stable(\.openURL, "openURL"),
        stable(\.chatLoadMatrixThumbnail, "chatLoadMatrixThumbnail"),
        value(\.appBotPresentation, "appBotPresentation"),
        object(\.appBotPresenter, "appBotPresenter"),
        value(\.appBotNoticeDisplays, "appBotNoticeDisplays"),
        stable(\.chatMediaAccess, "chatMediaAccess"),
        value(\.chatAttachmentsClosedReason, "chatAttachmentsClosedReason"),
        object(\.chatMediaPresenter, "chatMediaPresenter"),
        value(\.chatLocalMediaFiles, "chatLocalMediaFiles"),
        value(\.chatMediaRetryGeneration, "chatMediaRetryGeneration"),
        value(\.chatMediaNamespace, "chatMediaNamespace"),
    ]
    // forwarded-keys:end

    static func forward(_ source: EnvironmentValues, into target: inout EnvironmentValues) {
        for key in forwarded { key.copy(&target, source) }
    }

    static func same(_ old: EnvironmentValues, _ new: EnvironmentValues) -> Bool {
        forwarded.allSatisfy { $0.same(old, new) }
    }
}

@MainActor
private final class TranscriptEngine: NSObject, UICollectionViewDelegate {
    private struct Anchor {
        let id: String
        let viewportY: CGFloat
    }

    private struct SearchPlacement {
        let rowID: String
        var animate = true
        var routed: (match: ChatHistorySearch.RoutedMatch,
                     completion: AsyncThrowingStream<Void, Error>.Continuation)?
    }

    private let store: LiveConversationStore
    private let chrome: ChatChrome
    private let layout = TranscriptLayout()
    private let presentation = TranscriptRowPresentation()
    private let scroll = ChatScrollSignal()
    /// The row interactions, built once so forwarding the environment never
    /// changes them (`TranscriptRowEnvironment`).
    private var interactions = ChatRowInteractions()
    private var forwardedEnvironment = false
    /// Fresh local echoes whose send entrance plays when their cell first
    /// displays (`SendEntrance`).
    private var pendingEntrances: Set<String> = []
    private weak var list: TranscriptList?
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>?
    private var snapshot = Snapshot.empty
    private var rows: [String: ChatRow] = [:]
    private var request = ScrollRequest.initial
    private var searchFocus: ChatSearchSession.Focus?
    private var placement: SearchPlacement?
    private var replyJumpID: String?
    private var route: String?
    private var routeTask: Task<Void, Never>?
    private var covered = false
    private var sceneActive = false
    private var voiceOver = false
    private var dynamicTypeSize = DynamicTypeSize.large
    private var motion = ScrollMotion.idle
    private var opened = false
    private var applyingSnapshot = false
    private var layingOut = false
    private var readingAnchor: Anchor?
    private var resizedReadingAnchor: Anchor?
    private var foldingAnchor: Anchor?
    private var measuredAnchor: Anchor?
    private var lastGeometry: TranscriptGeometry?
    private var reportTask: Task<Void, Never>?
    private var cancelRouteOnReport = false
    private var releasePlacementOnReport = false
    private var detachOnReport = false
    private var dismissedKeyboardOnDrag = false
    private var keyboardPull: (entry: CGFloat, height: CGFloat, travel: CGFloat)?
    private var reportKeyboardPanEnd = false
    #if DEBUG
    private var loggedInset: CGFloat?
    private var loggedLatestDistance: Double?
    #endif

    init(store: LiveConversationStore, chrome: ChatChrome) {
        self.store = store
        self.chrome = chrome
    }

    func makeList() -> TranscriptList {
        let list = TranscriptList(frame: .zero, collectionViewLayout: layout)
        self.list = list
        list.backgroundColor = .clear
        list.alwaysBounceVertical = true
        list.allowsSelection = false
        list.delaysContentTouches = false
        list.contentInsetAdjustmentBehavior = .never
        list.automaticallyAdjustsScrollIndicatorInsets = false
        list.keyboardDismissMode = .interactive
        list.bottomEdgeEffect.style = .soft
        list.accessibilityIdentifier = AccessibilityID.transcript
        list.delegate = self
        list.panGestureRecognizer.addTarget(self, action: #selector(handleKeyboardDrag(_:)))
        scroll.isScrolling = { [weak list] in list.map { $0.isDragging || $0.isDecelerating } ?? false }
        interactions.showOriginal = { [weak self] in self?.showOriginal($0) }
        interactions.opening = { [weak self] in self?.rowOpening($0) }
        interactions.folded = { [weak self] in self?.rowFolded($0) }
        interactions.scroll = scroll
        let cells = UICollectionView.CellRegistration<UICollectionViewCell, String> { [weak self] cell, _, id in
            guard let self, let row = self.rows[id] else { return }
            cell.contentConfiguration = UIHostingConfiguration {
                TranscriptHostedRow(row: row, store: self.store, presentation: self.presentation)
            }
            .margins(.all, 0)
            .minSize(width: 0, height: 0)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: list) { list, path, id in
            list.dequeueConfiguredReusableCell(using: cells, for: path, item: id)
        }
        list.willLayout = { [weak self] in self?.beforeLayout() }
        list.didLayout = { [weak self] in self?.afterLayout() }
        list.windowChanged = { [weak self] in self?.scheduleReport() }
        return list
    }

    func update(_ input: TranscriptCollection, environment: EnvironmentValues) {
        guard let list else { return }
        covered = input.covered
        sceneActive = environment.scenePhase == .active
        voiceOver = environment.accessibilityVoiceOverEnabled
        list.isScrollEnabled = environment.isScrollEnabled
        list.accessibilityValue = AccessibilityID.transcriptValue(input.followState)
        if list.contentInset != input.insets {
            list.contentInset = input.insets
            list.verticalScrollIndicatorInsets = input.insets
        }

        let sizeChanged = dynamicTypeSize != input.dynamicTypeSize
        dynamicTypeSize = input.dynamicTypeSize
        if sizeChanged, !store.follow.isFollowing, placement == nil {
            resizedReadingAnchor = resizedReadingAnchor ?? readingAnchor ?? captureAnchor()
            traceAnchor(resizedReadingAnchor)
            updateSizingPin()
        }
        var rowEnvironment = environment
        rowEnvironment.dynamicTypeSize = input.dynamicTypeSize
        rowEnvironment.chatRowInteractions = interactions
        // Every visible row reads this, so assigning it re-renders them all.
        // Most updates (a streamed token, a receipt) leave it unchanged.
        if !forwardedEnvironment || !TranscriptRowEnvironment.same(presentation.environment, rowEnvironment) {
            forwardedEnvironment = true
            presentation.environment = rowEnvironment
        }
        if presentation.highlights != input.highlights { presentation.highlights = input.highlights }

        if snapshot != input.snapshot {
            let previous = snapshot
            snapshot = input.snapshot
            if input.pagination == .idle(hitTimelineStart: true),
               snapshot.rows.contains(where: { $0.item.kind == .timelineStart }),
               !previous.rows.contains(where: { $0.item.kind == .timelineStart }) {
                markMemory("timeline.start")
            }
            announceIncoming(after: previous)
            applySnapshot()
        }
        if let routed = placement?.routed,
           (snapshot.generation != input.generation || !routed.match.isCurrent(in: snapshot)) {
            stopPlacement()
        }
        if searchFocus != input.focus {
            searchFocus = input.focus
            if let focus = input.focus {
                cancelRouteOnReport = true
                showSearchMatch(focus.rowID)
            } else {
                stopPlacement()
            }
        }
        if route != input.route {
            route = input.route
            routeTask?.cancel()
            if let eventID = input.route {
                routeTask = Task { [weak self] in await self?.focusRoutedMessage(eventID) }
            } else if placement?.routed != nil {
                stopPlacement()
            }
        }
        if request != input.request {
            request = input.request
            if case let .scrollToBottom(animated) = request.command, store.follow.isFollowing {
                stopPlacement()
                replyJumpID = nil
                resizedReadingAnchor = nil
                scrollToBottom(animated: animated)
            }
        }
        list.setNeedsLayout()
        scheduleReport()
    }

    func close() {
        stopPlacement()
        releasePlacementOnReport = false
        reportTask?.cancel()
        reportTask = nil
        routeTask?.cancel()
        routeTask = nil
        MessageFoldStore.session.readerSees([], among: presentation.growing)
        Task { [weak store] in store?.bottomVisible = false }
    }

    // MARK: Snapshot and viewport anchors

    private func applySnapshot() {
        guard let list, let dataSource else { return }
        // A diffable snapshot traps on a repeated identifier. The projection
        // never emits one; keep the first occurrence if it ever does.
        var seen = Set<String>()
        let unique = snapshot.rows.filter { seen.insert($0.id).inserted }
        #if DEBUG
        if unique.count != snapshot.rows.count {
            assertionFailure("Transcript snapshot repeats \(snapshot.rows.count - unique.count) row IDs")
        }
        #endif
        let nextRows = Dictionary(unique.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let resizedReadingAnchor, nextRows[resizedReadingAnchor.id] == nil {
            self.resizedReadingAnchor = nil
        }
        let keepsBottom = store.follow.isFollowing && motion != .user
        let anchor = keepsBottom || placement != nil
            ? nil : resizedReadingAnchor ?? captureAnchor(keeping: nextRows)
        let ids = unique.map(\.id)
        let previousIDs = dataSource.snapshot().itemIdentifiers
        let changed = ids.filter { id in
            guard let old = rows[id] else { return false }
            return old != nextRows[id]
        }
        rows = nextRows
        if !previousIDs.isEmpty {
            let known = Set(previousIDs)
            for row in unique where !known.contains(row.id) && SendEntrance.plays(row) {
                pendingEntrances.insert(row.id)
            }
        }
        pendingEntrances = pendingEntrances.filter { id in rows[id].map { SendEntrance.plays($0) } ?? false }
        let growing = MessageFold.growingIDs(in: snapshot.rows)
        if presentation.growing != growing { presentation.growing = growing }
        let latestAnswer = store.kind == .assistant || store.kind == .appBot
            ? snapshot.rows.last { $0.item.kind == .message && !$0.item.isOwn }?.id : nil
        if presentation.latestAnswer != latestAnswer { presentation.latestAnswer = latestAnswer }
        if let placement, rows[placement.rowID] == nil { stopPlacement() }
        guard ids != previousIDs || !changed.isEmpty else { return }

        applyingSnapshot = true
        layout.pin = .none
        var next = NSDiffableDataSourceSnapshot<Int, String>()
        next.appendSections([0])
        next.appendItems(ids)
        next.reconfigureItems(changed)
        dataSource.apply(next, animatingDifferences: false)
        // Resolve the anchor against the new index path after UIKit lays out
        // the diff. Only the ID and its distance from the viewport survive.
        list.layoutIfNeeded()
        if let anchor { restore(anchor) }
        applyingSnapshot = false
        readingAnchor = anchor
        updateSizingPin()
        if store.follow.isFollowing, motion == .idle, placement == nil { scrollToBottom(animated: false) }
    }

    private func captureAnchor(keeping nextRows: [String: ChatRow]? = nil) -> Anchor? {
        guard let list, let dataSource else { return nil }
        let top = list.contentOffset.y + list.adjustedContentInset.top
        let bottom = list.contentOffset.y + list.bounds.height - list.adjustedContentInset.bottom
        var coveringEvent: Anchor?
        var fallback: Anchor?
        for path in list.indexPathsForVisibleItems.sorted() {
            guard let frame = layout.layoutAttributesForItem(at: path)?.frame,
                  frame.maxY > top, frame.minY < bottom,
                  let id = dataSource.itemIdentifier(for: path),
                  let kind = rows[id]?.item.kind, kind != .loadingEarlier,
                  nextRows?[id] != nil || nextRows == nil else { continue }
            let anchor = Anchor(id: id, viewportY: frame.minY - top)
            if fallback == nil { fallback = anchor }
            if kind.isEventContent {
                if frame.minY >= top - 0.5 { return anchor }
                coveringEvent = anchor
            }
        }
        return coveringEvent ?? fallback
    }

    private func rowFrame(_ id: String) -> CGRect? {
        guard let indexPath = dataSource?.indexPath(for: id) else { return nil }
        return layout.layoutAttributesForItem(at: indexPath)?.frame
    }

    @discardableResult
    private func restore(_ anchor: Anchor) -> Bool {
        guard let list, let frame = rowFrame(anchor.id) else { return false }
        let before = list.contentOffset.y
        let desired = frame.minY - anchor.viewportY - list.adjustedContentInset.top
        let target = setOffset(desired)
        traceHold(anchor, before: before, desired: desired, target: target, after: list.contentOffset.y)
        return abs(list.contentOffset.y - desired) <= 0.5
    }

    private func updateSizingPin() {
        if applyingSnapshot {
            layout.pin = .none
        } else if store.follow.isFollowing, motion != .user, placement == nil, !reportKeyboardPanEnd {
            layout.pin = .bottom
        } else if let id = placement?.rowID ?? foldingAnchor?.id ?? resizedReadingAnchor?.id ?? readingAnchor?.id,
                  let path = dataSource?.indexPath(for: id) {
            layout.pin = .row(path)
        } else {
            layout.pin = .none
        }
    }

    private func beforeLayout() {
        guard !layingOut, !applyingSnapshot else { return }
        // Keep the last reported anchor through asynchronous self-sizing
        // invalidations and use the current one for the next layout.
        measuredAnchor = foldingAnchor ?? resizedReadingAnchor ?? readingAnchor
        updateSizingPin()
    }

    private func afterLayout() {
        guard !layingOut, !applyingSnapshot, let list, list.bounds.height > 0, !rows.isEmpty else { return }
        layingOut = true
        defer { layingOut = false }
        var restored: Anchor?
        if placement != nil {
            placeSearchMatch()
        } else if motion == .idle, let id = replyJumpID {
            centerReply(id)
        } else if store.follow.isFollowing, motion == .idle, !reportKeyboardPanEnd {
            scrollToBottom(animated: false)
        } else if motion == .idle, let anchor = measuredAnchor, restore(anchor) {
            restored = anchor
        }
        if foldingAnchor != nil { foldingAnchor = nil }
        readingAnchor = restored ?? captureAnchor()
        updateSizingPin()
        scheduleReport()
    }

    @discardableResult
    private func setOffset(_ proposed: CGFloat, animated: Bool = false) -> CGFloat {
        guard let list, list.bounds.height > 0 else { return proposed }
        let inset = list.adjustedContentInset
        let bottom = max(-inset.top, list.contentSize.height - list.bounds.height + inset.bottom)
        let y = min(max(-inset.top, proposed), bottom)
        guard abs(list.contentOffset.y - y) > 0.5 else { return y }
        if animated && !ChatMotion.disabledForUITests {
            motion = .animating
            list.setContentOffset(CGPoint(x: list.contentOffset.x, y: y), animated: true)
        } else {
            list.contentOffset.y = y
        }
        return y
    }

    private func scrollToBottom(animated: Bool) {
        guard let list, list.bounds.height > 0, !rows.isEmpty else { return }
        let bottom = { list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom }
        let viewport = list.bounds.height - list.adjustedContentInset.top - list.adjustedContentInset.bottom
        let jumped = animated && !ChatMotion.disabledForUITests && bottom() - list.contentOffset.y > viewport * 2
        if jumped {
            // From far up, an animated scroll would cross rows still at their
            // estimated heights and land short as they size. Jump to one
            // screen above the end, let those rows size, then animate the
            // last screen. The bottom pin keeps that screen's distance.
            motion = .animating
            layout.pin = .bottom
            list.contentOffset.y = max(-list.adjustedContentInset.top, bottom() - viewport)
            list.layoutIfNeeded()
        }
        let before = list.contentOffset.y
        let target = setOffset(bottom(), animated: animated)
        // Nothing was left to animate after the jump, so no animation end
        // will arrive: the scroll is over.
        if jumped, abs(before - target) <= 0.5 { endMotion() }
    }

    // MARK: Scroll input, visibility and message folds

    // As in Messages, dragging towards older messages dismisses the
    // keyboard even if the finger has yet to reach it.
    @objc private func handleKeyboardDrag(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { dismissedKeyboardOnDrag = false }
        guard pan.state == .changed else { return }
        let travel = pan.translation(in: pan.view).y
        if let pull = keyboardPull, travel < 0 || travel > pull.height {
            keyboardPull = nil
            scheduleReport()
        } else {
            keyboardPull?.travel = travel
        }
        guard !dismissedKeyboardOnDrag, travel > 24 else { return }
        dismissedKeyboardOnDrag = true
        TranscriptKeyboardDismissal.dismiss()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // The rows move with the content, so their own press rules never see
        // this drag: cancel any press before it opens a menu.
        scroll.panBegan()
        motion = .user
        foldingAnchor = nil
        replyJumpID = nil
        resizedReadingAnchor = nil
        stopPlacement()
        cancelRouteOnReport = true
        keyboardPull = candidateKeyboardPull(in: scrollView)
        updateSizingPin()
    }

    /// A short pull from the transcript into the keyboard dismisses it
    /// while keeping the latest row. A drag starting farther up or moving
    /// more than a keyboard height reads older messages as usual.
    private func candidateKeyboardPull(in scrollView: UIScrollView) -> (entry: CGFloat, height: CGFloat, travel: CGFloat)? {
        guard store.follow.isFollowing, let window = scrollView.window else { return nil }
        // The collection ignores container insets and ends at the keyboard.
        let keyboardTop = scrollView.convert(scrollView.bounds, to: window).maxY
        let keyboardHeight = window.bounds.maxY - keyboardTop
        let pan = scrollView.panGestureRecognizer
        let startY = pan.location(in: window).y - pan.translation(in: window).y
        let distance = keyboardTop - startY
        traceKeyboardPull("begin entry=\(distance) height=\(keyboardHeight)")
        guard keyboardHeight > window.safeAreaInsets.bottom, (0...keyboardHeight).contains(distance) else { return nil }
        return (entry: distance, height: keyboardHeight, travel: 0)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !applyingSnapshot, !layingOut else { return }
        if motion == .user {
            readingAnchor = captureAnchor()
            updateSizingPin()
        }
        scheduleReport()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if let pull = keyboardPull {
            keyboardPull = nil
            let finalTravel = scrollView.panGestureRecognizer.translation(in: scrollView).y
            let travel = finalTravel == 0 ? pull.travel : finalTravel
            traceKeyboardPull("end entry=\(pull.entry) height=\(pull.height) travel=\(travel)")
            if (pull.entry...pull.height).contains(travel) {
                if decelerate { scrollView.stopScrollingAndZooming() }
                endMotion()
                scrollToBottom(animated: false)
                return
            }
            reportKeyboardPanEnd = !decelerate
        }
        if !decelerate { endMotion() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { endMotion() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { endMotion() }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { endMotion() }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        stopPlacement()
        resizedReadingAnchor = nil
        motion = .animating
        return true
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        guard let id = dataSource?.itemIdentifier(for: indexPath) else { return }
        guard pendingEntrances.remove(id) != nil, let row = rows[id], SendEntrance.plays(row) else {
            SendEntrance.stop(on: cell.layer)
            return
        }
        SendEntrance.play(on: cell.layer, reduceMotion: presentation.environment.chatReducesMotion)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        SendEntrance.stop(on: cell.layer)
    }

    func scrollViewDidChangeAdjustedContentInset(_ scrollView: UIScrollView) {
        list?.setNeedsLayout()
    }

    private func endMotion() {
        readingAnchor = captureAnchor()
        motion = .idle
        list?.setNeedsLayout()
        scheduleReport()
    }

    /// Coalesce UIKit's layout/delegate callbacks and publish outside the
    /// representable update. Layout corrections never dispatch store writes.
    private func scheduleReport() {
        guard reportTask == nil else { return }
        reportTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.reportTask = nil
            self.reportViewport()
        }
    }

    private func reportViewport() {
        guard let list else { return }
        if cancelRouteOnReport {
            cancelRouteOnReport = false
            store.searchTargetEventID = nil
        }
        let geometry = TranscriptGeometry(list)
        // The collection can briefly estimate a new content end at the
        // reading row as cells resize. A typography change is not a request
        // to reattach; the retained row still owns the reading position.
        let resizeAtEstimatedEnd = resizedReadingAnchor != nil && motion == .idle
            && geometry.distanceFromBottom <= FollowPolicy.nearBottomPoints
        let onScreen = list.window != nil && geometry.viewportHeight > 0 && !rows.isEmpty
        if onScreen {
            if !opened {
                opened = true
                if placement == nil { store.handle(.opened) }
                markMemory("chat.open")
            }
            let clampedToSearch = placement != nil
            if releasePlacementOnReport, !clampedToSearch {
                releasePlacementOnReport = false
                lastGeometry = geometry
                store.handle(.searchPlacementReleased(distanceFromBottom: geometry.distanceFromBottom,
                                                      viewportHeight: geometry.viewportHeight))
            }
            if keyboardPull == nil, !resizeAtEstimatedEnd,
               geometry != lastGeometry || detachOnReport || reportKeyboardPanEnd {
                lastGeometry = geometry
                let reportedMotion = detachOnReport || reportKeyboardPanEnd ? .user : motion
                detachOnReport = false
                reportKeyboardPanEnd = false
                store.handle(.geometry(
                    distanceFromBottom: clampedToSearch
                        ? max(geometry.distanceFromBottom, FollowPolicy.nearBottomPoints + 1)
                        : geometry.distanceFromBottom,
                    distanceFromTop: geometry.distanceFromTop,
                    viewportHeight: geometry.viewportHeight, motion: reportedMotion
                ))
            }
            confirmPlacement()
            noteReading(geometry)
        } else {
            lastGeometry = nil
            MessageFoldStore.session.readerSees([], among: presentation.growing)
        }
        let visible = onScreen && sceneActive && !covered
            && store.searchTargetEventID == nil
            && !resizeAtEstimatedEnd
            && geometry.distanceFromBottom <= FollowPolicy.nearBottomPoints
        if store.bottomVisible != visible { store.bottomVisible = visible }
        if chrome.pill != store.follow.pill { chrome.pill = store.follow.pill }
        list.accessibilityValue = store.follow.accessibilityValue
        #if DEBUG
        if UITestProbe.folder != nil, loggedInset != CGFloat(geometry.insetTop) {
            loggedInset = CGFloat(geometry.insetTop)
            UITestProbe.append(String(format: "insetTop=%.1f", geometry.insetTop), to: "geometry.txt")
        }
        if UITestProbe.folder != nil, onScreen, motion == .idle,
           let latest = snapshot.rows.last(where: \.isLatest), let frame = rowFrame(latest.id) {
            let visibleBottom = list.contentOffset.y + list.bounds.height - list.adjustedContentInset.bottom
            let distance = TranscriptGeometry.half(max(0, frame.minY - visibleBottom))
            if distance != loggedLatestDistance {
                loggedLatestDistance = distance
                UITestProbe.append(String(format: "distanceFromLatest=%.1f", distance), to: "geometry.txt")
            }
        }
        #endif
    }

    private func detach() {
        guard let list else { return }
        let geometry = TranscriptGeometry(list)
        store.handle(.geometry(distanceFromBottom: max(geometry.distanceFromBottom, FollowPolicy.nearBottomPoints + 1),
                               distanceFromTop: geometry.distanceFromTop,
                               viewportHeight: geometry.viewportHeight, motion: .user))
        scheduleReport()
    }

    private func showOriginal(_ eventID: String) {
        guard let row = snapshot.rows.first(where: { $0.item.eventID == eventID }) else { return }
        stopPlacement()
        resizedReadingAnchor = nil
        replyJumpID = row.id
        readingAnchor = nil
        centerReply(row.id, animated: true)
    }

    private func centerReply(_ id: String, animated: Bool = false) {
        guard let list, let path = dataSource?.indexPath(for: id),
              let frame = layout.layoutAttributesForItem(at: path)?.frame else {
            replyJumpID = nil
            return
        }
        let geometry = TranscriptGeometry(list)
        let viewport = geometry.viewportHeight
        let y = frame.midY - list.adjustedContentInset.top - viewport / 2
        if abs(list.contentOffset.y - y) > FollowPolicy.nearBottomPoints, store.follow.isFollowing { detach() }
        setOffset(y, animated: animated)
        // A distant item can start out at its estimated height. Center it
        // again once the target cell has actually entered the viewport.
        if !animated, list.cellForItem(at: path) != nil { replyJumpID = nil }
        if animated { list.setNeedsLayout() }
    }

    private func rowOpening(_ id: String) {
        guard let list, let frame = rowFrame(id) else { return }
        resizedReadingAnchor = nil
        if store.follow.isFollowing { detach() }
        let top = list.contentOffset.y + list.adjustedContentInset.top
        foldingAnchor = Anchor(id: id, viewportY: frame.minY - top)
        updateSizingPin()
    }

    private func rowFolded(_ id: String) {
        guard !store.follow.isFollowing, let list, let frame = rowFrame(id),
              frame.minY < list.contentOffset.y + list.adjustedContentInset.top else { return }
        foldingAnchor = Anchor(id: id, viewportY: 0)
        resizedReadingAnchor = nil
        readingAnchor = nil
        setOffset(frame.minY - list.adjustedContentInset.top, animated: true)
    }

    private func noteReading(_ geometry: TranscriptGeometry) {
        let growing = presentation.growing
        guard !growing.isEmpty else { return }
        var reading: Set<String> = []
        if !store.follow.isFollowing {
            let top = geometry.offsetY + geometry.insetTop
            let bottom = top + geometry.viewportHeight
            let foldLine = MessageFoldMeasure.lineHeight(dynamicTypeSize) * CGFloat(MessageFold.foldedLines)
            for id in growing {
                guard let frame = rowFrame(id), max(frame.minY + foldLine, top) < min(frame.maxY, bottom) else { continue }
                reading.insert(id)
            }
        }
        MessageFoldStore.session.readerSees(reading, among: growing)
    }

    // MARK: In-chat and routed search

    private func showSearchMatch(_ rowID: String) {
        stopPlacement()
        guard store.snapshot.rows.contains(where: { $0.id == rowID }) else { return }
        placement = SearchPlacement(rowID: rowID)
        resizedReadingAnchor = nil
        replyJumpID = nil
        detachOnReport = true
        traceSearch("request", rowID: rowID)
        list?.setNeedsLayout()
        scheduleReport()
    }

    private func stopPlacement() {
        guard let placement else { return }
        traceSearch("cancel", rowID: placement.rowID)
        self.placement = nil
        detachOnReport = false
        presentation.routeHighlight = nil
        placement.routed?.completion.finish()
        readingAnchor = captureAnchor()
        // While placed, reports clamp the distance from the bottom. Reconcile
        // the measured geometry with the follow policy on the next report,
        // without a full geometry report that could request a history page.
        releasePlacementOnReport = true
        scheduleReport()
    }

    private func placeSearchMatch() {
        guard motion != .user, motion != .animating, var placement, let list,
              let frame = rowFrame(placement.rowID) else { return }
        let desired = searchOffset(frame, in: list)
        let animate = placement.animate
        placement.animate = false
        self.placement = placement
        if animate { traceSearch("scroll", rowID: placement.rowID) }
        setOffset(desired, animated: animate)
    }

    private func searchOffset(_ frame: CGRect, in list: TranscriptList) -> CGFloat {
        frame.minY - list.adjustedContentInset.top - TranscriptGeometry(list).viewportHeight * 0.3
    }

    private func confirmPlacement() {
        guard motion == .idle, let placement, let routed = placement.routed, let list,
              let indexPath = dataSource?.indexPath(for: placement.rowID),
              list.cellForItem(at: indexPath) != nil, let frame = rowFrame(placement.rowID) else { return }
        guard routed.match.isCurrent(in: store.snapshot), store.snapshot.generation == store.timelineGeneration,
              store.searchTargetEventID == routed.match.eventID else {
            stopPlacement()
            return
        }
        let visible = TranscriptGeometry(list)
        let top = visible.offsetY + visible.insetTop
        guard abs(list.contentOffset.y - searchOffset(frame, in: list)) <= 2
                || ((visible.distanceFromBottom <= 0.5 || visible.distanceFromTop <= 0.5)
                    && frame.minY >= top && frame.minY < top + visible.viewportHeight) else { return }
        if case .enqueued = routed.completion.yield(()) {
            traceSearch("placed", rowID: placement.rowID)
            self.placement?.routed = nil
            store.searchTargetEventID = nil
            routed.completion.finish()
        }
    }

    private func focusRoutedMessage(_ eventID: String) async {
        let answer = await ChatHistorySearch.find(eventID: eventID, snapshot: { self.store.snapshot },
                                                  timelineGeneration: { self.store.timelineGeneration }, loadPage: {
            guard self.store.searchTargetEventID == eventID else { return .failed }
            return await self.store.loadOlderPageForSearch()
        }, placeMatch: { try await self.placeRoutedMatch($0) })
        guard answer.phase != .found, !Task.isCancelled, store.searchTargetEventID == eventID else { return }
        store.searchTargetEventID = nil
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func placeRoutedMatch(_ match: ChatHistorySearch.RoutedMatch) async throws -> Bool {
        guard !Task.isCancelled, store.searchTargetEventID == match.eventID,
              match.isCurrent(in: store.snapshot), store.snapshot.generation == store.timelineGeneration else { return false }
        showSearchMatch(match.rowID)
        defer {
            if placement?.routed?.match == match { stopPlacement() }
        }
        return try await ChatHistorySearch.waitForRoutedPlacement { completion in
            placement?.routed = (match, completion)
            presentation.routeHighlight = match.rowID
        }
    }

    // MARK: Announcements and local diagnostics

    private func announceIncoming(after previous: Snapshot) {
        guard voiceOver, store.follow.isFollowing, let theme = presentation.environment.chatTheme,
              let latestID = snapshot.rows.last(where: \.isLatest)?.id,
              let previousID = previous.rows.last(where: \.isLatest)?.id, latestID != previousID,
              let start = snapshot.rows.firstIndex(where: { $0.id == previousID }) else { return }
        switch snapshot.change {
        case .appendedAtEnd:
            break
        case let .mixed(appended, _) where appended > 0:
            break
        default:
            return
        }
        for row in snapshot.rows[(start + 1)...] where row.item.countsAsNewMessage {
            let text = theme.copy.text(.incomingAnnouncement,
                                       .text(ChatRowText.senderName(row, roomTitle: store.title, copy: theme.copy)),
                                       .text(ChatRowText.spokenBody(row, copy: theme.copy)))
            AccessibilityNotification.Announcement(text).post()
        }
    }

    private func markMemory(_ label: String) {
        #if DEBUG
        ProbeLog.markMemoryFootprint(label: label)
        #endif
    }

    private func traceAnchor(_ anchor: Anchor?) {
        #if DEBUG
        if let anchor { UITestProbe.append("held row=\(anchor.id)", to: "geometry.txt") }
        #endif
    }

    private func traceSearch(_ event: String, rowID: String) {
        #if DEBUG
        if UITestProbe.folder != nil {
            UITestProbe.append("search.\(event) row=\(rowID)", to: "search-placement.txt")
        }
        #endif
    }

    private func traceKeyboardPull(_ event: String) {
        #if DEBUG
        if UITestProbe.folder != nil { UITestProbe.append(event, to: "keyboard-pull.txt") }
        #endif
    }

    private func traceHold(_ anchor: Anchor, before: CGFloat, desired: CGFloat, target: CGFloat, after: CGFloat) {
        #if DEBUG
        guard UITestProbe.folder != nil else { return }
        // A disappearing loading row at the start can place the ideal
        // offset above the content. Record the clamp separately from a
        // correction UIKit could perform.
        if abs(target - desired) > 0.5 {
            UITestProbe.append(String(format: "boundary row=%@ desired=%.1f limit=%.1f", anchor.id, desired, target),
                               to: "geometry.txt")
        }
        let shift = target - before
        guard abs(shift) > 0.5 else { return }
        traceAnchor(anchor)
        let residual = after - target
        UITestProbe.append(String(format: "hold moving=%d shift=%.1f residual=%.1f motion=0.0 kept=%d",
                                  motion == .user ? 1 : 0, shift, residual, abs(residual) <= 4 ? 1 : 0),
                           to: "holds.txt")
        #endif
    }
}

private struct TranscriptGeometry: Equatable {
    let offsetY: Double
    let insetTop: Double
    let viewportHeight: Double
    let distanceFromTop: Double
    let distanceFromBottom: Double

    @MainActor
    init(_ list: UICollectionView) {
        let insets = list.adjustedContentInset
        offsetY = Self.half(list.contentOffset.y)
        insetTop = Self.half(insets.top)
        viewportHeight = Self.half(max(0, list.bounds.height - insets.top - insets.bottom))
        distanceFromTop = Self.half(list.contentOffset.y + insets.top)
        distanceFromBottom = Self.half(list.contentSize.height - list.contentOffset.y - list.bounds.height + insets.bottom)
    }

    static func half(_ value: CGFloat) -> Double { (Double(value) * 2).rounded() / 2 }
}

/// A tap on the transcript resigns the composer's first responder, while
/// the touched row's buttons, links and long presses receive their touches.
private enum TranscriptKeyboardDismissal {
    @MainActor static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    struct Tap: UIGestureRecognizerRepresentable {
        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                   shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        }

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
}
