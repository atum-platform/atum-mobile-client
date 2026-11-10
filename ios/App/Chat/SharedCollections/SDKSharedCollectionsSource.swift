import AtumChat
import Foundation
import MatrixRustSDK

private enum SharedSDKInput: Sendable {
    case diffs([TimelineDiff])
    case checkpoint(UUID)
}

/// A read-only filtered timeline on the session's Room, never another Client.
/// Separate instances preserve each section's SDK back-pagination position.
@MainActor
final class SDKSharedCollectionsSource: SharedCollectionSource {
    let updates: AsyncStream<SharedCollectionSnapshot>
    private let output: AsyncStream<SharedCollectionSnapshot>.Continuation
    private let inputs: AsyncStream<SharedSDKInput>
    private let input: AsyncStream<SharedSDKInput>.Continuation
    private var timeline: Timeline?
    private let mapper: ItemMapper
    private let section: SharedCollectionSection
    private let encrypted: Bool
    private var projection = SharedCollectionsProjection()
    private var snapshot = SharedCollectionSnapshot()
    private var listener: TaskHandle?
    private var consumer: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<SharedCollectionSnapshot, any Error>] = [:]
    private var initialWaiters: [CheckedContinuation<SharedCollectionSnapshot, any Error>] = []
    private var receivedInitial = false
    private var resetGeneration: UInt64 = 0
    private var closed = false
    private var terminalFailure: SharedCollectionFailure?

    static func make(room: Room, mapperRoom: ItemMapperRoom,
                     section: SharedCollectionSection) async throws -> SDKSharedCollectionsSource {
        let types: [RoomMessageEventMessageType] = switch section {
        case .media: [.image, .video]
        case .files: [.file, .audio]
        case .links: [.text, .notice, .emote]
        }
        let config = TimelineConfiguration(focus: .live(hideThreadedEvents: false),
                                           filter: .onlyMessage(types: types), internalIdPrefix: nil,
                                           dateDividerMode: .daily, trackReadReceipts: .messageLikeEvents,
                                           reportUtds: false)
        let timeline = try await room.timelineWithConfiguration(configuration: config)
        return SDKSharedCollectionsSource(timeline: timeline, mapperRoom: mapperRoom, section: section)
    }

    private init(timeline: Timeline, mapperRoom: ItemMapperRoom, section: SharedCollectionSection) {
        self.timeline = timeline
        self.section = section
        encrypted = mapperRoom.isEncrypted != false
        mapper = ItemMapper(room: mapperRoom)
        (updates, output) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (inputs, input) = AsyncStream.makeStream()
    }

    func start() async throws -> SharedCollectionSnapshot {
        guard !closed, let timeline else { throw SharedCollectionFailure.unavailable }
        if consumer == nil {
            let inputs = inputs
            consumer = Task { [weak self] in
                for await value in inputs {
                    guard let self, !self.closed else { return }
                    switch value {
                    case let .diffs(diffs): self.apply(diffs)
                    case let .checkpoint(id):
                        if let error = self.terminalFailure {
                            self.waiters.removeValue(forKey: id)?.resume(throwing: error)
                        } else { self.waiters.removeValue(forKey: id)?.resume(returning: self.snapshot) }
                    }
                }
            }
            let handle = await timeline.addListener(listener: SharedSDKListener(input: input))
            guard !closed else { handle.cancel(); throw SharedCollectionFailure.unavailable }
            listener = handle
        }
        if let terminalFailure { throw terminalFailure }
        if receivedInitial { return snapshot }
        // addListener supplies an initial diff, including an empty reset.
        return try await withCheckedThrowingContinuation { initialWaiters.append($0) }
    }

    func paginate(events: UInt16) async throws -> SharedCollectionSnapshot {
        guard !closed, let timeline else { throw SharedCollectionFailure.unavailable }
        if let terminalFailure { throw terminalFailure }
        guard !snapshot.capacityReached else { return snapshot }
        let generation = resetGeneration
        let reachedStart = try await timeline.paginateBackwards(numEvents: events)
        guard !closed else { throw SharedCollectionFailure.unavailable }
        // A FIFO marker drains callbacks already delivered by the SDK. The
        // seeded-room spike must verify delivery precedes pagination return.
        let id = UUID()
        _ = try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
            input.yield(.checkpoint(id))
        }
        guard !closed else { throw SharedCollectionFailure.unavailable }
        if let terminalFailure { throw terminalFailure }
        // Live diffs may have arrived while the checkpoint resumed. Always
        // publish the latest snapshot, never the older checkpoint's rows.
        snapshot.reachedStart = generation == resetGeneration && reachedStart
        snapshot.sequence &+= 1
        output.yield(snapshot)
        return snapshot
    }

    func close() {
        guard !closed else { return }
        closed = true
        listener?.cancel()
        listener = nil
        timeline = nil
        consumer?.cancel()
        consumer = nil
        input.finish()
        output.finish()
        for waiter in waiters.values { waiter.resume(throwing: CancellationError()) }
        waiters = [:]
        for waiter in initialWaiters { waiter.resume(throwing: CancellationError()) }
        initialWaiters = []
        snapshot = SharedCollectionSnapshot()
        projection = SharedCollectionsProjection()
    }

    private func apply(_ diffs: [TimelineDiff]) {
        guard terminalFailure == nil else { return }
        var content: [String: String] = [:]
        let resetting = diffs.contains(where: {
            switch $0 { case .reset, .clear: true; default: false }
        })
        if resetting { mapper.beginReset() }
        let mapped = diffs.map { diff in
            ChatDiff(diff) { item in
                let value = mapper.map(item).item
                content[value.id] = item.asEvent()?.lazyProvider.latestJson()
                return value
            }
        }
        mapper.finishBatch()
        do {
            snapshot.items = try projection.apply(mapped, contentJSON: content, section: section, encrypted: encrypted)
            snapshot.capacityReached = projection.capacityReached
            // A reset may replace fully loaded history with a shorter cache.
            if resetting { snapshot.reachedStart = false; resetGeneration &+= 1 }
            receivedInitial = true
            snapshot.sequence &+= 1
            output.yield(snapshot)
            for waiter in initialWaiters { waiter.resume(returning: snapshot) }
            initialWaiters = []
        } catch {
            terminalFailure = error as? SharedCollectionFailure ?? .unavailable
            snapshot.capacityReached = projection.capacityReached
            snapshot.failure = terminalFailure
            snapshot.sequence &+= 1
            output.yield(snapshot)
            for waiter in initialWaiters { waiter.resume(throwing: terminalFailure!) }
            initialWaiters = []
            listener?.cancel()
            listener = nil
        }
    }
}

private final class SharedSDKListener: TimelineListener {
    let input: AsyncStream<SharedSDKInput>.Continuation
    init(input: AsyncStream<SharedSDKInput>.Continuation) { self.input = input }
    func onUpdate(diff: [TimelineDiff]) { input.yield(.diffs(diff)) }
}
