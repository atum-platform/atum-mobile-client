import AtumChat
import AtumNativeAPI
import SwiftUI

// TS-6b: Team Space threads on the phone.
//
// - A channel's (or conversation's) thread panel, opened from its "…" menu
//   ("Open threads") or a message's "Reply in thread": the desktop's
//   `MatrixThreadPanel`, a sheet with Recent / Following / Unread and the list,
//   then one thread (`MatrixThreadDetail`): the root and its replies in the
//   chat's own transcript, the composer replying in the thread, and the
//   Follow capsule in the header.
// - Team Space's Threads row and its company-wide list (`CompanyThreadsView`):
//   Recent / Following / Unread, the room, the root, replies and last reply,
//   Mark read and Follow; a row opens its room with the thread on top.

/// One open panel: a room, and the thread to show (nil: the room's list).
struct CompanyThreadRoute: Identifiable, Equatable, Hashable, Sendable {
    let roomID: String
    let rootID: String?
    var id: String { roomID + "\u{0}" + (rootID ?? "") }
}

/// A company thread with the place it lives, as the company list draws it.
struct CompanyThreadListRow: Identifiable, Equatable {
    let thread: CompanyThread
    let roomName: String
    let isChannel: Bool
    var id: String { thread.id }
}

/// Team Space's Threads row: read the company's threads, follow, mark read, open one.
struct CompanyThreadsActions {
    let load: (String) async -> [CompanyThreadListRow]?
    let follow: (CompanyThread, Bool) async -> Bool
    let markRead: (CompanyThread) async -> Bool
    /// Opens the room (ID) with the thread (root ID) on top.
    let open: (String, String) -> Void
}

/// The app's one thread panel and the thread composers' drafts (in memory,
/// keyed by room and root, as the desktop keys `room#root`).
@MainActor
@Observable
final class CompanyThreadsCoordinator {
    /// The panel on screen, over its room's chat.
    var panel: CompanyThreadRoute?
    /// A thread the company list opened: shown once its room's chat is up.
    var pending: CompanyThreadRoute?
    @ObservationIgnored var drafts = [String: String]()

    func open(roomID: String, rootID: String?) {
        panel = CompanyThreadRoute(roomID: roomID, rootID: rootID)
    }
}

/// Hangs the room's thread panel on its chat (used by `AppRoot.chatHost`).
struct CompanyThreadPanelHost: ViewModifier {
    let model: LiveAppModel
    let design: LiveDesign
    let coordinator: CompanyThreadsCoordinator
    let roomID: String

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { coordinator.panel?.roomID == roomID ? coordinator.panel : nil },
                set: { coordinator.panel = $0 })) { route in
                CompanyThreadPanel(model: model, design: design, coordinator: coordinator, route: route)
                    .atumDesign(design)
            }
            // The company list asked for this room's thread: once the pushed chat
            // has settled, the panel opens on it (a sheet cannot present mid-push).
            .task(id: coordinator.pending) {
                guard let pending = coordinator.pending, pending.roomID == roomID else { return }
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, coordinator.pending == pending else { return }
                coordinator.pending = nil
                coordinator.panel = pending
            }
    }
}

// MARK: Chat header for a thread

/// What `ChatScreen` draws for a thread: "Thread" with its place under it,
/// the Follow capsule, and the composer's "Reply".
struct ChatThreadChrome {
    let title: String
    let place: String
    let composerPlaceholder: String
    let followed: Bool
    let followPending: Bool
    /// The capsule's word: "Following" or "Follow" (desktop `data-matrix-thread-follow`).
    let followText: String
    /// What a tap does: "Unfollow" or "Follow" (the desktop's tooltip).
    let followHint: String
    let toggleFollow: () -> Void
}

struct ChatThreadTitle: View {
    let design: LiveDesign
    let chrome: ChatThreadChrome

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: chrome.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(verbatim: chrome.place)
                .font(.caption)
                .foregroundStyle(AtumVisualSystem(design: design).color(.muted, scheme: scheme))
                .lineLimit(1)
                .accessibilityIdentifier("chat.thread.place")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("chat.thread.title")
        .accessibilityShowsLargeContentViewer {
            Text(verbatim: chrome.title + "\n" + chrome.place)
        }
    }
}

struct ChatThreadFollowButton: View {
    let chrome: ChatThreadChrome

    var body: some View {
        Button(action: chrome.toggleFollow) {
            Text(verbatim: chrome.followText)
                .font(.subheadline.weight(chrome.followed ? .semibold : .regular))
                .lineLimit(1)
        }
        .disabled(chrome.followPending)
        .accessibilityHint(Text(verbatim: chrome.followHint))
        .accessibilityIdentifier(chrome.followed ? "chat.thread.following" : "chat.thread.follow")
    }
}

// MARK: The room's thread panel (desktop `MatrixThreadPanel`)

struct CompanyThreadPanel: View {
    let model: LiveAppModel
    let design: LiveDesign
    let coordinator: CompanyThreadsCoordinator
    let route: CompanyThreadRoute

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var threads: [CompanyThread]?
    @State private var failed = false
    @State private var filter = CompanyThreadFilter.recent

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: CompanyThreadsCopy { CompanyThreadsCopy(design: design) }

    var body: some View {
        NavigationStack {
            Group {
                if let rootID = route.rootID {
                    // Opened on one thread (a message's "Reply in thread", the company
                    // list): no way back to a list it never showed (desktop `fromList`).
                    detail(rootID: rootID, fromList: false)
                        .toolbar { closeItem }
                } else {
                    list.toolbar { closeItem }
                }
            }
            .navigationDestination(for: String.self) { rootID in
                detail(rootID: rootID, fromList: true)
            }
        }
        .accessibilityIdentifier("chat.threads.panel")
    }

    private var closeItem: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button { dismiss() } label: { atum.barIcon(.close) }
                .accessibilityLabel(Text(verbatim: copy.closeThreads))
                .accessibilityIdentifier("chat.threads.close")
        }
    }

    private func detail(rootID: String, fromList: Bool) -> some View {
        CompanyThreadDetail(model: model, design: design, coordinator: coordinator, roomID: route.roomID,
                            rootID: rootID,
                            initialFollowed: threads?.first(where: { $0.root.eventID == rootID })?.followed ?? false,
                            fromList: fromList)
    }

    private var list: some View {
        let shown = CompanyThreads.filter(threads ?? [], by: filter)
        return List {
            Section {
                Picker(selection: $filter) {
                    ForEach(CompanyThreadFilter.allCases, id: \.self) { item in
                        Text(verbatim: copy.panelFilter(item)).tag(item)
                    }
                } label: {
                    Text(verbatim: copy.threads)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("chat.threads.filter")
            }
            if let threads, shown.isEmpty, !failed {
                Text(verbatim: threads.isEmpty ? copy.noThreads : copy.noFilteredThreads)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .multilineTextAlignment(.center)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("chat.threads.empty")
            }
            ForEach(shown) { thread in
                NavigationLink(value: thread.root.eventID) { panelRow(thread) }
                    .listRowBackground(atum.color(.cell, scheme: scheme))
                    .accessibilityIdentifier("chat.threads.row." + thread.root.eventID)
            }
        }
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .overlay { if threads == nil, !failed { ProgressView() } }
        .navigationTitle(copy.threads)
        .navigationBarTitleDisplayMode(.inline)
        // Every return to the list reads again: a thread just read or answered changes.
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func panelRow(_ thread: CompanyThread) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: thread.root.body.isEmpty ? "…" : thread.root.body)
                .font(.subheadline)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(verbatim: copy.panelReplies(thread.replyCount))
                Text(verbatim: "·").accessibilityHidden(true)
                Text(Date(timeIntervalSince1970: TimeInterval(thread.lastActivityAt) / 1000),
                     format: .dateTime.day().month(.abbreviated).year())
                if thread.highlights > 0 {
                    Text(verbatim: "@" + thread.highlights.formatted())
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .foregroundStyle(atum.color(.onInk, scheme: scheme))
                        .background(Capsule().fill(atum.color(.ink, scheme: scheme)))
                }
                Spacer(minLength: 0)
                if thread.unread {
                    Circle()
                        .fill(atum.color(.ink, scheme: scheme))
                        .frame(width: 8, height: 8)
                        .accessibilityLabel(Text(verbatim: copy.unread))
                }
            }
            .font(.caption)
            .foregroundStyle(atum.color(.muted, scheme: scheme))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func reload() async {
        let read = await model.roomThreads(roomID: route.roomID)
        guard !Task.isCancelled else { return }
        if let read {
            threads = read
            failed = false
        } else if threads == nil {
            failed = true
        }
    }
}

// MARK: One thread (desktop `MatrixThreadDetail`)

struct CompanyThreadDetail: View {
    let model: LiveAppModel
    let design: LiveDesign
    let coordinator: CompanyThreadsCoordinator
    let roomID: String
    let rootID: String
    let fromList: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var store: LiveConversationStore?
    @State private var available: Bool?
    @State private var followed: Bool
    @State private var followPending = false
    @State private var followFailed = 0

    init(model: LiveAppModel, design: LiveDesign, coordinator: CompanyThreadsCoordinator, roomID: String,
         rootID: String, initialFollowed: Bool, fromList: Bool) {
        self.model = model
        self.design = design
        self.coordinator = coordinator
        self.roomID = roomID
        self.rootID = rootID
        self.fromList = fromList
        _followed = State(initialValue: initialFollowed)
    }

    private var copy: CompanyThreadsCopy { CompanyThreadsCopy(design: design) }
    private var draftKey: String { roomID + "#" + rootID }

    /// The session the thread's timeline lives on: a renewal replaces it.
    private struct SessionKey: Equatable {
        let session: ObjectIdentifier?
        let ready: Bool
    }

    private var sessionKey: SessionKey {
        SessionKey(session: model.liveMatrix.map { ObjectIdentifier($0) }, ready: model.liveMatrix?.isReady == true)
    }

    var body: some View {
        Group {
            if available == false {
                unavailable
            } else if let store {
                ChatScreen(store: store, design: design, teamSpaceChat: true,
                           mediaAccess: mediaAccess,
                           loadMatrixThumbnail: { uri, side in await model.avatarThumbnail(uri: uri, pixelSide: side) },
                           thread: chrome)
            } else {
                ProgressView()
            }
        }
        .task(id: sessionKey) { await attach() }
        .task {
            guard available == nil else { return }
            available = await model.companyThreadRootAvailable(roomID: roomID, rootID: rootID)
        }
        .onDisappear { close() }
        .sensoryFeedback(.error, trigger: followFailed)
    }

    private var chrome: ChatThreadChrome {
        ChatThreadChrome(title: copy.thread, place: model.companyThreadPlace(roomID: roomID) ?? "",
                         composerPlaceholder: copy.reply, followed: followed, followPending: followPending,
                         followText: followed ? copy.following : copy.follow,
                         followHint: followed ? copy.unfollow : copy.follow,
                         toggleFollow: toggleFollow)
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Text(verbatim: copy.threadUnavailable)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(AtumVisualSystem(design: design).color(.muted, scheme: scheme))
            if fromList {
                Button(copy.backToThreads) { dismiss() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("chat.thread.back")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("chat.thread.unavailable")
    }

    private var mediaAccess: ChatMediaAccess {
        ChatMediaAccess(
            thumbnail: { media, width, height in
                await model.mediaThumbnail(sourceHandle: media.thumbnailSourceHandle ?? media.sourceHandle,
                                           pixelWidth: width, pixelHeight: height)
            },
            content: { media in await model.mediaContent(sourceHandle: media.sourceHandle) },
            file: { media in
                await model.mediaFile(sourceHandle: media.sourceHandle, filename: media.filename,
                                      mimetype: media.mimetype ?? "application/octet-stream")
            },
            uploadLimit: { await model.maximumMediaUploadSize() })
    }

    /// Builds the thread's store once, then (re)attaches it to each ready session.
    private func attach() async {
        if store == nil {
            store = model.companyThreadStore(roomID: roomID, rootID: rootID,
                                             draft: coordinator.drafts[draftKey] ?? "")
        }
        guard let store else { return }
        guard let session = model.liveMatrix, session.isReady, let room = try? session.room(id: roomID) else {
            store.detach()
            return
        }
        await store.attach(room: room)
    }

    private func close() {
        guard let store else { return }
        coordinator.drafts[draftKey] = store.draft
        store.close()
        self.store = nil
    }

    private func toggleFollow() {
        let next = !followed
        followPending = true
        Task { @MainActor in
            if await model.setCompanyThreadFollow(roomID: roomID, rootID: rootID, followed: next) {
                followed = next
            } else {
                followFailed &+= 1
            }
            followPending = false
        }
    }
}

// MARK: Team Space Threads (desktop `CompanyThreadsView`)

struct TeamSpaceThreadsSheet: View {
    let design: LiveDesign
    let rows: [CompanyThreadListRow]?
    let isLoading: Bool
    let reload: () async -> Void
    let follow: (CompanyThread, Bool) async -> Bool
    let markRead: (CompanyThread) async -> Bool
    let open: (CompanyThreadListRow) -> Void
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var filter = CompanyThreadFilter.recent
    @State private var visible = CompanyThreads.pageSize
    @State private var pending = Set<String>()
    @State private var failed = false
    @State private var overrides = [String: CompanyThreadOverride]()

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: CompanyThreadsCopy { CompanyThreadsCopy(design: design) }

    private var shownRows: [CompanyThreadListRow] {
        (rows ?? []).map { row in
            CompanyThreadListRow(thread: overrides[row.id]?.applied(to: row.thread) ?? row.thread,
                                 roomName: row.roomName, isChannel: row.isChannel)
        }
    }

    private var filtered: [CompanyThreadListRow] {
        let keep = Set(CompanyThreads.filter(shownRows.map(\.thread), by: filter).map(\.id))
        return shownRows.filter { keep.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker(selection: $filter) {
                        ForEach(CompanyThreadFilter.allCases, id: \.self) { item in
                            Text(verbatim: copy.companyFilter(item)).tag(item)
                        }
                    } label: {
                        Text(verbatim: copy.filterLabel)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("company.threads.filter")
                }
                if failed {
                    Text(verbatim: copy.actionFailed)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("company.threads.failed")
                }
                if rows != nil, filtered.isEmpty {
                    empty.listRowBackground(Color.clear)
                } else {
                    ForEach(filtered.prefix(visible)) { row in
                        threadRow(row).listRowBackground(atum.color(.cell, scheme: scheme))
                    }
                    if visible < filtered.count {
                        Button(copy.loadMore) { visible += CompanyThreads.pageSize }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .listRowBackground(Color.clear)
                            .accessibilityIdentifier("company.threads.more")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
            .overlay { if rows == nil, isLoading { ProgressView() } }
            .refreshable { await reload() }
            .onChange(of: filter) { _, _ in visible = CompanyThreads.pageSize }
            // Once sync catches up the row stops owning the field (desktop overrides effect).
            .onChange(of: rows) { _, value in
                overrides = CompanyThreadOverride.reconcile(overrides, with: (value ?? []).map(\.thread))
            }
            .navigationTitle(copy.companyTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { atum.barIcon(.close) }
                        .accessibilityLabel(design.text("desktop.common.close"))
                        .accessibilityIdentifier("company.threads.close")
                }
            }
        }
        .accessibilityIdentifier("company.threads")
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Text(verbatim: copy.emptyTitle(filter)).font(.headline)
            Text(verbatim: copy.emptyBody(filter))
                .font(.subheadline)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("company.threads.empty")
    }

    private func threadRow(_ row: CompanyThreadListRow) -> some View {
        let thread = row.thread
        let busy = pending.contains(row.id)
        let preview = thread.root.body.isEmpty ? copy.noPreview : thread.root.body
        return HStack(alignment: .center, spacing: 8) {
            Button { open(row) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(atum.symbol(row.isChannel ? .hash : .messageCircle))
                            .font(.caption)
                            .accessibilityHidden(true)
                        Text(verbatim: row.roomName.hasPrefix("# ") ? String(row.roomName.dropFirst(2)) : row.roomName)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if thread.unread {
                            Circle()
                                .fill(atum.color(.ink, scheme: scheme))
                                .frame(width: 8, height: 8)
                                .accessibilityLabel(Text(verbatim: copy.companyUnread))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    Text(verbatim: preview)
                        .font(.body)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        faces(thread)
                        Text(verbatim: copy.companyReplies(thread.replyCount))
                        Text(verbatim: "·").accessibilityHidden(true)
                        Text(verbatim: copy.lastReply(ago(thread.lastActivityAt)))
                    }
                    .font(.caption)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(verbatim: copy.open(room: row.roomName) + ": " + preview))
            .accessibilityIdentifier("company.threads.row." + thread.root.eventID)
            if thread.unread {
                Button { markRowRead(row) } label: {
                    Image(atum.symbol(.checkCircle)).frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel(Text(verbatim: copy.markRead))
                .accessibilityIdentifier("company.threads.read." + thread.root.eventID)
            }
            Button { toggleRowFollow(row) } label: {
                Image(atum.symbol(thread.followed ? .bellOff : .bell)).frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityLabel(Text(verbatim: thread.followed ? copy.companyUnfollow : copy.companyFollow))
            .accessibilityIdentifier("company.threads.follow." + thread.root.eventID)
        }
        .foregroundStyle(atum.color(.soft, scheme: scheme))
    }

    @ViewBuilder private func faces(_ thread: CompanyThread) -> some View {
        HStack(spacing: -4) {
            ForEach(thread.faces, id: \.senderID) { face in
                if let name = face.senderName {
                    MatrixFace(kind: .person, name: name, matrixURI: face.senderAvatarURI, size: 18,
                               loadMatrixThumbnail: loadMatrixThumbnail)
                        .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1))
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func ago(_ milliseconds: Int64) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: design.locale)
        formatter.unitsStyle = .full
        return formatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000),
                                         relativeTo: Date())
    }

    private func markRowRead(_ row: CompanyThreadListRow) {
        let key = row.id
        let previous = row.thread.unread
        let readAt = row.thread.lastActivityAt
        failed = false
        pending.insert(key)
        overrides[key, default: CompanyThreadOverride()].unread = false
        overrides[key]?.readAt = readAt
        Task { @MainActor in
            if !(await markRead(row.thread)) {
                overrides[key, default: CompanyThreadOverride()].unread = previous
                overrides[key]?.readAt = readAt
                failed = true
            }
            pending.remove(key)
        }
    }

    private func toggleRowFollow(_ row: CompanyThreadListRow) {
        let key = row.id
        let previous = row.thread.followed
        failed = false
        pending.insert(key)
        overrides[key, default: CompanyThreadOverride()].followed = !previous
        Task { @MainActor in
            if !(await follow(row.thread, !previous)) {
                overrides[key, default: CompanyThreadOverride()].followed = previous
                failed = true
            }
            pending.remove(key)
        }
    }
}
