/// Whether the transcript keeps the newest row in view (plan §2.5). This is
/// the one source of truth for following: the hotfix's transcript and the
/// revamp's `TranscriptView` both drive it (it replaced the hotfix's
/// `MobileTranscriptFollowPolicy`, whose rules it keeps).
public enum FollowState: Equatable, Hashable, Sendable {
    case following
    /// Scrolled away from the bottom; `newCount` messages arrived since.
    case detached(newCount: Int)
}

/// Who is moving the scroll view, from SwiftUI's `ScrollPhase`.
public enum ScrollMotion: Equatable, Hashable, Sendable {
    /// `.idle`: content or the viewport changed with nobody scrolling.
    case idle
    /// `.tracking`, `.interacting`, `.decelerating`: the person.
    case user
    /// `.animating`: an animated scroll (the jump pill's, or the system's
    /// scroll-to-top). Counts as the person's unless the pill started it.
    case animating
}

/// Everything the view and the store tell the policy (the rows of §2.5).
public enum FollowInput: Equatable, Sendable {
    case opened
    /// Distance from the visible bottom edge to the end of the content,
    /// including the composer and keyboard insets; distance from the start of
    /// the content to the visible top edge; the viewport height.
    /// `distanceFromTop` is the pagination input: FollowPolicy ignores it,
    /// the store's `PaginationPolicy` (S1b) reads it with `viewportHeight`.
    case geometry(distanceFromBottom: Double, distanceFromTop: Double, viewportHeight: Double,
                  motion: ScrollMotion)
    /// Rows added at the end. `localEcho` only for a send from this device;
    /// `count` is what the pill counts (no notices, nothing from here).
    case appended(count: Int, localEcho: Bool)
    case prepended
    case typingShown
    case inPlaceEdit
    case keyboardWillShow
    case composerGrew
    /// The SDK replaced the whole list.
    case reset
    case jumpTapped

    /// The input for one snapshot's change (§2.3 rule 5).
    public static func from(_ change: SnapshotChange) -> FollowInput {
        switch change {
        case .reset: return .reset
        case let .appendedAtEnd(count, localEcho): return .appended(count: count, localEcho: localEcho)
        case .prependedAtStart: return .prepended
        case .inPlace: return .inPlaceEdit
        case let .mixed(count, localEcho):
            return count > 0 || localEcho ? .appended(count: count, localEcho: localEcho) : .inPlaceEdit
        }
    }
}

/// What the store asks the view to do.
public enum FollowCommand: Equatable, Hashable, Sendable {
    case none
    case scrollToBottom(animated: Bool)
}

/// The jump pill (B4). `arrow` has the accessibility label "Đến tin nhắn mới
/// nhất"; `count(n)` reads "n tin nhắn mới" (exported copy).
public enum JumpPill: Equatable, Hashable, Sendable {
    case hidden
    case arrow
    case count(Int)
}

/// The FollowPolicy state machine (§2.5):
///
/// | Input | following | detached(n) |
/// |---|---|---|
/// | opened | scroll to bottom | → following, scroll |
/// | geometry ≤ 24 pt | stay | → following, count cleared |
/// | geometry > 24 pt, the person scrolling | → detached(0) | stay |
/// | geometry > 24 pt, nobody scrolling | scroll to bottom (content grew) | nothing |
/// | appended, localEcho | scroll to bottom | → following, scroll |
/// | appended(k), not localEcho | stay pinned, however tall (B3) | → detached(n + k) |
/// | prepended | nothing | nothing (the view holds its measured anchor) |
/// | typing / edit / keyboard / composer / reset | keep the last row visible | nothing |
/// | jumpTapped | n/a | → following, animated scroll |
public struct FollowPolicy: Equatable, Sendable {
    /// "Near the bottom", plan §1.
    public static let nearBottomPoints: Double = 24

    public private(set) var state: FollowState = .following
    public private(set) var distanceFromBottom: Double = 0
    public private(set) var viewportHeight: Double = 0
    /// The pill's animated scroll is running: its `.animating` geometry must
    /// not count as the person scrolling away.
    private var jumpInFlight = false

    public init() {}

    public var isFollowing: Bool { state == .following }

    /// `following` shows nothing; `detached(0)` shows the arrow once the view
    /// is more than one screen up; `detached(n ≥ 1)` shows the count.
    public var pill: JumpPill {
        switch state {
        case .following:
            return .hidden
        case .detached(0):
            return viewportHeight > 0 && distanceFromBottom > viewportHeight ? .arrow : .hidden
        case let .detached(count):
            return .count(count)
        }
    }

    /// The `transcript` element's accessibility value (§2.10).
    public var accessibilityValue: String { AccessibilityID.transcriptValue(state) }

    @discardableResult
    public mutating func handle(_ input: FollowInput) -> FollowCommand {
        switch input {
        case .opened:
            follow()
            return .scrollToBottom(animated: false)

        case let .geometry(distance, _, height, motion):
            guard distance.isFinite else { return .none }
            distanceFromBottom = distance
            if height.isFinite { viewportHeight = height }
            if distance <= Self.nearBottomPoints {
                follow()
                return .none
            }
            switch motion {
            case .animating where jumpInFlight && isFollowing:
                return .none
            case .user, .animating:
                jumpInFlight = false
                if isFollowing { state = .detached(newCount: 0) }
                return .none
            case .idle:
                return isFollowing ? .scrollToBottom(animated: false) : .none
            }

        case let .appended(count, localEcho):
            if localEcho {
                follow()
                return .scrollToBottom(animated: false)
            }
            switch state {
            case .following:
                return .scrollToBottom(animated: false)
            case let .detached(newCount):
                state = .detached(newCount: newCount + max(0, count))
                return .none
            }

        case .prepended:
            // TranscriptView holds its measured anchor while detached. If
            // following, the idle-geometry rule re-pins the bottom.
            return .none

        case .typingShown, .inPlaceEdit, .keyboardWillShow, .composerGrew, .reset:
            return isFollowing ? .scrollToBottom(animated: false) : .none

        case .jumpTapped:
            follow()
            jumpInFlight = true
            return .scrollToBottom(animated: true)
        }
    }

    private mutating func follow() {
        state = .following
        if distanceFromBottom <= Self.nearBottomPoints { jumpInFlight = false }
    }
}
