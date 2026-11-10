import SwiftUI
import UIKit
import UserNotifications
import AtumChat
import AtumNativeAPI

private struct RoomClassificationInput: Hashable {
    let roomIDs: [String]
    /// Rooms whose create event claims the company conversation type.
    let typeClaims: [String]
    let revision: UInt64
}

enum RoomRootDestination: Equatable {
    case personal
    case teamSpace

    static func authoritative(roomKind: LiveProductRoomKind,
                              classification: CompanyRoomClassification)
        -> RoomRootDestination? {
        // A company DM can look like a person's chat (two people), so the
        // platform's conversation directory decides before the kind does, and a
        // room that only claims the type opens nowhere.
        switch classification {
        case .conversation: return .teamSpace
        case .quarantined: return nil
        case .company, .personal, .unknown: break
        }
        guard roomKind == .group else { return .personal }
        return switch classification {
        case .company, .conversation: .teamSpace
        case .personal: .personal
        case .quarantined, .unknown: nil
        }
    }

    var tab: Router.Tab {
        switch self {
        case .personal: .home
        case .teamSpace: .teamSpace
        }
    }
}

enum CompanyRoomRemovalFence {
    static func closes(openRoomID: String?, removedRoomIDs: Set<String>) -> Bool {
        openRoomID.map(removedRoomIDs.contains) ?? false
    }
}

enum RoomPushDecision {
    static func decide(canOpen: Bool,
                       destination: RoomRootDestination?) -> Router.PendingRoomDecision {
        guard canOpen else { return .deny }
        return destination == nil ? .pending : .allow
    }
}

struct AppRoot: View {
    @State private var model = LiveAppModel()
    @State private var reporting = LiveReporting.shared
    @State private var router = Router()
    @State private var rosterStore = RosterStore()
    @State private var openRequestGeneration: UInt64 = 0
    @State private var dismissChatPresentationRequest: UInt64 = 0
    @State private var signInAttempt = SignInAttemptGate()
    @State private var confirmsStatusSignOut = false
    @State private var statusRecoverySheet = false
    @State private var statusSignOutError = false
    @State private var legalLinks = ChatLinkRouter()
    @State private var roomlessAppFallback: AppBotContinueRequest?
    @State private var appliedAccountScopeGeneration: UInt64?
    private let design = try! LiveDesign()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            design.color("ground", scheme: scheme).ignoresSafeArea()
            switch model.stage {
            case .booting:
                S6BootWait(design: design)
            case let .signedOut(notice):
                S6WelcomeScreen(design: design,
                                presentation: signInAttempt.isInProgress
                                    ? .busy : (notice?.welcomePresentation ?? .idle),
                                onContinue: beginSignIn,
                                onOpenLegal: openLegal)
            case .authorizingMatrix, .preparingDevice, .authorizingDomain:
                S6WelcomeScreen(design: design, presentation: .busy,
                                onContinue: {}, onOpenLegal: openLegal)
            case let .domainRequired(notice):
                S6StatusScreen(design: design, kind: .domain(notice),
                               busy: signInAttempt.isInProgress,
                               retry: beginDomainSignIn, signOut: nil)
            case let .signedIn(account):
                if router.pendingDeepLinkIsCold {
                    S6BootWait(design: design)
                } else {
                    product(account)
                }
            case .recoveryRequired, .unavailable:
                // W4 E3 (coordinator decisions 5 and 11): a launch that could
                // not open a session is never a lock screen and never says
                // the device needs recovery. Quiet, retried on each return to
                // the foreground, and "Thử lại" now. When the session can no
                // longer be renewed here (custody refuses, or records survived
                // a reinstall) it is the sign-in screen with the
                // expired-session notice; "Đăng nhập lại" moves the stranded
                // records aside (never deleted) and signs in.
                if model.launchSessionExpired {
                    S6WelcomeScreen(design: design, presentation: .expired,
                                    onContinue: beginSignInAgain, onOpenLegal: openLegal)
                } else {
                    S6StatusScreen(design: design, kind: .cannotConnect,
                                   busy: false,
                                   retry: { Task { await model.retryBootstrap() } },
                                   signOut: beginStatusSignOut)
                }
            }
        }
        .foregroundStyle(design.color("ink", scheme: scheme))
        .tint(design.color("ink", scheme: scheme))
        .atumDesign(design)
        .focusEffectDisabled()
        .task {
            configureRouter()
            LiveRemoteNotificationRelay.shared.attach(
                onToken: { token in Task { await model.receiveRemoteNotificationToken(token) } },
                onFailure: { error in model.remoteNotificationRegistrationFailed(error) },
                onRoomIntent: { roomID in router.receivePushIntent(roomID: roomID) }
            )
            LiveRemoteNotificationRelay.shared.presents = { model.presentsNotification(roomID: $0) }
            LiveRemoteNotificationRelay.shared.update(screen: router.pushScreen)
            model.appLanguage = design.locale
            model.configureCompanyWorkspace(copy: CompanyCopy(design: design))
            // The scene phase reaches the model through the relay, so this
            // body never depends on it.
            model.observeScenePhase()
            await model.bootstrap()
        }
        .onChange(of: router.pushIntentGeneration, initial: true) { _, _ in
            guard let roomID = router.latestPushIntentRoomID else { return }
            handlePushRoomIntent(roomID)
        }
        .onChange(of: router.pushScreen, initial: true) { _, screen in
            LiveRemoteNotificationRelay.shared.update(screen: screen)
        }
        .onChange(of: model.pushRoutingReady) { _, _ in validatePendingPush() }
        .fullScreenCover(item: $legalLinks.presented) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
        .fullScreenCover(item: Binding(
            get: { model.appContentPage },
            set: { if $0 == nil { model.dismissAppContent() } }
        )) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
        .sheet(item: Binding(
            get: { model.appOnboarding },
            set: { if $0 == nil { model.cancelAppOnboarding() } }
        )) { item in
            AppOnboardingSheet(
                presentation: model.appOnboarding ?? item,
                design: design,
                start: model.continueAppOnboarding,
                retry: model.retryAppOnboarding,
                update: model.updateAppIntake,
                submit: model.submitAppIntake,
                dismiss: model.cancelAppOnboarding
            )
            .atumDesign(design)
        }
        .sheet(item: $roomlessAppFallback) { request in
            ContinueOnMacSheet(request: request, design: design) {
                roomlessAppFallback = nil
            }
            .atumDesign(design)
        }
        .sheet(isPresented: $statusRecoverySheet) {
            RecoveryKeySheet(design: design, mode: .saveBeforeSignOut,
                             load: {
                                 model.currentRecoveryKey().map(RecoveryKeyLoadResult.value)
                                     ?? .unavailable
                             },
                             primary: {
                                 model.markRecoveryKeySaved()
                                 let succeeded = await model.signOutFromStatus(
                                     confirmedRecoverySaved: true
                                 )
                                 if !succeeded { statusSignOutError = true }
                                 return succeeded
                             })
        }
        .confirmationDialog(
            design.text("src.matrix.mobile-copy.mobilePhoneCopy.signOutTitle"),
            isPresented: $confirmsStatusSignOut,
            titleVisibility: .visible
        ) {
            Button(design.text("desktop.dm.signOut"), role: .destructive) {
                Task {
                    let succeeded = await model.signOutFromStatus(confirmedRecoverySaved: false)
                    if !succeeded {
                        statusSignOutError = true
                    }
                }
            }
            Button(design.text("src.matrix.chat-copy.copies.cancel")) {}
        } message: {
            Text(design.text("src.matrix.mobile-copy.mobilePhoneCopy.signOutBody"))
        }
        .alert(design.text("src.matrix.chat-copy.copies.errorGeneric"),
               isPresented: $statusSignOutError) {
            Button(design.text("src.matrix.chat-copy.copies.retry")) { beginStatusSignOut() }
            Button(design.text("src.matrix.chat-copy.copies.cancel"), role: .cancel) {}
        }
        .alert(design.text("src.matrix.chat-copy.copies.errorGeneric"),
               isPresented: Binding(get: { model.appRouteFailed },
                                    set: { if !$0 { model.dismissAppRouteFailure() } })) {
            Button(design.text("src.matrix.chat-copy.copies.dismiss"), role: .cancel) {
                model.dismissAppRouteFailure()
            }
        }
        .onChange(of: model.appOnboardingReadyRoomID) { _, roomID in
            guard roomID != nil, let canonical = model.consumeAppOnboardingReadyRoom() else { return }
            Task { _ = await openRoomAndRoute(canonical) }
        }
        .onChange(of: model.accountScopeGeneration, initial: true) { _, _ in
            guard appliedAccountScopeGeneration != model.accountScopeGeneration else { return }
            appliedAccountScopeGeneration = model.accountScopeGeneration
            router.resetAccountScope()
        }
    }

    private func beginSignIn() {
        guard signInAttempt.begin() else { return }
        Task {
            await model.signIn()
            signInAttempt.finish(signInOutcome)
        }
    }

    private func beginSignInAgain() {
        guard signInAttempt.begin() else { return }
        Task {
            await model.signInAgain()
            signInAttempt.finish(signInOutcome)
        }
    }

    private func beginDomainSignIn() {
        guard signInAttempt.begin() else { return }
        Task {
            await model.continueDomainSignIn()
            signInAttempt.finish(signInOutcome)
        }
    }

    private var signInOutcome: SignInAttemptGate.Outcome {
        switch model.stage {
        case .signedIn:
            .succeeded
        case let .signedOut(notice):
            notice == .cancelled ? .cancelled : .failed
        case let .domainRequired(notice):
            notice == .cancelled ? .cancelled : .failed
        default:
            .failed
        }
    }

    private func openLegal(_ url: URL) {
        legalLinks.open(url.absoluteString)
    }

    private func beginStatusSignOut() {
        if model.statusRequiresRecoverySave {
            statusRecoverySheet = true
        } else {
            confirmsStatusSignOut = true
        }
    }

    /// The S2 signed-in shell. Each tab keeps an independent navigation path;
    /// Home still pushes S1's chat; Store and Workplace are distinct roots,
    /// while Account keeps its existing avatar-triggered sheet.
    private func product(_ account: LiveAccountSummary) -> some View {
        let presentation = model.presentation()
        // The Founder's local draft is a row, never a room: it never reaches a Matrix call.
        let founderDraft = model.founderDraftRow
        let homeRooms = presentation.rooms.rooms + (founderDraft.map { [$0] } ?? [])
        let rosterSnapshot = Self.rosterSnapshot(from: homeRooms,
                                                 founderRoomID: model.founderRoomID ?? founderDraft?.id)
        let companySignals = model.companyWorkspace.roomSignals(from: presentation.rooms.rooms)
        let roomActivity = presentation.rooms.rooms.reduce(into: [String: Date]()) { result, room in
            if let date = room.latestEventAt { result[room.id] = date }
        }
        let home = homePresentation(from: presentation, extraRoom: founderDraft,
                                    snapshot: rosterSnapshot, companySignals: companySignals)
        // Settings > Assistants lists the assistants Home lists, in Home's order.
        let accountPresentation = accountPresentation(
            account,
            assistants: AccountAssistantRoster.summaries(
                readyRoomIDs: home.rows.filter(\.kind.isAssistant).map(\.roomID),
                rooms: presentation.rooms.rooms,
                titles: model.assistantTitles
            )
        )
        return RootTabs(
            router: router,
            design: design,
            availability: PhoneTabAvailability(
                drive: true,
                teamSpace: model.companyWorkspace.isVisible
            ),
            badges: PhoneTabBadges(
                teamSpace: model.companyWorkspace.tabBadge(signals: companySignals))
        ) {
            HomeScreen(design: design, router: router,
                       accountName: accountPresentation.name,
                       accountAvatarURL: accountPresentation.avatarURL,
                       presentation: home,
                       actions: homeActions,
                       dismissPresentationRequest: dismissChatPresentationRequest,
                       onPresentationChanged: { active in
                           if router.selectedTab == .home, router.homeRoomID == nil {
                               router.presentationChanged(active)
                           }
                       })
                .onAppear {
                    model.recordChatListSnapshot(accountID: account.matrixUserID,
                                                 rows: home.rows)
                }
                .onChange(of: home) { _, value in
                    model.recordChatListSnapshot(accountID: account.matrixUserID,
                                                 rows: value.rows)
                }
                .navigationDestination(for: String.self) { roomID in
                    chatHost(account, roomID: roomID)
                }
        } drive: {
            DriveScreen(design: design, router: router, model: model.drive)
        } store: {
            StoreScreen(
                design: design,
                store: presentation.store,
                onRefresh: { await model.refreshProduct() },
                onOpenRoom: { routeFromRootDestination($0) },
                onStartApp: { startAppChat($0) },
                setAppShortcutVisibility: { appID, shown in
                    await model.setAppShortcutVisibility(appID: appID, shown: shown)
                }
            )
        } teamSpace: {
            TeamSpaceScreen(
                design: design,
                presentation: TeamSpacePresentation(
                    isLoading: model.companyWorkspace.phase == .idle
                        || model.companyWorkspace.phase == .probing,
                    isUnavailable: model.companyWorkspace.phase == .unavailable,
                    invitations: model.companyWorkspace.invitationRows(),
                    workspace: model.companyWorkspace.activeCompanyID.flatMap {
                        model.companyWorkspace.workspace(companyID: $0, signals: companySignals,
                                                         activity: roomActivity)
                    },
                    switcher: model.companyWorkspace.switcherEntries(signals: companySignals),
                    canCreate: model.companyWorkspace.canCreate,
                    appIconCount: home.appIconCount,
                    logos: model.companyWorkspace.logoURIs(from: presentation.rooms.rooms)
                ),
                actions: TeamSpaceActions(
                    refresh: { await model.refreshCompanyWorkspace() },
                    selectCompany: { model.companyWorkspace.selectCompany($0) },
                    openRoom: { routeFromRootDestination($0) },
                    acceptInvitation: { invitationID in
                        guard let roomID = await model.companyWorkspace.accept(
                            invitationID: invitationID
                        ) else { return false }
                        return await openRoomAndRoute(roomID)
                    },
                    declineInvitation: { model.companyWorkspace.declineInvitation($0) },
                    leave: { await model.companyWorkspace.leave(companyID: $0) },
                    setMuted: { model.setRoomMuted($0, isMuted: $1) },
                    createCompany: { await createCompany(named: $0) },
                    createNameEdited: { model.companyWorkspace.abandonPendingCreate() },
                    setAppIconBadge: { count in
                        try? await UNUserNotificationCenter.current().setBadgeCount(count)
                    },
                    conversations: conversationListActions,
                    loadMatrixThumbnail: { uri, side in
                        await model.avatarThumbnail(uri: uri, pixelSide: side)
                    }
                )
            )
            .navigationDestination(for: String.self) { roomID in
                chatHost(account, roomID: roomID)
            }
        } account: {
            AccountScreen(design: design,
                          presentation: accountPresentation,
                          actions: accountActions,
                          store: presentation.store,
                          refreshStore: { await model.refreshProduct() },
                          openStoreRoom: { roomID in
                              router.dismissAccount()
                              requestRoomOpen(roomID)
                          },
                          setAppShortcutVisibility: { appID, shown in
                              await model.setAppShortcutVisibility(appID: appID, shown: shown)
                          },
                          shareActivity: model.shareActivity,
                          setShareActivity: { await model.setShareActivity($0) },
                          crashReportsEnabled: reporting.crashReportsEnabled,
                          setCrashReportsEnabled: { reporting.setCrashReportsEnabled($0) },
                          usageDataEnabled: reporting.usageDataEnabled,
                          setUsageDataEnabled: { reporting.setUsageDataEnabled($0) },
                          founderContactAvailable: model.founderContactAvailable,
                          founderContactTitle: model.founderContactTitle,
                          founderDraft: founderDraftActions(dismissAccountOnSent: true),
                          contactFounder: { await model.contactFounder() },
                          openFounderRoom: { roomID in
                              router.dismissAccount()
                              requestRoomOpen(roomID)
                          },
                          assistantCard: { assistant in
                              // The chat's own assistant card, with the same
                              // per-assistant actions the chat info sheet gives it.
                              AnyView(AssistantCard(
                                  design: design,
                                  identity: AssistantCardIdentity(
                                      roomID: assistant.roomID,
                                      name: assistant.name,
                                      title: assistant.title,
                                      botHandle: assistant.botHandle,
                                      isPrimary: assistant.isPrimary,
                                      avatar: assistant.avatarURL.map {
                                          .photo(url: $0, fallback: assistant.name)
                                      },
                                      matrixAvatarURI: assistant.matrixAvatarURL,
                                      avatarSHA256: assistant.avatarSHA256
                                  ),
                                  entry: .settingsRoster,
                                  definition: model.assistantDefinitionActions(roomID: assistant.roomID),
                                  models: model.assistantModelActions(roomID: assistant.roomID),
                                  home: model.assistantHomeActions(roomID: assistant.roomID),
                                  modelDestinations: model.assistantModelDestinationActions(roomID: assistant.roomID),
                                  avatar: model.assistantAvatarActions(roomID: assistant.roomID),
                                  routines: model.assistantRoutineActions(roomID: assistant.roomID),
                                  loadMatrixThumbnail: { uri, side in
                                      await model.avatarThumbnail(uri: uri, pixelSide: side)
                                  },
                                  onMessage: {
                                      router.dismissAccount()
                                      requestRoomOpen(assistant.roomID)
                                  },
                                  onOpenStore: {
                                      router.dismissAccount()
                                      router.select(tab: .store)
                                  }
                              ))
                          })
        }
        .environment(\.showsConnectionGlyph, model.showsConnectionGlyph)
        .task(id: rosterSnapshot) {
            rosterStore.apply(rosterSnapshot)
            validatePendingPush()
        }
        .task(id: RoomClassificationInput(
            roomIDs: presentation.rooms.rooms.map(\.id).sorted(),
            typeClaims: presentation.rooms.rooms.filter(\.claimsConversationType).map(\.id).sorted(),
            revision: model.companyWorkspace.classificationRevision
        )) {
            model.companyWorkspace.reconcileMatrixRooms(
                Set(presentation.rooms.rooms.map(\.id)),
                conversationTypeClaims: Set(presentation.rooms.rooms
                    .filter(\.claimsConversationType).map(\.id))
            )
            validatePendingPush()
        }
        .onChange(of: router.homePath.count) { _, count in
            if count == 0 { router.didPopHomeRoom() }
        }
        .onChange(of: router.teamSpacePath.count) { _, count in
            if count == 0 { router.didPopTeamSpaceRoom() }
        }
        .onChange(of: router.homeRoomID) { _, roomID in
            if roomID == nil, router.selectedTab == .home { model.closeConversation() }
        }
        .onChange(of: router.teamSpaceRoomID) { _, roomID in
            if roomID == nil, router.selectedTab == .teamSpace { model.closeConversation() }
        }
        .onChange(of: model.companyLeftToken) { _, _ in
            if CompanyRoomRemovalFence.closes(
                openRoomID: router.teamSpaceRoomID,
                removedRoomIDs: model.companyLeftRooms
            ) {
                router.popTeamSpaceToRoot()
            }
        }
        .onChange(of: model.companyWorkspace.classificationRevision) { _, _ in
            validatePendingPush()
        }
    }

    private func accountPresentation(_ account: LiveAccountSummary,
                                     assistants: [AccountAssistantSummary]) -> AccountPresentation {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
        return AccountPresentation(
            matrixUserID: account.matrixUserID,
            displayName: account.displayName,
            offersHistoryRecovery: model.offersHistoryRecovery,
            holdsRecoveryKey: model.holdsRecoveryKey,
            recoveryKeySavedOnThisPhone: model.recoveryKeySavedOnThisPhone,
            signOutInProgress: model.signOutInProgress,
            signOutFailureToken: model.signOutFailureToken,
            version: build.isEmpty ? version : version + " (" + build + ")",
            assistants: assistants,
            founderContactAvailable: model.founderContactAvailable,
            founderContactTitle: model.founderContactTitle,
            avatarURL: account.avatarURL,
            connection: model.accountConnection
        )
    }

    private var accountActions: AccountActions {
        AccountActions(
            readNotificationState: {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                return Self.notificationState(settings.authorizationStatus)
            },
            requestNotifications: {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .badge, .sound])
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                if settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional
                    || settings.authorizationStatus == .ephemeral {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                return Self.notificationState(settings.authorizationStatus)
            },
            openNotificationSettings: {
                UIApplication.shared.open(URL(string: UIApplication.openNotificationSettingsURLString)!)
            },
            openAppSettings: {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            },
            loadRecoveryKey: {
                model.currentRecoveryKey().map(RecoveryKeyLoadResult.value) ?? .unavailable
            },
            markRecoveryKeySaved: { model.markRecoveryKeySaved() },
            restoreMessages: { await model.restoreMessages(using: $0) },
            signOut: { await model.signOut(confirmedRecoverySaved: $0) },
            openWebPage: openLegal,
            saveProfileName: { await model.saveProfileName($0) },
            saveProfilePhoto: { await model.saveProfilePhoto($0) },
            loadAvatarThumbnail: { uri, pixelSide in
                await model.avatarThumbnail(uri: uri, pixelSide: pixelSide)
            },
            ignoredPeople: { await model.ignoredPeople() },
            setIgnored: { await model.setIgnored(userID: $0, ignored: $1) }
        )
    }

    private static func notificationState(_ status: UNAuthorizationStatus) -> AccountNotificationState {
        switch status {
        case .authorized, .provisional, .ephemeral: .on
        case .denied: .off
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    private func homePresentation(from source: LiveProductPresentation,
                                  extraRoom: LiveProductRoom? = nil,
                                  snapshot: RosterSnapshot,
                                  companySignals: CompanyRoomSignals) -> HomePresentation {
        var state: HomeLoadState = switch source.rooms.availability {
        case .loading: .loading
        case .ready: source.rooms.rooms.isEmpty && extraRoom == nil ? .empty : .ready
        case .empty: extraRoom == nil ? .empty : .ready
        case .offline: .offline
        case .unavailable: .error
        }
        var roomsByID = [String: LiveProductRoom]()
        for room in source.rooms.rooms where roomsByID[room.id] == nil { roomsByID[room.id] = room }
        if let extraRoom, roomsByID[extraRoom.id] == nil { roomsByID[extraRoom.id] = extraRoom }
        let projection = rosterStore.snapshot == snapshot
            ? rosterStore.output
            : RosterProjection.project(snapshot.projectionInput)
        // A company channel opens from its company, not from the ordinary
        // chat list; the room itself stays in `productRooms()` so the
        // existing chat can open it.
        let ordered = (projection.assistants + projection.chats)
            .compactMap { roomsByID[$0.roomID] }
            .filter { room in
                // A conversation (or a room that claims to be one) is never a Home row,
                // whatever its member count says.
                switch model.companyWorkspace.roomClassification(room.id) {
                case .conversation, .quarantined: return false
                case .company, .personal, .unknown:
                    guard room.kind == .group else { return true }
                    return model.companyWorkspace.roomClassification(room.id) == .personal
                }
            }
        let locale = Locale(identifier: design.locale)
        let liveRows = ordered.map { HomeRow(product: $0, locale: locale) }
        let rows: [HomeRow]
        if model.chatListIsAuthoritative {
            // All three sources settled: the live projection is the truth,
            // including a genuinely empty list. The one exception is a
            // delivery-outcome notice at the head of a chat: its warning was
            // suppressed, so keep the last real message the cache holds.
            rows = ChatListSnapshot.authoritative(cached: model.cachedChatList,
                                                  live: liveRows.map(\.snapshotRow))
                .map { HomeRow(snapshot: $0) }
        } else if model.hasCachedChatList {
            // Cold launch or a partial refresh: paint the last complete list
            // with its photos and real previews, and let live counts and
            // newer messages move in place.
            rows = ChatListSnapshot.merged(cached: model.cachedChatList,
                                           live: liveRows.map(\.snapshotRow),
                                           liveIsAuthoritative: false)
                .map { HomeRow(snapshot: $0) }
        } else if !liveRows.isEmpty, !model.chatListHoldExpired {
            // First ever launch only: wait for the bounded hold instead of
            // painting a wall of initials before /agents and /apps answer.
            rows = []
            state = .loading
        } else {
            rows = liveRows
        }
        return HomePresentation(
            state: state,
            rows: rows,
            showsNotificationPrompt: source.notificationPrompt,
            showsDomainReauthentication: model.domainRecoveryState == .reauthenticationRequired,
            domainReauthenticationBusy: model.domainReauthenticationInProgress,
            actionFailureToken: model.roomActionFailure.token,
            pinnedRoomCount: model.joinedPinnedRoomCount,
            companyAppIconRows: model.companyWorkspace.appIconRows(signals: companySignals))
    }

    static func rosterSnapshot(from rooms: [LiveProductRoom],
                               founderRoomID: String? = nil) -> RosterSnapshot {
        var projectedRooms = [RosterProjection.Room]()
        var assistants = [RosterProjection.Assistant]()
        var apps = [RosterProjection.App]()
        for (index, room) in rooms.enumerated() {
            switch room.kind {
            case .agent where room.isAppBotRoom || room.id.hasPrefix("app:"):
                let appID = room.id.hasPrefix("app:") ? String(room.id.dropFirst(4)) : room.id
                projectedRooms.append(.init(id: room.id, kind: .app(appID: appID),
                                            latestEventAt: room.latestEventAt,
                                            isFavourite: room.isPinned))
                apps.append(.init(id: appID, rosterOrder: index,
                                  conversationRoomID: room.canOpen ? room.id : nil,
                                  isPresentationOnly: room.isComingSoon))
            case .agent:
                // A room classified as an assistant chat must stay visible even
                // if `/agents` did not carry its metadata. The fallback keeps
                // the room's own ID and sorts it after the server's agents.
                let assistant = room.assistant
                    ?? LiveProductAssistantMetadata(id: room.id, isDefault: false, order: .max)
                projectedRooms.append(.init(id: room.id, kind: .assistant(agentID: assistant.id),
                                            latestEventAt: room.latestEventAt,
                                            isFavourite: room.isPinned))
                assistants.append(.init(id: assistant.id,
                                        conversationRoomID: room.canOpen ? room.id : nil,
                                        isPrimary: assistant.isDefault,
                                        agentOrder: assistant.order))
            case .people:
                projectedRooms.append(.init(id: room.id, kind: .person,
                                            membership: room.isInvitation ? .invited : .joined,
                                            latestEventAt: room.latestEventAt,
                                            isFavourite: room.isPinned))
            case .group:
                projectedRooms.append(.init(id: room.id, kind: .group,
                                            membership: room.isInvitation ? .invited : .joined,
                                            latestEventAt: room.latestEventAt,
                                            isFavourite: room.isPinned))
            }
        }
        return RosterSnapshot(rooms: projectedRooms, assistants: assistants, apps: apps,
                              founderRoomID: founderRoomID)
    }

    /// The pushed chat (B31): `ChatScreen` on the open chat's own store, with
    /// the system navigation bar (back button and edge swipe). Popping it
    /// closes the chat when Router observes the pop.
    @ViewBuilder private func chatHost(_ account: LiveAccountSummary, roomID: String) -> some View {
        if let store = model.conversation, store.roomID == roomID {
            ChatScreen(
                store: store, design: design, avatar: model.conversationAvatar,
                info: model.chatInfoPresentation(roomID: roomID),
                infoActions: ChatInfoActions(
                    setPinned: { model.setRoomPinned($0, isPinned: $1) },
                    setMuted: { model.setRoomMuted($0, isMuted: $1) },
                    deleteAppRoom: { roomID in
                        model.hideAppRoom(roomID)
                        router.popHomeToRoot()
                    },
                    leaveCompany: { companyID in
                        Task { await model.companyWorkspace.leave(companyID: companyID) }
                    },
                    assistantDefinition: model.assistantDefinitionActions(roomID: roomID),
                    assistantModels: model.assistantModelActions(roomID: roomID),
                    assistantModelDestinations: model.assistantModelDestinationActions(roomID: roomID),
                    assistantHome: model.assistantHomeActions(roomID: roomID),
                    assistantAvatar: model.assistantAvatarActions(roomID: roomID),
                    assistantPresentation: model.assistantPresentationActions(roomID: roomID),
                    assistantRoutines: model.assistantRoutineActions(roomID: roomID),
                    openStore: { router.select(tab: .store) },
                    exitRoom: { roomID, action in
                        model.exitRoom(roomID, action)
                        router.popHomeToRoot()
                    },
                    setIgnored: { await model.setIgnored(userID: $0, ignored: $1) },
                    viewerIsFounder: model.isFounderAccount
                ),
                appBot: model.appBotPresentation(roomID: roomID),
                appBotCatalog: model.appBotCatalogPresentation(),
                onOpenAppBot: { router.open(app: $0) },
                onBeginAppBotSetup: model.beginAppOnboarding,
                onOpenAppBotRoute: model.openAppRoute,
                onOpenAppBotTerms: model.openAppTerms,
                appOnboardingPresented: model.appOnboarding != nil,
                mediaAccess: ChatMediaAccess(
                    thumbnail: { media, width, height in
                        await model.mediaThumbnail(
                            sourceHandle: media.thumbnailSourceHandle ?? media.sourceHandle,
                            pixelWidth: width,
                            pixelHeight: height
                        )
                    },
                    content: { media in
                        await model.mediaContent(sourceHandle: media.sourceHandle)
                    },
                    file: { media in
                        await model.mediaFile(sourceHandle: media.sourceHandle,
                                              filename: media.filename,
                                              mimetype: media.mimetype ?? "application/octet-stream")
                    },
                    uploadLimit: { await model.maximumMediaUploadSize() }
                ),
                loadMatrixThumbnail: { uri, pixelSide in
                    await model.avatarThumbnail(uri: uri, pixelSide: pixelSide)
                },
                firstRunContext: model.firstRunContext(roomID: roomID),
                founderIntro: model.founderIntroPresentation(roomID: roomID),
                companyNotice: model.companyChatNotice(roomID: roomID),
                conversationChat: model.conversationChat(roomID: roomID),
                conversationActions: conversationChatActions,
                dismissPresentationRequest: dismissChatPresentationRequest,
                onPresentationChanged: { active in
                    if router.activeRoomID == roomID { router.presentationChanged(active) }
                }
            )
        } else if let opening = model.appBotRoomOpening, opening.roomID == roomID {
            AppBotRoomOpeningView(opening: opening, design: design) {
                model.retryAppBotJoin(roomID: roomID)
            }
            .toolbar(.hidden, for: .tabBar)
        } else {
            design.color("ground", scheme: scheme).ignoresSafeArea()
        }
    }

    private var homeActions: HomeActions {
        HomeActions(
            openRoom: { requestRoomOpen($0) },
            joinInvitation: { await openRoomAndRoute($0) },
            refresh: { await model.refreshProduct() },
            rowsShown: {
                Task { await model.chatListDidAppear() }
            },
            setAppIconBadge: { count in
                try? await UNUserNotificationCenter.current().setBadgeCount(count)
            },
            loadMatrixThumbnail: { uri, pixelSide in
                await model.avatarThumbnail(uri: uri, pixelSide: pixelSide)
            },
            answerNotificationPrompt: { allow in
                Task { await model.answerNotificationPrompt(allow: allow) }
            },
            reauthenticateDomain: {
                Task { await model.reauthenticateDomain() }
            },
            setUnread: { model.setRoomUnread($0, isUnread: $1) },
            setPinned: { model.setRoomPinned($0, isPinned: $1) },
            setMuted: { model.setRoomMuted($0, isMuted: $1) },
            setAppShortcutVisibility: { appID, shown in
                await model.setAppShortcutVisibility(appID: appID, shown: shown)
            },
            deleteAppRoom: { model.hideAppRoom($0) },
            declineInvitation: { model.declineInvitation($0) },
            addFriend: model.canAddFriend ? { handle in
                await model.addFriend(handle)
            } : nil,
            peopleDiscovery: model.canAddFriend ? HomePeopleDiscoveryActions(
                search: { await model.searchPeople($0) },
                open: { await model.openPerson($0) },
                loadMatrixThumbnail: { await model.avatarThumbnail(uri: $0, pixelSide: $1) }
            ) : nil,
            newGroup: model.canCreateGroup ? HomeGroupActions(
                candidates: model.groupCandidates,
                lookup: { handle in await model.lookupGroupPerson(handle) },
                create: { name, members in await model.createGroup(name, selected: members) },
                search: { await model.searchPeople($0) },
                loadMatrixThumbnail: { await model.avatarThumbnail(uri: $0, pixelSide: $1) }
            ) : nil,
            newAssistant: model.canCreateAssistant ? HomeAssistantActions(
                pending: model.hasPendingAssistantLifecycle,
                create: { name in await model.createAssistant(name) }
            ) : nil,
            founderDraft: founderDraftActions(dismissAccountOnSent: false),
            exitRoom: { model.exitRoom($0, $1) },
            viewerIsFounder: model.isFounderAccount
        )
    }

    /// The Founder draft's one send: its first message makes the chat (or finds the one another
    /// device made) and opens it. From Settings the account stays up until the send lands, so a
    /// failure keeps the draft and its words; a success dismisses Settings to the chat behind it.
    private func founderDraftActions(dismissAccountOnSent: Bool) -> FounderDraftActions? {
        model.founderDraftPresentation.map { copy in
            FounderDraftActions(
                name: copy.name,
                subtitle: copy.subtitle,
                intro: copy.intro,
                unready: copy.unready,
                send: { body in
                    guard let roomID = await model.openFounderDraftRoom(),
                          await openRoomAndRoute(roomID) else { return false }
                    let sent = model.sendInOpenConversation(body, roomID: roomID)
                    if sent, dismissAccountOnSent { router.dismissAccount() }
                    return sent
                }
            )
        }
    }

    /// Direct messages on the Workplace list. Every call goes to the company
    /// authority through the model's conversation store.
    private var conversationListActions: ConversationListActions {
        let store = model.companyWorkspace.conversations
        return ConversationListActions(
            people: { model.companyWorkspace.conversationPeople(companyID: $0) },
            start: { companyID, others in
                await model.companyWorkspace.startConversation(companyID: companyID, others: others)
            },
            open: { companyID, item in
                // The company is the one the person tapped in; every await below can outlive it.
                guard model.companyWorkspace.activeCompanyID == companyID else { return }
                // A hidden conversation is shown again by opening it.
                await store.prepareToOpen(companyID: companyID, conversationID: item.id)
                guard let roomID = item.row.roomID else { return }
                _ = await openRoomAndRoute(roomID, requiringCompany: companyID)
            },
            hide: { companyID, conversationID, hidden in
                _ = await store.setHidden(companyID: companyID, conversationID: conversationID, hidden: hidden)
            },
            routeToRoom: { companyID, roomID in requestRoomOpen(roomID, requiringCompany: companyID) })
    }

    /// Add people and Hide from inside an open conversation.
    private var conversationChatActions: ConversationChatActions {
        let store = model.companyWorkspace.conversations
        return ConversationChatActions(
            people: { companyID, kept in model.companyWorkspace.conversationPeople(companyID: companyID, excluding: kept) },
            addPeople: { companyID, sourceID, others in
                await model.companyWorkspace.addConversationPeople(
                    companyID: companyID, sourceConversationID: sourceID, others: others)
            },
            hide: { companyID, conversationID in
                if await store.setHidden(companyID: companyID, conversationID: conversationID, hidden: true),
                   model.companyWorkspace.activeCompanyID == companyID {
                    router.popTeamSpaceToRoot()
                }
            },
            routeToRoom: { companyID, roomID in requestRoomOpen(roomID, requiringCompany: companyID) })
    }

    private func requestRoomOpen(_ roomID: String, stagedCold: Bool = false, requiringCompany: String? = nil) {
        Task { _ = await openRoomAndRoute(roomID, stagedCold: stagedCold, requiringCompany: requiringCompany) }
    }

    private func routeFromRootDestination(_ roomID: String) {
        requestRoomOpen(roomID)
    }

    /// Workplace's "Create company": nil once the company exists and its
    /// #general is open (like the desktop; while the channel is still being
    /// prepared the list says so), else why it was not created.
    private func createCompany(named name: String) async -> CompanyCreateFailure? {
        switch await model.companyWorkspace.createCompany(named: name) {
        case let .created(roomID):
            if let roomID { _ = await openRoomAndRoute(roomID) }
            return nil
        case let .failed(failure):
            return failure
        }
    }

    /// `requiringCompany` is the company a person's own tap or action started in. It is checked
    /// before anything is staged and again after every await, before navigating: if they have
    /// moved to another company meanwhile, or the room is no longer that company's, nothing opens.
    private func openRoomAndRoute(_ roomID: String, stagedCold: Bool = false,
                                  requiringCompany: String? = nil) async -> Bool {
        func fenceHolds() -> Bool {
            guard let requiringCompany else { return true }
            return model.companyWorkspace.isSelected(companyID: requiringCompany, owning: roomID)
        }
        // A roster row for an app with no chat yet starts that app's flow (not a company room).
        if let slug = model.startableAppSlug(forRowID: roomID) {
            startAppChat(slug)
            return false
        }
        guard fenceHolds() else { return false }
        guard let requestedDestination = roomDestination(for: roomID) else { return false }
        if requestedDestination == .teamSpace { model.companyWorkspace.activateCompany(owning: roomID) }
        prepareRoot(requestedDestination, roomID: roomID, stagedCold: stagedCold)
        openRequestGeneration &+= 1
        let request = openRequestGeneration
        let openedRoomID = await model.openRoom(roomID) {
            // The company and the room's owner are part of "still current", checked around every
            // join, open and attach inside.
            request == openRequestGeneration
                && router.selectedTab == requestedDestination.tab
                && fenceHolds()
        }
        guard request == openRequestGeneration, let openedRoomID else {
            if stagedCold { popRoot(requestedDestination) }
            return false
        }
        guard fenceHolds() else {
            // The chat the model opened internally closes with the failed fence.
            if model.conversation?.roomID == openedRoomID { model.closeConversation() }
            if stagedCold { popRoot(requestedDestination) }
            return false
        }

        // Canonical readback is classified again. The caller never supplies a
        // company scope; only the existing company directory can choose it.
        guard let authoritativeDestination = roomDestination(for: openedRoomID) else {
            popRoot(requestedDestination)
            return false
        }
        if router.selectedTab != authoritativeDestination.tab {
            prepareRoot(authoritativeDestination, roomID: openedRoomID, stagedCold: false)
        }
        guard request == openRequestGeneration,
              router.selectedTab == authoritativeDestination.tab else { return false }

        if authoritativeDestination == .teamSpace { model.companyWorkspace.activateCompany(owning: openedRoomID) }
        let alreadyStaged = openRoomID(for: authoritativeDestination) == openedRoomID
        open(openedRoomID, in: authoritativeDestination)
        if !alreadyStaged {
            await LivePushRouting.removeDeliveredNotifications(for: openedRoomID)
        }
        return true
    }

    private func roomDestination(for roomID: String) -> RoomRootDestination? {
        guard let room = model.presentation().rooms.rooms.first(where: { $0.id == roomID }) else {
            return nil
        }
        return RoomRootDestination.authoritative(
            roomKind: room.kind,
            classification: model.companyWorkspace.roomClassification(roomID)
        )
    }

    private func prepareRoot(_ destination: RoomRootDestination,
                             roomID: String,
                             stagedCold: Bool) {
        switch (destination, stagedCold) {
        case (.personal, false): router.showHomeRoot()
        case (.personal, true): router.stageColdRoom(roomID: roomID)
        case (.teamSpace, false): router.showTeamSpaceRoot()
        case (.teamSpace, true): router.stageColdTeamSpaceRoom(roomID: roomID)
        }
    }

    private func open(_ roomID: String, in destination: RoomRootDestination) {
        switch destination {
        case .personal: router.open(roomId: roomID)
        case .teamSpace: router.openTeamSpace(roomId: roomID)
        }
    }

    private func openRoomID(for destination: RoomRootDestination) -> String? {
        switch destination {
        case .personal: router.homeRoomID
        case .teamSpace: router.teamSpaceRoomID
        }
    }

    private func popRoot(_ destination: RoomRootDestination) {
        switch destination {
        case .personal: router.popHomeToRoot()
        case .teamSpace: router.popTeamSpaceToRoot()
        }
    }

    private func configureRouter() {
        router.onValidatedRoom = { roomID in requestRoomOpen(roomID) }
        router.onValidatedColdRoom = { roomID in
            requestRoomOpen(roomID, stagedCold: true)
        }
        router.onOpenCurrentRoom = { roomID in
            model.scrollConversationToLatest()
            Task { await LivePushRouting.removeDeliveredNotifications(for: roomID) }
        }
        router.onOpenApp = { slug in requestAppOpen(slug) }
        router.onUserSelectedTab = { tab in
            openRequestGeneration &+= 1
            let retainedRoomID: String? = switch tab {
            case .home: router.homeRoomID
            case .teamSpace: router.teamSpaceRoomID
            case .drive, .store: nil
            }
            if let retainedRoomID { requestRoomOpen(retainedRoomID) }
        }
        router.dismissPresentation = {
            dismissChatPresentationRequest &+= 1
        }
    }

    /// “Start a chat” on a Store row for an app with no room: the app's own
    /// disclosure flow (guest or linked, by its catalog and status), whose
    /// finished chat the `appOnboardingReadyRoomID` handler opens on Home. An
    /// app the phone cannot start keeps the continue-on-computer sheet.
    private func startAppChat(_ slug: String) {
        if !model.beginRoomlessAppOnboarding(slug),
           let app = model.appBotPresentation(slug: slug) {
            roomlessAppFallback = AppBotContinueRequest(app: app, kind: .setup)
        }
    }

    private func requestAppOpen(_ slug: String) {
        Task {
            openRequestGeneration &+= 1
            let request = openRequestGeneration
            let openedRoomID = await model.openExistingAppBot(slug) {
                request == openRequestGeneration && router.selectedTab == .home
            }
            guard request == openRequestGeneration, router.selectedTab == .home else { return }
            if let openedRoomID {
                router.open(roomId: openedRoomID)
            } else if !model.beginRoomlessAppOnboarding(slug),
                      let app = model.appBotPresentation(slug: slug) {
                roomlessAppFallback = AppBotContinueRequest(app: app, kind: .setup)
            }
        }
    }

    private func handlePushRoomIntent(_ roomID: String) {
        if router.activeRoomID == roomID {
            model.scrollConversationToLatest()
            Task { await LivePushRouting.removeDeliveredNotifications(for: roomID) }
            return
        }
        let isCold: Bool = if case .signedIn = model.stage { false } else { true }
        router.holdDeepLink(roomID: roomID, cold: isCold)
        validatePendingPush()
    }

    private func validatePendingPush() {
        router.validatePendingDeepLink(
            sessionAndRosterAreReady: model.pushRoutingReady
        ) {
            RoomPushDecision.decide(
                canOpen: model.canOpenPushedRoom($0),
                destination: roomDestination(for: $0)
            )
        }
    }

}
