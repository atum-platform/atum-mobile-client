import AtumChat
import AtumDesign
import AtumNativeAPI
import SwiftUI
import UIKit

enum HomeLoadState: Hashable {
    case loading
    case ready
    case empty
    case offline
    case error
}

/// A display-safe Home row. Matrix objects and catalog clients remain outside
/// this boundary; the live and scripted adapters both produce the same value.
struct HomeRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case atum
        case assistant
        case app
        case person
        case group
        case invitation

        var avatarKind: AtumAvatarKind {
            switch self {
            case .atum: .atum
            case .assistant: .assistant
            case .app: .app
            case .person, .invitation: .person
            case .group: .group
            }
        }

        var roomKind: RoomKind {
            switch self {
            case .atum, .assistant: .assistant
            case .app: .appBot
            case .person, .invitation: .person
            case .group: .group
            }
        }

        var isAssistant: Bool { self == .atum || self == .assistant }
    }

    let id: String
    let roomID: String
    let kind: Kind
    let name: String
    var avatarURL: URL?
    var matrixAvatarURL: String?
    var avatarSHA256: String?
    var avatarCandidates: [LiveProductRemoteArt]
    /// A named assistant's coloured shape, drawn while it has no photo.
    var mark: AgentMark?
    var verification: AppVerificationTier?
    var preview: RowPreview.Display
    var latestEventAt: Date?
    /// The live newest event is a delivery notice; the preview is the last
    /// real message from the snapshot.
    var latestWasDeliveryNotice: Bool
    var badgeInput: Badge.Input
    var isPinned: Bool
    var isMuted: Bool
    var canOpen: Bool
    /// An active agent whose chat room has not reached this phone yet.
    var isWaitingForRoom: Bool
    /// A presentation-only catalog placeholder: no destination and no room
    /// action, launch, consent or link operation.
    var isComingSoon: Bool
    /// A catalog app with no chat yet: tapping starts it, and no room action
    /// (unread, mute, pin) applies to a room that does not exist.
    var awaitsStart: Bool
    /// The exact account-marked Founder room. Only this row uses the local
    /// approved raven; every other person keeps the ordinary human avatar.
    var isFounder: Bool
    /// HC-3: my assistant is at work here right now (`RosterWorking`). Live
    /// only: never written to the cold-launch snapshot, so no stale atom.
    var isWorking = false
    /// A group's joined-and-invited members, for Start chat's "N members"
    /// caption. Live only, like `isWorking`.
    var memberCount: Int?
    /// HC-7: the room's `m.lowpriority` tag, for the long-press toggle. Live
    /// rows only (a cached row reads false until the live list arrives).
    var isLowPriority = false

    /// HC-7: Low priority, Rename and Block apply to ordinary person and
    /// group chats (desktop `lowPriorityEligible`, `personalChatActions`);
    /// the Founder chat is the app's.
    var isPersonalChat: Bool { (kind == .person || kind == .group) && !isFounder }

    init(id: String, roomID: String? = nil, kind: Kind, name: String,
         avatarURL: URL? = nil, matrixAvatarURL: String? = nil,
         avatarSHA256: String? = nil,
         avatarCandidates: [LiveProductRemoteArt] = [],
         mark: AgentMark? = nil,
         verification: AppVerificationTier? = nil,
         preview: RowPreview.Display? = nil, latestEventAt: Date? = nil,
         latestWasDeliveryNotice: Bool = false,
         badgeInput: Badge.Input = .init(), isPinned: Bool = false,
         isMuted: Bool = false, canOpen: Bool = true,
         isWaitingForRoom: Bool = false, isComingSoon: Bool = false,
         awaitsStart: Bool = false, isFounder: Bool = false) {
        self.id = id
        self.roomID = roomID ?? id
        self.kind = kind
        self.name = name
        self.avatarURL = avatarURL
        self.matrixAvatarURL = matrixAvatarURL
        self.avatarSHA256 = avatarSHA256
        self.avatarCandidates = avatarCandidates
        self.mark = kind == .assistant ? mark : nil
        self.verification = verification
        self.preview = preview ?? RowPreview.Display(prefix: .none, value: .empty, sendState: .sent)
        self.latestEventAt = latestEventAt
        self.latestWasDeliveryNotice = latestWasDeliveryNotice
        self.badgeInput = badgeInput
        self.isPinned = isPinned
        self.isMuted = isMuted
        self.canOpen = canOpen
        self.isWaitingForRoom = isWaitingForRoom
        self.isComingSoon = isComingSoon
        self.awaitsStart = awaitsStart
        self.isFounder = isFounder
    }

    var badge: Badge { Badge.mark(for: badgeInput) }
    var isInvitation: Bool { kind == .invitation }

    /// Applies the session's live-only facts to rows that may have come from
    /// the cached chat list (HC-3, HC-5). Only assistant rows ever work.
    static func applyingLive(_ rows: [HomeRow], workingRoomIDs: Set<String>,
                             memberCounts: [String: Int]) -> [HomeRow] {
        guard !workingRoomIDs.isEmpty || !memberCounts.isEmpty else { return rows }
        return rows.map { row in
            var row = row
            row.isWorking = row.kind.isAssistant && workingRoomIDs.contains(row.roomID)
            if row.kind == .group { row.memberCount = memberCounts[row.roomID] }
            return row
        }
    }
    /// Desktop `MainAgentBadge`: Start chat stars the main assistant only.
    var showsMainAssistantBadge: Bool { kind == .atum }

    /// What `ChatExitPolicy` calls this row.
    var exitRoom: ChatExitPolicy.Room {
        switch kind {
        case .atum, .assistant: .assistant
        case .app: .appBot
        case .person: isFounder ? .founder : .person
        case .group: .group
        case .invitation: .invitation
        }
    }

    /// The Founder's local draft: a row that presents an empty chat and makes the room only
    /// when the first message is sent. It is never a room destination.
    var isFounderDraft: Bool { roomID == MobileFounderPolicy.draftRowID }

    init(snapshot row: ChatListSnapshot.Room) {
        let kind: Kind = switch row.kind {
        case .atum: .atum
        case .assistant: .assistant
        case .app: .app
        case .person: .person
        case .group: .group
        case .invitation: .invitation
        }
        let verification: AppVerificationTier? = switch row.verification {
        case .official: .official
        case .verified: .verified
        case nil: nil
        }
        self.init(
            id: row.id, roomID: row.roomID, kind: kind, name: row.name,
            avatarURL: row.avatarURL.flatMap(URL.init(string:)),
            matrixAvatarURL: row.matrixAvatarURL,
            avatarSHA256: row.avatarSHA256,
            avatarCandidates: row.avatarCandidates.compactMap { candidate in
                URL(string: candidate.url).map {
                    LiveProductRemoteArt(url: $0, sha256: candidate.sha256)
                }
            },
            mark: row.mark.flatMap { value in
                guard let shape = AgentMarkShape(rawValue: value.shape),
                      let color = AgentMarkColor(rawValue: value.color) else { return nil }
                return AgentMark(shape: shape, color: color)
            },
            verification: verification,
            preview: row.preview,
            latestEventAt: row.latestEventAt,
            latestWasDeliveryNotice: row.latestWasDeliveryNotice,
            badgeInput: Badge.Input(highlights: row.highlightCount,
                                    notifications: row.notificationCount,
                                    hasUnreadActivity: row.unreadCount > 0,
                                    isMarkedUnread: row.isMarkedUnread,
                                    isMuted: row.isMuted),
            isPinned: row.isPinned, isMuted: row.isMuted, canOpen: row.canOpen,
            isWaitingForRoom: row.isWaitingForRoom, isComingSoon: row.isComingSoon,
            awaitsStart: row.awaitsStart, isFounder: row.isFounder
        )
    }

    /// The exact state a cold launch paints. Only already-displayable fields
    /// are stored; no SDK object, token or per-account secret.
    var snapshotRow: ChatListSnapshot.Room {
        let kind: ChatListSnapshot.Kind = switch kind {
        case .atum: .atum
        case .assistant: .assistant
        case .app: .app
        case .person: .person
        case .group: .group
        case .invitation: .invitation
        }
        let verification: ChatListSnapshot.Verification? = switch verification {
        case .official: .official
        case .verified: .verified
        case nil: nil
        }
        return ChatListSnapshot.Room(
            id: id, roomID: roomID, kind: kind, name: name,
            verification: verification,
            avatarURL: avatarURL?.absoluteString,
            matrixAvatarURL: matrixAvatarURL,
            avatarSHA256: avatarSHA256,
            avatarCandidates: avatarCandidates.map {
                .init(url: $0.url.absoluteString, sha256: $0.sha256)
            },
            mark: mark.map { .init(shape: $0.shape.rawValue, color: $0.color.rawValue) },
            // A send that was still local when the list settled is not a
            // durable state; never resurrect "sending"/"not sent" on launch.
            preview: RowPreview.Display(prefix: preview.prefix, value: preview.value,
                                        sendState: .sent),
            latestEventAt: latestEventAt,
            latestWasDeliveryNotice: latestWasDeliveryNotice,
            unreadCount: badgeInput.hasUnreadActivity ? max(1, badgeInput.notifications) : 0,
            notificationCount: badgeInput.notifications,
            highlightCount: badgeInput.highlights,
            isMarkedUnread: badgeInput.isMarkedUnread,
            isPinned: isPinned, isMuted: isMuted, canOpen: canOpen,
            isWaitingForRoom: isWaitingForRoom, isComingSoon: isComingSoon,
            awaitsStart: awaitsStart, isFounder: isFounder
        )
    }
    var canDeleteAppRoom: Bool { kind == .app && !roomID.hasPrefix("app:") }

    /// The row knows it has a face to show, even before its bytes arrive.
    /// Those rows get a neutral tile, never their initial.
    var hasAvatarSource: Bool {
        isFounder || avatarURL != nil || matrixAvatarURL != nil || !avatarCandidates.isEmpty
    }

    init(product room: LiveProductRoom, locale: Locale) {
        let kind: Kind
        if room.isInvitation {
            kind = .invitation
        } else {
            switch room.kind {
            case .agent:
                if room.isAppBotRoom || room.id.hasPrefix("app:") { kind = .app }
                else if room.assistant?.isDefault == true { kind = .atum }
                else { kind = .assistant }
            case .people: kind = .person
            case .group: kind = .group
            }
        }
        let preview = RowPreview.display(
            for: RowPreview.Event(content: room.previewContent, isOwn: room.latestIsOwn,
                                  senderName: room.latestSenderName, roomKind: kind.roomKind,
                                  isInvitation: room.isInvitation,
                                  sendState: room.latestSendState),
            locale: locale
        )
        let avatarURL: URL? = switch room.avatar {
        case let .photo(url, _): url
        case .eclipse, .mark, .symbol, .monogram, .none: nil
        }
        let verification: AppVerificationTier? = switch room.appVerification {
        case .official: .official
        case .verified: .verified
        case nil: nil
        }
        self.init(
            id: room.id, kind: kind, name: room.title, avatarURL: avatarURL,
            matrixAvatarURL: room.matrixAvatarURL,
            avatarSHA256: room.avatarSHA256,
            avatarCandidates: room.avatarCandidates,
            mark: room.avatar?.agentMark,
            verification: verification,
            preview: preview, latestEventAt: room.latestEventAt,
            latestWasDeliveryNotice: room.latestWasDeliveryNotice,
            badgeInput: Badge.Input(highlights: room.highlightCount,
                                    notifications: room.notificationCount,
                                    hasUnreadActivity: room.unreadCount > 0,
                                    isMarkedUnread: room.isMarkedUnread,
                                    isMuted: room.isMuted),
            isPinned: room.isPinned, isMuted: room.isMuted, canOpen: room.canOpen,
            isWaitingForRoom: room.isAwaitingRoom, isComingSoon: room.isComingSoon,
            awaitsStart: room.awaitsStart, isFounder: room.isFounder
        )
        isLowPriority = room.isLowPriority
    }

}

struct HomePresentation: Equatable {
    var state: HomeLoadState
    var rows: [HomeRow]
    var showsNotificationPrompt: Bool
    var showsDomainReauthentication: Bool
    var domainReauthenticationBusy: Bool
    var actionFailureToken: UInt64
    var pinnedRoomCount: Int
    /// Company channels' share of the app-icon count (Team Space mentions),
    /// by the same rule as the rows.
    var companyAppIconRows: [Badge.AppIconRow]

    init(state: HomeLoadState, rows: [HomeRow] = [],
         showsNotificationPrompt: Bool = false,
         showsDomainReauthentication: Bool = false,
         domainReauthenticationBusy: Bool = false,
         actionFailureToken: UInt64 = 0, pinnedRoomCount: Int? = nil,
         companyAppIconRows: [Badge.AppIconRow] = []) {
        self.state = state
        self.companyAppIconRows = companyAppIconRows
        self.rows = rows
        self.showsNotificationPrompt = showsNotificationPrompt
        self.showsDomainReauthentication = showsDomainReauthentication
        self.domainReauthenticationBusy = domainReauthenticationBusy
        self.actionFailureToken = actionFailureToken
        self.pinnedRoomCount = pinnedRoomCount ?? rows.filter(\.isPinned).count
    }

    /// The foreground app-icon count: Home's rows plus company channels.
    var appIconCount: Int {
        Badge.appIconCount(rows.map { row in
            Badge.AppIconRow(input: row.badgeInput, isListed: true,
                             isJoined: !row.isInvitation, isHidden: false)
        } + companyAppIconRows)
    }
}

/// The Founder's local draft: words and the one send that makes the chat. It is not a room
/// destination, so it never goes through `openRoom`.
struct FounderDraftActions {
    let name: String
    let subtitle: String
    let intro: String
    let unready: String
    let send: @MainActor (String) async -> Bool
}

struct HomeActions {
    var openRoom: (String) -> Void
    var joinInvitation: ((String) async -> Bool)?
    var refresh: () async -> Void
    var rowsShown: (() -> Void)?
    var setAppIconBadge: ((Int) async -> Void)?
    var loadMatrixThumbnail: ((String, Int) async -> Data?)?
    var answerNotificationPrompt: ((Bool) -> Void)?
    var reauthenticateDomain: (() -> Void)?
    var setUnread: ((String, Bool) -> Void)?
    var setPinned: ((String, Bool) -> Void)?
    var setMuted: ((String, Bool) -> Void)?
    var setAppShortcutVisibility: (@MainActor (String, Bool) async -> Bool)?
    var deleteAppRoom: ((String) -> Void)?
    var declineInvitation: ((String) -> Void)?
    var addFriend: ((String) async -> HomeAddFriendResult)?
    var peopleDiscovery: HomePeopleDiscoveryActions?
    var newGroup: HomeGroupActions?
    var newAssistant: HomeAssistantActions?
    var founderDraft: FounderDraftActions?
    /// "Delete chat" / "Leave group" (`ChatExitPolicy`), confirmed first.
    var exitRoom: ((String, ChatExitAction) -> Void)?
    /// The signed-in account is the Founder: the Founder chat is kept.
    var viewerIsFounder: Bool
    /// An app row's "Info": the official app's read-only card (AS-11, desktop
    /// `RosterAppMenu` → `AppCard`). Nil for a row that is not an app.
    var appInfo: ((String) -> AppCardPresentation?)?
    /// HC-7: the long-press's Low priority, Rename and Block (desktop
    /// `RosterRoomMenu`). Nil hides each.
    var setLowPriority: ((String, Bool) -> Void)?
    var rename: ChatRenameActions?
    /// The other person of a person chat, the one Block applies to.
    var blockablePeer: ((String) -> String?)?
    var blockedUserIDs: (() async -> Set<String>)?
    var setBlocked: ((String, Bool) async -> Bool)?

    init(openRoom: @escaping (String) -> Void,
         joinInvitation: ((String) async -> Bool)? = nil,
         refresh: @escaping () async -> Void,
         rowsShown: (() -> Void)? = nil,
         setAppIconBadge: ((Int) async -> Void)? = nil,
         loadMatrixThumbnail: ((String, Int) async -> Data?)? = nil,
         answerNotificationPrompt: ((Bool) -> Void)? = nil,
         reauthenticateDomain: (() -> Void)? = nil,
         setUnread: ((String, Bool) -> Void)? = nil,
         setPinned: ((String, Bool) -> Void)? = nil,
         setMuted: ((String, Bool) -> Void)? = nil,
         setAppShortcutVisibility: (@MainActor (String, Bool) async -> Bool)? = nil,
         deleteAppRoom: ((String) -> Void)? = nil,
         declineInvitation: ((String) -> Void)? = nil,
         addFriend: ((String) async -> HomeAddFriendResult)? = nil,
         peopleDiscovery: HomePeopleDiscoveryActions? = nil,
         newGroup: HomeGroupActions? = nil,
         newAssistant: HomeAssistantActions? = nil,
         founderDraft: FounderDraftActions? = nil,
         exitRoom: ((String, ChatExitAction) -> Void)? = nil,
         viewerIsFounder: Bool = false,
         appInfo: ((String) -> AppCardPresentation?)? = nil) {
        self.exitRoom = exitRoom
        self.viewerIsFounder = viewerIsFounder
        self.appInfo = appInfo
        self.openRoom = openRoom
        self.joinInvitation = joinInvitation
        self.refresh = refresh
        self.rowsShown = rowsShown
        self.setAppIconBadge = setAppIconBadge
        self.loadMatrixThumbnail = loadMatrixThumbnail
        self.answerNotificationPrompt = answerNotificationPrompt
        self.reauthenticateDomain = reauthenticateDomain
        self.setUnread = setUnread
        self.setPinned = setPinned
        self.setMuted = setMuted
        self.setAppShortcutVisibility = setAppShortcutVisibility
        self.deleteAppRoom = deleteAppRoom
        self.declineInvitation = declineInvitation
        self.addFriend = addFriend
        self.peopleDiscovery = peopleDiscovery
        self.newGroup = newGroup
        self.newAssistant = newAssistant
        self.founderDraft = founderDraft
    }

    var hasCreationActions: Bool {
        addFriend != nil || newGroup != nil || newAssistant != nil
    }
}

/// S2's signed-in Home root. It renders only immutable presentation values;
/// ordering lives in `RosterProjection`, and every mutation returns through
/// `HomeActions` to the session adapter.
struct HomeScreen: View {
    let design: LiveDesign
    let router: Router
    /// The signed-in person's display name or handle, used only for the
    /// top-left account avatar's monogram (or its accessibility label).
    var accountName: String = ""
    /// The person's own Matrix avatar, so a photo set in Settings shows here too.
    var accountAvatarURL: String? = nil
    let presentation: HomePresentation
    let actions: HomeActions
    var dismissPresentationRequest: UInt64 = 0
    var onPresentationChanged: (Bool) -> Void = { _ in }

    @State private var query = ""
    /// While the top search field has focus (or a query), the face and the
    /// pencil step aside for Cancel.
    @FocusState private var searchFocused: Bool
    @State private var accountArt: AtumAvatarArt?
    @State private var startChatPresented = false
    @State private var founderDraftPresented = false
    @State private var showsDelayedLoadingMark = false
    @State private var markedFirstHomeFrame = false
    @State private var scrollRequest = 0
    @State private var joiningRoomID: String?
    @State private var actionFailure = 0
    @State private var pendingDeleteRoomID: String?
    @State private var pendingExit: HomePendingExit?
    /// The official app card an app row's "Info" opened.
    @State private var appCard: AppCardPresentation?
    /// HC-7: Rename's alert, Block's confirmation and who is blocked now.
    @State private var renameRequest: ChatRenameRequest?
    @State private var pendingBlock: HomePendingBlock?
    @State private var blockedUserIDs = Set<String>()
    /// Home search's People section (desktop roster global search).
    @State private var peopleSearch = HomePeopleSearchState.idle
    @State private var openingPersonID: String?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let topID = "home.top"

    var body: some View {
        VStack(spacing: 0) {
            header
            if presentation.showsDomainReauthentication {
                HomeDomainReauthenticationCard(
                    design: design,
                    busy: presentation.domainReauthenticationBusy,
                    action: actions.reauthenticateDomain
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            Group {
                if presentation.rows.isEmpty {
                    emptyContent
                } else if filteredRows.isEmpty && !showsPeopleResults {
                    noSearchResults
                } else {
                    roster
                }
            }
        }
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $startChatPresented) {
            HomeStartChatSheet(design: design,
                               rows: presentation.rows,
                               actions: actions,
                               onOpenFounderDraft: {
                                   startChatPresented = false
                                   founderDraftPresented = true
                               }) {
                startChatPresented = false
            }
        }
        .sheet(item: $appCard) { card in
            AppCardSheet(design: design, card: card, loadMatrixThumbnail: actions.loadMatrixThumbnail,
                         open: {
                             appCard = nil
                             actions.openRoom(card.rowID)
                         },
                         close: { appCard = nil })
        }
        .sheet(isPresented: $founderDraftPresented) {
            if let draft = actions.founderDraft {
                FounderDraftSheet(design: design, draft: draft) {
                    founderDraftPresented = false
                }
            } else {
                // The chat appeared on another device while the draft was open.
                Color.clear.onAppear { founderDraftPresented = false }
            }
        }
        .task(id: presentation.state) {
            showsDelayedLoadingMark = false
            guard presentation.state == .loading, presentation.rows.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            showsDelayedLoadingMark = true
        }
        .task(id: presentation.state == .ready && !presentation.rows.isEmpty) {
            if presentation.state == .ready, !presentation.rows.isEmpty {
                if !markedFirstHomeFrame {
                    markedFirstHomeFrame = true
                    ProbeLog.mark(.homeFirstFrame)
                }
                actions.rowsShown?()
            }
        }
        .task(id: waitingRow?.id) {
            guard waitingRow != nil else { return }
            await actions.refresh()
        }
        .task(id: peopleSearchTerm) { await searchPeople() }
        .onChange(of: scenePhase) { old, new in
            guard old != .active, new == .active, waitingRow != nil else { return }
            Task { await actions.refresh() }
        }
        .task(id: HomeBadgeUpdate(state: presentation.state, count: appIconBadge,
                                  isActive: scenePhase == .active)) {
            guard scenePhase == .active,
                  presentation.state != .loading, presentation.state != .error,
                  let setAppIconBadge = actions.setAppIconBadge else { return }
            await setAppIconBadge(appIconBadge)
        }
        .onAppear {
            router.onHomeRootRetap = { scrollRequest &+= 1 }
        }
        .onDisappear {
            router.onHomeRootRetap = {}
        }
        .sensoryFeedback(.error, trigger: actionFailure)
        .sensoryFeedback(.error, trigger: presentation.actionFailureToken) { old, new in
            router.homeRoomID == nil && old != new
        }
        .onChange(of: presentation.actionFailureToken) { old, new in
            guard router.homeRoomID == nil, old != new else { return }
            AccessibilityNotification.Announcement(copy(.errorGeneric)).post()
        }
        .onChange(of: dismissPresentationRequest) { _, _ in
            pendingDeleteRoomID = nil
            startChatPresented = false
        }
        .confirmationDialog(pendingExit.map { exitText($0.action, delete: "src.matrix.chat-copy.copies.deleteChatTitle",
                                                        leave: "src.matrix.chat-copy.copies.leaveTitle") } ?? "",
                            isPresented: Binding(get: { pendingExit != nil },
                                                 set: { if !$0 { pendingExit = nil } }),
                            titleVisibility: .visible, presenting: pendingExit) { exit in
            Button(exitText(exit.action, delete: HomeCopyKey.deleteChat.rawValue, leave: "desktop.dm.group.leave"),
                   role: .destructive) {
                pendingExit = nil
                actions.exitRoom?(exit.roomID, exit.action)
            }
            Button(copy(.cancel), role: .cancel) { pendingExit = nil }
        } message: { exit in
            Text(exitText(exit.action, delete: "src.matrix.chat-copy.copies.deleteChatBody",
                          leave: "src.matrix.chat-copy.copies.leaveBody"))
        }
        .onChange(of: pendingDeleteRoomID != nil || startChatPresented || founderDraftPresented, initial: true) { _, active in
            onPresentationChanged(active)
        }
        .onDisappear { onPresentationChanged(false) }
        .confirmationDialog(copy(.deleteChatTitle),
                            isPresented: Binding(
                                get: { pendingDeleteRoomID != nil },
                                set: { if !$0 { pendingDeleteRoomID = nil } }
                            ), titleVisibility: .visible) {
            Button(copy(.deleteChat), role: .destructive) {
                guard let roomID = pendingDeleteRoomID else { return }
                pendingDeleteRoomID = nil
                actions.deleteAppRoom?(roomID)
            }
            Button(copy(.cancel), role: .cancel) { pendingDeleteRoomID = nil }
        } message: {
            if let row = presentation.rows.first(where: { $0.roomID == pendingDeleteRoomID }) {
                Text(copy(.deleteBotChatBody, [.text(row.name)]))
            }
        }
        // HC-7: Block (desktop `blockPersonTitle` / `blockPersonBody`) and Rename.
        .confirmationDialog(design.text(ChatCopyKey.blockPersonTitle.rawValue),
                            isPresented: Binding(get: { pendingBlock != nil },
                                                 set: { if !$0 { pendingBlock = nil } }),
                            titleVisibility: .visible, presenting: pendingBlock) { block in
            Button(design.text(ChatCopyKey.blockPerson.rawValue), role: .destructive) {
                pendingBlock = nil
                Task {
                    if await actions.setBlocked?(block.userID, true) == true {
                        blockedUserIDs.insert(block.userID)
                    } else {
                        actionFailure &+= 1
                    }
                }
            }
            Button(copy(.cancel), role: .cancel) { pendingBlock = nil }
        } message: { _ in
            Text(design.text(ChatCopyKey.blockPersonBody.rawValue))
        }
        .chatRenameAlert($renameRequest, design: design) { request, name in
            await actions.rename?.save(request, name) ?? false
        }
        .task(id: presentation.state == .ready) {
            guard presentation.state == .ready, let load = actions.blockedUserIDs else { return }
            blockedUserIDs = await load()
        }
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    /// HC-7: the long-press's personal-chat items for one row.
    private func personalMenu(for row: HomeRow) -> HomeRowPersonalMenu {
        guard row.isPersonalChat, !row.isInvitation, !row.isFounderDraft else { return HomeRowPersonalMenu() }
        let peer = row.kind == .person ? actions.blockablePeer?(row.roomID) : nil
        return HomeRowPersonalMenu(
            setLowPriority: actions.setLowPriority,
            rename: actions.rename.map { rename in
                { roomID in
                    Task {
                        guard let request = await rename.request(roomID) else { return }
                        renameRequest = request
                    }
                }
            },
            block: peer.flatMap { peer in
                actions.setBlocked.map { setBlocked in
                    HomeRowPersonalMenu.Block(isBlocked: blockedUserIDs.contains(peer)) {
                        if blockedUserIDs.contains(peer) {
                            // Unblock needs no confirmation (desktop).
                            Task {
                                if await setBlocked(peer, false) { blockedUserIDs.remove(peer) }
                            }
                        } else {
                            pendingBlock = HomePendingBlock(roomID: row.roomID, userID: peer)
                        }
                    }
                }
            })
    }

    private func exitText(_ action: ChatExitAction, delete: String, leave: String) -> String {
        design.text(action == .deleteChat ? delete : leave)
    }
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
    /// the top centre): the account face (44 circle) leading, the Kit search
    /// field in the middle, the glass note-pencil (44) trailing. While
    /// searching, Cancel replaces the face and the pencil. At accessibility
    /// sizes the face and pencil sit on their own row above the field.
    ///
    /// The field is one stable child of its row in every state: only the
    /// controls around it come and go. Rebuilding it on focus (an `if` that
    /// swapped whole rows) dropped the keyboard the moment the field was
    /// tapped (HomeShellUITests' search test caught it on the simulator).
    private var header: some View {
        let accessible = dynamicTypeSize.isAccessibilitySize
        return VStack(spacing: 8) {
            if accessible && !searching {
                HStack(spacing: 10) {
                    accountButton
                    Spacer(minLength: 0)
                    createButton
                }
            }
            HStack(spacing: 10) {
                if !accessible && !searching { accountButton }
                searchField
                if searching {
                    Button(copy(.cancel)) { endSearch() }
                        .buttonStyle(.plain)
                        .font(.body)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("home.search.cancel")
                } else if !accessible {
                    createButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .background(atum.color(.ground, scheme: scheme))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: searching)
    }

    private var searching: Bool { searchFocused || !query.isEmpty }

    private var searchField: some View {
        HomeSearchField(query: $query, prompt: copy(.search), focused: $searchFocused)
    }

    private func endSearch() {
        query = ""
        searchFocused = false
    }

    private var accountButton: some View {
        Button { router.presentAccount() } label: {
            AtumAvatar(kind: .person, name: accountName, art: accountArt, size: 44)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .task(id: accountAvatarURL) {
            accountArt = nil
            guard let uri = accountAvatarURL, let load = actions.loadMatrixThumbnail else { return }
            let side = AtumAvatar.thumbnailPixelSide(for: 44)
            guard let data = await load(uri, side), !Task.isCancelled else { return }
            accountArt = await AtumAvatarArt.load(data: data, pixelSide: side)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: copy(.settings)))
        .accessibilityIdentifier("home.account")
    }

    @ViewBuilder private var createButton: some View {
        if canStartChat {
            Button { startChatPresented = true } label: {
                Image(atum.symbol(.composePencil))
                    .font(.system(size: 19, weight: .light))
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(atum.color(.ink, scheme: scheme))
            .modifier(LiveGlass(design: design, radius: 22))
            .accessibilityLabel(copy(.startChat))
            .accessibilityIdentifier("home.create")
        }
    }

    private var canStartChat: Bool {
        actions.hasCreationActions || presentation.rows.contains { !$0.isInvitation && $0.canOpen }
    }

    private var filteredRows: [HomeRow] {
        let locale = Locale(identifier: design.locale)
        let needle = HomeSearch.normalize(query, locale: locale)
        guard !needle.isEmpty else { return presentation.rows }
        return presentation.rows.filter { HomeSearch.normalize($0.name, locale: locale).contains(needle) }
    }

    private var assistantRows: [HomeRow] { filteredRows.filter { $0.kind.isAssistant } }
    private var chatRows: [HomeRow] { filteredRows.filter { !$0.kind.isAssistant } }

    /// An active agent whose room has not arrived yet. Its row appears once,
    /// requests a roster/sync refresh, and asks again on every foreground
    /// return until the room exists.
    private var waitingRow: HomeRow? {
        presentation.rows.first(where: \.isWaitingForRoom)
    }

    private var appIconBadge: Int { presentation.appIconCount }

    private var roster: some View {
        ScrollViewReader { proxy in
            TimelineView(.periodic(from: .now, by: 60)) { clock in
                List {
                    if presentation.showsNotificationPrompt {
                        HomeNotificationCard(design: design,
                                             onAnswer: actions.answerNotificationPrompt)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .id(topID)
                    }

                    // Desktop draws the search's People above the roster's
                    // own matches (`data-matrix-global-search-results`).
                    peopleResults(isTop: !presentation.showsNotificationPrompt)
                    section(copy(.assistants), id: "assistants", rows: assistantRows, now: clock.date,
                            isTop: !presentation.showsNotificationPrompt && !showsPeopleResults)
                    // Desktop parity: the roster labels its second block
                    // "Chats" too. Without it apps and people read as more
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
                    section(copy(.chats), id: "chats", rows: chatRows, now: clock.date,
                            isTop: !presentation.showsNotificationPrompt && !showsPeopleResults
                                && assistantRows.isEmpty)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(atum.color(.ground, scheme: scheme))
                .refreshable { await actions.refresh() }
                .animation(reduceMotion ? nil : .default, value: filteredRows.map(\.id))
                .accessibilityIdentifier("home.list")
                .modifier(HomeDebugBadgeValue(value: appIconBadge))
                .onChange(of: scrollRequest) { _, _ in
                    if reduceMotion {
                        proxy.scrollTo(topID, anchor: .top)
                    } else {
                        withAnimation { proxy.scrollTo(topID, anchor: .top) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, id: String, rows: [HomeRow], now: Date, isTop: Bool) -> some View {
        if !rows.isEmpty {
            // A plain row, not a `Section` header: transparent List headers
            // stick over the first row on scroll, which is the overlap the
            // owner saw ("Assistants" drawn across the first assistant). An
            // ordinary row scrolls away with the content and keeps the
            // hierarchy without painting over a face.
            Text(verbatim: title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .textCase(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, isTop ? 6 : 12)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.section.\(id)")
                .id(isTop ? topID : "home.header.\(rows[0].id)")
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(rows) { row in
                rowButton(row, now: now)
            }
        }
    }

    @ViewBuilder private func rowButton(_ row: HomeRow, now: Date) -> some View {
        if row.isComingSoon {
            decoratedRow(rowView(row, now: now), row: row)
        } else {
            decoratedRow(Button {
                guard row.canOpen else { return }
                if row.isInvitation, let joinInvitation = actions.joinInvitation {
                    guard joiningRoomID == nil else { return }
                    joiningRoomID = row.roomID
                    Task {
                        let joined = await joinInvitation(row.roomID)
                        joiningRoomID = nil
                        if !joined {
                            actionFailure &+= 1
                            AccessibilityNotification.Announcement(copy(.errorGeneric)).post()
                        }
                    }
                } else if row.isFounderDraft {
                    founderDraftPresented = true
                } else {
                    actions.openRoom(row.roomID)
                }
            } label: {
                rowView(row, now: now)
            }
            .disabled(!row.canOpen || (row.isInvitation && joiningRoomID != nil)), row: row)
        }
    }

    private func rowView(_ row: HomeRow, now: Date) -> some View {
        HomeRowView(design: design, row: row, now: now,
                    loadMatrixThumbnail: actions.loadMatrixThumbnail,
                    isJoining: joiningRoomID == row.roomID,
                    isSearching: !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func decoratedRow<Content: View>(_ content: Content, row: HomeRow) -> some View {
        content
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(atum.color(.frame, scheme: scheme))
        .tint(atum.color(.ink, scheme: scheme))
        .modifier(HomeRowActionsModifier(design: design, row: row,
                                         pinnedCount: presentation.pinnedRoomCount,
                                         actions: actions,
                                         requestDeleteAppRoom: actions.deleteAppRoom == nil ? nil : {
                                             pendingDeleteRoomID = $0
                                         },
                                         requestExit: actions.exitRoom == nil ? nil : { roomID, action in
                                             pendingExit = HomePendingExit(roomID: roomID, action: action)
                                         },
                                         requestAppInfo: actions.appInfo == nil ? nil : { rowID in
                                             appCard = actions.appInfo?(rowID)
                                         },
                                         personal: personalMenu(for: row)))
    }

    @ViewBuilder private var emptyContent: some View {
        switch presentation.state {
        case .loading:
            ZStack {
                atum.color(.ground, scheme: scheme).ignoresSafeArea()
                if showsDelayedLoadingMark {
                    AtomWait()
                        .frame(width: 28, height: 28)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .accessibilityLabel(copy(.loading))
                        .accessibilityIdentifier("home.loading")
                }
            }
        case .offline:
            // Kit state: one glyph in ink-4, one line.
            VStack(spacing: 12) {
                Image(atum.symbol(.cloudOff))
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(atum.kitColor(.ink4, scheme: scheme))
                    .accessibilityHidden(true)
                Text(copy(.offline))
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error:
            ContentUnavailableView {
                Text(copy(.loadFailed))
            } actions: {
                Button(copy(.retry)) { Task { await actions.refresh() } }
                    .buttonStyle(AtumCompactButtonStyle(atum: atum, scheme: scheme, size: .regular))
            }
        case .ready, .empty:
            ScrollView {
                ContentUnavailableView {
                    VStack(spacing: 0) {
                        LiveEclipseMark(design: design)
                            .frame(width: 72, height: 72)
                        Text(copy(.emptyTitle))
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(atum.color(.ink, scheme: scheme))
                            .multilineTextAlignment(.center)
                            .padding(.top, 20)
                        Text(copy(.emptyBody))
                            .font(.subheadline)
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                            .multilineTextAlignment(.center)
                            .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 96)
            }
            .refreshable { await actions.refresh() }
            .accessibilityIdentifier("home.empty")
        }
    }

    // MARK: People (desktop roster global search)

    /// The query the People section asks for: two or more characters, and
    /// only while people can be found (signed in, Matrix ready).
    private var peopleSearchTerm: String? {
        actions.peopleDiscovery == nil ? nil : HomePeopleSearchPolicy.term(query)
    }

    /// The answer for the query on screen; an older query's never shows.
    private var currentPeopleSearch: HomePeopleSearchState? {
        guard let term = peopleSearchTerm, peopleSearch.term == term else { return nil }
        return peopleSearch
    }

    /// Desktop's `globalSearching`: from the first keystroke of a long
    /// enough query until its answer lands, debounce included.
    private var peopleSearching: Bool {
        peopleSearchTerm != nil && (currentPeopleSearch?.pending ?? true)
    }

    private var shownPeople: [HomeGroupCandidate] {
        guard let current = currentPeopleSearch else { return [] }
        let directRoom = actions.peopleDiscovery?.directRoom
        return HomePeopleSearchPolicy.shown(current.people) { directRoom?($0) != nil }
    }

    /// While searching or showing people, the list stays instead of
    /// "No results" (desktop: `!externalSearching && totalResultCount === 0`).
    private var showsPeopleResults: Bool { peopleSearching || !shownPeople.isEmpty }

    private func searchPeople() async {
        guard let term = peopleSearchTerm, let discovery = actions.peopleDiscovery else {
            peopleSearch = .idle
            return
        }
        peopleSearch = HomePeopleSearchState(term: term, pending: true)
        do { try await Task.sleep(for: HomePeopleSearchPolicy.debounce) } catch { return }
        let found = await discovery.search(term)
        // A newer query cancelled this one: its late answer is dropped.
        guard !Task.isCancelled, peopleSearchTerm == term else { return }
        peopleSearch = HomePeopleSearchState(term: term, pending: false, people: found ?? [])
    }

    @ViewBuilder private func peopleResults(isTop: Bool) -> some View {
        if peopleSearching {
            Text(verbatim: copy(.searching))
                .font(.footnote)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, isTop ? 6 : 12)
                .accessibilityIdentifier("home.people.searching")
                .id(isTop ? topID : "home.people.searching")
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        let people = shownPeople
        if !people.isEmpty {
            let headerIsTop = isTop && !peopleSearching
            Text(verbatim: copy(.people))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .textCase(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, headerIsTop ? 6 : 12)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.section.people")
                .id(headerIsTop ? topID : "home.header.people")
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            ForEach(people) { person in
                Button { openPerson(person) } label: {
                    HomeDiscoveryPersonRow(design: design, person: person,
                                           load: actions.peopleDiscovery?.loadMatrixThumbnail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(openingPersonID != nil)
                .accessibilityIdentifier("home.people.\(person.id)")
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
    }

    /// Desktop `openGlobalPerson`: the direct chat with them, made if it does
    /// not exist yet, then opened. A failure is the generic error, as there.
    private func openPerson(_ person: HomeGroupCandidate) {
        guard let discovery = actions.peopleDiscovery, openingPersonID == nil else { return }
        openingPersonID = person.id
        Task { @MainActor in
            let result = await discovery.open(person.id)
            openingPersonID = nil
            if case let .openRoom(roomID) = result {
                actions.openRoom(roomID)
            } else {
                actionFailure &+= 1
                AccessibilityNotification.Announcement(copy(.errorGeneric)).post()
            }
        }
    }

    private var noSearchResults: some View {
        ContentUnavailableView {
            Label(copy(.emptySearch), image: atum.symbol(.search))
        } description: {
            Text(copy(.emptySearchHint))
        }
        .foregroundStyle(atum.color(.soft, scheme: scheme))
    }

    private func copy(_ key: HomeCopyKey, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key.rawValue, arguments: arguments)
    }
}

/// Home search's People section: desktop's roster global search
/// (`apps/desktop/src/matrix/roster-global-search.ts`, rendered in
/// `app.tsx`'s roster). While the Home search holds two or more characters it
/// asks the people directory once per query, 250 ms after typing stops, and
/// shows the people found that are not already one of your chats.
enum HomePeopleSearchPolicy {
    /// Desktop asks from two characters (`[...text].length < 2`, code points).
    static let minimumLength = 2
    /// Desktop's `createMatrixRosterGlobalSearch(bridges, delay = 250)`.
    static let debounce: Duration = .milliseconds(250)

    /// The trimmed query the directory is asked for, or nil while it is too
    /// short to ask.
    static func term(_ query: String) -> String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.unicodeScalars.count >= minimumLength ? text : nil
    }

    /// Desktop's `globalPeople`: people only (the model already leaves out
    /// this account, its assistants and app bots), and nobody you already
    /// have a direct chat with (`directRoomWith`). Each identity once.
    static func shown(_ found: [HomeGroupCandidate],
                      hasDirectChat: (String) -> Bool) -> [HomeGroupCandidate] {
        var seen = Set<String>()
        return found.filter { person in
            person.kind == .person && !hasDirectChat(person.id) && seen.insert(person.id).inserted
        }
    }
}

/// One query's People answer. `pending` covers the debounce and the request,
/// like desktop's `status: 'pending'`; a failed request completes empty,
/// because desktop's global search shows no error row (`.catch(() => [])`).
struct HomePeopleSearchState: Equatable {
    var term: String?
    var pending = false
    var people: [HomeGroupCandidate] = []

    static let idle = HomePeopleSearchState(term: nil)
}

enum HomeSearch {
    static func normalize(_ source: String, locale: Locale) -> String {
        source.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "D")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct HomeBadgeUpdate: Equatable {
    let state: HomeLoadState
    let count: Int
    let isActive: Bool
}

/// The Kit search field (`.ak-field--search`): a full-radius capsule on
/// `fill-quiet` with no ring, the magnifier (16, light) and placeholder in
/// ink-3, the query in `.body` ink; 44 pt tall on the phone (Kit regular
/// control height).
private struct HomeSearchField: View {
    @Binding var query: String
    let prompt: String
    var focused: FocusState<Bool>.Binding
    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let atum {
            HStack(spacing: 8) {
                Image(atum.symbol(.search))
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityHidden(true)
                // Vertical, so the prompt wraps instead of clipping at large
                // text sizes (the accessibility audit); Return never adds a line.
                TextField(text: $query,
                          prompt: Text(verbatim: prompt).foregroundStyle(atum.color(.muted, scheme: scheme)),
                          axis: .vertical) {
                    EmptyView()
                }
                .lineLimit(1...3)
                .onChange(of: query) { _, value in
                    guard value.contains("\n") else { return }
                    query = value.replacingOccurrences(of: "\n", with: "")
                    focused.wrappedValue = false
                }
                .focused(focused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel(prompt)
                .accessibilityIdentifier("home.search")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(atum.symbol(.close))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityLabel(Text(verbatim: prompt))
                    .accessibilityIdentifier("home.search.clear")
                }
            }
            .font(.body)
            .foregroundStyle(atum.color(.ink, scheme: scheme))
            .padding(.horizontal, atum.kit.space(.s3))
            .frame(maxWidth: .infinity, minHeight: atum.kit.phoneControlHeight(.regular))
            .background(atum.kitColor(.fillQuiet, scheme: scheme), in: Capsule())
        }
    }
}

/// What Start chat pushes.
private enum HomeStartChatRoute: Hashable {
    /// Add friend, with the @name typed in the sheet's search (nil from the
    /// footer button).
    case addFriend(String?)
    case newGroup
}

private struct HomeStartChatSheet: View {
    let design: LiveDesign
    let rows: [HomeRow]
    let actions: HomeActions
    let onOpenFounderDraft: () -> Void
    let dismiss: () -> Void

    /// A pushed screen (Add friend with the typed @name, New group).
    @State private var path = [HomeStartChatRoute]()
    @State private var findingAddress = false
    @State private var findAddressFailed = false
    @Environment(\.dismiss) private var systemDismiss
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                // Desktop `start-chat.tsx`: Assistants · People (people, then
                // groups, then an inline "New group") · Apps.
                section(.assistants, rows: assistants)
                section(.people, rows: people + groups) {
                    if !isSearching, actions.newGroup != nil { newGroupRow }
                }
                section(.apps, rows: apps)
                if let findable = query.findable, canFindPeople {
                    Section { findRow(findable) }
                }
            }
            .overlay {
                if isSearching, pickable.isEmpty, query.findable == nil || !canFindPeople {
                    ContentUnavailableView {
                        Text(verbatim: copy(.noMatches))
                    } description: {
                        if canFindPeople { Text(verbatim: copy(.noMatchesHint)) }
                    }
                    .accessibilityIdentifier("home.startChat.noMatches")
                }
            }
            .navigationDestination(for: HomeStartChatRoute.self) { route in
                destination(route)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(atum.color(.ground, scheme: scheme))
            .navigationTitle(copy(.startTitle))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $queryText, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(verbatim: copy(.startSearch)))
            // Return picks the first row, else finds the typed @name (desktop).
            .onSubmit(of: .search) { submitSearch() }
            .safeAreaInset(edge: .bottom, spacing: 0) { creationActions }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { close() }
                        .accessibilityLabel(copy(.cancel))
                }
            }
        }
        .atumDesign(visual: atum)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("home.startChat")
    }

    @ViewBuilder
    private func section(_ key: StartChatCopyKey, rows: [HomeRow]) -> some View {
        section(key, rows: rows) { EmptyView() }
    }

    @ViewBuilder
    private func section<Extra: View>(_ key: StartChatCopyKey, rows: [HomeRow],
                                      @ViewBuilder extra: () -> Extra) -> some View {
        let extra = extra()
        let hasExtra = !isSearching && key == .people && actions.newGroup != nil
        if !rows.isEmpty || hasExtra {
            Section(copy(key)) {
                ForEach(rows) { row in
                    Button {
                        if row.isFounderDraft {
                            close()
                            onOpenFounderDraft()
                        } else {
                            close()
                            actions.openRoom(row.roomID)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            // Home's own face: photos, marks, the crescent,
                            // the raven and app tiles (desktop `start-chat.tsx`).
                            HomeAvatar(row: row, size: 36,
                                       loadMatrixThumbnail: actions.loadMatrixThumbnail)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(verbatim: row.name)
                                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                                        .lineLimit(1)
                                    if row.showsMainAssistantBadge { mainAssistantBadge }
                                }
                                if let caption = caption(for: row) {
                                    Text(verbatim: caption)
                                        .font(.caption)
                                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                    }
                    .disabled(!row.canOpen && !row.isFounderDraft)
                    .accessibilityIdentifier("home.startChat.row.\(row.id)")
                }
                extra
            }
        }
    }

    /// Desktop's captions: a group's "N members", and an assistant whose
    /// chat is still on its way says so ("Getting ready") instead of being
    /// left out. A person's @handle needs the directory's reverse read
    /// (plan SV-4), which the phone does not have yet.
    private func caption(for row: HomeRow) -> String? {
        if row.kind == .group, let count = row.memberCount {
            return design.text(StartChatCopyKey.members.rawValue,
                               arguments: [.number(Int64(max(1, count)))])
        }
        if row.kind.isAssistant, row.isWaitingForRoom {
            let preview = HomePreviewText.text(row.preview, design: design)
            return preview.isEmpty ? nil : preview
        }
        return nil
    }

    private var newGroupRow: some View {
        NavigationLink(value: HomeStartChatRoute.newGroup) {
            HStack(spacing: 12) {
                Image(atum.symbol(.users))
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .frame(width: 36, height: 36)
                    .background(atum.kitColor(.fillQuiet, scheme: scheme), in: Circle())
                    .accessibilityHidden(true)
                Text(verbatim: copy(.newGroup))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
            }
            .frame(minHeight: 44)
        }
        .accessibilityIdentifier("home.startChat.newGroup")
    }

    /// "Find @x on Atum": an @name goes to Add friend, already searching; a
    /// full Matrix address is opened directly, as desktop accepts it quietly.
    private func findRow(_ findable: String) -> some View {
        Button { find() } label: {
            HStack(spacing: 12) {
                Group {
                    if findingAddress {
                        ProgressView()
                    } else {
                        Image(atum.symbol(.search))
                            .font(.body)
                            .foregroundStyle(atum.color(.ink, scheme: scheme))
                    }
                }
                .frame(width: 36, height: 36)
                .background(atum.kitColor(.fillQuiet, scheme: scheme), in: Circle())
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: copy(.findOnAtum, [.text(findable)]))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .lineLimit(1)
                    if findAddressFailed {
                        Text(verbatim: copy(.startFailed))
                            .font(.caption)
                            .foregroundStyle(atum.color(.danger, scheme: scheme))
                    }
                }
            }
            .frame(minHeight: 44)
        }
        .disabled(findingAddress)
        .accessibilityIdentifier("home.startChat.find")
    }

    @ViewBuilder private func destination(_ route: HomeStartChatRoute) -> some View {
        switch route {
        case let .addFriend(handle):
            if let addFriend = actions.addFriend {
                HomeAddFriendView(design: design, submit: addFriend, discovery: actions.peopleDiscovery,
                                  initialHandle: handle) { roomID in
                    close()
                    actions.openRoom(roomID)
                }
            }
        case .newGroup:
            if let newGroup = actions.newGroup {
                HomeNewGroupView(design: design, actions: newGroup) { roomID in
                    close()
                    actions.openRoom(roomID)
                }
            }
        }
    }

    private var canFindPeople: Bool { actions.addFriend != nil }
    private var isSearching: Bool { query != .empty }

    private func submitSearch() {
        if let first = pickable.first {
            close()
            if first.isFounderDraft { onOpenFounderDraft() } else { actions.openRoom(first.roomID) }
        } else if query.findable != nil, canFindPeople {
            find()
        }
    }

    private func find() {
        switch query {
        case let .handle(handle):
            path.append(.addFriend(handle))
        case let .matrixID(userID):
            guard let discovery = actions.peopleDiscovery, !findingAddress else { return }
            findingAddress = true
            findAddressFailed = false
            Task { @MainActor in
                let result = await discovery.open(userID)
                findingAddress = false
                if case let .openRoom(roomID) = result {
                    close()
                    actions.openRoom(roomID)
                } else {
                    findAddressFailed = true
                }
            }
        case .empty, .text:
            break
        }
    }

    // PENDING-COPY:desktop.matrixShell.mainAgent — the badge's spoken label.
    // Until the export carries the key the star is decorative and the name
    // alone is read.
    private var mainAssistantLabel: String? {
        let key = StartChatCopyKey.mainAgent.rawValue
        return design.copy.contains(key) ? design.text(key) : nil
    }

    @ViewBuilder private var mainAssistantBadge: some View {
        let star = Image(atum.symbol(.starFilled))
            .font(.system(size: 13))
            .foregroundStyle(atum.kitColor(.ink3, scheme: scheme))
            .accessibilityIdentifier("home.startChat.mainAssistant")
        if let label = mainAssistantLabel {
            star.accessibilityLabel(Text(verbatim: label))
        } else {
            star.accessibilityHidden(true)
        }
    }

    @ViewBuilder private var creationActions: some View {
        if actions.addFriend != nil || actions.newAssistant != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    creationActionViews
                }
                VStack(spacing: 8) { creationActionViews }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(atum.color(.ground, scheme: scheme))
            .overlay(alignment: .top) {
                Rectangle().fill(atum.color(.frame, scheme: scheme)).frame(height: 0.5)
            }
        }
    }

    @ViewBuilder private var creationActionViews: some View {
        if let newAssistant = actions.newAssistant {
            NavigationLink {
                AssistantNewSheet(design: design, actions: newAssistant) { roomID in
                    close()
                    actions.openRoom(roomID)
                }
            } label: {
                creationLabel(.newAssistant, glyph: .plus)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("home.startChat.newAssistant")
        }
        if actions.addFriend != nil {
            NavigationLink(value: HomeStartChatRoute.addFriend(nil)) {
                creationLabel(.addFriend, glyph: .userCircle)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("home.startChat.addFriend")
        }
    }

    private func creationLabel(_ key: StartChatCopyKey, glyph: AtumGlyph) -> some View {
        Label(copy(key), image: atum.symbol(glyph))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
    }

    /// The typed text, and what it means (`StartChatQuery`).
    @State private var queryText = ""
    private var query: StartChatQuery { StartChatQuery.parse(queryText) }

    private var visibleRows: [HomeRow] {
        let locale = Locale(identifier: design.locale)
        let needle = HomeSearch.normalize(queryText, locale: locale)
        return rows.filter { row in
            // Every assistant is listed, one whose chat is still on its way
            // too (desktop lists every projected agent); it opens once ready.
            !row.isInvitation && (row.canOpen || (row.kind.isAssistant && row.isWaitingForRoom))
                && (needle.isEmpty || HomeSearch.normalize(row.name, locale: locale).contains(needle))
        }
    }

    /// What Return picks: the first row that opens, in the sheet's order.
    private var pickable: [HomeRow] {
        (assistants + people + groups + apps).filter { $0.canOpen || $0.isFounderDraft }
    }

    private var assistants: [HomeRow] { visibleRows.filter(\.kind.isAssistant) }
    private var people: [HomeRow] { visibleRows.filter { $0.kind == .person } }
    private var groups: [HomeRow] { visibleRows.filter { $0.kind == .group } }
    private var apps: [HomeRow] { visibleRows.filter { $0.kind == .app } }

    private func copy(_ key: StartChatCopyKey, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key.rawValue, arguments: arguments)
    }

    private func close() {
        dismiss()
        systemDismiss()
    }
}

private struct HomeAddFriendView: View {
    let design: LiveDesign
    let submit: (String) async -> HomeAddFriendResult
    var discovery: HomePeopleDiscoveryActions? = nil
    /// HC-5: Start chat's "Find @x on Atum" arrives with the @name typed and
    /// the search already started, as desktop's `onFindPerson(query)`.
    var initialHandle: String? = nil
    let openRoom: (String) -> Void

    private enum Presentation: Equatable {
        case idle
        case searching
        case notFound(String)
        case notMessageable
        case rateLimited(Int?)
        case searchFailed
        case startFailed
    }

    @State private var matches = [HomeGroupCandidate]()
    @State private var directoryFailed = false
    @State private var query = ""
    @State private var presentation: Presentation = .idle
    @State private var request: Task<Void, Never>?
    @State private var startsWhenFilled = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var handle: String? { HomeAddFriendPolicy.handle(query)?.rawValue }

    var body: some View {
        Form {
            Section {
                Text(copy(.addFriendBody))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))

                TextField(copy(.handlePlaceholder), text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .accessibilityLabel(copy(.handleLabel))
                    .accessibilityIdentifier("home.addFriend.handle")
                    .onSubmit { start() }
            } header: {
                Text(copy(.handleLabel))
            }

            Section {
                Button { start() } label: {
                    HStack(spacing: 8) {
                        if presentation == .searching { ProgressView() }
                        Text(actionLabel)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                }
                .disabled(handle == nil || presentation == .searching)
                .accessibilityIdentifier("home.addFriend.find")
            }

            if !matches.isEmpty {
                Section(copy(.people)) {
                    ForEach(matches) { person in
                        Button {
                            guard let discovery, presentation != .searching else { return }
                            presentation = .searching
                            request = Task { @MainActor in
                                let result = await discovery.open(person.id)
                                guard !Task.isCancelled else { return }
                                if case let .openRoom(roomID) = result { openRoom(roomID) }
                                else { presentation = .startFailed }
                            }
                        } label: {
                            HomeDiscoveryPersonRow(design: design, person: person, load: discovery?.loadMatrixThumbnail)
                        }
                        .disabled(presentation == .searching)
                    }
                }
            }
            if directoryFailed {
                Text(copy(.searchFailed)).foregroundStyle(atum.color(.danger, scheme: scheme))
            }
            if let notice {
                Section {
                    Text(notice)
                        .foregroundStyle(noticeIsFailure
                            ? atum.color(.danger, scheme: scheme)
                            : atum.color(.muted, scheme: scheme))
                        .accessibilityIdentifier("home.addFriend.notice")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme))
        .navigationTitle(copy(.addFriendTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query) {
            matches = []
            directoryFailed = false
            guard let discovery, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            let found = await discovery.search(query)
            guard !Task.isCancelled else { return }
            matches = found ?? []
            directoryFailed = found == nil
        }
        .onAppear {
            if let initialHandle, query.isEmpty {
                // The search starts once the typed @name has landed (below),
                // so the edit that puts it there does not cancel it.
                startsWhenFilled = true
                query = initialHandle
            } else {
                focused = true
            }
        }
        .onChange(of: query) { _, _ in
            request?.cancel()
            request = nil
            presentation = .idle
            if startsWhenFilled {
                startsWhenFilled = false
                start()
            }
        }
        .onDisappear {
            request?.cancel()
            request = nil
        }
    }

    private var actionLabel: String {
        guard presentation != .searching else { return copy(.searching) }
        guard let handle else { return copy(.find) }
        return copy(.findOnAtum, [.text(handle)])
    }

    private var notice: String? {
        switch presentation {
        case .idle, .searching: nil
        case let .notFound(handle): copy(.notFound, [.text(handle)])
        case .notMessageable: copy(.noAddress)
        case let .rateLimited(seconds?): copy(.rateLimited, [.number(Int64(max(0, seconds)))])
        case .rateLimited(nil): copy(.rateLimitedSoon)
        case .searchFailed: copy(.searchFailed)
        case .startFailed: copy(.startFailed)
        }
    }

    private var noticeIsFailure: Bool {
        switch presentation {
        case .idle, .searching: false
        default: true
        }
    }

    private func start() {
        guard let handle, presentation != .searching else { return }
        request?.cancel()
        presentation = .searching
        request = Task { @MainActor in
            let result = await submit(handle)
            guard !Task.isCancelled else { return }
            request = nil
            switch result {
            case let .openRoom(roomID): openRoom(roomID)
            case let .notFound(handle): presentation = .notFound(handle)
            case .notMessageable: presentation = .notMessageable
            case let .rateLimited(seconds): presentation = .rateLimited(seconds)
            case .searchFailed: presentation = .searchFailed
            case .startFailed: presentation = .startFailed
            }
        }
    }

    private func copy(_ key: StartChatCopyKey,
                      _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key.rawValue, arguments: arguments)
    }
}
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
/// transcript in this app only. The first message makes the one chat and its invitation; until
/// then nothing exists on the server.
struct FounderDraftSheet: View {
    let design: LiveDesign
    let draft: FounderDraftActions
    let dismiss: () -> Void

    @State private var text = ""
    @State private var sending = false
    @State private var failed = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var placeholder: String {
        design.text("desktop.atum.composer.placeholderFor", arguments: [.text(draft.name)])
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    FounderRavenAvatar(size: 72, fallbackName: draft.name)
                    HStack(spacing: 4) {
                        Text(verbatim: draft.name)
                            .font(.title3.weight(.semibold))
                        AppSeal(tier: .official, placement: .chatTitle, label: .officialAccount)
                    }
                    Text(verbatim: draft.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                    Text(verbatim: draft.intro)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 28)

                Spacer(minLength: 24)

                if failed {
                    Text(verbatim: draft.unready)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 6)
                        .accessibilityIdentifier("home.founderDraft.notice")
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(atum.color(.cell, scheme: scheme), in: Capsule())
                        .accessibilityLabel(Text(verbatim: placeholder))
                        .accessibilityIdentifier("home.founderDraft.composer")
                    Button(design.text("desktop.common.send")) { send() }
                        .buttonStyle(.borderedProminent)
                        .tint(atum.color(.ink, scheme: scheme))
                        .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("home.founderDraft.send")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
            .navigationTitle(Text(verbatim: draft.name))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                        .accessibilityLabel(Text(verbatim: design.text("src.matrix.founder.founder-copy.FOUNDER_COPY.close")))
                }
            }
            .accessibilityIdentifier("home.founderDraft")
        }
        .onAppear { focused = true }
    }

    private func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sending else { return }
        sending = true
        failed = false
        Task { @MainActor in
            let sent = await draft.send(body)
            sending = false
            if sent {
                dismiss()
            } else {
                failed = true
            }
        }
    }
}

private struct HomeNewGroupView: View {
    let design: LiveDesign
    let actions: HomeGroupActions
    let openRoom: (String) -> Void

    private enum LookupPresentation: Equatable {
        case idle, searching, notMessageable, failed
        case notFound(String)
        case rateLimited(Int?)
    }

    @State private var name = ""
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var discovered = [HomeGroupCandidate]()
    @State private var directoryMatches = [HomeGroupCandidate]()
    @State private var lookupPresentation: LookupPresentation = .idle
    @State private var lookupTask: Task<Void, Never>?
    @State private var creationTask: Task<Void, Never>?
    @State private var creating = false
    @State private var createFailed = false
    @FocusState private var nameFocused: Bool
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        AtumAvatar.shape(for: .group, size: 44).fill(atum.color(.cell, scheme: scheme))
                        Image(atum.symbol(.users))
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                    }
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                    TextField(copy(.groupNamePlaceholder), text: $name)
                        .focused($nameFocused)
                        .accessibilityLabel(copy(.groupName))
                        .accessibilityIdentifier("home.newGroup.name")
                }
            }

            Section {
                TextField(copy(.handlePlaceholder), text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityLabel(copy(.handleLabel))
                    .accessibilityIdentifier("home.newGroup.handle")
                    .onSubmit { lookup() }
                Button { lookup() } label: {
                    HStack(spacing: 8) {
                        if lookupPresentation == .searching { ProgressView() }
                        Text(lookupActionLabel)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                }
                .disabled(findableHandle == nil || lookupPresentation == .searching
                          || selected.count >= HomeGroupPolicy.maximumInvites)
                .accessibilityIdentifier("home.newGroup.find")
                if let lookupNotice {
                    Text(lookupNotice)
                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                        .accessibilityIdentifier("home.newGroup.lookupNotice")
                }
            } header: {
                Text(copy(.nameOnly))
            }

            if !people.isEmpty {
                Section(copy(.people)) {
                    ForEach(people) { candidateRow($0) }
                }
            }

            Section {
                Text(copy(.historyShared))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                if selected.count >= HomeGroupPolicy.maximumInvites {
                    Text(copy(.groupFull))
                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                }
                if createFailed {
                    Text(copy(.groupFailed))
                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                        .accessibilityIdentifier("home.newGroup.failure")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme))
        .navigationTitle(copy(.groupCreateTitle))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { create() } label: {
                HStack(spacing: 8) {
                    if creating { ProgressView() }
                    Text(creating ? copy(.creating) : copy(.createGroup))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreate)
            .accessibilityIdentifier("home.newGroup.create")
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(atum.color(.ground, scheme: scheme))
            .overlay(alignment: .top) {
                Rectangle().fill(atum.color(.frame, scheme: scheme)).frame(height: 0.5)
            }
        }
        .task(id: query) {
            directoryMatches = []
            guard let search = actions.search, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            let found = await search(query)
            guard !Task.isCancelled else { return }
            directoryMatches = found ?? []
            if found == nil { lookupPresentation = .failed }
        }
        .onAppear { nameFocused = true }
        .onChange(of: name) { _, _ in createFailed = false }
        .onChange(of: query) { _, _ in
            lookupTask?.cancel()
            lookupTask = nil
            lookupPresentation = .idle
        }
        .onDisappear {
            lookupTask?.cancel()
            creationTask?.cancel()
        }
    }

    private var candidates: [HomeGroupCandidate] {
        var seen = Set<String>()
        return (directoryMatches + discovered + actions.candidates).filter { seen.insert($0.id).inserted }
    }

    private var people: [HomeGroupCandidate] { candidates.filter { $0.kind == .person } }
    private var selectedCandidates: [HomeGroupCandidate] {
        candidates.filter { selected.contains($0.id) }
    }
    private var findableHandle: String? { HomeAddFriendPolicy.handle(query)?.rawValue }
    private var canCreate: Bool {
        !creating && HomeGroupPolicy.name(typed: name, selected: selectedCandidates) != nil
    }

    private func candidateRow(_ candidate: HomeGroupCandidate) -> some View {
        let isSelected = selected.contains(candidate.id)
        let canSelect = HomeGroupPolicy.canSelect(candidate, selected: selectedCandidates)
        return Button {
            createFailed = false
            nameFocused = false
            if isSelected { selected.remove(candidate.id) }
            else if canSelect {
                if !discovered.contains(where: { $0.id == candidate.id }) { discovered.append(candidate) }
                selected.insert(candidate.id)
            }
        } label: {
            HStack(spacing: 12) {
                HomeDiscoveryPersonRow(design: design, person: candidate, load: actions.loadMatrixThumbnail)
                Spacer(minLength: 8)
                if isSelected {
                    Image(atum.symbol(.check))
                        .foregroundStyle(atum.color(.actionStrong, scheme: scheme))
                }
            }
            .frame(minHeight: 44)
        }
        .disabled(!isSelected && !canSelect)
        .accessibilityIdentifier("home.newGroup.member.\(candidate.id)")
    }

    private var lookupActionLabel: String {
        guard lookupPresentation != .searching else { return copy(.searching) }
        guard let handle = findableHandle else { return copy(.find) }
        return copy(.findOnAtum, [.text(handle)])
    }

    private var lookupNotice: String? {
        switch lookupPresentation {
        case .idle, .searching: nil
        case let .notFound(handle): copy(.notFound, [.text(handle)])
        case .notMessageable: copy(.noAddress)
        case let .rateLimited(seconds?): copy(.rateLimited, [.number(Int64(max(0, seconds)))])
        case .rateLimited(nil): copy(.rateLimitedSoon)
        case .failed: copy(.searchFailed)
        }
    }

    private func lookup() {
        guard let handle = findableHandle, lookupPresentation != .searching else { return }
        lookupTask?.cancel()
        lookupPresentation = .searching
        lookupTask = Task { @MainActor in
            let result = await actions.lookup(handle)
            guard !Task.isCancelled else { return }
            lookupTask = nil
            switch result {
            case let .candidate(candidate):
                if !candidates.contains(where: { $0.id == candidate.id }) {
                    discovered.append(candidate)
                }
                if HomeGroupPolicy.canSelect(candidate, selected: selectedCandidates) {
                    selected.insert(candidate.id)
                }
                query = ""
                lookupPresentation = .idle
            case let .notFound(handle): lookupPresentation = .notFound(handle)
            case .notMessageable: lookupPresentation = .notMessageable
            case let .rateLimited(seconds): lookupPresentation = .rateLimited(seconds)
            case .failed: lookupPresentation = .failed
            }
        }
    }

    private func create() {
        guard canCreate else { return }
        lookupTask?.cancel()
        creationTask?.cancel()
        creating = true
        createFailed = false
        let members = selectedCandidates
        creationTask = Task { @MainActor in
            let result = await actions.create(name, members)
            guard !Task.isCancelled else { return }
            creationTask = nil
            creating = false
            switch result {
            case let .openRoom(roomID): openRoom(roomID)
            case .failed: createFailed = true
            }
        }
    }

    private func copy(_ key: StartChatCopyKey,
                      _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key.rawValue, arguments: arguments)
    }
}

private struct HomeDebugBadgeValue: ViewModifier {
    let value: Int

    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
        content.accessibilityValue("badge:\(value)")
        #else
        content
        #endif
    }
}

private struct HomeRowView: View {
    let design: LiveDesign
    let row: HomeRow
    let now: Date
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?
    let isJoining: Bool
    var isSearching = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibleLayout
            } else {
                compactLayout
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .modifier(HomeJoiningDebugValue(isJoining: isJoining))
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var previewText: String { HomePreviewText.text(row.preview, design: design) }
    private var timeText: String {
        guard let date = row.latestEventAt else { return "" }
        return HomeTimeText.text(date: date, now: now, design: design)
    }

    private var compactLayout: some View {
        HStack(spacing: 12) {
            HomeAvatar(row: row, size: 52, loadMatrixThumbnail: loadMatrixThumbnail)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: row.name)
                        .font(nameFont)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .lineLimit(1)
                    if row.verification != nil {
                        AppSeal(tier: row.verification)
                            .accessibilityHidden(true)
                    }
                    if row.isMuted {
                        Image(atum.symbol(.bellOff))
                            .font(.footnote)
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 8)
                    timeOrJoining
                }
                HStack(spacing: 6) {
                    if row.isWaitingForRoom {
                        ProgressView()
                            .controlSize(.mini)
                            .accessibilityHidden(true)
                    } else {
                        sendStateGlyph
                    }
                    Text(verbatim: previewText.isEmpty ? " " : previewText)
                        .font(.subheadline)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    HomeBadgeView(design: design, badge: row.badge, pinned: row.isPinned)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { dimension in dimension[.leading] }
        }
    }

    private var accessibleLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                HomeAvatar(row: row, size: 52, loadMatrixThumbnail: loadMatrixThumbnail)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: row.name)
                        .font(nameFont)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .lineLimit(2)
                    if row.verification != nil {
                        AppSeal(tier: row.verification)
                            .accessibilityHidden(true)
                    }
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if row.isWaitingForRoom {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                } else {
                    sendStateGlyph
                }
                Text(verbatim: previewText.isEmpty ? " " : previewText)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                timeOrJoining
                if row.isMuted {
                    Image(atum.symbol(.bellOff))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                }
                HomeBadgeView(design: design, badge: row.badge, pinned: row.isPinned)
            }
        }
    }

    @ViewBuilder private var sendStateGlyph: some View {
        switch row.preview.sendState {
        case .sent:
            EmptyView()
        case .sending:
            Image(atum.symbol(.clock))
                .font(.caption)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityHidden(true)
        case .cannotBeSent:
            Image(atum.symbol(.alertCircle))
                .font(.caption)
                .foregroundStyle(atum.color(.danger, scheme: scheme))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var timeOrJoining: some View {
        if isJoining || showsWorking {
            // Joining, or my assistant at work (HC-3, desktop `RosterWorking`):
            // Atum's atom in the time's place.
            AtomWait()
                .frame(width: 14, height: 14)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityHidden(true)
        } else {
            Text(verbatim: timeText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(timeColor)
                .lineLimit(1)
        }
    }

    /// Desktop shows no atom while searching: the list then finds, it does
    /// not report.
    private var showsWorking: Bool { row.isWorking && !isSearching }

    /// Times are ink-3 whatever the row's state (FlowPhone); the badge and
    /// the name's weight carry unread.
    private var timeColor: Color { atum.color(.muted, scheme: scheme) }

    /// Semibold while the row has unread activity, regular once read.
    private var nameFont: Font {
        row.badge == .none ? .body : .body.weight(.semibold)
    }

    private var accessibilityLabel: String {
        var parts = [row.name]
        if row.kind == .app {
            parts.append(design.text(row.verification == .verified
                                     ? HomeCopyKey.partnerApp.rawValue
                                     : HomeCopyKey.firstPartyApp.rawValue))
        } else if row.kind == .person, row.verification == .official {
            parts.append(design.text("src.matrix.founder.founder-copy.FOUNDER_COPY.officialAccount"))
        }
        switch row.badge {
        case let .mention(count):
            parts.append(design.text(HomeCopyKey.unread.rawValue, arguments: [.number(Int64(count))]))
            parts.append(design.text(HomeCopyKey.mentions.rawValue))
        case let .count(count):
            parts.append(design.text(HomeCopyKey.unread.rawValue, arguments: [.number(Int64(count))]))
        case .dot, .quietDot:
            parts.append(design.text(HomeCopyKey.newMessages.rawValue))
        case .none:
            break
        }
        if row.isMuted { parts.append(design.text(HomeCopyKey.muted.rawValue)) }
        if row.isPinned { parts.append(design.text(HomeCopyKey.pinned.rawValue)) }
        switch row.preview.sendState {
        case .sending: parts.append(design.text(HomeCopyKey.pending.rawValue))
        case .cannotBeSent: parts.append(design.text(HomeCopyKey.notSent.rawValue))
        case .sent: break
        }
        if !previewText.isEmpty { parts.append(previewText) }
        if isJoining { parts.append(design.text(HomeCopyKey.loading.rawValue)) }
        else if showsWorking {
            parts.append(design.text(HomeCopyKey.working.rawValue, arguments: [.text(row.name)]))
        } else if !timeText.isEmpty { parts.append(timeText) }
        return parts.joined(separator: ", ")
    }
}

private struct HomeJoiningDebugValue: ViewModifier {
    let isJoining: Bool

    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
        content.accessibilityValue(isJoining ? "joining" : "")
        #else
        content
        #endif
    }
}

/// The one face Home draws for a row. Settings > Assistants draws it too, so an
/// assistant looks the same in both places.
struct HomeAvatar: View {
    let row: HomeRow
    let size: CGFloat
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?

    @State private var art: AtumAvatarArt?
    @State private var loadedRequest: HomeAvatarRequest?

    private var request: HomeAvatarRequest {
        HomeAvatarRequest(url: row.avatarURL, matrixURI: row.matrixAvatarURL,
                          sha256: row.avatarSHA256, candidates: row.avatarCandidates)
    }

    var body: some View {
        Group {
            if row.isFounder {
                FounderRavenAvatar(size: size, fallbackName: row.name)
            } else {
                AtumAvatar(kind: row.kind.avatarKind, name: row.name, art: art,
                           mark: row.mark,
                           placeholder: row.hasAvatarSource ? .neutral : .monogram,
                           size: size)
                    .task(id: request) {
                        if loadedRequest != request {
                            art = HomeAvatarArtCache.shared.art(for: request)
                            loadedRequest = request
                        }
                        guard art == nil else { return }
                        let pixelSide = AtumAvatar.thumbnailPixelSide(for: 72)
                        let candidates = AtumAvatarCandidateLoader.candidates(
                            avatar: row.avatarURL.map {
                                LiveProductAvatar.photo(url: $0, fallback: row.name)
                            },
                            sha256: row.avatarSHA256,
                            declared: row.avatarCandidates
                        )
                        let loaded = await AtumAvatarCandidateLoader.load(
                            matrixURI: row.matrixAvatarURL,
                            pixelSide: pixelSide,
                            loadMatrixThumbnail: loadMatrixThumbnail,
                            remoteCandidates: candidates
                        )
                        guard !Task.isCancelled else { return }
                        art = loaded
                        if let loaded {
                            HomeAvatarArtCache.shared.store(loaded, for: request)
                        }
                    }
            }
        }
        .saturation(row.isComingSoon ? 0 : 1)
    }
}

private struct HomeAvatarRequest: Hashable {
    let url: URL?
    let matrixURI: String?
    let sha256: String?
    let candidates: [LiveProductRemoteArt]

    var cacheKey: String {
        let candidateKey = candidates
            .map { $0.url.absoluteString + "#" + ($0.sha256 ?? "") }
            .joined(separator: "|")
        return [url?.absoluteString ?? "", matrixURI ?? "", sha256 ?? "", candidateKey]
            .joined(separator: "\n")
    }
}

/// Decoded row faces survive the view being rebuilt (a list diff, a scroll
/// back, an account refresh), so a photo never blinks back to a placeholder.
@MainActor
private final class HomeAvatarArtCache {
    static let shared = HomeAvatarArtCache()

    private var values = [String: AtumAvatarArt]()
    private var order = [String]()
    private let capacity = 200

    func art(for request: HomeAvatarRequest) -> AtumAvatarArt? {
        let key = request.cacheKey
        guard let value = values[key] else { return nil }
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
        return value
    }

    func store(_ art: AtumAvatarArt, for request: HomeAvatarRequest) {
        let key = request.cacheKey
        values[key] = art
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
        while order.count > capacity {
            values.removeValue(forKey: order.removeFirst())
        }
    }
}

struct HomeBadgeView: View {
    let design: LiveDesign
    let badge: Badge
    let pinned: Bool

    @ScaledMetric(relativeTo: .caption) private var dotSize = 10.0
    @ScaledMetric(relativeTo: .caption) private var quietDotSize = 8.0
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    @ViewBuilder var body: some View {
        switch badge {
        case let .mention(count): pill(count, fill: atum.color(.danger, scheme: scheme),
                                      text: atum.color(.onDanger, scheme: scheme))
        case let .count(count): pill(count, fill: atum.color(.ink, scheme: scheme),
                                    text: atum.color(.onInk, scheme: scheme))
        case .dot:
            Circle().fill(atum.color(.ink, scheme: scheme)).frame(width: dotSize, height: dotSize)
        case .quietDot:
            Circle().fill(atum.color(.muted, scheme: scheme)).frame(width: quietDotSize, height: quietDotSize)
        case .none where pinned:
            Image(atum.symbol(.pinFilled))
                .font(.footnote)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
        case .none:
            EmptyView()
        }
    }

    private func pill(_ count: Int, fill: Color, text: Color) -> some View {
        Text(verbatim: Badge.pillText(count))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(text)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 20)
            .background(fill, in: Capsule())
    }
}

private struct HomeDomainReauthenticationCard: View {
    let design: LiveDesign
    let busy: Bool
    let action: (() -> Void)?

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(DomainRecoveryPendingCopy.text(locale: design.locale))
                .font(.subheadline)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(design.text("src.matrix.launch-copy.copies.signInAgain")) {
                action?()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .tint(atum.color(.ink, scheme: scheme))
            .foregroundStyle(atum.color(.onInk, scheme: scheme))
            .frame(minHeight: 44)
            .disabled(busy || action == nil)
            .accessibilityIdentifier("home.domain.sign-in")
        }
        .padding(16)
        .background(atum.color(.cell, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityIdentifier("home.domain.card")
    }
}

/// Owner-approved phone line pending its shared atum-app export. It stays one
/// sentence in every shipped locale and is the card's only explanatory copy.
private enum DomainRecoveryPendingCopy {
    static func text(locale: String) -> String {
        switch locale {
        case "vi": "Đăng nhập lại để thấy trợ lý của bạn"
        case "ja": "アシスタントを見るには、もう一度サインインしてください"
        case "zh": "重新登录即可查看你的助手"
        case "zh-Hant": "重新登入即可查看你的助理"
        default: "Sign in again to see your assistants"
        }
    }
}

private struct HomeNotificationCard: View {
    let design: LiveDesign
    let onAnswer: ((Bool) -> Void)?

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(design.text(HomeCopyKey.notificationTitle.rawValue))
                .font(.body.weight(.semibold))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
            Text(design.text(HomeCopyKey.notificationHelp.rawValue))
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
            HStack(spacing: 10) {
                Button(design.text(HomeCopyKey.allow.rawValue)) { onAnswer?(true) }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.regular)
                    .tint(atum.color(.ink, scheme: scheme))
                    .foregroundStyle(atum.color(.onInk, scheme: scheme))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("live-notifications-allow")
                Button(design.text(HomeCopyKey.notNow.rawValue)) { onAnswer?(false) }
                    .buttonStyle(.borderless)
                    .font(.subheadline)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("live-notifications-not-now")
            }
        }
        .padding(16)
        .background(atum.color(.cell, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// A Delete chat / Leave group waiting for its confirmation.
struct HomePendingExit: Equatable {
    let roomID: String
    let action: ChatExitAction
}

enum HomeRowActionPolicy {
    static func canOfferPin(row: HomeRow, pinnedCount: Int) -> Bool {
        !row.isComingSoon && (row.isPinned || pinnedCount < RosterProjection.pinLimit)
    }

    static func offersDelete(row: HomeRow, hasDeleteAction: Bool) -> Bool {
        !row.isComingSoon && row.canDeleteAppRoom && hasDeleteAction
    }

    /// The row's Matrix exit (`ChatExitPolicy`): Delete chat for a person,
    /// Leave group for a group; nothing for assistants, apps, the Founder chat
    /// of the Founder, invitations, drafts and rows that are not rooms yet.
    static func exitAction(row: HomeRow, viewerIsFounder: Bool, hasAction: Bool) -> ChatExitAction? {
        guard hasAction, !row.isComingSoon, !row.awaitsStart, !row.isFounderDraft,
              !row.isWaitingForRoom, !row.roomID.hasPrefix("app:") else { return nil }
        return ChatExitPolicy.action(for: row.exitRoom, viewerIsFounder: viewerIsFounder)
    }

    static func offersShortcutHide(row: HomeRow, hasAction: Bool) -> Bool {
        row.isComingSoon && row.id.hasPrefix("app:") && hasAction
    }

    /// "Info" on an app's row: its chat, or a catalog app not started yet.
    /// A coming-soon placeholder has no card (desktop `MatrixComingSoonRow`).
    static func offersAppInfo(row: HomeRow, hasAction: Bool) -> Bool {
        hasAction && row.kind == .app && !row.isComingSoon && !row.isInvitation
    }
}

/// HC-7: a Home row's personal-chat menu items, built by the screen (which
/// holds the Rename alert, the Block confirmation and who is blocked).
struct HomeRowPersonalMenu {
    struct Block {
        let isBlocked: Bool
        let toggle: () -> Void
    }

    var setLowPriority: ((String, Bool) -> Void)?
    var rename: ((String) -> Void)?
    var block: Block?

    var hasItems: Bool { setLowPriority != nil || rename != nil || block != nil }
}

private struct HomePendingBlock: Identifiable, Equatable {
    let roomID: String
    let userID: String
    var id: String { roomID }
}

private struct HomeRowActionsModifier: ViewModifier {
    let design: LiveDesign
    let row: HomeRow
    let pinnedCount: Int
    let actions: HomeActions
    let requestDeleteAppRoom: ((String) -> Void)?
    var requestExit: ((String, ChatExitAction) -> Void)? = nil
    /// "Info" on an app row (desktop `RosterAppMenu`).
    var requestAppInfo: ((String) -> Void)? = nil
    var personal = HomeRowPersonalMenu()

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var hasBadge: Bool { row.badge != .none }
    private var exitAction: ChatExitAction? {
        HomeRowActionPolicy.exitAction(row: row, viewerIsFounder: actions.viewerIsFounder,
                                       hasAction: requestExit != nil)
    }
    private func exitTitle(_ action: ChatExitAction) -> String {
        design.text(action == .deleteChat ? HomeCopyKey.deleteChat.rawValue : "desktop.dm.group.leave")
    }
    private var canOfferPin: Bool { HomeRowActionPolicy.canOfferPin(row: row, pinnedCount: pinnedCount) }
    private var offersDelete: Bool {
        HomeRowActionPolicy.offersDelete(row: row, hasDeleteAction: requestDeleteAppRoom != nil)
    }
    private var hasMenuAction: Bool {
        if row.isInvitation { return actions.declineInvitation != nil }
        return actions.setUnread != nil || actions.setPinned != nil || actions.setMuted != nil
            || offersDelete || exitAction != nil || offersAppInfo || personal.hasItems
    }
    private var offersAppInfo: Bool {
        HomeRowActionPolicy.offersAppInfo(row: row, hasAction: requestAppInfo != nil)
    }

    private var appInfoButton: some View {
        Button { requestAppInfo?(row.id) } label: {
            Label(design.text(AppCardCopy.menuInfo), image: atum.symbol(.info))
        }
        .accessibilityIdentifier("home.row.app-info")
    }

    @ViewBuilder func body(content: Content) -> some View {
        if row.isComingSoon || row.awaitsStart || row.isFounderDraft {
            // No room exists behind a draft: no unread, mute, pin or membership action may
            // be sent for it.
            comingSoon(content)
        } else {
            interactive(content)
        }
    }

    @ViewBuilder
    private func comingSoon(_ content: Content) -> some View {
        if HomeRowActionPolicy.offersShortcutHide(
            row: row, hasAction: actions.setAppShortcutVisibility != nil
        ),
           let appID = row.id.hasPrefix("app:") ? String(row.id.dropFirst(4)) : nil,
           let setVisibility = actions.setAppShortcutVisibility {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { _ = await setVisibility(appID, false) }
                    } label: {
                        Text(design.text("src.matrix.app-copy.matrixAppCopy.hideShortcut"))
                    }
                    .tint(atum.color(.actionQuiet, scheme: scheme))
                }
                .contextMenu {
                    Button(role: .destructive) {
                        Task { _ = await setVisibility(appID, false) }
                    } label: {
                        Text(design.text("src.matrix.app-copy.matrixAppCopy.hideShortcut"))
                    }
                }
                .accessibilityAction(named: Text(design.text(
                    "src.matrix.app-copy.matrixAppCopy.hideShortcut"
                ))) {
                    Task { _ = await setVisibility(appID, false) }
                }
        } else if offersAppInfo {
            // A catalog app with no chat yet keeps its card (desktop wraps its
            // catalog row in `RosterAppMenu` too); still no room operation.
            content
                .contextMenu { appInfoButton }
                .accessibilityAction(named: Text(design.text(AppCardCopy.menuInfo))) {
                    requestAppInfo?(row.id)
                }
        } else {
            // No room exists behind a presentation-only catalog row, so no
            // unread, mute, pin, delete or membership operation may be sent.
            content
        }
    }

    @ViewBuilder
    private func interactive(_ content: Content) -> some View {
        let swipeContent = content
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !row.isInvitation, let setUnread = actions.setUnread {
                    Button {
                        setUnread(row.roomID, !hasBadge)
                    } label: {
                        Label(design.text(hasBadge ? HomeCopyKey.markRead.rawValue : HomeCopyKey.markUnread.rawValue),
                              image: atum.symbol(hasBadge ? .mailOpened : .mail))
                    }
                    .tint(atum.color(.actionStrong, scheme: scheme))
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if let exitAction, let requestExit {
                    Button(role: .destructive) { requestExit(row.roomID, exitAction) } label: {
                        Label(exitTitle(exitAction),
                              image: atum.symbol(exitAction == .deleteChat ? .trash : .logOut))
                    }
                    .tint(atum.kitColor(.danger, scheme: scheme))
                }
                if !row.isInvitation, let setMuted = actions.setMuted {
                    Button {
                        setMuted(row.roomID, !row.isMuted)
                    } label: {
                        Label(design.text(row.isMuted ? HomeCopyKey.unmute.rawValue : HomeCopyKey.mute.rawValue),
                              image: atum.symbol(row.isMuted ? .bell : .bellOff))
                    }
                    .tint(atum.color(.actionQuiet, scheme: scheme))
                }
                if !row.isInvitation, canOfferPin, let setPinned = actions.setPinned {
                    Button {
                        setPinned(row.roomID, !row.isPinned)
                    } label: {
                        Label(design.text(row.isPinned ? HomeCopyKey.unpin.rawValue : HomeCopyKey.pin.rawValue),
                              image: atum.symbol(row.isPinned ? .pinOff : .pin))
                    }
                    .tint(atum.color(.actionStrong, scheme: scheme))
                }
            }
        let accessibleContent = applyingAccessibilityActions(to: swipeContent)
            .accessibilityActions {
                if offersAppInfo {
                    Button(design.text(AppCardCopy.menuInfo)) { requestAppInfo?(row.id) }
                }
                if let exitAction, let requestExit {
                    Button(exitTitle(exitAction)) { requestExit(row.roomID, exitAction) }
                }
            }
        if hasMenuAction {
            accessibleContent.contextMenu { menuItems }
        } else {
            accessibleContent
        }
    }

    @ViewBuilder
    private func applyingAccessibilityActions<Content: View>(to content: Content) -> some View {
        if row.isInvitation {
            if let decline = actions.declineInvitation {
                content.accessibilityAction(named: Text(design.text(HomeCopyKey.declineInvite.rawValue))) {
                    decline(row.roomID)
                }
            } else {
                content
            }
        } else if canOfferPin {
            let standard = content
                .accessibilityAction(named: Text(design.text(
                    hasBadge ? HomeCopyKey.markRead.rawValue : HomeCopyKey.markUnread.rawValue
                ))) {
                    actions.setUnread?(row.roomID, !hasBadge)
                }
                .accessibilityAction(named: Text(design.text(
                    row.isPinned ? HomeCopyKey.unpin.rawValue : HomeCopyKey.pin.rawValue
                ))) {
                    actions.setPinned?(row.roomID, !row.isPinned)
                }
                .accessibilityAction(named: Text(design.text(
                    row.isMuted ? HomeCopyKey.unmute.rawValue : HomeCopyKey.mute.rawValue
                ))) {
                    actions.setMuted?(row.roomID, !row.isMuted)
                }
            if offersDelete, let requestDeleteAppRoom {
                standard.accessibilityAction(named: Text(design.text(HomeCopyKey.deleteChat.rawValue))) {
                    requestDeleteAppRoom(row.roomID)
                }
            } else {
                standard
            }
        } else {
            let standard = content
                .accessibilityAction(named: Text(design.text(
                    hasBadge ? HomeCopyKey.markRead.rawValue : HomeCopyKey.markUnread.rawValue
                ))) {
                    actions.setUnread?(row.roomID, !hasBadge)
                }
                .accessibilityAction(named: Text(design.text(
                    row.isMuted ? HomeCopyKey.unmute.rawValue : HomeCopyKey.mute.rawValue
                ))) {
                    actions.setMuted?(row.roomID, !row.isMuted)
                }
            if offersDelete, let requestDeleteAppRoom {
                standard.accessibilityAction(named: Text(design.text(HomeCopyKey.deleteChat.rawValue))) {
                    requestDeleteAppRoom(row.roomID)
                }
            } else {
                standard
            }
        }
    }

    @ViewBuilder private var menuItems: some View {
        if row.isInvitation {
            if let decline = actions.declineInvitation {
                Button(role: .destructive) { decline(row.roomID) } label: {
                    Text(design.text(HomeCopyKey.declineInvite.rawValue))
                }
            }
        } else {
            if offersAppInfo {
                appInfoButton
                Divider()
            }
            if let setUnread = actions.setUnread {
                Button { setUnread(row.roomID, !hasBadge) } label: {
                    Label(design.text(hasBadge ? HomeCopyKey.markRead.rawValue : HomeCopyKey.markUnread.rawValue),
                          image: atum.symbol(hasBadge ? .mailOpened : .mail))
                }
            }
            if let rename = personal.rename {
                Button { rename(row.roomID) } label: {
                    Label(design.text(ChatCopyKey.rename.rawValue), image: atum.symbol(.pencil))
                }
                .accessibilityIdentifier("home.row.rename")
            }
            if let setPinned = actions.setPinned {
                if canOfferPin {
                    Button { setPinned(row.roomID, !row.isPinned) } label: {
                        Label(design.text(row.isPinned ? HomeCopyKey.unpin.rawValue : HomeCopyKey.pin.rawValue),
                              image: atum.symbol(row.isPinned ? .pinOff : .pin))
                    }
                } else {
                    Button {} label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(design.text(HomeCopyKey.pin.rawValue), image: atum.symbol(.pin))
                            Text(design.text(HomeCopyKey.pinLimit.rawValue))
                                .font(.caption)
                        }
                    }
                    .disabled(true)
                    .accessibilityValue(design.text(HomeCopyKey.pinLimit.rawValue))
                }
            }
            if let setLowPriority = personal.setLowPriority {
                // A checkmark toggle, as iOS menus show a state: no separate
                // "Remove low priority" words are needed.
                Toggle(isOn: Binding(get: { row.isLowPriority },
                                     set: { setLowPriority(row.roomID, $0) })) {
                    Label(design.text(ChatCopyKey.lowPriority.rawValue), image: atum.symbol(.chevronDown))
                }
                .accessibilityIdentifier("home.row.lowPriority")
            }
            if let setMuted = actions.setMuted {
                Button { setMuted(row.roomID, !row.isMuted) } label: {
                    Label(design.text(row.isMuted ? HomeCopyKey.unmute.rawValue : HomeCopyKey.mute.rawValue),
                          image: atum.symbol(row.isMuted ? .bell : .bellOff))
                }
            }
            if let block = personal.block {
                Button(role: block.isBlocked ? nil : .destructive) { block.toggle() } label: {
                    Label(design.text(block.isBlocked ? ChatCopyKey.unblockPerson.rawValue
                                                      : ChatCopyKey.blockPerson.rawValue),
                          image: atum.symbol(.userCircle))
                }
                .accessibilityIdentifier("home.row.block")
            }
            if offersDelete, let requestDeleteAppRoom {
                Divider()
                Button(role: .destructive) { requestDeleteAppRoom(row.roomID) } label: {
                    Text(design.text(HomeCopyKey.deleteChat.rawValue))
                }
            }
            if let exitAction, let requestExit {
                Divider()
                Button(role: .destructive) { requestExit(row.roomID, exitAction) } label: {
                    Label(exitTitle(exitAction),
                          image: atum.symbol(exitAction == .deleteChat ? .trash : .logOut))
                }
                .accessibilityIdentifier("home.row.exit." + exitAction.rawValue)
            }
        }
    }
}

private enum HomePreviewText {
    @MainActor
    static func text(_ preview: RowPreview.Display, design: LiveDesign) -> String {
        let value: String = switch preview.value {
        case let .text(text), let .appNotice(text): text
        case .photo: design.text(HomeCopyKey.previewPhoto.rawValue)
        case .video: design.text(HomeCopyKey.previewVideo.rawValue)
        case .audio: design.text(HomeCopyKey.previewAudio.rawValue)
        case let .file(name?): design.text(HomeCopyKey.previewFileNamed.rawValue, arguments: [.text(name)])
        case .file(nil): design.text(HomeCopyKey.previewFile.rawValue)
        case .sticker: design.text(HomeCopyKey.previewSticker.rawValue)
        case .redacted: design.text(HomeCopyKey.redacted.rawValue)
        case .waitingForDecryption: design.text(HomeCopyKey.previewWaiting.rawValue)
        case .invitation: design.text(HomeCopyKey.previewInvite.rawValue)
        case .empty: ""
        }
        guard !value.isEmpty else { return value }
        return switch preview.prefix {
        case .none: value
        case .currentUser:
            design.text(HomeCopyKey.previewByline.rawValue,
                        arguments: [.text(design.text(HomeCopyKey.you.rawValue)), .text(value)])
        case let .sender(name):
            design.text(HomeCopyKey.previewByline.rawValue, arguments: [.text(name), .text(value)])
        }
    }
}

private enum HomeTimeText {
    @MainActor
    static func text(date: Date, now: Date, design: LiveDesign) -> String {
        let locale = Locale(identifier: design.locale)
        switch RowTime.display(for: date, now: now, calendar: .current, locale: locale) {
        case .justNow, .relative:
            // FlowPhone: today reads as a clock time ("09:41"), as on the
            // desktop roster, never "3 minutes ago".
            return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
        case .yesterday, .weekday, .date:
            return DayLabel.text(for: date, now: now, calendar: .current, locale: locale)
        }
    }
}

private enum HomeCopyKey: String {
    case assistants = "desktop.atum.roster.assistants"
    case chats = "desktop.atum.roster.title"
    /// The top-left avatar opens Settings, so that is what it is called.
    case settings = "desktop.atum.settings.title"
    case search = "desktop.atum.roster.search"
    case startChat = "desktop.atum.roster.startChat"
    case emptySearch = "desktop.atum.roster.emptySearch"
    case emptySearchHint = "desktop.atum.roster.emptySearchHint"
    /// Home search's People section and its pending line (desktop roster).
    case people = "desktop.atum.roster.people"
    case searching = "desktop.atum.roster.searching"
    case loadFailed = "desktop.atum.roster.loadFailed"
    case retry = "src.matrix.chat-copy.copies.retry"
    case offline = "src.matrix.chat-copy.copies.errorOffline"
    case loading = "desktop.common.loading"
    case emptyTitle = "src.matrix.mobile-copy.mobileChatCopy.home.emptyTitle"
    case emptyBody = "src.matrix.mobile-copy.mobileChatCopy.home.emptyBody"
    case justNow = "src.matrix.mobile-copy.mobileChatCopy.home.justNow"
    case previewByline = "src.matrix.mobile-copy.mobileChatCopy.home.preview.byline"
    case previewPhoto = "src.matrix.mobile-copy.mobileChatCopy.home.preview.photo"
    case previewVideo = "src.matrix.mobile-copy.mobileChatCopy.home.preview.video"
    case previewAudio = "src.matrix.mobile-copy.mobileChatCopy.home.preview.audio"
    case previewFile = "src.matrix.mobile-copy.mobileChatCopy.home.preview.file"
    case previewFileNamed = "src.matrix.mobile-copy.mobileChatCopy.home.preview.fileNamed"
    case previewSticker = "src.matrix.mobile-copy.mobileChatCopy.home.preview.sticker"
    case previewWaiting = "src.matrix.mobile-copy.mobileChatCopy.home.preview.waiting"
    case previewInvite = "src.matrix.mobile-copy.mobileChatCopy.home.preview.invite"
    case declineInvite = "src.matrix.mobile-copy.mobileChatCopy.home.declineInvite"
    case mentions = "src.matrix.mobile-copy.mobileChatCopy.home.mentions"
    case newMessages = "src.matrix.mobile-copy.mobileChatCopy.home.newMessages"
    case muted = "src.matrix.mobile-copy.mobileChatCopy.home.muted"
    case pinned = "src.matrix.mobile-copy.mobileChatCopy.home.pinned"
    case redacted = "src.matrix.mobile-copy.mobileChatCopy.placeholder.redacted"
    case you = "desktop.dm.you"
    case unread = "desktop.atum.roster.unread"
    case firstPartyApp = "desktop.atum.roster.badgeFirstParty"
    case partnerApp = "desktop.atum.roster.badgePartner"
    case pending = "src.matrix.copy.copies.pending"
    case notSent = "src.matrix.chat-copy.copies.notSent"
    case errorGeneric = "src.matrix.chat-copy.copies.errorGeneric"
    case markRead = "src.matrix.chat-copy.copies.markRead"
    case markUnread = "src.matrix.chat-copy.copies.markUnread"
    case pin = "src.matrix.chat-copy.copies.pin"
    case unpin = "src.matrix.chat-copy.copies.unpin"
    case mute = "src.matrix.chat-copy.copies.mute"
    case unmute = "src.matrix.chat-copy.copies.unmute"
    case deleteChat = "src.matrix.chat-copy.copies.deleteChat"
    case deleteChatTitle = "src.matrix.chat-copy.copies.deleteChatTitle"
    case deleteBotChatBody = "src.matrix.chat-copy.copies.deleteBotChatBody"
    case pinLimit = "desktop.atum.roster.pinLimit"
    case notificationTitle = "src.matrix.mobile-copy.mobilePhoneCopy.notificationTitle"
    case notificationHelp = "src.matrix.mobile-copy.mobilePhoneCopy.notificationHelp"
    case allow = "src.matrix.mobile-copy.mobilePhoneCopy.allow"
    case notNow = "src.matrix.mobile-copy.mobilePhoneCopy.notNow"
    case cancel = "src.matrix.chat-copy.copies.cancel"
    /// HC-3: "Lan is working", spoken in the time's place.
    case working = "src.matrix.working-copy.copies.working"
}

private enum StartChatCopyKey: String {
    /// PENDING-COPY: not in the export yet (desktop `i18n` `matrixShell.mainAgent`).
    case mainAgent = "desktop.matrixShell.mainAgent"
    case startTitle = "src.matrix.roster-create-copy.copies.startTitle"
    case startSearch = "src.matrix.roster-create-copy.copies.startSearch"
    case assistants = "src.matrix.roster-create-copy.copies.assistants"
    case people = "src.matrix.roster-create-copy.copies.people"
    case groups = "src.matrix.roster-create-copy.copies.groups"
    case apps = "src.matrix.roster-create-copy.copies.apps"
    case addFriend = "src.matrix.roster-create-copy.copies.addFriend"
    case addFriendTitle = "src.matrix.roster-create-copy.copies.addFriendTitle"
    case addFriendBody = "src.matrix.roster-create-copy.copies.addFriendBody"
    case handleLabel = "src.matrix.roster-create-copy.copies.handleLabel"
    case handlePlaceholder = "src.matrix.roster-create-copy.copies.handlePlaceholder"
    case find = "src.matrix.roster-create-copy.copies.find"
    case findOnAtum = "src.matrix.roster-create-copy.copies.findOnAtum"
    case noMatches = "src.matrix.roster-create-copy.copies.noMatches"
    case noMatchesHint = "src.matrix.roster-create-copy.copies.noMatchesHint"
    case members = "src.matrix.roster-create-copy.copies.members"
    case searching = "src.matrix.roster-create-copy.copies.searching"
    case notFound = "src.matrix.roster-create-copy.copies.notFound"
    case noAddress = "src.matrix.roster-create-copy.copies.noAddress"
    case rateLimited = "src.matrix.roster-create-copy.copies.rateLimited"
    case rateLimitedSoon = "src.matrix.roster-create-copy.copies.rateLimitedSoon"
    case searchFailed = "src.matrix.roster-create-copy.copies.searchFailed"
    case startFailed = "src.matrix.roster-create-copy.copies.startFailed"
    case newGroup = "src.matrix.roster-create-copy.copies.newGroup"
    case createGroup = "src.matrix.roster-create-copy.copies.createGroup"
    case creating = "src.matrix.roster-create-copy.copies.creating"
    case groupFailed = "src.matrix.roster-create-copy.copies.groupFailed"
    case historyShared = "src.matrix.roster-create-copy.copies.historyShared"
    case nameOnly = "src.matrix.roster-create-copy.copies.nameOnly"
    case groupCreateTitle = "src.matrix.group-picker-copy.copies.createTitle"
    case groupName = "src.matrix.group-picker-copy.copies.groupName"
    case groupNamePlaceholder = "src.matrix.group-picker-copy.copies.groupNamePlaceholder"
    case groupFull = "src.matrix.group-picker-copy.copies.block.full"
    case newAssistant = "src.matrix.roster-create-copy.copies.newAssistant"
    case assistantIntro = "src.matrix.roster-create-copy.copies.assistantIntro"
    case assistantName = "src.matrix.roster-create-copy.copies.assistantName"
    case assistantNamePlaceholder = "src.matrix.roster-create-copy.copies.assistantNamePlaceholder"
    case createAssistant = "src.matrix.roster-create-copy.copies.createAssistant"
    case assistantCloudDisclosure = "src.matrix.roster-create-copy.copies.assistantCloudDisclosure"
    case assistantStarting = "src.matrix.roster-create-copy.copies.assistantStarting"
    case assistantUnavailable = "src.matrix.roster-create-copy.copies.assistantUnavailable"
    case assistantCreateFailed = "src.matrix.roster-create-copy.copies.assistantCreateFailed"
    case retry = "src.matrix.chat-copy.copies.retry"
    case cancel = "src.matrix.chat-copy.copies.cancel"
}

/// The existing Kit face and text stack, shared by discovery and group pickers.
/// Handles stay here; chat names and messages never consume this enrichment.
private struct HomeDiscoveryPersonRow: View {
    let design: LiveDesign
    let person: HomeGroupCandidate
    let load: ((String, Int) async -> Data?)?
    @State private var art: AtumAvatarArt?
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        HStack(spacing: 12) {
            AtumAvatar(kind: person.kind == .assistant ? .assistant : .person,
                       name: person.name, art: art, size: 36)
                // Decorative: the name beside it is what is read (the Home
                // row does the same), and its initial is sized to the face.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: person.name).foregroundStyle(atum.color(.ink, scheme: scheme)).lineLimit(1)
                // Desktop `PersonHandleLine`: never a handle that only
                // repeats the name above it.
                if let handle = person.handle, "@" + handle != person.name.trimmingCharacters(in: .whitespaces) {
                    Text(verbatim: "@" + handle).font(.caption).foregroundStyle(atum.color(.muted, scheme: scheme)).lineLimit(1)
                }
            }
        }
        .frame(minHeight: 44)
        .task(id: person.avatarURL) {
            art = nil
            guard let uri = person.avatarURL, let load,
                  let bytes = await load(uri, AtumAvatar.thumbnailPixelSide(for: 36)),
                  !Task.isCancelled else { return }
            art = await AtumAvatarArt.load(data: bytes, pixelSide: AtumAvatar.thumbnailPixelSide(for: 36))
        }
    }
}
