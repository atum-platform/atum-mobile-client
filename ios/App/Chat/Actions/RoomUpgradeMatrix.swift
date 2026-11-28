import AtumChat
import MatrixRustSDK

extension LiveMatrixSession {
    /// Cached Matrix links. Reading them never joins or leaves a room.
    func roomUpgradeContinuity(roomID: String) async -> RoomUpgradeContinuity {
        guard (try? runtime.requireCurrent()) != nil,
              let room = try? room(id: roomID), room.membership() == .joined, !room.isSpace()
        else { return .init() }
        var continuity = RoomUpgradeContinuity()
        if let successor = room.successorRoom() {
            let replacement = try? self.room(id: successor.roomId)
            continuity.successor = await Self.upgradeDestination(old: room, replacementID: successor.roomId,
                                                                 replacement: replacement)
        }
        if let predecessor = room.predecessorRoom(), let earlier = try? self.room(id: predecessor.roomId),
           earlier.membership() == .joined, !earlier.isSpace(), earlier.successorRoom()?.roomId == roomID,
           RoomUpgradeRules.links(old: earlier.id(), replacement: roomID, predecessor: predecessor.roomId) {
            continuity.earlierRoomID = earlier.id()
        }
        guard !Task.isCancelled, (try? runtime.requireCurrent()) != nil else { return .init() }
        return continuity
    }

    /// Explicit banner action. Check the current tombstone and use the chat's
    /// existing access route only after the join and backlink are verified.
    func followRoomUpgrade(roomID: String, replacementID: String) async -> RoomUpgradeDestination {
        do {
            try Task.checkCancellation()
            try runtime.requireCurrent()
            let old = try room(id: roomID)
            guard old.membership() == .joined, !old.isSpace(),
                  old.successorRoom()?.roomId == replacementID else { return .unavailable }
            let known = try? room(id: replacementID)
            let action = await Self.upgradeDestination(old: old, replacementID: replacementID, replacement: known)
            try Task.checkCancellation()
            try runtime.requireCurrent()
            guard old.successorRoom()?.roomId == replacementID else { return .unavailable }
            guard case .join = action else { return action }
            let replacement: Room
            if let known, known.membership() == .invited {
                try await known.join()
                replacement = known
            } else {
                replacement = try await runtime.client.joinRoomById(roomId: replacementID)
            }
            try Task.checkCancellation()
            try runtime.requireCurrent()
            guard old.successorRoom()?.roomId == replacementID, replacement.id() == replacementID,
                  replacement.membership() == .joined else { return .unavailable }
            return await Self.upgradeDestination(old: old, replacementID: replacementID, replacement: replacement)
        } catch {
            return .unavailable
        }
    }

    /// The roster supplies its already-authorized visible room IDs. The
    /// underlying room list stays available for history and lookups.
    func hiddenUpgradePredecessors(visibleRoomIDs: Set<String>) -> Set<String> {
        guard (try? runtime.requireCurrent()) != nil else { return [] }
        var links = [String: String]()
        for old in visibleRoomIDs {
            guard let earlier = try? room(id: old), earlier.membership() == .joined,
                  let successor = earlier.successorRoom()?.roomId, visibleRoomIDs.contains(successor),
                  let replacement = try? room(id: successor), replacement.membership() == .joined,
                  RoomUpgradeRules.links(old: old, replacement: successor,
                                         predecessor: replacement.predecessorRoom()?.roomId) else { continue }
            links[old] = successor
        }
        return RoomUpgradeRules.hiddenPredecessors(verifiedLinks: links)
    }

    private static func upgradeDestination(old: Room, replacementID: String,
                                           replacement: Room?) async -> RoomUpgradeDestination {
        if replacement?.isSpace() == true { return .unavailable }
        let create = try? await replacement?.stateEvents(eventType: .roomCreate)
        return RoomUpgradeRules.successor(old: old.id(), replacement: replacementID,
                                         joined: replacement?.membership() == .joined,
                                         hasCreateState: create?.contains { $0.stateKey.isEmpty } == true,
                                         predecessor: replacement?.predecessorRoom()?.roomId)
    }
}
