#if DEBUG
import Foundation

// Scripted scenarios (plan §2.10): synthetic timelines for previews, the
// G-scroll gate and the XCUITests, picked with `-AtumScripted <scenario>`.
// Debug only: Release builds compile none of this, and the owner never passes
// launch arguments. All data is synthetic: `.test` user IDs, invented names
// and text, no real rooms or people.

/// One chat scenario: what the SDK has cached at open, older history served
/// on demand, timed events, and what happens to the person's sends.
public struct ScriptedScript: Sendable {
    /// The scenario name, e.g. `chat.long`.
    public var name: String
    /// The title capsule's name.
    public var title: String
    public var context: RoomContext
    /// The SDK's cached items at open: the first batch, as a `reset`.
    public var initial: [ChatItem]
    /// Older history, newest page first. `paginateBackwards` serves one page
    /// per call, each a slice of the full transcript (day dividers included).
    public var olderPages: [[ChatItem]]
    /// The start of the room lies just before the oldest page: once every
    /// page is served (or at once, with no pages), the start header is pushed
    /// to the front and pagination reports `hitTimelineStart`. True by
    /// default: a short scenario is the whole room, so the store never asks
    /// for pages that do not exist.
    public var startsAfterOlderPages: Bool
    /// Events at fixed times after the open, in seconds.
    public var steps: [ScriptedStep]
    /// What happens to the person's sends.
    public var sends: ScriptedSendOutcome
    /// The room's agent, bot or person answering each successful send.
    public var replies: ScriptedReplies?
    /// Display names by user ID, for sender lines and typing names.
    public var names: [String: String]

    public init(name: String, title: String, context: RoomContext, initial: [ChatItem],
                olderPages: [[ChatItem]] = [], startsAfterOlderPages: Bool = true,
                steps: [ScriptedStep] = [], sends: ScriptedSendOutcome = .succeeds(after: 0.3),
                replies: ScriptedReplies? = nil, names: [String: String] = [:]) {
        self.name = name
        self.title = title
        self.context = context
        self.initial = initial
        self.olderPages = olderPages
        self.startsAfterOlderPages = startsAfterOlderPages
        self.steps = steps
        self.sends = sends
        self.replies = replies
        self.names = names
    }

    /// The name the chat shows for a user (the typing resolver for scripted
    /// chats): the scenario's names; my own user has none.
    public func name(for userID: String) -> String? {
        userID == context.ownUserID ? nil : names[userID]
    }
}

/// One timed event.
public struct ScriptedStep: Sendable {
    /// Seconds after the open.
    public var at: TimeInterval
    public var event: ScriptedEvent

    public init(at: TimeInterval, _ event: ScriptedEvent) {
        self.at = at
        self.event = event
    }
}

/// What a step does. Item IDs name items already in the timeline (scripted
/// IDs are fixed, so UI tests can query `row.<id>`).
public enum ScriptedEvent: Sendable {
    /// A new remote item from anyone (an agent, a person, my own account on
    /// another device). Placed like the SDK places remote events: above my
    /// local echoes still on their way, with a day divider first when the day
    /// changes. Its timestamp is set to the step's time.
    case arrive(ChatItem)
    /// An in-place edit (`m.replace` arrives as a `set` on the same item).
    case edit(id: String, body: String)
    /// S5's edited notice: body and latest raw metadata change together on
    /// the same stable row ID.
    case editNotice(id: String, body: String, appBotMeta: String?)
    /// A read receipt moves to this item.
    case receipt(userID: String, onItemID: String)
    /// The typing listener reports these user IDs (empty: nobody).
    case typing([String])
    /// The item is redacted.
    case redact(id: String)
}

/// How the person's sends end.
public enum ScriptedSendOutcome: Equatable, Sendable {
    /// Sent after the delay; the remote copy replaces the echo shortly after.
    case succeeds(after: TimeInterval)
    /// A recoverable failure (the SDK disabled the room's queue). Sends made
    /// after it wait, sending, behind it. Re-enabling the queue resends it
    /// and everything behind it, and those resends succeed after
    /// `retryAfter`.
    case failsRecoverably(after: TimeInterval, retryAfter: TimeInterval)
    /// An unrecoverable failure (the request is parked). `retrySend` resends
    /// it, and that resend succeeds after `retryAfter`.
    case failsUnrecoverably(after: TimeInterval, retryAfter: TimeInterval)
    /// Stays sending: the clock never goes away.
    case staysSending
}

/// How the room answers each of the person's sends once it is sent.
public struct ScriptedReplies: Sendable {
    public var sender: String
    /// Seconds after the send is accepted.
    public var seenAfter: TimeInterval
    /// Typing starts; nil for no dots.
    public var typingAfter: TimeInterval?
    /// The answer arrives (and typing stops); nil for no answer.
    public var answerAfter: TimeInterval?
    /// Answer bodies, used in turn.
    public var bodies: [String]
    /// Agents and bots answer with a rich reply to the message (B21); people
    /// just write.
    public var answersAsReply: Bool
    /// The answer grows in place as a live answer streams (`m.replace`
    /// edits): it arrives as the first of these bodies and is edited to each
    /// next one `every` seconds; typing stops only after the last. Nil: it
    /// arrives whole (and typing stops with it).
    public var stream: ScriptedStream?

    public init(sender: String, seenAfter: TimeInterval, typingAfter: TimeInterval? = nil,
                answerAfter: TimeInterval? = nil, bodies: [String] = [], answersAsReply: Bool = true,
                stream: ScriptedStream? = nil) {
        self.sender = sender
        self.seenAfter = seenAfter
        self.typingAfter = typingAfter
        self.answerAfter = answerAfter
        self.bodies = bodies
        self.answersAsReply = answersAsReply
        self.stream = stream
    }
}

/// A streamed answer's bodies, shortest first, and the seconds between them.
public struct ScriptedStream: Sendable {
    public var bodies: [String]
    public var every: TimeInterval

    public init(bodies: [String], every: TimeInterval) {
        self.bodies = bodies
        self.every = every
    }
}
#endif
