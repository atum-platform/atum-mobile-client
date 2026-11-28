import AtumChat
import AtumNativeAPI
import Observation
import SwiftUI

// Chat parity S4/S5 presentation state for the one open person or group
// chat: the room's native thread list (root summaries, the details preview,
// the pushed list) and its shared pins (menu state, the pinned page). It
// follows the engine contract in docs/implementation/chat-parity-ml1-threads-pins.md
// ("Opus integration contract"): one `RoomThreadList` and one `RoomPins` per
// open room, re-read on SDK signals, closed on room exit, account or session
// replacement and loss of eligibility.

/// What is pushed over an eligible group chat (M2: the thread and the list
/// are pushed screens, not sheets).
enum GroupThreadDestination: Hashable, Identifiable {
    case thread(roomID: String, rootID: String, focusEventID: String?)
    case list(roomID: String)

    var id: Self { self }

    var roomID: String {
        switch self {
        case let .thread(roomID, _, _), let .list(roomID): roomID
        }
    }
}

/// A pin write the chat or the pinned page reports once (S5 recoverable
/// categories). `awaitingSync` and `unavailable` are not reported: the
/// snapshot already disables the action or the chat is closing.
struct PinWriteNotice: Identifiable, Equatable {
    let id = UUID()
    let failure: RoomPinFailure
}

/// The live reads behind one open chat. Owned by `GroupThreadsCoordinator`;
/// it outlives the chat being covered by its own pushed thread.
@MainActor
@Observable
final class GroupRoomLive {
    struct Key: Equatable, Sendable {
        let roomID: String
        let session: ObjectIdentifier
        let scope: MessageMenuRules.SharedChatActions
    }

    let key: Key
    var roomID: String { key.roomID }
    var offersThreads: Bool { key.scope == .peopleGroup }

    /// Newest activity first, with unread and follow from the last full read.
    private(set) var threads: [CompanyThread]?
    /// A load error, distinct from a successful empty list.
    private(set) var threadsFailed = false
    private(set) var canLoadMoreThreads = false
    private(set) var loadingMoreThreads = false

    private(set) var pins: RoomPinSnapshot?
    private(set) var pinsFailed = false
    /// The pinned page's rows for `pinRowsSnapshot`; replaced after a newer snapshot.
    private(set) var pinRows: [CompanyPinnedRow]?
    private(set) var pinRowsSnapshot: RoomPinSnapshot?
    private(set) var pinRowsFailed = false
    /// Event IDs this phone is writing now.
    private(set) var pinWrites = Set<String>()
    var pinNotice: PinWriteNotice?

    @ObservationIgnored private let list: RoomThreadList?
    @ObservationIgnored private let pinReader: RoomPins?
    @ObservationIgnored nonisolated(unsafe) private var runners: [Task<Void, Never>] = []
    @ObservationIgnored private var fullReadGeneration = 0
    @ObservationIgnored private var receiptReadGeneration = 0
    private var transcriptRoots = [String: CompanyThread]()
    private var transcriptUnread = [String: Bool]()

    init(key: Key, list: RoomThreadList?, pins: RoomPins?) {
        self.key = key
        self.list = list
        pinReader = pins
    }

    deinit { runners.forEach { $0.cancel() } }

    var isRunning: Bool { !runners.isEmpty }

    /// One main-actor reader per SDK signal stream; both stop together.
    func start() {
        guard runners.isEmpty else { return }
        if let list {
            runners.append(Task { @MainActor [weak self] in await self?.followThreads(list) })
        }
        if let pinReader {
            runners.append(Task { @MainActor [weak self] in await self?.followPins(pinReader) })
        }
    }

    func stop() {
        runners.forEach { $0.cancel() }
        runners = []
    }

    #if DEBUG
    fileprivate func seed(threads: [CompanyThread], pins: RoomPinSnapshot, pinRows: [CompanyPinnedRow]) {
        self.threads = threads
        self.pins = pins
        self.pinRows = pinRows
        pinRowsSnapshot = pins
    }
    #endif

    // MARK: Threads

    /// Root summaries keyed by event ID. The transcript can supply roots
    /// that the separate paged list has never fetched.
    var summaries: [String: CompanyThread] {
        guard offersThreads else { return [:] }
        var result = Dictionary((threads ?? []).map { ($0.root.eventID, $0) },
                                uniquingKeysWith: { first, _ in first })
        for (id, root) in transcriptRoots {
            let listEntry = result[id]
            let listed = listEntry.flatMap { listed -> CompanyThread? in
                if let latest = root.latest { return listed.latest?.eventID == latest.eventID ? listed : nil }
                return listed.replyCount == root.replyCount ? listed : nil
            }
            result[id] = CompanyThread(roomID: roomID, root: root.root,
                                       latest: root.latest ?? listed?.latest,
                                       replyCount: root.replyCount,
                                       unread: transcriptUnread[id] ?? listed?.unread ?? false,
                                       highlights: listed?.highlights ?? 0,
                                       followed: listEntry?.followed ?? false)
        }
        return result
    }

    static func transcriptRoots(in rows: [ChatRow], roomID: String, ownUserID: String) -> [String: CompanyThread] {
        var roots = [String: CompanyThread]()
        for row in rows {
            let item = row.item
            guard let summary = item.threadSummary, let id = item.eventID, item.threadRoot == nil else { continue }
            let root = CompanyThreadMessage(eventID: id, senderID: item.sender, senderName: item.senderName,
                                            senderAvatarURI: item.senderAvatarURI, isOwn: item.isOwn,
                                            body: item.body, sentAt: Int64(item.timestamp.timeIntervalSince1970 * 1000))
            let latest = summary.latest.map {
                CompanyThreadMessage(eventID: $0.eventID, senderID: $0.senderID, senderName: $0.senderName,
                                     senderAvatarURI: $0.senderAvatarURI, isOwn: $0.senderID == ownUserID,
                                     body: "", sentAt: Int64(clamping: $0.timestamp))
            }
            roots[id] = CompanyThread(roomID: roomID, root: root, latest: latest, replyCount: summary.replyCount)
        }
        return roots
    }

    func updateTranscriptRoots(_ roots: [String: CompanyThread]) async {
        transcriptUnread = transcriptUnread.filter { id, _ in
            transcriptRoots[id]?.latest?.eventID == roots[id]?.latest?.eventID && roots[id] != nil
        }
        transcriptRoots = roots
        await refreshTranscriptUnread()
    }

    private func refreshTranscriptUnread() async {
        guard let list else { return }
        receiptReadGeneration &+= 1
        let generation = receiptReadGeneration
        let unread = await list.transcriptUnread(transcriptRoots)
        guard !Task.isCancelled, generation == receiptReadGeneration else { return }
        transcriptUnread = unread
    }

    /// M2 details: the three newest, then All threads.
    var preview: [CompanyThread] { Array((threads ?? []).prefix(3)) }

    private func followThreads(_ list: RoomThreadList) async {
        do {
            try await list.paginate()
        } catch {
            guard !Task.isCancelled else { return }
            if threads == nil { threadsFailed = true }
        }
        await refreshThreads()
        for await _ in list.updates() {
            guard !Task.isCancelled else { return }
            applyRoots(from: list)
            await refreshTranscriptUnread()
        }
    }

    /// A native summary change: counts and latest replies update at once,
    /// keeping the unread and follow projection of the last full read.
    private func applyRoots(from list: RoomThreadList) {
        guard let roots = list.roots() else { return }
        let known = Dictionary((threads ?? []).map { ($0.root.eventID, $0) }, uniquingKeysWith: { first, _ in first })
        let next = roots.compactMap { entry -> CompanyThread? in
            guard CompanyThreadAttention.isRootID(entry.root.eventID) else { return nil }
            let prior = known[entry.root.eventID]
            let newer = prior.map { (entry.latest?.eventID ?? entry.root.eventID)
                != ($0.latest?.eventID ?? $0.root.eventID) } ?? true
            return CompanyThread(roomID: roomID, root: entry.root, latest: entry.latest,
                                 replyCount: entry.replyCount,
                                 // A newer reply from someone else is unread until the next full read.
                                 unread: (prior?.unread ?? false) || (newer && prior != nil && entry.latest?.isOwn == false),
                                 highlights: prior?.highlights ?? 0, followed: prior?.followed ?? false)
        }
        threads = CompanyThreads.sorted(next)
        threadsFailed = false
        canLoadMoreThreads = list.canPaginate
    }

    /// The full projection with unread and follow (list open, return from a
    /// thread, pull to refresh, after follow or mark read).
    func refreshThreads() async {
        guard let list else { return }
        fullReadGeneration &+= 1
        let generation = fullReadGeneration
        await refreshTranscriptUnread()
        let read = await list.threads()
        guard !Task.isCancelled, generation == fullReadGeneration else { return }
        if let read {
            threads = read
            threadsFailed = false
        } else if threads == nil {
            threadsFailed = true
        }
        canLoadMoreThreads = list.canPaginate
    }

    func retryThreads() async {
        guard let list else { return }
        threadsFailed = false
        do { try await list.paginate() } catch {}
        await refreshThreads()
    }

    func loadMoreThreads() async {
        guard let list, list.canPaginate, !loadingMoreThreads else { return }
        loadingMoreThreads = true
        defer { loadingMoreThreads = false }
        do {
            try await list.paginate()
            applyRoots(from: list)
        } catch {
            canLoadMoreThreads = false
        }
    }

    // MARK: Pins

    /// The menu's view of the pins, nil while the first snapshot is unread.
    var pinMenu: PinMenuContext? {
        guard let pins else { return nil }
        return PinMenuContext(scope: key.scope, pinnedEventIDs: Set(pins.eventIDs), canChange: pins.canChange,
                              awaitingSync: pins.awaitingSync || !pinWrites.isEmpty)
    }

    private func followPins(_ reader: RoomPins) async {
        await refreshPins(reader)
        for await _ in reader.updates() {
            guard !Task.isCancelled else { return }
            await refreshPins(reader)
        }
    }

    private func refreshPins(_ reader: RoomPins) async {
        do {
            let snapshot = try await reader.snapshot()
            guard !Task.isCancelled else { return }
            pins = snapshot
            pinsFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            if pins == nil { pinsFailed = true }
        }
    }

    /// Hydrates the pinned page for the current snapshot. A result for an
    /// older snapshot is dropped, never shown over a newer list.
    func loadPinRows() async {
        guard let pinReader else { return }
        if pins == nil { await refreshPins(pinReader) }
        guard let snapshot = pins else {
            pinRowsFailed = true
            return
        }
        do {
            let rows = try await pinReader.entries(for: snapshot)
            guard !Task.isCancelled, pins == snapshot else { return }
            pinRows = rows
            pinRowsSnapshot = snapshot
            pinRowsFailed = false
        } catch {
            guard !Task.isCancelled else { return }
            if pinRows == nil { pinRowsFailed = true }
        }
    }

    /// One pin intent. The SDK re-reads power and state; a refused write is
    /// reported once and the next snapshot decides what the UI offers.
    func setPinned(_ pinned: Bool, eventID: String) {
        guard let pinReader, !pinWrites.contains(eventID) else { return }
        pinWrites.insert(eventID)
        Task { @MainActor [weak self] in
            do {
                try await pinReader.setPinned(pinned, eventID: eventID)
            } catch let failure as RoomPinFailure {
                switch failure {
                case .awaitingSync, .unavailable: break
                default: self?.pinNotice = PinWriteNotice(failure: failure)
                }
            } catch {
                self?.pinNotice = PinWriteNotice(failure: .failed)
            }
            guard let self else { return }
            pinWrites.remove(eventID)
            await refreshPins(pinReader)
        }
    }
}

#if DEBUG
extension GroupRoomLive {
    /// `-AtumScriptedGroupThreads` only: a reader with fixed rows and no SDK,
    /// for scripted simulator captures of the M2 states.
    static func capture(roomID: String, threads: [CompanyThread], pins: RoomPinSnapshot,
                        pinRows: [CompanyPinnedRow]) -> GroupRoomLive {
        let live = GroupRoomLive(key: Key(roomID: roomID, session: ObjectIdentifier(GroupRoomLive.self),
                                          scope: .peopleGroup), list: nil, pins: nil)
        live.seed(threads: threads, pins: pins, pinRows: pinRows)
        return live
    }
}
#endif

/// The app's one group-thread navigator and live-read owner (beside
/// `CompanyThreadsCoordinator`, which keeps Team Space's sheet panel).
@MainActor
@Observable
final class GroupThreadsCoordinator {
    /// The screen pushed over the open chat, if any.
    private(set) var destination: GroupThreadDestination?

    /// The navigation binding's write: a pop to the chat or further.
    func setDestination(_ next: GroupThreadDestination?) {
        destination = next
        if next == nil { releaseOrphan() }
    }
    private(set) var live: GroupRoomLive?
    /// Thread composers' drafts, in memory, keyed `room#root` like desktop.
    @ObservationIgnored var drafts = [String: String]()
    /// Whether a chat for this room is still the app's open conversation.
    @ObservationIgnored var isOpenRoom: (String) -> Bool = { _ in false }

    /// Shows a pinned main-timeline message in the open chat (set by the host).
    @ObservationIgnored var focusMainEvent: (String, String) -> Void = { _, _ in }

    func live(for roomID: String) -> GroupRoomLive? {
        live?.roomID == roomID ? live : nil
    }

    /// The details sheet's Threads section; nil outside eligible groups.
    func panelThreads(roomID: String) -> GroupThreadsPanelActions? {
        guard let live = live(for: roomID), live.offersThreads else { return nil }
        return GroupThreadsPanelActions(live: live) { [weak self] rootID in
            self?.openAfterPanel(rootID.map { .thread(roomID: roomID, rootID: $0, focusEventID: nil) }
                ?? .list(roomID: roomID))
        }
    }

    /// The details sheet's Pinned messages row and page; nil without pins.
    func panelPins(roomID: String) -> RoomPinsPanelActions? {
        guard let live = live(for: roomID), live.pins != nil || live.pinsFailed else { return nil }
        return RoomPinsPanelActions(live: live) { [weak self] row in
            guard let self else { return }
            if let rootID = row.summary?.threadRootID, live.offersThreads {
                openAfterPanel(.thread(roomID: roomID, rootID: rootID, focusEventID: row.eventID))
            } else {
                let focus = focusMainEvent
                Task { @MainActor in
                    try? await Task.sleep(for: Self.panelDismissal)
                    focus(roomID, row.eventID)
                }
            }
        }
    }

    /// A push cannot start while the details sheet is still going away.
    private static let panelDismissal = Duration.milliseconds(450)

    private func openAfterPanel(_ destination: GroupThreadDestination) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.panelDismissal)
            self?.open(destination)
        }
    }

    func open(_ destination: GroupThreadDestination) {
        guard live(for: destination.roomID)?.offersThreads == true else { return }
        self.destination = destination
    }

    /// Ensures one live reader for this chat and key, replacing any other.
    func ensure(_ key: GroupRoomLive.Key, make: () -> GroupRoomLive?) {
        if let live, live.key == key {
            live.start()
            return
        }
        live?.stop()
        if destination != nil, destination?.roomID != key.roomID || key.scope != .peopleGroup {
            destination = nil
        }
        live = make()
        live?.start()
    }

    /// The chat left (or lost eligibility): close its reads and pushed screen.
    func close(roomID: String) {
        guard live?.roomID == roomID else { return }
        if destination?.roomID == roomID { destination = nil }
        live?.stop()
        live = nil
    }

    /// The chat or its pushed screen went away. Once navigation settles,
    /// close the reads unless the chat is still the open conversation (a
    /// Back from the thread to its chat) or covered by its own push.
    func closeIfLeft(roomID: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, destination?.roomID != roomID, !isOpenRoom(roomID) else { return }
            close(roomID: roomID)
        }
    }

    private func releaseOrphan() {
        guard let live else { return }
        closeIfLeft(roomID: live.roomID)
    }
}

// MARK: Environment for rows and the menu

/// The open chat's pins as the long-press menu needs them.
struct ChatPinMenu {
    let context: PinMenuContext
    let setPinned: (Bool, String) -> Void
}

/// What a message row shows under a thread root: the M2 summary in the main
/// transcript, or the "N replies" rule under the root inside its thread.
struct ChatThreadSummaries {
    enum Mode { case transcript, insideThread(rootID: String) }
    let mode: Mode
    let threads: [String: CompanyThread]
    let open: (String) -> Void
}

extension EnvironmentValues {
    @Entry var chatPinMenu: ChatPinMenu?
    @Entry var chatThreadSummaries: ChatThreadSummaries?
}

/// Hangs group threads and shared pins on an eligible personal chat (used by
/// `AppRoot.chatHost`; the only host hook). Team Space chats keep their sheet
/// panel and read-only pins; assistant, app, Notes and unknown chats get none.
struct GroupThreadsHost: ViewModifier {
    let model: LiveAppModel
    let design: LiveDesign
    let coordinator: GroupThreadsCoordinator
    let roomID: String

    private var scope: MessageMenuRules.SharedChatActions { model.sharedChatActions(roomID: roomID) }

    private struct TaskKey: Equatable {
        let session: ObjectIdentifier?
        let ready: Bool
        let scope: MessageMenuRules.SharedChatActions
    }

    private var taskKey: TaskKey {
        TaskKey(session: model.liveMatrix.map { ObjectIdentifier($0) },
                ready: model.liveMatrix?.isReady == true, scope: scope)
    }

    private struct TranscriptRead: Equatable, Sendable {
        let key: GroupRoomLive.Key
        let roots: [String: CompanyThread]
    }

    private func transcriptRead(for live: GroupRoomLive?) -> TranscriptRead? {
        guard let live, live.offersThreads, let store = model.conversation, store.roomID == roomID else { return nil }
        return TranscriptRead(key: live.key, roots: GroupRoomLive.transcriptRoots(
            in: store.snapshot.rows, roomID: roomID, ownUserID: store.ownUserID))
    }

    func body(content: Content) -> some View {
        let live = coordinator.live(for: roomID)
        let transcriptRead = transcriptRead(for: live)
        content
            .environment(\.chatThreadSummaries, live.flatMap { live in
                live.offersThreads ? ChatThreadSummaries(mode: .transcript, threads: live.summaries) { rootID in
                    coordinator.open(.thread(roomID: roomID, rootID: rootID, focusEventID: nil))
                } : nil
            })
            .environment(\.chatPinMenu, live.flatMap { live in
                live.pinMenu.map { ChatPinMenu(context: $0) { live.setPinned($0, eventID: $1) } }
            })
            .navigationDestination(item: Binding(
                get: { coordinator.destination?.roomID == roomID ? coordinator.destination : nil },
                set: { coordinator.setDestination($0) })) { destination in
                GroupThreadDestinationView(model: model, design: design, coordinator: coordinator,
                                           destination: destination)
            }
            .alert(GroupThreadsCopy(design: design).errorGeneric,
                   isPresented: Binding(get: { live?.pinNotice != nil && coordinator.destination == nil },
                                        set: { if !$0 { live?.pinNotice = nil } })) {
                Button(GroupThreadsCopy(design: design).dismiss, role: .cancel) {}
            }
            .task(id: taskKey) { attach(taskKey) }
            .task(id: transcriptRead) {
                if let transcriptRead { await live?.updateTranscriptRoots(transcriptRead.roots) }
            }
            // Covered by its own pushed thread or list: keep reading.
            .onDisappear { coordinator.closeIfLeft(roomID: roomID) }
    }

    private func attach(_ key: TaskKey) {
        coordinator.isOpenRoom = { [weak model] roomID in model?.conversation?.roomID == roomID }
        coordinator.focusMainEvent = { [weak model] roomID, eventID in
            guard let store = model?.conversation, store.roomID == roomID else { return }
            store.searchTargetEventID = eventID
        }
        guard key.ready, let session = model.liveMatrix,
              key.scope == .peopleGroup || key.scope == .peopleDM else {
            coordinator.close(roomID: roomID)
            return
        }
        let liveKey = GroupRoomLive.Key(roomID: roomID, session: ObjectIdentifier(session), scope: key.scope)
        coordinator.ensure(liveKey) {
            let list = key.scope == .peopleGroup ? model.openGroupThreadList(roomID: roomID) : nil
            let pins = model.openRoomPins(roomID: roomID)
            guard list != nil || pins != nil else { return nil }
            return GroupRoomLive(key: liveKey, list: list, pins: pins)
        }
    }
}
