import Foundation

/// Earlier history on demand (plan B5, §2.3 rule 7). One per open chat,
/// owned by the store and fed from the view's `.geometry` input and the SDK's
/// back-pagination status.
///
/// - Trigger: the top of the loaded content is within two screen heights of
///   the visible top edge.
/// - One request in flight, and at most one request start every 0.1 s.
/// - Page size 20 events: `Timeline.paginateBackwards(numEvents: 20)`.
/// - Never once the timeline start is reached.
/// - A failed page waits 1 s, 4 s, then 15 s before the next try; after
///   that it waits until the person scrolls (the geometry changes) or the
///   store calls `resume(now:)` (sync recovered, back in the foreground).
///   Offline, an open chat near its top asks at most four times, not ten
///   times a second.
/// - A chat shorter than one screen sits inside the trigger, so the open's
///   one background page (rule 7) needs no rule of its own, and pages keep
///   coming until two screens are filled or the start is reached.
///
/// The trigger, throttle and page size follow Element X at the Apache-2.0
/// revision (`EX: TimelineTableViewController.swift:199-204, 387-399`),
/// rewritten from the plan's plain-language rule; no code was copied.
///
/// Times are monotonic seconds, injected.
public struct PaginationPolicy: Equatable, Sendable {
    public static let pageSize: UInt16 = 20
    public static let triggerScreens: Double = 2
    public static let throttleSeconds: TimeInterval = 0.1
    /// The wait after each consecutive failed page (ReadPolicy's schedule).
    public static let failureRetrySeconds: [TimeInterval] = [1, 4, 15]

    /// What the store does with a geometry update or a finished request.
    public enum Decision: Equatable, Hashable, Sendable {
        case none
        /// Call `paginateBackwards(numEvents: pageSize)` now, then report the
        /// result with `requestFinished(hitTimelineStart:now:)`, or
        /// `requestFailed(now:)` when it threw.
        case request
        /// Inside the trigger but throttled or backing off after a failure:
        /// call `decide(now:)` again at this time.
        case retry(at: TimeInterval)
    }

    /// The SDK's `PaginationStatus`, as last reported.
    public private(set) var status: PaginationState = .idle(hitTimelineStart: false)
    private var requestInFlight = false
    private var lastRequestAt: TimeInterval?
    private var distanceFromTop: Double?
    private var viewportHeight: Double = 0
    /// Consecutive failed pages.
    private var failures = 0
    /// No request before this time (the backoff after a failure).
    private var notBefore: TimeInterval?
    /// Every backoff step failed: wait for a scroll or `resume(now:)`.
    private var suspended = false

    public init() {}

    public var hitTimelineStart: Bool { status == .idle(hitTimelineStart: true) }

    /// The small static atom at the top (the projection's loading row).
    public var showsLoadingRow: Bool { requestInFlight || status == .paginating }

    /// `Timeline.subscribeToBackPaginationStatus` reported a status. A
    /// pagination the SDK ran on its own may end inside the trigger, so this
    /// re-checks the last geometry.
    public mutating func statusChanged(_ newStatus: PaginationState, now: TimeInterval) -> Decision {
        status = newStatus
        return decide(now: now)
    }

    /// The view's `.geometry` input (`distanceFromTop`, `viewportHeight`).
    /// After every backoff step failed, a changed geometry (the person
    /// scrolled) tries again with a fresh backoff; during a backoff it waits.
    public mutating func geometry(distanceFromTop: Double, viewportHeight: Double,
                                  now: TimeInterval) -> Decision {
        var changed = false
        if distanceFromTop.isFinite, distanceFromTop != self.distanceFromTop {
            self.distanceFromTop = distanceFromTop
            changed = true
        }
        if viewportHeight.isFinite, viewportHeight != self.viewportHeight {
            self.viewportHeight = viewportHeight
            changed = true
        }
        if changed, suspended { clearFailures() }
        return decide(now: now)
    }

    /// The network may be back (sync recovered, or the app returned to the
    /// foreground): drop any backoff and re-check the last geometry.
    public mutating func resume(now: TimeInterval) -> Decision {
        clearFailures()
        return decide(now: now)
    }

    /// Re-checks the last geometry: after a request finished, or at a
    /// `.retry` time.
    public mutating func decide(now: TimeInterval) -> Decision {
        guard !requestInFlight, status != .paginating, !hitTimelineStart, !suspended,
              viewportHeight > 0, let distanceFromTop,
              distanceFromTop <= Self.triggerScreens * viewportHeight else { return .none }
        var earliest = -TimeInterval.infinity
        if let lastRequestAt { earliest = lastRequestAt + Self.throttleSeconds }
        if let notBefore { earliest = max(earliest, notBefore) }
        if now < earliest { return .retry(at: earliest) }
        requestInFlight = true
        lastRequestAt = now
        return .request
    }

    /// `paginateBackwards` returned (true at the start of the room). Returns
    /// whether to ask again right away: the rows added above may still leave
    /// the top inside the trigger.
    public mutating func requestFinished(hitTimelineStart: Bool, now: TimeInterval) -> Decision {
        requestInFlight = false
        clearFailures()
        if hitTimelineStart { status = .idle(hitTimelineStart: true) }
        return decide(now: now)
    }

    /// `paginateBackwards` threw (offline, a server error). Returns when to
    /// try again, if at all: `.retry(at:)` after the next backoff step while
    /// the top is still near; nothing once every step failed.
    public mutating func requestFailed(now: TimeInterval) -> Decision {
        requestInFlight = false
        failures += 1
        guard failures <= Self.failureRetrySeconds.count else {
            notBefore = nil
            suspended = true
            return .none
        }
        notBefore = now + Self.failureRetrySeconds[failures - 1]
        return decide(now: now)
    }

    private mutating func clearFailures() {
        failures = 0
        notBefore = nil
        suspended = false
    }
}
