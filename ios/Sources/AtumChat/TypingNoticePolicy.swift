import Foundation

/// Typing out (plan B12): only people and group rooms send typing notices;
/// agent and bot rooms send nothing, as on desktop. Editing a non-empty draft
/// sends `Room.typingNotice(isTyping: true)` at most once every 3 s, so a
/// person still typing keeps the notice alive. Sending, clearing the draft,
/// a 6 s pause or leaving the chat sends `typingNotice(isTyping: false)`.
/// The SDK's own keep-alive is undocumented in the bindings, so the throttle
/// lives here.
///
/// Times are monotonic seconds (`ProcessInfo.systemUptime` in the app),
/// injected so tests drive the clock.
public struct TypingNoticePolicy: Equatable, Sendable {
    public static let throttleSeconds: TimeInterval = 3
    public static let pauseSeconds: TimeInterval = 6

    /// The `Room.typingNotice(isTyping:)` call to make, if any.
    public enum Call: Equatable, Hashable, Sendable {
        case none
        /// `typingNotice(isTyping: true)`.
        case typing
        /// `typingNotice(isTyping: false)`.
        case stopped
    }

    public let sendsNotices: Bool
    /// A `typing` notice is out and no `stopped` has followed it.
    public private(set) var isTyping = false
    private var lastNoticeAt: TimeInterval?
    private var lastEditAt: TimeInterval?

    public init(kind: RoomKind) {
        sendsNotices = kind.sendsTypingNotices
    }

    /// When `tick(now:)` must run next to end a pause, or nil when no notice
    /// is out.
    public var pauseDeadline: TimeInterval? {
        guard isTyping, let lastEditAt else { return nil }
        return lastEditAt + Self.pauseSeconds
    }

    /// The draft's text changed (typed, pasted, cleared).
    public mutating func draftChanged(_ text: String, now: TimeInterval) -> Call {
        guard sendsNotices else { return .none }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return stop()
        }
        lastEditAt = now
        if isTyping, let lastNoticeAt, now - lastNoticeAt < Self.throttleSeconds {
            return .none
        }
        isTyping = true
        lastNoticeAt = now
        return .typing
    }

    /// The draft was sent (the composer clears it in the same frame).
    public mutating func sent() -> Call { stop() }

    /// The person left the chat, or the app went to the background.
    public mutating func left() -> Call { stop() }

    /// The pause timer fired: a 6 s pause in editing ends the notice.
    public mutating func tick(now: TimeInterval) -> Call {
        guard let pauseDeadline, now >= pauseDeadline else { return .none }
        return stop()
    }

    private mutating func stop() -> Call {
        guard isTyping else { return .none }
        isTyping = false
        lastNoticeAt = nil
        lastEditAt = nil
        return .stopped
    }
}
