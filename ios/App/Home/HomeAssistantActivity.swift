import AtumChat
import Foundation
import MatrixRustSDK
import Observation

/// HC-3: the live "assistant at work" signal for Home's assistant rows. It
/// listens to the typing notifications of my assistants' own rooms only
/// (a handful of rooms) and publishes the rooms where the agent is typing,
/// through the pure `RosterWorking` rule. Nothing is persisted: the set is
/// empty after a cold launch until the agent's next typing notice arrives.
@MainActor
@Observable
final class HomeAssistantActivity {
    /// The assistant rooms with a turn running now.
    private(set) var workingRoomIDs = Set<String>()

    @ObservationIgnored private var session: ObjectIdentifier?
    @ObservationIgnored private var ownUserID = ""
    @ObservationIgnored private var watched = [String: Watch]()
    @ObservationIgnored private var typing = [String: [String]]()
    @ObservationIgnored private var sequences = [String: UInt64]()

    private final class Watch {
        let handle: TaskHandle
        let listener: HomeTypingListener
        init(handle: TaskHandle, listener: HomeTypingListener) {
            self.handle = handle
            self.listener = listener
        }
    }

    /// Follows exactly these rooms of this session. A new session drops every
    /// old subscription first; nil stops everything.
    func watch(roomIDs: Set<String>, session matrix: LiveMatrixSession?) {
        let identity = matrix.map { ObjectIdentifier($0) }
        if identity != session {
            stopAll()
            session = identity
        }
        guard let matrix, matrix.isReady else {
            stopAll()
            return
        }
        for roomID in watched.keys where !roomIDs.contains(roomID) {
            watched.removeValue(forKey: roomID)?.handle.cancel()
            typing.removeValue(forKey: roomID)
            sequences.removeValue(forKey: roomID)
        }
        for roomID in roomIDs where watched[roomID] == nil {
            guard let room = try? matrix.room(id: roomID) else { continue }
            ownUserID = room.ownUserId()
            let listener = HomeTypingListener { [weak self] sequence, userIDs in
                Task { @MainActor in self?.receive(roomID: roomID, userIDs: userIDs, sequence: sequence) }
            }
            watched[roomID] = Watch(handle: room.subscribeToTypingNotifications(listener: listener),
                                    listener: listener)
        }
        publish()
    }

    func stopAll() {
        for watch in watched.values { watch.handle.cancel() }
        watched = [:]
        typing = [:]
        sequences = [:]
        publish()
    }

    private func receive(roomID: String, userIDs: [String], sequence: UInt64) {
        // Callbacks hop to the main actor in separate tasks: an older list
        // never overwrites a newer one, and a room no longer watched is ignored.
        guard watched[roomID] != nil, sequence > sequences[roomID, default: 0] else { return }
        sequences[roomID] = sequence
        typing[roomID] = userIDs
        publish()
    }

    private func publish() {
        let next = RosterWorking.rooms(typing: typing, ownUserID: ownUserID,
                                       assistantRoomIDs: Set(watched.keys))
        if next != workingRoomIDs { workingRoomIDs = next }
    }
}

private final class HomeTypingListener: TypingNotificationsListener, @unchecked Sendable {
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

/// What `HomeAssistantActivity.watch` follows: re-run when the session, its
/// readiness or the set of assistant rooms changes.
struct HomeAssistantActivityKey: Hashable {
    let session: ObjectIdentifier?
    let ready: Bool
    let roomIDs: Set<String>
}
