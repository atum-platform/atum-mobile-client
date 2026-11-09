import Foundation

/// The three signed-in destinations the phone shell shows. Store and Account
/// are deliberately absent: Account lives behind Home's top-left avatar, and
/// Store has no tab in the 2026-10-20 phone navigation.
public enum PhoneTab: String, CaseIterable, Sendable {
    case chats
    case drive
    case teamSpace = "team_space"
}

public enum PhoneTabState: Equatable, Sendable {
    case available
    case comingSoon
}

/// Maps account feature availability to what the tab bar shows. A feature
/// that is not available for the account still gets a tab: it is drawn
/// subdued and opens the "coming soon" screen, so the tab is never a dead
/// tap or a control that disappears between accounts.
public struct PhoneTabAvailability: Equatable, Sendable {
    public var drive: Bool
    public var teamSpace: Bool

    public init(drive: Bool = false, teamSpace: Bool = false) {
        self.drive = drive
        self.teamSpace = teamSpace
    }

    /// Today's phone build has no Drive or Team Space surface yet.
    public static let none = PhoneTabAvailability()

    public func state(for tab: PhoneTab) -> PhoneTabState {
        switch tab {
        case .chats: .available
        case .drive: drive ? .available : .comingSoon
        case .teamSpace: teamSpace ? .available : .comingSoon
        }
    }
}
