import AtumChat
import Observation

/// Plain, SDK-free roster input.  The SDK adapter turns room-list changes
/// into this value before crossing to the main actor.
struct RosterSnapshot: Equatable, Sendable {
    var rooms: [RosterProjection.Room]
    var assistants: [RosterProjection.Assistant]
    var apps: [RosterProjection.App]
    var founderRoomID: String?

    init(rooms: [RosterProjection.Room] = [],
         assistants: [RosterProjection.Assistant] = [],
         apps: [RosterProjection.App] = [],
         founderRoomID: String? = nil) {
        self.rooms = rooms
        self.assistants = assistants
        self.apps = apps
        self.founderRoomID = founderRoomID
    }

    var projectionInput: RosterProjection.Input {
        RosterProjection.Input(assistants: assistants, rooms: rooms, apps: apps,
                               founderRoomID: founderRoomID)
    }
}

/// Main-actor bridge from plain room snapshots to Home's two ordered sections.
/// All classification and ordering remain in the independently-tested pure
/// `RosterProjection`; this store owns neither Matrix objects nor policy.
@MainActor
@Observable
final class RosterStore {
    private(set) var snapshot: RosterSnapshot
    /// First occurrence wins, matching `RosterProjection`'s duplicate-room
    /// rule.  The dictionary supports targeted row actions without changing
    /// the projection's source ordering.
    private(set) var roomsByID: [String: RosterProjection.Room]
    private(set) var output: RosterProjection.Output

    var assistantRows: [RosterProjection.Row] { output.assistants }
    var chatRows: [RosterProjection.Row] { output.chats }

    init(snapshot: RosterSnapshot = RosterSnapshot()) {
        self.snapshot = snapshot
        roomsByID = Self.indexedRooms(snapshot.rooms)
        output = RosterProjection.project(snapshot.projectionInput)
    }

    /// Applies one immutable, Sendable snapshot.  Equivalent publications do
    /// not churn SwiftUI observation or re-sort Home.
    func apply(_ snapshot: RosterSnapshot) {
        guard snapshot != self.snapshot else { return }
        self.snapshot = snapshot
        roomsByID = Self.indexedRooms(snapshot.rooms)
        output = RosterProjection.project(snapshot.projectionInput)
    }

    /// Replaces only the room side of a domain refresh while retaining the
    /// last authoritative agents/apps classification inputs.
    func applyRooms(_ rooms: [RosterProjection.Room]) {
        guard rooms != snapshot.rooms else { return }
        snapshot.rooms = rooms
        roomsByID = Self.indexedRooms(rooms)
        output = RosterProjection.project(snapshot.projectionInput)
    }

    private static func indexedRooms(_ rooms: [RosterProjection.Room]) -> [String: RosterProjection.Room] {
        var result = [String: RosterProjection.Room]()
        for room in rooms where !room.id.isEmpty && result[room.id] == nil {
            result[room.id] = room
        }
        return result
    }
}
