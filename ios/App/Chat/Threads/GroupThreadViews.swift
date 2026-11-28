import AtumChat
import AtumNativeAPI
import SwiftUI

// Chat parity S4 on the phone, drawn to mockup M2 (atum-desktop 22e0798a,
// docs/mockups/chat-parity-phone/m2-p-*):
// - m2-p-group: one summary capsule under a root (up to three faces,
//   "N replies", last reply time); right-aligned under my own roots.
// - m2-p-menu: "Reply in thread" under Reply (`MessageMenuRules`).
// - m2-p-thread: a pushed screen titled "Thread" with the group under it,
//   the root, a "N replies" rule, the replies in the group's bubbles and a
//   "Reply in thread" composer.
// - m2-p-list: a pushed "Threads" list of card rows (root sender's face,
//   root text, "N replies · time", unread dot).
// The details sheet shows the three newest threads and All threads.

// MARK: Pushed destinations

struct GroupThreadDestinationView: View {
    let model: LiveAppModel
    let design: LiveDesign
    let coordinator: GroupThreadsCoordinator
    let destination: GroupThreadDestination

    var body: some View {
        switch destination {
        case let .thread(roomID, rootID, focusEventID):
            GroupThreadScreen(model: model, design: design, coordinator: coordinator, roomID: roomID,
                              rootID: rootID, focusEventID: focusEventID)
        case let .list(roomID):
            GroupThreadListScreen(model: model, design: design, coordinator: coordinator, roomID: roomID)
        }
    }
}

// MARK: Root summary (m2-p-group)

/// Under a message row: the thread summary in the main transcript, or the
/// "N replies" rule under the root inside its own thread. Draws nothing
/// outside eligible groups (the environment carries no summaries there).
struct ThreadSummaryAttachment: View {
    let row: ChatRow
    /// The row's face gutter, so the capsule starts under the bubble.
    var leading: CGFloat = 0

    @Environment(\.chatThreadSummaries) private var summaries

    var body: some View {
        // Empty (no subview, no stack spacing) unless this row is a known root.
        if let summaries, let eventID = row.item.eventID, row.item.threadRoot == nil,
           let thread = summaries.threads[eventID], thread.replyCount > 0 {
            switch summaries.mode {
            case .transcript:
                ThreadSummaryCapsule(thread: thread) { summaries.open(eventID) }
                    .padding(.leading, leading)
            case let .insideThread(rootID) where rootID == eventID:
                ThreadRepliesRule(count: thread.replyCount)
            case .insideThread:
                EmptyView()
            }
        }
    }
}

struct ThreadSummaryCapsule: View {
    let thread: CompanyThread
    let open: () -> Void

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chatMembers) private var members
    @Environment(\.chatRoomFace) private var roomFace
    @ScaledMetric(relativeTo: .footnote) private var face: CGFloat = 20

    var body: some View {
        if let theme {
            let kit = theme.design.kit
            let copy = GroupThreadsCopy(design: theme.design)
            let when = GroupThreadsTime.label(Self.date(thread.lastActivityAt), locale: theme.design.locale)
            Button(action: open) {
                HStack(spacing: kit.space(.s2)) {
                    HStack(spacing: -kit.space(.s1)) {
                        ForEach(Array(faces.enumerated()), id: \.offset) { _, person in
                            ChatFaceView(face: person, size: face)
                                .overlay(Circle().stroke(kit.color(.surface, scheme: scheme), lineWidth: 1.5))
                        }
                    }
                    .accessibilityHidden(true)
                    Text(verbatim: copy.replies(thread.replyCount))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(kit.color(.ink, scheme: scheme))
                    Text(verbatim: when)
                        .font(.footnote)
                        .foregroundStyle(kit.color(.ink3, scheme: scheme))
                    if thread.unread {
                        Circle()
                            .fill(kit.color(.ink, scheme: scheme))
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, kit.space(.s1))
                .padding(.leading, kit.space(.s1))
                .padding(.trailing, kit.space(.s3))
                .background(Capsule().fill(kit.color(.surface, scheme: scheme)))
                .overlay(Capsule().stroke(kit.color(.line, scheme: scheme), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, kit.space(.s1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: [copy.replies(thread.replyCount), when,
                                                thread.unread ? copy.unread : nil]
                .compactMap { $0 }.joined(separator: ", ")))
            .accessibilityHint(Text(verbatim: copy.replyInThread))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("chat.thread.summary." + thread.root.eventID)
        }
    }

    /// The repliers the native summary names (newest reply first), then the
    /// root's sender; at most three.
    private var faces: [ChatFace] {
        var seen = Set<String>()
        return ([thread.latest, thread.root].compactMap { $0 })
            .filter { seen.insert($0.senderID).inserted }
            .prefix(3)
            .map { message in
                ChatFace.reader(ChatReader(userID: message.senderID, name: message.senderName,
                                           avatarURI: message.senderAvatarURI),
                                kind: .group, roomFace: roomFace, members: members)
            }
    }

    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(millis) / 1000) }
}

/// m2-p-thread: "3 replies" and a hairline under the root.
struct ThreadRepliesRule: View {
    let count: Int

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let theme {
            let kit = theme.design.kit
            HStack(spacing: kit.space(.s3)) {
                Text(verbatim: GroupThreadsCopy(design: theme.design).replies(count))
                    .font(.footnote)
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
                    .fixedSize()
                Rectangle()
                    .fill(kit.color(.line, scheme: scheme))
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
            .padding(.top, kit.space(.s4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("chat.thread.repliesRule")
        }
    }
}

// MARK: One thread (m2-p-thread)

struct GroupThreadScreen: View {
    let model: LiveAppModel
    let design: LiveDesign
    let coordinator: GroupThreadsCoordinator
    let roomID: String
    let rootID: String
    let focusEventID: String?

    @Environment(\.colorScheme) private var scheme
    @State private var store: LiveConversationStore?
    @State private var unavailable = false
    @State private var followed: Bool?
    @State private var followPending = false
    @State private var followFailed = 0

    private var copy: GroupThreadsCopy { GroupThreadsCopy(design: design) }
    private var draftKey: String { roomID + "#" + rootID }
    private var live: GroupRoomLive? { coordinator.live(for: roomID) }

    private struct SessionKey: Equatable {
        let session: ObjectIdentifier?
        let ready: Bool
    }

    private var sessionKey: SessionKey {
        SessionKey(session: model.liveMatrix.map { ObjectIdentifier($0) }, ready: model.liveMatrix?.isReady == true)
    }

    var body: some View {
        Group {
            if unavailable {
                GroupThreadsMessage(design: design, text: copy.threadUnavailable)
                    .accessibilityIdentifier("chat.thread.unavailable")
            } else if let store {
                ChatScreen(store: store, design: design, mediaAccess: model.groupThreadMediaAccess,
                           loadMatrixThumbnail: { uri, side in await model.avatarThumbnail(uri: uri, pixelSide: side) },
                           thread: chrome)
                    .environment(\.chatThreadSummaries,
                                 ChatThreadSummaries(mode: .insideThread(rootID: rootID),
                                                     threads: live?.summaries ?? [:], open: { _ in }))
                    .environment(\.chatPinMenu, live.flatMap { live in
                        live.pinMenu.map { ChatPinMenu(context: $0) { live.setPinned($0, eventID: $1) } }
                    })
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AtumVisualSystem(design: design).color(.ground, scheme: scheme).ignoresSafeArea())
            }
        }
        .toolbarVisibility(.hidden, for: .tabBar)
        .task(id: sessionKey) { await attach() }
        .task(id: live?.threads?.first(where: { $0.root.eventID == rootID })?.followed) {
            await loadFollow()
        }
        .onDisappear { close() }
        .sensoryFeedback(.error, trigger: followFailed)
        .alert(copy.errorGeneric, isPresented: Binding(get: { live?.pinNotice != nil },
                                                       set: { if !$0 { live?.pinNotice = nil } })) {
            Button(copy.dismiss, role: .cancel) {}
        }
    }

    private var chrome: ChatThreadChrome {
        Self.chrome(design: design, place: model.groupThreadPlace(roomID: roomID), followed: followed ?? false,
                    pending: followPending || followed == nil, toggle: toggleFollow)
    }

    /// M2's header: "Thread" over the group, "…" with Follow, the bubbles kept.
    static func chrome(design: LiveDesign, place: String, followed: Bool, pending: Bool,
                       toggle: @escaping () -> Void) -> ChatThreadChrome {
        let copy = GroupThreadsCopy(design: design)
        return ChatThreadChrome(title: copy.thread, place: place, composerPlaceholder: copy.replyInThread,
                                followed: followed, followPending: pending, followText: copy.follow,
                                followHint: copy.unfollow, toggleFollow: toggle, flatRuns: false,
                                optionsLabel: copy.threadOptions)
    }

    /// Opens the focused SDK timeline for this root on each ready session.
    private func attach() async {
        guard sessionKey.ready else {
            store?.detach()
            return
        }
        do {
            let opened = try await model.openGroupThread(roomID: roomID, rootID: rootID,
                                                         draft: store?.draft ?? coordinator.drafts[draftKey] ?? "",
                                                         focusEventID: focusEventID)
            guard !Task.isCancelled else {
                opened.close()
                return
            }
            store?.close()
            store = opened
            unavailable = false
        } catch {
            guard !Task.isCancelled else { return }
            unavailable = store == nil
        }
    }

    private func loadFollow() async {
        if let known = live?.threads?.first(where: { $0.root.eventID == rootID })?.followed {
            followed = known
            return
        }
        guard followed == nil, let session = model.liveMatrix else { return }
        // Older than the loaded list: only an explicit choice is known.
        let attention = await session.companyThreadAttention(roomID: roomID)
        guard !Task.isCancelled, followed == nil else { return }
        followed = attention.isFollowed(rootID, automatic: false)
    }

    private func toggleFollow() {
        guard let current = followed, !followPending else { return }
        followPending = true
        Task { @MainActor in
            defer { followPending = false }
            do {
                try await model.setGroupThreadFollow(roomID: roomID, rootID: rootID, followed: !current)
                followed = !current
                await live?.refreshThreads()
            } catch {
                followFailed &+= 1
            }
        }
    }

    private func close() {
        if let store {
            coordinator.drafts[draftKey] = store.draft
            store.close()
        }
        store = nil
        // A thread just read or answered changes the list's unread state.
        let live = live
        Task { await live?.refreshThreads() }
    }
}

// MARK: The room's threads (m2-p-list)

struct GroupThreadListScreen: View {
    let model: LiveAppModel
    let design: LiveDesign
    let coordinator: GroupThreadsCoordinator
    let roomID: String

    @State private var opened: GroupThreadDestination?

    var body: some View {
        GroupThreadListContent(design: design, live: coordinator.live(for: roomID),
                               place: model.groupThreadPlace(roomID: roomID), members: members) { rootID in
            opened = .thread(roomID: roomID, rootID: rootID, focusEventID: nil)
        }
        .navigationDestination(item: $opened) { destination in
            GroupThreadDestinationView(model: model, design: design, coordinator: coordinator,
                                       destination: destination)
        }
    }

    private var members: [String: ChatInfoMember] {
        Dictionary((model.chatInfoPresentation(roomID: roomID)?.members ?? []).map { ($0.userID, $0) },
                   uniquingKeysWith: { first, _ in first })
    }
}

/// The list itself: card rows, paging at the end, and distinct loading,
/// failed and empty states.
struct GroupThreadListContent: View {
    let design: LiveDesign
    let live: GroupRoomLive?
    let place: String
    let members: [String: ChatInfoMember]
    let onOpen: (String) -> Void

    @Environment(\.colorScheme) private var scheme

    private var copy: GroupThreadsCopy { GroupThreadsCopy(design: design) }
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        let threads = live?.threads
        List {
            if let threads, !threads.isEmpty {
                Section {
                    ForEach(threads) { thread in
                        Button {
                            onOpen(thread.root.eventID)
                        } label: {
                            GroupThreadRow(design: design, thread: thread, members: members)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(atum.color(.cell, scheme: scheme))
                        .accessibilityIdentifier("chat.threads.row." + thread.root.eventID)
                        .onAppear {
                            if thread.id == threads.last?.id { Task { await live?.loadMoreThreads() } }
                        }
                    }
                } footer: {
                    if live?.loadingMoreThreads == true {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .overlay {
            if live == nil || live?.threadsFailed == true, threads == nil {
                GroupThreadsMessage(design: design, text: copy.errorGeneric, actionTitle: copy.tryAgain) {
                    Task { await live?.retryThreads() }
                }
                .accessibilityIdentifier("chat.threads.failed")
            } else if threads == nil {
                ProgressView()
            } else if threads?.isEmpty == true {
                GroupThreadsMessage(design: design, text: copy.noThreads)
                    .accessibilityIdentifier("chat.threads.empty")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChatThreadHeading(design: design, title: copy.threadsTitle, place: place)
                    .accessibilityIdentifier("chat.threads.title")
            }
        }
        .toolbarVisibility(.hidden, for: .tabBar)
        .task { await live?.refreshThreads() }
        .refreshable { await live?.refreshThreads() }
        .accessibilityIdentifier("chat.threads.list")
    }
}

struct GroupThreadRow: View {
    let design: LiveDesign
    let thread: CompanyThread
    let members: [String: ChatInfoMember]
    var compact = false

    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body) private var faceSize: CGFloat = 40

    var body: some View {
        let kit = design.kit
        let copy = GroupThreadsCopy(design: design)
        let when = GroupThreadsTime.label(ThreadSummaryCapsule.date(thread.lastActivityAt), locale: design.locale)
        HStack(spacing: kit.space(.s3)) {
            if !compact {
                ChatFaceView(face: ChatFace.reader(ChatReader(userID: thread.root.senderID, name: thread.root.senderName,
                                                              avatarURI: thread.root.senderAvatarURI),
                                                   kind: .group, roomFace: nil, members: members),
                             size: faceSize)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: kit.space(.s1)) {
                Text(verbatim: Self.title(thread.root.body) ?? copy.thread)
                    .font(compact ? .body : .body.weight(.semibold))
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                    .lineLimit(1)
                Text(verbatim: compact ? copy.replies(thread.replyCount)
                                       : copy.replies(thread.replyCount) + " · " + when)
                    .font(.subheadline)
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
                    .lineLimit(1)
            }
            Spacer(minLength: kit.space(.s2))
            if thread.unread {
                Circle()
                    .fill(kit.color(.ink, scheme: scheme))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, compact ? 0 : kit.space(.s1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [Self.title(thread.root.body) ?? copy.thread,
                                            copy.replies(thread.replyCount), compact ? nil : when,
                                            thread.unread ? copy.unread : nil]
            .compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(.isButton)
    }

    /// The root's first line, as the list's title.
    static func title(_ body: String) -> String? {
        let line = body.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }
}

// MARK: Details sheet (M2 decision 4; desktop `GroupThreadPreview`)

/// What the details sheet needs to show and open threads and pins.
struct GroupThreadsPanelActions {
    let live: GroupRoomLive
    /// Closes the sheet, then pushes the thread (nil: the list) over the chat.
    let open: (String?) -> Void
}

struct RoomPinsPanelActions {
    let live: GroupRoomLive
    /// Closes the sheet, then shows the message in the chat or its thread.
    let jump: (CompanyPinnedRow) -> Void
}

/// "Threads": the three newest (unread dot, root, replies), then All threads.
/// Hidden until the room has a thread, as desktop.
struct GroupThreadsInfoSection: View {
    let design: LiveDesign
    let actions: GroupThreadsPanelActions
    let members: [String: ChatInfoMember]
    let rowBackground: Color
    /// Closes the details sheet first: the thread is pushed over the chat.
    let close: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let copy = GroupThreadsCopy(design: design)
        let preview = actions.live.preview
        if !preview.isEmpty {
            Section {
                ForEach(preview) { thread in
                    Button {
                        close()
                        actions.open(thread.root.eventID)
                    } label: {
                        GroupThreadRow(design: design, thread: thread, members: members, compact: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("info.threads.row." + thread.root.eventID)
                }
                Button {
                    close()
                    actions.open(nil)
                } label: {
                    HStack {
                        Text(verbatim: copy.allThreads)
                            .foregroundStyle(design.kit.color(.ink, scheme: scheme))
                        Spacer()
                        Image(AtumVisualSystem(design: design).symbol(.chevronRight))
                            .foregroundStyle(design.kit.color(.ink3, scheme: scheme))
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("info.threads.all")
            } header: {
                Text(verbatim: copy.threadsTitle)
            }
            .listRowBackground(rowBackground)
        }
    }
}

// MARK: Shared pieces

/// A centred quiet line, with an optional recovery action.
struct GroupThreadsMessage: View {
    let design: LiveDesign
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: design.kit.space(.s3)) {
            Text(verbatim: text)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(AtumVisualSystem(design: design).color(.muted, scheme: scheme))
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(design.kit.space(.s6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// M2's times: today's hour ("10:42"), "Yesterday", a weekday within the
/// week ("Mon"), else the date.
enum GroupThreadsTime {
    static func label(_ date: Date, locale: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        let locale = Locale(identifier: locale)
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(Date.FormatStyle.dateTime.hour().minute().locale(locale))
        }
        if calendar.isDateInYesterday(date) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.doesRelativeDateFormatting = true
            return formatter.string(from: date)
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            return date.formatted(Date.FormatStyle.dateTime.weekday(.abbreviated).locale(locale))
        }
        return date.formatted(Date.FormatStyle.dateTime.day().month(.abbreviated).locale(locale))
    }
}

extension LiveAppModel {
    /// The group's name under "Thread" and "Threads".
    func groupThreadPlace(roomID: String) -> String {
        liveMatrix?.rooms.first(where: { $0.roomID == roomID })?.displayName ?? ""
    }

    /// The same media access the chat uses, for a thread's rows and composer.
    var groupThreadMediaAccess: ChatMediaAccess {
        ChatMediaAccess(
            thumbnail: { [weak self] media, width, height in
                await self?.mediaThumbnail(sourceHandle: media.thumbnailSourceHandle ?? media.sourceHandle,
                                           pixelWidth: width, pixelHeight: height)
            },
            content: { [weak self] media in await self?.mediaContent(sourceHandle: media.sourceHandle) },
            file: { [weak self] media in
                await self?.mediaFile(sourceHandle: media.sourceHandle, filename: media.filename,
                                      mimetype: media.mimetype ?? "application/octet-stream")
            },
            uploadLimit: { [weak self] in
                await self?.maximumMediaUploadSize() ?? MediaAttachmentPolicy.fallbackUploadLimit
            })
    }
}
