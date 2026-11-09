import Foundation

/// Row actions, passed to every row view as one environment value (plan
/// §2.6 "Rendering"), so no view rebuilds closures in `body`. The store
/// fills them; the defaults do nothing. All run on the main actor. Which
/// rows offer which action is `ChatItemRules` (the menu shows, the store
/// enforces).
public struct ChatActions: Sendable {
    /// B8: "Thử lại" on a failed send.
    public var retrySend: @MainActor @Sendable (_ itemID: String) -> Void
    /// B8: "Xóa" in the failed-send sheet: aborts a failed (or held) send.
    public var deleteSend: @MainActor @Sendable (_ itemID: String) -> Void
    /// B20: "Sao chép".
    public var copy: @MainActor @Sendable (_ itemID: String) -> Void
    /// B21: "Trả lời".
    public var reply: @MainActor @Sendable (_ itemID: String) -> Void
    /// B22: toggle my reaction.
    public var toggleReaction: @MainActor @Sendable (_ itemID: String, _ key: String) -> Void
    /// B17: every link tap, through `LinkPolicy`.
    public var openLink: @MainActor @Sendable (_ url: String) -> Void
    /// B20: "Xóa" in the menu on my message: redacts it, or aborts it when
    /// it is a failed send, or drops it when it is held (contract amendment,
    /// S1 day 1).
    public var delete: @MainActor @Sendable (_ itemID: String) -> Void
    /// B20: "Sửa" on my text message in people and group chats: loads it
    /// into the composer (`ConversationStore.beginEdit`; contract amendment,
    /// S1 day 1).
    public var edit: @MainActor @Sendable (_ itemID: String) -> Void

    public init(retrySend: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                deleteSend: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                copy: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                reply: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                toggleReaction: @escaping @MainActor @Sendable (String, String) -> Void = { _, _ in },
                openLink: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                delete: @escaping @MainActor @Sendable (String) -> Void = { _ in },
                edit: @escaping @MainActor @Sendable (String) -> Void = { _ in }) {
        self.retrySend = retrySend
        self.deleteSend = deleteSend
        self.copy = copy
        self.reply = reply
        self.toggleReaction = toggleReaction
        self.openLink = openLink
        self.delete = delete
        self.edit = edit
    }

    public static let none = ChatActions()
}

/// SDK `PaginationStatus` as a plain value (B5).
public enum PaginationState: Equatable, Hashable, Sendable {
    case idle(hitTimelineStart: Bool)
    case paginating
}

/// A scroll command from the store to the view. `sequence` grows with every
/// request, so the view applies a repeated command too (it watches the value
/// with `onChange`).
public struct ScrollRequest: Equatable, Hashable, Sendable {
    public var sequence: UInt64
    public var command: FollowCommand

    public init(sequence: UInt64, command: FollowCommand) {
        self.sequence = sequence
        self.command = command
    }

    public static let initial = ScrollRequest(sequence: 0, command: .none)
}

/// One open chat (plan §2.6). The app's `@MainActor @Observable` class holds
/// its own room and a timeline controller over a `ChatTimelineSource` (the
/// SDK's, or the scripted one in UI tests), so a chat no longer depends on
/// the roster rows. Frozen in S0 and amended once by the coordinator at the
/// end of S1's first lane day (2026-10-11: the edit and reply controls,
/// `parsedBody(for:)`, `typingLine`); frozen again until wave 2.
///
/// The view reads `snapshot`, `follow`, `scrollRequest`, `draft`,
/// `typingLine`, `editTarget`, `replyTarget` and `actions`; it sends
/// geometry, phase and visibility in through `handle(_:)` and
/// `bottomVisible`, and never diffs arrays itself. The connection glyph
/// (B30) is not the store's: the chat screen reads it from the environment
/// (`showsConnectionGlyph`, from `SessionLifecycleControlling`).
///
/// Markdown: the implementation parses message bodies off the main actor in
/// its projector Task, once per `(row id, body)`, into a parse cache it
/// publishes together with each snapshot; row views read the parsed body
/// with `parsedBody(for:)` and never parse (`ChatItem.body`).
@MainActor
public protocol ConversationStore: AnyObject {
    var roomID: String { get }
    var kind: RoomKind { get }
    /// This account's user ID. Reaction menus read it from the same store as
    /// the rows, so a renewed session cannot give the palette stale identity.
    var ownUserID: String { get }
    /// The title capsule's name.
    var title: String { get }
    /// Display rows and how they changed (§2.3).
    var snapshot: Snapshot { get }
    /// Follow state and the pill (§2.5).
    var follow: FollowPolicy { get }
    /// The latest command for the transcript.
    var scrollRequest: ScrollRequest { get }
    /// Display names of whoever is typing, my own user dropped (B10, B11).
    /// In agent and bot rooms the projection shows them as the last row; in
    /// people and group rooms they show as `typingLine` instead (§2.7,
    /// `TypingNames.presentation`).
    var typingNames: [String] { get }
    /// B11: the quiet line above the composer in people and group rooms;
    /// `.nobody` in agent and bot rooms (contract amendment, S1 day 1).
    var typingLine: TypingLine { get }
    var pagination: PaginationState { get }
    /// Kept per room while the app runs (B25).
    var draft: String { get set }
    /// The event a reply will answer (B21): the reply chip in the composer.
    var replyTarget: String? { get set }
    /// B20: the row "Sửa" loaded into the composer (the edit chip), or nil.
    /// While set, `send()` posts the edit and never a new message.
    var editTarget: String? { get }
    var actions: ChatActions { get }
    /// Set by the view: the app is active, this chat is on screen and its
    /// bottom is within 24 pt. Read by the read rule (B13).
    var bottomVisible: Bool { get set }

    /// Geometry, phase, visibility, keyboard and composer events from the
    /// view; the store publishes the resulting `scrollRequest`.
    ///
    /// `.geometry` is also the pagination input: from S1b the store runs
    /// `PaginationPolicy` (two-screen trigger, 0.1 s throttle, one request
    /// in flight) on `distanceFromTop` and `viewportHeight` and calls
    /// `paginateBackwards(20)`, publishing `pagination`. A chat shorter than
    /// one screen sits inside the trigger, which is also how S1a's single
    /// background page (§2.3 rule 7) can be decided. `TranscriptView` owns
    /// its measured prepend anchor; the policy does not carry a second row-ID
    /// anchor.
    func handle(_ input: FollowInput)
    /// B6: sends the trimmed draft as plain text, clearing it in the same
    /// frame. Never disables the composer.
    func send()
    /// B20 "Sửa": loads my message into the composer; the draft that was
    /// there comes back after the edit is sent, cancelled or replaced. Does
    /// nothing for a row `ChatItemRules.canEdit` refuses.
    func beginEdit(_ itemID: String)
    /// Closes the edit chip; the earlier draft comes back.
    func cancelEdit()
    /// Closes the reply chip.
    func cancelReply()
    /// The parsed markdown of an answer or notice row, if its body has not
    /// changed since it was parsed; nil for my own messages (they show
    /// literally) and while the parse is pending.
    func parsedBody(for row: ChatRow) -> AttributedString?
}
