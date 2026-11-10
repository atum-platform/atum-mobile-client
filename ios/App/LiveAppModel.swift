import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit
import UserNotifications
import AtumNativeAPI
import AtumDrive
import AtumChat
import AtumDesign

private enum InstalledStoreArtError: Error { case invalidResource }

enum LiveSignInNotice: Equatable {
    case cancelled
    /// A sign-in attempt that failed for a reason other than the person
    /// cancelling. The Welcome screen shows the generic error line.
    case failed
    case domainUnavailable
    case subjectMismatch
}

extension LiveSignInNotice {
    /// The Welcome screen's notice for a signed-out stage. The domain notices
    /// belong to the status screen and never reach this mapping.
    var welcomePresentation: WelcomePresentation {
        switch self {
        case .cancelled: .cancelled
        case .failed: .failed
        case .domainUnavailable, .subjectMismatch: .idle
        }
    }
}

struct LiveAccountSummary: Equatable {
    let matrixUserID: String
    let displayName: String?
    var avatarURL: String? = nil
}

enum LiveAppStage: Equatable {
    case booting
    case signedOut(LiveSignInNotice?)
    case authorizingMatrix
    case preparingDevice
    case authorizingDomain
    case domainRequired(LiveSignInNotice)
    case signedIn(LiveAccountSummary)
    /// No Matrix session could be opened at launch or sign-in (a keychain or
    /// custody failure). W4 E3 (coordinator decisions 5 and 11): never a lock
    /// screen and never "this device needs recovery". The root shows the
    /// quiet "not connected, try again" state, retried on a return to the
    /// foreground, or, when the session can no longer be renewed here
    /// (`LiveAppModel.launchSessionExpired`: custody refuses, or records
    /// survived without their installation), the sign-in screen with the
    /// expired-session notice and "Đăng nhập lại" (`signInAgain`), which
    /// moves the stranded records aside, never deleting or overwriting them.
    /// From the product only a custody refusal comes back here, once the
    /// working session's token has expired.
    case recoveryRequired
    case unavailable
}

struct LiveRoomActionFailure: Equatable {
    var token: UInt64 = 0
    var roomID: String?
}

enum StatusRecoverySignOutPolicy {
    static func requiresSave(hasRecoveryKey: Bool, saved: Bool) -> Bool {
        hasRecoveryKey && !saved
    }

    static func authorizesArchive(hasRecoveryKey: Bool, saved: Bool,
                                  confirmedSaved: Bool) -> Bool {
        !hasRecoveryKey || saved || confirmedSaved
    }
}

@MainActor
@Observable
final class LiveAppModel {
    /// Immutable resources from the installed design-export bundle. A missing
    /// older export simply leaves Store rows on their catalog glyphs.
    private static let storeArtLog = Logger(subsystem: "com.atum.mobile", category: "store-art")
    private static let installedStoreArt: [String: LiveProductStoreArt] = {
        do {
            let catalog = try AtumStoreArtCatalog.load()
            let maximumPointSide = AtumAvatar.cappedPointSize(base: 44, scaled: 44 * 1.35)
            let pixelSide = AtumAvatar.thumbnailPixelSide(for: maximumPointSide)
            var result = [String: LiveProductStoreArt]()
            for (itemID, item) in catalog.items {
                let data = try AtumDesign.data(for: item.resource)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == item.sha256,
                      let art = AtumAvatarArt.decode(data: data, pixelSide: pixelSide) else {
                    throw InstalledStoreArtError.invalidResource
                }
                result[itemID] = LiveProductStoreArt(
                    resource: item.resource, sha256: item.sha256, value: art
                )
            }
            return result
        } catch {
            // Static initialization runs once, so a broken/missing export is
            // visible once without turning every Store render into log noise.
            storeArtLog.error("Installed Store art inventory could not be loaded")
            return [:]
        }
    }()
    private(set) var stage: LiveAppStage = .booting
    private(set) var liveMatrix: LiveMatrixSession?
    /// True while the Matrix runtime is being replaced with a renewed token.
    /// The open chat keeps its transcript; the reconnect notice stays hidden.
    private(set) var isRenewingMatrixSession = false
    private(set) var matrixRecoverySnapshot: MatrixLiveRecoverySnapshot? {
        didSet { conversation?.accountOffersRecovery = offersHistoryRecovery }
    }
    private(set) var recoveryInProgress = false
    /// The one-time "allow notifications?" card on the chat list.
    private(set) var notificationPromptVisible = false
    /// The account-wide first-run answer (`io.atum.onboarding.first_run`).
    /// Unknown is never offered; a missing record alone is `unseen`.
    private(set) var firstRunMarker: FirstRunMarkerState = .unknown
    @ObservationIgnored private var firstRunMarkerCoordinator: FirstRunMarkerCoordinator?
    private(set) var holdsRecoveryKey = false
    private(set) var recoveryKeySavedOnThisPhone = false
    private(set) var signOutInProgress = false
    private(set) var signOutFailureToken: UInt64 = 0
    /// The owner's activity switch (`io.atum.desktop.share_activity`): public
    /// receipts and typing by default. Loaded from Matrix account data on
    /// each established session; the Account screen writes it back.
    private(set) var shareActivity = true
    /// The open chat (plan §2.6): its own store, which holds its own room and
    /// timeline, independent of the roster rows.
    private(set) var conversation: LiveConversationStore?
    private(set) var appBotRoomOpening: AppBotRoomOpening?
    private(set) var appOnboarding: AppOnboardingPresentation?
    private(set) var appOnboardingReadyRoomID: String?
    private(set) var appContentPage: AppContentPage?
    private(set) var appRouteFailed = false
    /// The open chat's avatar, from the row it was opened from (Home's
    /// identity: the eclipse, a photo, a catalog avatar).
    private(set) var conversationAvatar: LiveProductAvatar?
    /// Joined members for the open group, loaded from the current SDK cache.
    /// The info sheet remains usable while this is still empty.
    private(set) var conversationMembers = [LiveMatrixMemberRow]()
    /// A rollback announces only on the surface for the room whose action
    /// failed; Home receives every row failure while the info sheet filters by
    /// its room ID.
    private(set) var roomActionFailure = LiveRoomActionFailure()
    /// The pushed chat (B31): one room ID while a chat is open. Popping it
    /// (back, or the swipe once the system toolbar lands) closes the chat.
    /// Each room keeps its draft while the app runs (B25).
    @ObservationIgnored private var drafts = [String: String]()
    @ObservationIgnored private var mediaDrafts = [String: ChatMediaComposerState]()
    @ObservationIgnored private var localMediaDrafts = [String: ConversationLocalMediaDraft]()
    @ObservationIgnored private var conversationMembersTask: Task<Void, Never>?
    private var conversationOpenedRoom: LiveProductRoom?
    @ObservationIgnored private var isRefreshingDomainOnForeground = false
    /// The app's copy language (`LiveDesign.locale`), set by the root view:
    /// a catalog bot's two-language notice shows the line in it.
    @ObservationIgnored var appLanguage = "vi"
    /// The vendored "Getting ready" line for an active agent whose chat room
    /// has not reached this phone yet.
    private var waitingDetail: String? {
        guard let copyCatalog else { return nil }
        let locale = copyCatalog.locales.contains(Self.currentLocale) ? Self.currentLocale : "en"
        return try? copyCatalog.text(LiveRosterRows.waitingCopyKey, locale: locale)
    }
    /// The vendored "Coming soon" line for an inert catalog placeholder. Only
    /// the existing copy key is used; the row invents no copy.
    private var comingSoonDetail: String? {
        guard let copyCatalog else { return nil }
        let locale = copyCatalog.locales.contains(Self.currentLocale) ? Self.currentLocale : "en"
        return try? copyCatalog.text(LiveRosterRows.comingSoonCopyKey, locale: locale)
    }
    /// The desktop's pointer room per app ID (`io.atum.app_bot.dm.<appId>`
    /// account data), read after each refresh, so the list and reopening pick
    /// the same bot room as the Mac (§4.2 item 2).
    private var appBotPointers = [String: String]()
    /// The person's explicit `io.atum.app_shortcut.<appId>` choice, read from
    /// the same SDK global account data the desktop writes. Unknown covers
    /// loading/failed reads; the roster fails closed on it.
    private var appShortcuts = [AppCatalogID: MobileAppShortcutState]()
    /// At most one explicit write per app. The token prevents a late result
    /// from an old account/session from publishing into a newer Store view.
    @ObservationIgnored private var appShortcutWriteOperations = [AppCatalogID: UUID]()
    /// Each explicit write advances its app twice: once before its first await
    /// and once when the attempt finishes. A refresh may publish an app only
    /// when this value still equals the revision it captured before reading.
    @ObservationIgnored private var appShortcutMutationRevisions = [AppCatalogID: UInt64]()
    /// Only the latest refresh pass may publish. A newer overlapping refresh,
    /// account invalidation or session replacement retires every older pass.
    @ObservationIgnored private var appShortcutRefreshEpoch: UInt64 = 0
    /// The platform's official-accounts answer. A failed read keeps the last
    /// good answer; an unknown answer never creates a Founder chat or draws a
    /// mark.
    private(set) var officialAccountsRead = NativeRead<OfficialAccountsResponse>()
    /// Single-flight and bounded failure retry for the current account's
    /// official-accounts read. Its value cache remains `officialAccountsRead`.
    @ObservationIgnored private var officialAccountsCadence = OfficialAccountsRetryCadence()
    /// Bumped whenever the bearer-owning native client object changes. It is
    /// part of the cadence scope so a discarded old-client completion cannot
    /// release or complete the new client's in-flight read.
    @ObservationIgnored private var officialAccountsClientGeneration: UInt64 = 0
    /// The one joined, account-marked Founder room this account may show.
    private(set) var founderRoomID: String?
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
    /// read while no chat exists. Opening it creates nothing; the first message makes the room.
    private(set) var founderDraftAvailable = false
    /// The Founder's Matrix profile avatar, loaded from the exact room member.
    /// Marked Founder surfaces render the bundled raven; this metadata never
    /// grants the mark or overrides that local art.
    private(set) var founderAvatarURL: String?
    @ObservationIgnored private var founderBoundUserID: String?
    @ObservationIgnored private var founderChatMarker = MobileFounderPolicy.ChatMarker.unknown
    @ObservationIgnored private var founderEnsureInFlight = false
    /// A room this device created but could not record yet. It is retried on
    /// the next readiness callback; it is never invented after a restart.
    @ObservationIgnored private var founderUnrecordedRoomID: String?
    private var appWorkspaces = [String: AppWorkspaceSnapshot]()
    private struct AppOnboardingAttempt {
        let id: UUID
        let slug: String
        let accountGeneration: UInt64
        let disclosureVersion: Int64
        /// Whether the person has agreed yet. A retry never goes past the
        /// disclosure on its own before they have.
        var gate: AppOnboardingGate
        var mode: AppStartPolicy.Mode = .linked
        var nonce: AppLinkNonce?
        var initiationID: NativeID?
    }
    @ObservationIgnored private var appOnboardingAttempt: AppOnboardingAttempt?
    @ObservationIgnored private var appOnboardingTask: Task<Void, Never>?
    @ObservationIgnored private var appLinkPresenter: AppLinkWebAuthPresenter?
    @ObservationIgnored private var appAccountGeneration: UInt64 = 0
    @ObservationIgnored private var appAccountInstallationID: UUID?
    /// The last launch attempt, for the spaced foreground retry (W4 E3).
    @ObservationIgnored private var lastLaunchAttemptAt: Date?
    /// What the last failed launch showed (W4 E3); nil after a launch that
    /// opened a session.
    private(set) var launchFailureOutcome: MobileSessionContinuityPolicy.LaunchOutcome?
    /// W4 E3: automatic renewals back off after failures and stop when
    /// custody refuses (`MobileSessionContinuityPolicy.RenewalRetry`).
    @ObservationIgnored private var renewalRetry = MobileSessionContinuityPolicy.RenewalRetry()
    @ObservationIgnored private var lastRenewalResult = MobileSessionContinuityPolicy.RenewalResult.superseded
    /// Set on entering the background; the next activation is a return.
    @ObservationIgnored private var returningFromBackground = false
    @ObservationIgnored private var scenePhaseToken: LiveScenePhaseRelay.Token?

    private let marker = OIDCInstallationMarker()
    private let recovery = MatrixRecoveryKeychain()
    private let recoverySavedStore = LiveRecoverySavedStore()
    @ObservationIgnored private let localSignOut = try? LocalSignOutCoordinator()
    private let transport = MASHTTP()
    /// The vendored copy pack, read once for the roster's waiting line.
    private let copyCatalog = try? AtumCopy()
    private var clients: MASPublicClients?
    private var metadata: MASMetadata?
    private var context: Context? {
        didSet {
            if oldValue?.runtime.ticket.session.userID != context?.runtime.ticket.session.userID {
                applePurchases.bind(accountID: nil, api: nil)
            }
        }
    }
    private var bootstrapTask: Task<Void, Never>?
    private var productTask: Task<Void, Never>?
    /// One placement request per sign-in product start (owner decision
    /// 2026-10-19: a new account's assistant runs in the cloud at sign-up,
    /// phone-first included). It never gates sign-in, and a failure is retried
    /// by the next sign-in.
    private var assistantPlacementTask: Task<Void, Never>?
    private var assistantLifecycleCapability: AgentLifecycleCapability?
    /// A refused cloud Stop is not offered again until product facts refresh.
    /// Transport loss remains retryable with the state machine's same UUID.
    private var assistantTurnStopUnavailable = Set<NativeID>()
    private var assistantLifecycleStore: LiveAssistantLifecycleStore?
    @ObservationIgnored private var assistantLifecycleTask: Task<Void, Never>?
    /// Identifies an interactive begin/resume across suspension points. The
    /// token is process-local; the request UUID remains the sole durable state.
    @ObservationIgnored private var assistantLifecycleOperationToken: UUID?
    /// Bumped when the signed-in account or live session is replaced. A
    /// lifecycle begin/resume from an older generation can never publish a
    /// room or clear another account's retained UUID.
    @ObservationIgnored private var assistantLifecycleGeneration: UInt64 = 0
    private var isRefreshingProduct = false
    private(set) var domainRecoveryState = MobileDomainRecoveryState.temporarilyUnavailable
    private(set) var domainReauthenticationInProgress = false
    /// Non-UI purchase owner. API origin remains the client's fixed build origin.
    /// Sandbox TestFlight integration must supply the approved sandbox origin first.
    @ObservationIgnored lazy var applePurchases = ApplePurchaseCoordinator(
        store: StoreKitPurchaseStore(), environment: .production,
        refreshWallet: { [weak self] in await self?.refreshApplePurchaseWallet() }
    )

    private func refreshApplePurchaseWallet() async {
        guard let client = domainClient else { return }
        let result = await readWallet(using: client)
        guard domainClient === client else { return }
        apply(result, to: &walletRead)
    }

    private var domainClient: NativeDomainClient? {
        didSet {
            let replaced: Bool
            switch (oldValue, domainClient) {
            case (nil, nil): replaced = false
            case let (old?, new?): replaced = old !== new
            default: replaced = true
            }
            guard replaced else { return }
            applePurchases.bind(accountID: context?.runtime.ticket.session.userID, api: domainClient)
            assistantTurnStopUnavailable.removeAll()
            officialAccountsClientGeneration &+= 1
            officialAccountsCadence.activate(nil)
            if let accountID = context?.runtime.ticket.session.userID {
                officialAccountsCadence.activate(.init(
                    accountID: accountID,
                    generation: officialAccountsClientGeneration
                ))
            }
        }
    }
    /// A38: the per-account acknowledged zone for the roster read, and the
    /// one system-time-zone observer, which reuses the foreground refresh.
    @ObservationIgnored private let ownerTimeZone = OwnerTimeZoneBookkeeper()
    @ObservationIgnored private var timeZoneObserver: OwnerTimeZoneChangeObserver?
    private var agentsRead = NativeRead<AgentsResponse>()
    private var appsRead = NativeRead<AppCatalogResponse>()
    private var storeCatalogRead = NativeRead<StoreCatalogResponse>()
    private var walletRead = NativeRead<WalletResponse>()
    private var routineSnapshots = [NativeID: AgentRoutinesSnapshot]()
    private var lastLoggedRecoveryState: String?
    private var hiddenRooms = MobileHiddenRoomLedger()
    private var homeHoldExpired = false
    @ObservationIgnored private var homeHoldTask: Task<Void, Never>?
    /// The last complete chat list from disk, painted before the room list
    /// and the catalog reads answer. Presentation only; it never opens a
    /// room or performs a room action on its own.
    private(set) var cachedChatList = [ChatListSnapshot.Room]()
    @ObservationIgnored private var cachedChatListAccountID: String?
    @ObservationIgnored private let chatListSnapshots = ChatListSnapshotStore()
    private var hiddenRoomStore: LiveHiddenRoomStore?
    @ObservationIgnored private var loggedAgentRoomChoices = [String: String]()
    @ObservationIgnored private var attemptedInvites = Set<String>()
    /// A target gets at most one Matrix create attempt in this live session.
    /// A retry after an ambiguous transport outcome only observes sync, so a
    /// double tap or timeout cannot fork a second direct room.
    @ObservationIgnored private var attemptedDirectTargets = Set<String>()
    /// App-bot chats this session created (bot user ID to room ID), and the
    /// bots it already tried to create one for. A retry reuses the room, and a
    /// bot is never sent a second create while the first may still be landing.
    @ObservationIgnored private var createdAppBotChats = [String: String]()
    @ObservationIgnored private var attemptedAppBotChatTargets = Set<String>()
    /// The room IDs visible before each group operation. A retry after an
    /// ambiguous response watches for a matching new room and never creates
    /// again during this live session.
    @ObservationIgnored private var attemptedGroupBaselines = [String: Set<String>]()
    private var suppressedInvitationIDs = Set<String>()
    private var invitationDeclinesAwaitingReplacement = Set<String>()
    private var pendingRoomMutations = [RoomMutationKey: PendingRoomMutation]()
    @ObservationIgnored private var nextRoomMutationGeneration: UInt64 = 0
    @ObservationIgnored private var roomPublicationRevision: UInt64 = 0
    @ObservationIgnored private var roomMutationQueue = RoomMutationQueue<RoomMutationKey>()
    @ObservationIgnored private var pushConsidered = false
    /// S3: the phone's in-memory pusher identity; removed on sign-out and on
    /// token rotation. Never persisted, never logged.
    @ObservationIgnored private let push = MobilePushCoordinator()
    /// The one in-flight runtime renewal; every caller joins it.
    private let matrixRenewal = MobileSingleFlight()
    @ObservationIgnored private var lastRenewalAttemptAt: Date?
    @ObservationIgnored private var isSceneActive = false
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var keepAliveGeneration: UInt64 = 0
    private let pushPromptStore = LivePushPromptStore()
    /// Team Space (B19 S4): the company directory, channels, members and the
    /// leave journal. It holds no authority; every action re-reads the
    /// platform and every 1.1 shape is refused rather than widened.
    private(set) var companyWorkspace = CompanyWorkspaceModel()
    /// Personal Drive is its own third grant and account cache. Company files
    /// remain exclusively in the company authority flow.
    private(set) var drive = DriveFeatureModel()
    @ObservationIgnored private var driveSession: LiveDriveSession?
    /// The rooms of a company the person just left; the root pops the open
    /// chat when it is one of them.
    private(set) var companyLeftRooms = Set<String>()
    private(set) var companyLeftToken: UInt64 = 0
    private(set) var accountScopeGeneration: UInt64 = 0
    @ObservationIgnored private var companyConfigured = false
    @ObservationIgnored private var companyAccountID: String?

    private enum RoomMutationKind: Hashable {
        case unread
        case pinned
        case muted
        case lowPriority
    }

    private struct RoomMutationKey: Hashable {
        let roomID: String
        let kind: RoomMutationKind
    }

    private struct Context {
        let installation: OIDCInstallation
        let sessionStore: MatrixSessionKeychain
        let domainStore: OIDCDomainKeychain
        let runtime: MatrixLiveRuntime
        let domainRefresh: OIDCGrantRefresh?
    }

    private final class LiveDriveSession {
        let generation: UUID
        let account: OIDCRestoredAccount
        let cache: DriveCache
        let store: OIDCDriveKeychain
        var legacyGrantCleaned = false
        var domainClient: NativeDomainClient?
        var client: DriveClient?
        var activationFlight: Task<LiveDriveAccess, Never>?

        init(generation: UUID, account: OIDCRestoredAccount, cache: DriveCache,
             store: OIDCDriveKeychain) {
            self.generation = generation
            self.account = account
            self.cache = cache
            self.store = store
        }
    }

    func presentation() -> LiveProductPresentation {
        let rows = productRooms()
        return LiveProductPresentation(
            rooms: LiveProductRoomList(availability: roomAvailability(rows: rows),
                                       rooms: rows),
            store: storePresentation,
            notificationPrompt: notificationPromptVisible
        )
    }

    /// W4 E3: the account offers the quiet recovery row (its key backup is
    /// not open on this phone, and old history can open here at all).
    var offersHistoryRecovery: Bool {
        matrixRecoverySnapshot?.recovery == .available
            && context?.runtime.oldHistoryUnavailable != true
    }

    /// The platform-named Founder, never a name or avatar heuristic.
    var founderUserID: String? { officialAccountsRead.value?.founder?.userID }

    var founderHandle: String? { officialAccountsRead.value?.founderHandle }

    var founderRoster: OfficialFounderRoster? { officialAccountsRead.value?.founderRoster }

    /// The Founder's own account has no Founder row, no automatic creation and
    /// no Contact us entry.
    var isFounderAccount: Bool {
        guard let founderUserID else { return false }
        return founderUserID == context?.runtime.ticket.session.userID
    }

    /// Contact us exists only for another person's account while the platform
    /// names a Founder. The server answer is the whole authority.
    var founderContactAvailable: Bool {
        guard founderUserID != nil, !isFounderAccount, let matrix = liveMatrix else {
            return false
        }
        return FirstRunMarkerReadiness.canRead(sessionReady: matrix.isReady,
                                               completedInitialSync: matrix.hasCompletedInitialSync)
    }

    /// The local Founder words from the pinned copy bundle. Missing copy keeps
    /// a safe English fallback; no invented disclosure or encryption claim.
    private var founderName: String {
        founderText("src.matrix.founder.founder-copy.FOUNDER_COPY.name", fallback: "Founder")
    }

    private var founderSubtitle: String {
        founderText("src.matrix.founder.founder-copy.FOUNDER_COPY.subtitle",
                    fallback: "Atum founder")
    }

    var founderContactTitle: String {
        founderText("src.matrix.founder.founder-copy.FOUNDER_COPY.contactTitle",
                    fallback: "Contact us")
    }

    /// The Founder draft's words and its one row. Present only while the platform offers the
    /// Founder and this account has no chat: opening it is a local act, the first message makes
    /// the room (Element's create-the-DM-on-first-message).
    struct FounderDraftPresentation: Equatable {
        let name: String
        let subtitle: String
        let intro: String
        let unready: String
    }

    var founderDraftPresentation: FounderDraftPresentation? {
        guard founderDraftAvailable else { return nil }
        return FounderDraftPresentation(
            name: founderName,
            subtitle: founderSubtitle,
            intro: founderText("src.matrix.founder.founder-copy.FOUNDER_COPY.intro",
                               fallback: "Questions, ideas or problems? Message me here. I usually reply within a day."),
            unready: founderText("src.matrix.founder.founder-copy.FOUNDER_COPY.unready",
                                 fallback: "Founder can't receive messages yet. Nothing was sent; try again in a little while.")
        )
    }

    /// The Home row for the draft. Its row ID is not a room ID, so nothing can open, join,
    /// mute or pin it; tapping it presents the local draft.
    var founderDraftRow: LiveProductRoom? {
        guard let presentation = founderDraftPresentation else { return nil }
        return LiveProductRoom(
            id: MobileFounderPolicy.draftRowID,
            kind: .people,
            title: presentation.name,
            detail: presentation.subtitle,
            previewContent: .text(presentation.subtitle),
            avatar: .monogram(LiveProductAvatar.fallbackMonogram(for: presentation.name)),
            appVerification: .official,
            isFounder: true
        )
    }

    /// One creation shared by every send tapped while it runs; a failed attempt can be tried
    /// again, a made chat is kept.
    @ObservationIgnored private lazy var founderDraftOpen = MobileFounderPolicy.DraftOpen { [weak self] in
        await self?.contactFounder()
    }

    /// The draft's first send: its room (made here or found on another device), never a second.
    func openFounderDraftRoom() async -> String? {
        await founderDraftOpen.room()
    }

    /// Puts the person's first message into the chat that just opened for it. A chat opened
    /// in the gap (another row, a notification) is a different room and never receives it.
    @discardableResult
    func sendInOpenConversation(_ body: String, roomID: String) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let conversation,
              MobileFounderPolicy.draftSendAllowed(roomID: roomID,
                                                   conversationRoomID: conversation.roomID) else {
            return false
        }
        conversation.draft = text
        conversation.send()
        return true
    }

    /// The empty-chat card exists only for the one room bound from this
    /// account's marker to the platform-named Founder. It is not inferred
    /// from the room's display name, handle or avatar.
    func founderIntroPresentation(roomID: String) -> FounderIntroPresentation? {
        guard let founderUserID,
              let room = liveMatrix?.rooms.first(where: { $0.roomID == roomID }),
              room.memberCount <= 2,
              room.memberUserIDs.isEmpty || room.memberUserIDs.contains(founderUserID) else {
            return nil
        }
        return FounderIntroPresentation.exactRoom(
            roomID: roomID,
            founderRoomID: founderRoomID,
            isFounderAccount: isFounderAccount,
            name: founderName,
            subtitle: founderSubtitle,
            intro: founderText("src.matrix.founder.founder-copy.FOUNDER_COPY.intro",
                               fallback: "Questions, ideas or problems? Message me here. I usually reply within a day.")
        )
    }

    private func founderText(_ key: String, fallback: String) -> String {
        guard let copyCatalog else { return fallback }
        let locale = copyCatalog.locales.contains(appLanguage) ? appLanguage : "en"
        return (try? copyCatalog.text(key, locale: locale)) ?? fallback
    }

    /// B30: the quiet `wifi.slash` glyph in the chat's navigation bar while
    /// sync is offline or in error (`SessionLifecycle`), and while a session
    /// that failed is suspended and kept on screen (W4 E3) until a renewal
    /// brings it back. Never during the second or two of a renewal.
    var showsConnectionGlyph: Bool {
        guard case .signedIn = stage, let liveMatrix else { return false }
        if let lifecycle = liveMatrix.lifecycle { return lifecycle.showsConnectionGlyph }
        return liveMatrix.error != nil && !isRenewingMatrixSession
    }

    /// How this phone is connected, for Settings > This iPhone. It follows the
    /// same session lifecycle as the quiet offline glyph, so the two never
    /// disagree; before sync has started it is "connecting".
    var accountConnection: AccountConnectionState {
        guard case .signedIn = stage, let liveMatrix else { return .connecting }
        if let lifecycle = liveMatrix.lifecycle {
            switch lifecycle.syncState {
            case .running: return .ready
            case .offline: return .offline
            case .error: return .error
            case .idle, .terminated: return .connecting
            }
        }
        switch liveMatrix.error {
        case nil: return liveMatrix.isReady ? .ready : .connecting
        case .offline?: return .offline
        case _?: return isRenewingMatrixSession ? .connecting : .error
        }
    }

    func avatarThumbnail(uri: String, pixelSide: Int) async -> Data? {
        guard let liveMatrix else { return nil }
        return await liveMatrix.avatarThumbnail(uri: uri, pixelSide: pixelSide)
    }

    func mediaThumbnail(sourceHandle: String, pixelWidth: Int, pixelHeight: Int) async -> Data? {
        guard let liveMatrix else { return nil }
        return await liveMatrix.mediaThumbnail(sourceHandle: sourceHandle,
                                               pixelWidth: pixelWidth,
                                               pixelHeight: pixelHeight)
    }

    func mediaContent(sourceHandle: String) async -> Data? {
        guard let liveMatrix else { return nil }
        return await liveMatrix.mediaContent(sourceHandle: sourceHandle)
    }

    func mediaFile(sourceHandle: String, filename: String?, mimetype: String) async -> LiveMediaFile? {
        guard let liveMatrix else { return nil }
        return await liveMatrix.mediaFile(sourceHandle: sourceHandle,
                                          filename: filename,
                                          mimetype: mimetype)
    }

    func maximumMediaUploadSize() async -> UInt64 {
        guard let liveMatrix else { return AttachmentPreparer.fallbackUploadLimit }
        return await liveMatrix.maximumMediaUploadSize() ?? AttachmentPreparer.fallbackUploadLimit
    }

    func currentRecoveryKey() -> String? {
        do {
            if let current = context {
                return try recovery.currentInput(session: current.runtime.ticket,
                                                 sessionStore: current.sessionStore,
                                                 marker: marker)?.recoveryKey
            }
            return try contextlessRecoveryState().input?.recoveryKey
        } catch {
            return nil
        }
    }

    func markRecoveryKeySaved() {
        if let installation = context?.installation, holdsRecoveryKey {
            recoverySavedStore.markSaved(installationID: installation.id)
            recoveryKeySavedOnThisPhone = true
            return
        }
        guard let state = try? contextlessRecoveryState(), state.input != nil,
              let installation = state.installation else { return }
        recoverySavedStore.markSaved(installationID: installation.id)
        recoveryKeySavedOnThisPhone = true
    }

    /// A status screen has no live Matrix runtime from which to derive the
    /// usual Account presentation. Inspect only the exact marker-bound local
    /// recovery envelope. Any unreadable or mismatched inventory is treated as
    /// requiring the save sheet, so the escape fails closed.
    var statusRequiresRecoverySave: Bool {
        if context != nil {
            return holdsRecoveryKey && !recoveryKeySavedOnThisPhone
        }
        do {
            let state = try contextlessRecoveryState()
            return StatusRecoverySignOutPolicy.requiresSave(
                hasRecoveryKey: state.input != nil, saved: state.saved
            )
        } catch {
            return true
        }
    }

    /// S6 local sign-out. The view has already obtained any required explicit
    /// save confirmation. Remote token revocation is deliberately not part of
    /// this local data-loss boundary.
    @discardableResult
    func signOut(confirmedRecoverySaved: Bool) async -> Bool {
        guard !signOutInProgress, let current = context, let localSignOut else {
            signOutFailureToken &+= 1
            return false
        }
        if holdsRecoveryKey && !(confirmedRecoverySaved || recoveryKeySavedOnThisPhone) {
            signOutFailureToken &+= 1
            return false
        }
        signOutInProgress = true
        applePurchases.bind(accountID: nil, api: nil)
        defer {
            if let domainClient, let accountID = context?.runtime.ticket.session.userID {
                applePurchases.bind(accountID: accountID, api: domainClient)
            }
        }
        await withdrawDrive(current, reason: .signOut)
        invalidateAppAccount()
        closeConversation()
        productTask?.cancel(); productTask = nil
        assistantPlacementTask?.cancel(); assistantPlacementTask = nil
        cancelAssistantLifecycle()
        homeHoldTask?.cancel(); homeHoldTask = nil
        keepAliveTask?.cancel(); keepAliveTask = nil
        roomMutationQueue.cancelAll(); pendingRoomMutations = [:]
        // S3: delete the phone's pusher before anything about the session is
        // ended, so the call still authenticates. Best effort: a failure is
        // logged without the token and sign-out proceeds.
        await removePushForSignOut(using: current.runtime)
        if let liveMatrix { await liveMatrix.stop() }
        liveMatrix = nil
        await current.runtime.pause()

        do {
            _ = try localSignOut.signOut(
                installation: current.installation,
                session: current.runtime.ticket,
                sessionStore: current.sessionStore,
                domainStore: current.domainStore,
                recoveryStore: recovery,
                confirmedRecoverySaved: confirmedRecoverySaved || recoveryKeySavedOnThisPhone
            )
            recoverySavedStore.clear(installationID: current.installation.id)
            context = nil
            domainClient = nil
            firstRunMarkerCoordinator?.reset()
            firstRunMarkerCoordinator = nil
            firstRunMarker = .unknown
            ownerTimeZone.end(clearStoredValue: true)
            agentsRead.clear(); appsRead.clear(); storeCatalogRead.clear(); walletRead.clear()
            assistantLifecycleCapability = nil
            assistantLifecycleStore = nil
            clearCompanyAccountScope()
            routineSnapshots.removeAll()
            holdsRecoveryKey = false
            recoveryKeySavedOnThisPhone = false
            clearChatListSnapshot()
            await clearAccountCaches()
            signOutInProgress = false
            stage = .signedOut(nil)
            return true
        } catch let failure as LocalSignOutFailure where failure == .rollbackIncomplete {
            // Active and quarantined records may be split. Never reopen a
            // runtime against that uncertain namespace; bootstrap resumes the
            // person's already-authorized transaction forward from its
            // non-secret journal.
            context = nil
            domainClient = nil
            assistantLifecycleCapability = nil
            assistantLifecycleStore = nil
            clearCompanyAccountScope()
            signOutInProgress = false
            signOutFailureToken &+= 1
            launchFailureOutcome = .retryLaunch
            stage = .unavailable
            return false
        } catch {
            // A staging failure rolls the active namespace back. Recompose the
            // current product instead of pretending sign-out succeeded.
            context = current
            signOutInProgress = false
            signOutFailureToken &+= 1
            publishSignedIn(current)
            return false
        }
    }

    /// O4's escape from the quiet can't-connect screen. If bootstrap already
    /// opened an exact session, use the ordinary transactional sign-out. If
    /// it failed before that context existed, move any blocking credentials
    /// and marker into the lossless stranded-session archive instead. The
    /// Matrix store and a surviving recovery key are deliberately retained;
    /// the person reaches Welcome without an unsafe broad delete.
    @discardableResult
    func signOutFromStatus(confirmedRecoverySaved: Bool) async -> Bool {
        if context != nil {
            return await signOut(confirmedRecoverySaved: confirmedRecoverySaved)
        }
        guard !signOutInProgress,
              stage == .recoveryRequired || stage == .unavailable else {
            signOutFailureToken &+= 1
            return false
        }
        signOutInProgress = true
        do {
            let recoveryState = try contextlessRecoveryState()
            guard StatusRecoverySignOutPolicy.authorizesArchive(
                hasRecoveryKey: recoveryState.input != nil,
                saved: recoveryState.saved,
                confirmedSaved: confirmedRecoverySaved
            ) else {
                throw LocalSignOutFailure.confirmationRequired
            }
            await withdrawContextlessDrive(reason: .signOut)
            _ = try StrandedSessionArchive(marker: marker).archive()
            if let installation = recoveryState.installation {
                recoverySavedStore.clear(installationID: installation.id)
            }
            ownerTimeZone.end(clearStoredValue: true)
            clearAssistantLifecycle()
            clearCompanyAccountScope()
            launchFailureOutcome = nil
            holdsRecoveryKey = false
            recoveryKeySavedOnThisPhone = false
            clearChatListSnapshot()
            await clearAccountCaches()
            signOutInProgress = false
            stage = .signedOut(nil)
            return true
        } catch {
            signOutInProgress = false
            signOutFailureToken &+= 1
            return false
        }
    }

    private func contextlessRecoveryState() throws -> (
        installation: OIDCInstallation?, input: MatrixRecoveryInput?, saved: Bool
    ) {
        guard context == nil else { throw MatrixRecoveryFailure.identityChanged }
        guard let installation = try marker.load() else {
            // A recovery survivor without its original marker may be the sole
            // copy but cannot be attributed safely. Refuse the escape instead
            // of archiving around it.
            try recovery.requireAbsentForExplicitSignIn()
            return (nil, nil, false)
        }
        let input = try recovery.currentInput(installation: installation, marker: marker)
        return (installation, input,
                input != nil && recoverySavedStore.isSaved(installationID: installation.id))
    }

    var pushRoutingReady: Bool {
        guard case .signedIn = stage, let liveMatrix else { return false }
        return !liveMatrix.isLoadingRooms && (liveMatrix.isReady || liveMatrix.error != nil)
    }

    var joinedPinnedRoomCount: Int {
        var pinned = Set((liveMatrix?.rooms ?? []).filter(\.isFavourite).map(\.roomID))
        for (key, mutation) in pendingRoomMutations where key.kind == .pinned {
            guard liveMatrix?.rooms.contains(where: { $0.roomID == key.roomID }) == true else { continue }
            if mutation.desired { pinned.insert(key.roomID) }
            else { pinned.remove(key.roomID) }
        }
        return pinned.count
    }

    func canOpenPushedRoom(_ roomID: String) -> Bool {
        // A room that only claims the conversation type has no directory record: it never opens.
        !companyWorkspace.isQuarantinedConversation(roomID)
            && productRooms().contains { $0.id == roomID && $0.canOpen && !$0.isInvitation }
    }

    /// Whether a notification for this room may be shown in the foreground. A room that only claims
    /// the company conversation type has no directory record behind it, so nothing of it shows.
    func presentsNotification(roomID: String) -> Bool {
        !companyWorkspace.isQuarantinedConversation(roomID)
    }

    var canAddFriend: Bool {
        domainClient != nil && context != nil && liveMatrix?.isReady == true
    }

    var canCreateGroup: Bool { canAddFriend }

    /// The platform's lifecycle capability is the only authority for creating
    /// an assistant from the phone. A retained UUID keeps the action available
    /// while its setup is still pending, so Retry never starts a second one.
    var canCreateAssistant: Bool {
        guard canAddFriend, assistantLifecycleStore != nil else { return false }
        return hasPendingAssistantLifecycle || assistantLifecycleCapability?.available == true
            && assistantLifecycleCapability?.disclosureVersion != nil
    }

    var hasPendingAssistantLifecycle: Bool { assistantLifecycleStore?.pending() != nil }

    var groupCandidates: [HomeGroupCandidate] {
        guard let matrix = liveMatrix, let ownUserID = context?.runtime.ticket.session.userID else { return [] }
        let excluded = Set(
            [ownUserID]
                + (agentsRead.value?.agents.compactMap { $0.matrixUser?.rawValue } ?? [])
                + (appsRead.value?.apps.compactMap { $0.bot?.userID.rawValue } ?? [])
        )
        var newest = [String: (candidate: HomeGroupCandidate, timestamp: UInt64)]()
        for room in matrix.rooms where room.isDirect && room.memberCount <= 2 {
            for userID in room.memberUserIDs where !excluded.contains(userID) {
                let timestamp = room.latestTimestamp ?? 0
                if newest[userID]?.timestamp ?? 0 > timestamp { continue }
                let profile = room.memberProfiles.first { $0.userID == userID }
                newest[userID] = (
                    HomeGroupCandidate(id: userID, name: profile?.displayName ?? room.displayName,
                                       kind: .person, avatarURL: profile?.avatarURL),
                    timestamp
                )
            }
        }
        let locale = Locale(identifier: appLanguage)
        return newest.values.map(\.candidate).sorted {
            $0.name.compare($1.name, options: [.caseInsensitive, .diacriticInsensitive],
                            range: nil, locale: locale) == .orderedAscending
        }
    }

    /// One owner-account-scoped Unicode request UUID drives begin, retry,
    /// termination and resume. A retry never edits itself into a second
    /// assistant: while a UUID is pending the name is ignored and the same
    /// operation resumes. The phone never paints a synthetic assistant or
    /// room; success is only the authoritative joined room.
    func createAssistant(_ typedName: String) async -> HomeAssistantCreateResult {
        guard canCreateAssistant, let client = domainClient, let session = liveMatrix,
              let current = context, let store = assistantLifecycleStore,
              session.isReady else { return .unavailable }
        guard assistantLifecycleTask == nil,
              assistantLifecycleOperationToken == nil else { return .starting }
        let existing = store.pending()
        let name = typedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing != nil || (1...40).contains(name.count)
                && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return .failed }
        guard let requestID = existing ?? (try? NativeID(UUID().uuidString.lowercased())) else {
            return .failed
        }
        let begin: AgentLifecycleBegin?
        if existing == nil {
            guard let disclosure = assistantLifecycleCapability?.disclosureVersion else {
                return .unavailable
            }
            do {
                begin = try AgentLifecycleBegin(
                    requestId: requestID, displayName: name,
                    ownerDevice: current.runtime.ticket.session.deviceID,
                    disclosureVersion: disclosure
                )
            } catch { return .failed }
        } else {
            begin = nil
        }
        if existing == nil { store.save(requestID) }
        let generation = assistantLifecycleGeneration
        let operationToken = UUID()
        assistantLifecycleOperationToken = operationToken
        defer {
            if assistantLifecycleOperationToken == operationToken {
                assistantLifecycleOperationToken = nil
            }
        }
        LiveFlowLog.creation(.assistant, outcome: existing == nil ? "begin" : "resume")
        let initial: AgentLifecycleSnapshot
        do {
            if let begin {
                initial = try await client.beginAgentLifecycle(begin)
            } else {
                initial = try await client.resumeAgentLifecycle(AgentLifecycleResume(requestId: requestID))
            }
        } catch let failure as NativeDomainClientFailure {
            guard assistantLifecycleIsCurrent(requestID: requestID, client: client,
                                              session: session, store: store,
                                              generation: generation) else { return .starting }
            switch failure {
            case let .assistantName(reason):
                store.clear(requestID)
                LiveFlowLog.creation(.assistant, outcome: "refused", code: reason.rawValue)
                return .name(reason)
            case let .http(http) where existing != nil && http.response.error == .notFound:
                store.clear(requestID)
                LiveFlowLog.creation(.assistant, outcome: "missing", code: "matrix_404")
                return .failed
            case let .http(http) where ["capacity_unavailable", "entitlement_required",
                                        "consent_required", "unavailable", "limit"].contains(
                                            http.response.details?.reason ?? ""
                                        ):
                store.clear(requestID)
                LiveFlowLog.creation(.assistant, outcome: "unavailable",
                                     code: http.response.details?.reason
                                         ?? http.response.error.rawValue)
                return .unavailable
            default:
                LiveFlowLog.creation(.assistant, outcome: "starting", code: "retry_pending")
                return .starting
            }
        } catch {
            guard assistantLifecycleIsCurrent(requestID: requestID, client: client,
                                              session: session, store: store,
                                              generation: generation) else { return .starting }
            LiveFlowLog.creation(.assistant, outcome: "starting", code: "retry_pending")
            return .starting
        }
        guard assistantLifecycleGeneration == generation,
              domainClient === client, liveMatrix === session,
              context?.runtime === current.runtime else {
            return .starting
        }
        return await finishAssistantLifecycle(initial, requestID: requestID,
                                              client: client, session: session, store: store,
                                              generation: generation)
    }

    private func finishAssistantLifecycle(_ first: AgentLifecycleSnapshot,
                                          requestID: NativeID,
                                          client: NativeDomainClient,
                                          session: LiveMatrixSession,
                                          store: LiveAssistantLifecycleStore,
                                          generation: UInt64) async -> HomeAssistantCreateResult {
        var snapshot = first
        var authoritativeAgent: AgentsResponse.Agent?
        var didSubmitExactJoin = false
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard assistantLifecycleIsCurrent(requestID: requestID, client: client,
                                              session: session, store: store,
                                              generation: generation),
                  !Task.isCancelled else { return .starting }
            if let assistant = snapshot.assistant {
                if authoritativeAgent == nil, let response = try? await client.agents() {
                    guard assistantLifecycleIsCurrent(requestID: requestID, client: client,
                                                      session: session, store: store,
                                                      generation: generation),
                          !Task.isCancelled else { return .starting }
                    agentsRead.receive(response)
                    authoritativeAgent = HomeAssistantLifecyclePolicy.authoritativeAgent(
                        for: snapshot, in: response.agents
                    )
                }
                if let roomID = snapshot.roomID,
                   let matrixUser = assistant.matrixUser?.rawValue {
                    if let invite = session.invites.first(where: {
                        $0.roomID == roomID && $0.inviterID == matrixUser
                    }), !didSubmitExactJoin {
                        // A lifecycle invite can arrive before `/agents`
                        // publishes the new assistant. Generic invite handling
                        // may then classify it as human-owned; the exact
                        // lifecycle authority is allowed to reclaim only this
                        // room/inviter pair.
                        attemptedInvites.insert(invite.roomID)
                        let joined = await session.acceptInvite(roomID: invite.roomID)
                        guard assistantLifecycleIsCurrent(requestID: requestID, client: client,
                                                          session: session, store: store,
                                                          generation: generation),
                              !Task.isCancelled else { return .starting }
                        if joined {
                            didSubmitExactJoin = true
                        } else {
                            attemptedInvites.remove(invite.roomID)
                        }
                    }
                    if let joinedRoomID = HomeAssistantLifecyclePolicy.joinedRoomID(
                        for: snapshot, authoritativeAgent: authoritativeAgent,
                        rooms: session.rooms
                    ) {
                        store.clear(requestID)
                        LiveFlowLog.creation(.assistant, outcome: "ready")
                        return .openRoom(joinedRoomID)
                    }
                }
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return .starting }
            do {
                snapshot = try await client.resumeAgentLifecycle(
                    AgentLifecycleResume(requestId: requestID)
                )
            } catch let failure as NativeDomainClientFailure {
                if case let .http(http) = failure, http.response.error == .notFound {
                    guard assistantLifecycleIsCurrent(requestID: requestID, client: client,
                                                      session: session, store: store,
                                                      generation: generation),
                          !Task.isCancelled else { return .starting }
                    store.clear(requestID)
                    LiveFlowLog.creation(.assistant, outcome: "missing", code: "matrix_404")
                    return .failed
                }
                LiveFlowLog.creation(.assistant, outcome: "starting", code: "resume_pending")
                return .starting
            } catch {
                LiveFlowLog.creation(.assistant, outcome: "starting", code: "resume_pending")
                return .starting
            }
        }
        LiveFlowLog.creation(.assistant, outcome: "starting", code: "room_pending")
        return .starting
    }

    /// A launch or foreground return resumes the one retained UUID when both
    /// account services are ready. A definitive 404 clears it; every transient
    /// outcome keeps it for the next attempt.
    private func startPendingAssistantLifecycleResume() {
        guard assistantLifecycleTask == nil,
              assistantLifecycleOperationToken == nil,
              let requestID = assistantLifecycleStore?.pending(),
              let client = domainClient, let session = liveMatrix,
              let store = assistantLifecycleStore, session.isReady else { return }
        let generation = assistantLifecycleGeneration
        assistantLifecycleTask = Task { @MainActor [weak self, weak session] in
            defer {
                if self?.assistantLifecycleGeneration == generation {
                    self?.assistantLifecycleTask = nil
                }
            }
            guard let self, let session,
                  self.liveMatrix === session,
                  self.assistantLifecycleGeneration == generation else { return }
            do {
                let snapshot = try await client.resumeAgentLifecycle(
                    AgentLifecycleResume(requestId: requestID)
                )
                guard self.assistantLifecycleGeneration == generation,
                      self.liveMatrix === session else { return }
                _ = await self.finishAssistantLifecycle(snapshot, requestID: requestID,
                                                        client: client, session: session,
                                                        store: store, generation: generation)
            } catch let failure as NativeDomainClientFailure {
                if case let .http(http) = failure, http.response.error == .notFound {
                    guard !Task.isCancelled,
                          self.assistantLifecycleIsCurrent(
                            requestID: requestID, client: client, session: session,
                            store: store, generation: generation
                          ) else { return }
                    store.clear(requestID)
                }
            } catch { }
        }
    }

    private func assistantLifecycleIsCurrent(requestID: NativeID,
                                             client: NativeDomainClient,
                                             session: LiveMatrixSession,
                                             store: LiveAssistantLifecycleStore,
                                             generation: UInt64) -> Bool {
        assistantLifecycleGeneration == generation
            && domainClient === client
            && liveMatrix === session
            && store.pending() == requestID
    }

    /// Cancel the in-flight observer and fence everything it may still return.
    /// The retained UUID itself lives in the account-scoped defaults ledger, so
    /// signing out does not lose a pending setup for that same account.
    private func cancelAssistantLifecycle() {
        assistantLifecycleTask?.cancel()
        assistantLifecycleTask = nil
        assistantLifecycleOperationToken = nil
        assistantLifecycleGeneration &+= 1
    }

    private func clearAssistantLifecycle() {
        cancelAssistantLifecycle()
        assistantLifecycleCapability = nil
        assistantLifecycleStore = nil
    }

    func searchPeople(_ query: String) async -> [HomeGroupCandidate]? {
        guard let session = liveMatrix, let results = await session.searchPeople(query),
              liveMatrix === session, !Task.isCancelled else { return nil }
        let nonPeople = Set((agentsRead.value?.agents.compactMap { $0.matrixUser?.rawValue } ?? [])
            + (appsRead.value?.apps.compactMap { $0.bot?.userID.rawValue } ?? []))
        var people = results.filter { !nonPeople.contains($0.id) }
        // The phone currently has only exact forward alias lookup. Enrich a
        // matching SDK result, never bypass directory visibility with an alias hit.
        if let handle = HomeAddFriendPolicy.handle(query), let client = domainClient,
           let lookup = try? await client.aliasLookup(handle: handle),
           case let .assigned(assignment) = lookup,
           let index = people.firstIndex(where: { $0.id == assignment.matrixUser?.rawValue }) {
            people[index].handle = assignment.handle.rawValue
        }
        guard liveMatrix === session, !Task.isCancelled else { return nil }
        return people
    }

    func openPerson(_ userID: String) async -> HomeAddFriendResult {
        guard let target = try? NativeMatrixUser(userID), let session = liveMatrix,
              target.rawValue != context?.runtime.ticket.session.userID else { return .notMessageable }
        return await openDirectPerson(target, session: session)
    }

    /// Exact handle lookup followed by reuse-or-create. No roster row is
    /// synthesized: success is returned only after the current Matrix room
    /// list publishes the joined room.
    func addFriend(_ rawHandle: String) async -> HomeAddFriendResult {
        guard let handle = HomeAddFriendPolicy.handle(rawHandle),
              let client = domainClient,
              let session = liveMatrix,
              let ownUserID = context?.runtime.ticket.session.userID,
              session.isReady else { return .searchFailed }

        let lookup: AliasLookupResponse
        do {
            lookup = try await client.aliasLookup(handle: handle)
        } catch let failure as NativeDomainClientFailure {
            if case let .http(http) = failure, http.response.error == .rateLimited {
                return .rateLimited(http.retryAfterSeconds.flatMap(Int.init(exactly:)))
            }
            return .searchFailed
        } catch {
            return .searchFailed
        }
        guard liveMatrix === session, !Task.isCancelled else { return .searchFailed }

        guard case let .assigned(assignment) = lookup else {
            return .notFound(handle.rawValue)
        }
        guard assignment.kind == .human,
              let target = assignment.matrixUser,
              target.rawValue != ownUserID else { return .notMessageable }

        return await openDirectPerson(target, session: session)
    }

    private func openDirectPerson(_ target: NativeMatrixUser, session: LiveMatrixSession) async -> HomeAddFriendResult {
        if let roomID = HomeAddFriendPolicy.existingRoomID(
            in: session.rooms, matrixUserID: target.rawValue
        ) {
            return .openRoom(roomID)
        }

        guard attemptedDirectTargets.insert(target.rawValue).inserted else {
            if let roomID = await waitForDirectRoom(with: target.rawValue, session: session) {
                return .openRoom(roomID)
            }
            return .startFailed
        }

        if let roomID = await session.createDirectRoom(inviting: target) {
            guard let published = await waitForDirectRoom(
                with: target.rawValue, preferredRoomID: roomID, session: session
            ) else { return .startFailed }
            return .openRoom(published)
        }

        // The request may have reached the homeserver before transport failed.
        // Observe sync, but never issue a second create in this live session.
        if let roomID = await waitForDirectRoom(with: target.rawValue, session: session) {
            return .openRoom(roomID)
        }
        return .startFailed
    }

    func lookupGroupPerson(_ rawHandle: String) async -> HomeGroupLookupResult {
        guard let handle = HomeAddFriendPolicy.handle(rawHandle),
              let client = domainClient,
              let session = liveMatrix,
              let ownUserID = context?.runtime.ticket.session.userID,
              session.isReady else { return .failed }
        do {
            let result = try await client.aliasLookup(handle: handle)
            guard liveMatrix === session, !Task.isCancelled else { return .failed }
            guard case let .assigned(assignment) = result else {
                return .notFound(handle.rawValue)
            }
            guard assignment.kind == .human,
                  let matrixUser = assignment.matrixUser,
                  matrixUser.rawValue != ownUserID else { return .notMessageable }
            let known = groupCandidates.first(where: { $0.id == matrixUser.rawValue })
            let profile = await session.personProfile(userID: matrixUser.rawValue)
            guard liveMatrix === session, !Task.isCancelled else { return .failed }
            var candidate = known ?? profile ?? HomeGroupCandidate(
                id: matrixUser.rawValue, name: matrixUser.rawValue, kind: .person)
            candidate.handle = assignment.handle.rawValue
            return .candidate(candidate)
        } catch let failure as NativeDomainClientFailure {
            if case let .http(http) = failure, http.response.error == .rateLimited {
                return .rateLimited(http.retryAfterSeconds.flatMap(Int.init(exactly:)))
            }
            return .failed
        } catch {
            return .failed
        }
    }

    func createGroup(_ typedName: String,
                     selected: [HomeGroupCandidate]) async -> HomeGroupCreateResult {
        guard let session = liveMatrix,
              let ownUserID = context?.runtime.ticket.session.userID,
              session.isReady,
              selected.count <= HomeGroupPolicy.maximumInvites,
              Set(selected.map(\.id)).count == selected.count,
              selected.allSatisfy({ $0.kind == .person }),
              let name = HomeGroupPolicy.name(typed: typedName, selected: selected)
        else { return .failed }
        let targets: [NativeMatrixUser]
        do {
            targets = try selected.map { try NativeMatrixUser($0.id) }
        } catch {
            return .failed
        }
        guard targets.allSatisfy({ $0.rawValue != ownUserID }) else { return .failed }

        let fingerprint = HomeGroupPolicy.fingerprint(name: name, selected: selected)
        let baseline: Set<String>
        if let existing = attemptedGroupBaselines[fingerprint] {
            baseline = existing
        } else {
            baseline = Set(session.rooms.map(\.roomID))
            attemptedGroupBaselines[fingerprint] = baseline
            if let roomID = await session.createGroup(name: name, inviting: targets) {
                if let published = await waitForGroup(
                    named: name, preferredRoomID: roomID, excluding: baseline, session: session
                ) { return .openRoom(published) }
                return .failed
            }
        }

        if let roomID = await waitForGroup(named: name, excluding: baseline, session: session) {
            return .openRoom(roomID)
        }
        return .failed
    }

    private func waitForGroup(named name: String,
                              preferredRoomID: String? = nil,
                              excluding baseline: Set<String>,
                              session: LiveMatrixSession) async -> String? {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard liveMatrix === session, !Task.isCancelled else { return nil }
            if let preferredRoomID,
               session.rooms.contains(where: { $0.roomID == preferredRoomID }) {
                return preferredRoomID
            }
            if let room = session.rooms.first(where: {
                !baseline.contains($0.roomID) && !$0.isDirect && $0.displayName == name
            }) { return room.roomID }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return nil }
        }
        return nil
    }

    /// Waits (at most 10 s) for this exact room to appear in the session's room
    /// list. False when it did not, or the session was replaced.
    private func waitForRoom(_ roomID: String, session: LiveMatrixSession) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard liveMatrix === session, !Task.isCancelled else { return false }
            if session.rooms.contains(where: { $0.roomID == roomID }) { return true }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
        }
        return false
    }

    private func waitForDirectRoom(with matrixUserID: String,
                                   preferredRoomID: String? = nil,
                                   session: LiveMatrixSession) async -> String? {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard liveMatrix === session, !Task.isCancelled else { return nil }
            if let preferredRoomID,
               session.rooms.contains(where: { $0.roomID == preferredRoomID }) {
                return preferredRoomID
            }
            if let roomID = HomeAddFriendPolicy.existingRoomID(
                in: session.rooms, matrixUserID: matrixUserID
            ) { return roomID }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return nil }
        }
        return nil
    }

    func scrollConversationToLatest() {
        conversation?.handle(.jumpTapped)
    }

    func setRoomUnread(_ roomID: String, isUnread: Bool) {
        let sharing = shareActivity
        beginRoomMutation(roomID: roomID, kind: .unread, desired: isUnread) { session in
            await session.setUnread(roomID: roomID, isUnread: isUnread, shareActivity: sharing)
        }
    }

    /// The owner changed Settings › Privacy. Optimistic: the switch moves
    /// now and goes back if the account-data write fails.
    func setShareActivity(_ sharing: Bool) async -> Bool {
        let previous = shareActivity
        shareActivity = sharing
        conversation?.setShareActivity(sharing)
        guard let session = liveMatrix, session.isReady else {
            shareActivity = previous
            conversation?.setShareActivity(previous)
            return false
        }
        let succeeded = await session.setShareActivity(sharing)
        guard liveMatrix === session else { return succeeded }
        if !succeeded {
            shareActivity = previous
            conversation?.setShareActivity(previous)
        }
        return succeeded
    }

    private func refreshShareActivity() async {
        guard let session = liveMatrix, session.isReady else { return }
        let value = await session.readShareActivity()
        guard liveMatrix === session else { return }
        shareActivity = value
    }

    func setRoomPinned(_ roomID: String, isPinned: Bool) {
        if isPinned, joinedPinnedRoomCount >= RosterProjection.pinLimit {
            recordRoomActionFailure(roomID)
            return
        }
        beginRoomMutation(roomID: roomID, kind: .pinned, desired: isPinned) { session in
            await session.setPinned(roomID: roomID, isPinned: isPinned)
        }
    }

    func setRoomMuted(_ roomID: String, isMuted: Bool) {
        beginRoomMutation(roomID: roomID, kind: .muted, desired: isMuted) { session in
            await session.setMuted(roomID: roomID, isMuted: isMuted)
        }
    }

    func setRoomLowPriority(_ roomID: String, isLowPriority: Bool) {
        beginRoomMutation(roomID: roomID, kind: .lowPriority, desired: isLowPriority) { session in
            await session.setLowPriority(roomID: roomID, isLowPriority: isLowPriority)
        }
    }

    /// The side panel's facts for a chat (M2): when it began, the
    /// Team Spaces you share with the other person, the ignore list, and the
    /// room's power levels for the Members page. Nil when there's no session.
    func chatPanelDetails(roomID: String) async -> ChatInfoDetails? {
        guard let liveMatrix, let read = await liveMatrix.panelDetails(roomID: roomID),
              self.liveMatrix === liveMatrix else { return nil }
        let ownUserID = conversation?.ownUserID
        var details = ChatInfoDetails(
            startedAt: read.createdAt.map { Date(timeIntervalSince1970: Double($0) / 1_000) },
            ignoredUserIDs: read.ignoredUserIDs,
            members: read.members.map {
                .init(userID: $0.userID, name: $0.displayName, matrixAvatarURI: $0.avatarURL,
                      power: $0.power, membership: $0.membership)
            }
        )
        if let own = read.ownPower, let kick = read.kickLevel, let ban = read.banLevel {
            details.moderation = ChatMemberModeration(ownPower: own, kickLevel: kick, banLevel: ban)
        }
        // A person chat: the Team Spaces whose rooms you are both joined to.
        if conversation?.roomID == roomID, conversation?.kind == .person,
           let peer = read.members.first(where: { $0.userID != ownUserID && $0.membership == .joined }) {
            var names = [String]()
            for company in companyWorkspace.companyRooms()
            where await liveMatrix.isJoined(userID: peer.userID, inAnyOf: company.roomIDs) {
                names.append(company.name)
            }
            guard self.liveMatrix === liveMatrix else { return nil }
            details.teamSpaces = names
        }
        return details
    }

    /// Remove, ban or unban someone in a group's Members page.
    func moderateMember(roomID: String, userID: String, action: ChatMemberAction) async -> Bool {
        guard let liveMatrix else { return false }
        let succeeded = await liveMatrix.moderate(roomID: roomID, userID: userID, action: action)
        return succeeded && self.liveMatrix === liveMatrix
    }

    func declineInvitation(_ roomID: String) {
        guard let liveMatrix,
              productRooms().contains(where: { $0.id == roomID && $0.isInvitation }) else { return }
        suppressedInvitationIDs.insert(roomID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let succeeded = await liveMatrix.declineInvite(roomID: roomID)
            // A replacement session will authoritatively republish invitations;
            // keep the row suppressed until that publication resolves the
            // unknown outcome instead of flashing it with a false error.
            guard self.liveMatrix === liveMatrix else {
                self.invitationDeclinesAwaitingReplacement.insert(roomID)
                return
            }
            if !succeeded {
                self.suppressedInvitationIDs.remove(roomID)
                self.recordRoomActionFailure(roomID)
            }
        }
    }

    /// "Delete chat" / "Leave group" (`ChatExitPolicy`). The row disappears once
    /// the room list publishes the leave; a failure says so on the row.
    func exitRoom(_ roomID: String, _ action: ChatExitAction) {
        guard let liveMatrix else { return }
        Task { @MainActor [weak self] in
            let succeeded = await liveMatrix.exit(roomID: roomID, forget: action == .deleteChat)
            guard let self, self.liveMatrix === liveMatrix else { return }
            if !succeeded { self.recordRoomActionFailure(roomID) }
        }
    }

    /// Ignore or unignore a person (Matrix `m.ignored_user_list`).
    func setIgnored(userID: String, ignored: Bool) async -> Bool {
        guard let liveMatrix else { return false }
        return await liveMatrix.setIgnored(userID: userID, ignored: ignored)
    }

    func ignoredPeople() async -> [IgnoredPerson]? {
        await liveMatrix?.ignoredPeople()
    }

    /// Hides an app room only in this phone's ledger. The Matrix room and its
    /// history stay intact, and every duplicate room for the same app bot is
    /// hidden with it so the synthetic app row reopens the canonical choice.
    func hideAppRoom(_ roomID: String) {
        hideAppRooms(startingAt: roomID, outcome: "hidden_from_delete")
    }

    /// The phone first run appears only in the real default assistant's open
    /// chat, only while the account-wide marker is still unseen, and only with
    /// a live, current marker owner. It never renames an existing assistant
    /// automatically and never manufactures `Atum Bot`.
    func firstRunContext(roomID: String) -> FirstRunContext? {
        guard firstRunMarker == .unseen,
              case let .signedIn(account) = stage,
              let current = context,
              let matrix = liveMatrix,
              FirstRunMarkerReadiness.canRead(sessionReady: matrix.isReady,
                                              completedInitialSync: matrix.hasCompletedInitialSync),
              let owner = firstRunMarkerCoordinator,
              owner.isCurrent,
              let agent = firstRunAgent(roomID: roomID),
              conversation?.roomID == roomID,
              conversation?.kind == .assistant,
              let room = matrix.rooms.first(where: { $0.roomID == roomID }),
              botUserID(for: room) == nil else { return nil }

        let accountID = current.runtime.ticket.session.userID
        let deviceID = current.runtime.ticket.session.deviceID
        let persistedName = agent.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !persistedName.isEmpty else { return nil }

        return FirstRunContext(
            accountID: accountID,
            deviceID: deviceID,
            assistantID: agent.id.rawValue,
            marker: firstRunMarker,
            personDisplayName: account.displayName,
            persistedAssistantName: persistedName,
            assistantIsDefault: agent.isDefault
        )
    }

    private func firstRunAgent(roomID: String) -> AgentsResponse.Agent? {
        guard let agent = agentForRoom(roomID), agent.isDefault, agent.status == .active else { return nil }
        return agent
    }

    private func firstRunMarkerCoordinator(for current: Context,
                                           matrix: LiveMatrixSession) -> FirstRunMarkerCoordinator {
        if let existing = firstRunMarkerCoordinator, existing.isCurrent { return existing }
        let owner = FirstRunMarkerCoordinator(io: .init(
            read: {
                try await current.runtime.client.accountData(
                    eventType: FirstRunMarkerRecord.eventType
                )
            },
            write: { payload in
                try await current.runtime.client.setAccountData(
                    eventType: FirstRunMarkerRecord.eventType,
                    content: payload
                )
            },
            isCurrent: { [weak self] in
                guard let self, case .signedIn = self.stage,
                      self.context?.runtime === current.runtime,
                      self.liveMatrix === matrix,
                      FirstRunMarkerReadiness.canRead(sessionReady: matrix.isReady,
                                                      completedInitialSync: matrix.hasCompletedInitialSync) else {
                    return false
                }
                return true
            },
            nowMilliseconds: {
                Int64(Date().timeIntervalSince1970 * 1_000)
            }
        ))
        firstRunMarkerCoordinator = owner
        firstRunMarker = .unknown
        return owner
    }

    /// Reads the account-wide marker on product/foreground refresh. A failure
    /// leaves it unknown (never an offer); an existing answer is latched.
    private func refreshFirstRunMarker() async {
        guard case .signedIn = stage, let current = context, let matrix = liveMatrix,
              FirstRunMarkerReadiness.canRead(sessionReady: matrix.isReady,
                                              completedInitialSync: matrix.hasCompletedInitialSync) else {
            firstRunMarkerCoordinator?.reset()
            firstRunMarkerCoordinator = nil
            firstRunMarker = .unknown
            return
        }
        let owner = firstRunMarkerCoordinator(for: current, matrix: matrix)
        await owner.refresh()
        guard firstRunMarkerCoordinator === owner, owner.isCurrent else { return }
        firstRunMarker = owner.state
    }

    func chatInfoPresentation(roomID: String) -> ChatInfoPresentation? {
        // A company conversation has its own header and menu; its people are the platform's.
        guard !companyWorkspace.isConversationRoom(roomID) else { return nil }
        guard conversation?.roomID == roomID,
              let matrixRoom = liveMatrix?.rooms.first(where: { $0.roomID == roomID }) else { return nil }
        guard let room = productRooms().first(where: { $0.id == roomID })
            ?? conversationOpenedRoom.flatMap({ $0.id == roomID ? $0 : nil }) else { return nil }
        let appVerification = ChatInfoAppTier.presentation(room.appVerification)
        let company = companyChatInfo(roomID: roomID)
        let kind: ChatInfoPresentation.Kind = switch conversation?.kind {
        case .assistant?: .assistant
        case .appBot?: .app(appVerification)
        case .person?: .person
        case .group?:
            .group(memberCount: company.flatMap { $0.members.isEmpty ? nil : $0.members.count }
                   ?? Int(min(matrixRoom.memberCount, UInt64(Int.max))))
        case nil: .person
        }
        let knownAssistants = knownAgentAndBotUserIDs
        let appBots = catalogBotUserIDs
        let ownUserID = conversation?.ownUserID
        let assistant = kind == .assistant ? agentForRoom(roomID) : nil
        let assistantBotHandle: String? = (assistant?.slug ?? nil).flatMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let members = conversationMembers.map { member in
            ChatInfoMember(userID: member.userID, name: member.displayName,
                           matrixAvatarURI: member.avatarURL,
                           isAssistant: knownAssistants.contains(member.userID),
                           isCurrentUser: member.userID == ownUserID,
                           isApp: appBots.contains(member.userID))
        }
        return ChatInfoPresentation(
            roomID: roomID, title: room.title,
            subtitle: room.isFounder ? founderSubtitle
                : (kind == .assistant ? assistant?.title : nil),
            kind: kind,
            avatar: room.avatar, matrixAvatarURI: room.matrixAvatarURL,
            avatarSHA256: room.avatarSHA256,
            avatarCandidates: room.avatarCandidates,
            accent: Self.catalogAccent(room.appAccent),
            isPinned: room.isPinned, isMuted: room.isMuted,
            roomIsEncrypted: matrixRoom.isEncrypted != false,
            pinLimitReached: !room.isPinned && joinedPinnedRoomCount >= RosterProjection.pinLimit,
            members: company == nil ? members : [],
            actionFailureToken: roomActionFailure.roomID == roomID ? roomActionFailure.token : 0,
            company: company,
            isFounder: room.isFounder,
            founderHandle: room.isFounder ? founderHandle : nil,
            isPrimaryAssistant: assistant?.isDefault ?? false,
            botHandle: assistantBotHandle,
            topic: matrixRoom.topic,
            isLowPriority: room.isLowPriority,
            offersLowPriority: company == nil && Self.offersLowPriority(room, founderRoomID: founderRoomID)
        )
    }

    /// `RosterProjection.offersLowPriority` for one chat-list row.
    private static func offersLowPriority(_ room: LiveProductRoom, founderRoomID: String?) -> Bool {
        let kind: RosterProjection.Room.Kind
        switch room.kind {
        case .people: kind = .person
        case .group: kind = .group
        case .agent: return false
        }
        let projected = RosterProjection.Room(id: room.id, kind: kind,
                                              membership: room.isInvitation ? .invited : .joined,
                                              isFavourite: room.isPinned, isLowPriority: room.isLowPriority)
        return RosterProjection.offersLowPriority(roomID: room.id, rooms: [projected],
                                                  founderRoomID: founderRoomID)
    }

    /// What each assistant is for (the one-line title it was given), by agent
    /// ID, for Settings > Assistants.
    var assistantTitles: [String: String] {
        (agentsRead.value?.agents ?? []).reduce(into: [:]) { titles, agent in
            guard let title = agent.title, !title.isEmpty,
                  titles[agent.id.rawValue] == nil else { return }
            titles[agent.id.rawValue] = title
        }
    }

    func assistantDefinitionActions(roomID: String) -> AssistantDefinitionActions? {
        guard domainClient != nil, agentForRoom(roomID) != nil else { return nil }
        return AssistantDefinitionActions(
            read: { [weak self] in
                guard let self else { return .failed }
                return await self.readAssistantDefinition(roomID: roomID)
            },
            save: { [weak self] snapshot, definition in
                guard let self else { return .failed }
                return await self.saveAssistantDefinition(roomID: roomID,
                                                          snapshot: snapshot,
                                                          definition: definition)
            },
            rename: { [weak self] snapshot, name in
                guard let self else { return .failed }
                return await self.renameAssistantDefinition(roomID: roomID,
                                                            snapshot: snapshot, name: name)
            }
        )
    }

    func assistantModelActions(roomID: String) -> AssistantModelActions? {
        guard let accountID = context?.runtime.ticket.session.userID,
              domainClient != nil, agentForRoom(roomID) != nil else { return nil }
        return AssistantModelActions(
            matrixAccountID: accountID,
            read: { [weak self] in
                guard let self else { return .failed }
                return await self.readAssistantModels(roomID: roomID)
            },
            save: { [weak self] snapshot, model, effort, requestID in
                guard let self else { return .failed }
                return await self.saveAssistantModel(roomID: roomID, snapshot: snapshot,
                                                     model: model, effort: effort,
                                                     requestID: requestID)
            }
        )
    }

    func assistantModelDestinationActions(roomID: String) -> AssistantModelDestinationActions? {
        guard let accountID = context?.runtime.ticket.session.userID,
              domainClient != nil, agentForRoom(roomID) != nil else { return nil }
        return AssistantModelDestinationActions(
            matrixAccountID: accountID,
            read: { [weak self] in
                guard let self else { return .failed }
                return await self.readAssistantModelDestinations(roomID: roomID)
            },
            save: { [weak self] snapshot, destination, model, requestID in
                guard let self else { return .refused(nil) }
                return await self.saveAssistantModelDestination(
                    roomID: roomID, snapshot: snapshot, destination: destination,
                    model: model, requestID: requestID
                )
            }
        )
    }

    func assistantHomeActions(roomID: String) -> AssistantHomeActions? {
        guard let accountID = context?.runtime.ticket.session.userID,
              let client = domainClient, agentForRoom(roomID) != nil else { return nil }
        return AssistantHomeActions(
            matrixAccountID: accountID,
            // Owner writes are bearer-authorized on the authenticated phone channel.
            read: { [weak self] in
                guard let self else { return .failed }
                return await self.readAssistantHome(roomID: roomID)
            },
            catalog: { [weak self] deviceID in
                guard let self else { return .failed }
                return await self.readAssistantHomeCatalog(roomID: roomID, deviceID: deviceID)
            },
            preflight: { [weak self] input, requestID in
                guard let self else { return .failure(NativeDomainClientFailure.cancelled) }
                return await self.preflightAssistantHome(roomID: roomID, input: input, requestID: requestID)
            },
            move: { [weak self] input, requestID in
                guard let self else { return .failure(NativeDomainClientFailure.cancelled) }
                return await self.moveAssistantHome(roomID: roomID, input: input, requestID: requestID)
            },
            cancel: { [weak self] input, requestID in
                guard let self else { return .failure(NativeDomainClientFailure.cancelled) }
                return await self.cancelAssistantHomeMove(roomID: roomID, input: input, requestID: requestID)
            },
            progress: { [weak self] moveID in
                guard let self else { return .failure(NativeDomainClientFailure.cancelled) }
                return await self.readAssistantHomeProgress(roomID: roomID, moveID: moveID)
            },
            writeModel: { [weak self] input, requestID in
                guard let self else { return .failure(NativeDomainClientFailure.cancelled) }
                return await self.writeAssistantHomeModel(roomID: roomID, input: input, requestID: requestID)
            },
            application: { [weak self] in
                guard let self else { return nil }
                return await self.readAssistantHomeApplication(roomID: roomID)
            }
        )
    }

    private func assistantTurnStopRoute(roomID: String) -> CloudAssistantTurnStop? {
        guard conversation?.roomID == roomID, conversation?.kind == .assistant,
              liveMatrix?.isReady == true, agentsRead.condition == .fresh,
              let agent = agentForRoom(roomID) else { return nil }
        return CloudAssistantTurnStop(agent: agent, roomID: roomID,
                                      routeAvailable: domainClient != nil
                                          && !assistantTurnStopUnavailable.contains(agent.principal))
    }

    func assistantTurnStopActions(roomID: String) -> AssistantTurnStopActions? {
        guard let client = domainClient, let route = assistantTurnStopRoute(roomID: roomID) else { return nil }
        let generation = assistantLifecycleGeneration
        return AssistantTurnStopActions { [weak self] intent in
            guard let self, self.domainClient === client,
                  self.assistantLifecycleGeneration == generation,
                  self.assistantTurnStopRoute(roomID: roomID) == route else { return .failed }
            var unavailable = false
            let result = await route.stop(intent, using: client, onRouteUnavailable: { unavailable = true })
            guard self.domainClient === client, self.assistantLifecycleGeneration == generation,
                  self.assistantTurnStopRoute(roomID: roomID) == route else { return .failed }
            if unavailable { self.assistantTurnStopUnavailable.insert(route.agentPrincipal) }
            return result
        }
    }

    func assistantAvatarActions(roomID: String) -> AssistantAvatarActions? {
        guard domainClient != nil, agentForRoom(roomID) != nil else { return nil }
        return AssistantAvatarActions(save: { [weak self] image in
            guard let self else { return .failed }
            return await self.saveAssistantAvatar(roomID: roomID, image: image)
        })
    }

    func assistantPresentationActions(roomID: String) -> AssistantPresentationActions? {
        guard domainClient != nil, agentForRoom(roomID) != nil else { return nil }
        return AssistantPresentationActions(
            read: { [weak self] in
                guard let self else { return .failed }
                return await self.readAssistantPresentation(roomID: roomID)
            },
            save: { [weak self] snapshot, title, mark in
                guard let self else { return .failed }
                return await self.saveAssistantPresentation(roomID: roomID, snapshot: snapshot,
                                                            title: title, mark: mark)
            }
        )
    }

    func assistantRoutineActions(roomID: String) -> AssistantRoutineActions? {
        guard domainClient != nil, let agent = agentForRoom(roomID) else { return nil }
        return AssistantRoutineActions(
            scope: agent.id.rawValue,
            read: { [weak self] in
                guard let self else { return .failed }
                return await self.readAssistantRoutines(roomID: roomID)
            },
            create: { [weak self] value in
                guard let self else { return .failed }
                return await self.createAssistantRoutine(roomID: roomID, value: value)
            },
            update: { [weak self] value in
                guard let self else { return .failed }
                return await self.updateAssistantRoutine(roomID: roomID, value: value)
            },
            run: { [weak self] value in
                guard let self else { return .failed }
                return await self.runAssistantRoutine(roomID: roomID, value: value)
            },
            delete: { [weak self] value in
                guard let self else { return .failed }
                return await self.deleteAssistantRoutine(roomID: roomID, value: value)
            },
            runs: { [weak self] routineID in
                guard let self else { return .failed }
                return await self.readAssistantRoutineRuns(roomID: roomID, routineID: routineID)
            }
        )
    }

    private func readAssistantDefinition(roomID: String) async -> AssistantDefinitionLoadResult {
        guard let client = domainClient, let agent = agentForRoom(roomID) else { return .failed }
        do {
            let value = try await client.agentDefinition(assistantID: agent.id)
            guard domainClient === client, agentForRoom(roomID)?.id == agent.id else { return .failed }
            return .value(value)
        } catch {
            return .failed
        }
    }

    private func saveAssistantDefinition(roomID: String,
                                         snapshot: AgentDefinitionSnapshot,
                                         definition: PortableAssistantDefinition)
        async -> AssistantDefinitionSaveResult {
        guard let client = domainClient, let agent = agentForRoom(roomID),
              snapshot.assistant.id == agent.id else { return .failed }
        do {
            let write = try AgentDefinitionWrite(snapshot: snapshot, definition: definition)
            let value = try await client.writeAgentDefinition(assistantID: agent.id, value: write)
            guard domainClient === client, agentForRoom(roomID)?.id == agent.id else { return .failed }
            return .saved(value)
        } catch let failure as NativeDomainClientFailure {
            guard case let .http(http) = failure, http.response.error == .conflict else { return .failed }
            let latest = try? await client.agentDefinition(assistantID: agent.id)
            guard domainClient === client, agentForRoom(roomID)?.id == agent.id else { return .failed }
            return .conflict(latest)
        } catch {
            return .failed
        }
    }

    private func renameAssistantDefinition(roomID: String,
                                           snapshot: AgentDefinitionSnapshot,
                                           name: String) async -> AssistantRenameResult {
        guard let client = domainClient, let agent = agentForRoom(roomID),
              snapshot.assistant.id == agent.id,
              let definition = snapshot.definition else { return .failed }
        do {
            let write = try AgentDefinitionWrite(snapshot: snapshot, displayName: name,
                                                 definition: definition)
            let value = try await client.writeAgentDefinition(assistantID: agent.id, value: write)
            guard domainClient === client, agentForRoom(roomID)?.id == agent.id else { return .failed }
            return .renamed(value)
        } catch let failure as NativeDomainClientFailure {
            switch failure {
            case let .assistantName(reason):
                return .refused(reason)
            case let .http(http) where http.response.error == .conflict:
                let latest = try? await client.agentDefinition(assistantID: agent.id)
                guard domainClient === client, agentForRoom(roomID)?.id == agent.id else {
                    return .failed
                }
                return .conflict(latest)
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    private func readAssistantModels(roomID: String) async -> AssistantModelLoadResult {
        guard let client = domainClient, let agent = agentForRoom(roomID) else { return .failed }
        do {
            let value = try await client.managedModels(agentPrincipal: agent.principal)
            guard domainClient === client, agentForRoom(roomID)?.principal == agent.principal else { return .failed }
            return .value(value)
        } catch let failure as NativeDomainClientFailure {
            if case let .http(http) = failure,
               http.response.error == .unavailable || http.response.error == .denied {
                return .unavailable
            }
            return .failed
        } catch {
            return .failed
        }
    }

    private func saveAssistantModel(roomID: String,
                                    snapshot: ManagedModelSnapshot,
                                    model: String,
                                    effort: ManagedModelEffort,
                                    requestID: NativeID) async -> AssistantModelSaveResult {
        guard let client = domainClient, let agent = agentForRoom(roomID),
              snapshot.agentPrincipal == agent.principal else { return .failed }
        do {
            let write = try ManagedModelWrite(requestId: requestID, snapshot: snapshot,
                                              model: model, effort: effort)
            let value = try await client.writeManagedModel(agentPrincipal: agent.principal,
                                                           value: write)
            guard domainClient === client, agentForRoom(roomID)?.principal == agent.principal else { return .failed }
            return .saved(value)
        } catch let failure as NativeDomainClientFailure {
            guard case let .http(http) = failure, http.response.error == .conflict else { return .failed }
            let latest = try? await client.managedModels(agentPrincipal: agent.principal)
            guard domainClient === client, agentForRoom(roomID)?.principal == agent.principal else { return .failed }
            return .conflict(latest)
        } catch {
            return .failed
        }
    }

    private func readAssistantModelDestinations(roomID: String) async
        -> AssistantModelDestinationLoadResult {
        guard let client = domainClient, let agent = agentForRoom(roomID) else { return .failed }
        do {
            async let destinationRead = client.managedModelDestinations(agentPrincipal: agent.principal)
            async let offerRead = try? client.managedModels(agentPrincipal: agent.principal)
            let snapshot = try await destinationRead
            let offer = await offerRead
            guard domainClient === client,
                  agentForRoom(roomID)?.principal == agent.principal else { return .failed }
            let eligible: Set<String> = Set((offer?.models ?? []).compactMap { model -> String? in
                guard model.eligibility == .ready,
                      ManagedModelLineup.servedAliases.contains(model.alias) else { return nil }
                return model.alias
            })
            return .value(AssistantModelDestinationValue(snapshot: snapshot,
                                                         cloudEligibleAliases: eligible))
        } catch let failure as NativeDomainClientFailure {
            if case let .http(http) = failure,
               [.notFound, .denied, .unavailable].contains(http.response.error) {
                return .unavailable
            }
            return .failed
        } catch {
            return .failed
        }
    }

    private func readAssistantHome(roomID: String) async -> AssistantHomeLoadResult {
        guard let client = domainClient, let agent = agentForRoom(roomID) else { return .failed }
        do {
            let snapshot = try await client.agentHome(agentPrincipal: agent.principal)
            async let destinationsRead = client.managedModelDestinations(agentPrincipal: agent.principal)
            async let cloudRead = client.managedModels(agentPrincipal: agent.principal)
            let application: AgentHomeModelApplication?
            if snapshot.placement.location.deviceID != nil {
                application = try? await client.agentHomeModelApplication(agentPrincipal: agent.principal)
            } else { application = nil }
            let destinations = try await destinationsRead
            let cloud = try await cloudRead
            guard domainClient === client, agentForRoom(roomID)?.principal == agent.principal,
                  snapshot.placement.agentPrincipal == agent.principal,
                  application.map({ $0.homeID == snapshot.placement.homeID
                      && $0.homeEpoch == snapshot.placement.homeEpoch }) ?? true else { return .failed }
            return .value(AssistantHomeValue(snapshot: snapshot, destinations: destinations,
                                             cloudModels: cloud, application: application,
                                             choiceOverride: nil, pendingNextTurn: false))
        } catch let failure as NativeDomainClientFailure {
            if case let .http(http) = failure,
               [.notFound, .denied, .unavailable].contains(http.response.error) { return .unavailable }
            return .failed
        } catch { return .failed }
    }

    private func readAssistantHomeCatalog(roomID: String, deviceID: NativeID) async
        -> AssistantHomeCatalogResult {
        guard let client = domainClient, let agent = agentForRoom(roomID) else { return .failed }
        do {
            let catalog = try await client.agentHomeCatalog(agentPrincipal: agent.principal,
                                                            deviceServiceID: deviceID)
            guard domainClient === client, agentForRoom(roomID)?.principal == agent.principal else { return .failed }
            return .value(catalog)
        } catch let failure as NativeDomainClientFailure {
            if case let .http(http) = failure,
               [.notFound, .denied, .unavailable].contains(http.response.error) { return .unavailable }
            return .failed
        } catch { return .failed }
    }

    private func preflightAssistantHome(roomID: String, input: AgentHomePreflightInput,
                                        requestID: NativeID) async
        -> Result<AgentHomeMovePreflight, Error> {
        guard let client = domainClient, let agent = agentForRoom(roomID),
              input.agentPrincipal == agent.principal else {
            return .failure(NativeDomainClientFailure.invalidRequest)
        }
        do {
            let result = try await client.preflightAgentHomeMove(input, requestID: requestID)
            guard domainClient === client, agentForRoom(roomID)?.principal == agent.principal,
                  result.common.agentPrincipal == agent.principal else {
                return .failure(NativeDomainClientFailure.invalidResponse)
            }
            return .success(result)
        } catch { return .failure(error) }
    }

    private func moveAssistantHome(roomID: String, input: AgentHomeMoveInput,
                                   requestID: NativeID) async
        -> Result<AgentHomeMoveCommandResult, Error> {
        guard let client = domainClient, let agent = agentForRoom(roomID),
              input.agentPrincipal == agent.principal else {
            return .failure(NativeDomainClientFailure.invalidRequest)
        }
        do {
            let result = try await client.moveAgentHome(input, requestID: requestID)
            guard domainClient === client, agentForRoom(roomID)?.principal == agent.principal else {
                return .failure(NativeDomainClientFailure.invalidResponse)
            }
            return .success(result)
        } catch { return .failure(error) }
    }

    private func cancelAssistantHomeMove(roomID: String, input: AgentHomeCancelInput,
                                         requestID: NativeID) async
        -> Result<AgentHomeMoveCommandResult, Error> {
        guard let client = domainClient, let agent = agentForRoom(roomID),
              input.agentPrincipal == agent.principal else {
            return .failure(NativeDomainClientFailure.invalidRequest)
        }
        do {
            let result = try await client.cancelAgentHomeMove(input, requestID: requestID)
            guard domainClient === client, agentForRoom(roomID)?.principal == agent.principal else {
                return .failure(NativeDomainClientFailure.invalidResponse)
            }
            return .success(result)
        } catch { return .failure(error) }
    }

    private func readAssistantHomeProgress(roomID: String, moveID: NativeID) async
        -> Result<AgentHomeMoveProgress, Error> {
        guard let client = domainClient, let agent = agentForRoom(roomID) else {
            return .failure(NativeDomainClientFailure.invalidRequest)
        }
        do {
            let result = try await client.agentHomeMoveProgress(agentPrincipal: agent.principal,
                                                                moveID: moveID)
            guard domainClient === client, agentForRoom(roomID)?.principal == agent.principal else {
                return .failure(NativeDomainClientFailure.invalidResponse)
            }
            return .success(result)
        } catch { return .failure(error) }
    }

    private func writeAssistantHomeModel(roomID: String, input: AgentHomeModelChoiceInput,
                                         requestID: NativeID) async
        -> Result<AgentHomeModelChoiceResult, Error> {
        guard let client = domainClient, let agent = agentForRoom(roomID),
              input.agentPrincipal == agent.principal else {
            return .failure(NativeDomainClientFailure.invalidRequest)
        }
        do {
            let result = try await client.writeAgentHomeModelChoice(input, requestID: requestID)
            guard domainClient === client, agentForRoom(roomID)?.principal == agent.principal else {
                return .failure(NativeDomainClientFailure.invalidResponse)
            }
            return .success(result)
        } catch { return .failure(error) }
    }

    private func readAssistantHomeApplication(roomID: String) async -> AgentHomeModelApplication? {
        guard let client = domainClient, let agent = agentForRoom(roomID) else { return nil }
        let result = try? await client.agentHomeModelApplication(agentPrincipal: agent.principal)
        guard domainClient === client, agentForRoom(roomID)?.principal == agent.principal else { return nil }
        return result
    }

    private func saveAssistantModelDestination(roomID: String,
                                               snapshot: ManagedModelDestinationSnapshot,
                                               destination: ManagedModelDestinationID,
                                               model: String,
                                               requestID: NativeID) async
        -> AssistantModelDestinationSaveResult {
        guard let client = domainClient, let agent = agentForRoom(roomID),
              snapshot.agentPrincipal == agent.principal else { return .refused(nil) }
        do {
            let write = try ManagedModelDestinationWrite(
                requestId: requestID, snapshot: snapshot,
                destination: destination, model: model
            )
            let value = try await client.writeManagedModelDestination(
                agentPrincipal: agent.principal, value: write
            )
            guard domainClient === client,
                  agentForRoom(roomID)?.principal == agent.principal else { return .refused(nil) }
            return .saved(value)
        } catch let failure as NativeDomainClientFailure {
            guard case let .http(http) = failure,
                  http.response.error == .conflict else { return .refused(nil) }
            let latest = try? await client.managedModelDestinations(agentPrincipal: agent.principal)
            guard domainClient === client,
                  agentForRoom(roomID)?.principal == agent.principal else { return .refused(nil) }
            return .refused(latest)
        } catch {
            return .refused(nil)
        }
    }

    private func saveAssistantAvatar(roomID: String,
                                     image: AgentAvatarImage?) async -> AssistantAvatarSaveResult {
        guard let client = domainClient, let agent = agentForRoom(roomID) else { return .failed }
        do {
            _ = try await client.writeAgentAvatar(
                assistantID: agent.id,
                value: AgentAvatarWrite(targetPrincipal: agent.principal, avatar: image)
            )
            guard domainClient === client, agentForRoom(roomID)?.id == agent.id else { return .failed }
            await refreshProduct()
            return .saved
        } catch {
            return .failed
        }
    }

    private func readAssistantPresentation(roomID: String) async -> AssistantPresentationLoadResult {
        guard let client = domainClient, let agent = agentForRoom(roomID) else { return .failed }
        do {
            let value = try await client.agentPresentation(assistantID: agent.id)
            guard domainClient === client, agentForRoom(roomID)?.id == agent.id,
                  value.assistantPrincipal == agent.principal else { return .failed }
            return .value(value)
        } catch {
            return .failed
        }
    }

    private func saveAssistantPresentation(roomID: String,
                                           snapshot: AgentPresentationSnapshot,
                                           title: String?, mark: AgentMark)
        async -> AssistantPresentationSaveResult {
        guard let client = domainClient, let agent = agentForRoom(roomID),
              snapshot.assistantID == agent.id,
              snapshot.assistantPrincipal == agent.principal else { return .failed }
        do {
            let write = try AgentPresentationWrite(snapshot: snapshot, title: title, mark: mark)
            let value = try await client.writeAgentPresentation(assistantID: agent.id, value: write)
            guard domainClient === client, agentForRoom(roomID)?.id == agent.id,
                  value.assistantPrincipal == agent.principal else { return .failed }
            await refreshProduct()
            return .saved(value)
        } catch let failure as NativeDomainClientFailure {
            guard case let .http(http) = failure, http.response.error == .conflict else { return .failed }
            let latest = try? await client.agentPresentation(assistantID: agent.id)
            guard domainClient === client, agentForRoom(roomID)?.id == agent.id else { return .failed }
            return .conflict(latest)
        } catch {
            return .failed
        }
    }

    private func readAssistantRoutines(roomID: String) async -> AssistantRoutineLoadResult {
        guard let client = domainClient, let agent = agentForRoom(roomID) else { return .failed }
        do {
            let value = try await client.agentRoutines(assistantID: agent.id)
            guard domainClient === client, agentForRoom(roomID)?.id == agent.id,
                  value.assistantPrincipal == agent.principal else { return .failed }
            routineSnapshots[agent.id] = value
            return .value(value)
        } catch { return .failed }
    }

    private func createAssistantRoutine(roomID: String, value: AgentRoutineCreate)
        async -> AssistantRoutineMutationResult {
        await mutateAssistantRoutine(roomID: roomID) { client, assistantID in
            .upsert(try await client.createAgentRoutine(assistantID: assistantID, value: value))
        }
    }

    private func updateAssistantRoutine(roomID: String, value: AgentRoutineUpdate)
        async -> AssistantRoutineMutationResult {
        await mutateAssistantRoutine(roomID: roomID) { client, assistantID in
            .upsert(try await client.updateAgentRoutine(assistantID: assistantID, value: value))
        }
    }

    private func runAssistantRoutine(roomID: String, value: AgentRoutineAction)
        async -> AssistantRoutineMutationResult {
        guard value.operation == .run else { return .failed }
        return await mutateAssistantRoutine(roomID: roomID) { client, assistantID in
            .upsert(try await client.runAgentRoutine(assistantID: assistantID, value: value))
        }
    }

    private func deleteAssistantRoutine(roomID: String, value: AgentRoutineAction)
        async -> AssistantRoutineMutationResult {
        guard value.operation == .delete else { return .failed }
        return await mutateAssistantRoutine(roomID: roomID) { client, assistantID in
            try await client.deleteAgentRoutine(assistantID: assistantID, value: value)
            return .delete(value.routineId)
        }
    }

    private enum RoutineCacheChange { case upsert(AgentRoutine), delete(NativeID) }

    private func mutateAssistantRoutine(
        roomID: String,
        operation: (NativeDomainClient, NativeID) async throws -> RoutineCacheChange
    ) async -> AssistantRoutineMutationResult {
        guard let client = domainClient, let agent = agentForRoom(roomID) else { return .failed }
        do {
            let change = try await operation(client, agent.id)
            let latest: AgentRoutinesSnapshot
            do {
                latest = try await client.agentRoutines(assistantID: agent.id)
            } catch {
                let current = routineSnapshots[agent.id]
                var rows = current?.routines ?? []
                switch change {
                case let .upsert(routine):
                    if let index = rows.firstIndex(where: { $0.id == routine.id }) { rows[index] = routine }
                    else { rows.append(routine) }
                case let .delete(id): rows.removeAll { $0.id == id }
                }
                latest = try AgentRoutinesSnapshot(
                    assistantID: agent.id, assistantPrincipal: agent.principal,
                    serverTime: Int64(Date().timeIntervalSince1970 * 1_000),
                    legacyState: current?.legacyState ?? .clear, routines: rows
                )
            }
            guard domainClient === client, agentForRoom(roomID)?.id == agent.id,
                  latest.assistantPrincipal == agent.principal else { return .failed }
            routineSnapshots[agent.id] = latest
            return .saved(latest)
        } catch let failure as NativeDomainClientFailure {
            guard case let .http(http) = failure, http.response.error == .conflict else { return .failed }
            let latest = try? await client.agentRoutines(assistantID: agent.id)
            guard domainClient === client, agentForRoom(roomID)?.id == agent.id else { return .failed }
            if let latest { routineSnapshots[agent.id] = latest }
            return .conflict(latest)
        } catch { return .failed }
    }

    private func readAssistantRoutineRuns(roomID: String, routineID: NativeID)
        async -> AssistantRoutineRunsResult {
        guard let client = domainClient, let agent = agentForRoom(roomID) else { return .failed }
        do {
            let value = try await client.agentRoutineRuns(assistantID: agent.id, routineID: routineID)
            guard domainClient === client, agentForRoom(roomID)?.id == agent.id else { return .failed }
            return .value(value)
        } catch { return .failed }
    }

    private func agentForRoom(_ roomID: String) -> AgentsResponse.Agent? {
        guard let room = liveMatrix?.rooms.first(where: { $0.roomID == roomID }),
              !ConversationTypeGuard.excludedFromBotAndAgent(roomType: room.roomType) else { return nil }
        let candidates = MobileAgentRoomPolicy.candidateUserIDs(
            memberCount: room.memberCount,
            heroes: room.memberUserIDs,
            latestSenderID: room.latestSenderID
        )
        return (agentsRead.value?.agents ?? []).first { agent in
            agent.status == .active
                && agent.matrixUser.map { candidates.contains($0.rawValue) } == true
        }
    }

    func appBotPresentation(roomID: String) -> AppBotPresentation? {
        guard conversation?.roomID == roomID,
              let room = liveMatrix?.rooms.first(where: { $0.roomID == roomID }),
              let botUserID = botUserID(for: room),
              let app = appsRead.value?.apps.first(where: { $0.bot?.userID.rawValue == botUserID })
        else { return nil }
        return appBotPresentation(app)
    }

    func appBotCatalogPresentation() -> AppBotCatalogPresentation {
        var byUserID = [String: AppBotPresentation]()
        var roomsBySlug = [String: String]()
        for app in appsRead.value?.apps ?? [] {
            guard let bot = app.bot,
                  let presentation = appBotPresentation(app) else { continue }
            byUserID[bot.userID.rawValue] = presentation
            if let choice = botChatChoice(forBot: bot.userID.rawValue, appID: app.appID.rawValue) {
                roomsBySlug[app.app] = choice.roomID
            }
        }
        return AppBotCatalogPresentation(appsByBotUserID: byUserID,
                                         roomIDBySlug: roomsBySlug)
    }

    private func appBotPresentation(_ app: AppDescriptor) -> AppBotPresentation? {
        let name = app.name.localized(locale: appLanguage, fallback: app.bot?.displayName ?? app.app)
        let onboardingCopy: AppOnboardingCopy?
        if let bot = app.bot,
           AppOnboardingPolicy.supports(disclosureVersion: bot.disclosureVersion, for: app.app) {
            onboardingCopy = copyCatalog.flatMap {
                AppOnboardingCopy(catalog: $0, locale: appLanguage, slug: app.app, appName: name)
            }
        } else {
            onboardingCopy = nil
        }
        return AppBotPresentation(app: app, locale: appLanguage,
                                  workspace: appWorkspaces[app.app],
                                  onboardingCopy: onboardingCopy)
    }

    /// The slug of the catalog app a roster row (`app:<id>`) stands for when it
    /// has no chat yet and the phone can start it; nil for every other row.
    func startableAppSlug(forRowID rowID: String) -> String? {
        guard rowID.hasPrefix("app:"),
              productRooms().first(where: { $0.id == rowID })?.awaitsStart == true else { return nil }
        let appID = String(rowID.dropFirst("app:".count))
        return appsRead.value?.apps.first(where: { $0.appID.rawValue == appID })?.app
    }

    func appBotPresentation(slug: String) -> AppBotPresentation? {
        guard let app = appsRead.value?.apps.first(where: { $0.app == slug }) else { return nil }
        return appBotPresentation(app)
    }

    /// Returns false only when the exact P1 reader/copy/API capability is not
    /// present, so the caller can retain the existing P0 continue-on-computer
    /// sheet. A supported attempt owns all later transient failures itself.
    func beginAppOnboarding(_ requested: AppBotPresentation) -> Bool {
        prepareAppOnboarding(requested, automaticallyContinue: true)
    }

    private func prepareAppOnboarding(_ requested: AppBotPresentation,
                                      automaticallyContinue: Bool) -> Bool {
        guard let client = domainClient,
              let descriptor = appsRead.value?.apps.first(where: {
                  $0.appID.rawValue == requested.appID && $0.app == requested.slug
              }), let bot = descriptor.bot,
              AppOnboardingPolicy.supports(disclosureVersion: bot.disclosureVersion,
                                           for: descriptor.app),
              let app = appBotPresentation(descriptor),
              let copy = copyCatalog.flatMap({
                  AppOnboardingCopy(catalog: $0, locale: appLanguage,
                                    slug: descriptor.app, appName: app.name)
              }), let locale = AppBotConsentLocale(designLocale: appLanguage),
              case .signedIn = stage else { return false }
        startAppOnboarding(app: app, copy: copy, locale: locale,
                           disclosureVersion: bot.disclosureVersion,
                           client: client, automaticallyContinue: automaticallyContinue)
        return true
    }

    @discardableResult
    func beginRoomlessAppOnboarding(_ slug: String) -> Bool {
        guard let descriptor = appsRead.value?.apps.first(where: { $0.app == slug }),
              let app = appBotPresentation(descriptor) else { return false }
        if descriptor.bot?.transportMode == .botAPI {
            return beginBotAPIDirectChat(descriptor)
        }
        return prepareAppOnboarding(app, automaticallyContinue: false)
    }

    /// Catalog-selected Bot API entry deliberately bypasses every legacy
    /// platform setup call. The existing Matrix port joins a known direct
    /// room or creates the same plain direct room the phone already uses for
    /// app bots, then hands it to AppRoot to open.
    private func beginBotAPIDirectChat(_ descriptor: AppDescriptor) -> Bool {
        guard descriptor.bot?.transportMode == .botAPI,
              AppStartPolicy.action(for: descriptor, existingRoomID: nil) == .startDirect,
              let session = liveMatrix, case .signedIn = stage else { return false }
        cancelAppOnboarding()
        appOnboardingReadyRoomID = nil
        let generation = appAccountGeneration
        let appID = descriptor.appID
        let appVersionID = descriptor.appVersionID
        appOnboardingTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let roomID = try await AppBotDirectStart.run(
                    app: descriptor,
                    chats: AppStartChatPort(model: self, session: session)
                )
                guard self.liveMatrix === session,
                      self.appAccountGeneration == generation,
                      self.appsRead.value?.apps.contains(where: {
                          $0.appID == appID && $0.appVersionID == appVersionID
                              && $0.bot?.transportMode == .botAPI
                      }) == true else { return }
                self.appOnboardingTask = nil
                self.appOnboardingReadyRoomID = roomID
            } catch is CancellationError {
                return
            } catch {
                guard self.liveMatrix === session,
                      self.appAccountGeneration == generation else { return }
                self.appOnboardingTask = nil
                LiveFlowLog.botRoom(.open, outcome: "bot_api_direct_failed", roomID: nil)
            }
        }
        return true
    }

    func continueAppOnboarding() {
        guard let attempt = appOnboardingAttempt,
              appOnboarding?.id == attempt.id,
              appOnboarding?.phase == .consent,
              let client = domainClient,
              appOnboardingAttempt?.gate.startPressed() == true else { return }
        appOnboardingTask?.cancel()
        appOnboardingTask = Task { @MainActor [weak self] in
            await self?.runAppConnection(client: client, attemptID: attempt.id)
        }
    }

    func retryAppOnboarding() {
        guard let current = appOnboarding, current.phase == .failed,
              let client = domainClient else { return }
        // Only a person who already pressed Start gets the flow resumed for
        // them; a failure while the disclosure was still loading comes back to
        // the disclosure and accepts nothing.
        let resumes = appOnboardingAttempt?.gate.retried().consentStarted ?? false
        startAppOnboarding(app: current.app, copy: current.copy, locale: current.locale,
                           disclosureVersion: current.disclosureVersion,
                           client: client, automaticallyContinue: resumes)
    }

    func updateAppIntake(name: String, value: String) {
        guard var presentation = appOnboarding,
              case let .intake(fields) = presentation.phase,
              fields.contains(where: { $0.name == name }) else { return }
        presentation.values[name] = value
        presentation.fieldErrors.remove(name)
        presentation.formFailed = false
        appOnboarding = presentation
    }

    func submitAppIntake() {
        guard var presentation = appOnboarding,
              case let .intake(fields) = presentation.phase,
              let attempt = appOnboardingAttempt,
              attempt.id == presentation.id,
              let client = domainClient else { return }
        let blanks = Set(fields.compactMap { field in
            (presentation.values[field.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? field.name : nil
        })
        guard blanks.isEmpty else {
            presentation.fieldErrors = blanks
            appOnboarding = presentation
            return
        }
        let submission: AppIntakeSubmission
        do { submission = try AppIntakeSubmission(values: presentation.values, fields: fields) }
        catch {
            presentation.formFailed = true
            appOnboarding = presentation
            return
        }
        appOnboardingTask?.cancel()
        appOnboardingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await client.submitAppIntake(slug: attempt.slug, value: submission)
                guard self.isCurrentAppAttempt(attempt.id, client: client) else { return }
                guard AppOnboardingPolicy.acceptsIntake(result, for: attempt.slug) else {
                    throw AppOnboardingFlowFailure.failed
                }
                if result.complete {
                    try await self.finishAppOnboarding(client: client, attemptID: attempt.id)
                } else {
                    try self.presentAppIntake(result, attemptID: attempt.id)
                }
            } catch let AppIntakeSubmissionFailure.invalid(field) {
                guard self.isCurrentAppAttempt(attempt.id, client: client),
                      var current = self.appOnboarding else { return }
                if let field, fields.contains(where: { $0.name == field }) {
                    current.fieldErrors = [field]
                } else {
                    current.formFailed = true
                }
                self.appOnboarding = current
            } catch is CancellationError {
                return
            } catch {
                self.failAppOnboarding(attempt.id)
            }
        }
    }

    func cancelAppOnboarding() {
        appOnboardingTask?.cancel()
        appOnboardingTask = nil
        appLinkPresenter?.cancel()
        appLinkPresenter = nil
        appOnboardingAttempt = nil
        appOnboarding = nil
    }

    func consumeAppOnboardingReadyRoom() -> String? {
        defer { appOnboardingReadyRoomID = nil }
        return appOnboardingReadyRoomID
    }

    func openAppRoute(_ requested: AppBotPresentation, routeID: String) -> Bool {
        guard let client = domainClient,
              let descriptor = appsRead.value?.apps.first(where: {
                  $0.appID.rawValue == requested.appID && $0.app == requested.slug
              }), descriptor.bot?.consent == .accepted, descriptor.link.state == .linked,
              let workspace = appWorkspaces[descriptor.app],
              workspace.appVersionID == descriptor.appVersionID, workspace.supportsLaunch,
              workspace.routes.contains(where: {
                  $0.id == routeID && $0.session == .required
              }), AppOnboardingPolicy.allowsLaunch(slug: descriptor.app, routeID: routeID),
              let request = try? AppLaunchRequest(appVersionID: descriptor.appVersionID,
                                                  routeID: routeID),
              case .signedIn = stage else { return false }
        let generation = appAccountGeneration
        appRouteFailed = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await client.launchApp(slug: descriptor.app, value: request)
                guard self.domainClient === client, self.appAccountGeneration == generation,
                      case .signedIn = self.stage else { return }
                self.appContentPage = AppContentPage(url: response.launchURL)
            } catch {
                guard self.domainClient === client, self.appAccountGeneration == generation else { return }
                self.appRouteFailed = true
            }
        }
        return true
    }

    func dismissAppContent() { appContentPage = nil }
    func openAppTerms(_ url: URL) { appContentPage = AppContentPage(url: url) }
    func dismissAppRouteFailure() { appRouteFailed = false }

    private func startAppOnboarding(app: AppBotPresentation, copy: AppOnboardingCopy,
                                    locale: AppBotConsentLocale, disclosureVersion: Int64,
                                    client: NativeDomainClient,
                                    automaticallyContinue: Bool) {
        cancelAppOnboarding()
        appOnboardingReadyRoomID = nil
        let id = UUID()
        appOnboardingAttempt = AppOnboardingAttempt(
            id: id, slug: app.slug, accountGeneration: appAccountGeneration,
            disclosureVersion: disclosureVersion,
            gate: AppOnboardingGate(automaticallyContinue: automaticallyContinue)
        )
        appOnboarding = AppOnboardingPresentation(
            id: id, app: app, disclosureVersion: disclosureVersion,
            locale: locale, copy: copy, phase: .loading
        )
        appOnboardingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let status = try await client.appBotStatus(slug: app.slug)
                guard self.isCurrentAppAttempt(id, client: client), status.bot != nil,
                      status.consent.disclosureVersion == disclosureVersion,
                      AppOnboardingPolicy.supports(disclosureVersion: disclosureVersion,
                                                   for: app.slug) else {
                    throw AppOnboardingFlowFailure.stale
                }
                // The catalog and status decide the entry: guest chat when the
                // bot declares it, the provider account link otherwise.
                guard let descriptor = self.appsRead.value?.apps.first(where: {
                          $0.appID.rawValue == app.appID
                      }), let mode = AppStartPolicy.mode(for: descriptor, status: status) else {
                    throw AppOnboardingFlowFailure.failed
                }
                self.appOnboardingAttempt?.mode = mode
                self.appOnboarding?.phase = .consent
                if self.appOnboardingAttempt?.gate.statusLoaded() == true {
                    await self.runAppConnection(client: client, attemptID: id)
                }
            } catch is CancellationError {
                return
            } catch {
                self.failAppOnboarding(id)
            }
        }
    }

    private func runAppConnection(client: NativeDomainClient, attemptID: UUID) async {
        guard let attempt = appOnboardingAttempt, attempt.id == attemptID,
              let presentation = appOnboarding else { return }
        do {
            let consent = try AppBotConsentRequest(disclosureVersion: attempt.disclosureVersion,
                                                   locale: presentation.locale)
            if attempt.mode == .guest {
                try await runGuestStart(client: client, attemptID: attemptID, consent: consent)
                return
            }
            appOnboarding?.phase = .authenticating
            _ = try await client.acceptAppBotConsent(slug: attempt.slug, value: consent)
            try requireCurrentAppAttempt(attemptID, client: client)

            let nonce = try AppLinkNonce.random()
            let connection = try await client.beginAppConnection(
                slug: attempt.slug, value: AppLinkConnectRequest(nonce: nonce)
            )
            try requireCurrentAppAttempt(attemptID, client: client)
            appOnboardingAttempt?.nonce = nonce
            appOnboardingAttempt?.initiationID = connection.initiationID

            let presenter = try makeAppLinkPresenter()
            appLinkPresenter = presenter
            let proof = try await presenter.authorize(
                at: connection.authorizationURL, nonce: nonce,
                initiationID: connection.initiationID
            )
            appLinkPresenter = nil
            try requireCurrentAppAttempt(attemptID, client: client)
            appOnboarding?.phase = .connecting
            _ = try await client.confirmAppConnection(
                slug: attempt.slug,
                value: try AppLinkConfirmRequest(proof: proof,
                                                 disclosureVersion: attempt.disclosureVersion)
            )
            try requireCurrentAppAttempt(attemptID, client: client)
            try await awaitAppProvider(client: client, attemptID: attemptID)
        } catch let failure as AppLinkWebAuthFailure where failure == .cancelled {
            if isCurrentAppAttempt(attemptID, client: client) { cancelAppOnboarding() }
        } catch is CancellationError {
            return
        } catch let failure as NativeDomainClientFailure where failure == .cancelled {
            return
        } catch {
            failAppOnboarding(attemptID)
        }
    }

    private func awaitAppProvider(client: NativeDomainClient, attemptID: UUID) async throws {
        let delays: [Duration] = [.zero, .seconds(1), .seconds(2), .seconds(4),
                                  .seconds(6), .seconds(8), .seconds(10), .seconds(10)]
        for delay in delays {
            if delay != .zero { try await Task.sleep(for: delay) }
            try requireCurrentAppAttempt(attemptID, client: client)
            guard let attempt = appOnboardingAttempt,
                  let initiationID = attempt.initiationID else { throw AppOnboardingFlowFailure.stale }
            let connection = try await client.appConnection(slug: attempt.slug)
            let status = try await client.appBotStatus(slug: attempt.slug)
            try requireCurrentAppAttempt(attemptID, client: client)
            guard connection.initiation.initiationID == initiationID,
                  status.consent.disclosureVersion == attempt.disclosureVersion,
                  status.consent.state == .accepted else { throw AppOnboardingFlowFailure.stale }
            if connection.connection.readiness == .unavailable { throw AppOnboardingFlowFailure.failed }
            guard connection.connection.state == .linked,
                  connection.connection.available,
                  connection.connection.readiness == .ready,
                  status.link.state == .linked, status.link.available, status.link.ready,
                  status.roomID != nil else { continue }
            let intake = try await client.appIntake(slug: attempt.slug)
            try requireCurrentAppAttempt(attemptID, client: client)
            guard AppOnboardingPolicy.acceptsIntake(intake, for: attempt.slug) else {
                throw AppOnboardingFlowFailure.failed
            }
            if intake.complete {
                try await finishAppOnboarding(client: client, attemptID: attemptID)
            } else {
                try presentAppIntake(intake, attemptID: attemptID)
            }
            return
        }
        throw AppOnboardingFlowFailure.failed
    }

    private func presentAppIntake(_ intake: AppIntakeStatus, attemptID: UUID) throws {
        guard appOnboardingAttempt?.id == attemptID, !intake.complete else {
            throw AppOnboardingFlowFailure.failed
        }
        let fields = intake.missingFields
        guard !fields.isEmpty,
              var presentation = appOnboarding else { throw AppOnboardingFlowFailure.failed }
        presentation.phase = .intake(fields)
        presentation.values = presentation.values.filter { key, _ in
            fields.contains(where: { $0.name == key })
        }
        presentation.fieldErrors = []
        presentation.formFailed = false
        appOnboarding = presentation
    }

    private func finishAppOnboarding(client: NativeDomainClient, attemptID: UUID) async throws {
        try requireCurrentAppAttempt(attemptID, client: client)
        guard let attempt = appOnboardingAttempt,
              let expectedInitiation = attempt.initiationID else { throw AppOnboardingFlowFailure.stale }
        let connection = try await client.appConnection(slug: attempt.slug)
        let status = try await client.appBotStatus(slug: attempt.slug)
        try requireCurrentAppAttempt(attemptID, client: client)
        guard connection.initiation.initiationID == expectedInitiation,
              connection.connection.state == .linked,
              connection.connection.readiness == .ready,
              connection.connection.available,
              status.consent.state == .accepted,
              status.consent.disclosureVersion == attempt.disclosureVersion,
              status.link.state == .linked, status.link.ready, status.link.available,
              let roomID = status.roomID?.rawValue else { throw AppOnboardingFlowFailure.failed }
        try await completeAppOnboarding(roomID: roomID, client: client, attemptID: attemptID)
    }

    /// Guest entry: the disclosure, the platform's `ready` guest state, then the
    /// person's one chat with the bot (found, or created once). No provider
    /// account and no browser. Everything app-specific came from the catalog.
    private func runGuestStart(client: NativeDomainClient, attemptID: UUID,
                               consent: AppBotConsentRequest) async throws {
        guard let attempt = appOnboardingAttempt, attempt.id == attemptID,
              let descriptor = appsRead.value?.apps.first(where: { $0.app == attempt.slug }),
              let session = liveMatrix else { throw AppOnboardingFlowFailure.failed }
        appOnboarding?.phase = .connecting
        let roomID = try await AppGuestStart.run(
            app: descriptor, consent: consent, backend: client,
            chats: AppStartChatPort(model: self, session: session)
        )
        try requireCurrentAppAttempt(attemptID, client: client)
        try await completeAppOnboarding(roomID: roomID, client: client, attemptID: attemptID)
    }

    /// Both entries end here: the chat is refreshed into the roster, awaited in
    /// the room list, and handed to the root to open.
    private func completeAppOnboarding(roomID: String, client: NativeDomainClient,
                                       attemptID: UUID) async throws {
        await refreshDomainReads()
        await refreshAppBotPointers()
        await refreshAppShortcuts()
        for _ in 0..<30 {
            try requireCurrentAppAttempt(attemptID, client: client)
            if liveMatrix?.rooms.contains(where: { $0.roomID == roomID }) == true { break }
            try await Task.sleep(for: .seconds(1))
        }
        try requireCurrentAppAttempt(attemptID, client: client)
        guard liveMatrix?.rooms.contains(where: { $0.roomID == roomID }) == true else {
            throw AppOnboardingFlowFailure.failed
        }
        appOnboardingTask = nil
        appOnboardingAttempt = nil
        appOnboarding = nil
        appOnboardingReadyRoomID = roomID
    }

    private func makeAppLinkPresenter() throws -> AppLinkWebAuthPresenter {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let anchor = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow,
              anchor.isKeyWindow else { throw AppLinkWebAuthFailure.browserUnavailable }
        return AppLinkWebAuthPresenter(anchor: anchor)
    }

    private func isCurrentAppAttempt(_ id: UUID, client: NativeDomainClient) -> Bool {
        guard let attempt = appOnboardingAttempt else { return false }
        return attempt.id == id && attempt.accountGeneration == appAccountGeneration
            && domainClient === client && appOnboarding?.id == id
    }

    private func requireCurrentAppAttempt(_ id: UUID,
                                          client: NativeDomainClient) throws {
        guard isCurrentAppAttempt(id, client: client) else { throw AppOnboardingFlowFailure.stale }
    }

    private func failAppOnboarding(_ id: UUID) {
        guard appOnboardingAttempt?.id == id, appOnboarding?.id == id else { return }
        appOnboardingAttempt?.gate.failed()
        appLinkPresenter = nil
        appOnboardingTask = nil
        appOnboarding?.phase = .failed
    }

    private enum AppOnboardingFlowFailure: Error { case stale, failed }

    /// The Matrix side of a guest start: the chat this phone already holds
    /// with the bot, or the one chat it makes (once per bot and session).
    @MainActor private struct AppStartChatPort: AppBotChatPort {
        let model: LiveAppModel
        let session: LiveMatrixSession

        func existingChat(appID: String, botUserID: String) async -> String? {
            // The account pointer is read again first: a room another device
            // made and named counts even before it reaches this phone's list.
            await model.refreshAppBotPointer(appID: appID, botUserID: botUserID)
            guard let roomID = await AppBotChatResolver.resolve(
                localChoice: model.botChatChoice(forBot: botUserID, appID: appID),
                pointerRoomID: model.appBotPointers[appID],
                join: { await session.join(roomID: $0) },
                appears: { await model.waitForRoom($0, session: session) }
            ) else { return nil }
            if model.hiddenRooms.unhide(roomID: roomID) {
                model.hiddenRoomStore?.save(model.hiddenRooms)
            }
            return roomID
        }

        // The platform's canonical-room arbitration (`AppBotRoomArbitration`).

        func verifiedChat(appID: String, botUserID: String) async -> String? {
            // A room this session made counts once it shows in the room list.
            if let made = model.createdAppBotChats[botUserID],
               session.rooms.contains(where: { $0.roomID == made }) { return made }
            // Only an open, joined, plain one-to-one chat is offered: the
            // candidate choice already refuses encrypted, group and invited rooms.
            guard let choice = model.botChatChoice(forBot: botUserID, appID: appID),
                  choice.action == .open else { return nil }
            return choice.roomID
        }

        func createPlainChat(botUserID: String) async -> String? {
            // A retry of this attempt names the room already made, not a second one.
            if let made = model.createdAppBotChats[botUserID] { return made }
            guard let bot = try? NativeMatrixUser(botUserID),
                  let roomID = await session.createDirectRoom(inviting: bot) else { return nil }
            model.createdAppBotChats[botUserID] = roomID
            return roomID
        }

        func writeChatRecords(roomID: String, appID: String, botUserID: String) async {
            guard let bot = try? NativeMatrixUser(botUserID) else { return }
            await session.writeAppBotChatRecords(roomID: roomID, appID: appID, bot: bot)
        }

        func leave(roomID: String) async {
            _ = await session.leave(roomID: roomID)
            model.createdAppBotChats = model.createdAppBotChats.filter { $0.value != roomID }
        }

        func open(roomID: String) async -> Bool {
            guard await session.join(roomID: roomID),
                  await model.waitForRoom(roomID, session: session) else { return false }
            if model.hiddenRooms.unhide(roomID: roomID) {
                model.hiddenRoomStore?.save(model.hiddenRooms)
            }
            return true
        }

        func createChat(appID: String, botUserID: String) async -> String? {
            if let made = model.createdAppBotChats[botUserID] { return made }
            guard model.attemptedAppBotChatTargets.insert(botUserID).inserted else {
                // An earlier create may still be landing; observe sync, never re-issue.
                return await model.waitForDirectRoom(with: botUserID, session: session)
            }
            guard let bot = try? NativeMatrixUser(botUserID),
                  let roomID = await session.createAppBotChat(appID: appID, bot: bot) else {
                return await model.waitForDirectRoom(with: botUserID, session: session)
            }
            model.createdAppBotChats[botUserID] = roomID
            return roomID
        }
    }

    /// Existing-room open stays unchanged. AppRoot may separately start the
    /// typed room-less setup path when this returns nil; neither path creates
    /// or discovers a room locally.
    func openExistingAppBot(_ slug: String,
                            stillCurrent: @escaping @MainActor () -> Bool = { true }) async -> String? {
        guard let app = appsRead.value?.apps.first(where: { $0.app == slug && $0.bot != nil }),
              let choice = await botChatToOpen(forAppRow: "app:" + app.appID.rawValue),
              stillCurrent() else { return nil }
        if hiddenRooms.unhide(roomID: choice.roomID) { hiddenRoomStore?.save(hiddenRooms) }
        if choice.action == .join {
            guard let session = liveMatrix,
                  let presentation = AppBotPresentation(app: app, locale: appLanguage) else { return nil }
            startAppBotJoin(roomID: choice.roomID, app: presentation, session: session)
            return choice.roomID
        }
        let rows = productRooms()
        guard let row = rows.first(where: { $0.id == choice.roomID })
                ?? rows.first(where: { $0.id == "app:" + app.appID.rawValue }),
              stillCurrent() else { return nil }
        openConversation(roomID: choice.roomID, row: row)
        return conversation?.roomID
    }

    private func beginRoomMutation(
        roomID: String,
        kind: RoomMutationKind,
        desired: Bool,
        perform: @escaping @MainActor (LiveMatrixSession) async -> Bool
    ) {
        guard let liveMatrix,
              productRooms().contains(where: { $0.id == roomID && !$0.isInvitation }) else {
            recordRoomActionFailure(roomID)
            return
        }
        nextRoomMutationGeneration &+= 1
        let generation = nextRoomMutationGeneration
        let key = RoomMutationKey(roomID: roomID, kind: kind)
        pendingRoomMutations[key] = PendingRoomMutation(
            desired: desired, generation: generation, settleAfterRoomRevision: nil
        )
        if let opened = conversationOpenedRoom, opened.id == roomID {
            conversationOpenedRoom = opened.withRosterState(
                unreadOverride: kind == .unread ? desired : nil,
                pinnedOverride: kind == .pinned ? desired : nil,
                mutedOverride: kind == .muted ? desired : nil,
                lowPriorityOverride: kind == .lowPriority ? desired : nil
            )
        }
        roomMutationQueue.enqueue(for: key) { @MainActor [weak self] in
            guard let self else { return }
            guard self.liveMatrix === liveMatrix else {
                if self.pendingRoomMutations[key]?.generation == generation {
                    self.pendingRoomMutations[key] = nil
                    self.restoreOpenedRoomState(roomID: roomID)
                    self.recordRoomActionFailure(roomID)
                }
                return
            }
            let succeeded = await perform(liveMatrix)
            guard self.pendingRoomMutations[key]?.generation == generation else { return }
            guard self.liveMatrix === liveMatrix else {
                self.pendingRoomMutations[key] = nil
                self.restoreOpenedRoomState(roomID: roomID)
                self.recordRoomActionFailure(roomID)
                return
            }
            if !succeeded {
                self.pendingRoomMutations[key] = nil
                self.restoreOpenedRoomState(roomID: roomID)
                self.recordRoomActionFailure(roomID)
            } else {
                self.pendingRoomMutations[key]?.settleAfterRoomRevision = self.roomPublicationRevision
                self.reconcileRoomMutations(with: liveMatrix.rooms,
                                            revision: self.roomPublicationRevision)
            }
        }
    }

    private func recordRoomActionFailure(_ roomID: String) {
        roomActionFailure.token &+= 1
        roomActionFailure.roomID = roomID
    }

    private func restoreOpenedRoomState(roomID: String) {
        guard let opened = conversationOpenedRoom, opened.id == roomID,
              let live = liveMatrix?.rooms.first(where: { $0.roomID == roomID }) else { return }
        syncOpenedRoomState(opened, with: live)
    }

    /// Opens a chat from a roster row and pushes it (B31). An app row opens
    /// the bot room this phone already has (the same room as the Mac); a
    /// Moon or Andy row without a room is not listed at all (§4.2 item 1).
    @discardableResult
    func openRoom(_ roomID: String,
                  stillCurrent: @escaping @MainActor () -> Bool = { true }) async -> String? {
        // Claiming the conversation type is not authority: such a room has no transcript here.
        guard !companyWorkspace.isQuarantinedConversation(roomID) else { return nil }
        let rows = productRooms()
        guard let row = rows.first(where: { $0.id == roomID && $0.canOpen }) else { return nil }
        if row.isInvitation {
            guard let session = liveMatrix, stillCurrent(),
                  await session.acceptInvite(roomID: roomID), stillCurrent(),
                  await waitForJoinedRoom(roomID, session: session, stillCurrent: stillCurrent)
            else { return nil }
            let joinedRow = productRooms().first(where: { $0.id == roomID }) ?? row
            guard stillCurrent() else { return nil }
            openConversation(roomID: roomID, row: joinedRow)
            return conversation?.roomID
        }
        if roomID.hasPrefix("app:") {
            guard let choice = await botChatToOpen(forAppRow: roomID) else {
                LiveFlowLog.botRoom(.open, outcome: "no_room", roomID: nil)
                return nil
            }
            // Opening the bot again brings back the same room; the phone
            // never creates a replacement.
            if hiddenRooms.unhide(roomID: choice.roomID) {
                hiddenRoomStore?.save(hiddenRooms)
                LiveFlowLog.botRoom(.unhide, outcome: "opened_from_app_row", roomID: choice.roomID)
            }
            if choice.action == .join {
                guard let session = liveMatrix,
                      let appID = roomID.split(separator: ":", maxSplits: 1).last.map(String.init),
                      let descriptor = appsRead.value?.apps.first(where: { $0.appID.rawValue == appID }),
                      let app = AppBotPresentation(app: descriptor, locale: appLanguage) else { return nil }
                startAppBotJoin(roomID: choice.roomID, app: app, session: session)
                return choice.roomID
            } else {
                LiveFlowLog.botRoom(.open, outcome: "reused_" + choice.reason.rawValue, roomID: choice.roomID)
            }
            guard stillCurrent() else { return nil }
            openConversation(roomID: choice.roomID, row: row)
            return conversation?.roomID
        }
        if let room = liveMatrix?.rooms.first(where: { $0.roomID == roomID }), botUserID(for: room) != nil {
            LiveFlowLog.botRoom(.open, outcome: "reused", roomID: roomID)
        }
        guard stillCurrent() else { return nil }
        openConversation(roomID: roomID, row: row)
        return conversation?.roomID
    }

    /// Each app-row tap that has to wait for a joined room; a later tap or
    /// an opened chat supersedes it.
    @ObservationIgnored private var appRowOpenGeneration: UInt64 = 0

    private func beginAppRowOpen() -> UInt64 {
        appRowOpenGeneration &+= 1
        return appRowOpenGeneration
    }

    func retryAppBotJoin(roomID: String) {
        guard let opening = appBotRoomOpening, opening.roomID == roomID,
              let session = liveMatrix else { return }
        startAppBotJoin(roomID: roomID, app: opening.app, session: session)
    }

    private func startAppBotJoin(roomID: String, app: AppBotPresentation,
                                 session: LiveMatrixSession) {
        closeConversation()
        // A room that claims the conversation type is never a bot's chat, joined or not.
        let claimed = session.rooms.first(where: { $0.roomID == roomID })?.roomType
            ?? session.invites.first(where: { $0.roomID == roomID })?.roomType
        guard !ConversationTypeGuard.excludedFromBotAndAgent(roomType: claimed) else {
            appBotRoomOpening = AppBotRoomOpening(roomID: roomID, app: app, phase: .failed)
            return
        }
        appBotRoomOpening = AppBotRoomOpening(roomID: roomID, app: app, phase: .joining)
        let tap = beginAppRowOpen()
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            let joined: Bool
            if session.rooms.contains(where: { $0.roomID == roomID }) {
                joined = true
            } else {
                joined = await session.acceptInvite(roomID: roomID)
            }
            guard self.liveMatrix === session, self.appRowOpenGeneration == tap,
                  self.appBotRoomOpening?.roomID == roomID else { return }
            LiveFlowLog.botRoom(.open, outcome: joined ? "joined_invited" : "join_failed",
                                roomID: roomID)
            guard joined else {
                if self.appBotRoomOpening?.roomID == roomID {
                    self.appBotRoomOpening?.phase = .failed
                }
                return
            }
            guard await self.waitForJoinedRoom(roomID, session: session, tap: tap),
                  let row = self.productRooms().first(where: { $0.id == roomID }) else {
                LiveFlowLog.botRoom(.open, outcome: "joined_not_listed", roomID: roomID)
                if self.appBotRoomOpening?.roomID == roomID {
                    self.appBotRoomOpening?.phase = .failed
                }
                return
            }
            self.openConversation(roomID: roomID, row: row)
        }
    }

    /// Waits (at most 10 s) for a just-joined room to appear in the room list
    /// of the same session. False when it did not, or when the person moved
    /// on (another tap, a chat opened, the session replaced).
    private func waitForJoinedRoom(_ roomID: String, session: LiveMatrixSession, tap: UInt64) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard liveMatrix === session, appRowOpenGeneration == tap, conversation == nil else { return false }
            if session.rooms.contains(where: { $0.roomID == roomID }) { return true }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
        }
        return false
    }

    private func waitForJoinedRoom(_ roomID: String, session: LiveMatrixSession,
                                   stillCurrent: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard liveMatrix === session, stillCurrent(), conversation == nil else { return false }
            if session.rooms.contains(where: { $0.roomID == roomID }) { return true }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return false }
        }
        return false
    }

    /// Leaves the open chat: its draft is kept (with any send held during a
    /// session renewal, which `close` puts back into it), `.fullyRead`
    /// goes out if the person reached the bottom, and the timeline is freed
    /// once sends already tapped reach the SDK (§2.3 rule 8).
    func closeConversation() {
        conversationMembersTask?.cancel()
        conversationMembersTask = nil
        conversationMembers = []
        if let conversation {
            conversation.close()
            drafts[conversation.roomID] = conversation.draft
        }
        conversation = nil
        appBotRoomOpening = nil
        conversationAvatar = nil
        conversationOpenedRoom = nil
    }

    private func openConversation(roomID: String, row: LiveProductRoom) {
        // A conversation is named for the other people, from the platform's record, never
        // from the Matrix room name.
        let title = companyWorkspace.claim(roomID: roomID).map { claim in
            companyWorkspace.copy?.channelName(claim.displayName, isDefault: claim.isDefault)
                ?? claim.displayName
        } ?? companyWorkspace.conversationClaim(roomID: roomID)?.title ?? row.title
        guard let current = context, let info = conversationInfo(roomID: roomID, title: title,
                                                                 ownUserID: current.runtime.ticket.session.userID)
        else { return }
        if conversation?.roomID == roomID {
            return
        }
        closeConversation()
        // B5: `ChatScreen`'s transcript holds the row being read when older
        // rows are added above it, so history loads as the person scrolls up.
        let mediaComposer = mediaDrafts[roomID] ?? ChatMediaComposerState()
        mediaDrafts[roomID] = mediaComposer
        let localMediaDraft = localMediaDrafts[roomID] ?? ConversationLocalMediaDraft()
        localMediaDrafts[roomID] = localMediaDraft
        let store = LiveConversationStore(info: info, draft: drafts[roomID] ?? "", history: .onScroll,
                                          mediaComposer: mediaComposer,
                                          localMediaDraft: localMediaDraft,
                                          makeTyping: Self.typingFactory(for: info))
        store.onUnsentAfterClose = { [weak self] text in self?.keepUnsentText(text, roomID: roomID) }
        store.onMessageSent = { LiveReporting.shared.messageSent() }
        store.accountOffersRecovery = offersHistoryRecovery
        conversation = store
        conversationAvatar = row.avatar
        conversationOpenedRoom = row
        attachConversation()
        if firstRunMarker == .unknown {
            Task { @MainActor [weak self] in await self?.refreshFirstRunMarker() }
        }
        if let session = liveMatrix {
            let ownUserID = info.context.ownUserID
            let localeIdentifier = appLanguage
            // The member list in chat info is for personal groups; a company
            // channel's people come from the company roster. Both feed the
            // composer's `@` picker.
            let listsMembers = info.context.kind == .group && !companyWorkspace.isCompanyChannel(roomID)
            let roster = companyWorkspace.mentionRoster(roomID: roomID)
            conversationMembersTask = Task { @MainActor [weak self, weak session] in
                guard let self, let session, let members = await session.members(roomID: roomID) else { return }
                let ordered = await Task.detached(priority: .userInitiated) {
                    let locale = Locale(identifier: localeIdentifier)
                    return members.sorted { left, right in
                        if (left.userID == ownUserID) != (right.userID == ownUserID) {
                            return left.userID == ownUserID
                        }
                        let order = left.displayName.compare(
                            right.displayName,
                            options: [.caseInsensitive, .diacriticInsensitive],
                            range: nil,
                            locale: locale
                        )
                        if order != .orderedSame { return order == .orderedAscending }
                        return left.userID < right.userID
                    }
                }.value
                guard !Task.isCancelled,
                      self.liveMatrix === session,
                      self.conversation?.roomID == roomID else { return }
                if listsMembers || info.context.kind == .person { self.conversationMembers = ordered }
                self.conversation?.setMentionCandidates(MentionRules.candidates(
                    members: ordered.map { (userID: $0.userID, displayName: $0.displayName) },
                    roster: roster, ownUserID: ownUserID))
            }
        }
    }

    /// B10–B12: WS3's `TypingController` on each session's room, naming
    /// typers with the chat's own label rule. Real signals only.
    private static func typingFactory(for info: ConversationRoomInfo) -> ConversationTypingFactory {
        let kind = info.context.kind
        let title = info.title
        let names = info.knownNames
        let sharing = info.shareActivity
        return { room in
            let controller = TypingController(room: room, kind: kind, roomTitle: title,
                                              shareActivity: sharing) { userID, profile in
                MobileSenderLabelPolicy.label(senderID: userID, profileDisplayName: profile, knownNames: names)
            }
            controller.start()
            return controller
        }
    }

    /// Attaches the open chat to the current session's room, when there is
    /// one. Called on open and each time a session is established (start,
    /// restart, renewal).
    private func attachConversation() {
        guard let conversation, let liveMatrix, liveMatrix.isReady else { return }
        do {
            let room = try liveMatrix.room(id: conversation.roomID)
            Task { await conversation.attach(room: room) }
        } catch {
            // The session is up but has no such room: sends held for it go
            // back to the composer rather than wait forever.
            conversation.attachFailed()
        }
    }

    /// A send refused after its chat was closed: its text joins the room's
    /// draft (the open chat's composer if it was reopened meanwhile).
    private func keepUnsentText(_ text: String, roomID: String) {
        if let conversation, conversation.roomID == roomID {
            conversation.restoreUnsent(text)
            return
        }
        drafts[roomID] = MobileComposerDraftPolicy.draftAfterRefusedSend(currentDraft: drafts[roomID] ?? "",
                                                                         sentBody: text, sameRoomOpen: true).draft
    }

    /// The chat's kind and who is who in it (§2.7), from the same tested
    /// policies the roster uses: the owner's agent → my assistant; a catalog
    /// bot → app bot; otherwise a 1:1 person or a group by member count.
    private func conversationInfo(roomID: String, title: String, ownUserID: String) -> ConversationRoomInfo? {
        guard let room = liveMatrix?.rooms.first(where: { $0.roomID == roomID }) else { return nil }
        var agentByUser = [String: AgentsResponse.Agent]()
        for agent in agentsRead.value?.agents ?? [] where agent.status == .active {
            if let user = agent.matrixUser?.rawValue { agentByUser[user] = agent }
        }
        let candidates = MobileAgentRoomPolicy.candidateUserIDs(memberCount: room.memberCount,
                                                                heroes: room.memberUserIDs,
                                                                latestSenderID: room.latestSenderID)
        let context: RoomContext
        if let conversation = companyWorkspace.conversationClaim(roomID: roomID) {
            // A company DM is a conversation between people (a group DM a group), whatever the
            // room's size says; never an assistant's or a bot's, and never from `m.room.create.type`.
            context = RoomContext(kind: conversation.kind == .dm ? .person : .group, ownUserID: ownUserID)
        } else if let agent = candidates.first(where: { agentByUser[$0] != nil }) {
            context = RoomContext(kind: .assistant, ownUserID: ownUserID, agentUserIDs: [agent])
        } else if let bot = botUserID(for: room) ?? candidates.first(where: { catalogBotUserIDs.contains($0) }) {
            context = RoomContext(kind: .appBot, ownUserID: ownUserID, agentUserIDs: [bot])
        } else if companyWorkspace.isCompanyChannel(roomID) {
            // A company channel is the same chat surface as a group even when
            // the roster is small; its name and members come from the
            // platform, never from `m.room.create.type`.
            context = RoomContext(kind: .group, ownUserID: ownUserID)
        } else {
            context = RoomContext(kind: room.memberCount > 2 ? .group : .person, ownUserID: ownUserID)
        }
        return ConversationRoomInfo(roomID: roomID, title: title, context: context,
                                    knownNames: knownAgentAndBotNames,
                                    catalogBotUserIDs: catalogBotUserIDs,
                                    languageCode: appLanguage,
                                    roomIsEncrypted: room.isEncrypted,
                                    isMarkedUnread: room.isMarkedUnread,
                                    shareActivity: shareActivity)
    }

    /// Leave and Delete chat on an app bot room hide it on this phone only.
    /// The phone never leaves or forgets a bot room: leaving makes the next
    /// open elsewhere create a new, empty room. Other rooms are unchanged.
    private func hideAppRooms(startingAt roomID: String, outcome: String) {
        guard let liveMatrix,
              let room = liveMatrix.rooms.first(where: { $0.roomID == roomID }) else {
            LiveFlowLog.botRoom(.hideRefused, outcome: "room_not_found", roomID: roomID)
            return
        }
        guard let bot = botUserID(for: room) else {
            LiveFlowLog.botRoom(.hideRefused, outcome: "not_bot_room", roomID: roomID)
            return
        }
        let nowMillis = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        hiddenRooms.hide(roomID: roomID, latestTimestamp: room.latestTimestamp, nowMillis: nowMillis)
        discardRoomDrafts(roomID)
        LiveFlowLog.botRoom(.hide, outcome: outcome, roomID: roomID)
        // A person has one conversation with each app. Rooms 0.19.3 duplicated
        // for the same bot are hidden with it, so the app row comes back and
        // reopening picks the desktop's room.
        for other in liveMatrix.rooms where other.roomID != roomID
            && botUserID(for: other) == bot
            && !hiddenRooms.isHidden(roomID: other.roomID, latestTimestamp: other.latestTimestamp) {
            hiddenRooms.hide(roomID: other.roomID, latestTimestamp: other.latestTimestamp, nowMillis: nowMillis)
            discardRoomDrafts(other.roomID)
            LiveFlowLog.botRoom(.hide, outcome: "duplicate_hidden", roomID: other.roomID)
        }
        hiddenRoomStore?.save(hiddenRooms)
        if conversation?.roomID == roomID { closeConversation() }
    }

    private func discardRoomDrafts(_ roomID: String) {
        drafts[roomID] = nil
        mediaDrafts.removeValue(forKey: roomID)?.discardAll()
        localMediaDrafts[roomID] = nil
    }

    // MARK: Foreground session keep-alive

    /// Follows the app's scene phase through `LiveScenePhaseRelay`, so the
    /// root view's body never depends on it. Idempotent.
    func observeScenePhase() {
        applePurchases.start()
        guard scenePhaseToken == nil else { return }
        scenePhaseToken = LiveScenePhaseRelay.shared.observe { [weak self] phase in
            switch phase {
            case .active: self?.sceneBecameActive()
            case .background: self?.sceneEnteredBackground()
            default: break
            }
        }
        observeTimeZoneChanges()
    }

    /// A38: the only new trigger. A system time-zone change (travel, or a
    /// manual change in Settings) runs the same refresh as a return to the
    /// foreground; there is no timer, retry loop or second read path.
    private func observeTimeZoneChanges() {
        guard timeZoneObserver == nil else { return }
        let observer = OwnerTimeZoneChangeObserver()
        observer.start { [weak self] in
            // A background delivery waits for the next foreground refresh:
            // no renewal spends a token while suspended.
            guard let self, self.isSceneActive else { return }
            Task { @MainActor [weak self] in await self?.refreshDomainOnForeground() }
        }
        timeZoneObserver = observer
    }

    /// The scene became active (launch, unlock, return from another app).
    /// Renews a token that is expired or about to expire. Sync and every
    /// send queue are the session's `SessionLifecycle` (B9): it starts sync
    /// and wakes the queues on the same phase change, while the session is
    /// current.
    func sceneBecameActive() {
        Task { [weak self] in await self?.applePurchases.replayUnfinished() }
        isSceneActive = true
        startSessionKeepAlive()
        if returningFromBackground {
            returningFromBackground = false
            // B30: agents, apps, store and wallet refresh on every return
            // (the session's lifecycle asks too; one refresh runs).
            Task { @MainActor [weak self] in await self?.refreshDomainOnForeground() }
            // The network may be back: an open chat stops backing off.
            conversation?.resumeAfterReconnect()
        }
        retryLaunchOnForeground()
    }

    /// No renewals run in the background: a refresh-token spend cut short by
    /// suspension would strand custody. The next activation renews instead.
    func sceneEnteredBackground() {
        isSceneActive = false
        returningFromBackground = true
        // B13: nothing is marked read in the background.
        conversation?.bottomVisible = false
        keepAliveGeneration &+= 1
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    /// W4 E3: a launch that could not open a Matrix session is tried again
    /// on a return to the foreground, spaced, never by a lock screen. A
    /// custody refusal is not retried automatically (nothing can change it).
    private func retryLaunchOnForeground() {
        guard stage == .recoveryRequired || stage == .unavailable, !isBusy,
              MobileSessionContinuityPolicy.retriesLaunch(launchFailureOutcome ?? .retryLaunch, now: Date(),
                                                          lastAttemptAt: lastLaunchAttemptAt) else {
            return
        }
        LiveFlowLog.session(.continuity, outcome: "launch_retry_foreground")
        Task { @MainActor [weak self] in await self?.retryBootstrap() }
    }

    /// W4 E3: the session can no longer be renewed on this phone (custody
    /// refused, or records survived without their installation), so the root
    /// shows the sign-in screen with the expired-session notice (decision
    /// 11), never "check your connection".
    var launchSessionExpired: Bool { launchFailureOutcome == .sessionExpired }

    /// Custody's grant, read without spending (W4 E3).
    private func custodyGrant(_ store: MatrixSessionKeychain) -> MobileSessionContinuityPolicy.CustodyGrant {
        MobileSessionContinuityPolicy.custodyGrant { try store.resume(marker: marker).session.expiresAt }
    }

    private func startSessionKeepAlive() {
        guard isSceneActive, keepAliveTask == nil else { return }
        keepAliveGeneration &+= 1
        let generation = keepAliveGeneration
        keepAliveTask = Task { @MainActor [weak self] in
            await self?.runSessionKeepAlive()
            guard let self, self.keepAliveGeneration == generation else { return }
            self.keepAliveTask = nil
        }
    }

    /// Wakes about 60 s before the access token expires and renews it through
    /// the same runtime replacement pull-to-refresh uses; a session that is
    /// no longer current is rebuilt the same way (W4 E3: custody decides
    /// whether anything is spent). After failed renewals it backs off (30 s,
    /// 2 min, 10 min) and after a custody refusal it stops
    /// (`MobileSessionContinuityPolicy.RenewalRetry`). Exits when signed out;
    /// `beginProduct` and the next activation restart it.
    private func runSessionKeepAlive() async {
        while !Task.isCancelled, isSceneActive {
            guard case .signedIn = stage, let current = context, let session = liveMatrix else { return }
            let now = Date()
            guard let backoff = renewalRetry.automaticWait(now: now) else {
                LiveFlowLog.session(.keepAlive, outcome: "stopped_custody_refused")
                // Decision 11: the working session runs until its token
                // expires; then nothing can sync or send on it, so the
                // sign-in screen replaces the chats.
                let wait = MobileSessionContinuityPolicy.secondsUntilSignIn(
                    custodyRefused: true, sessionExpiresAt: current.runtime.ticket.session.expiresAt, now: now
                ) ?? 0
                if wait > 0 {
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                }
                guard isSceneActive, case .signedIn = stage, context?.installation == current.installation,
                      renewalRetry.custodyRefused else { return }
                await endStrandedSession()
                return
            }
            if backoff > 0 {
                let seconds = max(MobileMatrixSessionKeepAlivePolicy.minimumWaitSeconds, backoff)
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                continue
            }
            let expiresAt = current.runtime.ticket.session.expiresAt
            // A session that is no longer current (a renewed one that came up
            // invalid, or one an SDK update flagged) is due now, under the
            // same 30 s spacing between attempts.
            let invalid = session.error == .currentSessionInvalid
            switch MobileMatrixSessionKeepAlivePolicy.nextStep(expiresAt: invalid ? now : expiresAt, now: now,
                                                                lastAttemptAt: lastRenewalAttemptAt) {
            case .renewNow:
                LiveFlowLog.session(.keepAlive, outcome: invalid ? "rebuild_started" : "renew_started")
                let result = await renewMatrixRuntime(current: current, session: session, now: now,
                                                      reason: invalid ? "keep_alive_rebuild" : "keep_alive")
                LiveFlowLog.session(.keepAlive, outcome: result.rawValue)
            case let .wait(seconds):
                do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            }
        }
    }

    /// An SDK update or a send found the custody ticket no longer current.
    /// In the foreground the runtime is rebuilt instead of leaving the chat
    /// silently frozen. Custody decides whether a refresh token is spent
    /// (only when its own grant is inside the renewal lead), so this is safe
    /// for any reason a session goes invalid, not only expiry (W4 E3). Same
    /// spacing, backoff and custody stop as the keep-alive.
    private func matrixSessionBecameInvalid(_ matrix: LiveMatrixSession) {
        guard liveMatrix === matrix, !matrixRenewal.isRunning, case .signedIn = stage,
              isSceneActive, let current = context else { return }
        let now = Date()
        guard renewalRetry.automaticWait(now: now) == 0,
              MobileMatrixSessionKeepAlivePolicy.nextStep(expiresAt: now, now: now,
                                                          lastAttemptAt: lastRenewalAttemptAt) == .renewNow
        else { return }
        LiveFlowLog.session(.keepAlive, outcome: "renew_after_invalid")
        Task { @MainActor [weak self] in
            await self?.renewMatrixRuntime(current: current, session: matrix, now: now, reason: "session_invalid")
        }
    }

    /// Single flight around `replaceMatrixRuntimeAfterRefresh`: a second
    /// concurrent replacement would spend the refresh token while the first
    /// spend is pending and strand custody. Every attempt's result feeds the
    /// automatic-retry backoff and one continuity log line with the failure
    /// class (W4 E3). A caller that joins a run in progress gets that run's
    /// result.
    @discardableResult
    private func renewMatrixRuntime(current: Context, session: LiveMatrixSession, now: Date,
                                    requiredLifetimeSeconds: TimeInterval =
                                        MobileMatrixSessionKeepAlivePolicy.refreshLeadSeconds,
                                    reason: String) async -> MobileSessionContinuityPolicy.RenewalResult {
        await matrixRenewal.run { [weak self] in
            guard let self else { return }
            self.lastRenewalAttemptAt = now
            // The refresh-token spend is journaled; if iOS suspended the app
            // mid-spend, the next launch would find custody stranded. Ask for
            // background time so a renewal that has started can finish.
            let assertion = LiveBackgroundAssertion(name: "atum.matrix-renewal")
            defer { assertion.end() }
            self.isRenewingMatrixSession = true
            let attempt = await self.replaceMatrixRuntimeAfterRefresh(
                current: current, session: session, now: now, requiredLifetimeSeconds: requiredLifetimeSeconds
            )
            self.isRenewingMatrixSession = false
            self.renewalRetry.record(attempt.result, at: Date())
            if attempt.result != .renewed || attempt.code != nil {
                LiveFlowLog.session(.continuity, outcome: reason + "_" + attempt.result.rawValue,
                                    code: attempt.code ?? "none")
            }
            self.lastRenewalResult = attempt.result
        }
        return lastRenewalResult
    }

    /// Domain reads on foreground (B30), unless a full refresh is running.
    /// The model and the session's lifecycle both ask on a return; one runs.
    private func refreshDomainOnForeground() async {
        guard case .signedIn = stage, !isRefreshingProduct, !isRefreshingDomainOnForeground else { return }
        isRefreshingDomainOnForeground = true
        defer { isRefreshingDomainOnForeground = false }
        await refreshDomainReads()
        await refreshCompanyWorkspace()
        if let liveMatrix { acceptKnownInvites(liveMatrix.invites, session: liveMatrix) }
        await refreshAppBotPointers()
        await refreshAppShortcuts()
        await refreshFirstRunMarker()
        startPendingAssistantLifecycleResume()
    }

    func configureCompanyWorkspace(copy: CompanyCopy) {
        configureCompanyWorkspaceIfNeeded()
        companyWorkspace.copy = copy
    }

    private func configureCompanyWorkspaceIfNeeded() {
        guard !companyConfigured else { return }
        companyConfigured = true
        companyWorkspace.clientProvider = { [weak self] in self?.domainClient }
        companyWorkspace.privateCosProvider = { [weak self] in self?.domainClient }
        companyWorkspace.privateCosRoomTitle = { [weak self] roomID in
            self?.liveMatrix?.rooms.first(where: { $0.roomID == roomID })?.displayName
                ?? self?.liveMatrix?.invites.first(where: { $0.roomID == roomID })?.displayName
        }
        companyWorkspace.conversationsProvider = { [weak self] in self?.domainClient }
        companyWorkspace.presence = { [weak self] roomID in
            guard let self, let matrix = self.liveMatrix else { return .unknown }
            if matrix.rooms.contains(where: { $0.roomID == roomID }) { return .joined }
            if matrix.invites.contains(where: { $0.roomID == roomID }) { return .invited }
            return .absent
        }
        companyWorkspace.join = { [weak self] roomID in
            guard let self, let matrix = self.liveMatrix else { return false }
            return await matrix.acceptInvite(roomID: roomID)
        }
        // Only the directory-confirmed conversation convergence may join a conversation-type room.
        companyWorkspace.conversationJoin = { [weak self] roomID in
            guard let self, let matrix = self.liveMatrix else { return false }
            return await matrix.acceptInvite(roomID: roomID, directoryConfirmedConversation: true)
        }
        companyWorkspace.onLeft = { [weak self] rooms in
            guard let self else { return }
            self.companyLeftRooms = rooms
            self.companyLeftToken &+= 1
            if let roomID = self.conversation?.roomID, rooms.contains(roomID) {
                self.closeConversation()
            }
        }
    }

    private func beginCompanyAccountScope(_ accountID: String) {
        guard companyAccountID != accountID else { return }
        companyWorkspace.beginAccountScope(accountID)
        companyAccountID = accountID
        companyLeftRooms.removeAll()
        companyLeftToken &+= 1
        accountScopeGeneration &+= 1
    }

    private func clearCompanyAccountScope() {
        companyWorkspace.clear()
        companyAccountID = nil
        companyLeftRooms.removeAll()
        companyLeftToken &+= 1
        accountScopeGeneration &+= 1
    }

    /// The non-E2EE line above the composer: company channels only, until
    /// this phone has sent something in the open chat.
    func companyChatNotice(roomID: String) -> String? {
        guard let claim = companyWorkspace.claim(roomID: roomID),
              conversation?.roomID == roomID,
              let copy = companyWorkspace.copy else { return nil }
        let required = CompanyChannelNotice.isRequired(isCompanyChannel: true,
                                                       roomEncrypted: conversation?.roomIsEncrypted)
        let hasOwn = conversation?.snapshot.rows.contains(where: { $0.item.isOwn }) ?? false
        guard CompanyChannelNotice.showsAboveComposer(required: required,
                                                      hasOwnMessage: hasOwn) else { return nil }
        _ = claim
        return copy.notEncrypted
    }

    /// What the open chat shows for a company DM or group DM: the platform's
    /// name for it, the privacy note until the first message, the read-only
    /// banner in place of the composer, and who is already in (for Add people).
    func conversationChat(roomID: String) -> ConversationChatPresentation? {
        guard conversation?.roomID == roomID,
              let claim = companyWorkspace.conversationClaim(roomID: roomID),
              let record = companyWorkspace.conversations.conversation(roomID: roomID),
              let kept = companyWorkspace.conversations.kept(roomID: roomID),
              let copy = companyWorkspace.copy else { return nil }
        let text = ConversationCopy(design: copy.design)
        let readOnly = record.isReadOnly
        let required = CompanyChannelNotice.isRequired(isCompanyChannel: true,
                                                       roomEncrypted: conversation?.roomIsEncrypted)
        let hasOwn = conversation?.snapshot.rows.contains(where: { $0.item.isOwn }) ?? false
        // A stale list (the last read failed) keeps the transcript readable and closes the composer
        // and every write until a read succeeds.
        let stale = !companyWorkspace.conversations.isFresh(roomID: roomID)
        let showsNote = !readOnly && !stale
            && CompanyChannelNotice.showsAboveComposer(required: required, hasOwnMessage: hasOwn)
        return ConversationChatPresentation(
            companyID: claim.companyID, conversationID: claim.conversationID, title: claim.title,
            isReadOnly: readOnly, isStale: stale,
            canAddPeople: !readOnly && !stale && record.state == .active
                && record.participants.count < CompanyConversation.maximumParticipants,
            canHide: !stale,
            note: showsNote ? text.note : nil,
            banner: stale ? text.failed : (readOnly ? text.readOnlyBanner : nil),
            kept: kept)
    }

    /// The info sheet's company block: the platform roster, never the Matrix
    /// member list, plus the leave path.
    func companyChatInfo(roomID: String) -> CompanyChatInfo? {
        guard let claim = companyWorkspace.claim(roomID: roomID) else { return nil }
        return CompanyChatInfo(
            companyID: claim.companyID,
            companyName: companyWorkspace.companyName(claim.companyID) ?? claim.displayName,
            channelName: claim.displayName,
            members: companyWorkspace.members(companyID: claim.companyID),
            membersLoading: companyWorkspace.membersLoading.contains(claim.companyID),
            leavePending: companyWorkspace.isLeavePending(companyID: claim.companyID),
            notice: companyWorkspace.copy?.notEncrypted ?? "")
    }

    func refreshCompanyWorkspace() async {
        configureCompanyWorkspaceIfNeeded()
        await companyWorkspace.refresh()
    }

    func refreshProduct() async {
        guard !isRefreshingProduct else { return }
        isRefreshingProduct = true
        defer { isRefreshingProduct = false }

        configureCompanyWorkspaceIfNeeded()
        async let matrixRefresh: Void = refreshMatrix()
        async let domainRefresh: Void = refreshDomainReads()
        async let recoveryRefresh: Void = refreshRecoveryState()
        async let firstRunRefresh: Void = refreshFirstRunMarker()
        async let companyRefresh: Void = companyWorkspace.refresh()
        _ = await (matrixRefresh, domainRefresh, recoveryRefresh, firstRunRefresh, companyRefresh)
        pruneRevealedHiddenRooms()
        // Agents and apps may load after the invites arrived.
        if let liveMatrix { acceptKnownInvites(liveMatrix.invites, session: liveMatrix) }
        await refreshAppBotPointers()
        await refreshAppShortcuts()
        startPendingAssistantLifecycleResume()
    }

    // MARK: Push notifications

    /// Called once the chat list is on screen with rooms: the sensible moment
    /// to ask, after the person has seen what Atum is. Asked once per install.
    func chatListDidAppear() async {
        guard case .signedIn = stage, !pushConsidered else { return }
        pushConsidered = true
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            LiveFlowLog.push(.permission, outcome: "already_granted")
            UIApplication.shared.registerForRemoteNotifications()
        case .denied:
            LiveFlowLog.push(.permission, outcome: "denied_before")
        case .notDetermined:
            if pushPromptStore.wasShown {
                LiveFlowLog.push(.permission, outcome: "asked_before")
            } else {
                notificationPromptVisible = true
                LiveFlowLog.push(.permission, outcome: "prompt_shown")
            }
        @unknown default:
            LiveFlowLog.push(.permission, outcome: "unknown_status")
        }
    }

    func answerNotificationPrompt(allow: Bool) async {
        guard notificationPromptVisible else { return }
        notificationPromptVisible = false
        pushPromptStore.markShown()
        guard allow else {
            LiveFlowLog.push(.permission, outcome: "not_now")
            return
        }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            LiveFlowLog.push(.permission, outcome: granted ? "granted" : "declined")
            if granted { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            LiveFlowLog.push(.permission, outcome: "request_failed", code: LiveAuthDiagnostics.code(error))
        }
    }

    /// APNs gave this phone a token: register the Matrix pusher for it. The
    /// APNs environment comes from the signed `aps-environment` in the
    /// embedded profile, cross-checked against the build flag; a mismatch
    /// (for example a development-signed Release build) registers nothing.
    /// A rotated token sets the new pusher first and then deletes the old.
    func receiveRemoteNotificationToken(_ data: Data) async {
        guard let current = context else {
            LiveFlowLog.push(.pusher, outcome: "skipped_signed_out")
            return
        }
        LiveFlowLog.push(.apnsRegister, outcome: "token_received")
        let device: MobilePushDevice = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        let outcome = await push.receive(
            tokenBytes: data,
            build: LivePushEnvironment.build,
            signed: LivePushEnvironment.signed(),
            device: device,
            locale: MobilePushLocale(languageTag: Locale.preferredLanguages.first ?? "vi"),
            using: current.runtime
        )
        switch outcome {
        case let .set(environment, _, previous):
            LiveFlowLog.push(.pusher,
                             outcome: previous == .removalFailed ? "set_previous_remove_failed" : "set",
                             code: environment == .sandbox ? "dev" : "prod")
        case .unchanged:
            break
        case let .refused(reason):
            LiveFlowLog.push(.pusher, outcome: "refused", code: reason.rawValue)
        case .invalidToken:
            LiveFlowLog.push(.pusher, outcome: "failed", code: "invalid_token")
        case .failed:
            LiveFlowLog.push(.pusher, outcome: "failed", code: "transport")
        }
    }

    /// S3: the pusher must not outlive the session it was created for.
    /// Best effort, while the client still authenticates; a failure is a
    /// closed log code and never blocks the sign-out itself.
    private func removePushForSignOut(using runtime: MatrixLiveRuntime) async {
        switch await push.signOut(using: runtime) {
        case .removed: LiveFlowLog.push(.pusher, outcome: "removed_on_sign_out")
        case .nothingRegistered: break
        case .removalFailed: LiveFlowLog.push(.pusher, outcome: "sign_out_removal_failed")
        }
    }

    func remoteNotificationRegistrationFailed(_ error: any Error) {
        LiveFlowLog.push(.apnsRegister, outcome: "failed", code: LiveAuthDiagnostics.code(error))
    }

    private func observeInvites(on matrix: LiveMatrixSession) {
        matrix.onInvitesChanged = { [weak self, weak matrix] invites in
            guard let self, let matrix else { return }
            let published = Set(invites.map(\.roomID))
            for roomID in self.invitationDeclinesAwaitingReplacement {
                if published.contains(roomID) {
                    self.suppressedInvitationIDs.remove(roomID)
                    self.recordRoomActionFailure(roomID)
                }
            }
            self.invitationDeclinesAwaitingReplacement.removeAll()
            self.suppressedInvitationIDs.formIntersection(published)
            self.acceptKnownInvites(invites, session: matrix)
        }
        matrix.onRoomsChanged = { [weak self, weak matrix] rooms in
            guard let self, let matrix, self.liveMatrix === matrix else { return }
            self.roomPublicationRevision &+= 1
            self.reconcileRoomMutations(with: rooms, revision: self.roomPublicationRevision)
            self.reconcileFounderBindingFromKnownMarker()
        }
        matrix.onSessionInvalid = { [weak self, weak matrix] in
            guard let self, let matrix else { return }
            self.matrixSessionBecameInvalid(matrix)
        }
        matrix.onSessionReady = { [weak self, weak matrix] in
            guard let self, let matrix, self.liveMatrix === matrix else { return }
            self.attachConversation()
            Task { @MainActor [weak self] in
                await self?.refreshShareActivity()
                await self?.refreshAppBotPointers()
                await self?.refreshAppShortcuts()
                await self?.refreshFirstRunMarker()
                await self?.refreshFounderChat()
            }
        }
        matrix.onInitialSyncCompleted = { [weak self, weak matrix] in
            guard let self, let matrix, self.liveMatrix === matrix else { return }
            Task { @MainActor [weak self] in
                await self?.refreshAppShortcuts()
                await self?.refreshFirstRunMarker()
                await self?.refreshFounderChat()
            }
        }
        matrix.onSyncRecovered = { [weak self, weak matrix] in
            guard let self, let matrix, self.liveMatrix === matrix else { return }
            self.conversation?.resumeAfterReconnect()
            Task { @MainActor [weak self] in
                await self?.refreshFirstRunMarker()
                await self?.refreshFounderChat()
            }
        }
        matrix.onForegroundReturn = { [weak self, weak matrix] in
            guard let self, let matrix, self.liveMatrix === matrix else { return }
            Task { @MainActor [weak self] in await self?.refreshDomainOnForeground() }
        }
    }

    /// 0.20 agent and bot rooms arrive as invites. Accept those whose inviter
    /// is one of the owner's agents or a catalog bot; leave every other
    /// invite alone. Each invite is tried once per session.
    private func acceptKnownInvites(_ invites: [LiveMatrixInvite], session: LiveMatrixSession) {
        guard liveMatrix === session, !invites.isEmpty else { return }
        var known = catalogBotUserIDs
        for agent in agentsRead.value?.agents ?? [] {
            if let user = agent.matrixUser?.rawValue { known.insert(user) }
        }
        for invite in invites where !attemptedInvites.contains(invite.roomID) {
            guard MobileInvitePolicy.shouldAutoAccept(inviterID: invite.inviterID,
                                                      knownAgentAndBotUserIDs: known,
                                                      roomType: invite.roomType) else {
                // While /agents or /apps are still loading the inviter may be
                // unknown only for now, so it is not marked as tried yet.
                if agentsRead.value != nil, appsRead.value != nil {
                    attemptedInvites.insert(invite.roomID)
                    LiveFlowLog.roster(.invite, outcome: "left_for_person", roomID: invite.roomID)
                }
                continue
            }
            attemptedInvites.insert(invite.roomID)
            Task { @MainActor [weak self, weak session] in
                guard let session else { return }
                let joined = await session.acceptInvite(roomID: invite.roomID)
                guard let self, self.liveMatrix === session else { return }
                LiveFlowLog.roster(.invite, outcome: joined ? "auto_joined" : "join_failed",
                                   roomID: invite.roomID)
                if !joined { self.attemptedInvites.remove(invite.roomID) }
            }
        }
    }

    private func pruneRevealedHiddenRooms() {
        guard let rooms = liveMatrix?.rooms, !rooms.isEmpty else { return }
        var timestamps = [String: UInt64?]()
        for room in rooms { timestamps[room.roomID] = room.latestTimestamp }
        let revealed = hiddenRooms.pruneRevealed(latestTimestamps: timestamps)
        guard !revealed.isEmpty else { return }
        hiddenRoomStore?.save(hiddenRooms)
        for roomID in revealed {
            LiveFlowLog.botRoom(.unhide, outcome: "new_message", roomID: roomID)
        }
    }

    func restoreMessages(using recoveryKey: String) async -> RecoveryRestoreResult {
        guard let current = context, !recoveryInProgress else { return .failed }
        recoveryInProgress = true
        defer { recoveryInProgress = false }
        do {
            let snapshot = try await current.runtime.recover(using: recoveryKey)
            guard context?.runtime === current.runtime else { return .failed }
            matrixRecoverySnapshot = snapshot
            await conversation?.reloadAfterRecovery()
            guard context?.runtime === current.runtime, snapshot.recovery == .ready else { return .failed }
            refreshLocalRecoveryKeyState(current)
            return .restored
        } catch {
            guard context?.runtime === current.runtime else { return .failed }
            let code = LiveAuthDiagnostics.code(error)
            switch MobileManualRecoveryKeyPolicy.presentation(forFailureCode: code) {
            case .retryKey:
                return .rejected
            case .stillRestoring:
                for _ in 0..<Int(MobileManualRecoveryKeyPolicy.pendingWaitSeconds) {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return .failed }
                    guard context?.runtime === current.runtime else { return .failed }
                    guard let snapshot = try? await current.runtime.recoverySnapshot() else { continue }
                    matrixRecoverySnapshot = snapshot
                    if snapshot.recovery == .ready {
                        await conversation?.reloadAfterRecovery()
                        refreshLocalRecoveryKeyState(current)
                        return .restored
                    }
                }
                return .failed
            case .genericRetry:
                return .failed
            }
        }
    }

    func bootstrap() async {
        guard bootstrapTask == nil else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
        bootstrapTask = nil
    }

    /// W4 E3, coordinator decision 11: "Đăng nhập lại" on the expired-session
    /// screen. Custody is read again at the tap, without spending: a ready
    /// grant launches again and an unreadable Keychain moves nothing. Else the
    /// stranded Matrix/domain records move aside, never deleted or overwritten
    /// (`StrandedSessionArchive`), and the normal sign-in starts as a new
    /// installation beside them: plain chats come back after it; old
    /// encrypted history may stay as placeholders (the recovery row in
    /// Account). A cancelled browser leaves the ordinary welcome screen.
    func signInAgain() async {
        guard stage == .recoveryRequired, launchFailureOutcome == .sessionExpired, !isBusy else { return }
        guard let clients, let metadata else {
            await retryBootstrap()
            return
        }
        let custody: MobileSessionContinuityPolicy.CustodyGrant?
        do {
            if let installation = try marker.load() {
                custody = custodyGrant(MatrixSessionKeychain(generation: installation.generation,
                                                             clients: clients, metadata: metadata))
            } else {
                custody = nil
            }
        } catch {
            // A marker that cannot be read with the app in front is stranded
            // too; the archive moves it unread.
            custody = .refused
        }
        switch MobileSessionContinuityPolicy.signInAgainStep(custody: custody) {
        case .launchAgain:
            LiveFlowLog.session(.continuity, outcome: "sign_in_again_custody_ready")
            await retryBootstrap()
            return
        case .retryLater:
            LiveFlowLog.session(.continuity, outcome: "sign_in_again_custody_unreadable")
            return
        case .archiveThenSignIn:
            break
        }
        // Release anything still open from the stranded session first.
        invalidateAppAccount()
        clearAssistantLifecycle()
        productTask?.cancel()
        productTask = nil
        assistantPlacementTask?.cancel()
        assistantPlacementTask = nil
        homeHoldTask?.cancel()
        homeHoldTask = nil
        roomMutationQueue.cancelAll()
        pendingRoomMutations = [:]
        if let liveMatrix { await liveMatrix.stop() }
        liveMatrix = nil
        if let runtime = context?.runtime { await runtime.pause() }
        if let current = context { await withdrawDrive(current, reason: .signInAgain) }
        else { await withdrawContextlessDrive(reason: .signInAgain) }
        context = nil
        clearCompanyAccountScope()
        do {
            let receipt = try StrandedSessionArchive(marker: marker).archive()
            LiveFlowLog.session(.continuity, outcome: "sign_in_again_archived", code: receipt.logCode)
        } catch {
            LiveAuthDiagnostics.record(phase: "sign_in_again_archive", error: error)
            LiveFlowLog.session(.continuity, outcome: "sign_in_again_archive_failed",
                                code: LiveAuthDiagnostics.code(error))
            return
        }
        launchFailureOutcome = nil
        stage = .signedOut(nil)
        await signIn()
    }

    /// Decision 11, in the product: custody refused and the working token has
    /// expired, so nothing can sync or send on this session. The chat closes
    /// (its draft is kept for this run) and the sign-in screen with the
    /// expired-session notice shows. Matrix/domain custody is untouched;
    /// account-scoped Drive bytes and its separate refresh grant are withdrawn.
    private func endStrandedSession() async {
        guard case .signedIn = stage else { return }
        LiveFlowLog.session(.continuity, outcome: "product_custody_refused_sign_in")
        invalidateAppAccount()
        clearAssistantLifecycle()
        closeConversation()
        productTask?.cancel()
        productTask = nil
        assistantPlacementTask?.cancel()
        assistantPlacementTask = nil
        homeHoldTask?.cancel()
        homeHoldTask = nil
        roomMutationQueue.cancelAll()
        pendingRoomMutations = [:]
        if let liveMatrix { await liveMatrix.stop() }
        liveMatrix = nil
        if let runtime = context?.runtime { await runtime.pause() }
        if let current = context { await withdrawDrive(current, reason: .forcedSessionEnd) }
        else { await withdrawContextlessDrive(reason: .forcedSessionEnd) }
        context = nil
        domainClient = nil
        clearCompanyAccountScope()
        ownerTimeZone.end(clearStoredValue: false)
        routineSnapshots.removeAll()
        launchFailureOutcome = .sessionExpired
        stage = .recoveryRequired
    }

    func retryBootstrap() async {
        guard !isBusy else { return }
        lastLaunchAttemptAt = Date()
        if case .recoveryRequired = stage {
            // 0.20: this screen is never a dead end. Release the current
            // client first so the relaunch path opens the store alone.
            LiveFlowLog.session(.blockedRetry, outcome: "started")
            productTask?.cancel()
            productTask = nil
            clearAssistantLifecycle()
            assistantPlacementTask?.cancel()
            assistantPlacementTask = nil
            homeHoldTask?.cancel()
            homeHoldTask = nil
            roomMutationQueue.cancelAll()
            pendingRoomMutations = [:]
            if let liveMatrix { await liveMatrix.stop() }
            liveMatrix = nil
            if let runtime = context?.runtime { await runtime.pause() }
            context = nil
            ownerTimeZone.end(clearStoredValue: false)
        }
        stage = .booting
        await bootstrap()
    }

    func signIn() async {
        guard case .signedOut = stage, !isBusy,
              let clients, let metadata else { return }
        LiveAuthDiagnostics.clear()
        var failurePhase = "matrix_preflight"
        let generation = UUID()
        let reader = MatrixSessionReader(clients: clients, metadata: metadata)
        let prospectiveDomain = OIDCDomainKeychain(generation: generation,
                                                   clients: clients, metadata: metadata)
        var durableIdentityStarted = false
        do {
            // Repeat all three inventories at the user gesture boundary. The
            // earlier launch read cannot authorize a browser flow later.
            try reader.requireAbsent()
            try prospectiveDomain.requireAbsentForExplicitSignIn()
            logRecoveryJournalSurvivor()

            let signIn = try makeSignIn(clients: clients, metadata: metadata)
            stage = .authorizingMatrix
            failurePhase = "matrix_authorization"
            let matrix = try await signIn.matrix(deviceID: Self.newDeviceID(),
                                                 sessionReader: reader)

            stage = .preparingDevice
            failurePhase = "device_preparation"
            let installation = try marker.createForExplicitSignIn(generation: generation)
            durableIdentityStarted = true
            let sessionStore = MatrixSessionKeychain(generation: generation,
                                                     clients: clients, metadata: metadata)
            let prepared = try sessionStore.prepare(device: matrix.device,
                                                    marker: marker,
                                                    requestStartedAt: matrix.delivery.requestStartedAt)
            let directories = try MatrixStoreDirectory()
            let runtime = try await MatrixLiveRuntime.create(prepared: prepared,
                                                             store: sessionStore,
                                                             marker: marker,
                                                             recoveryStore: recovery,
                                                             directories: directories,
                                                             reader: reader)
            // 0.20 (E3): sign-in never prepares a recovery key. Old history
            // is opened later, only if the person chooses to, from Account.
            LiveFlowLog.session(.signInRecovery, outcome: "skipped")

            let domainStore = OIDCDomainKeychain(generation: generation,
                                                 clients: clients, metadata: metadata)
            let current = Context(installation: installation,
                                  sessionStore: sessionStore,
                                  domainStore: domainStore,
                                  runtime: runtime,
                                  domainRefresh: nil)
            context = current
            stage = .authorizingDomain
            failurePhase = "domain_authorization"
            do {
                let domain = try await signIn.domain(matrix: runtime.ticket,
                                                     installation: installation,
                                                     store: domainStore)
                try runtime.requireCurrent()
                let signedIn = Context(installation: installation,
                                       sessionStore: sessionStore,
                                       domainStore: domainStore,
                                       runtime: runtime,
                                       domainRefresh: domain.refresh)
                context = signedIn
                publishSignedIn(signedIn)
                LiveReporting.shared.signInCompleted()
                LiveAuthDiagnostics.recordSuccess()
            } catch {
                LiveAuthDiagnostics.record(phase: failurePhase, error: error)
                if Self.domainNotice(error) == .cancelled {
                    LiveReporting.shared.signInCancelled()
                } else {
                    LiveReporting.shared.signInFailed()
                }
                stage = .domainRequired(Self.domainNotice(error))
            }
        } catch {
            LiveAuthDiagnostics.record(phase: failurePhase, error: error)
            if Self.initialNotice(error) == .cancelled {
                LiveReporting.shared.signInCancelled()
            } else {
                LiveReporting.shared.signInFailed()
            }
            if durableIdentityStarted {
                launchFailureOutcome = .retryLaunch
                stage = .recoveryRequired
            } else {
                stage = .signedOut(Self.initialNotice(error))
            }
        }
    }

    func continueDomainSignIn() async {
        guard case .domainRequired = stage, let context,
              let clients, let metadata else { return }
        LiveAuthDiagnostics.clear()
        do {
            try context.runtime.requireCurrent()
            let signIn = try makeSignIn(clients: clients, metadata: metadata)
            stage = .authorizingDomain
            let domain = try await signIn.domain(matrix: context.runtime.ticket,
                                                 installation: context.installation,
                                                 store: context.domainStore)
            try context.runtime.requireCurrent()
            let signedIn = Context(installation: context.installation,
                                   sessionStore: context.sessionStore,
                                   domainStore: context.domainStore,
                                   runtime: context.runtime,
                                   domainRefresh: domain.refresh)
            self.context = signedIn
            publishSignedIn(signedIn)
            LiveReporting.shared.signInCompleted()
            LiveAuthDiagnostics.recordSuccess()
        } catch {
            LiveAuthDiagnostics.record(phase: "domain_authorization", error: error)
            if Self.domainNotice(error) == .cancelled {
                LiveReporting.shared.signInCancelled()
            } else {
                LiveReporting.shared.signInFailed()
            }
            stage = .domainRequired(Self.domainNotice(error))
        }
    }

    /// Repairs only the independent account/domain grant while the Matrix
    /// session, rooms and drafts stay live. A refresh has already been tried
    /// before this action is offered. The unresolved record is preserved under
    /// the archive service, then the existing domain-only OIDC flow creates a
    /// new grant for this same installation.
    func reauthenticateDomain() async {
        guard case .signedIn = stage,
              domainRecoveryState == .reauthenticationRequired,
              !domainReauthenticationInProgress,
              let current = context,
              let clients else { return }
        domainReauthenticationInProgress = true
        defer { domainReauthenticationInProgress = false }

        let metadata: MASMetadata
        do {
            if let existing = self.metadata {
                metadata = existing
            } else {
                metadata = try await MASProduction.metadata(using: transport)
                self.metadata = metadata
            }
        } catch {
            // Discovery/reachability is retryable. It is deliberately not
            // rewritten as a grant reauthentication diagnostic.
            LiveAuthDiagnostics.record(phase: "domain_discovery_retry", error: error)
            return
        }

        do {
            try current.runtime.requireCurrent()
            let moved = try StrandedSessionArchive(marker: marker).archiveDomain()
            LiveFlowLog.session(.continuity, outcome: "domain_grant_archived",
                                code: "d\(moved)")
            let signIn = try makeSignIn(clients: clients, metadata: metadata)
            let domain = try await signIn.domain(matrix: current.runtime.ticket,
                                                 installation: current.installation,
                                                 store: current.domainStore)
            try current.runtime.requireCurrent()
            let repaired = Context(installation: current.installation,
                                   sessionStore: current.sessionStore,
                                   domainStore: current.domainStore,
                                   runtime: current.runtime,
                                   domainRefresh: domain.refresh)
            context = repaired
            domainClient = makeDomainClient(refresh: domain.refresh, metadata: metadata)
            domainRecoveryState = .available
            LiveAuthDiagnostics.recordSuccess()
            await refreshDomainReads()
            guard context?.installation == current.installation else { return }
            if let liveMatrix { acceptKnownInvites(liveMatrix.invites, session: liveMatrix) }
            await refreshCompanyWorkspace()
            await refreshAppBotPointers()
            await refreshAppShortcuts()
            startPendingAssistantLifecycleResume()
        } catch {
            LiveAuthDiagnostics.record(phase: "domain_reauthorization", error: error)
            domainClient = nil
            domainRecoveryState = .reauthenticationRequired
        }
    }

    private var isBusy: Bool {
        switch stage {
        case .booting, .authorizingMatrix, .preparingDevice, .authorizingDomain:
            return true
        default:
            return false
        }
    }

    private func performBootstrap() async {
        LiveAuthDiagnostics.clear()
        do { _ = try localSignOut?.resumePending() }
        catch {
            LiveAuthDiagnostics.record(phase: "bootstrap_sign_out_resume", error: error)
            launchFailureOutcome = .retryLaunch
            stage = .unavailable
            return
        }
        var failurePhase = "bootstrap_configuration"
        let clients: MASPublicClients
        let metadata: MASMetadata
        do {
            clients = try MASProduction.clients()
            failurePhase = "bootstrap_metadata"
            metadata = try await MASProduction.metadata(using: transport)
            self.clients = clients
            self.metadata = metadata
        } catch {
            LiveAuthDiagnostics.record(phase: failurePhase, error: error)
            launchFailureOutcome = .retryLaunch
            stage = .unavailable
            return
        }

        let reader = MatrixSessionReader(clients: clients, metadata: metadata)
        var launchCustody: MatrixSessionKeychain?
        do {
            failurePhase = "bootstrap_installation"
            guard let installation = try marker.load() else {
                failurePhase = "bootstrap_empty_inventory"
                // Attributes only; throws when the Keychain cannot be read
                // (the quiet retry state, below).
                let survivors = try StrandedSessionArchive(marker: marker).survivors()
                logRecoveryJournalSurvivor()
                guard survivors.isEmpty else {
                    // W4 E3 (decision 11): records that survived without
                    // their installation (a reinstall keeps Keychain items)
                    // can open no session and block every sign-in: the
                    // sign-in screen, whose "Đăng nhập lại" moves them aside.
                    launchFailureOutcome = MobileSessionContinuityPolicy.outcome(for: .recordsWithoutInstallation)
                    LiveFlowLog.session(.continuity, outcome: "launch_records_without_installation",
                                        code: survivors.logCode)
                    stage = .recoveryRequired
                    return
                }
                stage = .signedOut(nil)
                return
            }

            failurePhase = "bootstrap_matrix_custody"
            let sessionStore = MatrixSessionKeychain(generation: installation.generation,
                                                     clients: clients, metadata: metadata)
            launchCustody = sessionStore
            failurePhase = "bootstrap_matrix_refresh"
            let matrixResume = try sessionStore.resumeGrantForRefresh(marker: marker)
            let matrixRefresh = try OIDCGrantRefresh(resuming: matrixResume)
            _ = try await matrixRefresh.accessToken(now: Date()) { request in
                try await self.transport.refresh(request, metadata: metadata)
            }
            failurePhase = "bootstrap_matrix_custody"
            let ticket = try sessionStore.resume(marker: marker)
            let directories = try MatrixStoreDirectory()
            failurePhase = "bootstrap_matrix_runtime"
            let runtime = try await MatrixLiveRuntime.resume(ticket: ticket,
                                                             store: sessionStore,
                                                             marker: marker,
                                                             recoveryStore: recovery,
                                                             directories: directories,
                                                             reader: reader)
            resumeRecoveryJournal(session: ticket, sessionStore: sessionStore,
                                  installationID: installation.id)
            let domainStore = OIDCDomainKeychain(generation: installation.generation,
                                                 clients: clients, metadata: metadata)
            context = Context(installation: installation,
                              sessionStore: sessionStore,
                              domainStore: domainStore,
                              runtime: runtime,
                              domainRefresh: nil)
            var domainFailure: (any Error)?
            var restoredDomainRefresh: OIDCGrantRefresh?
            do {
                failurePhase = "bootstrap_domain"
                let domain = try domainStore.resume(installation: marker)
                try domain.account.reconcile(matrix: runtime.ticket)
                restoredDomainRefresh = try OIDCGrantRefresh(resuming: domain)
                domainRecoveryState = .available
            } catch {
                domainFailure = error
                domainRecoveryState = MobileDomainRecoveryPolicy.state(for: error)
            }
            // The Matrix session must still be current; a failure here is a
            // launch failure (the outer catch).
            failurePhase = "bootstrap_runtime_recheck"
            try runtime.requireCurrent()
            let resumed = Context(installation: installation, sessionStore: sessionStore, domainStore: domainStore,
                                  runtime: runtime, domainRefresh: restoredDomainRefresh)
            if let domainFailure {
                LiveAuthDiagnostics.record(phase: "bootstrap_domain", error: domainFailure)
                // Chats always open. A definitive grant failure becomes one
                // inline Home action; discovery/storage failures remain quiet
                // retry states. No Matrix state is removed.
                LiveFlowLog.session(.continuity, outcome: "launch_without_account_service",
                                    code: LiveAuthDiagnostics.code(domainFailure))
                publishSignedIn(resumed)
            } else {
                publishSignedIn(resumed)
                LiveAuthDiagnostics.recordSuccess()
            }
        } catch {
            LiveAuthDiagnostics.record(phase: failurePhase, error: error)
            // W4 E3: a custody that refuses (a spend journaled and never
            // finished) is an expired session, not a network problem: no
            // automatic retries and no "check your connection".
            let outcome = MobileSessionContinuityPolicy.outcome(
                for: .matrix(custody: launchCustody.map { custodyGrant($0) })
            )
            launchFailureOutcome = outcome
            LiveFlowLog.session(.continuity,
                                outcome: outcome == .sessionExpired ? "launch_custody_refused" : "launch_retry_state",
                                code: LiveAuthDiagnostics.code(error))
            stage = .recoveryRequired
        }
    }

    /// A recovery-key record from an earlier sign-in is kept untouched (it may
    /// be the only copy) and never blocks signing in again.
    private func logRecoveryJournalSurvivor() {
        do {
            try recovery.requireAbsentForExplicitSignIn()
            LiveFlowLog.session(.recoveryJournal, outcome: "absent")
        } catch {
            LiveFlowLog.session(.recoveryJournal, outcome: "survivor_kept")
        }
    }

    /// The phone-only recovery journal is optional since 0.20: a missing or
    /// unmatched record means only that old history needs the person's key.
    private func resumeRecoveryJournal(session: MatrixCustodyTicket,
                                       sessionStore: MatrixSessionKeychain,
                                       installationID: UUID? = nil) {
        do {
            let ticket = try recovery.resumeForExplicitReconciliation(session: session,
                                                                      sessionStore: sessionStore,
                                                                      marker: marker)
            _ = ticket
            holdsRecoveryKey = true
            if let installationID = installationID ?? context?.installation.id {
                recoveryKeySavedOnThisPhone = recoverySavedStore.isSaved(installationID: installationID)
            }
            LiveFlowLog.session(.recoveryJournal, outcome: "present")
        } catch {
            holdsRecoveryKey = false
            recoveryKeySavedOnThisPhone = false
            LiveFlowLog.session(.recoveryJournal, outcome: "unavailable_" + LiveAuthDiagnostics.code(error))
        }
    }

    private func makeSignIn(clients: MASPublicClients,
                            metadata: MASMetadata) throws -> OIDCSignIn {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let anchor = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow,
              anchor.isKeyWindow else { throw OIDCFailure.browserUnavailable }
        let flows = OIDCFlows()
        return MASWebAuthPresenter(anchor: anchor, flows: flows)
            .signIn(clients: clients, metadata: metadata, transport: transport)
    }

    private func publishSignedIn(_ current: Context) {
        if appAccountInstallationID != current.installation.id {
            invalidateAppAccount(nextInstallationID: current.installation.id)
        }
        let fallback = LiveAccountSummary(matrixUserID: current.runtime.ticket.session.userID,
                                          displayName: nil)
        ownerTimeZone.begin(accountID: fallback.matrixUserID)
        loadChatListSnapshot(accountID: fallback.matrixUserID)
        stage = .signedIn(fallback)
        launchFailureOutcome = nil
        renewalRetry = MobileSessionContinuityPolicy.RenewalRetry()
        beginProduct(current)
        Task { @MainActor [weak self] in
            guard let self,
                  let profile = await current.runtime.currentProfile(),
                  profile.displayName != nil || profile.avatarURL != nil,
                  self.context?.installation == current.installation,
                  case let .signedIn(existing) = self.stage,
                  existing.matrixUserID == fallback.matrixUserID else { return }
            self.stage = .signedIn(LiveAccountSummary(matrixUserID: fallback.matrixUserID,
                                                      displayName: profile.displayName,
                                                      avatarURL: profile.avatarURL))
        }
    }

    /// Settings' inline name edit. The write is the SDK's own-profile call;
    /// the summary changes only after it succeeds, and only for the account
    /// and installation that asked.
    func saveProfileName(_ name: String) async -> AccountProfileSaveResult {
        // The editor already refused a name outside the desktop's rule; the
        // model checks again so no caller can write one (the desktop checks in
        // the window, at the native boundary and in the SDK host alike).
        guard AccountProfileName.validate(name) == .valid(name),
              let current = context, case let .signedIn(before) = stage else { return .failed }
        do {
            try await current.runtime.setOwnDisplayName(name)
        } catch {
            return .failed
        }
        guard context?.installation == current.installation,
              case let .signedIn(existing) = stage,
              existing.matrixUserID == before.matrixUserID else { return .failed }
        stage = .signedIn(LiveAccountSummary(matrixUserID: existing.matrixUserID,
                                             displayName: name,
                                             avatarURL: existing.avatarURL))
        return .saved
    }

    /// Settings' inline photo change (nil removes the photo).
    func saveProfilePhoto(_ photo: AccountProfilePhoto?) async -> AccountProfileSaveResult {
        guard let current = context, case let .signedIn(before) = stage else { return .failed }
        let avatarURL: String?
        do {
            avatarURL = try await current.runtime.setOwnAvatar(mimeType: photo?.mimeType ?? "",
                                                                data: photo?.data)
        } catch {
            return .failed
        }
        guard context?.installation == current.installation,
              case let .signedIn(existing) = stage,
              existing.matrixUserID == before.matrixUserID else { return .failed }
        stage = .signedIn(LiveAccountSummary(matrixUserID: existing.matrixUserID,
                                             displayName: existing.displayName,
                                             avatarURL: avatarURL))
        return .saved
    }

    private func invalidateAppAccount(nextInstallationID: UUID? = nil) {
        cancelAppOnboarding()
        appContentPage = nil
        appOnboardingReadyRoomID = nil
        appRouteFailed = false
        appAccountGeneration &+= 1
        appAccountInstallationID = nextInstallationID
        appWorkspaces.removeAll()
        appShortcuts.removeAll()
        appShortcutWriteOperations.removeAll()
        appShortcutMutationRevisions.removeAll()
        appShortcutRefreshEpoch &+= 1
        officialAccountsRead.clear()
        officialAccountsCadence.activate(nil)
        resetFounderState()
    }

    private enum ProductReadResult<Value: Sendable>: Sendable {
        case success(Value)
        case failure(NativeRead<Value>.Condition)
    }

    private enum OfficialAccountsAttempt: Sendable {
        case completed(ProductReadResult<OfficialAccountsResponse>, retryAfterSeconds: Int64?)
        case abandoned
    }

    private func makeDomainClient(refresh: OIDCGrantRefresh,
                                  metadata: MASMetadata) -> NativeDomainClient {
        let tokenTransport = transport
        return NativeDomainClient(
            refresh: refresh,
            preflight: {
                _ = try await MASProduction.metadata(using: tokenTransport)
            },
            exchange: { request in
                try await tokenTransport.refresh(request, metadata: metadata)
            },
            onAuthenticationFailure: { [weak self] error in
                self?.domainAuthenticationFailed(error)
            }
        )
    }

    private func domainAuthenticationFailed(_ error: any Error) {
        guard case .signedIn = stage else { return }
        let state = MobileDomainRecoveryPolicy.state(for: error)
        if state == .reauthenticationRequired {
            domainClient = nil
            domainRecoveryState = state
        }
        LiveAuthDiagnostics.record(
            phase: state == .reauthenticationRequired
                ? "domain_refresh_reauthentication"
                : "domain_refresh_unavailable",
            error: error
        )
    }

    /// Pull-to-refresh and foreground return may repair discovery, a locked
    /// Keychain, or another temporary local failure. A definitive interrupted
    /// spend is never retried silently; Home keeps the one sign-in action.
    private func restoreDomainAccessSilently() async {
        guard domainClient == nil,
              domainRecoveryState != .reauthenticationRequired,
              let current = context,
              let clients else { return }
        do {
            let metadata: MASMetadata
            if let existing = self.metadata {
                metadata = existing
            } else {
                metadata = try await MASProduction.metadata(using: transport)
                self.metadata = metadata
            }
            let resume = try current.domainStore.resume(installation: marker)
            try resume.account.reconcile(matrix: current.runtime.ticket)
            let refresh = try OIDCGrantRefresh(resuming: resume)
            guard context?.installation == current.installation else { return }
            domainClient = makeDomainClient(refresh: refresh, metadata: metadata)
            domainRecoveryState = .available
            LiveFlowLog.session(.continuity, outcome: "account_service_restored_silently")
        } catch {
            guard context?.installation == current.installation else { return }
            domainRecoveryState = MobileDomainRecoveryPolicy.state(for: error)
            LiveAuthDiagnostics.record(
                phase: self.metadata == nil ? "domain_discovery_retry" : "domain_resume_retry",
                error: error
            )
        }
    }

    private func beginProduct(_ current: Context) {
        beginCompanyAccountScope(current.runtime.ticket.session.userID)
        productTask?.cancel()
        productTask = nil
        assistantPlacementTask?.cancel()
        assistantPlacementTask = nil
        cancelAssistantLifecycle()
        assistantLifecycleCapability = nil
        homeHoldTask?.cancel()
        homeHoldTask = nil
        homeHoldExpired = false
        if let previous = liveMatrix {
            Task { @MainActor in await previous.stop() }
        }
        closeConversation()
        drafts = [:]
        for mediaDraft in mediaDrafts.values { mediaDraft.discardAll() }
        mediaDrafts = [:]
        localMediaDrafts = [:]
        matrixRecoverySnapshot = nil
        firstRunMarkerCoordinator?.reset()
        firstRunMarkerCoordinator = nil
        firstRunMarker = .unknown
        agentsRead.clear()
        appsRead.clear()
        appWorkspaces.removeAll()
        appShortcuts.removeAll()
        appShortcutWriteOperations.removeAll()
        appShortcutMutationRevisions.removeAll()
        appShortcutRefreshEpoch &+= 1
        officialAccountsRead.clear()
        officialAccountsCadence.activate(nil)
        officialAccountsCadence.activate(.init(
            accountID: current.runtime.ticket.session.userID,
            generation: officialAccountsClientGeneration
        ))
        resetFounderState()
        storeCatalogRead.clear()
        walletRead.clear()
        routineSnapshots.removeAll()

        let store = LiveHiddenRoomStore(matrixUserID: current.runtime.ticket.session.userID)
        hiddenRoomStore = store
        hiddenRooms = store.load()
        assistantLifecycleStore = LiveAssistantLifecycleStore(
            matrixUserID: current.runtime.ticket.session.userID
        )
        lastLoggedRecoveryState = nil
        loggedAgentRoomChoices = [:]
        attemptedInvites = []
        attemptedDirectTargets = []
        createdAppBotChats = [:]
        attemptedAppBotChatTargets = []
        attemptedGroupBaselines = [:]
        suppressedInvitationIDs = []
        invitationDeclinesAwaitingReplacement = []
        pendingRoomMutations = [:]
        roomMutationQueue.cancelAll()
        roomPublicationRevision = 0

        let matrix = LiveMatrixSession(runtime: current.runtime)
        liveMatrix = matrix
        observeInvites(on: matrix)
        homeHoldTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.context?.installation == current.installation else { return }
            self.homeHoldExpired = true
        }
        beginRecoveryObservation(current: current, matrix: matrix)
        do {
            guard let metadata else {
                throw OIDCFailure.invalidConfiguration
            }
            let refresh: OIDCGrantRefresh
            if let established = current.domainRefresh {
                refresh = established
            } else {
                let resume = try current.domainStore.resume(installation: marker)
                try resume.account.reconcile(matrix: current.runtime.ticket)
                refresh = try OIDCGrantRefresh(resuming: resume)
            }
            domainClient = makeDomainClient(refresh: refresh, metadata: metadata)
            domainRecoveryState = .available
        } catch {
            domainClient = nil
            domainRecoveryState = MobileDomainRecoveryPolicy.state(for: error)
            LiveAuthDiagnostics.record(
                phase: metadata == nil ? "domain_metadata_unavailable" : "domain_resume",
                error: error
            )
            agentsRead.fail(domainCondition(for: error, value: AgentsResponse.self))
            appsRead.fail(domainCondition(for: error, value: AppCatalogResponse.self))
            officialAccountsRead.fail(domainCondition(for: error,
                                                      value: OfficialAccountsResponse.self))
            storeCatalogRead.fail(domainCondition(for: error, value: StoreCatalogResponse.self))
            walletRead.fail(domainCondition(for: error, value: WalletResponse.self))
        }

        if driveSession?.generation != current.installation.generation {
            driveSession = nil
        }
        drive.configure(
            accountID: current.runtime.ticket.session.userID,
            resume: { [weak self] in
                guard let self else { throw DriveFailure.offline }
                return try await self.driveAccess()
            },
            connect: { [weak self] in
                guard let self else { throw DriveFailure.offline }
                return try await self.driveAccess()
            }
        )

        productTask = Task { @MainActor [weak self] in
            guard let self,
                  self.context?.installation == current.installation else { return }
            await self.refreshProduct()
        }
        if let client = domainClient {
            assistantPlacementTask = Task { @MainActor [weak self] in
                await self?.placeAssistantInCloud(using: client, current: current)
            }
        }
        startSessionKeepAlive()
    }

    private func driveAccess() async throws -> LiveDriveAccess {
        guard let current = context, let metadata else {
            throw DriveFailure.serviceUnavailable(retryAfter: nil)
        }
        let account: OIDCRestoredAccount
        do {
            if let existing = driveSession, existing.generation == current.installation.generation {
                account = existing.account
            } else {
                let domain = try current.domainStore.resume(installation: marker)
                try domain.account.reconcile(matrix: current.runtime.ticket)
                account = domain.account
            }
        } catch let failure as OIDCGrantFailure where failure == .storageUnavailable {
            return LiveDriveAccess(cache: nil, state: .serviceUnavailable)
        } catch let failure as OIDCGrantFailure where failure == .refreshInterrupted && domainClient != nil {
            // A live account refresh may currently own the spend journal. Its controller
            // decides recovery; a simultaneous Drive access must not declare it stranded.
            return LiveDriveAccess(cache: nil, state: .serviceUnavailable)
        } catch {
            domainAuthenticationFailed(error)
            return LiveDriveAccess(cache: nil, state: .serviceUnavailable)
        }

        let session: LiveDriveSession
        if let existing = driveSession,
           existing.generation == current.installation.generation,
           existing.account == account {
            session = existing
        } else {
            let cache: DriveCache
            do {
                cache = try DriveCache.live(scope: DriveCacheScope(account: account))
            } catch {
                return LiveDriveAccess(cache: nil, state: .storageUnavailable)
            }
            let store = OIDCDriveKeychain(
                generation: current.installation.generation,
                account: account,
                metadata: metadata
            )
            let created = LiveDriveSession(
                generation: current.installation.generation,
                account: account,
                cache: cache,
                store: store
            )
            driveSession = created
            try? await cache.trim()
            guard context?.installation == current.installation,
                  driveSession === created else {
                return LiveDriveAccess(cache: cache, state: .serviceUnavailable)
            }
            session = created
        }

        // Upgrade cleanup: withdraw the old Drive-only chain before using the account grant.
        // Retry a locked Keychain on the next access; never resume or refresh this grant.
        if !session.legacyGrantCleaned {
            do {
                let record = try session.store.withdraw()
                session.legacyGrantCleaned = true
                if let record {
                    let tokenTransport = transport
                    Task { try? await tokenTransport.revokeDrive(record, metadata: metadata) }
                }
            } catch {
                return LiveDriveAccess(cache: session.cache, state: .storageUnavailable)
            }
        }
        guard let domainClient else {
            return LiveDriveAccess(cache: session.cache, state: .serviceUnavailable)
        }
        if session.domainClient !== domainClient {
            session.client = nil
            session.domainClient = domainClient
        }
        if let client = session.client {
            return LiveDriveAccess(cache: session.cache, state: .active(client))
        }
        if let flight = session.activationFlight { return await flight.value }
        let task = Task<LiveDriveAccess, Never> { @MainActor [weak self, weak session] in
            guard let self, let session else {
                return LiveDriveAccess(cache: nil, state: .serviceUnavailable)
            }
            return await self.activateDriveSession(
                session,
                current: current,
                domainClient: domainClient
            )
        }
        session.activationFlight = task
        let result = await task.value
        if driveSession === session { session.activationFlight = nil }
        return result
    }

    private func activateDriveSession(_ session: LiveDriveSession,
                                      current: Context,
                                      domainClient: NativeDomainClient) async -> LiveDriveAccess {
        let account: DriveAccount
        do { account = try await domainClient.driveAccount() }
        catch let failure as NativeDomainClientFailure {
            switch failure {
            case .transportUnavailable:
                return LiveDriveAccess(cache: session.cache, state: .offline)
            case .cancelled:
                return LiveDriveAccess(cache: session.cache, state: .serviceUnavailable)
            case .authenticationRefused:
                return LiveDriveAccess(cache: session.cache, state: .serviceUnavailable)
            case let .http(http) where http.response.error == .unauthenticated:
                return LiveDriveAccess(cache: session.cache, state: .serviceUnavailable)
            case let .http(http) where http.response.error == .denied:
                return LiveDriveAccess(cache: session.cache, state: .denied)
            case let .http(http) where http.response.error == .rateLimited:
                return LiveDriveAccess(cache: session.cache, state: .rateLimited)
            default:
                return LiveDriveAccess(cache: session.cache, state: .serviceUnavailable)
            }
        } catch {
            return LiveDriveAccess(cache: session.cache, state: .serviceUnavailable)
        }
        guard driveSession === session,
              context?.installation == current.installation else {
            return LiveDriveAccess(cache: session.cache, state: .serviceUnavailable)
        }
        switch account.state {
        case .provisioning:
            return LiveDriveAccess(cache: session.cache, state: .provisioning)
        case .active:
            do {
                let client = try DriveClient(serverURL: account.serverURL, domainClient: domainClient)
                session.client = client
                return LiveDriveAccess(cache: session.cache, state: .active(client))
            } catch {
                return LiveDriveAccess(cache: session.cache, state: .serviceUnavailable)
            }
        case .suspended, .deleting, .deleted:
            return LiveDriveAccess(cache: session.cache, state: .denied)
        }
    }

    private func withdrawDrive(_ current: Context, reason: DriveExitReason) async {
        let memoized = driveSession
        driveSession = nil
        memoized?.activationFlight?.cancel()
        await drive.withdraw(reason: reason)
        DriveCache.wipeAll()
        guard let metadata else {
            try? OIDCDriveKeychain.forceWithdraw(generation: current.installation.generation)
            return
        }
        if let memoized, memoized.generation == current.installation.generation {
            guard let record = try? memoized.store.withdraw() else {
                try? OIDCDriveKeychain.forceWithdraw(generation: current.installation.generation)
                return
            }
            let tokenTransport = transport
            Task { try? await tokenTransport.revokeDrive(record, metadata: metadata) }
            return
        }
        guard let account = try? current.domainStore.resume(installation: marker).account else {
            try? OIDCDriveKeychain.forceWithdraw(generation: current.installation.generation)
            return
        }
        let store = OIDCDriveKeychain(
            generation: current.installation.generation,
            account: account,
            metadata: metadata
        )
        guard let record = try? store.withdraw() else {
            try? OIDCDriveKeychain.forceWithdraw(generation: current.installation.generation)
            return
        }
        let tokenTransport = transport
        Task { try? await tokenTransport.revokeDrive(record, metadata: metadata) }
    }

    private func withdrawContextlessDrive(reason: DriveExitReason) async {
        let memoized = driveSession
        driveSession = nil
        memoized?.activationFlight?.cancel()
        await drive.withdraw(reason: reason)
        DriveCache.wipeAll()
        guard let installation = try? marker.load(), let clients, let metadata else {
            return
        }
        if let memoized, memoized.generation == installation.generation {
            guard let record = try? memoized.store.withdraw() else {
                try? OIDCDriveKeychain.forceWithdraw(generation: installation.generation)
                return
            }
            let tokenTransport = transport
            Task { try? await tokenTransport.revokeDrive(record, metadata: metadata) }
            return
        }
        let domainStore = OIDCDomainKeychain(
            generation: installation.generation,
            clients: clients,
            metadata: metadata
        )
        guard let account = try? domainStore.resume(installation: marker).account else {
            try? OIDCDriveKeychain.forceWithdraw(generation: installation.generation)
            return
        }
        let store = OIDCDriveKeychain(
            generation: installation.generation,
            account: account,
            metadata: metadata
        )
        guard let record = try? store.withdraw() else {
            try? OIDCDriveKeychain.forceWithdraw(generation: installation.generation)
            return
        }
        let tokenTransport = transport
        Task { try? await tokenTransport.revokeDrive(record, metadata: metadata) }
    }

    /// Owner decision 2026-10-19: every new account's assistant is placed in
    /// the cloud at sign-up. The sentence shown on the sign-in screen is the
    /// consent, so here the phone reads the active disclosure version and
    /// reports it once on `POST /assistant` (the desktop's readCloudDisclosure
    /// Version/ensureDomainAssistant contract, including the empty-body retry
    /// for a Shell that predates the versioned body). It runs alongside the
    /// first domain reads and never blocks them: a failure only means this
    /// account behaves as before and the next sign-in tries again. Only a
    /// default assistant that still answers locally is ever enrolled.
    private func placeAssistantInCloud(using client: NativeDomainClient, current: Context) async {
        let version = await client.cloudDisclosureVersion()
        guard !Task.isCancelled, context?.installation == current.installation else { return }
        do {
            try await client.ensureAssistant(disclosureVersion: version,
                                             timeZone: TimeZone.autoupdatingCurrent.identifier)
            LiveFlowLog.session(.cloudPlacement,
                                outcome: version == nil ? "mac_first" : "requested")
        } catch {
            LiveFlowLog.session(.cloudPlacement, outcome: "failed",
                                code: LiveAuthDiagnostics.code(error))
        }
    }

    private func refreshRecoveryState() async {
        guard let current = context else { return }
        do {
            let snapshot = try await current.runtime.recoverySnapshot()
            guard context?.runtime === current.runtime, let liveMatrix else { return }
            receiveRecoverySnapshot(snapshot, matrix: liveMatrix)
            refreshLocalRecoveryKeyState(current)
        } catch {
            guard context?.runtime === current.runtime else { return }
            LiveAuthDiagnostics.record(phase: "recovery_state_refresh", error: error)
        }
    }

    private func beginRecoveryObservation(current: Context, matrix: LiveMatrixSession) {
        current.runtime.observeRecovery { [weak self, weak matrix] snapshot in
            guard let self, let matrix, self.liveMatrix === matrix else { return }
            self.receiveRecoverySnapshot(snapshot, matrix: matrix)
            self.refreshLocalRecoveryKeyState(current)
        }
    }

    private func receiveRecoverySnapshot(_ snapshot: MatrixLiveRecoverySnapshot,
                                         matrix: LiveMatrixSession) {
        guard liveMatrix === matrix else { return }
        matrixRecoverySnapshot = snapshot
        if lastLoggedRecoveryState != snapshot.logCode {
            lastLoggedRecoveryState = snapshot.logCode
            LiveFlowLog.recovery(.trustState, outcome: snapshot.logCode, code: snapshot.logCode)
        }
    }

    private func refreshLocalRecoveryKeyState(_ current: Context) {
        do {
            holdsRecoveryKey = try recovery.currentInput(
                session: current.runtime.ticket, sessionStore: current.sessionStore, marker: marker
            ) != nil
            recoveryKeySavedOnThisPhone = holdsRecoveryKey
                && recoverySavedStore.isSaved(installationID: current.installation.id)
        } catch {
            holdsRecoveryKey = false
            recoveryKeySavedOnThisPhone = false
        }
    }

    /// Server-authored names for the owner's agents (`/agents`) and catalog
    /// bots (`/apps`), keyed by Matrix user ID.
    private var knownAgentAndBotNames: [String: String] {
        var names = [String: String]()
        for app in appsRead.value?.apps ?? [] {
            if let bot = app.bot {
                names[bot.userID.rawValue] = app.name.localized(locale: appLanguage,
                                                                fallback: app.app)
            }
        }
        for agent in agentsRead.value?.agents ?? [] {
            if let user = agent.matrixUser?.rawValue { names[user] = agent.displayName }
        }
        return names
    }

    private var knownAgentAndBotUserIDs: Set<String> {
        Set(knownAgentAndBotNames.keys).union(catalogBotUserIDs)
    }

    private var catalogBotUserIDs: Set<String> {
        LiveRosterRows.catalogBotUserIDs(appsRead.value?.apps ?? [])
    }

    private func botUserID(for room: LiveMatrixRoomRow) -> String? {
        LiveRosterRows.botUserID(for: room, catalogBotUserIDs: catalogBotUserIDs)
    }

    /// The bot's one chat in desktop's order (`LiveRosterRows.botChatChoice`).
    private func botChatChoice(forBot bot: String, appID: String) -> MobileAppBotChatChoice? {
        guard let liveMatrix else { return nil }
        return LiveRosterRows.botChatChoice(forBot: bot, appID: appID, rooms: liveMatrix.rooms,
                                            invites: liveMatrix.invites, pointers: appBotPointers,
                                            catalogBotUserIDs: catalogBotUserIDs)
    }

    /// The chat an app row opens, with the pointer read again first.
    private func botChatToOpen(forAppRow rowID: String) async -> MobileAppBotChatChoice? {
        let appID = String(rowID.dropFirst("app:".count))
        guard let bot = appsRead.value?.apps.first(where: { $0.appID.rawValue == appID })?.bot?.userID.rawValue
        else { return nil }
        await refreshAppBotPointer(appID: appID, botUserID: bot)
        let choice = botChatChoice(forBot: bot, appID: appID)
        LiveFlowLog.botRoom(.pointer, outcome: (appBotPointers[appID] == nil ? "missing_" : "present_")
                                + (choice?.reason.rawValue ?? "no_choice"), roomID: appBotPointers[appID])
        return choice
    }

    /// Reads every catalog bot's pointer from the SDK's cached account data.
    private func refreshAppBotPointers() async {
        for app in appsRead.value?.apps ?? [] {
            guard let bot = app.bot?.userID.rawValue else { continue }
            await refreshAppBotPointer(appID: app.appID.rawValue, botUserID: bot)
        }
    }

    private func refreshAppBotPointer(appID: String, botUserID: String) async {
        guard let current = context else { return }
        let pointer = await current.runtime.appBotPointerRoomID(appID: appID, botUserID: botUserID)
        guard context?.runtime === current.runtime, appBotPointers[appID] != pointer else { return }
        appBotPointers[appID] = pointer
    }

    /// Reads every explicit app-shortcut preference that can produce a phone
    /// row (catalog bots and presentation-only entries) from the current
    /// SDK's synchronized account-data store. That read is a cache, not a
    /// network request, and a nil result before this session has completed
    /// its initial sync is a cache miss rather than proof of absence: until
    /// both readiness gates pass, every candidate stays `unknown` and no read
    /// is attempted. There is no custom-event observer in the pinned SDK, so
    /// this runs with the existing product/foreground/session-ready refresh
    /// and the first-sync completion callback. A wrong runtime/account
    /// generation drops late results; a failed or malformed read stays
    /// `unknown` and the row fails closed.
    private func refreshAppShortcuts() async {
        guard case .signedIn = stage,
              let current = context,
              let matrix = liveMatrix,
              let catalog = appsRead.value else {
            appShortcutRefreshEpoch &+= 1
            appShortcuts.removeAll()
            return
        }
        let generation = appAccountGeneration
        let candidates = catalog.apps.filter {
            $0.bot != nil || $0.effectiveRosterState == .comingSoon
        }
        let candidateIDs = candidates.map(\.appID)
        appShortcutRefreshEpoch &+= 1
        let refreshEpoch = appShortcutRefreshEpoch
        let capturedMutationRevisions = Dictionary(uniqueKeysWithValues:
            candidateIDs.map { ($0, appShortcutMutationRevisions[$0] ?? 0) }
        )
        let canReadCachedAccountData = FirstRunMarkerReadiness.canRead(
            sessionReady: matrix.isReady,
            completedInitialSync: matrix.hasCompletedInitialSync
        )
        let next = await MobileAppShortcutRefreshPolicy.states(
            existing: appShortcuts,
            candidates: candidateIDs,
            canReadCachedAccountData: canReadCachedAccountData,
            read: { appID in
                await current.runtime.appShortcutState(
                    appID: appID.rawValue,
                    canReadCachedAccountData: canReadCachedAccountData
                )
            },
            isCurrent: {
                guard case .signedIn = stage else { return false }
                return context?.runtime === current.runtime
                    && liveMatrix === matrix
                    && appAccountGeneration == generation
                    && appShortcutRefreshEpoch == refreshEpoch
                    && FirstRunMarkerReadiness.canRead(
                        sessionReady: matrix.isReady,
                        completedInitialSync: matrix.hasCompletedInitialSync
                    )
            }
        )
        guard let next, appShortcutRefreshEpoch == refreshEpoch else { return }
        let merged = Self.mergeAppShortcutRefresh(
            existing: appShortcuts,
            refreshed: next,
            candidates: candidateIDs,
            capturedMutationRevisions: capturedMutationRevisions,
            currentMutationRevisions: appShortcutMutationRevisions,
            activeWriteAppIDs: Set(appShortcutWriteOperations.keys)
        )
        if merged != appShortcuts { appShortcuts = merged }
    }

    /// Merges a refresh per app rather than replacing the whole projection.
    /// A write that starts or finishes after the refresh snapshot changes that
    /// app's revision; an active write also excludes that app even when the
    /// refresh captured its start revision. The existing UI value is preserved
    /// while unrelated app results still land.
    nonisolated static func mergeAppShortcutRefresh(
        existing: [AppCatalogID: MobileAppShortcutState],
        refreshed: [AppCatalogID: MobileAppShortcutState],
        candidates: [AppCatalogID],
        capturedMutationRevisions: [AppCatalogID: UInt64],
        currentMutationRevisions: [AppCatalogID: UInt64],
        activeWriteAppIDs: Set<AppCatalogID>
    ) -> [AppCatalogID: MobileAppShortcutState] {
        let candidateSet = Set(candidates)
        var merged = existing.filter { candidateSet.contains($0.key) }
        for appID in candidates {
            guard !activeWriteAppIDs.contains(appID),
                  capturedMutationRevisions[appID] == (currentMutationRevisions[appID] ?? 0),
                  let state = refreshed[appID] else { continue }
            merged[appID] = state
        }
        return merged
    }

    /// The Store is the reversible authority surface for app shortcuts. The
    /// write changes only global Matrix account data; it never mutates room
    /// membership, the bot-room hidden ledger, `m.favourite`, or a pointer.
    @discardableResult
    func setAppShortcutVisibility(appID rawAppID: String, shown: Bool) async -> Bool {
        guard case .signedIn = stage,
              let current = context,
              let matrix = liveMatrix,
              let app = appsRead.value?.apps.first(where: { $0.appID.rawValue == rawAppID }),
              app.bot != nil || app.effectiveRosterState == .comingSoon,
              FirstRunMarkerReadiness.canRead(sessionReady: matrix.isReady,
                                              completedInitialSync: matrix.hasCompletedInitialSync),
              appShortcutWriteOperations[app.appID] == nil else {
            return false
        }

        let generation = appAccountGeneration
        let operation = UUID()
        appShortcutWriteOperations[app.appID] = operation
        advanceAppShortcutMutationRevision(for: app.appID)
        defer {
            if appShortcutWriteOperations[app.appID] == operation {
                appShortcutWriteOperations[app.appID] = nil
            }
        }

        let visibility: MobileAppShortcutPolicy.Visibility = shown ? .shown : .hidden
        let outcome = await current.runtime.setAppShortcutVisibility(
            appID: app.appID.rawValue,
            visibility: visibility
        )
        guard appShortcutWriteContextIsCurrent(
            current: current, matrix: matrix, generation: generation,
            appID: app.appID, operation: operation
        ) else {
            return false
        }
        // Retire any refresh that began while this write was pending. This is
        // required for confirmed, failed and unconfirmed attempts alike: none
        // may publish a pre-write snapshot after the attempt finishes.
        advanceAppShortcutMutationRevision(for: app.appID)

        switch outcome {
        case .confirmed:
            appShortcuts[app.appID] = shown ? .shown : .hidden
            return true
        case .unconfirmed, .failed:
            recordRoomActionFailure("app:" + app.appID.rawValue)
            return false
        case .stale:
            return false
        }
    }

    private func advanceAppShortcutMutationRevision(for appID: AppCatalogID) {
        appShortcutMutationRevisions[appID, default: 0] &+= 1
    }

    private func appShortcutWriteContextIsCurrent(
        current: Context,
        matrix: LiveMatrixSession,
        generation: UInt64,
        appID: AppCatalogID,
        operation: UUID
    ) -> Bool {
        guard case .signedIn = stage else { return false }
        return context?.runtime === current.runtime
            && liveMatrix === matrix
            && appAccountGeneration == generation
            && appShortcutWriteOperations[appID] == operation
            && FirstRunMarkerReadiness.canRead(sessionReady: matrix.isReady,
                                              completedInitialSync: matrix.hasCompletedInitialSync)
            && appsRead.value?.apps.contains(where: {
                $0.appID == appID
                    && ($0.bot != nil || $0.effectiveRosterState == .comingSoon)
            }) == true
    }

    // MARK: Founder chat

    /// Applies the last good official-accounts answer. A different named
    /// Founder invalidates every binding from the previous one; a failed read
    /// keeps the last good answer and is never treated as "no Founder".
    private func applyFounderRead() {
        let founder = founderUserID
        guard founder != founderBoundUserID else { return }
        founderBoundUserID = founder
        founderRoomID = nil
        founderDraftOpen.reset()
        founderDraftAvailable = false
        founderAvatarURL = nil
        founderChatMarker = .unknown
        founderUnrecordedRoomID = nil
    }

    private func resetFounderState() {
        founderRoomID = nil
        founderDraftOpen.reset()
        founderDraftAvailable = false
        founderAvatarURL = nil
        founderBoundUserID = nil
        founderChatMarker = .unknown
        founderUnrecordedRoomID = nil
    }

    /// The person's explicit Contact us. It opens a usable chat or replaces a
    /// record whose chat was left. It is the only path that may create after a
    /// record exists, and it uses the same canonical recipe and fences.
    func contactFounder() async -> String? {
        if founderEnsureInFlight {
            let deadline = Date().addingTimeInterval(6)
            while founderEnsureInFlight, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !founderEnsureInFlight else { return founderRoomID }
        }
        founderEnsureInFlight = true
        defer { founderEnsureInFlight = false }

        guard case .signedIn = stage,
              let current = context,
              let matrix = liveMatrix,
              let founder = founderUserID,
              founder != current.runtime.ticket.session.userID,
              FirstRunMarkerReadiness.canRead(sessionReady: matrix.isReady,
                                              completedInitialSync: matrix.hasCompletedInitialSync) else {
            return nil
        }
        let generation = appAccountGeneration
        let marker = await current.runtime.founderChatMarker(canReadCachedAccountData: true)
        guard founderContextCurrent(current, matrix, generation) else { return nil }
        founderChatMarker = marker

        if case .absent = marker, let pending = founderUnrecordedRoomID {
            if await retryPendingFounderMarker(pending, founder: founder, current: current,
                                               matrix: matrix, generation: generation) {
                return pending
            }
            return nil
        }

        let usability = await founderMarkerRoomUsability(marker, founder: founder, current: current)
        guard founderContextCurrent(current, matrix, generation) else { return nil }
        switch MobileFounderPolicy.explicitAction(
            founder: founder,
            marker: marker,
            ownUserID: current.runtime.ticket.session.userID,
            sessionReady: matrix.isReady,
            completedInitialSync: matrix.hasCompletedInitialSync,
            existingRoomUsability: usability
        ) {
        case let .bindExisting(roomID):
            bindFounderRoom(roomID, founder: founder, current: current, matrix: matrix,
                            generation: generation)
            return roomID
        case .createReplacement:
            guard let roomID = await establishFounderRoom(founder: founder, current: current,
                                                          matrix: matrix, generation: generation) else {
                return nil
            }
            bindFounderRoom(roomID, founder: founder, current: current, matrix: matrix,
                            generation: generation)
            return roomID
        case .unavailable, .founderMode, .wait:
            return nil
        }
    }

    /// Reads the canonical account marker and binds a chat that already exists. It never
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
    /// the server's default it only offers the roster's local draft. Called on the existing
    /// sign-in/foreground/session-ready refreshes and on first-sync completion; never from a
    /// background ticker.
    private func refreshFounderChat() async {
        guard !founderEnsureInFlight else { return }
        founderEnsureInFlight = true
        defer { founderEnsureInFlight = false }
        await performFounderEnsure()
    }

    private func performFounderEnsure() async {
        guard case .signedIn = stage,
              let current = context,
              let matrix = liveMatrix,
              let founder = founderUserID,
              founder != current.runtime.ticket.session.userID,
              FirstRunMarkerReadiness.canRead(sessionReady: matrix.isReady,
                                              completedInitialSync: matrix.hasCompletedInitialSync) else {
            return
        }
        let generation = appAccountGeneration
        let marker = await current.runtime.founderChatMarker(canReadCachedAccountData: true)
        guard founderContextCurrent(current, matrix, generation) else { return }
        founderChatMarker = marker

        if case .absent = marker, let pending = founderUnrecordedRoomID {
            _ = await retryPendingFounderMarker(pending, founder: founder, current: current,
                                                matrix: matrix, generation: generation)
            return
        }

        let usability = await founderMarkerRoomUsability(marker, founder: founder, current: current)
        guard founderContextCurrent(current, matrix, generation) else { return }
        founderDraftAvailable = false
        switch MobileFounderPolicy.autoAction(
            founder: founder,
            roster: officialAccountsRead.value?.founderRoster,
            marker: marker,
            ownUserID: current.runtime.ticket.session.userID,
            sessionReady: matrix.isReady,
            completedInitialSync: matrix.hasCompletedInitialSync,
            existingRoomUsability: usability
        ) {
        case let .bindExisting(roomID):
            bindFounderRoom(roomID, founder: founder, current: current, matrix: matrix,
                            generation: generation)
        case .draft:
            // The roster's local draft row; nothing exists on the server yet.
            founderRoomID = nil
            founderAvatarURL = nil
            founderDraftAvailable = true
        case .decline, .suppressed, .unavailable, .founderMode:
            founderRoomID = nil
            founderAvatarURL = nil
            founderDraftAvailable = false
        case .wait:
            // Unknown/pre-sync never creates and never replaces the last good
            // binding established by an earlier completed read.
            break
        }
    }

    /// A room created before its account marker could be written. The marker
    /// write is retried on the next readiness callback; no second room is made.
    private func retryPendingFounderMarker(_ roomID: String, founder: String,
                                           current: Context, matrix: LiveMatrixSession,
                                           generation: UInt64) async -> Bool {
        do {
            try await current.runtime.writeFounderChatMarker(
                founder: founder, roomID: roomID,
                atMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            guard founderContextCurrent(current, matrix, generation) else { return false }
            founderUnrecordedRoomID = nil
            founderChatMarker = .present(founder: founder, roomID: roomID)
            bindFounderRoom(roomID, founder: founder, current: current, matrix: matrix,
                            generation: generation)
            return true
        } catch {
            guard founderContextCurrent(current, matrix, generation) else { return false }
            bindFounderRoom(roomID, founder: founder, current: current, matrix: matrix,
                            generation: generation)
            LiveFlowLog.creation(.founder, outcome: "marker_refused", code: "account_data")
            return false
        }
    }

    private enum FounderRoomPortFailure: Error { case stale }

    /// The one adapter from the package-testable establishment state machine
    /// to this account's current SDK runtime and phone-hidden-room ledger.
    @MainActor
    private final class FounderRoomRuntimePort: MobileFounderPolicy.FounderRoomPort {
        unowned let owner: LiveAppModel
        let current: Context
        let matrix: LiveMatrixSession
        let generation: UInt64

        init(owner: LiveAppModel, current: Context, matrix: LiveMatrixSession,
             generation: UInt64) {
            self.owner = owner
            self.current = current
            self.matrix = matrix
            self.generation = generation
        }

        private var isCurrent: Bool {
            owner.founderContextCurrent(current, matrix, generation)
        }

        func serverMarker(anchorRoomID: String?) async -> MobileFounderPolicy.ChatMarker {
            var anchors = [String]()
            if let anchorRoomID { anchors.append(anchorRoomID) }
            if let recorded = owner.founderChatMarker.readableRoomID { anchors.append(recorded) }
            anchors.append(contentsOf: matrix.rooms.map(\.roomID))
            var seen = Set<String>()
            for roomID in anchors where seen.insert(roomID).inserted {
                let marker = await current.runtime.fetchFounderChatMarker(roomID: roomID)
                guard isCurrent else { return .unknown }
                if marker != .unknown { return marker }
            }
            return .unknown
        }

        func roomUsability(roomID: String, founder: String) async
            -> MobileFounderPolicy.RoomUsability {
            let value = await current.runtime.founderRoomUsability(roomID: roomID,
                                                                   founder: founder)
            return isCurrent ? value : .unknown
        }

        func adoptableRoomID(founder: String, ownUserID: String) async -> String? {
            let candidateRoomIDs = matrix.rooms
                .filter {
                    $0.memberCount <= 2
                        && ($0.memberUserIDs.isEmpty || $0.memberUserIDs.contains(founder))
                }
                .map(\.roomID)
            let roomID = await current.runtime.adoptableFounderRoom(
                founder: founder, ownUserID: ownUserID,
                candidateRoomIDs: candidateRoomIDs
            )
            return isCurrent ? roomID : nil
        }

        func createRoom(founder: String) async throws -> String {
            guard isCurrent else { throw FounderRoomPortFailure.stale }
            let roomID = try await current.runtime.createFounderChat(founder: founder)
            guard isCurrent else { throw FounderRoomPortFailure.stale }
            return roomID
        }

        func writeMarker(founder: String, roomID: String) async throws {
            guard isCurrent else { throw FounderRoomPortFailure.stale }
            try await current.runtime.writeFounderChatMarker(
                founder: founder, roomID: roomID,
                atMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            guard isCurrent else { throw FounderRoomPortFailure.stale }
        }

        func rememberDirect(founder: String, roomID: String) async {
            guard isCurrent else { return }
            await matrix.rememberFounderDirect(roomID: roomID, founderUserID: founder)
        }

        func ownMessageState(roomID: String, ownUserID: String) async
            -> MobileFounderPolicy.OwnMessageState {
            _ = await owner.waitForFounderRoom(roomID, matrix: matrix, current: current,
                                               generation: generation)
            guard isCurrent,
                  let room = matrix.rooms.first(where: { $0.roomID == roomID }) else {
                return .unknown
            }
            if room.latestText == nil, room.latestPreviewContent == .none {
                return .absent
            }
            if room.latestSenderID == ownUserID {
                return .present
            }
            return .unknown
        }

        func leaveAndForget(roomID: String) async -> Bool {
            guard isCurrent else { return false }
            return await matrix.leaveAndForgetFounderRoom(roomID: roomID)
        }

        func hide(roomID: String) {
            guard isCurrent else { return }
            owner.hideFounderRaceLoser(roomID, matrix: matrix)
        }
    }

    /// Desktop's authoritative ensure recipe, executed through the fakeable
    /// port above. The server marker is read before any create and again after
    /// the write; only a proved message-free created loser is left+forgotten.
    private func establishFounderRoom(founder: String, current: Context,
                                      matrix: LiveMatrixSession, generation: UInt64) async -> String? {
        let port = FounderRoomRuntimePort(owner: self, current: current,
                                          matrix: matrix, generation: generation)
        let result = await MobileFounderPolicy.establishRoom(
            founder: founder,
            ownUserID: current.runtime.ticket.session.userID,
            port: port
        )
        guard founderContextCurrent(current, matrix, generation) else { return nil }
        switch result {
        case let .ready(roomID):
            founderUnrecordedRoomID = nil
            founderChatMarker = .present(founder: founder, roomID: roomID)
            _ = await waitForFounderRoom(roomID, matrix: matrix, current: current,
                                         generation: generation)
            return roomID
        case let .unrecorded(roomID):
            LiveFlowLog.creation(.founder, outcome: "marker_refused", code: "account_data")
            founderUnrecordedRoomID = roomID
            founderChatMarker = .present(founder: founder, roomID: roomID)
            _ = await waitForFounderRoom(roomID, matrix: matrix, current: current,
                                         generation: generation)
            return roomID
        case .failed:
            LiveFlowLog.creation(.founder, outcome: "room_refused", code: "matrix")
            return nil
        case .declined:
            founderRoomID = nil
            founderAvatarURL = nil
            return nil
        case .wait:
            return nil
        }
    }

    private func hideFounderRaceLoser(_ roomID: String, matrix: LiveMatrixSession) {
        let latest = matrix.rooms.first(where: { $0.roomID == roomID })?.latestTimestamp
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1_000))
        hiddenRooms.hide(roomID: roomID, latestTimestamp: latest, nowMillis: now)
        hiddenRoomStore?.save(hiddenRooms)
        discardRoomDrafts(roomID)
        if conversation?.roomID == roomID { closeConversation() }
        LiveFlowLog.creation(.founder, outcome: "race_loser_hidden", code: "message_state")
    }

    private func waitForFounderRoom(_ roomID: String, matrix: LiveMatrixSession,
                                    current: Context, generation: UInt64) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if matrix.rooms.contains(where: { $0.roomID == roomID }) { return true }
            try? await Task.sleep(for: .milliseconds(100))
            guard founderContextCurrent(current, matrix, generation) else { return false }
        } while Date() < deadline
        return matrix.rooms.contains(where: { $0.roomID == roomID })
    }

    private func founderMarkerRoomUsability(_ marker: MobileFounderPolicy.ChatMarker,
                                            founder: String, current: Context)
        async -> MobileFounderPolicy.RoomUsability {
        guard let roomID = marker.readableRoomID else { return .unusable }
        return await current.runtime.founderRoomUsability(roomID: roomID, founder: founder)
    }

    private func bindFounderRoom(_ roomID: String, founder: String, current: Context,
                                 matrix: LiveMatrixSession, generation: UInt64) {
        guard founderContextCurrent(current, matrix, generation) else { return }
        founderRoomID = roomID
        founderDraftAvailable = false
        founderAvatarURL = matrix.rooms.first(where: { $0.roomID == roomID })?.avatarURL
        founderBoundUserID = founder
        if founderChatMarker.readableRoomID != roomID
            || founderChatMarker.readableFounder != founder {
            founderChatMarker = .present(founder: founder, roomID: roomID)
        }
        guard matrix.rooms.contains(where: { $0.roomID == roomID }) else { return }
        Task { @MainActor [weak self, weak matrix] in
            guard let self, let matrix else { return }
            let members = await matrix.members(roomID: roomID)
            guard self.liveMatrix === matrix,
                  self.context?.runtime === current.runtime,
                  self.appAccountGeneration == generation,
                  self.founderRoomID == roomID else { return }
            if let avatar = members?.first(where: { $0.userID == founder })?.avatarURL {
                self.founderAvatarURL = avatar
            }
        }
    }

    private func founderContextCurrent(_ current: Context, _ matrix: LiveMatrixSession,
                                       _ generation: UInt64) -> Bool {
        guard case .signedIn = stage else { return false }
        return context?.runtime === current.runtime
            && liveMatrix === matrix
            && appAccountGeneration == generation
            && FirstRunMarkerReadiness.canRead(sessionReady: matrix.isReady,
                                              completedInitialSync: matrix.hasCompletedInitialSync)
    }

    /// A room publication can arrive after the marker read. Re-bind from the
    /// marker already observed; never perform a new account-data or network
    /// read from this callback.
    private func reconcileFounderBindingFromKnownMarker() {
        guard case .signedIn = stage, let matrix = liveMatrix,
              let founder = founderUserID else { return }
        guard founderChatMarker.readableFounder == founder,
              let roomID = founderChatMarker.readableRoomID else {
            if founderChatMarker.hasRecord {
                founderRoomID = nil
                founderAvatarURL = nil
            }
            return
        }
        if matrix.rooms.contains(where: { $0.roomID == roomID }) {
            if founderRoomID != roomID {
                founderRoomID = roomID
                founderAvatarURL = nil
            }
        } else if founderRoomID == roomID {
            founderRoomID = nil
            founderAvatarURL = nil
        }
    }

    private func refreshMatrix() async {
        if await matrixRenewal.joinIfRunning() { return }
        guard let liveMatrix, let current = context else { return }
        let now = Date()
        if MobileMatrixSessionKeepAlivePolicy.needsRefresh(expiresAt: current.runtime.ticket.session.expiresAt,
                                                            now: now) {
            await renewMatrixRuntime(current: current, session: liveMatrix, now: now, reason: "refresh")
            return
        }
        if liveMatrix.error == .currentSessionInvalid {
            // W4 E3: the session no longer matches custody. Rebuild it on
            // custody's grant without leaving the product; a refresh token is
            // spent only when that grant is inside the renewal lead, as the
            // old lock screen's "Thử lại" (launch) spent only on expiry. The
            // result is logged after the attempt.
            await renewMatrixRuntime(current: current, session: liveMatrix, now: now,
                                     reason: "session_invalid_rebuild")
        } else if liveMatrix.error != nil {
            await liveMatrix.restartAfterFailedSync()
        } else {
            await liveMatrix.start()
        }
    }

    /// One renewal attempt: its result and, for a failure, the closed
    /// failure class (`LiveAuthDiagnostics.code`).
    private struct RenewalAttempt {
        let result: MobileSessionContinuityPolicy.RenewalResult
        var code: String?
    }

    /// Rebuild the SDK client over the same encrypted stores and verified
    /// device keys, on custody's grant when it already outlives what the
    /// caller needs, otherwise after rotating the grant (W4 E3:
    /// `MobileSessionContinuityPolicy.renewalGrant`, decided before the
    /// working session is touched). The suspended session's display snapshot
    /// is presentation only and cannot authorize a send. An account-service
    /// failure never fails the renewal (as at launch). Nothing in custody is
    /// removed or overwritten.
    private func replaceMatrixRuntimeAfterRefresh(current: Context,
                                                  session: LiveMatrixSession,
                                                  now: Date,
                                                  requiredLifetimeSeconds: TimeInterval) async -> RenewalAttempt {
        guard let clients, let metadata else {
            return RenewalAttempt(result: .failed, code: "metadata_missing")
        }

        // Custody first: a spend that completed but was never installed (a
        // failure after the spend), or a session that only needs rebuilding,
        // resumes custody's grant and spends nothing. A refusing custody
        // leaves the working session alone and stops automatic renewals.
        let grant = MobileSessionContinuityPolicy.renewalGrant(
            custody: custodyGrant(current.sessionStore), now: Date(),
            requiredLifetimeSeconds: requiredLifetimeSeconds
        )
        switch grant {
        case .stop: return RenewalAttempt(result: .custodyRefused, code: "custody_refused")
        case .retryLater: return RenewalAttempt(result: .failed, code: "custody_unreadable")
        case .resumeStored, .spend: break
        }

        // Match cold launch's harmless reachability check before journaling a
        // one-time refresh-token spend. A request can still fail after this
        // check, but an already-offline phone cannot enter the spending state
        // merely because the owner pressed Retry.
        do {
            _ = try await MASProduction.metadata(using: transport)
        } catch {
            guard self.liveMatrix === session,
                  context?.installation == current.installation else { return RenewalAttempt(result: .superseded) }
            // A proactive renewal (token still valid) leaves the working
            // session alone; the keep-alive tries again shortly.
            guard MobileMatrixSessionKeepAlivePolicy.isExpired(
                expiresAt: current.runtime.ticket.session.expiresAt, now: Date()
            ) else { return RenewalAttempt(result: .unreachable, code: LiveAuthDiagnostics.code(error)) }
            conversation?.detach()
            _ = await session.suspendForRuntimeReplacement(retaining: .offline)
            await current.runtime.pause()
            return RenewalAttempt(result: .unreachable, code: LiveAuthDiagnostics.code(error))
        }
        guard self.liveMatrix === session,
              context?.installation == current.installation else { return RenewalAttempt(result: .superseded) }

        // The open chat keeps its rows and draft; sends tapped now wait in
        // its store and go out once it reattaches to the new session.
        conversation?.detach()
        _ = await session.suspendForRuntimeReplacement()
        await current.runtime.pause()
        guard self.liveMatrix === session,
              context?.installation == current.installation else { return RenewalAttempt(result: .superseded) }

        // The candidate SDK's persisted multi-process lease is 500 ms and can
        // outlive `pause` even though renewal has stopped. Match the proven
        // conformance margin before opening the same encrypted stores with the
        // replacement client; this is not a retry of the one-time token spend.
        do {
            try await Task.sleep(for: .milliseconds(
                MobileMatrixLeasePolicy.reopenDelayMilliseconds
            ))
        }
        catch { return RenewalAttempt(result: .superseded) }
        guard self.liveMatrix === session,
              context?.installation == current.installation else { return RenewalAttempt(result: .superseded) }

        var builtRuntime: MatrixLiveRuntime?
        do {
            if grant == .spend {
                let matrixResume = try current.sessionStore.resumeGrantForRefresh(marker: marker)
                let matrixRefresh = try OIDCGrantRefresh(resuming: matrixResume)
                _ = try await matrixRefresh.refresh(now: now) { request in
                    try await self.transport.refresh(request, metadata: metadata)
                }
            }
            let ticket = try current.sessionStore.resume(marker: marker)
            let reader = MatrixSessionReader(clients: clients, metadata: metadata)
            let runtime = try await MatrixLiveRuntime.resume(
                ticket: ticket,
                store: current.sessionStore,
                marker: marker,
                recoveryStore: recovery,
                directories: MatrixStoreDirectory(),
                reader: reader
            )
            builtRuntime = runtime
            resumeRecoveryJournal(session: ticket, sessionStore: current.sessionStore)
            // The account service never fails the renewal (as at launch): a
            // record that does not reconcile keeps the chats, and no domain
            // client is built from it.
            var accountResume: OIDCDomainResume?
            var accountFailure: (any Error)?
            do {
                let domain = try current.domainStore.resume(installation: marker)
                try domain.account.reconcile(matrix: ticket)
                accountResume = domain
            } catch {
                accountFailure = error
            }
            try runtime.requireCurrent()

            guard self.liveMatrix === session,
                  context?.installation == current.installation else {
                await runtime.pause()
                return RenewalAttempt(result: .superseded)
            }
            let replacement = LiveMatrixSession(runtime: runtime,
                                                displaySnapshot: session.displaySnapshot)
            observeInvites(on: replacement)
            let replacementContext = Context(installation: current.installation,
                                             sessionStore: current.sessionStore,
                                             domainStore: current.domainStore,
                                             runtime: runtime,
                                             domainRefresh: accountFailure == nil ? current.domainRefresh : nil)
            context = replacementContext
            liveMatrix = replacement
            matrixRecoverySnapshot = nil
            beginRecoveryObservation(current: replacementContext, matrix: replacement)
            builtRuntime = nil
            if let accountFailure {
                LiveFlowLog.session(.continuity, outcome: "renewal_account_unreconciled",
                                    code: LiveAuthDiagnostics.code(accountFailure))
            } else if let accountResume {
                restoreAccountServiceIfMissing(accountResume)
            }
            await replacement.start()
            guard self.liveMatrix === replacement,
                  context?.installation == current.installation else { return RenewalAttempt(result: .superseded) }
            if replacement.error == .currentSessionInvalid {
                await runtime.pause()
                return RenewalAttempt(result: .failed, code: "renewed_session_invalid")
            }
            return RenewalAttempt(result: .renewed, code: grant == .resumeStored ? "resumed_without_spend" : nil)
        } catch {
            await builtRuntime?.pause()
            guard self.liveMatrix === session,
                  context?.installation == current.installation else { return RenewalAttempt(result: .superseded) }
            // A spend cut short leaves custody refusing (journaled, never
            // finished): no automatic retry can change that.
            let refused = custodyGrant(current.sessionStore) == .refused
            return RenewalAttempt(result: refused ? .custodyRefused : .failed, code: LiveAuthDiagnostics.code(error))
        }
    }

    /// W4 E3: a launch or a renewal that could not reconcile the account
    /// service left the product without a domain client. Once a renewal
    /// reconciles the record, build the client (only when none exists, so
    /// two refreshers never share the record) and read agents, apps, Store
    /// and wallet again.
    private func restoreAccountServiceIfMissing(_ resume: OIDCDomainResume) {
        guard domainClient == nil, let metadata else { return }
        do {
            let refresh = try OIDCGrantRefresh(resuming: resume)
            domainClient = makeDomainClient(refresh: refresh, metadata: metadata)
            domainRecoveryState = .available
            LiveFlowLog.session(.continuity, outcome: "account_service_restored")
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshDomainReads()
                if let liveMatrix = self.liveMatrix { self.acceptKnownInvites(liveMatrix.invites, session: liveMatrix) }
                await self.refreshAppBotPointers()
                await self.refreshAppShortcuts()
                self.startPendingAssistantLifecycleResume()
            }
        } catch {
            domainRecoveryState = MobileDomainRecoveryPolicy.state(for: error)
            LiveFlowLog.session(.continuity, outcome: "account_service_still_unavailable",
                                code: LiveAuthDiagnostics.code(error))
        }
    }

    private func refreshDomainReads() async {
        if domainClient == nil { await restoreDomainAccessSilently() }
        guard let domainClient else {
            agentsRead.fail(.unavailable)
            appsRead.fail(.unavailable)
            officialAccountsRead.fail(.unavailable)
            storeCatalogRead.fail(.unavailable)
            walletRead.fail(.unavailable)
            assistantLifecycleCapability = nil
            return
        }
        let officialScope = context.map {
            OfficialAccountsRetryCadence.Scope(
                accountID: $0.runtime.ticket.session.userID,
                generation: officialAccountsClientGeneration
            )
        }
        let readOfficial = officialScope.map {
            officialAccountsCadence.begin(scope: $0, now: Date())
        } ?? false
        async let agentsResponse = readAgents(using: domainClient)
        async let appsResponse = readApps(using: domainClient)
        async let officialAccountsResponse = readOfficialAccounts(if: readOfficial,
                                                                  using: domainClient)
        async let storeCatalogResponse = readStoreCatalog(using: domainClient)
        async let walletResponse = readWallet(using: domainClient)
        let lifecycleGeneration = assistantLifecycleGeneration
        async let lifecycleCapability = readAssistantLifecycleCapability(using: domainClient)
        let (agentsResult, appsResult, officialAccountsResult, storeCatalogResult,
             walletResult, lifecycleResult) = await (
            agentsResponse, appsResponse, officialAccountsResponse, storeCatalogResponse,
            walletResponse, lifecycleCapability
        )
        if let currentClient = self.domainClient, currentClient !== domainClient {
            return
        }
        apply(agentsResult, to: &agentsRead)
        if case .success = agentsResult { assistantTurnStopUnavailable.removeAll() }
        apply(appsResult, to: &appsRead)
        apply(storeCatalogResult, to: &storeCatalogRead)
        apply(walletResult, to: &walletRead)
        if self.domainClient === domainClient,
           assistantLifecycleGeneration == lifecycleGeneration {
            assistantLifecycleCapability = lifecycleResult
        }
        if case let .success(catalog) = appsResult {
            await refreshAppWorkspaces(catalog: catalog, client: domainClient)
        }
        if let officialAccountsResult, let officialScope {
            guard self.domainClient === domainClient else {
                officialAccountsCadence.abandon(scope: officialScope)
                return
            }
            switch officialAccountsResult {
            case .abandoned:
                officialAccountsCadence.abandon(scope: officialScope)
            case let .completed(result, retryAfterSeconds):
                let current: Bool
                switch result {
                case .success:
                    current = officialAccountsCadence.succeed(scope: officialScope)
                case .failure:
                    current = officialAccountsCadence.fail(
                        scope: officialScope,
                        now: Date(),
                        retryAfterSeconds: retryAfterSeconds
                    )
                }
                if current {
                    apply(result, to: &officialAccountsRead)
                    applyFounderRead()
                    if case .success = result {
                        await refreshFounderChat()
                    }
                }
            }
        }
    }

    private func refreshAppWorkspaces(catalog: AppCatalogResponse,
                                      client: NativeDomainClient) async {
        for descriptor in catalog.apps where descriptor.app == "moon" || descriptor.app == "andy" {
            guard descriptor.hasSurface else { continue }
            do {
                let workspace = try await client.appWorkspace(slug: descriptor.app)
                guard domainClient === client,
                      workspace.appVersionID == descriptor.appVersionID else { continue }
                appWorkspaces[descriptor.app] = workspace
            } catch {
                // Preserve a last good current-account declaration. A failed
                // read must not become an empty action list.
                continue
            }
        }
    }

    private func readAgents(using client: NativeDomainClient) async -> ProductReadResult<AgentsResponse> {
        let report = ownerTimeZone.report(deviceTimeZone: TimeZone.autoupdatingCurrent.identifier)
        do {
            let read = try await client.agents(timeZone: report?.zone)
            ownerTimeZone.record(report, acknowledgement: read.timeZoneAck)
            return .success(read.response)
        } catch { return .failure(domainCondition(for: error, value: AgentsResponse.self)) }
    }

    private func readApps(using client: NativeDomainClient) async -> ProductReadResult<AppCatalogResponse> {
        do { return .success(try await client.apps()) }
        catch { return .failure(domainCondition(for: error, value: AppCatalogResponse.self)) }
    }

    private func readOfficialAccounts(if shouldRead: Bool, using client: NativeDomainClient)
        async -> OfficialAccountsAttempt? {
        guard shouldRead else { return nil }
        do {
            return .completed(.success(try await client.officialAccounts()),
                              retryAfterSeconds: nil)
        } catch is CancellationError {
            return .abandoned
        } catch let error as URLError where error.code == .cancelled {
            return .abandoned
        } catch let failure as NativeDomainClientFailure where failure == .cancelled {
            return .abandoned
        } catch {
            let retryAfter: Int64? = if case let .http(http)? = error as? NativeDomainClientFailure,
                                         http.response.error == .rateLimited {
                http.retryAfterSeconds
            } else {
                nil
            }
            return .completed(
                .failure(domainCondition(for: error, value: OfficialAccountsResponse.self)),
                retryAfterSeconds: retryAfter
            )
        }
    }

    private func readStoreCatalog(using client: NativeDomainClient)
        async -> ProductReadResult<StoreCatalogResponse> {
        do { return .success(try await client.storeCatalog()) }
        catch { return .failure(domainCondition(for: error, value: StoreCatalogResponse.self)) }
    }

    private func readWallet(using client: NativeDomainClient) async -> ProductReadResult<WalletResponse> {
        do { return .success(try await client.wallet()) }
        catch { return .failure(domainCondition(for: error, value: WalletResponse.self)) }
    }

    /// Capability is a closed read; an unavailable or invalid answer hides the
    /// action rather than inventing a disclosure version or a provider state.
    private func readAssistantLifecycleCapability(using client: NativeDomainClient) async
        -> AgentLifecycleCapability? {
        try? await client.agentLifecycleCapability()
    }

    private func apply<Value>(_ result: ProductReadResult<Value>, to read: inout NativeRead<Value>) {
        switch result {
        case let .success(value): read.receive(value)
        case let .failure(condition): read.fail(condition)
        }
    }

    private func domainCondition<Value>(for error: any Error,
                                        value _: Value.Type) -> NativeRead<Value>.Condition {
        guard let failure = error as? NativeDomainClientFailure else { return .failed }
        switch failure {
        case .transportUnavailable:
            return .offline
        case let .http(http) where http.cloudUnavailable:
            return .unavailable
        case .cancelled:
            return .offline
        default:
            return .failed
        }
    }

    func isPrivateCosHomeRow(_ room: ChatListSnapshot.Room) -> Bool {
        LiveRosterRows.isPrivateCosHomeRow(room, agents: agentsRead.value?.agents ?? [],
                                           bindings: companyWorkspace.privateCosBindings)
    }

    var hasCachedChatList: Bool { !cachedChatList.isEmpty }

    /// True once the room list and both catalog reads are fresh. Until then
    /// the cached projection stays, so a failed or slow `/agents` or `/apps`
    /// can never turn known photos back into initials. A list with no cached
    /// rows still paints live rows after the bounded hold.
    var chatListIsAuthoritative: Bool {
        guard let liveMatrix, liveMatrix.isReady, liveMatrix.hasCompletedInitialSync,
              !liveMatrix.isLoadingRooms else { return false }
        return agentsRead.condition == .fresh && appsRead.condition == .fresh
    }

    /// The first-launch bounded wait has elapsed; Home may paint partial
    /// rows rather than keep the skeleton forever.
    var chatListHoldExpired: Bool { homeHoldExpired }

    private func loadChatListSnapshot(accountID: String) {
        guard cachedChatListAccountID != accountID else { return }
        cachedChatListAccountID = accountID
        cachedChatList = chatListSnapshots.load(accountID: accountID)?.rooms ?? []
    }

    /// Called after Home has rendered an authoritative live list. The row
    /// state saved here is exactly what the person saw, so the next launch
    /// paints photos and real previews instead of letters.
    func recordChatListSnapshot(accountID: String, rows: [HomeRow]) {
        guard chatListIsAuthoritative, !rows.isEmpty else { return }
        let snapshot = rows.map { row in
            var snapshot = row.snapshotRow
            if let agent = agentsRead.value?.agents.first(where: { "agent:" + $0.id.rawValue == row.id }) {
                snapshot.assistantPrincipal = agent.principal.rawValue
                snapshot.assistantMatrixUserID = agent.matrixUser?.rawValue
            }
            return snapshot
        }
        guard snapshot != cachedChatList else { return }
        cachedChatList = snapshot
        try? chatListSnapshots.save(accountID: accountID, rooms: snapshot)
    }

    private func clearChatListSnapshot() {
        cachedChatList = []
        cachedChatListAccountID = nil
        chatListSnapshots.clear()
    }

    /// Avatar bytes and chat-row text are one account's data. Sign-out clears
    /// both disk caches so the next person on this phone cannot read a face or
    /// a preview left by the previous one.
    private func clearAccountCaches() async {
        await MatrixAvatarThumbnailCache.shared.removeAll()
        await AvatarDiskCache().removeAll()
    }

    /// The chat list's rows (`LiveRosterRows`, pure) from the live values.
    private func productRooms() -> [LiveProductRoom] {
        let output = LiveRosterRows.rows(LiveRosterRows.Input(
            agents: agentsRead.value?.agents ?? [],
            privateCosBindings: companyWorkspace.privateCosBindings,
            apps: appsRead.value?.apps ?? [],
            rooms: liveMatrix?.rooms ?? [],
            invites: liveMatrix?.invites ?? [],
            pointers: appBotPointers,
            hiddenRooms: hiddenRooms,
            appShortcuts: appShortcuts,
            locale: Self.currentLocale,
            waitingDetail: waitingDetail,
            comingSoonDetail: comingSoonDetail,
            founderRoomID: founderRoomID,
            founderUserID: founderUserID,
            founderName: founderName,
            founderSubtitle: founderSubtitle,
            founderAvatarURL: founderAvatarURL
        ))
        for (groupKey, choice) in output.agentChoices {
            logAgentRoomChoice(groupKey: groupKey, choice: choice)
        }
        for (groupKey, count) in output.agentDuplicatePlainRoomCounts {
            logDuplicatePlainAgentRooms(groupKey: groupKey, count: count)
        }
        return output.rows
            .filter { !$0.isInvitation || !suppressedInvitationIDs.contains($0.id) }
            .map { room in
                room.withRosterState(
                    unreadOverride: pendingRoomMutations[
                        RoomMutationKey(roomID: room.id, kind: .unread)
                    ]?.desired,
                    pinnedOverride: pendingRoomMutations[
                        RoomMutationKey(roomID: room.id, kind: .pinned)
                    ]?.desired,
                    mutedOverride: pendingRoomMutations[
                        RoomMutationKey(roomID: room.id, kind: .muted)
                    ]?.desired,
                    lowPriorityOverride: pendingRoomMutations[
                        RoomMutationKey(roomID: room.id, kind: .lowPriority)
                    ]?.desired
                )
            }
    }

    private func reconcileRoomMutations(with rooms: [LiveMatrixRoomRow], revision: UInt64) {
        var byID = [String: LiveMatrixRoomRow]()
        for room in rooms where byID[room.roomID] == nil { byID[room.roomID] = room }
        var completed = [RoomMutationKey]()
        for (key, mutation) in pendingRoomMutations {
            guard let room = byID[key.roomID] else { continue }
            let matches: Bool = switch key.kind {
            case .unread where mutation.desired:
                room.isMarkedUnread
            case .unread:
                !room.isMarkedUnread && room.unreadCount == 0
                    && room.notificationCount == 0 && room.highlightCount == 0
            case .pinned:
                room.isFavourite == mutation.desired
            case .muted:
                room.isMuted == mutation.desired
            case .lowPriority:
                room.isLowPriority == mutation.desired
            }
            if mutation.shouldRetire(actualMatches: matches, publicationRevision: revision) {
                completed.append(key)
            }
        }
        for key in completed { pendingRoomMutations[key] = nil }
        if let opened = conversationOpenedRoom, let live = byID[opened.id] {
            syncOpenedRoomState(opened, with: live)
        }
    }

    private func syncOpenedRoomState(_ opened: LiveProductRoom, with live: LiveMatrixRoomRow) {
        let unread = pendingRoomMutations[
            RoomMutationKey(roomID: opened.id, kind: .unread)
        ]?.desired
        conversationOpenedRoom = opened.withRosterState(
            unreadOverride: unread ?? live.isMarkedUnread,
            unreadCountOverride: unread == nil ? Self.boundedRoomCount(live.unreadCount) : nil,
            notificationCountOverride: unread == nil ? Self.boundedRoomCount(live.notificationCount) : nil,
            highlightCountOverride: unread == nil ? Self.boundedRoomCount(live.highlightCount) : nil,
            pinnedOverride: pendingRoomMutations[
                RoomMutationKey(roomID: opened.id, kind: .pinned)
            ]?.desired ?? live.isFavourite,
            mutedOverride: pendingRoomMutations[
                RoomMutationKey(roomID: opened.id, kind: .muted)
            ]?.desired ?? live.isMuted,
            lowPriorityOverride: pendingRoomMutations[
                RoomMutationKey(roomID: opened.id, kind: .lowPriority)
            ]?.desired ?? live.isLowPriority
        )
        if conversation?.roomID == live.roomID {
            conversation?.markedUnreadChanged(live.isMarkedUnread)
        }
    }

    private static func boundedRoomCount(_ value: UInt64) -> Int {
        Int(min(value, UInt64(Int.max)))
    }

    /// One line per agent when its chat or its number of unlisted rooms
    /// changes. The roster is recomputed on every render, so this is deduped.
    private func logAgentRoomChoice(groupKey: String, choice: MobileAgentRoomChoice) {
        let signature = choice.chatRoomID + "|" + String(choice.hiddenRoomIDs.count) + "|" + choice.reason.rawValue
        guard loggedAgentRoomChoices[groupKey] != signature else { return }
        loggedAgentRoomChoices[groupKey] = signature
        LiveFlowLog.roster(.agentRooms, outcome: choice.reason.rawValue, roomID: choice.chatRoomID,
                           count: choice.hiddenRoomIDs.count)
    }

    /// A duplicate-plain failure has no room choice, but it must remain
    /// observable without logging an agent ID or selecting either room.
    private func logDuplicatePlainAgentRooms(groupKey: String, count: Int) {
        let signature = "duplicate_plain|" + String(count)
        guard loggedAgentRoomChoices[groupKey] != signature else { return }
        loggedAgentRoomChoices[groupKey] = signature
        LiveFlowLog.roster(.agentRooms, outcome: "duplicate_plain", roomID: nil, count: count)
    }

    private func roomAvailability(rows: [LiveProductRoom]) -> LiveProductAvailability {
        let roomSource: HomeReadiness.Source
        if let error = liveMatrix?.error {
            roomSource = error == .offline ? .offline : .failed
        } else if liveMatrix?.isLoadingRooms == true || liveMatrix?.isReady != true {
            roomSource = .loading
        } else {
            roomSource = .ready
        }
        let result = HomeReadiness.decide(.init(
            hasListedRows: !rows.isEmpty,
            hasMatrixRooms: !(liveMatrix?.rooms.isEmpty ?? true)
                || !(liveMatrix?.invites.isEmpty ?? true),
            rooms: roomSource,
            agents: Self.homeSource(agentsRead.condition),
            apps: Self.homeSource(appsRead.condition),
            holdExpired: homeHoldExpired
        ))
        return switch result {
        case .loading: .loading
        case .ready: .ready
        case .empty: .empty
        case .offline: .offline
        case .error: .unavailable
        }
    }

    private static func homeSource<Value>(_ condition: NativeRead<Value>.Condition) -> HomeReadiness.Source {
        switch condition {
        case .loading: .loading
        case .fresh: .ready
        case .offline: .offline
        case .failed, .unavailable: .failed
        }
    }

    /// Effective Store toggle state for an inert presentation-only app. Live
    /// apps with rooms keep using room-level controls; unavailable live apps
    /// never gain a destination from this preference.
    nonisolated static func storeShortcutVisibility(
        for app: AppDescriptor,
        state: MobileAppShortcutState
    ) -> Bool? {
        guard app.effectiveRosterState == .comingSoon else { return nil }
        return switch state {
        case .shown: true
        case .hidden: false
        case .absent: app.rosterDefault
        case .unknown: nil
        }
    }

    private var storePresentation: LiveProductStoreRead {
        let openableRooms = Set(productRooms().filter {
            $0.canOpen && !$0.isInvitation && !$0.id.hasPrefix("app:")
        }.map(\.id))
        let items = (storeCatalogRead.value?.items ?? [])
            .sorted { left, right in
                left.sortOrder == right.sortOrder
                    ? left.itemID < right.itemID
                    : left.sortOrder < right.sortOrder
            }
            .map { item in
                let kind: LiveProductStoreItemKind = switch item.kind {
                case .agent: .agent
                case .skill: .skill
                case .pet: .pet
                }
                return LiveProductStoreItem(
                    id: item.itemID,
                    kind: kind,
                    title: item.title.localized(locale: Self.currentLocale, fallback: item.itemID),
                    summary: item.summary.localized(locale: Self.currentLocale),
                    glyph: item.glyph,
                    featured: item.featured,
                    price: item.offer.map {
                        MicroProtonFormat.string($0.priceMicroProtons,
                                                 locale: Locale.current.identifier)
                    },
                    accent: Self.catalogAccent(item.accent),
                    art: Self.installedStoreArt[item.itemID]
                )
            }
        let apps = (appsRead.value?.apps ?? [])
            .sorted { left, right in
                left.rosterOrder == right.rosterOrder
                    ? left.appID.rawValue < right.appID.rawValue
                    : left.rosterOrder < right.rosterOrder
            }
            .map { app in
                let choice = app.bot.flatMap {
                    botChatChoice(forBot: $0.userID.rawValue, appID: app.appID.rawValue)
                }
                let roomID = choice.flatMap {
                    $0.action == .open && openableRooms.contains($0.roomID) ? $0.roomID : nil
                }
                let verification: LiveProductAppVerification? = switch app.verification {
                case .official?: .official
                case .verified?: .verified
                case nil: nil
                }
                let canManageShortcut = app.effectiveRosterState == .comingSoon
                let canStartChat = AppStartPolicy.canStartChat(app) && roomID == nil
                let shortcutVisible = Self.storeShortcutVisibility(
                    for: app,
                    state: appShortcuts[app.appID] ?? .unknown
                )
                return LiveProductStoreApp(
                    id: app.appID.rawValue,
                    title: app.name.localized(locale: Self.currentLocale, fallback: app.app),
                    subtitle: app.subtitle?.localized(locale: Self.currentLocale),
                    avatarCandidates: app.displayAvatarCandidates.map {
                        LiveProductRemoteArt(url: $0.url, sha256: $0.sha256)
                    },
                    accent: Self.catalogAccent(app.accent),
                    isAvailable: app.availability == .available,
                    isVerified: app.verification != nil,
                    verification: verification,
                    roomID: roomID,
                    shortcutVisible: shortcutVisible,
                    canManageShortcut: canManageShortcut,
                    canStartChat: canStartChat,
                    slug: app.app
                )
            }
        if walletRead.value != nil || appsRead.value != nil || storeCatalogRead.value != nil {
            let staleAvailability: LiveProductAvailability?
            if walletRead.condition == .offline || appsRead.condition == .offline
                || storeCatalogRead.condition == .offline {
                staleAvailability = .offline
            } else if walletRead.condition != .fresh || appsRead.condition != .fresh
                || storeCatalogRead.condition != .fresh {
                staleAvailability = .unavailable
            } else {
                staleAvailability = nil
            }
            return LiveProductStoreRead(
                availability: .ready,
                walletValue: walletRead.value.map {
                    MicroProtonFormat.string($0.balances.available,
                                             locale: Locale.current.identifier)
                },
                items: items,
                apps: apps,
                staleAvailability: staleAvailability
            )
        }
        if walletRead.condition == .loading || appsRead.condition == .loading
            || storeCatalogRead.condition == .loading {
            return LiveProductStoreRead(availability: .loading)
        }
        if walletRead.condition == .offline || appsRead.condition == .offline
            || storeCatalogRead.condition == .offline {
            return LiveProductStoreRead(availability: .offline)
        }
        return LiveProductStoreRead(availability: .unavailable)
    }

    private func matrixAvailability(for error: LiveMatrixSessionError?) -> LiveProductAvailability {
        error == .offline ? .offline : .unavailable
    }

    private func availability<Value>(for condition: NativeRead<Value>.Condition) -> LiveProductAvailability {
        switch condition {
        case .loading: .loading
        case .fresh: .ready
        case .offline: .offline
        case .failed, .unavailable: .unavailable
        }
    }

    private static var currentLocale: String {
        let identifier = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        return identifier.split(separator: "-", maxSplits: 1).first.map(String.init) ?? identifier
    }

    private static func catalogAccent(_ hex: String?) -> Color? {
        guard let hex = AppBrand.resolve(accentHex: hex).avatarRingHex,
              let value = UInt64(hex.dropFirst(), radix: 16) else { return nil }
        return Color(.sRGB,
                     red: Double((value >> 16) & 0xff) / 255,
                     green: Double((value >> 8) & 0xff) / 255,
                     blue: Double(value & 0xff) / 255,
                     opacity: 1)
    }

    private static func newDeviceID() -> String {
        "ATUM-IOS-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    /// A person cancelling the provider sheet (or the browser presenter being
    /// unavailable, as before) keeps the cancelled notice. Every other thrown
    /// sign-in error is a visible failure, never a quiet return.
    static func initialNotice(_ error: any Error) -> LiveSignInNotice? {
        if let failure = error as? OIDCFailure,
           [.authorizationDenied, .browserUnavailable].contains(failure) {
            return .cancelled
        }
        return .failed
    }

    private static func domainNotice(_ error: any Error) -> LiveSignInNotice {
        if let failure = error as? OIDCFailure {
            if failure == .subjectMismatch { return .subjectMismatch }
            if failure == .authorizationDenied || failure == .browserUnavailable { return .cancelled }
        }
        return .domainUnavailable
    }
}

private struct LiveRecoverySavedStore {
    private let defaults = UserDefaults.standard
    private func key(_ id: UUID) -> String { "com.atum.mobile.recovery-saved." + id.uuidString }
    func isSaved(installationID: UUID) -> Bool { defaults.bool(forKey: key(installationID)) }
    func markSaved(installationID: UUID) { defaults.set(true, forKey: key(installationID)) }
    func clear(installationID: UUID) { defaults.removeObject(forKey: key(installationID)) }
}

/// Background execution time for one short operation. Ended explicitly, or by
/// the system's expiration callback; never held past either.
@MainActor
final class LiveBackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Whether the one-time notification card was shown on this install. A flag
/// only; no identifiers or content.
struct LivePushPromptStore {
    private let key = "atum.live.notificationPromptShown.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var wasShown: Bool { defaults.bool(forKey: key) }
    func markShown() { defaults.set(true, forKey: key) }
}

/// This phone's list of hidden rooms (bot deletes and unresolved Founder race
/// losers), kept per account in the app's own defaults. It holds room IDs and
/// message times only: no content, keys or tokens. The historical key name is
/// retained for compatibility. Losing it only brings hidden rooms back.
struct LiveHiddenRoomStore {
    private let key: String
    private let defaults: UserDefaults

    init(matrixUserID: String, defaults: UserDefaults = .standard) {
        key = "atum.live.hiddenBotRooms.v1." + LiveFlowLog.fingerprint(matrixUserID)
        self.defaults = defaults
    }

    func load() -> MobileHiddenRoomLedger {
        guard let data = defaults.data(forKey: key),
              let ledger = try? JSONDecoder().decode(MobileHiddenRoomLedger.self, from: data) else {
            return MobileHiddenRoomLedger()
        }
        return ledger
    }

    func save(_ ledger: MobileHiddenRoomLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: key)
    }
}

/// One opaque lifecycle UUID per account. Names, instructions, room IDs and
/// provider state remain authoritative on the platform and never enter
/// defaults. The key is derived from the owner's Matrix ID, so two accounts on
/// the same phone can never resume each other's setup.
struct LiveAssistantLifecycleStore {
    private let key: String
    private let defaults: UserDefaults

    init(matrixUserID: String, defaults: UserDefaults = .standard) {
        key = "atum.live.assistantLifecycle.v1." + LiveFlowLog.fingerprint(matrixUserID)
        self.defaults = defaults
    }

    func pending() -> NativeID? {
        defaults.string(forKey: key).flatMap { try? NativeID($0) }
    }

    func save(_ requestID: NativeID) {
        defaults.set(requestID.rawValue, forKey: key)
    }

    /// A completion may clear only the exact operation it observed. Together
    /// with the live generation fence this prevents an old A session from
    /// erasing a newer request after an A→B→A account sequence.
    func clear(_ requestID: NativeID) {
        guard pending() == requestID else { return }
        defaults.removeObject(forKey: key)
    }
}
