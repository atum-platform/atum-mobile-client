import Foundation
import AtumChat
import AtumNativeAPI
import MatrixRustSDK
import Observation

/// SDK-neutral room data for the live roster.
struct LiveMatrixRoomRow: Equatable, Identifiable, Sendable {
    let roomID: String
    let displayName: String
    let avatarURL: String?
    /// The other member's Matrix profile photo, when the room itself has no
    /// avatar. A one-to-one room carries no room avatar, so this is what makes
    /// a person's face appear instead of a letter.
    var heroAvatarURL: String? = nil
    let latestText: String?
    /// The newest event is a delivery-outcome notice, deliberately kept out
    /// of the preview. Home keeps the last real message line instead.
    var latestWasDeliveryNotice: Bool = false
    let latestPreviewContent: RowPreview.Content
    let latestSenderID: String?
    let latestSenderName: String?
    let latestIsOwn: Bool
    let latestIsNotice: Bool
    let latestSendState: RowPreview.SendState
    /// Server time of the latest event, used only to bring back a hidden room
    /// when a newer message arrives.
    let latestTimestamp: UInt64?
    let unreadCount: UInt64
    let notificationCount: UInt64
    let highlightCount: UInt64
    let isMarkedUnread: Bool
    let isFavourite: Bool
    let isMuted: Bool
    let isDirect: Bool
    /// Other joined/invited members from SDK state; excludes this account to
    /// preserve existing agent/app identity classification contracts.
    let memberUserIDs: [String]
    /// Joined plus invited count from SDK room info, including named rooms.
    let memberCount: UInt64
    /// The custom room type from cached `m.room.create` state, when present.
    /// The SDK room-list service already requests that state event.
    let roomType: String?
    /// From the SDK's room info: true with encryption, false without, nil
    /// while the SDK does not know yet. 0.20 agent and bot rooms are false.
    let isEncrypted: Bool?
    /// When the person deleted this official bot chat on the desktop
    /// (`io.atum.app_bot.hidden`, read through the SDK's cached raw room
    /// account data). Read-only: the phone's own Delete chat stays local.
    var appBotHiddenAt: UInt64? = nil
    /// The desktop's "moved" note on a retired official bot chat
    /// (`io.atum.app_bot.legacy_moved`); such a room is never that bot's chat.
    var legacyAppBotMove: MobileLegacyAppBotMove? = nil
    /// SDK profile records for people lists; room titles never rename members.
    var memberProfiles: [LiveMatrixMemberRow] = []
    /// The standard `m.lowpriority` tag, from the SDK's room info.
    var isLowPriority: Bool = false
    /// The room's `m.room.topic`, from the SDK's room info.
    var topic: String? = nil
    /// HC-7: your own name for this chat (`io.atum.title`, desktop's private
    /// Rename). It goes before the room's own name, as on desktop.
    var privateTitle: String? = nil

    var id: String { roomID }
}

/// What the chat's side panel reads when it opens (M2), SDK-neutral.
/// Every field comes from the SDK's local store; none starts a sync.
struct LiveMatrixPanelDetails: Equatable, Sendable {
    struct Member: Equatable, Sendable {
        let userID: String
        let displayName: String
        let avatarURL: String?
        /// A creator's unlimited power (room version 12) reads as `Int64.max`.
        let power: Int64
        let membership: ChatMemberModeration.Membership
    }

    /// The `m.room.create` event's server time, in milliseconds.
    let createdAt: UInt64?
    let ownPower: Int64?
    let kickLevel: Int64?
    let banLevel: Int64?
    let members: [Member]
    let ignoredUserIDs: Set<String>
}

/// A room this account is invited to. The inviter is carried so the app can
/// accept invites from its own agents and bots and nothing else, and the
/// encryption state so a bot's invitation to a plain room can be chosen as
/// its chat (`MobileAppBotRoomPolicy.chooseChat`).
struct LiveMatrixInvite: Equatable, Sendable {
    let roomID: String
    let inviterID: String?
    let displayName: String?
    let inviterDisplayName: String?
    let latestTimestamp: UInt64?
    /// From the SDK's room info: nil while it does not know.
    var isEncrypted: Bool? = nil
    /// The custom room type from stripped `m.room.create` state, when present.
    var roomType: String? = nil
    var avatarURL: String? = nil
    var isDirect: Bool = false

    init(roomID: String, inviterID: String?, displayName: String? = nil,
         inviterDisplayName: String? = nil, latestTimestamp: UInt64? = nil,
         isEncrypted: Bool? = nil, roomType: String? = nil,
         avatarURL: String? = nil, isDirect: Bool = false) {
        self.roomID = roomID
        self.inviterID = inviterID
        self.displayName = displayName
        self.inviterDisplayName = inviterDisplayName
        self.latestTimestamp = latestTimestamp
        self.isEncrypted = isEncrypted
        self.roomType = roomType
        self.avatarURL = avatarURL
        self.isDirect = isDirect
    }
}

/// Display-safe joined member data for S2's chat info sheet. SDK member
/// objects never cross the session adapter boundary.
struct LiveMatrixMemberRow: Equatable, Identifiable, Sendable {
    let userID: String
    let displayName: String
    let avatarURL: String?

    var id: String { userID }
}

enum LiveMatrixSessionError: Equatable, Sendable {
    case currentSessionInvalid
    case startupFailed
    case offline
    case roomUnavailable
    case timelineUnavailable
    case sendUnavailable
    case callbackFailed
}

/// Read-only UI state that can survive replacing an invalid Matrix runtime:
/// the roster rows only. An open chat lives in its own
/// `LiveConversationStore`, which keeps its rows and reattaches to the
/// replacement session's room (`onSessionReady`).
struct LiveMatrixSessionDisplaySnapshot: Equatable, Sendable {
    let rooms: [LiveMatrixRoomRow]
}

/// Main-actor bridge between the one custody-checked Matrix client and SwiftUI:
/// the room list and invites, with sync, send-queue wake-ups and the app's
/// lifecycle in this session's `SessionLifecycle` (WS3, plan §2.8). Open chats
/// own their timelines (`ios/App/Chat`); the SDK owns encrypted stores, local
/// echo and its send queue.
@MainActor
@Observable
final class LiveMatrixSession {
    private(set) var rooms = [LiveMatrixRoomRow]()
    private(set) var invites = [LiveMatrixInvite]()
    /// Called on the main actor whenever the invite list changes.
    var onInvitesChanged: (([LiveMatrixInvite]) -> Void)?
    /// Called after one authoritative joined-room publication. The model uses
    /// it only to retire matching optimistic Home mutations.
    var onRoomsChanged: (([LiveMatrixRoomRow]) -> Void)?
    /// Called on the main actor when an SDK update finds the custody ticket
    /// no longer current (normally: the 300 s access token expired). The
    /// update is still dropped; the owner of the runtime decides whether to
    /// renew it.
    var onSessionInvalid: (() -> Void)?
    /// Called on the main actor each time the session is established (start,
    /// restart after a failed sync): the room list is ready, so an open chat
    /// can attach to its room.
    var onSessionReady: (() -> Void)?
    /// Called on the main actor when sync comes back after being offline or
    /// failed (offline mode, §2.8). `SessionLifecycle` already wakes every
    /// send queue then; the app uses it to resume an open chat's paging.
    var onSyncRecovered: (() -> Void)?
    /// Called on the main actor on each return from the background (B30:
    /// agents, apps, Store and wallet refresh then).
    var onForegroundReturn: (() -> Void)?
    /// Called once this session's room-list state machine reports that the
    /// first rooms have synced (`RoomListServiceState.settingUp`). The first
    /// run and the app-shortcut projection use it because global account data
    /// before this point may only be an empty local store, not an
    /// authoritative missing record.
    var onInitialSyncCompleted: (() -> Void)?
    /// True after the first rooms have synced in this session epoch. Latches
    /// for the epoch; a replacement session starts false again.
    private(set) var hasCompletedInitialSync = false
    /// Sync, send queues and the scene phase for this session (B9, B30): the
    /// quiet connection glyph reads it. Nil until the session is established
    /// and after it is torn down.
    private(set) var lifecycle: SessionLifecycle?
    private(set) var isLoadingRooms = false
    private(set) var error: LiveMatrixSessionError?

    let sharedCollectionsRegistry = SharedCollectionsRegistry()
    /// Internal for the company notes-to-self glue (`CompanyWorkspaceModel.swift`).
    let runtime: MatrixLiveRuntime
    private var syncService: SyncService?
    private var roomList: RoomList?
    private var roomEntries: RoomListEntriesWithDynamicAdaptersResult?
    private var roomEntriesController: RoomListDynamicEntriesController?
    private var roomEntriesStream: TaskHandle?
    private var roomListener: LiveMatrixRoomListListener?
    private var roomLoadingListener: LiveMatrixRoomLoadingListener?
    private var roomLoadingStream: TaskHandle?
    private var syncStateObserver: LiveMatrixSyncStateObserver?
    private var syncStateStream: TaskHandle?
    private var roomListStateObserver: LiveRoomListStateObserver?
    private var roomListStateStream: TaskHandle?
    private var sessionEpoch: UInt64 = 0
    private var latestRoomPublication: UInt64 = 0
    private var requestedRoomPages = 1
    private var directCreations: [String: Task<String?, Never>] = [:]
    private var maximumMediaUploadSizeTask: Task<UInt64?, Never>?

    init(runtime: MatrixLiveRuntime,
         displaySnapshot: LiveMatrixSessionDisplaySnapshot? = nil) {
        self.runtime = runtime
        if let displaySnapshot { rooms = displaySnapshot.rooms }
    }

    /// A display-only snapshot for a replacement session. In particular, this
    /// excludes SDK objects, listeners, and send authority.
    var displaySnapshot: LiveMatrixSessionDisplaySnapshot {
        LiveMatrixSessionDisplaySnapshot(rooms: rooms)
    }

    /// True once the session is established: an open chat can attach to its
    /// room. Offline still counts: the timeline shows the SDK's cache and
    /// sends wait in its queue (B9).
    var isReady: Bool { syncService != nil && roomList != nil }

    /// A joined room of this session, for a chat to open its own timeline.
    func room(id roomID: String) throws -> Room {
        try runtime.requireCurrent()
        if let roomList, let room = try? roomList.room(roomId: roomID) { return room }
        guard let room = try runtime.client.getRoom(roomId: roomID) else { throw LiveMatrixAdapterFailure.unavailable }
        return room
    }

    func personProfile(userID: String) async -> HomeGroupCandidate? {
        do {
            try runtime.requireCurrent()
            let profile = try await runtime.client.getProfile(userId: userID)
            try runtime.requireCurrent()
            return HomeGroupCandidate(id: userID, name: PeopleNameWords.person(profile.displayName, userID: userID),
                                      kind: .person, avatarURL: profile.avatarUrl)
        } catch { return nil }
    }

    /// Native directory search; SDK owns authentication and transport. No
    /// alias-service response may insert a person the directory did not return.
    func searchPeople(_ query: String) async -> [HomeGroupCandidate]? {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 200 else { return [] }
        do {
            try runtime.requireCurrent()
            let result = try await runtime.client.searchUsers(searchTerm: term, limit: 30)
            try runtime.requireCurrent()
            return result.results.filter { $0.userId != runtime.ticket.session.userID }.map {
                HomeGroupCandidate(id: $0.userId, name: PeopleNameWords.person($0.displayName, userID: $0.userId),
                                   kind: .person, avatarURL: $0.avatarUrl)
            }
        } catch { return nil }
    }

    /// Creates one ordinary, unencrypted direct conversation with shared
    /// history, matching desktop 0.20. The SDK performs the authoritative
    /// Matrix create/invite; Home still waits for the room-list echo before it
    /// opens anything. `m.direct` is presentation metadata only, written best
    /// effort after creation and never used as membership authority.
    func createDirectRoom(inviting target: NativeMatrixUser) async -> String? {
        if let pending = directCreations[target.rawValue] { return await pending.value }
        let task = Task { await self.reuseOrCreateDirectRoom(inviting: target) }
        directCreations[target.rawValue] = task
        // Retain the outcome for this session: an ambiguous create failure must
        // never become a second create when a picker is tapped again.
        return await task.value
    }

    private func reuseOrCreateDirectRoom(inviting target: NativeMatrixUser) async -> String? {
        do {
            try runtime.requireCurrent()
            // Read m.direct through the SDK before creating, including rooms not
            // yet published by the paged room-list adapter. Only joined ordinary
            // one-to-one rooms qualify; account data is never membership authority.
            let raw: String?
            if let anchor = rooms.first {
                // The pinned SDK's authenticated global-account-data bridge is
                // a one-shot read, so another device's classification need not
                // wait for our next sync before a create decision.
                raw = try await room(id: anchor.roomID).fetchGlobalAccountDataRaw(eventType: "m.direct")
            } else {
                guard hasCompletedInitialSync else { throw LiveMatrixAdapterFailure.unavailable }
                raw = try await runtime.client.accountData(eventType: "m.direct")
            }
            try runtime.requireCurrent()
            for roomID in try MobileDirectRoomPolicy.roomIDs(accountData: raw, userID: target.rawValue) {
                guard let room = try runtime.client.getRoom(roomId: roomID) else {
                    // Another device's DM can precede our local room sync.
                    // Wait for it rather than create a duplicate.
                    throw LiveMatrixAdapterFailure.unavailable
                }
                let info = try await room.roomInfo()
                guard info.membership == .joined, !info.isSpace,
                      info.activeMembersCount <= 2 else { continue }
                // Unknown member state cannot justify a new DM.
                let members = try await Self.cachedMembers(from: room, synchronize: true, includeInvited: true)
                let create = try await room.stateEvents(eventType: .roomCreate)
                guard MobileDirectRoomPolicy.canReuse(
                    isJoined: info.membership == .joined, isSpace: info.isSpace,
                    activeMemberCount: info.activeMembersCount, activeMemberIDs: members.map(\.userID),
                    target: target.rawValue,
                    hasCustomRoomType: create.contains { MobileRoomTypePolicy.roomType(createContentJSON: $0.contentJson) != nil }
                ) else { continue }
                try runtime.requireCurrent()
                return roomID
            }
            if let existing = HomeAddFriendPolicy.existingRoomID(in: rooms, matrixUserID: target.rawValue) {
                return existing
            }
            let roomID = try await runtime.client.createRoom(request: CreateRoomParameters(
                name: nil,
                isEncrypted: false,
                isDirect: true,
                visibility: .private,
                preset: .privateChat,
                invite: [target.rawValue],
                historyVisibilityOverride: .shared
            ))
            try runtime.requireCurrent()
            try? await rememberDirectRoom(roomID, for: target.rawValue)
            return roomID
        } catch {
            return nil
        }
    }

    /// A chat with a catalog app bot in the desktop's recipe (`openAppBotDm`): an
    /// ordinary plain direct room that invites the bot, then the bot-chat room
    /// marker and the per-app account pointer, written (with bounded retries)
    /// before this returns, so before anything can be sent into the room. They
    /// are how another device recognises the room; a record that still fails is
    /// logged and does not block the chat. This narrows the window for a second
    /// room on another device but does not close it: only the platform's
    /// canonical-room arbitration will. Callers create at most once per bot and
    /// session.
    func createAppBotChat(appID: String, bot: NativeMatrixUser) async -> String? {
        guard let roomID = await createDirectRoom(inviting: bot) else { return nil }
        await writeAppBotChatRecords(roomID: roomID, appID: appID, bot: bot)
        return roomID
    }

    /// The marker and pointer of a bot chat, with bounded retries. A record that
    /// still fails is logged (a closed code) and does not block the chat.
    func writeAppBotChatRecords(roomID: String, appID: String, bot: NativeMatrixUser) async {
        _ = await AppBotChatRecipe.finalize(
            roomID: roomID, appID: appID, botUserID: bot.rawValue,
            writer: AppBotChatRecords(session: self, appID: appID),
            log: { LiveFlowLog.botRoom(.pointer, outcome: $0, roomID: roomID) }
        )
    }

    /// Leaves a joined room this device made and lost to the platform's choice.
    func leave(roomID: String) async -> Bool {
        do {
            try runtime.requireCurrent()
            guard let room = try runtime.client.getRoom(roomId: roomID) else {
                throw LiveMatrixAdapterFailure.unavailable
            }
            try await room.leave()
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }

    /// "Delete chat" (leave, then forget) or "Leave group" (leave) from a
    /// person's chat or a group (`ChatExitPolicy`). Others keep their copy.
    func exit(roomID: String, forget: Bool) async -> Bool {
        do {
            try runtime.requireCurrent()
            guard let room = try runtime.client.getRoom(roomId: roomID) else {
                throw LiveMatrixAdapterFailure.unavailable
            }
            try await room.leave()
            try runtime.requireCurrent()
            if forget {
                try await room.forget()
                try runtime.requireCurrent()
            }
            return true
        } catch {
            return false
        }
    }

    /// Matrix ignore (`m.ignored_user_list`): their messages and invites stop
    /// reaching this account, and they are not told.
    func setIgnored(userID: String, ignored: Bool) async -> Bool {
        do {
            try runtime.requireCurrent()
            if ignored {
                try await runtime.client.ignoreUser(userId: userID)
            } else {
                try await runtime.client.unignoreUser(userId: userID)
            }
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }

    /// Ignored people with their profile names (a failed profile read keeps
    /// the person, unnamed).
    func ignoredPeople() async -> [IgnoredPerson]? {
        do {
            try runtime.requireCurrent()
            let users = try await runtime.client.ignoredUsers()
            try runtime.requireCurrent()
            var people: [IgnoredPerson] = []
            for userID in users {
                let name = try? await runtime.client.getProfile(userId: userID).displayName
                people.append(IgnoredPerson(userID: userID, name: name))
            }
            try runtime.requireCurrent()
            return people
        } catch {
            return nil
        }
    }

    /// A Founder room created by this phone lost the authoritative marker
    /// race and has no message from this account. Match desktop: leave, then
    /// forget. Any ambiguity returns false so the caller hides instead.
    func leaveAndForgetFounderRoom(roomID: String) async -> Bool {
        do {
            try runtime.requireCurrent()
            guard let room = try runtime.client.getRoom(roomId: roomID) else {
                throw LiveMatrixAdapterFailure.unavailable
            }
            try await room.leave()
            try runtime.requireCurrent()
            try await room.forget()
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }

    @MainActor private struct AppBotChatRecords: AppBotChatWriter {
        let session: LiveMatrixSession
        let appID: String

        func writeMarker(roomID: String, content: String) async throws {
            try session.runtime.requireCurrent()
            guard let room = try session.runtime.client.getRoom(roomId: roomID) else {
                throw LiveMatrixAdapterFailure.unavailable
            }
            _ = try await room.sendStateEventRaw(eventType: MobileAppBotRoomPolicy.markerEventType,
                                                 stateKey: "", content: content)
            try session.runtime.requireCurrent()
        }

        func writePointer(content: String) async throws {
            try session.runtime.requireCurrent()
            try await session.runtime.client.setAccountData(
                eventType: MobileAppBotRoomPolicy.pointerEventType(appID: appID), content: content)
            try session.runtime.requireCurrent()
        }
    }

    /// Joins a room this phone knows by ID: a no-op when already joined, the
    /// invitation when it is invited, else a join by room ID (a room another
    /// device made, named by the account pointer, that has not synced here yet).
    /// False when the person cannot join it, for example a room they left.
    func join(roomID: String) async -> Bool {
        if rooms.contains(where: { $0.roomID == roomID }) { return true }
        if await acceptInvite(roomID: roomID) { return true }
        do {
            try runtime.requireCurrent()
            _ = try await runtime.client.joinRoomById(roomId: roomID)
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }

    /// Creates an ordinary people group. Assistant membership stays outside
    /// this path until a non-Mac join authority is available; callers expose
    /// only candidates they can complete. Like desktop 0.20, the room is
    /// private, plain and shares earlier history with people added later.
    func createGroup(name: String, inviting targets: [NativeMatrixUser]) async -> String? {
        guard !name.isEmpty, name.unicodeScalars.count <= 200,
              targets.count <= HomeGroupPolicy.maximumInvites,
              Set(targets.map(\.rawValue)).count == targets.count else { return nil }
        do {
            try runtime.requireCurrent()
            let roomID = try await runtime.client.createRoom(request: CreateRoomParameters(
                name: name,
                isEncrypted: false,
                isDirect: false,
                visibility: .private,
                preset: .privateChat,
                invite: targets.map(\.rawValue),
                historyVisibilityOverride: .shared
            ))
            try runtime.requireCurrent()
            return roomID
        } catch {
            return nil
        }
    }

    private func rememberDirectRoom(_ roomID: String, for userID: String) async throws {
        let raw = try await runtime.client.accountData(eventType: "m.direct") ?? "{}"
        guard raw.utf8.count <= 262_144,
              let data = raw.data(using: .utf8),
              var direct = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { throw LiveMatrixAdapterFailure.unavailable }
        direct[userID] = Array(Set((direct[userID] ?? []) + [roomID])).sorted()
        let encoded = try JSONEncoder().encode(direct)
        guard encoded.count <= 262_144, let content = String(data: encoded, encoding: .utf8)
        else { throw LiveMatrixAdapterFailure.unavailable }
        try await runtime.client.setAccountData(eventType: "m.direct", content: content)
        try runtime.requireCurrent()
    }

    /// Best-effort `m.direct` presentation hint for the canonical Founder
    /// chat. The account marker, not `m.direct`, remains the no-recreate
    /// authority, so a failed hint never blocks the chat.
    func rememberFounderDirect(roomID: String, founderUserID: String) async {
        try? await rememberDirectRoom(roomID, for: founderUserID)
    }

    func start() async {
        do {
            try runtime.requireCurrent()
            guard syncService == nil else { return }
            let epoch = beginSessionEpoch()
            await establishSession(sessionEpoch: epoch)
        } catch {
            await failSessionStart(after: error)
        }
    }

    /// Reconnect an explicitly failed sync session. Unlike `start`, this is
    /// intentionally allowed to replace its resources, but only after a known
    /// failed state so a healthy session cannot be accidentally torn down.
    func restartAfterFailedSync() async {
        guard error == .offline || error == .startupFailed || error == .callbackFailed
                || error == .roomUnavailable || error == .timelineUnavailable
                || error == .sendUnavailable else {
            return
        }

        let epoch = fenceCallbacksForTeardown()
        isLoadingRooms = true
        error = nil
        await discardLiveResources()
        guard sessionEpoch == epoch else { return }
        await establishSession(sessionEpoch: epoch)
    }

    /// Stop the SDK-facing portion of this session before its runtime is
    /// replaced (for example, after an explicit credential rotation). The
    /// returned snapshot is safe to pass to a newly constructed session, but
    /// this suspended instance deliberately has no active send path.
    func suspendForRuntimeReplacement(
        retaining forcedError: LiveMatrixSessionError? = nil
    ) async -> LiveMatrixSessionDisplaySnapshot {
        let snapshot = displaySnapshot
        let retainedError = forcedError ?? error ?? .startupFailed
        let epoch = fenceCallbacksForTeardown()
        await discardLiveResources()
        guard sessionEpoch == epoch else { return snapshot }
        isLoadingRooms = false
        error = retainedError
        return snapshot
    }

    private func markSessionInvalid() {
        error = .currentSessionInvalid
        onSessionInvalid?()
    }

    /// Join a room this account was invited to. The caller decides which
    /// invites to accept; this only performs the join.
    ///
    /// This is the only place the phone joins a room, so it holds the one guard: a room whose create
    /// event claims the company conversation type is joined only by the directory-confirmed
    /// conversation convergence (`directoryConfirmedConversation`), never by a bot or agent
    /// invitation, the lifecycle join, the app-bot join or any other path. An unreadable type
    /// fails the same way for a room already known to claim it.
    func acceptInvite(roomID: String, directoryConfirmedConversation: Bool = false) async -> Bool {
        do {
            try runtime.requireCurrent()
            guard let room = try runtime.client.getRoom(roomId: roomID) else {
                throw LiveMatrixAdapterFailure.unavailable
            }
            // The room's type is the one every invitation and room already carries (read for all of
            // them). A room this session does not list cannot be vouched for: only the
            // directory-confirmed convergence joins it.
            let listed: String?? = invites.first(where: { $0.roomID == roomID }).map(\.roomType)
                ?? rooms.first(where: { $0.roomID == roomID }).map(\.roomType)
            if let listed {
                guard ConversationTypeGuard.mayJoin(roomType: listed,
                                                    directoryConfirmed: directoryConfirmedConversation)
                else { return false }
            } else if !directoryConfirmedConversation {
                return false
            }
            try await room.join()
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }

    /// Declines a human invitation by leaving its invited room. Agent and app
    /// invites are handled by the automatic acceptance policy and never call
    /// this path.
    func declineInvite(roomID: String) async -> Bool {
        do {
            try runtime.requireCurrent()
            guard let room = try runtime.client.getRoom(roomId: roomID) else {
                throw LiveMatrixAdapterFailure.unavailable
            }
            let info = try await room.roomInfo()
            guard info.membership == .invited else { return false }
            try runtime.requireCurrent()
            try await room.leave()
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }

    /// Home's read toggle. Marking read advances this account's receipt on
    /// the latest event (public when the owner shares activity, private
    /// otherwise) and clears the explicit unread flag; marking unread changes
    /// only that flag, preserving server counts until the user actually reads.
    func setUnread(roomID: String, isUnread: Bool, shareActivity: Bool = true) async -> Bool {
        do {
            let room = try room(id: roomID)
            if isUnread {
                try await room.setUnreadFlag(newValue: true)
            } else {
                try await room.markAsRead(receiptType: shareActivity ? .read : .readPrivate)
                try await room.setUnreadFlag(newValue: false)
            }
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
    /// account data desktop reads and writes. Missing or unreadable means the
    /// default, on (`ShareActivityPreference`).
    func readShareActivity() async -> Bool {
        do {
            try runtime.requireCurrent()
            let content = try await runtime.client.accountData(
                eventType: ShareActivityPreference.eventType
            )
            try runtime.requireCurrent()
            return ShareActivityPreference.value(fromAccountData: content)
        } catch {
            return true
        }
    }

    /// Writes the owner's choice so the Mac and phone agree on the next sync.
    func setShareActivity(_ sharing: Bool) async -> Bool {
        do {
            try runtime.requireCurrent()
            try await runtime.client.setAccountData(
                eventType: ShareActivityPreference.eventType,
                content: ShareActivityPreference.accountDataJSON(sharing: sharing)
            )
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }

    /// Desktop-compatible `m.favourite`: new pins have no explicit tag order.
    func setPinned(roomID: String, isPinned: Bool) async -> Bool {
        do {
            let room = try room(id: roomID)
            try await room.setIsFavourite(isFavourite: isPinned, tagOrder: nil)
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }

    /// Mute is an explicit room mode. Unmute asks the SDK to restore the
    /// account's encrypted/direct default instead of guessing `allMessages`.
    func setMuted(roomID: String, isMuted: Bool) async -> Bool {
        guard var row = rooms.first(where: { $0.roomID == roomID }) else { return false }
        do {
            try runtime.requireCurrent()
            let settings = await runtime.client.getNotificationSettings()
            if isMuted {
                try await settings.setRoomNotificationMode(roomId: roomID, mode: .mute)
            } else {
                // RoomInfo may transiently publish unknown encryption during a
                // restart. Wait for the same live session to answer rather than
                // restoring the wrong account default or flashing a rollback.
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while row.isEncrypted == nil, ProcessInfo.processInfo.systemUptime < deadline {
                    try runtime.requireCurrent()
                    try await Task.sleep(for: .milliseconds(250))
                    guard let refreshed = rooms.first(where: { $0.roomID == roomID }) else { return false }
                    row = refreshed
                }
                guard let isEncrypted = row.isEncrypted else { return false }
                try await settings.unmuteRoom(roomId: roomID, isEncrypted: isEncrypted,
                                              isOneToOne: row.isDirect && row.memberCount <= 2)
            }
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }

    /// Desktop-compatible `m.lowpriority`, with no explicit tag order.
    func setLowPriority(roomID: String, isLowPriority: Bool) async -> Bool {
        do {
            let room = try room(id: roomID)
            try await room.setIsLowPriority(isLowPriority: isLowPriority, tagOrder: nil)
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }

    // MARK: HC-7: names and topics

    /// Your own name for a chat (desktop's private Rename): the room account
    /// data event `io.atum.title`, `{}` to clear it. The pinned SDK has no
    /// room account data write, so this one request goes to the session's own
    /// homeserver with the session's bearer (HTTPS only, no cookies, no
    /// redirects), as Team Space's notification read does. The row shows the
    /// new name at once; sync brings the event back into the SDK's cache.
    func setPrivateTitle(roomID: String, title: String) async -> Bool {
        do {
            try runtime.requireCurrent()
            let session = try runtime.client.session()
            let userID = try runtime.client.userId()
            guard var components = URLComponents(string: session.homeserverUrl), components.scheme == "https",
                  components.host?.isEmpty == false,
                  let user = Self.pathSegment(userID), let room = Self.pathSegment(roomID),
                  let type = Self.pathSegment(ChatPrivateTitle.eventType) else { return false }
            let base = components.percentEncodedPath.hasSuffix("/")
                ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
            components.percentEncodedPath = base + "/_matrix/client/v3/user/\(user)/rooms/\(room)/account_data/\(type)"
            guard let url = components.url else { return false }
            let content = ChatPrivateTitle.content(title)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.httpMethod = "PUT"
            request.httpShouldHandleCookies = false
            request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: content)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            let transport = URLSession(configuration: configuration, delegate: LiveMatrixNoRedirect(),
                                       delegateQueue: nil)
            defer { transport.finishTasksAndInvalidate() }
            let (_, response) = try await transport.data(for: request)
            try runtime.requireCurrent()
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            patchPrivateTitle(roomID: roomID, title: content["title"])
            return true
        } catch {
            return false
        }
    }

    /// A group's name for everyone in it (`m.room.name`, never empty). Your
    /// own private name would hide the new one from you, so it goes too
    /// (desktop `groupName`).
    func setGroupName(roomID: String, name: String) async -> Bool {
        let name = ChatPrivateTitle.normalized(name)
        guard !name.isEmpty, name.count <= ChatPrivateTitle.maximumLength else { return false }
        do {
            let room = try room(id: roomID)
            try await room.setName(name: name)
            try runtime.requireCurrent()
        } catch {
            return false
        }
        if rooms.first(where: { $0.roomID == roomID })?.privateTitle != nil {
            _ = await setPrivateTitle(roomID: roomID, title: "")
        }
        return true
    }

    /// A group's topic for everyone in it (`m.room.topic`).
    func setGroupTopic(roomID: String, topic: String) async -> Bool {
        do {
            let room = try room(id: roomID)
            try await room.setTopic(topic: ChatGroupTopic.normalized(topic))
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }

    /// Whether this account may name the group and set its topic (desktop
    /// `room.canName` / `room.canTopic`, from the power levels).
    func groupDetailsPowers(roomID: String) async -> (name: Bool, topic: Bool) {
        guard let room = try? room(id: roomID), let levels = try? await room.getPowerLevels() else {
            return (false, false)
        }
        let own = room.ownUserId()
        return ((try? levels.canUserSendState(userId: own, stateEvent: .roomName)) ?? false,
                (try? levels.canUserSendState(userId: own, stateEvent: .roomTopic)) ?? false)
    }

    private func patchPrivateTitle(roomID: String, title: String?) {
        guard let index = rooms.firstIndex(where: { $0.roomID == roomID }) else { return }
        rooms[index].privateTitle = title
    }

    nonisolated private static func pathSegment(_ value: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// The side panel's facts, from the local store: when the room began, its
    /// power levels as they apply to you, its people with their power (joined,
    /// invited and banned) and the account's ignore list. A part the store
    /// can't answer is left unknown.
    func panelDetails(roomID: String) async -> LiveMatrixPanelDetails? {
        do {
            let room = try room(id: roomID)
            let client = runtime.client
            let details = await Task.detached(priority: .userInitiated) {
                await Self.panelDetails(room: room, client: client)
            }.value
            try runtime.requireCurrent()
            return details
        } catch {
            return nil
        }
    }

    nonisolated private static func panelDetails(room: Room, client: Client) async -> LiveMatrixPanelDetails {
        async let create = try? await room.stateEvents(eventType: .roomCreate)
        async let levels = try? await room.getPowerLevels()
        async let ignored = try? await client.ignoredUsers()
        var members = [LiveMatrixPanelDetails.Member]()
        if let iterator = try? await room.membersNoSync() {
            let maximum = min(Int(iterator.len()), 2_000)
            while members.count < maximum,
                  let chunk = iterator.nextChunk(chunkSize: UInt32(min(100, maximum - members.count))),
                  !chunk.isEmpty {
                for member in chunk {
                    let membership: ChatMemberModeration.Membership
                    switch member.membership {
                    case .join: membership = .joined
                    case .invite: membership = .invited
                    case .ban: membership = .banned
                    default: continue
                    }
                    members.append(.init(userID: member.userId,
                                         displayName: PeopleNameWords.person(member.displayName, userID: member.userId),
                                         avatarURL: member.avatarUrl,
                                         power: Self.power(member.powerLevel),
                                         membership: membership))
                }
            }
        }
        let ownUserID = room.ownUserId()
        let values = await levels?.values()
        let createdAt = await create?.first(where: { $0.stateKey.isEmpty })?.timestamp
        return LiveMatrixPanelDetails(
            createdAt: createdAt,
            ownPower: members.first(where: { $0.userID == ownUserID })?.power,
            kickLevel: values?.kick,
            banLevel: values?.ban,
            members: members,
            ignoredUserIDs: Set(await ignored ?? [])
        )
    }

    nonisolated private static func power(_ level: PowerLevel) -> Int64 {
        switch level {
        case .infinite: .max
        case let .value(value): value
        }
    }

    /// Matrix kick, ban and unban, as the desktop's members sheet sends them
    /// (no reason).
    func moderate(roomID: String, userID: String, action: ChatMemberAction) async -> Bool {
        do {
            let room = try room(id: roomID)
            switch action {
            case .remove: try await room.kickUser(userId: userID, reason: nil)
            case .ban: try await room.banUser(userId: userID, reason: nil)
            case .unban: try await room.unbanUser(userId: userID, reason: nil)
            case .block, .unblock, .report: return false
            }
            try runtime.requireCurrent()
            return true
        } catch {
            return false
        }
    }

    /// Whether someone is joined to any of these rooms that you are joined
    /// to, from the local store (the Team Spaces you share, desktop
    /// `matrixSharedCompanies`).
    func isJoined(userID: String, inAnyOf roomIDs: [String]) async -> Bool {
        for roomID in roomIDs {
            guard rooms.contains(where: { $0.roomID == roomID }),
                  let room = try? room(id: roomID),
                  let member = try? await room.member(userId: userID) else { continue }
            if member.membership == .join { return true }
        }
        return false
    }

    /// SDK-synchronized joined members. Lazy-loaded room heroes are never a
    /// membership roster; the SDK fetches missing state and owns its cache.
    func members(roomID: String) async -> [LiveMatrixMemberRow]? {
        do {
            let room = try room(id: roomID)
            let members = try await Task.detached(priority: .userInitiated) {
                try await Self.cachedMembers(from: room, synchronize: true)
            }.value
            try runtime.requireCurrent()
            return members
        } catch {
            return nil
        }
    }

    nonisolated fileprivate static func cachedMembers(from room: Room, synchronize: Bool = false, includeInvited: Bool = false) async throws -> [LiveMatrixMemberRow] {
        let iterator = try await (synchronize ? room.members() : room.membersNoSync())
        var members = [LiveMatrixMemberRow]()
        let maximumMembers = min(Int(iterator.len()), 10_000)
        members.reserveCapacity(maximumMembers)
        while members.count < maximumMembers,
              let chunk = iterator.nextChunk(chunkSize: UInt32(min(100, maximumMembers - members.count))),
              !chunk.isEmpty {
            for member in chunk where member.membership == .join || (includeInvited && member.membership == .invite) {
                members.append(LiveMatrixMemberRow(
                    userID: member.userId,
                    displayName: PeopleNameWords.person(member.displayName, userID: member.userId),
                    avatarURL: member.avatarUrl
                ))
                if members.count == maximumMembers { break }
            }
        }
        return members
    }

    /// Matrix room/member avatars use the SDK media repository and its cache;
    /// no raw `mxc` URL is handed to URLSession.
    func avatarThumbnail(uri: String, pixelSide: Int) async -> Data? {
        guard pixelSide > 0 else { return nil }
        if let cached = await MatrixAvatarThumbnailCache.shared.data(uri: uri,
                                                                     pixelSide: pixelSide) {
            return cached
        }
        do {
            try runtime.requireCurrent()
            let source = try MediaSource.fromUrl(url: uri)
            let data = try await runtime.client.getMediaThumbnail(
                mediaSource: source, width: UInt64(pixelSide), height: UInt64(pixelSide)
            )
            try runtime.requireCurrent()
            await MatrixAvatarThumbnailCache.shared.store(data, uri: uri, pixelSide: pixelSide)
            return data
        } catch {
            return nil
        }
    }

    /// S4 media handles are the SDK's own JSON representation. They remain
    /// opaque outside this adapter and are reconstructed only after the
    /// current-session custody check succeeds.
    func mediaThumbnail(sourceHandle: String, pixelWidth: Int, pixelHeight: Int) async -> Data? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        do {
            try runtime.requireCurrent()
            let source = try MediaSource.fromJson(json: sourceHandle)
            let data = try await runtime.client.getMediaThumbnail(
                mediaSource: source,
                width: UInt64(pixelWidth),
                height: UInt64(pixelHeight)
            )
            try runtime.requireCurrent()
            return data
        } catch {
            return nil
        }
    }

    func mediaContent(sourceHandle: String) async -> Data? {
        do {
            try runtime.requireCurrent()
            let source = try MediaSource.fromJson(json: sourceHandle)
            let data = try await runtime.client.getMediaContent(mediaSource: source)
            try runtime.requireCurrent()
            return data
        } catch {
            return nil
        }
    }

    func mediaFile(sourceHandle: String, filename: String?, mimetype: String) async -> LiveMediaFile? {
        do {
            try runtime.requireCurrent()
            let source = try MediaSource.fromJson(json: sourceHandle)
            let handle = try await runtime.client.getMediaFile(
                mediaSource: source,
                filename: filename,
                mimeType: mimetype,
                useCache: true,
                tempDir: nil
            )
            try runtime.requireCurrent()
            return try LiveMediaFile(handle: handle)
        } catch {
            return nil
        }
    }

    func maximumMediaUploadSize() async -> UInt64? {
        if let maximumMediaUploadSizeTask { return await maximumMediaUploadSizeTask.value }
        let task = Task { @MainActor [weak self] () -> UInt64? in
            guard let self else { return nil }
            do {
                try Task.checkCancellation()
                try self.runtime.requireCurrent()
                let value = try await self.runtime.client.getMaxMediaUploadSize()
                try Task.checkCancellation()
                try self.runtime.requireCurrent()
                return value
            } catch {
                return nil
            }
        }
        maximumMediaUploadSizeTask = task
        return await task.value
    }

    func stop() async {
        sessionEpoch &+= 1
        await discardLiveResources()
        rooms = []
        invites = []
        latestRoomPublication = 0
        maximumMediaUploadSizeTask?.cancel()
        maximumMediaUploadSizeTask = nil
        error = nil
        isLoadingRooms = false
    }

    private func beginSessionEpoch() -> UInt64 {
        sessionEpoch &+= 1
        latestRoomPublication = 0
        isLoadingRooms = true
        hasCompletedInitialSync = false
        error = nil
        return sessionEpoch
    }

    /// Invalidate every callback before beginning resource teardown. The
    /// roster rows remain visible.
    @discardableResult
    private func fenceCallbacksForTeardown() -> UInt64 {
        sessionEpoch &+= 1
        latestRoomPublication = 0
        roomListener?.deactivate()
        return sessionEpoch
    }

    private func establishSession(sessionEpoch expectedEpoch: UInt64) async {
        do {
            try runtime.requireCurrent()
            runtime.client.enableSendQueueUploadProgress(enable: true)
            // Offline mode (B30, §2.8): after a network error the service
            // reports `.offline` and recovers on its own instead of stopping.
            let service = try await SessionLifecycle.makeSyncService(client: runtime.client)
            guard sessionEpoch == expectedEpoch else {
                await service.stop()
                return
            }
            syncService = service
            let syncObserver = LiveMatrixSyncStateObserver(session: self, sessionEpoch: expectedEpoch)
            syncStateObserver = syncObserver
            syncStateStream = service.state(listener: syncObserver)
            try runtime.requireCurrent()

            let listService = service.roomListService()
            let stateObserver = LiveRoomListStateObserver(session: self, sessionEpoch: expectedEpoch)
            roomListStateObserver = stateObserver
            roomListStateStream = listService.state(listener: stateObserver)
            let list = try await listService.allRooms()
            guard sessionEpoch == expectedEpoch else {
                await service.stop()
                return
            }
            let listener = LiveMatrixRoomListListener(session: self, sessionEpoch: expectedEpoch)
            let entries = list.entriesWithDynamicAdapters(pageSize: 100, listener: listener)
            let controller = entries.controller()
            // Joined rooms are the roster; invites are listed so the app can
            // accept those from its own agents and bots (0.20 plain rooms
            // arrive as invites).
            guard controller.setFilter(kind: .all(filters: [.nonSpace, .any(filters: [.joined, .invite])])) else {
                throw LiveMatrixAdapterFailure.unavailable
            }

            roomList = list
            roomEntries = entries
            roomEntriesController = controller
            roomEntriesStream = entries.entriesStream()
            roomListener = listener
            let loadingListener = LiveMatrixRoomLoadingListener(session: self,
                                                                sessionEpoch: expectedEpoch)
            let loading = try list.loadingState(listener: loadingListener)
            guard sessionEpoch == expectedEpoch else {
                await service.stop()
                return
            }
            roomLoadingListener = loadingListener
            roomLoadingStream = loading.stateStream
            publishRoomLoadingState(loading.state, sessionEpoch: expectedEpoch)
            // `SessionLifecycle` starts sync and wakes every send queue at once
            // when the app is active and the session current (a new client
            // starts with every queue enabled, but requests left from an
            // earlier run only resume when woken: the hotfix's
            // `session_started` wake), stops sync in the background after a
            // short grace, wakes the queues again when sync recovers, and logs
            // each room whose queue the SDK disables.
            let sessionRuntime = runtime
            let lifecycle = SessionLifecycle(
                client: sessionRuntime.client, syncService: service,
                sessionIsCurrent: {
                    (try? sessionRuntime.requireCurrent()) != nil
                        && !MobileMatrixSessionKeepAlivePolicy.needsRefresh(
                            expiresAt: sessionRuntime.ticket.session.expiresAt, now: Date())
                },
                refreshDomainReads: { [weak self] in self?.onForegroundReturn?() }
            )
            self.lifecycle = lifecycle
            lifecycle.start()
            try runtime.requireCurrent()
            guard sessionEpoch == expectedEpoch, syncService != nil else {
                await lifecycle.stop()
                if self.lifecycle === lifecycle { self.lifecycle = nil }
                await service.stop()
                return
            }
            onSessionReady?()
        } catch {
            await failSessionStart(after: error, expectedSessionEpoch: expectedEpoch)
        }
    }

    private func failSessionStart(after error: any Error,
                                  expectedSessionEpoch: UInt64? = nil) async {
        if let expectedSessionEpoch, sessionEpoch != expectedSessionEpoch { return }
        let teardownEpoch = fenceCallbacksForTeardown()
        await discardLiveResources()
        guard sessionEpoch == teardownEpoch else { return }
        isLoadingRooms = false
        self.error = errorState(after: error, otherwise: .startupFailed)
    }

    private func discardLiveResources() async {
        sharedCollectionsRegistry.closeAll()
        roomListener?.deactivate()
        roomEntriesStream?.cancel()
        roomLoadingStream?.cancel()
        syncStateStream?.cancel()
        roomListStateStream?.cancel()
        roomEntriesStream = nil
        roomLoadingStream = nil
        syncStateStream = nil
        roomListStateStream = nil
        roomListStateObserver = nil
        hasCompletedInitialSync = false
        let lifecycle = lifecycle
        self.lifecycle = nil
        await lifecycle?.stop()
        roomEntriesController = nil
        roomEntries = nil
        roomListener = nil
        roomLoadingListener = nil
        syncStateObserver = nil
        roomList = nil
        requestedRoomPages = 1
        let service = syncService
        syncService = nil
        if let service { await service.stop() }
    }

    fileprivate func publishRooms(_ rows: [LiveMatrixRoomRow],
                                  invites newInvites: [LiveMatrixInvite],
                                  publication: UInt64,
                                  sessionEpoch: UInt64) {
        guard self.sessionEpoch == sessionEpoch, syncService != nil,
              publication >= latestRoomPublication else { return }
        do {
            try runtime.requireCurrent()
            let shouldPublishInvites = latestRoomPublication == 0 || invites != newInvites
            latestRoomPublication = publication
            rooms = rows
            onRoomsChanged?(rows)
            isLoadingRooms = false
            if shouldPublishInvites {
                invites = newInvites
                onInvitesChanged?(newInvites)
            }
        } catch {
            markSessionInvalid()
        }
    }

    fileprivate func publishCallbackFailure(sessionEpoch: UInt64) {
        guard self.sessionEpoch == sessionEpoch else { return }
        do {
            try runtime.requireCurrent()
            error = .callbackFailed
        } catch {
            markSessionInvalid()
        }
    }

    fileprivate func publishRoomLoadingState(_ state: RoomListLoadingState,
                                             sessionEpoch: UInt64) {
        guard self.sessionEpoch == sessionEpoch, syncService != nil else { return }
        do {
            try runtime.requireCurrent()
            switch state {
            case .notLoaded:
                isLoadingRooms = true
            case let .loaded(maximumNumberOfRooms):
                requestRoomPages(maximumNumberOfRooms)
                isLoadingRooms = false
            }
        } catch {
            isLoadingRooms = false
            markSessionInvalid()
        }
    }

    fileprivate func publishRoomListState(_ state: RoomListServiceState,
                                          sessionEpoch: UInt64) {
        guard self.sessionEpoch == sessionEpoch, syncService != nil else { return }
        guard !hasCompletedInitialSync else { return }
        switch state {
        case .settingUp, .running:
            hasCompletedInitialSync = true
            onInitialSyncCompleted?()
        case .initial, .recovering, .error, .terminated:
            break
        }
    }

    fileprivate func publishSyncState(_ state: SyncServiceState,
                                      sessionEpoch: UInt64) {
        guard self.sessionEpoch == sessionEpoch, syncService != nil else { return }
        do {
            try runtime.requireCurrent()
            switch state {
            case .running:
                if error == .offline || error == .startupFailed {
                    error = nil
                    // Network is back: `SessionLifecycle` wakes the send
                    // queues; an open chat stops backing off its paging.
                    onSyncRecovered?()
                }
            case .offline:
                error = .offline
                isLoadingRooms = false
            case .terminated where LiveScenePhaseRelay.shared.phase != .active:
                // `SessionLifecycle` stopped sync after the background grace:
                // not a failure. The next foreground starts it again.
                isLoadingRooms = false
            case .error, .terminated:
                error = .startupFailed
                isLoadingRooms = false
            case .idle:
                break
            }
        } catch {
            isLoadingRooms = false
            markSessionInvalid()
        }
    }

    private func requestRoomPages(_ maximum: UInt32?) {
        guard let maximum, maximum > 100, let roomEntriesController else { return }
        // Keep the native list paged while making ordinary large accounts fully
        // discoverable without inventing a second cache or room-list transport.
        let boundedMaximum = min(Int(maximum), 10_000)
        let pageCount = (boundedMaximum + 99) / 100
        while requestedRoomPages < pageCount {
            roomEntriesController.addOnePage()
            requestedRoomPages += 1
        }
    }

    private func errorState(after _: any Error,
                            otherwise fallback: LiveMatrixSessionError) -> LiveMatrixSessionError {
        (try? runtime.requireCurrent()) == nil ? .currentSessionInvalid : fallback
    }
}

private enum LiveMatrixAdapterFailure: Error {
    case unavailable
}

private final class LiveMatrixRoomLoadingListener: RoomListLoadingStateListener, @unchecked Sendable {
    private weak var session: LiveMatrixSession?
    private let sessionEpoch: UInt64

    init(session: LiveMatrixSession, sessionEpoch: UInt64) {
        self.session = session
        self.sessionEpoch = sessionEpoch
    }

    func onUpdate(state: RoomListLoadingState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            session?.publishRoomLoadingState(state, sessionEpoch: sessionEpoch)
        }
    }
}

private final class LiveRoomListStateObserver: RoomListServiceStateListener, @unchecked Sendable {
    private weak var session: LiveMatrixSession?
    private let sessionEpoch: UInt64

    init(session: LiveMatrixSession, sessionEpoch: UInt64) {
        self.session = session
        self.sessionEpoch = sessionEpoch
    }

    func onUpdate(state: RoomListServiceState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            session?.publishRoomListState(state, sessionEpoch: sessionEpoch)
        }
    }
}

private final class LiveMatrixSyncStateObserver: SyncServiceStateObserver, @unchecked Sendable {
    private weak var session: LiveMatrixSession?
    private let sessionEpoch: UInt64

    init(session: LiveMatrixSession, sessionEpoch: UInt64) {
        self.session = session
        self.sessionEpoch = sessionEpoch
    }

    func onUpdate(state: SyncServiceState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            session?.publishSyncState(state, sessionEpoch: sessionEpoch)
        }
    }
}

/// FFI list batches are applied on one serial queue before exactly one immutable
/// snapshot is handed back to the main actor.
private final class LiveMatrixRoomListListener: RoomListEntriesListener, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.atum.live.matrix.room-list-diffs")
    private weak var session: LiveMatrixSession?
    private let sessionEpoch: UInt64
    private var rooms = [Room]()
    private var publication: UInt64 = 0
    private var active = true

    init(session: LiveMatrixSession, sessionEpoch: UInt64) {
        self.session = session
        self.sessionEpoch = sessionEpoch
    }

    func deactivate() {
        queue.sync { active = false; rooms.removeAll() }
    }

    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
        queue.async { [weak self] in
            guard let self, self.active else { return }
            guard self.apply(roomEntriesUpdate) else {
                self.active = false
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.session?.publishCallbackFailure(sessionEpoch: self.sessionEpoch)
                }
                return
            }
            self.publication &+= 1
            let publication = self.publication
            let snapshot = self.rooms
            let sessionEpoch = self.sessionEpoch
            let session = self.session
            Task.detached { [weak session] in
                let (rows, invites) = await Self.rows(from: snapshot)
                await MainActor.run {
                    session?.publishRooms(rows, invites: invites, publication: publication,
                                          sessionEpoch: sessionEpoch)
                }
            }
        }
    }

    private func apply(_ diff: [RoomListEntriesUpdate]) -> Bool {
        for update in diff {
            switch update {
            case .append(let values): rooms.append(contentsOf: values)
            case .clear: rooms.removeAll()
            case .pushFront(let value): rooms.insert(value, at: 0)
            case .pushBack(let value): rooms.append(value)
            case .popFront:
                guard !rooms.isEmpty else { return false }
                rooms.removeFirst()
            case .popBack:
                guard !rooms.isEmpty else { return false }
                rooms.removeLast()
            case .insert(let index, let value):
                guard Int(index) <= rooms.count else { return false }
                rooms.insert(value, at: Int(index))
            case .set(let index, let value):
                guard Int(index) < rooms.count else { return false }
                rooms[Int(index)] = value
            case .remove(let index):
                guard Int(index) < rooms.count else { return false }
                rooms.remove(at: Int(index))
            case .truncate(let length):
                guard Int(length) <= rooms.count else { return false }
                rooms.removeLast(rooms.count - Int(length))
            case .reset(let values): rooms = values
            }
        }
        return true
    }

    /// Reads every room concurrently and keeps the SDK's room order. Only a
    /// room with the owner and one other active member can be an agent's or an
    /// official bot's chat, so larger rooms skip the create-state and
    /// account-data reads instead of paying for them on every rebuild.
    nonisolated private static func rows(
        from rooms: [Room]
    ) async -> ([LiveMatrixRoomRow], [LiveMatrixInvite]) {
        let reads = await withTaskGroup(
            of: (index: Int, row: LiveMatrixRoomRow?, invite: LiveMatrixInvite?).self
        ) { group in
            for (index, room) in rooms.enumerated() {
                group.addTask {
                    guard let info = try? await room.roomInfo(), !info.isSpace else {
                        return (index, nil, nil)
                    }
                    switch info.membership {
                    case .joined:
                        return (index, await row(from: room, info: info), nil)
                    case .invited:
                        return (index, nil, await invite(from: room, info: info))
                    default:
                        return (index, nil, nil)
                    }
                }
            }
            var reads = [(index: Int, row: LiveMatrixRoomRow?, invite: LiveMatrixInvite?)]()
            reads.reserveCapacity(rooms.count)
            for await read in group { reads.append(read) }
            return reads
        }
        var result = [LiveMatrixRoomRow]()
        var invites = [LiveMatrixInvite]()
        result.reserveCapacity(rooms.count)
        for read in reads.sorted(by: { $0.index < $1.index }) {
            if let row = read.row { result.append(row) }
            if let invite = read.invite { invites.append(invite) }
        }
        return (result, invites)
    }

    nonisolated private static func invite(from room: Room, info: RoomInfo) async -> LiveMatrixInvite {
        async let latest = room.latestEvent()
        // Every invitation's type is read, not only a small one's: a company DM or group DM
        // invitation must never read as a person's invitation, whatever its member count.
        let type = await Self.roomType(from: room)
        let preview: (timestamp: UInt64?, inviter: String?, name: String?) = switch await latest {
        case let .remoteInvite(timestamp, inviter, profile):
            (UInt64(timestamp), inviter, senderName(from: profile, userID: inviter ?? ""))
        default:
            (nil, nil, nil)
        }
        return LiveMatrixInvite(
            roomID: info.id,
            inviterID: info.inviter?.userId ?? preview.inviter,
            // Readable names only; the roster row falls back to the unnamed words.
            displayName: [info.displayName, info.rawName, preview.name]
                .lazy.compactMap(MatrixPersonName.readableRoomName).first,
            inviterDisplayName: info.inviter.flatMap { MatrixPersonName.name($0.displayName, userID: $0.userId) }
                ?? preview.name,
            latestTimestamp: preview.timestamp,
            isEncrypted: encrypted(info.encryptionState),
            roomType: type,
            avatarURL: info.avatarUrl ?? (info.isDirect ? info.inviter?.avatarUrl : nil),
            isDirect: info.isDirect
        )
    }

    nonisolated private static func row(from room: Room, info: RoomInfo) async -> LiveMatrixRoomRow {
        let isChatCandidate = info.activeMembersCount <= 2
        async let latest = room.latestEvent()
        // The room type is read for every room (cached `m.room.create`, no extra request): a
        // company conversation of any size must be recognised so it never reads as a Personal chat.
        async let roomTypeValue = roomTypeIfChatCandidate(from: room, isChatCandidate: true)
        async let botData = appBotAccountDataIfChatCandidate(from: room, isChatCandidate: isChatCandidate)
        async let privateTitleData = try? await room.accountDataRaw(eventType: ChatPrivateTitle.eventType)
        let preview = latestText(from: await latest)
        // A delivery-outcome notice is not something a person said. Keep the
        // row's last real message (the snapshot merge supplies it) instead of
        // letting the warning become the chat list's second line.
        let suppressed = preview.text.map {
            RowPreview.suppressesPreview(body: $0, isOwn: preview.isOwn,
                                         isNotice: preview.isNotice)
        } ?? false
        let bot = await botData
        let type = await roomTypeValue
        let name = [info.displayName, info.rawName].lazy.compactMap(MatrixPersonName.readableRoomName).first
            ?? PeopleNameWords.room(nil, isDirect: info.isDirect)
        let members = (try? await LiveMatrixSession.cachedMembers(from: room, synchronize: true, includeInvited: true)) ?? []
        return LiveMatrixRoomRow(roomID: info.id, displayName: name,
                                 avatarURL: info.avatarUrl,
                                 heroAvatarURL: await heroAvatarURL(
                                    from: info, room: room, ownUserID: room.ownUserId(),
                                    members: members
                                 ),
                                 latestText: suppressed ? nil : preview.text,
                                 latestWasDeliveryNotice: suppressed,
                                 latestPreviewContent: suppressed ? .none : preview.content,
                                 latestSenderID: preview.senderID,
                                 latestSenderName: preview.senderName,
                                 latestIsOwn: suppressed ? false : preview.isOwn,
                                 latestIsNotice: suppressed ? false : preview.isNotice,
                                 latestSendState: suppressed ? .sent : preview.sendState,
                                 latestTimestamp: preview.timestamp,
                                 unreadCount: info.numUnreadMessages,
                                 notificationCount: info.numUnreadNotifications,
                                 highlightCount: info.numUnreadMentions,
                                 isMarkedUnread: info.isMarkedUnread,
                                 isFavourite: info.isFavourite,
                                 isMuted: info.cachedUserDefinedNotificationMode == .mute,
                                 isDirect: info.isDirect || info.isDm,
                                 memberUserIDs: members.map(\.userID).filter { $0 != room.ownUserId() },
                                 memberCount: info.activeMembersCount,
                                 roomType: type,
                                 isEncrypted: Self.encrypted(info.encryptionState),
                                 appBotHiddenAt: bot.hiddenAt,
                                 legacyAppBotMove: bot.move,
                                 memberProfiles: members,
                                 isLowPriority: info.isLowPriority,
                                 topic: info.topic,
                                 privateTitle: ChatPrivateTitle.title(eventJSON: await privateTitleData))
    }

    /// The other joined member's photo, including named DMs with no heroes.
    nonisolated private static func heroAvatarURL(from info: RoomInfo, room: Room,
                                                  ownUserID: String,
                                                  members: [LiveMatrixMemberRow]) async -> String? {
        guard info.activeMembersCount <= 2 else { return nil }
        let other = members.first(where: { $0.userID != ownUserID })
        if let avatar = other?.avatarURL { return avatar }
        let userID = other?.userID
        guard let userID, userID != ownUserID else { return nil }
        return try? await room.memberAvatarUrl(userId: userID)
    }

    nonisolated private static func roomTypeIfChatCandidate(
        from room: Room, isChatCandidate: Bool
    ) async -> String? {
        guard isChatCandidate else { return nil }
        return await roomType(from: room)
    }

    nonisolated private static func appBotAccountDataIfChatCandidate(
        from room: Room, isChatCandidate: Bool
    ) async -> (hiddenAt: UInt64?, move: MobileLegacyAppBotMove?) {
        guard isChatCandidate else { return (nil, nil) }
        return await appBotAccountData(from: room)
    }

    /// The desktop's per-person bot-chat notes from the SDK's cached room
    /// account data. A missing, unreadable or invalid event is simply absent:
    /// the room then stays visible and eligible.
    nonisolated private static func appBotAccountData(
        from room: Room
    ) async -> (hiddenAt: UInt64?, move: MobileLegacyAppBotMove?) {
        async let hidden = try? await room.accountDataRaw(eventType: MobileAppBotRoomAccountData.hiddenType)
        async let moved = try? await room.accountDataRaw(eventType: MobileAppBotRoomAccountData.legacyMovedType)
        return (MobileAppBotRoomAccountData.hiddenAt(eventJSON: await hidden),
                MobileAppBotRoomAccountData.legacyMove(eventJSON: await moved))
    }

    nonisolated private static func roomType(from room: Room) async -> String? {
        guard let events = try? await room.stateEvents(eventType: .roomCreate),
              let create = events.first(where: { $0.stateKey.isEmpty }) else { return nil }
        return MobileRoomTypePolicy.roomType(createContentJSON: create.contentJson)
    }

    nonisolated private static func encrypted(_ state: EncryptionState) -> Bool? {
        switch state {
        case .encrypted: true
        case .notEncrypted: false
        case .unknown: nil
        }
    }

    nonisolated private static func latestText(from event: LatestEventValue) -> LiveLatestEventPreview {
        switch event {
        case let .remote(timestamp, sender, isOwn, profile, content):
            return LiveLatestEventPreview(text: text(from: content), content: previewContent(from: content),
                                          senderID: sender, senderName: senderName(from: profile, userID: sender),
                                          isOwn: isOwn, isNotice: isNotice(content),
                                          sendState: .sent, timestamp: UInt64(timestamp))
        case let .local(timestamp, sender, profile, content, state):
            let sendState: RowPreview.SendState = switch state {
            case .isSending: .sending
            case .hasBeenSent: .sent
            case .cannotBeSent: .cannotBeSent
            }
            return LiveLatestEventPreview(text: text(from: content), content: previewContent(from: content),
                                          senderID: sender, senderName: senderName(from: profile, userID: sender),
                                          isOwn: true, isNotice: isNotice(content),
                                          sendState: sendState, timestamp: UInt64(timestamp))
        case .none, .remoteInvite:
            return LiveLatestEventPreview()
        }
    }

    /// The sender's own name, or nil: never their Matrix ID or its opaque localpart.
    nonisolated private static func senderName(from profile: ProfileDetails, userID: String) -> String? {
        guard case let .ready(displayName, _, _, _, _) = profile else { return nil }
        return MatrixPersonName.name(displayName, userID: userID)
    }

    nonisolated private static func isNotice(_ content: TimelineItemContent) -> Bool {
        guard case let .msgLike(messageLike) = content,
              case let .message(message) = messageLike.kind,
              case .notice = message.msgType else { return false }
        return true
    }

    nonisolated private static func previewContent(from content: TimelineItemContent) -> RowPreview.Content {
        guard case let .msgLike(messageLike) = content else { return .none }
        switch messageLike.kind {
        case let .message(message):
            switch message.msgType {
            case let .text(value): return .text(value.body)
            case let .emote(value): return .text(value.body)
            case let .notice(value): return .text(value.body)
            case .image: return .image
            case let .file(value): return .file(name: value.filename)
            case .video: return .video
            case .audio: return .audio
            case let .location(value): return .text(value.description ?? value.body)
            case let .gallery(value): return .text(value.body)
            case let .other(_, body): return .text(body)
            }
        case .sticker: return .sticker
        case let .poll(question, _, _, _, _, _, _): return .text(question)
        case .redacted: return .redacted
        case .unableToDecrypt: return .undecryptable
        case .other, .liveLocation: return .none
        }
    }
}

private struct LiveLatestEventPreview {
    var text: String?
    var content: RowPreview.Content
    var senderID: String?
    var senderName: String?
    var isOwn: Bool
    var isNotice: Bool
    var sendState: RowPreview.SendState
    var timestamp: UInt64?

    init(text: String? = nil, content: RowPreview.Content = .none,
         senderID: String? = nil, senderName: String? = nil,
         isOwn: Bool = false, isNotice: Bool = false,
         sendState: RowPreview.SendState = .sent,
         timestamp: UInt64? = nil) {
        self.text = text
        self.content = content
        self.senderID = senderID
        self.senderName = senderName
        self.isOwn = isOwn
        self.isNotice = isNotice
        self.sendState = sendState
        self.timestamp = timestamp
    }
}

/// The roster preview: text and notices. Agents and bots send status and
/// error notices (`m.notice`); dropping them would show silence.
private func text(from content: TimelineItemContent) -> String? {
    guard case let .msgLike(messageLike) = content,
          case let .message(message) = messageLike.kind else { return nil }
    switch message.msgType {
    case .text, .notice: return message.body
    default: return nil
    }
}

/// HC-7: the private Rename's one request never follows a redirect.
private final class LiveMatrixNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async
        -> URLRequest? { nil }
}
