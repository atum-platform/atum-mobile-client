import AtumChat
import Foundation
import MatrixRustSDK

// Typing in and out for one open room (plan B10–B12, §2.2). The rules are
// AtumChat's `TypingNames` and `TypingNoticePolicy`; this file only wires them
// to the SDK. Real signals only: the names come from the room's typing
// listener, never from a guess that an agent is working.

/// What a `ConversationStore` needs from typing. The store owns one per open
/// chat and closes it when the chat closes.
@MainActor
protocol TypingControlling: AnyObject {
    /// Display names of the others typing now, my own user dropped, in the
    /// SDK's order (B10). In an agent or bot room an unnamed typer shows as
    /// the room's title, so the agent's dots never wait for a name. Pass them
    /// through
    /// `TypingNames.presentation(kind:names:)`: agents and bots get the typing
    /// row, people and groups the line above the composer.
    var typingNames: [String] { get }
    /// Called on the main actor after `typingNames` changed.
    var onTypingNamesChange: (@MainActor ([String]) -> Void)? { get set }
    /// The owner's activity switch changed while the chat is open.
    func setShareActivity(_ sharing: Bool)
    /// The composer's draft changed (B12; people and group rooms only).
    func draftChanged(_ text: String)
    /// The draft was sent.
    func messageSent()
    /// The chat closed: typing out stops and the listener goes.
    func close()
}

/// The SDK side: `Room.subscribeToTypingNotifications` in,
/// `Room.typingNotice(isTyping:)` out.
@MainActor
final class TypingController: TypingControlling {
    /// Applies the label rule the chat uses for sender names (the app passes
    /// `MobileSenderLabelPolicy.label` with the known agent and bot names):
    /// user ID and profile display name in, a usable name or nil out. Called
    /// first without a profile name; a typer it cannot name then gets one
    /// `Room.memberDisplayName` lookup.
    typealias Label = @MainActor (_ userID: String, _ profileDisplayName: String?) -> String?

    private(set) var typingNames: [String] = []
    var onTypingNamesChange: (@MainActor ([String]) -> Void)?

    private let room: Room
    private let ownUserID: String
    private let kind: RoomKind
    private let roomTitle: String?
    private let label: Label
    /// The owner's `io.atum.desktop.share_activity`: off sends no public
    /// typing notice at all (§9.1). It follows the setting while a chat is
    /// open; turning it off ends an outstanding notice.
    private var shareActivity: Bool
    private var notice: TypingNoticePolicy
    private var typingUserIDs: [String] = []
    private var profileNames: [String: String] = [:]
    private var lookedUp: Set<String> = []
    private var listener: TypingListener?
    private var listenerHandle: TaskHandle?
    private var lastSequence: UInt64 = 0
    private var pauseTimer: Task<Void, Never>?
    private var noticeTail: Task<Void, Never>?
    private var closed = false

    /// `roomTitle` is the title the chat's header shows (the agent's or
    /// bot's name in their rooms).
    init(room: Room, kind: RoomKind, roomTitle: String?, shareActivity: Bool = true,
         label: @escaping Label) {
        self.room = room
        ownUserID = room.ownUserId()
        self.kind = kind
        self.roomTitle = roomTitle
        self.shareActivity = shareActivity
        self.label = label
        notice = TypingNoticePolicy(kind: kind)
    }

    /// Subscribes to the room's typing notifications. Idempotent.
    func start() {
        guard listenerHandle == nil, !closed else { return }
        let listener = TypingListener { [weak self] sequence, userIDs in
            Task { @MainActor in self?.receive(userIDs, sequence: sequence) }
        }
        self.listener = listener
        listenerHandle = room.subscribeToTypingNotifications(listener: listener)
    }

    func draftChanged(_ text: String) {
        guard !closed, shareActivity else { return }
        perform(notice.draftChanged(text, now: Self.now))
        schedulePause()
    }

    func messageSent() {
        guard !closed else { return }
        perform(notice.sent())
        schedulePause()
    }

    func setShareActivity(_ sharing: Bool) {
        guard shareActivity != sharing else { return }
        shareActivity = sharing
        guard !sharing else { return }
        perform(notice.left())
        pauseTimer?.cancel()
        pauseTimer = nil
    }

    func close() {
        guard !closed else { return }
        perform(notice.left())
        closed = true
        pauseTimer?.cancel()
        pauseTimer = nil
        listenerHandle?.cancel()
        listenerHandle = nil
        listener = nil
        typingUserIDs = []
        publish()
    }

    // MARK: Typing in

    private func receive(_ userIDs: [String], sequence: UInt64) {
        // Callbacks hop to the main actor in separate tasks; never let an
        // older list overwrite a newer one.
        guard !closed, sequence > lastSequence else { return }
        lastSequence = sequence
        typingUserIDs = TypingNames.others(userIDs, ownUserID: ownUserID)
        publish()
        for userID in typingUserIDs where name(for: userID) == nil && !lookedUp.contains(userID) {
            lookUpProfileName(userID)
        }
    }

    private func name(for userID: String) -> String? {
        label(userID, profileNames[userID])
    }

    private func lookUpProfileName(_ userID: String) {
        lookedUp.insert(userID)
        let room = room
        Task { @MainActor [weak self] in
            guard let profile = try? await room.memberDisplayName(userId: userID) else { return }
            guard let self, !self.closed else { return }
            self.profileNames[userID] = profile
            self.publish()
        }
    }

    private func publish() {
        var resolved: [String: String] = [:]
        for userID in typingUserIDs {
            if let value = name(for: userID) { resolved[userID] = value }
        }
        let known = resolved
        let names = TypingNames.displayNames(typingUserIDs, ownUserID: ownUserID, kind: kind, roomTitle: roomTitle,
                                             name: { known[$0] })
        guard names != typingNames else { return }
        if typingNames.isEmpty, !names.isEmpty {
            ProbeLog.mark(.typingShown, fields: ["count": String(min(names.count, 9))])
        }
        typingNames = names
        onTypingNamesChange?(names)
    }

    // MARK: Typing out

    /// Notices go out one at a time, in order, so a `false` never overtakes
    /// the `true` before it.
    private func perform(_ call: TypingNoticePolicy.Call) {
        let isTyping: Bool
        switch call {
        case .none: return
        case .typing: isTyping = true
        case .stopped: isTyping = false
        }
        let previous = noticeTail
        let room = room
        noticeTail = Task {
            await previous?.value
            try? await room.typingNotice(isTyping: isTyping)
        }
    }

    private func schedulePause() {
        pauseTimer?.cancel()
        guard let deadline = notice.pauseDeadline else {
            pauseTimer = nil
            return
        }
        let delay = max(0, deadline - Self.now)
        pauseTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.perform(self.notice.tick(now: Self.now))
            self.schedulePause()
        }
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

/// The SDK calls this from its own threads. It numbers each callback so the
/// main actor can drop one that arrives after a newer list.
private final class TypingListener: TypingNotificationsListener, @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private let deliver: @Sendable (UInt64, [String]) -> Void

    init(deliver: @escaping @Sendable (UInt64, [String]) -> Void) {
        self.deliver = deliver
    }

    func call(typingUserIds: [String]) {
        lock.lock()
        sequence &+= 1
        let current = sequence
        lock.unlock()
        deliver(current, typingUserIds)
    }
}
