import Foundation

/// HC-3: where Home shows an assistant at work (desktop `roster-working.ts`
/// `matrixWorkingRooms`, `roster-conversations.tsx` `RosterWorking`): Atum's
/// atom in the time's place while a turn runs.
///
/// The desktop reads its own agent runtime. The phone has only the room's real
/// signals, so a turn counts as running while someone other than me is typing
/// in my assistant's own room (the agent's typing notice, which the cloud
/// runtime refreshes for the whole turn). Typing is ephemeral: nothing is
/// stored, so a cold launch never paints a stale atom, and the atom clears as
/// soon as the agent's typing lapses at the turn's end.
///
/// Display only, never authority: it decides no stop, send or read.
public enum RosterWorking {
    /// The assistant rooms with a turn running now.
    ///
    /// - Parameters:
    ///   - typing: the typing user IDs last reported for each watched room.
    ///   - ownUserID: this account; my own typing never counts.
    ///   - assistantRoomIDs: my assistants' own rooms. Any other room (people,
    ///     groups, app bots) never shows the atom from this signal.
    public static func rooms(typing: [String: [String]], ownUserID: String,
                             assistantRoomIDs: Set<String>) -> Set<String> {
        var result = Set<String>()
        for (roomID, userIDs) in typing where assistantRoomIDs.contains(roomID) {
            if !TypingNames.others(userIDs, ownUserID: ownUserID).isEmpty {
                result.insert(roomID)
            }
        }
        return result
    }
}
