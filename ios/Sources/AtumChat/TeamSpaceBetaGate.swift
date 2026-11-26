import Foundation

/// Desktop #132's Team Space beta gate (`railSurfaceState('teamSpace') ===
/// 'coming_soon'` for an account whose native `/me` says no beta features).
///
/// The tab stays in the bar, drawn subdued and named "Team space · Coming
/// soon", with no mark. Its page is the Coming soon page, never the
/// workspace. Every route whose authoritative destination is Team Space (a
/// notification, a room link, a board link, a search result, a retained
/// room) lands on that same page: no transcript and no composer. Personal
/// chats are not affected. The gate is presentation only; the platform
/// authorizes each company action.
public enum TeamSpaceBetaGate: Equatable, Sendable {
    case open
    case comingSoon

    public init(betaFeatures: Bool) {
        self = betaFeatures ? .open : .comingSoon
    }

    public var isComingSoon: Bool { self == .comingSoon }

    /// The tab's spoken name. Desktop composes the rail label as
    /// `${label} · ${status}`, so a gated tab reads "Team space · Coming soon".
    public func tabLabel(title: String, comingSoon: String) -> String {
        isComingSoon ? title + " · " + comingSoon : title
    }

    /// A gated tab carries no mark (desktop drops `placeBadge` for an
    /// unavailable place), so it never invites a tap into rooms it cannot show.
    public func tabBadge(_ badge: Badge) -> Badge {
        isComingSoon ? .none : badge
    }

    /// Where a route lands once its destination is known.
    public func landing(routesToTeamSpace: Bool) -> TeamSpaceRouteLanding {
        routesToTeamSpace && isComingSoon ? .comingSoon : .room
    }

    /// A Team Space room still open when the gate closes (another account,
    /// or a `/me` answer that turned beta features off) leaves the screen.
    public func closesOpenRoom(teamSpaceRoomID: String?) -> Bool {
        isComingSoon && teamSpaceRoomID != nil
    }
}

public enum TeamSpaceRouteLanding: Equatable, Sendable {
    /// The room opens in its own tab, as before.
    case room
    /// Team Space's Coming soon page; the room is never opened.
    case comingSoon
}
