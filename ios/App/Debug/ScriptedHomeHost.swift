#if DEBUG
import AtumChat
import AtumDesign
import AtumNativeAPI
import Foundation
import SwiftUI

/// Debug only (plan §2.10): `-AtumScripted <roster scenario>`
/// (`bot.moon-no-room`, `home.roster`) shows today's Home on a
/// `ScriptedRoster` instead of signing in. The rows come from the same pure
/// composition the live model uses (`LiveRosterRows`, with
/// `MobileAgentRoomPolicy`, `MobileAppBotRoomPolicy.chooseChat` and
/// `MobileAppRosterPolicy.entries`), so a UI test proves that "a bot
/// with no plain room that the phone cannot start has no row and nothing opens
/// the Store" (§4.2 item 1; a startable bot with no room now lists a row that
/// starts its flow, `AppStartRosterTests`), not a hard-coded list. Nothing opens from here: the rows' taps and the
/// tabs do nothing. Release builds compile none of this.
///
/// What the host adds to the scripted data, because the live contracts
/// require it: the account's default agent Atum (`/agents` always has one),
/// the catalog descriptors for the scripted apps (`/apps`), and the catalog
/// bots' Matrix IDs on the server name the bot contract requires
/// (`@app-<name>:atumplatform.com`). A bot's ID is mapped wherever it
/// appears (members, senders, inviters), so the policies see the same
/// relations as in the scenario; every other ID stays on `.test`.
struct ScriptedHomeHost: View {
    let roster: ScriptedRoster

    @State private var router = Router()
    @State private var rows: [LiveProductRoom]
    @State private var scriptedCompany = "anka"
    @State private var scriptedMuted = [String: Bool]()
    @State private var scriptedLater = Set<String>()
    @State private var scriptedBlocked = Set<String>()
    /// Rooms the scripted account has left since launch (Home search's
    /// eligibility drops their results).
    @State private var scriptedLeftRooms = Set<String>()
    @Environment(\.colorScheme) private var scheme
    private let design: LiveDesign

    init(roster: ScriptedRoster) {
        self.roster = roster
        design = try! LiveDesign()
        let productRows = Self.rows(roster, locale: Self.locale)
        // Screenshot-only focus for reviewing avatar rows: keep the
        // assistants and the catalog app bots (Moon, Andy) without scrolling
        // the full home.roster fixture. Release compiles none of this host.
        if ProcessInfo.processInfo.arguments.contains("-AtumDebugAvatars") {
            _rows = State(initialValue: productRows.filter {
                $0.assistant != nil || $0.isAppBotRoom || $0.id.hasPrefix("app:")
            })
        } else {
            _rows = State(initialValue: productRows)
        }
    }

    var body: some View {
        ZStack {
            design.color("ground", scheme: scheme).ignoresSafeArea()
            RootTabs(router: router, design: design,
                     availability: PhoneTabAvailability(teamSpace: true),
                     badges: PhoneTabBadges(teamSpace: scriptedTabBadge)) {
                HomeScreen(
                    design: design,
                    router: router,
                    accountName: Self.accountName,
                    presentation: HomePresentation(state: rows.isEmpty ? .empty : .ready,
                                                   rows: Self.workingRows(Self.testHomeRows(roster, productRows: rows))),
                    actions: personalMenu(HomeActions(
                        openRoom: { router.open(roomId: $0) },
                        joinInvitation: { roomID in
                            try? await Task.sleep(for: .seconds(1))
                            router.open(roomId: roomID)
                            return true
                        },
                        refresh: {},
                        setUnread: { roomID, value in
                            update(roomID) { $0.withRosterState(unreadOverride: value) }
                            UITestProbe.append("unread \(roomID) \(value)", to: "home-actions.txt")
                        },
                        setPinned: { roomID, value in
                            update(roomID) { $0.withRosterState(pinnedOverride: value) }
                            rows.sort { left, right in
                                left.isPinned != right.isPinned ? left.isPinned : false
                            }
                            UITestProbe.append("pinned \(roomID) \(value)", to: "home-actions.txt")
                        },
                        setMuted: { roomID, value in
                            update(roomID) { $0.withRosterState(mutedOverride: value) }
                            UITestProbe.append("muted \(roomID) \(value)", to: "home-actions.txt")
                        },
                        deleteAppRoom: { roomID in
                            deleteAppRoom(roomID)
                            UITestProbe.append("hidden \(roomID)", to: "home-actions.txt")
                        },
                        declineInvitation: { roomID in
                            rows.removeAll { $0.id == roomID }
                            UITestProbe.append("declined \(roomID)", to: "home-actions.txt")
                        },
                        addFriend: { handle in
                            UITestProbe.append("addFriend \(handle)", to: "home-actions.txt")
                            return .notFound(handle)
                        },
                        peopleDiscovery: scriptedPeopleDiscovery,
                        newGroup: HomeGroupActions(
                            candidates: [
                                HomeGroupCandidate(id: "@lan:atum.test", name: "Lan", kind: .person),
                                // The phone has no shared-agent group consent/capability
                                // contract. The real group UI must keep this ineligible.
                                HomeGroupCandidate(id: "@alfred:atum.test", name: "Alfred", kind: .assistant),
                            ],
                            lookup: { handle in
                                .candidate(HomeGroupCandidate(id: "@\(handle):atum.test",
                                                              name: "@\(handle)", kind: .person))
                            },
                            create: { name, members in
                                UITestProbe.append("newGroup \(name) \(members.count)",
                                                   to: "home-actions.txt")
                                return .openRoom("!gia-dinh:atum.test")
                            },
                            handles: ScriptedHandles.lookup
                        ),
                        newAssistant: HomeAssistantActions(
                            pending: false,
                            create: { name in
                                UITestProbe.append("newAssistant \(name)", to: "home-actions.txt")
                                return .starting
                            },
                            // AS-3: a second "Alfred" is refused before
                            // anything is created; handles with "taken" are taken.
                            names: ["Atum", "Alfred"],
                            checkHandle: { handle in
                                let taken = handle.rawValue.contains("taken")
                                return AgentAliasCheck(handle: handle, available: !taken,
                                                       code: taken ? .unavailable : nil)
                            }
                        ),
                        exitRoom: { roomID, action in
                            rows.removeAll { $0.id == roomID }
                            UITestProbe.append("\(action.rawValue) \(roomID)", to: "home-actions.txt")
                        },
                        appInfo: { rowID in
                            // The scripted catalog's app by the row's name: the same
                            // descriptor the rows were composed from.
                            guard let row = rows.first(where: { $0.id == rowID }),
                                  row.isAppBotRoom || rowID.hasPrefix("app:"),
                                  let app = Self.catalog(roster.apps).first(where: {
                                      $0.name.localized(locale: Self.locale) == row.title
                                  }) else { return nil }
                            UITestProbe.append("appInfo \(rowID)", to: "home-actions.txt")
                            return AppCardPresentation(app: app, rowID: rowID, locale: Self.locale,
                                                       avatar: row.avatar,
                                                       matrixAvatarURI: row.matrixAvatarURL,
                                                       avatarSHA256: row.avatarSHA256,
                                                       avatarCandidates: row.avatarCandidates)
                        }
                    ))
                )
                .navigationDestination(for: String.self) { roomID in
                    ZStack {
                        design.color("ground", scheme: scheme).ignoresSafeArea()
                        Text(verbatim: rows.first(where: { $0.id == roomID })?.title ?? "")
                            .font(.headline)
                    }
                    .accessibilityIdentifier("home.scripted.destination")
                    .toolbar(.hidden, for: .tabBar)
                }
            } drive: {
                PhoneComingSoonView(design: design, tab: .drive)
            } store: {
                StoreScreen(design: design, store: scriptedStore,
                            onRefresh: {}, onOpenRoom: { router.open(roomId: $0) })
            } teamSpace: {
                TeamSpaceScreen(
                    design: design,
                    presentation: scriptedTeamSpace,
                    actions: TeamSpaceActions(
                        refresh: {},
                        selectCompany: { scriptedCompany = $0 },
                        openRoom: { router.openTeamSpace(roomId: $0) },
                        acceptInvitation: { _ in false },
                        declineInvitation: { scriptedLater.insert($0) },
                        leave: { _ in },
                        setMuted: { roomID, muted in
                            UITestProbe.append("mute \(roomID) \(muted)", to: "team-actions.txt")
                            scriptedMuted[String(roomID.dropFirst().prefix { $0 != ":" })] = muted
                        },
                        createCompany: { name in
                            UITestProbe.append("create \(name)", to: "team-actions.txt")
                            // A name that spells the refusal shows the platform's closed answer.
                            if name == "closed" { return .closed }
                            scriptedCompany = "studio"
                            return nil
                        },
                        loadMatrixThumbnail: { uri, _ in
                            uri == Self.scriptedLogoURI
                                ? try? AtumDesign.data(for: "app-icon/atum-app-icon-1024.png") : nil
                        },
                        invites: scriptedInvites
                    )
                )
                .navigationDestination(for: String.self) { roomID in
                    ZStack {
                        design.color("ground", scheme: scheme).ignoresSafeArea()
                        Text(verbatim: roomID).font(.headline)
                    }
                    .accessibilityIdentifier("teamSpace.scripted.destination")
                }
            } account: {
                AccountScreen(
                    design: design,
                    presentation: AccountPresentation(
                        matrixUserID: ScriptedCast.me,
                        displayName: nil,
                        offersHistoryRecovery: false,
                        holdsRecoveryKey: false,
                        recoveryKeySavedOnThisPhone: false,
                        signOutInProgress: false,
                        signOutFailureToken: 0,
                        version: ""
                    ),
                    actions: AccountActions(
                        readNotificationState: { .off },
                        requestNotifications: { .off },
                        openNotificationSettings: {},
                        openAppSettings: {},
                        loadRecoveryKey: { .unavailable },
                        markRecoveryKeySaved: {},
                        restoreMessages: { _ in .failed },
                        signOut: { _ in false },
                        openWebPage: { _ in }
                    ),
                    store: scriptedStore,
                    openStoreRoom: { roomID in
                        router.dismissAccount()
                        router.open(roomId: roomID)
                    }
                )
            }
        }
        .foregroundStyle(design.color("ink", scheme: scheme))
        .tint(design.color("ink", scheme: scheme))
        .focusEffectDisabled()
        .task { applyDebugSurface() }
    }

    /// Screenshot-only preselection for the scripted host. It never ships in
    /// Release and only chooses a destination the same Router actions reach.
    private func applyDebugSurface() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-AtumDebugAccount") {
            router.presentAccount()
        } else if arguments.contains("-AtumDebugDrive") {
            router.select(tab: .drive)
        } else if arguments.contains("-AtumDebugStore") {
            router.select(tab: .store)
        } else if arguments.contains("-AtumDebugTeamSpace") {
            router.select(tab: .teamSpace)
        }
    }

    private static let accountName = "Bạn"

    private struct ScriptedChannel {
        let id: String
        let title: String
        let isDefault: Bool
        let input: Badge.Input
        var isFavourite = false
        var isArchived = false
    }

    private static let scriptedChannels: [String: [ScriptedChannel]] = [
        "anka": [
            ScriptedChannel(id: "general", title: "general", isDefault: true,
                            input: Badge.Input(highlights: 2, notifications: 4, hasUnreadActivity: true)),
            ScriptedChannel(id: "random", title: "random", isDefault: false,
                            input: Badge.Input(notifications: 3, hasUnreadActivity: true)),
            ScriptedChannel(id: "ops", title: "ops", isDefault: false,
                            input: Badge.Input(notifications: 5, hasUnreadActivity: true, isMuted: true)),
            ScriptedChannel(id: "design", title: "design", isDefault: false, input: Badge.Input()),
            // Wave 3 TS-13: a favourite and an archived channel for the section captures.
            ScriptedChannel(id: "launch", title: "launch", isDefault: false, input: Badge.Input(),
                            isFavourite: true),
            ScriptedChannel(id: "retro-2025", title: "retro-2025", isDefault: false, input: Badge.Input(),
                            isArchived: true),
        ],
        "studio": [
            ScriptedChannel(id: "studio-general", title: "general", isDefault: true,
                            input: Badge.Input(notifications: 1, hasUnreadActivity: true)),
        ],
    ]

    private func scriptedInput(_ channel: ScriptedChannel) -> Badge.Input {
        var input = channel.input
        input.isMuted = scriptedMuted[channel.id] ?? channel.input.isMuted
        return input
    }

    private var scriptedTabBadge: Badge {
        return TeamSpaceBadges.tab(
            companies: Self.scriptedChannels.keys.sorted().map { company in
                TeamSpaceBadges.company(channels: (Self.scriptedChannels[company] ?? []).map(scriptedInput))
            },
            pendingInvitations: scriptedLater.contains("invite-labs") ? 0 : 1)
    }

    private var scriptedTeamSpace: TeamSpacePresentation {
        let channels = (Self.scriptedChannels[scriptedCompany] ?? []).map { channel -> CompanyChannelRow in
            let input = scriptedInput(channel)
            return CompanyChannelRow(id: channel.id, title: channel.title, state: "Ready",
                                     roomID: "!" + channel.id + ":atum.test", memberCount: 3,
                                     canOpen: true, badge: Badge.mark(for: input), isMuted: input.isMuted,
                                     isFavourite: channel.isFavourite, isArchived: channel.isArchived)
        }
        let entries = ["anka": "Anka", "studio": "Studio"].sorted { $0.key < $1.key }.map { key, title in
            CompanySwitcherEntry(
                id: key, title: title,
                badge: TeamSpaceBadges.company(channels: (Self.scriptedChannels[key] ?? []).map(scriptedInput)),
                isActive: key == scriptedCompany)
        }
        return TeamSpacePresentation(
            isLoading: false,
            isUnavailable: false,
            invitations: scriptedLater.contains("invite-labs") ? [] : [
                CompanyHomeRow(id: "invitation:labs", companyID: "labs", invitationID: "invite-labs",
                               title: "Labs", subtitle: nil),
            ],
            workspace: CompanyWorkspacePresentation(
                id: scriptedCompany, title: scriptedCompany == "anka" ? "Anka" : "Studio",
                channels: channels, members: [], channelsLoading: false, membersLoading: false,
                leavePending: false, notice: nil, error: nil),
            switcher: entries,
            canCreate: true,
            // Studio has a logo (served by the scripted media below); Anka has
            // none and shows the Kit monogram.
            logos: ["studio": Self.scriptedLogoURI],
            menu: CompanyMenuAllowed(overview: true, invite: true, create: true, leave: true),
            inviteAbilities: CompanyInviteAbilities(invite: true, method: .admin, inviteLink: true,
                                                    revokeInviteLink: true),
            canCreateChannel: true,
            // The section captures show the desktop's C2 channels mode.
            sectionsChannels: true)
    }

    /// TS-11/TS-13 with synthetic answers (the desktop public pack's fixture shapes): "@nobody"
    /// is refused, "@minh" is already in, "@lan" already invited; every press is probed.
    private var scriptedInvites: CompanyInviteActions {
        func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
            try? NativeAPI.decode(type, from: Data(json.utf8))
        }
        let link = #"{"id":"00000000-0000-4000-8000-507f79cf6e24","role":"member","state":"active","#
            + #""createdAt":1792540800,"expiresAt":4102444800,"maxUses":5,"uses":2}"#
        let preview = #"{"schemaVersion":3,"company":{"id":"00000000-0000-4000-8000-68ce1b921bf1","#
            + #""displayName":"Labs"},"role":"member","inviter":{"handle":"minh","displayName":"Minh"},"#
            + #""expiresAt":4102444800,"maxUses":5,"usesRemaining":3}"#
        return CompanyInviteActions(
            standing: { _, handle in handle == "minh" ? .member : handle == "lan" ? .invited : .none },
            invite: { _, handle in
                UITestProbe.append("invite \(handle)", to: "team-actions.txt")
                return handle == "nobody" ? .refused(.missing, reason: "invite_target_unavailable") : .invited
            },
            loadLinks: { _ in decode(CompanyInviteLinkSummary.self, link).map { [$0] } ?? [] },
            createLink: { _ in
                UITestProbe.append("invite-link create", to: "team-actions.txt")
                let created = #"{"schemaVersion":3,"replayed":false,"link":{"id":"00000000-0000-4000-8000-7d72ef2bd9bc","#
                    + #""companyId":"00000000-0000-4000-8000-68ce1b921bf1","role":"member","state":"active","#
                    + #""createdAt":1792540800,"expiresAt":1793145600,"maxUses":5,"uses":0,"#
                    + #""url":"https://atum.app/j/PUBLIC_FIXTURE_ONLY_61818fe4de417671d243876c2279bbbe"}}"#
                guard case let .created(secret)? = try? CompanyInviteWire.decodeLinkCreated(Data(created.utf8)) else {
                    return .failed(nil)
                }
                return .created(secret)
            },
            revokeLink: { _, _ in
                UITestProbe.append("invite-link revoke", to: "team-actions.txt")
                return nil
            },
            preview: { _ in
                guard let value = decode(CompanyInviteLinkPreview.self, preview) else {
                    return CompanyInviteJoinState.failure(.unavailable, preview: nil)
                }
                return CompanyInviteJoinState.preview(value)
            },
            redeem: { _, _, value in
                UITestProbe.append("invite-link redeem", to: "team-actions.txt")
                return .complete(value, .joined, companyID: value.companyId.rawValue)
            },
            createChannel: { _, name in
                UITestProbe.append("create-channel \(name)", to: "team-actions.txt")
                return .created(roomID: nil)
            })
    }

    static let scriptedLogoURI = "mxc://atum.test/studio-logo"

    private var scriptedStore: LiveProductStoreRead {
        LiveProductStoreRead(
            availability: .ready,
            walletMicroProtons: 12_400_000_000,
            items: [LiveProductStoreItem(
                id: "featured", kind: .skill,
                title: design.text("desktop.atum.discover.featuredSection"),
                summary: design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeBody"),
                glyph: "◉", featured: true, price: "24"
            )]
        )
    }

    /// HC-7: the long-press's Low priority, Rename and Block, recorded in
    /// `home-actions.txt`. A person row's peer is a fixed scripted ID.
    /// Home search's People section on a scripted directory: a new person
    /// found by @handle or name, Lan (already a chat, so never listed again)
    /// and an assistant (never a person). Opening someone makes a chat.
    private static let scriptedDirectory = [
        HomeGroupCandidate(id: "@somehandle:atum.test", name: "Thảo Nguyên", kind: .person,
                           handle: "somehandle"),
        HomeGroupCandidate(id: "@lan:atum.test", name: "Lan", kind: .person, handle: "lan"),
        HomeGroupCandidate(id: "@some-assistant:atum.test", name: "Some assistant", kind: .assistant),
        // Found by "launch" with the scripted channels and company answers,
        // so one query shows all four global sections.
        HomeGroupCandidate(id: "@launchlead:atum.test", name: "Mai Phương", kind: .person,
                           handle: "launchlead"),
    ]

    private var scriptedPeopleDiscovery: HomePeopleDiscoveryActions {
        HomePeopleDiscoveryActions(
            search: { query in
                UITestProbe.append("peopleSearch \(query)", to: "home-actions.txt")
                let needle = String(query.lowercased().drop { $0 == "@" })
                return Self.scriptedDirectory.filter {
                    $0.name.lowercased().contains(needle) || ($0.handle ?? "").contains(needle)
                }
            },
            open: { userID in
                UITestProbe.append("openPerson \(userID)", to: "home-actions.txt")
                return .openRoom("!new-chat:atum.test")
            },
            loadMatrixThumbnail: nil,
            directRoom: { userID in
                roster.rooms.first { $0.isDirect && $0.members == [userID] }?.roomID
            },
            handles: ScriptedHandles.lookup
        )
    }

    /// Home search's Channels, Messages and Files: two Team Space rooms named
    /// "launch…", and company answers whose words or file names hold the
    /// query. Every ask and open is written to `home-actions.txt`.
    static let scriptedSearchChannels = [
        HomeSearchChannel(roomID: "!launch:atum.test", name: "launch"),
        HomeSearchChannel(roomID: "!general:atum.test", name: "general"),
        HomeSearchChannel(roomID: "!launch-vn:atum.test", name: "Launch Việt Nam"),
        // "kickoff" finds a channel, a message and a file but nobody in the
        // scripted directory: the audit's query without the People row.
        HomeSearchChannel(roomID: "!kickoff:atum.test", name: "Kickoff Q4"),
    ]

    static let scriptedCompanyResults: [CompanySearchTab: [CompanySearchResult]] = [
        .messages: [
            CompanySearchResult(companyID: "11111111-1111-4111-8111-111111111111",
                                channelID: "22222222-2222-4222-8222-222222222222",
                                roomID: "!general:atum.test", channelName: "general",
                                eventID: "$launch-review", sender: "@minh:atum.test",
                                snippet: "Can we move the launch review to Thursday? The deck needs one more pass.",
                                at: 1_762_000_000_000),
            CompanySearchResult(companyID: "11111111-1111-4111-8111-111111111111",
                                channelID: "33333333-3333-4333-8333-333333333333",
                                roomID: "!launch-vn:atum.test", channelName: "Launch Việt Nam",
                                eventID: "$launch-draft", sender: "@thao:atum.test",
                                snippet: "Bản nháp launch đã sẵn sàng.", at: 1_761_900_000_000,
                                threadRootID: "$launch-thread"),
            CompanySearchResult(companyID: "11111111-1111-4111-8111-111111111111",
                                channelID: "22222222-2222-4222-8222-222222222222",
                                roomID: "!general:atum.test", channelName: "general",
                                eventID: "$kickoff-notes", sender: "@minh:atum.test",
                                snippet: "Kickoff notes are pinned in the channel.", at: 1_761_700_000_000),
        ],
        .files: [
            CompanySearchResult(companyID: "11111111-1111-4111-8111-111111111111",
                                channelID: "44444444-4444-4444-8444-444444444444",
                                roomID: "!launch:atum.test", channelName: "launch",
                                eventID: "$launch-deck", sender: "@minh:atum.test",
                                snippet: "launch-deck.pdf", at: 1_761_800_000_000,
                                file: CompanySearchResult.File(name: "launch-deck.pdf", mimeType: "application/pdf",
                                                               size: 1_200_000, type: .pdfs)),
            CompanySearchResult(companyID: "11111111-1111-4111-8111-111111111111",
                                channelID: "55555555-5555-4555-8555-555555555555",
                                roomID: "!kickoff:atum.test", channelName: "Kickoff Q4",
                                eventID: "$kickoff-agenda", sender: "@thao:atum.test",
                                snippet: "kickoff-agenda.pdf", at: 1_761_600_000_000,
                                file: CompanySearchResult.File(name: "kickoff-agenda.pdf", mimeType: "application/pdf",
                                                               size: 300_000, type: .pdfs)),
        ],
    ]

    private var scriptedGlobalSearch: HomeGlobalSearchActions {
        HomeGlobalSearchActions(
            channels: Self.scriptedSearchChannels,
            companyIDs: ["11111111-1111-4111-8111-111111111111"],
            // Every scripted result's room is joined, unencrypted and listed.
            eligibility: CompanySearchEligibility(bindings: [
                "11111111-1111-4111-8111-111111111111": Dictionary(
                    Self.scriptedCompanyResults.values.flatMap { $0 }
                        .filter { !scriptedLeftRooms.contains($0.roomID) }
                        .map { ($0.roomID, $0.channelID) },
                    uniquingKeysWith: { first, _ in first }),
            ]),
            search: { term, tab in
                UITestProbe.append("companySearch \(tab.rawValue) \(term)", to: "home-actions.txt")
                // `-AtumScriptedLeaveAfterSearch <roomID>`: that room is left
                // two seconds after the answer lands, with the answer on screen.
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "-AtumScriptedLeaveAfterSearch"),
                   arguments.indices.contains(index + 1) {
                    let room = arguments[index + 1]
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        scriptedLeftRooms.insert(room)
                        UITestProbe.append("left \(room)", to: "home-actions.txt")
                    }
                }
                let needle = HomeGlobalSearchPolicy.normalize(term)
                return (Self.scriptedCompanyResults[tab] ?? []).filter {
                    HomeGlobalSearchPolicy.normalize($0.text).contains(needle)
                }
            },
            open: { result in
                UITestProbe.append("openResult \(result.eventID)", to: "home-actions.txt")
                // "$launch-draft" stands for a room the phone can no longer
                // open (left, or the router refused): Home says so.
                guard result.eventID != "$launch-draft" else { return false }
                router.open(roomId: result.roomID)
                return true
            })
    }

    private func personalMenu(_ base: HomeActions) -> HomeActions {
        var actions = base
        actions.globalSearch = scriptedGlobalSearch
        actions.handles = ScriptedHandles.lookup
        actions.setLowPriority = { roomID, value in
            update(roomID) { $0.withRosterState(lowPriorityOverride: value) }
            UITestProbe.append("lowPriority \(roomID) \(value)", to: "home-actions.txt")
        }
        actions.rename = ChatRenameActions(
            request: { roomID in
                guard let room = rows.first(where: { $0.id == roomID }) else { return nil }
                return ChatRenameRequest(roomID: roomID, current: room.title, shared: false)
            },
            save: { request, name in
                UITestProbe.append("rename \(request.roomID) \(ChatPrivateTitle.normalized(name))",
                                   to: "home-actions.txt")
                return true
            })
        actions.blockablePeer = { roomID in
            rows.first(where: { $0.id == roomID && $0.kind == .people }) == nil ? nil : "@peer:" + roomID
        }
        actions.blockedUserIDs = { scriptedBlocked }
        actions.setBlocked = { userID, blocked in
            if blocked { scriptedBlocked.insert(userID) } else { scriptedBlocked.remove(userID) }
            UITestProbe.append("blocked \(userID) \(blocked)", to: "home-actions.txt")
            return true
        }
        return actions
    }

    private func update(_ roomID: String, transform: (LiveProductRoom) -> LiveProductRoom) {
        guard let index = rows.firstIndex(where: { $0.id == roomID }) else { return }
        rows[index] = transform(rows[index])
    }

    private func deleteAppRoom(_ roomID: String) {
        guard let index = rows.firstIndex(where: { $0.id == roomID }),
              rows[index].isAppBotRoom,
              let app = roster.apps.first(where: { $0.name == rows[index].title }) else { return }
        let removed = rows.remove(at: index)
        rows.append(LiveProductRoom(
            id: "app:" + app.appID, kind: .agent, title: app.name,
            detail: nil, avatar: .monogram(LiveRosterRows.monogram(for: app.name)),
            appAccent: removed.appAccent, appVerification: removed.appVerification,
            canOpen: true, isAppBotRoom: true
        ))
    }

    /// HC-3 captures: `-AtumDebugWorking` shows the first assistant at work,
    /// as a typing agent does live (`HomeAssistantActivity`).
    static func workingRows(_ rows: [HomeRow]) -> [HomeRow] {
        guard ProcessInfo.processInfo.arguments.contains("-AtumDebugWorking"),
              let first = rows.first(where: \.kind.isAssistant) else { return rows }
        return HomeRow.applyingLive(rows, workingRoomIDs: [first.roomID], memberCounts: [:])
    }

    static func homeRows(_ roster: ScriptedRoster, productRows: [LiveProductRoom]) -> [HomeRow] {
        let rows = productRows.map { HomeRow(product: $0, locale: Locale(identifier: locale)) }
        // The live path's one-to-one partners and their verified handles.
        let partners = roster.rooms.reduce(into: [String: String]()) {
            if $1.isDirect, $1.members.count == 1 { $0[$1.roomID] = $1.members[0] }
        }
        return HomeRow.applyingLive(rows, workingRoomIDs: [], memberCounts: [:], partners: partners,
                                    handle: { ScriptedHandles.byUser[$0] })
    }

    /// A bounded synthetic tail lets the shell UI test measure the actual last
    /// List row against the existing tab button frames at compact and large
    /// text sizes. This never changes release data or live roster ownership.
    static func testHomeRows(_ roster: ScriptedRoster, productRows: [LiveProductRoom]) -> [HomeRow] {
        let rows = homeRows(roster, productRows: productRows)
        guard ProcessInfo.processInfo.arguments.contains("-AtumDebugLongRoster") else {
            return rows
        }
        let tail = (0..<20).map { index in
            HomeRow(id: "test.roster.tail.\(index)", kind: .person,
                    name: index == 19 ? "Roster final row" : "Roster row \(index + 1)",
                    canOpen: false)
        }
        return rows + tail
    }

    private static func scriptedName(_ userID: String) -> String? {
        userID == ScriptedCast.me ? nil : ScriptedCast.names[userID]
    }

    /// `LiveAppModel.currentLocale`: catalog names in the device's language.
    private static var locale: String {
        let identifier = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        return identifier.split(separator: "-", maxSplits: 1).first.map(String.init) ?? identifier
    }

    static func rows(_ roster: ScriptedRoster, locale: String) -> [LiveProductRoom] {
        let bots = Set(roster.apps.map(\.botUserID))
        let serverID = { (id: String) in bots.contains(id) ? botID(id) : id }
        var rooms = [LiveMatrixRoomRow]()
        var invites = [LiveMatrixInvite]()
        for room in roster.rooms {
            switch room.membership {
            case .joined:
                let members = room.members.map(serverID)
                let sender = room.latestSenderID.map(serverID)
                rooms.append(LiveMatrixRoomRow(
                    roomID: room.roomID,
                    displayName: room.name,
                    avatarURL: nil,
                    latestText: room.latestBody.isEmpty ? nil : room.latestBody,
                    latestPreviewContent: room.latestPreviewContent
                        ?? (room.latestBody.isEmpty ? .none : .text(room.latestBody)),
                    latestSenderID: sender,
                    latestSenderName: room.latestSenderID.flatMap(scriptedName),
                    latestIsOwn: sender == ScriptedCast.me,
                    latestIsNotice: isAppNotice(room.latestPreviewContent),
                    latestSendState: room.latestSendState,
                    latestTimestamp: room.latestTimestamp.map { UInt64(max(0, $0.timeIntervalSince1970 * 1000)) },
                    unreadCount: UInt64(max(0, room.unreadCount)),
                    notificationCount: UInt64(max(0, room.unreadCount)),
                    highlightCount: UInt64(max(0, room.mentionCount)),
                    isMarkedUnread: room.isMarkedUnread,
                    isFavourite: room.isFavourite,
                    isMuted: room.isMuted,
                    isDirect: room.isDirect,
                    memberUserIDs: members,
                    memberCount: UInt64(members.count + 1),
                    roomType: nil,
                    isEncrypted: room.encrypted
                ))
            case let .invited(by: inviter):
                invites.append(LiveMatrixInvite(roomID: room.roomID, inviterID: serverID(inviter),
                                                displayName: room.name,
                                                inviterDisplayName: scriptedName(inviter),
                                                latestTimestamp: room.latestTimestamp.map {
                                                    UInt64(max(0, $0.timeIntervalSince1970 * 1_000))
                                                },
                                                isEncrypted: room.encrypted,
                                                roomType: nil))
            }
        }
        var hiddenRooms = MobileHiddenRoomLedger()
        let hiddenAt = roster.hiddenAt.map { UInt64(max(0, $0.timeIntervalSince1970 * 1_000)) }
        for roomID in roster.hiddenRoomIDs {
            let latest = rooms.first { $0.roomID == roomID }?.latestTimestamp
            hiddenRooms.hide(roomID: roomID, latestTimestamp: latest, nowMillis: hiddenAt ?? latest ?? 0)
        }
        let copy = try? AtumCopy()
        let waitingDetail = copy.flatMap { catalog in
            try? catalog.text(LiveRosterRows.waitingCopyKey,
                              locale: catalog.locales.contains(locale) ? locale : "en")
        }
        let apps = catalog(roster.apps)
        let input = LiveRosterRows.Input(agents: defaultAgents(), apps: apps, rooms: rooms,
                                         invites: invites, pointers: roster.pointers,
                                         hiddenRooms: hiddenRooms,
                                         // Scripted fixtures have no account data; this is
                                         // the successful no-event state, not a guess.
                                         appShortcuts: Dictionary(uniqueKeysWithValues: apps.map {
                                             ($0.appID, MobileAppShortcutState.absent)
                                         }),
                                         locale: locale,
                                         waitingDetail: waitingDetail)
        return LiveRosterRows.rows(input).rows
    }

    /// A scripted catalog bot's ID on the server name the bot contract
    /// requires.
    static func botID(_ id: String) -> String {
        id.hasSuffix(":atum.test") ? String(id.dropLast(":atum.test".count)) + ":atumplatform.com" : id
    }

    private static func isAppNotice(_ content: RowPreview.Content?) -> Bool {
        if case .appNotice? = content { return true }
        return false
    }

    /// The account's default agent: Atum, on `ScriptedCast.atum`.
    private static func defaultAgents() -> [AgentsResponse.Agent] {
        let definitions = [
            ("00000000-0000-4000-8000-89c0dd5b3309", "Atum", ScriptedCast.atum, true),
            ("00000000-0000-4000-8000-b71039fe0b83", "Luna", ScriptedCast.luna, false),
            ("00000000-0000-4000-8000-19ef26fcbb3a", "Nhà phân tích", ScriptedCast.analyst, false),
        ]
        let agents: [[String: Any]] = definitions.map { id, name, matrixUser, isDefault in
            [
                "id": id, "identity_id": NSNull(), "display_name": name,
                "slug": NSNull(), "avatar": "", "avatar_url": NSNull(),
                "is_default": isDefault, "lifecycle_revision": 1,
                "identity_revision": 0, "definition_revision": 0,
                "status": "active", "principal": id, "matrixUser": matrixUser,
            ]
        }
        return decode(AgentsResponse.self, agents).agents
    }

    /// `/apps` descriptors for the scripted catalog: active bots with a
    /// device, shown by default, icons on a host that never resolves.
    private static func catalog(_ apps: [ScriptedRosterApp]) -> [AppDescriptor] {
        let entries: [[String: Any]] = apps.enumerated().map { index, app in
            let slug = app.name.lowercased()
            let icon: [String: Any] = ["url": "https://scripted.atum.test/\(slug).png",
                                       "sha256": String(repeating: "a", count: 64)]
            return [
                "app": slug,
                "app_id": app.appID,
                "app_version_id": "00000000-0000-4000-8000-00000000b00\(index)",
                "name": ["vi": app.name, "en": app.name],
                "subtitle": NSNull(),
                "description": NSNull(),
                "icon": icon,
                "accent": app.appID == ScriptedCast.moonAppID ? "#2c8078" : "#b4690e",
                "affiliation": "first_party",
                "verified": true,
                "verification": "official",
                "availability": "available",
                "roster_default": true,
                "roster_order": index,
                "supported_modes": ["direct"],
                "matrix_room_context": "addressed_only",
                "has_surface": true,
                "link": ["mode": "none", "state": "never_linked"],
                "bot": [
                    "v": 1,
                    "user_id": botID(app.botUserID),
                    "handle": "\(slug)_bot",
                    "display_name": app.name,
                    "avatar": icon,
                    "device_generation": 1,
                    "device": ["device_id": "\(app.name.uppercased()).1",
                               "ed25519": String(repeating: "A", count: 43),
                               "curve25519": String(repeating: "B", count: 43)],
                    "state": "active",
                    "groups": true,
                    "consent": "accepted",
                    "disclosure_version": 1,
                    "open_route_id": "open",
                    "open_shared_memory": false,
                    "purchase_route_id": "purchase",
                ] as [String: Any],
            ]
        }
        return decode(AppCatalogResponse.self, ["profile": AppCatalogResponse.profile, "apps": entries]).apps
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: Any) -> T {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try NativeAPI.decode(type, from: data)
        } catch {
            preconditionFailure("scripted roster: \(T.self) does not decode: \(error)")
        }
    }
}

/// The scripted directory's verified handles for the cast (Debug only), so the
/// Home roster, Start chat, the pickers and chat info show the same @handle
/// lines the live cache fills in. Every visible-row request is written to
/// `handle-requests.txt` for UI tests.
enum ScriptedHandles {
    static let byUser: [String: String] = [
        "@lan:atum.test": "lannguyen",
        ScriptedCast.hoa: "hoatran",
        ScriptedCast.tuan: "tuanle",
        ScriptedCast.minh: "minhpham",
        ScriptedCast.huy: "huydo",
        ScriptedCast.anhKhoa: "anhkhoa",
        ScriptedCast.chiMai: "chimai",
    ]

    static var lookup: PersonHandleLookup {
        PersonHandleLookup(
            handle: { byUser[$0] },
            request: { UITestProbe.append("request \($0.sorted().joined(separator: ","))", to: "handle-requests.txt") }
        )
    }
}
#endif
