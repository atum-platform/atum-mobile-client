import Foundation

/// `atum.app-panel/1`: the pages an app declares for its side panel, the
/// optional sibling of an `atum.app-workspace/1` manifest read. Desktop
/// `apps/desktop/shared/app-panel.ts` (`decodeAppPanel`) and platform
/// `packages/protocol/src/app-panel.ts`.
public enum AppPanelContract {
    public static let profile = "atum.app-panel/1"
    /// Sent on the manifest read; without it the platform omits `app_panel`.
    public static let negotiationHeader = "Atum-App-Panel-Profile"
}

/// A validated panel declaration. Desktop rejects the whole declaration
/// (falling back to the manifest's menu routes) when any page is malformed,
/// duplicated or names a route that is not a menu route; so does this type.
public struct AppPanelDeclaration: Equatable, Sendable {
    public struct Page: Equatable, Sendable {
        public let routeID: String
        public let glyph: String

        public init(routeID: String, glyph: String) {
            self.routeID = routeID
            self.glyph = glyph
        }
    }

    public let pages: [Page]
    public let defaultPage: String?

    public init(pages: [Page], defaultPage: String? = nil) {
        self.pages = pages
        self.defaultPage = defaultPage
    }

    init?(raw: RawAppPanel, routes: [AppWorkspaceSnapshot.Route]) {
        let ids = raw.pages.map(\.routeID)
        guard raw.profile == AppPanelContract.profile,
              (1...12).contains(raw.pages.count),
              Set(ids).count == ids.count,
              raw.pages.allSatisfy({ page in
                  routes.contains { $0.id == page.routeID && $0.placements.contains(.menu) }
              }),
              raw.defaultPage.map { ids.contains($0) } ?? true else { return nil }
        pages = raw.pages.map { Page(routeID: $0.routeID, glyph: $0.glyph) }
        defaultPage = raw.defaultPage
    }
}

/// The wire shape, decoded strictly; any failure drops the declaration.
struct RawAppPanel: Decodable {
    struct Page: Decodable {
        let routeID: String
        let glyph: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["route_id", "glyph", "tag"])
            routeID = try c.string("route_id", minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_-]{0,63}")
            // The platform validates the name against the Kit's curated glyph
            // list before it emits a declaration; the phone checks its shape.
            glyph = try c.string("glyph", minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9-]{0,63}")
            // The tag is validated and not shown: the desktop panel shows none.
            _ = try c.optional("tag", as: Tag.self)
        }
    }

    struct Tag: Decodable {
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["vi", "en"])
            _ = try c.string("vi", minimum: 1, maximum: 10)
            _ = try c.string("en", minimum: 1, maximum: 10)
        }
    }

    let profile: String
    let defaultPage: String?
    let pages: [Page]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["profile", "default_page", "pages"])
        profile = try c.value("profile")
        defaultPage = try c.optional("default_page", as: String.self)
        if let defaultPage {
            _ = try checkedString(defaultPage, minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_-]{0,63}")
        }
        pages = try c.value("pages")
    }
}

/// What an app chat's side panel shows (desktop `matrix/app-bots/panel.tsx`
/// `AppBotPanel`, its home: identity, then one column of page capsules).
/// Pure: the app's catalog entry, its last manifest read and whether that read
/// failed go in; the panel's state comes out.
public enum AppPanelPagesPolicy {
    /// One page capsule.
    public struct Page: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: AppWorkspaceSnapshot.RouteLabel
        /// The declared glyph, else the route's manifest icon.
        public let glyph: String
        /// The phone can open this page now. Desktop disables a page only when
        /// it needs a session the account has not linked; the phone also needs
        /// the route to be one the mobile contract admits for launch.
        public let opens: Bool

        public init(id: String, label: AppWorkspaceSnapshot.RouteLabel, glyph: String, opens: Bool) {
            self.id = id
            self.label = label
            self.glyph = glyph
            self.opens = opens
        }
    }

    public enum State: Equatable, Sendable {
        /// The app needs its account linked first: one action, back to the
        /// chat, where the connect card lives.
        case connect
        /// "This app is unavailable." Retry is offered only while the app
        /// itself is up (the failure was the read).
        case unavailable(retry: Bool)
        /// The pages are being read.
        case loading
        /// The app declares no page besides its chat.
        case empty
        case pages([Page])
    }

    /// Desktop `ready`: the app is available and its bot is running on a device.
    public static func isReady(_ app: AppDescriptor) -> Bool {
        app.availability == .available && app.bot?.isStartable == true
    }

    /// Desktop `!requiresPlatformConnection(app.link)`.
    public static func isLinked(_ app: AppDescriptor) -> Bool {
        !(app.link.mode == .externalAccount && app.link.state != .linked)
    }

    /// Bot API apps own their web login, so their room never needs an Atum link.
    public static func isBotAPI(_ app: AppDescriptor) -> Bool {
        app.bot?.transportMode == .botAPI
    }

    /// The panel's pages in order: the declared pages (with their glyphs) when
    /// the app declares any, otherwise its menu routes; never the route its
    /// chat already is (`open_route_id`).
    public static func pages(_ workspace: AppWorkspaceSnapshot, app: AppDescriptor) -> [Page] {
        let menu = workspace.routes.filter { $0.placements.contains(.menu) }
        let declared: [(AppWorkspaceSnapshot.Route, String)]
        if let panel = workspace.panel {
            declared = panel.pages.compactMap { page in
                menu.first { $0.id == page.routeID }.map { ($0, page.glyph) }
            }
        } else {
            declared = menu.map { ($0, $0.icon) }
        }
        return declared
            .filter { $0.0.id != app.bot?.openRouteID }
            .map { route, glyph in
                Page(id: route.id, label: route.label, glyph: glyph,
                     opens: opens(route, workspace: workspace, app: app))
            }
    }

    /// The phone opens a page through the same signed launch the composer's
    /// route uses (`LiveAppModel.openAppRoute`), so the same gate applies: a
    /// launchable manifest, a session the account holds, and a route the phone
    /// admits (`AppOnboardingPolicy.allowsLaunch`: any declared page but commerce).
    public static func opens(_ route: AppWorkspaceSnapshot.Route, workspace: AppWorkspaceSnapshot,
                             app: AppDescriptor) -> Bool {
        guard workspace.supportsLaunch, route.session == .required,
              app.bot?.consent == .accepted, app.link.state == .linked,
              route.id != app.bot?.purchaseRouteID else { return false }
        return AppOnboardingPolicy.allowsLaunch(slug: app.app, routeID: route.id)
    }

    /// Desktop's order of checks: connect, unavailable, loading, empty, pages.
    /// A workspace for another version of the app is a failed read.
    public static func state(app: AppDescriptor, workspace: AppWorkspaceSnapshot?,
                             readFailed: Bool) -> State {
        guard isLinked(app) || isBotAPI(app) else { return .connect }
        let ready = isReady(app)
        var current: AppWorkspaceSnapshot?
        if let workspace, workspace.slug == app.app, workspace.appVersionID == app.appVersionID {
            current = workspace
        }
        let failed = readFailed || (workspace != nil && current == nil)
        if !ready || (current == nil && failed) { return .unavailable(retry: ready) }
        guard let shown = current else { return .loading }
        let list = Self.pages(shown, app: app)
        return list.isEmpty ? .empty : .pages(list)
    }
}
