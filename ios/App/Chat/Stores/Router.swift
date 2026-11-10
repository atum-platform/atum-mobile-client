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

    private(set) var selectedTab: Tab = .home
    var homePath = NavigationPath()
    var drivePath = NavigationPath()
    var storePath = NavigationPath()
    var teamSpacePath = NavigationPath()

    /// Account is no longer a tab. Home's top-left avatar asks the shell to
    /// present the same Account screen as a sheet.
    var isAccountPresented = false

    func presentAccount() {
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
        dismissPresentation()
        hasActivePresentation = false
        selectedTab = .home
        homePath = NavigationPath()
        homeRoomID = nil
    }

    func showTeamSpaceRoot() {
        dismissPresentation()
        hasActivePresentation = false
        selectedTab = .teamSpace
        teamSpacePath = NavigationPath()
        teamSpaceRoomID = nil
    }

    func receivePushIntent(roomID: String) {
        guard !roomID.isEmpty else { return }
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

    func resetAccountScope() {
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

    /// Called by the tab shell for both user selection and a selected-tab
    /// re-tap.  A re-tap pops that tab only; Home at root is the roster's
    /// scroll-to-top affordance.
    func select(tab: Tab) {
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

    /// Home's Back action uses this instead of mutating the type-erased path
    /// directly, so the same-room fast path stays correct afterwards.
    func popHomeToRoot() {
        hasActivePresentation = false
        homePath = NavigationPath()
        homeRoomID = nil
    }

    func popTeamSpaceToRoot() {
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
