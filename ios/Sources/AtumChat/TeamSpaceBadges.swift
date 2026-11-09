import Foundation

/// The marks on the phone's tab bar. Only the Workplace tab carries one today.
public struct PhoneTabBadges: Equatable, Sendable {
    public var teamSpace: Badge

    public init(teamSpace: Badge = .none) { self.teamSpace = teamSpace }

    public static let none = PhoneTabBadges()
}

/// Unread and mention marks for Workplace (U1/U4). A channel row uses the same
/// `Badge` rule as a Home row; a company and the tab fold their channels'
/// marks into one, so a person sees where to look without opening anything.
public enum TeamSpaceBadges {
    /// Channel rows go bold for anything the person should notice. A muted
    /// room's quiet dot, and a read room, stay regular weight.
    public static func isBold(_ badge: Badge) -> Bool {
        switch badge {
        case .mention, .count, .dot: true
        case .quietDot, .none: false
        }
    }

    /// A company's mark, folded the way desktop folds a company's channels
    /// (`companyRoomsBadge`): a muted channel counts only its mentions, the
    /// mentions show as one number (the larger of the notification and
    /// mention totals, as a single room's mark does), else a dot when
    /// anything notified or was marked unread, else a quiet dot for muted or
    /// unnotified activity. Desktop prints plain notifications as a count;
    /// the phone keeps them a dot, so only mentions are a number.
    public static func company(channels: [Badge.Input]) -> Badge {
        var notifications = 0
        var highlights = 0
        var marked = false
        var activity = false
        for channel in channels {
            notifications += channel.isMuted ? channel.highlights : channel.notifications
            highlights += channel.highlights
            marked = marked || channel.isMarkedUnread
            activity = activity || channel.hasUnreadActivity
                || (channel.isMuted && channel.notifications > 0)
        }
        if highlights > 0 { return .mention(max(notifications, highlights)) }
        if notifications > 0 || marked { return .dot }
        return activity ? .quietDot : .none
    }

    /// What the switcher sheet shows next to a company: its mark, except on
    /// the company you are already in, where there is nothing to go and look at.
    public static func switcherMark(_ company: Badge, isActive: Bool) -> Badge {
        isActive ? .none : company
    }

    /// The Workplace tab's mark: mentions first, then waiting invitations as a
    /// count, then a dot for plain unread. Muted activity never shows here.
    public static func tab(companies: [Badge], pendingInvitations: Int) -> Badge {
        let mentions = mentionTotal(companies)
        if mentions > 0 { return .mention(mentions) }
        if pendingInvitations > 0 { return .count(pendingInvitations) }
        if companies.contains(.dot) { return .dot }
        return .none
    }

    private static func mentionTotal(_ marks: [Badge]) -> Int {
        marks.reduce(into: 0) { total, mark in
            if case let .mention(value) = mark { total += value }
        }
    }
}
