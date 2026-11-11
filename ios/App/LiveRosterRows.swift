import AtumNativeAPI
import AtumChat
import Foundation

enum HomeAddFriendResult: Equatable, Sendable {
    case openRoom(String)
    case notFound(String)
    case notMessageable
    case rateLimited(Int?)
    case searchFailed
    case startFailed
}

/// Pure input and reuse rules for Add friend. The directory accepts one exact
/// public handle, and an existing direct conversation always wins over room
/// creation so the phone cannot fork someone's chat merely because it was
/// started on another device.
enum HomeAddFriendPolicy {
    static func handle(_ raw: String) -> NativeHandle? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.first == "@" { value.removeFirst() }
        return try? NativeHandle(value)
    }

    static func existingRoomID(in rooms: [LiveMatrixRoomRow], matrixUserID: String) -> String? {
        rooms
            .filter {
                $0.isDirect && $0.memberCount <= 2 && $0.memberUserIDs.contains(matrixUserID)
                    && !ConversationTypeGuard.excludedFromBotAndAgent(roomType: $0.roomType)
            }
            .sorted {
                let left = $0.latestTimestamp ?? 0
                let right = $1.latestTimestamp ?? 0
                return left == right ? $0.roomID < $1.roomID : left > right
            }
            .first?.roomID
    }
}

struct HomeGroupCandidate: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case person, assistant }
    let id: String
    let name: String
    let kind: Kind
    var avatarURL: String? = nil
    var handle: String? = nil
}

enum HomeGroupLookupResult: Equatable, Sendable {
    case candidate(HomeGroupCandidate)
    case notFound(String)
    case notMessageable
    case rateLimited(Int?)
    case failed
}

enum HomeGroupCreateResult: Equatable, Sendable {
    case openRoom(String)
    case failed
}

enum HomeAssistantCreateResult: Equatable, Sendable {
    case openRoom(String)
    case starting
    case unavailable
    case name(AssistantNameRefusal)
    case failed
}

struct HomeAssistantActions {
    let pending: Bool
    let create: (String) async -> HomeAssistantCreateResult
    /// The owner's assistants' names, so a second "Lan" is refused before
    /// anything is created (desktop `checkAssistantName`).
    var names: [String] = []
    /// Checks a bot handle before the assistant exists; nil hides the field
    /// (desktop draws it only where the directory is reachable).
    var checkHandle: (@MainActor (NativeHandle) async throws -> AgentAliasCheck)?
    /// The persona, handle and photo writes for the new assistant's room.
    var followUp: (@MainActor (String) -> AssistantCreateFollowUp?)?
}

/// The lifecycle endpoint identifies the operation, assistant and canonical
/// room; `/agents` and the live Matrix room list independently prove that the
/// identity was published and the exact assistant actually joined. Nothing
/// outside this relation is safe to navigate to as the new assistant chat.
enum HomeAssistantLifecyclePolicy {
    static func authoritativeAgent(for snapshot: AgentLifecycleSnapshot,
                                   in agents: [AgentsResponse.Agent]) -> AgentsResponse.Agent? {
        guard let expected = snapshot.assistant,
              expected.status == .active,
              expected.answering == .cloud,
              expected.matrixUser != nil else { return nil }
        return agents.first {
            $0.id == expected.id
                && $0.principal == expected.principal
                && $0.matrixUser == expected.matrixUser
                && $0.status == .active
                && $0.answering == .cloud
        }
    }

    static func joinedRoomID(for snapshot: AgentLifecycleSnapshot,
                             authoritativeAgent: AgentsResponse.Agent?,
                             rooms: [LiveMatrixRoomRow]) -> String? {
        guard snapshot.isAuthoritativeReady,
              let expected = snapshot.assistant,
              let authoritativeAgent,
              authoritativeAgent.id == expected.id,
              authoritativeAgent.principal == expected.principal,
              authoritativeAgent.matrixUser == expected.matrixUser,
              authoritativeAgent.status == .active,
              authoritativeAgent.answering == .cloud,
              let matrixUser = authoritativeAgent.matrixUser?.rawValue,
              let roomID = snapshot.roomID,
              rooms.contains(where: {
                  $0.roomID == roomID && $0.memberUserIDs.contains(matrixUser)
                      && !ConversationTypeGuard.excludedFromBotAndAgent(roomType: $0.roomType)
              }) else { return nil }
        return roomID
    }
}

struct HomePeopleDiscoveryActions {
    let search: (String) async -> [HomeGroupCandidate]?
    let open: (String) async -> HomeAddFriendResult
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?
}

struct HomeGroupActions {
    let candidates: [HomeGroupCandidate]
    let lookup: (String) async -> HomeGroupLookupResult
    let create: (String, [HomeGroupCandidate]) async -> HomeGroupCreateResult
    var search: ((String) async -> [HomeGroupCandidate]?)? = nil
    var loadMatrixThumbnail: ((String, Int) async -> Data?)? = nil
}

enum HomeGroupPolicy {
    static let maximumInvites = 20
    static let maximumAssistants = 5

    static func name(typed: String, selected: [HomeGroupCandidate]) -> String? {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            guard typed.unicodeScalars.count <= 200,
                  !typed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            return typed
        }
        let joined = selected.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard !joined.isEmpty else { return nil }
        let scalars = Array(joined.unicodeScalars)
        return scalars.count <= 200
            ? joined
            : String(String.UnicodeScalarView(scalars.prefix(199))) + "…"
    }

    static func canSelect(_ candidate: HomeGroupCandidate,
                          selected: [HomeGroupCandidate]) -> Bool {
        if selected.contains(where: { $0.id == candidate.id }) { return true }
        guard selected.count < maximumInvites else { return false }
        if candidate.kind == .assistant {
            return selected.filter { $0.kind == .assistant }.count < maximumAssistants
        }
        return true
    }

    static func fingerprint(name: String, selected: [HomeGroupCandidate]) -> String {
        name + "\n" + selected.map(\.id).sorted().joined(separator: "\n")
    }
}

/// The chat list's rows from plain values (revamp plan §4.2 items 1–2): the
/// owner's agents, the app catalog, this phone's rooms and invitations, the
/// desktop's bot pointers and the rooms hidden on this phone. Pure: the same
/// inputs give the same rows. `LiveAppModel` feeds it the live values; the
/// Debug scripted roster (`-AtumScripted bot.moon-no-room`) feeds it
/// synthetic ones, so a UI test proves this composition, not a copy of it.
enum LiveRosterRows {
    /// The vendored line for an active agent whose room has not reached this
    /// phone yet (`uiDeliveryPending`: "Getting ready" / "Đang chuẩn bị").
    static let waitingCopyKey = "src.matrix.mobile-device-copy.mobileDeviceCopy.uiDeliveryPending"
    /// The existing shared "Coming soon" line used by the inert catalog row.
    static let comingSoonCopyKey = "desktop.atum.discover.comingSoon"

    struct Input {
        /// `/agents`, every status; only active agents are listed.
        var agents: [AgentsResponse.Agent]
        /// Positive platform bindings, before any personal bot/agent choice.
        var privateCosBindings = CompanyPrivateCosBindings()
        /// Company notes rooms proven by their create content (`CompanyNotesSelf`): plain rows
        /// only Team Space opens ("You"); Home never lists them.
        var notesSelfRoomIDs = Set<String>()
        /// Their title, "You", instead of the SDK's "Empty Room".
        var notesSelfTitle: String? = nil
        /// `/apps`.
        var apps: [AppDescriptor]
        var rooms: [LiveMatrixRoomRow]
        var invites: [LiveMatrixInvite]
        /// The desktop's pointer room per app ID (`io.atum.app_bot.dm.<appId>`).
        var pointers: [String: String]
        var hiddenRooms: MobileHiddenRoomLedger
        /// The person's explicit `io.atum.app_shortcut.<appId>` choice. A
        /// missing entry is `unknown`; callers must pass a successful read's
        /// result, never guess a default.
        var appShortcuts: [AppCatalogID: MobileAppShortcutState] = [:]
        /// The language for catalog names (`Locale.current`'s, as the model).
        var locale: String
        /// The localized "Getting ready" line for an agent whose room is not
        /// on this phone yet. Nil keeps the agent's title.
        var waitingDetail: String? = nil
        /// The vendored "Coming soon" line for an inert presentation-only row.
        var comingSoonDetail: String? = nil
        /// The one joined room named by this account's `io.atum.founder_chat`
        /// record, and the platform-named Founder it contains. Only that exact
        /// room may carry the ordinary human Founder row and official mark.
        var founderRoomID: String? = nil
        var founderUserID: String? = nil
        var founderName: String? = nil
        /// The localized identity line used while the exact Founder chat has
        /// no message preview.
        var founderSubtitle: String? = nil
        /// Matrix profile metadata for the exact Founder member. Atum renders
        /// the bundled raven for the marked row; this remains available to
        /// non-Founder presentation paths without granting identity.
        var founderAvatarURL: String? = nil
    }

    struct Output {
        let rows: [LiveProductRoom]
        /// The chat chosen for each agent, for the model's log.
        let agentChoices: [String: MobileAgentRoomChoice]
        /// Agent keys rejected because more than one plain room exists.
        let agentDuplicatePlainRoomCounts: [String: Int]
    }

    /// Applied after cache merging too, so a cached joined/invited row cannot
    /// re-enter Home while catalog or Matrix reads are still settling.
    static func isPrivateCosHomeRow(_ room: ChatListSnapshot.Room,
                                    agents: [AgentsResponse.Agent],
                                    bindings: CompanyPrivateCosBindings) -> Bool {
        if bindings.roomIDs.contains(room.roomID) || bindings.roomIDs.contains(room.id) { return true }
        if let principal = room.assistantPrincipal, bindings.agentPrincipals.contains(principal) { return true }
        if let user = room.assistantMatrixUserID, bindings.agentUserIDs.contains(user) { return true }
        return agents.contains { agent in
            room.id == "agent:" + agent.id.rawValue
                && (bindings.agentPrincipals.contains(agent.principal.rawValue)
                    || bindings.agentUserIDs.contains(agent.matrixUser?.rawValue ?? ""))
        }
    }

    static func rows(_ input: Input) -> Output {
        struct IndexedAgent {
            let value: AgentsResponse.Agent
            let order: Int

            var metadata: LiveProductAssistantMetadata {
                LiveProductAssistantMetadata(id: value.id.rawValue,
                                             isDefault: value.isDefault,
                                             order: order,
                                             botHandle: value.slug)
            }
        }
        let agents = input.agents.enumerated().compactMap { order, agent in
            agent.status == .active
                && !input.privateCosBindings.agentPrincipals.contains(agent.principal.rawValue)
                && !input.privateCosBindings.agentUserIDs.contains(agent.matrixUser?.rawValue ?? "")
                ? IndexedAgent(value: agent, order: order) : nil
        }
        // Every agent, not only an active one, is an agent sender for the
        // invitation guard below: a retired agent's lingering task-room invite
        // must not turn into a person row.
        let agentSenders = Set(input.agents.compactMap { $0.matrixUser?.rawValue })
        // Agent task rooms and the desktop's notes-to-self rooms are never Chats
        // rows (the notes room has only its owner, so the SDK calls it "Empty Room").
        let rooms = input.rooms.filter {
            !MobileRoomTypePolicy.isHiddenFromChats($0.roomType) || input.notesSelfRoomIDs.contains($0.roomID)
        }
        let invites = input.invites.filter { !MobileRoomTypePolicy.isHiddenFromChats($0.roomType) }
        // A room or invitation that claims the company conversation type is never a bot's or an
        // agent's: the choosers below see only these. The claim still rides on the plain row, so
        // Home leaves it out and only the directory can open it.
        let botAndAgentRooms = rooms.filter { !input.privateCosBindings.roomIDs.contains($0.roomID)
            && !ConversationTypeGuard.excludedFromBotAndAgent(roomType: $0.roomType) }
        let botAndAgentInvites = invites.filter { !input.privateCosBindings.roomIDs.contains($0.roomID)
            && !ConversationTypeGuard.excludedFromBotAndAgent(roomType: $0.roomType) }
        let catalogApps = input.apps
            .sorted { left, right in
                left.rosterOrder == right.rosterOrder
                    ? left.appID.rawValue < right.appID.rawValue
                    : left.rosterOrder < right.rosterOrder
            }
        // A presentation-only entry never contributes a bot identity, even if
        // a malformed producer supplied one. Only executable entries do.
        let availableApps = catalogApps.filter { $0.effectiveRosterState == .available }
        let catalogBots = catalogBotUserIDs(availableApps)
        var agentByMatrixUser = [String: IndexedAgent]()
        for agent in agents {
            if let matrixUser = agent.value.matrixUser?.rawValue {
                agentByMatrixUser[matrixUser] = agent
            }
        }
        var appByMatrixUser = [String: AppDescriptor]()
        // Each bot's one chat, in desktop's order (§4.2 item 2).
        var botChoices = [AppCatalogID: MobileAppBotChatChoice]()
        for app in availableApps {
            guard let bot = app.bot else { continue }
            appByMatrixUser[bot.userID.rawValue] = app
            if let choice = botChatChoice(forBot: bot.userID.rawValue, appID: app.appID.rawValue,
                                          rooms: botAndAgentRooms, invites: botAndAgentInvites,
                                          pointers: input.pointers, catalogBotUserIDs: catalogBots) {
                botChoices[app.appID] = choice
            }
        }

        var consumedAgentIDs = Set<NativeID>()
        var consumedAppIDs = Set<AppCatalogID>()
        var rows = [LiveProductRoom]()

        // Classify each joined room. Only a room with the owner plus one other
        // member (joined or invited) can be an agent's or bot's chat; a group
        // stays its own people row even when an agent is in it or spoke last.
        struct AgentRoom {
            let room: LiveMatrixRoomRow
            let groupKey: String
            let agent: IndexedAgent?
            let app: AppDescriptor?
            let isBotRoom: Bool
        }
        var classified = [(room: LiveMatrixRoomRow, agentRoom: AgentRoom?)]()
        for room in rooms {
            // A Founder race loser that could not be safely left is hidden by
            // the same account-scoped ledger as other phone-hidden rooms. A
            // newer message reveals it again; trust is never inferred from
            // the hidden state.
            if !input.privateCosBindings.roomIDs.contains(room.roomID),
               input.hiddenRooms.isHidden(roomID: room.roomID,
                                          latestTimestamp: room.latestTimestamp) {
                continue
            }
            // A conversation-type room stays a plain row (carrying its claim), whoever is in it.
            if input.privateCosBindings.roomIDs.contains(room.roomID)
                || ConversationTypeGuard.excludedFromBotAndAgent(roomType: room.roomType) {
                classified.append((room, nil))
                continue
            }
            let isBotRoom = botUserID(for: room, catalogBotUserIDs: catalogBots) != nil
            // A hidden bot room gives its app row back, so tapping Moon or
            // Andy reopens this same room.
            if isBotRoom, isHidden(room, by: input.hiddenRooms) {
                continue
            }
            let candidateIDs = MobileAgentRoomPolicy.candidateUserIDs(memberCount: room.memberCount,
                                                                      heroes: room.memberUserIDs,
                                                                      latestSenderID: room.latestSenderID)
            let agent = candidateIDs.lazy.compactMap { agentByMatrixUser[$0] }.first
            let app = agent == nil
                ? candidateIDs.lazy.compactMap { appByMatrixUser[$0] }.first
                : nil
            let groupKey = agent.map { "agent:" + $0.value.id.rawValue }
                ?? app.map { "app:" + $0.appID.rawValue }
            guard let groupKey else {
                classified.append((room, nil))
                continue
            }
            classified.append((room, AgentRoom(room: room, groupKey: groupKey, agent: agent, app: app,
                                               isBotRoom: isBotRoom)))
        }

        // One conversation per agent: the room without encryption is its chat
        // and the only room listed for it. Its other rooms (with encryption,
        // or not known yet) are not listed anywhere; they stay on the server.
        // With no plain room yet, the most recent room is listed. More than
        // one plain room has no choice: every duplicate stays hidden and the
        // active-agent pass below emits its disabled row instead of guessing.
        // A bot's rooms are not in this listing: its chat is `botChoices`
        // (plain rooms only, desktop's order).
        let listing = MobileAgentRoomPolicy.listing(classified.filter { $0.agentRoom?.app == nil }.map { entry in
            MobileRosterRoomEntry(roomID: entry.room.roomID, agentKey: entry.agentRoom?.groupKey,
                                  encrypted: entry.room.isEncrypted,
                                  latestTimestamp: entry.room.latestTimestamp)
        })
        let listedRoomIDs = Set(listing.listedRoomIDs).union(botChoices.values.map(\.roomID))

        var emittedRoomIDs = Set<String>()
        for entry in classified where listedRoomIDs.contains(entry.room.roomID) {
            guard emittedRoomIDs.insert(entry.room.roomID).inserted else { continue }
            guard let agentRoom = entry.agentRoom else {
                let room = entry.room
                let isFounder: Bool = {
                    guard let founderRoomID = input.founderRoomID,
                          founderRoomID == room.roomID,
                          let founderUserID = input.founderUserID else { return false }
                    return room.memberCount <= 2
                        && (room.memberUserIDs.isEmpty || room.memberUserIDs.contains(founderUserID))
                }()
                // HC-7: your own name for the chat comes first (desktop
                // `matrixChatTitle`); the Founder's and your notes' are the app's.
                let title = isFounder
                    ? (input.founderName ?? room.displayName)
                    : input.notesSelfRoomIDs.contains(room.roomID)
                        ? (input.notesSelfTitle ?? room.displayName)
                        : (room.privateTitle ?? room.displayName)
                let previewContent: RowPreview.Content = if isFounder,
                                                           room.latestPreviewContent == .none,
                                                           let subtitle = input.founderSubtitle {
                    .text(subtitle)
                } else {
                    room.latestPreviewContent
                }
                rows.append(LiveProductRoom(
                    id: room.roomID,
                    kind: room.isDirect && room.memberCount <= 2 ? .people : .group,
                    title: title,
                    detail: isFounder && room.latestText == nil ? input.founderSubtitle : room.latestText,
                    previewContent: previewContent,
                    latestEventAt: room.latestTimestamp.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
                    latestSenderName: room.latestSenderName,
                    latestIsOwn: room.latestIsOwn,
                    latestSendState: room.latestSendState,
                    latestWasDeliveryNotice: room.latestWasDeliveryNotice,
                    avatar: .monogram(monogram(for: title)),
                    matrixAvatarURL: MobileFounderPolicy.presentedAvatarURL(
                        roomAvatarURL: room.avatarURL,
                        roomName: room.displayName,
                        founderName: input.founderName,
                        founderAvatarURL: input.founderAvatarURL,
                        isFounder: isFounder
                    ) ?? room.heroAvatarURL,
                    appVerification: isFounder ? .official : nil,
                    unreadCount: Int(min(room.unreadCount, UInt64(Int.max))),
                    notificationCount: Int(min(room.notificationCount, UInt64(Int.max))),
                    highlightCount: Int(min(room.highlightCount, UInt64(Int.max))),
                    isMarkedUnread: room.isMarkedUnread,
                    isPinned: room.isFavourite,
                    isMuted: room.isMuted,
                    isLowPriority: room.isLowPriority,
                    isFounder: isFounder,
                    claimsConversationType: ConversationRoomType.isClaimed(room.roomType),
                    roomAvatarURL: room.avatarURL
                ))
                continue
            }
            if let agent = agentRoom.agent { consumedAgentIDs.insert(agent.value.id) }
            if let app = agentRoom.app { consumedAppIDs.insert(app.appID) }
            let title = agentRoom.agent?.value.displayName
                ?? agentRoom.app?.name.localized(locale: input.locale, fallback: agentRoom.app?.app ?? "")
                ?? agentRoom.room.displayName
            let avatar = agentRoom.agent.map { productAvatar(for: $0.value) }
                ?? agentRoom.app.map { productAvatar(for: $0, locale: input.locale) }
                ?? .monogram(monogram(for: title))
            rows.append(agentRow(agentRoom.room, title: title, avatar: avatar,
                                 app: agentRoom.app,
                                 assistant: agentRoom.agent?.metadata,
                                 isBotRoom: agentRoom.isBotRoom, locale: input.locale))
        }

        for agent in agents where !consumedAgentIDs.contains(agent.value.id) {
            let groupKey = "agent:" + agent.value.id.rawValue
            // A duplicate plain room is an invariant failure, not a room still
            // on its way: it keeps the agent's title and gets no spinner.
            let duplicatePlainRoom = listing.duplicatePlainRoomCounts[groupKey] != nil
            let detail = duplicatePlainRoom ? agent.value.title : (input.waitingDetail ?? agent.value.title)
            rows.append(LiveProductRoom(
                id: groupKey,
                kind: .agent,
                title: agent.value.displayName,
                detail: detail,
                previewContent: detail.map(RowPreview.Content.text) ?? .none,
                avatar: productAvatar(for: agent.value),
                assistant: agent.metadata,
                canOpen: false,
                isAwaitingRoom: !duplicatePlainRoom
            ))
        }
        // Human invitations remain actionable Home rows. Agent and catalog
        // bot invitations are handled by the existing automatic acceptance
        // path and never appear as a dead-end person chat. This also covers an
        // `io.atum.agent_task.v1` invite whose stripped create state is
        // unreadable (so `roomType` is nil): its sender still proves it is not
        // a person invitation.
        for invite in invites {
            // An agent's or bot's invitation to a conversation-type room is not theirs to hide:
            // it stays a plain, flagged row that Home leaves out.
            if !input.privateCosBindings.roomIDs.contains(invite.roomID),
               let inviter = invite.inviterID,
               !ConversationTypeGuard.excludedFromBotAndAgent(roomType: invite.roomType),
               agentSenders.contains(inviter) || catalogBots.contains(inviter) {
                continue
            }
            // Stripped invite state may arrive before profiles. Keep the invite
            // actionable even then, under the unnamed words, never the room ID.
            let title = [invite.displayName, invite.inviterDisplayName]
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) ?? PeopleNameWords.room(nil, isDirect: invite.isDirect)
            rows.append(LiveProductRoom(
                id: invite.roomID,
                kind: invite.isDirect ? .people : .group,
                title: title,
                previewContent: .none,
                latestEventAt: invite.latestTimestamp.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
                matrixAvatarURL: invite.avatarURL,
                isInvitation: true,
                claimsConversationType: ConversationRoomType.isClaimed(invite.roomType)
            ))
        }
        // Mirror the desktop roster's default discovery rule. A bot row
        // reopens the bot's chat on this phone when it has one (hidden here,
        // or the bot's invitation). A bot with no chat is listed too when the
        // phone can start it (`AppStartPolicy.canStartChat`), and its row
        // runs that app's own disclosure flow; a bot the phone cannot start
        // has no row.
        // `m.favourite` on the chosen chat is an explicit person choice, so it
        // keeps that app's row across a server default change.
        let pinnedApps = Set(botChoices.compactMap { appID, choice -> AppCatalogID? in
            guard botAndAgentRooms.first(where: { $0.roomID == choice.roomID })?.isFavourite == true else {
                return nil
            }
            return appID
        })
        for entry in MobileAppRosterPolicy.entries(from: catalogApps,
                                                   excluding: consumedAppIDs,
                                                   pinned: pinnedApps,
                                                   shortcuts: input.appShortcuts) {
            let app = entry.app
            switch entry {
            case .comingSoon:
                // The one inert placeholder row. It names the app and uses the
                // existing localized "Coming soon" line; it has no destination
                // and no room, launch, consent or link operation.
                let title = app.name.localized(locale: input.locale, fallback: app.app)
                let detail = input.comingSoonDetail
                rows.append(LiveProductRoom(
                    id: "app:" + app.appID.rawValue,
                    kind: .agent,
                    title: title,
                    detail: detail,
                    previewContent: detail.map(RowPreview.Content.text) ?? .none,
                    avatar: productAvatar(for: app, locale: input.locale),
                    avatarSHA256: app.displayAvatarCandidates.first?.sha256,
                    avatarCandidates: remoteArt(for: app),
                    appAccent: app.accent,
                    // A presentation-only row makes no trust claim.
                    appVerification: nil,
                    canOpen: false,
                    isComingSoon: true
                ))
            case .shortcut:
                // A bot with a chat on this phone reopens it. One without a
                // chat is listed only when the phone can start it (a running,
                // published bot with a disclosure the phone reads): the row
                // opens that app's own flow, whatever the app is.
                guard app.bot != nil else { continue }
                let awaitsStart = botChoices[app.appID] == nil
                if awaitsStart, !AppStartPolicy.canStartChat(app) { continue }
                let backingRoom = botChoices[app.appID].flatMap { choice in
                    botAndAgentRooms.first(where: { $0.roomID == choice.roomID })
                }
                let title = app.name.localized(locale: input.locale, fallback: app.app)
                let roomPreview = backingRoom.map { actualRoomPreview(for: $0, isBotRoom: true) } ?? .none
                let preview = appPreview(roomPreview, app: app, locale: input.locale)
                rows.append(LiveProductRoom(
                    id: "app:" + app.appID.rawValue,
                    kind: .agent,
                    title: title,
                    detail: hasSemanticPreview(roomPreview)
                        ? backingRoom?.latestText
                        : appDescriptionOrSubtitle(app, locale: input.locale),
                    previewContent: preview,
                    latestEventAt: backingRoom?.latestTimestamp.map {
                        Date(timeIntervalSince1970: Double($0) / 1_000)
                    },
                    latestWasDeliveryNotice: backingRoom?.latestWasDeliveryNotice ?? false,
                    avatar: productAvatar(for: app, locale: input.locale),
                    matrixAvatarURL: memberAvatarFallback(
                        room: backingRoom,
                        avatar: productAvatar(for: app, locale: input.locale)
                    ),
                    avatarSHA256: app.displayAvatarCandidates.first?.sha256,
                    avatarCandidates: remoteArt(for: app),
                    appAccent: app.accent,
                    appVerification: productVerification(for: app),
                    isPinned: backingRoom?.isFavourite ?? false,
                    isMuted: backingRoom?.isMuted ?? false,
                    canOpen: true,
                    awaitsStart: awaitsStart
                ))
            }
        }
        return Output(rows: rows, agentChoices: listing.choices,
                      agentDuplicatePlainRoomCounts: listing.duplicatePlainRoomCounts)
    }

    static func catalogBotUserIDs(_ apps: [AppDescriptor]) -> Set<String> {
        Set(apps
            .filter { $0.effectiveRosterState == .available }
            .compactMap { $0.bot?.userID.rawValue })
    }

    static func botUserID(for room: LiveMatrixRoomRow, catalogBotUserIDs: Set<String>) -> String? {
        MobileAppBotRoomPolicy.botUserID(heroes: room.memberUserIDs,
                                         latestSenderID: room.latestSenderID,
                                         isDirect: room.isDirect,
                                         catalogBotUserIDs: catalogBotUserIDs)
    }

    /// Matrix milliseconds of the room's latest message; 0 when nobody has written.
    static func lastMessageAt(_ room: LiveMatrixRoomRow) -> UInt64 {
        room.latestText == nil ? 0 : room.latestTimestamp ?? 0
    }

    /// A bot chat is out of sight when it was deleted on this phone or on the
    /// desktop (`io.atum.app_bot.hidden`): in both cases only a newer message
    /// brings it back. Its app row stays, and opens the same room.
    static func isHidden(_ room: LiveMatrixRoomRow, by ledger: MobileHiddenRoomLedger) -> Bool {
        ledger.isHidden(roomID: room.roomID, latestTimestamp: room.latestTimestamp)
            || MobileAppBotRoomAccountData.isHidden(hiddenAt: room.appBotHiddenAt,
                                                    lastMessageAt: lastMessageAt(room))
    }

    /// The bot's one chat in desktop's order (`MobileAppBotRoomPolicy.chooseChat`,
    /// §4.2 item 2): the same rule lists the room and reopens it from the app
    /// row, so the phone and the Mac use the same room. Plain rooms only; a
    /// bot with no plain room has no row and nothing opens (§4.2 item 1).
    static func botChatChoice(forBot bot: String, appID: String, rooms: [LiveMatrixRoomRow],
                              invites: [LiveMatrixInvite], pointers: [String: String],
                              catalogBotUserIDs: Set<String>) -> MobileAppBotChatChoice? {
        var candidates = [MobileAppBotChatCandidate]()
        // The one place every bot-chat caller goes through: a conversation-type room or invitation is
        // never a bot's chat, whoever invited you to it.
        for room in rooms where botUserID(for: room, catalogBotUserIDs: catalogBotUserIDs) == bot
            && !ConversationTypeGuard.excludedFromBotAndAgent(roomType: room.roomType) {
            // A chat the desktop retired ("moved") is never the bot's chat.
            if let move = room.legacyAppBotMove, move.botUserID == bot, move.appID == appID { continue }
            candidates.append(MobileAppBotChatCandidate(
                roomID: room.roomID, membership: .joined, isOneToOneWithBot: true, invitedByBot: false,
                encrypted: room.isEncrypted, lastMessageAt: lastMessageAt(room),
                lastActiveAt: room.latestTimestamp ?? 0))
        }
        for invite in invites where invite.inviterID == bot
            && !ConversationTypeGuard.excludedFromBotAndAgent(roomType: invite.roomType) {
            candidates.append(MobileAppBotChatCandidate(
                roomID: invite.roomID, membership: .invited, isOneToOneWithBot: false, invitedByBot: true,
                encrypted: invite.isEncrypted, lastMessageAt: 0, lastActiveAt: 0))
        }
        return MobileAppBotRoomPolicy.chooseChat(pointerRoomID: pointers[appID], candidates: candidates)
    }

    static func agentRow(_ room: LiveMatrixRoomRow, title: String, avatar: LiveProductAvatar,
                         app: AppDescriptor?,
                         assistant: LiveProductAssistantMetadata? = nil,
                         isBotRoom: Bool,
                         locale: String = Locale.current.identifier) -> LiveProductRoom {
        let roomPreview = actualRoomPreview(for: room, isBotRoom: isBotRoom)
        let preview = app.map { appPreview(roomPreview, app: $0, locale: locale) }
            ?? roomPreview
        let detail = hasSemanticPreview(roomPreview)
            ? room.latestText
            : app.flatMap { appDescriptionOrSubtitle($0, locale: locale) }
                ?? room.latestText
        return LiveProductRoom(
            id: room.roomID,
            kind: .agent,
            title: title,
            detail: detail,
            previewContent: preview,
            latestEventAt: room.latestTimestamp.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
            latestSenderName: room.latestSenderName,
            latestIsOwn: room.latestIsOwn,
            latestSendState: room.latestSendState,
            latestWasDeliveryNotice: room.latestWasDeliveryNotice,
            avatar: avatar,
            matrixAvatarURL: memberAvatarFallback(room: room, avatar: avatar),
            avatarSHA256: app?.displayAvatarCandidates.first?.sha256,
            avatarCandidates: app.map { remoteArt(for: $0) } ?? [],
            appAccent: app?.accent,
            appVerification: app.flatMap { productVerification(for: $0) },
            assistant: assistant,
            unreadCount: Int(min(room.unreadCount, UInt64(Int.max))),
            notificationCount: Int(min(room.notificationCount, UInt64(Int.max))),
            highlightCount: Int(min(room.highlightCount, UInt64(Int.max))),
            isMarkedUnread: room.isMarkedUnread,
            isPinned: room.isFavourite,
            isMuted: room.isMuted,
            isAppBotRoom: isBotRoom,
            claimsConversationType: ConversationRoomType.isClaimed(room.roomType)
        )
    }

    /// App-authored metadata is a roster fallback only. Event content remains
    /// authoritative whenever it carries a semantic preview.
    static func appPreview(_ roomPreview: RowPreview.Content, app: AppDescriptor,
                           locale: String) -> RowPreview.Content {
        guard !hasSemanticPreview(roomPreview),
              let fallback = appDescriptionOrSubtitle(app, locale: locale) else {
            return roomPreview
        }
        return .text(fallback)
    }

    static func hasSemanticPreview(_ preview: RowPreview.Content) -> Bool {
        switch preview {
        case .none: false
        case let .text(text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: true
        }
    }

    static func actualRoomPreview(for room: LiveMatrixRoomRow,
                                  isBotRoom: Bool) -> RowPreview.Content {
        let preview = productPreview(for: room, isBotRoom: isBotRoom)
        guard !hasSemanticPreview(preview),
              let text = room.latestText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return preview }
        return .text(text)
    }

    static func appDescriptionOrSubtitle(_ app: AppDescriptor, locale: String) -> String? {
        for copy in [app.description, app.subtitle] {
            guard let value = copy?.localized(locale: locale)
                .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
            return value
        }
        return nil
    }

    static func productPreview(for room: LiveMatrixRoomRow, isBotRoom: Bool) -> RowPreview.Content {
        guard isBotRoom, room.latestIsNotice,
              case let .text(body) = room.latestPreviewContent else {
            return room.latestPreviewContent
        }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 2 else { return room.latestPreviewContent }
        return .appNotice([
            .init(localeIdentifier: "vi", text: lines[0]),
            .init(localeIdentifier: "en", text: lines[1]),
        ])
    }

    static func productVerification(for app: AppDescriptor) -> LiveProductAppVerification? {
        switch app.verification {
        case .official: .official
        case .verified: .verified
        case nil: nil
        }
    }

    static func monogram(for value: String) -> String {
        let words = value.split(whereSeparator: { $0.isWhitespace })
        let result = words.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return result.isEmpty ? "?" : result.uppercased()
    }

    /// A Matrix profile photo is the last face to try when the platform and
    /// the catalog expose none. It is never allowed to override a canonical
    /// assistant photo or app icon.
    static func memberAvatarFallback(room: LiveMatrixRoomRow?,
                                     avatar: LiveProductAvatar) -> String? {
        guard let room else { return nil }
        switch avatar {
        case .monogram: return room.avatarURL ?? room.heroAvatarURL
        case .photo, .eclipse, .mark, .symbol: return nil
        }
    }

    static func productAvatar(for agent: AgentsResponse.Agent) -> LiveProductAvatar {
        let fallback = agent.avatar.isEmpty ? monogram(for: agent.displayName) : agent.avatar
        if let rawURL = agent.avatarURL, let url = URL(string: rawURL) {
            return .photo(url: url, fallback: fallback)
        }
        if agent.isDefault { return .eclipse }
        return agent.mark.map(LiveProductAvatar.mark) ?? .monogram(fallback)
    }

    static func productAvatar(for app: AppDescriptor, locale: String) -> LiveProductAvatar {
        let displayName = app.name.localized(locale: locale, fallback: app.app)
        let fallback = monogram(for: displayName)
        guard let icon = app.displayAvatarCandidates.first else { return .monogram(fallback) }
        return .photo(url: icon.url, fallback: fallback)
    }

    static func remoteArt(for app: AppDescriptor) -> [LiveProductRemoteArt] {
        app.displayAvatarCandidates.map {
            LiveProductRemoteArt(url: $0.url, sha256: $0.sha256)
        }
    }
}
