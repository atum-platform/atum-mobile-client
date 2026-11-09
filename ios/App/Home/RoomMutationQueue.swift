import Foundation

/// Serializes SDK writes for one semantic room field while allowing unrelated
/// rooms/fields to proceed independently. Cancelling a tail prevents queued
/// work from starting; an FFI call already in flight is still fenced by the
/// model's session and optimistic-generation checks.
@MainActor
final class RoomMutationQueue<Key: Hashable> {
    private struct Tail {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private var tails = [Key: Tail]()
    private var nextGeneration: UInt64 = 0

    func enqueue(for key: Key, operation: @escaping @MainActor () async -> Void) {
        nextGeneration &+= 1
        let generation = nextGeneration
        let predecessor = tails[key]?.task
        let task = Task { @MainActor [weak self] in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            await operation()
            guard self?.tails[key]?.generation == generation else { return }
            self?.tails[key] = nil
        }
        tails[key] = Tail(generation: generation, task: task)
    }

    func waitForIdle(_ key: Key) async {
        await tails[key]?.task.value
    }

    func cancelAll() {
        for tail in tails.values { tail.task.cancel() }
        tails.removeAll()
    }
}

struct PendingRoomMutation: Equatable {
    let desired: Bool
    let generation: UInt64
    /// Once the SDK call returns, the next authoritative room publication is
    /// newer than the optimistic write and wins even when it disagrees.
    var settleAfterRoomRevision: UInt64?

    func shouldRetire(actualMatches: Bool, publicationRevision: UInt64) -> Bool {
        if actualMatches { return true }
        guard let settleAfterRoomRevision else { return false }
        return publicationRevision > settleAfterRoomRevision
    }
}
