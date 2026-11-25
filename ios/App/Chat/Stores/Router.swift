import AtumChat
import Observation
import SwiftUI

/// The app shell's navigation owner. The four paths deliberately stay
/// independent: switching tabs must not discard work in another tab.
@MainActor
@Observable
final class Router: RouterOpening {
    enum PendingRoomDecision: Equatable {
        case pending
        case allow
        case deny
    }
    enum Tab: Hashable, Sendable {
        case home
        case drive
        case store
        case teamSpace
    }
    /// Store destinations live on `storePath`, so a shelf route that resets
    /// the path also leaves them (#101).
    enum StoreDestination: Hashable, Sendable {
        case purchased
    }
    /// One attempt to reopen the last personal chat (W4-V2). The ID stays
    /// the same for the intent's retries; the generation is the navigation
    /// generation the intent started under.
    struct ChatRestoreIntent: Equatable {
        let id: UUID
        let entry: PersonalChatRestoreEntry
        let generation: UInt64
    }

    /// How long Chats keeps its root covered while a restore intent can
    /// still apply. Past it the roster shows and the intent ends, so a late
    /// restore never replaces a roster the person is reading.
    static func chatRestoreHold(for entry: PersonalChatRestoreEntry) -> Duration {
        switch entry {
        case .launch: .seconds(3)
        case .chatsTap: .seconds(1)
        }
    }

    /// How long a cold notification may keep the boot screen up while its
    /// room is still being validated: the launch restore's hold.
    static let coldDeepLinkHold = chatRestoreHold(for: .launch)

    private(set) var selectedTab: Tab = .home
    var homePath = NavigationPath()
    var drivePath = NavigationPath()
    var storePath = NavigationPath()
    var teamSpacePath = NavigationPath()

    /// Account is no longer a tab. Home's top-left avatar asks the shell to
    /// present the same Account screen as a sheet.
    var isAccountPresented = false

    func presentAccount() {
        claimNavigation()
        isAccountPresented = true
    }

    func dismissAccount() {
        isAccountPresented = false
    }

    /// The one room a notification may ask us to open before the session and
    /// its roster are both authoritative.  A later notification replaces it;
    /// this is intentionally not a queue of stale intent.
    private(set) var pendingDeepLinkRoomID: String?
    private(set) var pendingDeepLinkIsCold = false
    private(set) var latestPushIntentRoomID: String?
    private(set) var pushIntentGeneration: UInt64 = 0
    private(set) var hasActivePresentation = false
    /// Every navigation Router performs claims the route. A restore intent
    /// stays current only while this matches the generation it started on.
    private(set) var navigationGeneration: UInt64 = 0
    /// The pending restore intent, if any. Chats keeps its root covered while
    /// it is pending, so a restore that applies lands straight in the chat.
    private(set) var chatRestoreIntent: ChatRestoreIntent?

    /// The room represented by Home's path.  `NavigationPath` is type-erased,
    /// so retain this small, typed mirror to distinguish replacement from a
    /// request for the chat that is already visible.
    private(set) var homeRoomID: String?
    /// Company channels belong exclusively to Workplace's stack.
    private(set) var teamSpaceRoomID: String?

    /// Presentation state is owned by the feature that presents it.  Opening
    /// a room only asks that owner to dismiss, keeping Router free of sheets,
    /// Safari and dialog types.
    @ObservationIgnored var dismissPresentation: @MainActor () -> Void = {}
    /// A second request for the already-open room means "go to latest", not
    /// another push.  ChatScreen supplies the scrolling implementation.
    @ObservationIgnored var onOpenCurrentRoom: @MainActor (String) -> Void = { _ in }
    /// Live composition opens the validated room's model/store before it
    /// mutates the path; tests and non-live hosts may leave this nil and use
    /// Router's direct path behavior.
    @ObservationIgnored var onValidatedRoom: (@MainActor (String) -> Void)?
    @ObservationIgnored var onValidatedColdRoom: (@MainActor (String) -> Void)?
    /// S5 supplies first-contact handling without growing the frozen protocol.
    @ObservationIgnored var onOpenApp: @MainActor (String) -> Void = { _ in }
    /// A re-tap on Home's root scrolls the roster to its top.
    @ObservationIgnored var onHomeRootRetap: @MainActor () -> Void = {}
    /// User tab choices cancel an in-flight room open. Programmatic routing
    /// uses the dedicated root/open methods and does not trigger this hook.
    @ObservationIgnored var onUserSelectedTab: @MainActor (Tab) -> Void = { _ in }

    func open(roomId: String) {
        guard !roomId.isEmpty else { return }
        claimNavigation()
        dismissPresentation()
        hasActivePresentation = false
        selectedTab = .home

        if homeRoomID == roomId {
            onOpenCurrentRoom(roomId)
            return
        }

        // A deep link replaces an open conversation rather than building an
        // unbounded stack of chats behind it.
        homePath = NavigationPath([roomId])
        homeRoomID = roomId
    }

    func openTeamSpace(roomId: String) {
        guard !roomId.isEmpty else { return }
        claimNavigation()
        dismissPresentation()
        hasActivePresentation = false
        selectedTab = .teamSpace

        if teamSpaceRoomID == roomId {
            onOpenCurrentRoom(roomId)
            return
        }

        teamSpacePath = NavigationPath([roomId])
        teamSpaceRoomID = roomId
    }

    func open(app: String) {
        guard !app.isEmpty else { return }
        claimNavigation()
        dismissPresentation()
        hasActivePresentation = false
        selectedTab = .home
        onOpenApp(app)
    }

    /// A notification for another or invalid room first establishes the safe
    /// fallback required by S2: Home at its root with transient presentation
    /// dismissed. A subsequently validated room replaces this root with one
    /// chat push.
    func showHomeRoot() {
        claimNavigation()
        dismissPresentation()
        hasActivePresentation = false
        selectedTab = .home
        homePath = NavigationPath()
        homeRoomID = nil
    }

    func showTeamSpaceRoot() {
        claimNavigation()
        dismissPresentation()
        hasActivePresentation = false
        selectedTab = .teamSpace
        teamSpacePath = NavigationPath()
        teamSpaceRoomID = nil
    }

    func receivePushIntent(roomID: String) {
        guard !roomID.isEmpty else { return }
        // The relay's delivery claims the route at once: a restore retry
        // queued before the shell holds this room must not open another.
        claimNavigation()
        latestPushIntentRoomID = roomID
        pushIntentGeneration &+= 1
    }

    func presentationChanged(_ active: Bool) {
        hasActivePresentation = active
    }

    var pushScreen: PushPresentation.Screen {
        if hasActivePresentation { return .other }
        switch selectedTab {
        case .home:
            return homeRoomID.map { .chat(roomID: $0) } ?? .homeRoot
        case .teamSpace:
            return teamSpaceRoomID.map { .chat(roomID: $0) } ?? .other
        case .drive, .store:
            return .other
        }
    }

    /// The room open in the selected tab. It routes presentation reports and
    /// the same-room fast path; it no longer decides whether the tab bar is
    /// shown (each chat destination hides the system bar itself, animated
    /// with the push).
    var activeRoomID: String? {
        switch selectedTab {
        case .home: homeRoomID
        case .teamSpace: teamSpaceRoomID
        case .drive, .store: nil
        }
    }

    /// Records a notification before its room can be trusted.  Call
    /// `validatePendingDeepLink` after both the session and room list report
    /// ready; this method deliberately does not navigate on its own.
    func holdDeepLink(roomID: String, cold: Bool = false) {
        guard !roomID.isEmpty else { return }
        // A notification beats a restore that has not landed yet.
        claimNavigation()
        pendingDeepLinkRoomID = roomID
        pendingDeepLinkIsCold = cold
    }

    /// Validates and consumes the one held notification intent.  When either
    /// prerequisite or classification is not ready, it remains pending. A
    /// conclusive denial is consumed; only an allowed room is handed off.
    @discardableResult
    func validatePendingDeepLink(sessionAndRosterAreReady: Bool,
                                 decision: (String) -> PendingRoomDecision) -> Bool {
        guard sessionAndRosterAreReady, let roomID = pendingDeepLinkRoomID else { return false }
        let result = decision(roomID)
        guard result != .pending else { return false }
        let wasCold = pendingDeepLinkIsCold
        pendingDeepLinkRoomID = nil
        pendingDeepLinkIsCold = false
        guard result == .allow else { return false }
        if wasCold, let onValidatedColdRoom { onValidatedColdRoom(roomID) }
        else if let onValidatedRoom { onValidatedRoom(roomID) }
        else { open(roomId: roomID) }
        return true
    }

    /// The cold hold is over: the shell mounts at its roster. The
    /// notification stays held, now as a foreground one, so a later
    /// conclusive validation opens it the way a foreground notification
    /// opens (and a denial drops it). Navigation is not claimed: nothing
    /// moved.
    func releaseColdDeepLinkHold() {
        pendingDeepLinkIsCold = false
    }

    /// The shell applies each new account scope here. `replacesAccount` is
    /// true only when a signed-in account's scope ends (sign-out, another
    /// account): its routes go with it. The first scope after none (a cold
    /// launch, a fresh sign-in) is initial setup, not a switch, so a
    /// notification received while booting is carried through and validated
    /// against the resumed account. The scope then reopens its last chat
    /// unless a notification already owns the route.
    func applyAccountScope(replacesAccount: Bool) {
        if replacesAccount { resetAccountScope() } else { claimNavigation() }
        // A full reset clears the received intent, so one still recorded here
        // arrived while no account was scoped.
        guard pendingDeepLinkRoomID == nil, latestPushIntentRoomID == nil,
              homePath.isEmpty, homeRoomID == nil else { return }
        beginChatRestore(.launch)
    }

    func resetAccountScope() {
        claimNavigation()
        dismissPresentation()
        hasActivePresentation = false
        selectedTab = .home
        homePath = NavigationPath()
        drivePath = NavigationPath()
        storePath = NavigationPath()
        teamSpacePath = NavigationPath()
        homeRoomID = nil
        teamSpaceRoomID = nil
        isAccountPresented = false
        pendingDeepLinkRoomID = nil
        pendingDeepLinkIsCold = false
        latestPushIntentRoomID = nil
        pushIntentGeneration &+= 1
    }

    func stageColdRoom(roomID: String) {
        guard !roomID.isEmpty else { return }
        claimNavigation()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            hasActivePresentation = false
            selectedTab = .home
            homePath = NavigationPath([roomID])
            homeRoomID = roomID
        }
    }

    func stageColdTeamSpaceRoom(roomID: String) {
        guard !roomID.isEmpty else { return }
        claimNavigation()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            hasActivePresentation = false
            selectedTab = .teamSpace
            teamSpacePath = NavigationPath([roomID])
            teamSpaceRoomID = roomID
        }
    }

    /// The Store shelf an assistant card asked for (Pet → Pets, "Find more
    /// skills" → Skills, desktop's `openShelf`). The Store scrolls to it once
    /// and clears it; a later request replaces it.
    private(set) var storeShelfRequest: StoreSectionKind?

    /// Shows the Store at its root, scrolled to `shelf`.
    func openStore(shelf: StoreSectionKind) {
        claimNavigation()
        // Resetting the path also leaves Purchased (#101).
        storePath = NavigationPath()
        storeShelfRequest = shelf
        if selectedTab != .store {
            selectedTab = .store
            onUserSelectedTab(.store)
        }
    }

    func storeShelfShown() {
        storeShelfRequest = nil
    }

    /// Store's Purchased list, pushed on `storePath` (#101).
    func openStorePurchased() {
        claimNavigation()
        storePath.append(StoreDestination.purchased)
    }

    /// Called by the tab shell for both user selection and a selected-tab
    /// re-tap.  A re-tap pops that tab only; Home at root is the roster's
    /// scroll-to-top affordance.
    func select(tab: Tab) {
        claimNavigation()
        guard selectedTab == tab else {
            selectedTab = tab
            onUserSelectedTab(tab)
            return
        }

        switch tab {
        case .home:
            if homeRoomID != nil || !homePath.isEmpty {
                homePath = NavigationPath()
                homeRoomID = nil
            } else {
                onHomeRootRetap()
            }
        case .drive:
            guard !drivePath.isEmpty else { return }
            drivePath = NavigationPath()
        case .store:
            guard !storePath.isEmpty else { return }
            storePath = NavigationPath()
        case .teamSpace:
            if teamSpaceRoomID != nil || !teamSpacePath.isEmpty {
                teamSpacePath = NavigationPath()
                teamSpaceRoomID = nil
            }
        }
    }

    // MARK: Last personal chat (W4-V2)

    /// Starts a restore intent with a fresh ID under the current navigation
    /// generation. The shell starts `.launch` for each account scope and
    /// `.chatsTap` when a person switches to Chats at its root.
    @discardableResult
    func beginChatRestore(_ entry: PersonalChatRestoreEntry, id: UUID = UUID()) -> ChatRestoreIntent {
        let intent = ChatRestoreIntent(id: id, entry: entry, generation: navigationGeneration)
        chatRestoreIntent = intent
        return intent
    }

    /// Ends the intent without a restore (its hold expired, or nothing can
    /// apply). A stale ID leaves a newer intent alone.
    func endChatRestore(_ id: UUID) {
        guard chatRestoreIntent?.id == id else { return }
        chatRestoreIntent = nil
    }

    /// A pending or held notification route wins over a restore.
    var hasExplicitRoute: Bool { pendingDeepLinkRoomID != nil }

    /// True while `intent` still owns Chats: no newer navigation, Chats is
    /// selected at its root, and nothing is presented over it.
    func chatRestoreIsCurrent(_ intent: ChatRestoreIntent) -> Bool {
        chatRestoreIntent == intent && navigationGeneration == intent.generation
            && selectedTab == .home && homePath.isEmpty && homeRoomID == nil
            && !hasActivePresentation && !isAccountPresented && pendingDeepLinkRoomID == nil
    }

    /// Whether Chats' root is covered while the pending intent decides.
    var coversChatsRootForRestore: Bool {
        guard let chatRestoreIntent else { return false }
        return chatRestoreIsCurrent(chatRestoreIntent)
    }

    /// Asks `restore` (the model's `restorePersonalChat`) once for the pending
    /// intent, reusing its ID. A returned room is already open in the model;
    /// it is published to Chats' path in the same turn, without a push
    /// animation, and the intent ends. A `nil` keeps the intent pending.
    @discardableResult
    func attemptChatRestore(
        hasExplicitRoute extraExplicitRoute: Bool = false,
        _ restore: (PersonalChatRestoreEntry, UUID, Bool, @escaping @MainActor () -> Bool) -> String?
    ) -> String? {
        guard let intent = chatRestoreIntent, chatRestoreIsCurrent(intent) else { return nil }
        let stillCurrent: @MainActor () -> Bool = { [weak self] in
            self?.chatRestoreIsCurrent(intent) ?? false
        }
        guard let roomID = restore(intent.entry, intent.id, hasExplicitRoute || extraExplicitRoute, stillCurrent),
              !roomID.isEmpty, chatRestoreIsCurrent(intent) else { return nil }
        claimNavigation()
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            homePath = NavigationPath([roomID])
            homeRoomID = roomID
        }
        return roomID
    }

    /// A newer navigation owns the route; any pending restore intent ends.
    private func claimNavigation() {
        navigationGeneration &+= 1
        chatRestoreIntent = nil
    }

    /// Home's Back action uses this instead of mutating the type-erased path
    /// directly, so the same-room fast path stays correct afterwards.
    func popHomeToRoot() {
        claimNavigation()
        hasActivePresentation = false
        homePath = NavigationPath()
        homeRoomID = nil
    }

    func popTeamSpaceToRoot() {
        claimNavigation()
        hasActivePresentation = false
        teamSpacePath = NavigationPath()
        teamSpaceRoomID = nil
    }

    /// The shell calls this when a view-pop changed a path outside Router's
    /// own actions.  It keeps the typed mirror accurate without inspecting a
    /// type-erased `NavigationPath`.
    func didPopHomeRoom() {
        hasActivePresentation = false
        homeRoomID = nil
    }

    func didPopTeamSpaceRoom() {
        hasActivePresentation = false
        teamSpaceRoomID = nil
    }
}
