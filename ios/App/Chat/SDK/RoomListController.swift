import Foundation

/// The SDK listener maps its entry updates into this narrow, ID-only seam.
/// No Matrix object crosses into stores or views, and a test adapter can use
/// the exact same incremental contract.
enum RoomListDiff: Equatable, Sendable {
    case append([String])
    case clear
    case pushFront(String)
    case pushBack(String)
    case popFront
    case popBack
    case insert(index: Int, roomID: String)
    case set(index: Int, roomID: String)
    case remove(index: Int)
    case truncate(length: Int)
    case reset([String])
}

enum RoomListControllerError: Error, Equatable, Sendable {
    case invalidDiff
}

/// A single ordered row in a publication.  The `roomID` is retained even when
/// the reader could not currently produce a snapshot, so the next touched
/// update can fill it without losing the list's SDK ordering.
struct RoomListEntry<Value: Sendable>: Sendable {
    let roomID: String
    let value: Value
}

/// Immutable plain data delivered to the main actor.  `generation` lets the
/// consumer fence an older detached read behind a newer room-list batch.
struct RoomListPublication<Value: Sendable>: Sendable {
    let generation: UInt64
    let entries: [RoomListEntry<Value>]
}

/// Applies list diffs serially, re-reading only IDs introduced or replaced by
/// that diff.  It stores IDs and Sendable snapshots, never Matrix SDK values.
///
/// A live adapter supplies `readRoom` using `roomInfo()` / `latestEvent()`.
/// Because reads suspend, a later diff may arrive first; the generation check
/// drops that stale read rather than publishing an older ordering.
actor RoomListController<Value: Sendable> {
    typealias RoomReader = @Sendable (String) async -> Value?

    private let readRoom: RoomReader
    private var roomIDs = [String]()
    private var valuesByID = [String: Value]()
    private var generation: UInt64 = 0

    init(readRoom: @escaping RoomReader) {
        self.readRoom = readRoom
    }

    /// Applies one callback batch and returns its ordered, fully plain
    /// publication.  A malformed SDK diff leaves state unchanged and is
    /// surfaced to the session as a callback failure.
    func apply(_ updates: [RoomListDiff]) async throws -> RoomListPublication<Value>? {
        var proposed = roomIDs
        let touchedIDs = try Self.apply(updates, to: &proposed)
        let liveIDs = Set(proposed)
        // A single SDK callback can insert then remove an entry.  It was
        // touched, but is no longer represented by this generation and must
        // not trigger a needless room read.
        var rereadIDs = touchedIDs.filter { liveIDs.contains($0) }
        var scheduled = Set(rereadIDs)
        // A later removal-only batch can overtake an earlier suspended first
        // read. Re-read only still-live IDs that have never produced a value;
        // cached unaffected rooms remain untouched.
        for roomID in proposed where valuesByID[roomID] == nil && scheduled.insert(roomID).inserted {
            rereadIDs.append(roomID)
        }
        generation &+= 1
        let expectedGeneration = generation
        roomIDs = proposed

        // Removing entries is itself a complete publication once every live
        // ID has a cached value; it never rereads an unaffected cached room.
        guard !rereadIDs.isEmpty else {
            pruneValuesToCurrentIDs()
            return publication(generation: expectedGeneration)
        }

        var refreshed = [(roomID: String, value: Value?)]()
        refreshed.reserveCapacity(rereadIDs.count)
        for roomID in rereadIDs {
            refreshed.append((roomID, await readRoom(roomID)))
        }

        // `await readRoom` made this actor re-entrant.  A later update owns
        // the state and publication if it advanced the counter meanwhile.
        guard generation == expectedGeneration else { return nil }
        for (roomID, value) in refreshed {
            valuesByID[roomID] = value
        }
        pruneValuesToCurrentIDs()
        return publication(generation: expectedGeneration)
    }

    private func publication(generation: UInt64) -> RoomListPublication<Value> {
        RoomListPublication(
            generation: generation,
            entries: roomIDs.compactMap { roomID in
                valuesByID[roomID].map { RoomListEntry(roomID: roomID, value: $0) }
            }
        )
    }

    private func pruneValuesToCurrentIDs() {
        let liveIDs = Set(roomIDs)
        valuesByID = valuesByID.filter { liveIDs.contains($0.key) }
    }

    /// Returns IDs whose backing SDK values changed and therefore need a
    /// fresh read.  Removal-only operations intentionally return no IDs.
    private static func apply(_ updates: [RoomListDiff], to roomIDs: inout [String]) throws -> [String] {
        var rereadIDs = [String]()
        var seenRereadIDs = Set<String>()

        func appendTouched(_ ids: [String]) {
            for id in ids where !id.isEmpty && seenRereadIDs.insert(id).inserted {
                rereadIDs.append(id)
            }
        }

        for update in updates {
            switch update {
            case let .append(ids):
                roomIDs.append(contentsOf: ids)
                appendTouched(ids)
            case .clear:
                roomIDs.removeAll()
            case let .pushFront(roomID):
                roomIDs.insert(roomID, at: 0)
                appendTouched([roomID])
            case let .pushBack(roomID):
                roomIDs.append(roomID)
                appendTouched([roomID])
            case .popFront:
                guard !roomIDs.isEmpty else { throw RoomListControllerError.invalidDiff }
                roomIDs.removeFirst()
            case .popBack:
                guard !roomIDs.isEmpty else { throw RoomListControllerError.invalidDiff }
                roomIDs.removeLast()
            case let .insert(index, roomID):
                guard roomIDs.indices.contains(index) || index == roomIDs.endIndex else {
                    throw RoomListControllerError.invalidDiff
                }
                roomIDs.insert(roomID, at: index)
                appendTouched([roomID])
            case let .set(index, roomID):
                guard roomIDs.indices.contains(index) else { throw RoomListControllerError.invalidDiff }
                roomIDs[index] = roomID
                appendTouched([roomID])
            case let .remove(index):
                guard roomIDs.indices.contains(index) else { throw RoomListControllerError.invalidDiff }
                roomIDs.remove(at: index)
            case let .truncate(length):
                guard (0...roomIDs.count).contains(length) else { throw RoomListControllerError.invalidDiff }
                roomIDs.removeLast(roomIDs.count - length)
            case let .reset(ids):
                roomIDs = ids
                // A reset carries a new SDK entry set, so every retained ID
                // was touched by this callback and is reread once.
                appendTouched(ids)
            }
        }
        guard !roomIDs.contains(where: \.isEmpty), Set(roomIDs).count == roomIDs.count else {
            throw RoomListControllerError.invalidDiff
        }
        return rereadIDs
    }
}
