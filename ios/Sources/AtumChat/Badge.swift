import Foundation

/// The unread mark for a Home row (S2 §3.2.3). Rendering owns colours and
/// localized accessibility copy; this policy only selects the semantic mark.
public enum Badge: Equatable, Hashable, Sendable {
    case mention(Int)
    case count(Int)
    case dot
    case quietDot
    case none

    /// The number a pill displays. The UI uses `isCapped` to render its own
    /// localized 99-plus presentation without this pure target owning copy.
    public var pillNumber: Int? {
        switch self {
        case let .mention(value), let .count(value): return value
        case .dot, .quietDot, .none: return nil
        }
    }

    public var isCapped: Bool { (pillNumber ?? 0) > 99 }

    /// The pill's text, the one cap shared with desktop: 99 and under print
    /// as they are, anything more is "99+".
    public static func pillText(_ count: Int) -> String {
        count > 99 ? "99+" : String(max(0, count))
    }

    public struct Input: Equatable, Sendable {
        public var highlights: Int
        public var notifications: Int
        public var hasUnreadActivity: Bool
        public var isMarkedUnread: Bool
        public var isMuted: Bool

        public init(highlights: Int = 0, notifications: Int = 0,
                    hasUnreadActivity: Bool = false, isMarkedUnread: Bool = false,
                    isMuted: Bool = false) {
            self.highlights = max(0, highlights)
            self.notifications = max(0, notifications)
            self.hasUnreadActivity = hasUnreadActivity
            self.isMarkedUnread = isMarkedUnread
            self.isMuted = isMuted
        }
    }

    /// Highlights always win. A muted room keeps a highlight pill, but all
    /// other activity is intentionally reduced to a quiet dot.
    public static func mark(for input: Input) -> Badge {
        if input.highlights > 0 { return .mention(max(input.notifications, input.highlights)) }
        if !input.isMuted && input.notifications > 0 { return .count(input.notifications) }
        if input.isMarkedUnread { return .dot }
        if input.isMuted && (input.notifications > 0 || input.hasUnreadActivity) { return .quietDot }
        if input.hasUnreadActivity { return .quietDot }
        return .none
    }

    /// The foreground app-icon count. Only visible, joined, unmuted rows
    /// contribute; a dot without a pill contributes one.
    public static func appIconCount(_ rows: [AppIconRow]) -> Int {
        rows.reduce(into: 0) { total, row in
            guard row.isListed, row.isJoined, !row.isHidden, !row.input.isMuted else { return }
            switch mark(for: row.input) {
            case let .mention(value), let .count(value): total += value
            case .dot: total += 1
            case .quietDot, .none: break
            }
        }
    }

    public struct AppIconRow: Equatable, Sendable {
        public var input: Input
        public var isListed: Bool
        public var isJoined: Bool
        public var isHidden: Bool

        public init(input: Input, isListed: Bool = true, isJoined: Bool = true, isHidden: Bool = false) {
            self.input = input
            self.isListed = isListed
            self.isJoined = isJoined
            self.isHidden = isHidden
        }
    }
}
