import Foundation

/// How often an open sheet reads a move's progress.
///
/// Owner reads are rate limited, so the cadence backs off instead of ticking at
/// a fixed second: it starts at two seconds, doubles up to thirty, and starts
/// over when a read shows something new. A 429 waits for at least the server's
/// `Retry-After` (never more than two minutes) and is never a failure; neither
/// is a dropped connection or a 503, which say nothing about the move.
public struct AgentHomeProgressPolling: Equatable, Sendable {
    public static let initialDelay: TimeInterval = 2
    public static let maximumDelay: TimeInterval = 30
    public static let maximumRetryAfter: TimeInterval = 120

    /// What the last read (or the start of polling) taught us.
    public enum Outcome: Equatable, Sendable {
        case started
        case changed
        case unchanged
        case transientFailure
        case rateLimited(retryAfter: TimeInterval)
    }

    /// What a failed read means for the poll loop.
    public enum FailureClass: Equatable, Sendable {
        /// Back off at least `retryAfter`; the move is untouched.
        case rateLimited(retryAfter: TimeInterval)
        /// Offline or a platform hiccup: say nothing, try again later.
        case transient
        /// The loop's own task was cancelled: stop quietly.
        case cancelled
        /// The platform answered and the answer is final: the read failed.
        case definitive
    }

    private var step = 0

    public init() {}

    /// The wait before the next read.
    public mutating func delay(after outcome: Outcome) -> TimeInterval {
        switch outcome {
        case .started, .changed:
            step = 0
        case .unchanged, .transientFailure, .rateLimited:
            // The ceiling holds from the fourth doubling; the cap only keeps the power small.
            step = min(step + 1, 6)
        }
        var wait = min(Self.initialDelay * pow(2, Double(step)), Self.maximumDelay)
        if case let .rateLimited(retryAfter) = outcome {
            wait = min(max(wait, retryAfter), Self.maximumRetryAfter)
        }
        return wait
    }

    public static func classify(_ error: Error) -> FailureClass {
        if error is CancellationError { return .cancelled }
        guard let failure = error as? NativeDomainClientFailure else { return .definitive }
        switch failure {
        case .cancelled:
            return .cancelled
        case .transportUnavailable:
            return .transient
        case let .http(http):
            switch http.response.error {
            case .rateLimited: return .rateLimited(retryAfter: TimeInterval(http.retryAfterSeconds ?? 0))
            case .unavailable: return .transient
            default: return .definitive
            }
        default:
            return .definitive
        }
    }
}
