import Foundation
import Observation

public enum SharedCollectionFailure: Error, Equatable, Sendable {
    case unavailable, capacity, sizeUnavailable, tooLarge, invalidMedia
}

public struct SharedCollectionSnapshot: Equatable, Sendable {
    public var items: [SharedCollectionItem]
    public var sequence: UInt64
    public var reachedStart: Bool
    public var failure: SharedCollectionFailure?
    /// True when our retained window is full. History remains incomplete.
    public var capacityReached: Bool
    public init(items: [SharedCollectionItem] = [], reachedStart: Bool = false, capacityReached: Bool = false, failure: SharedCollectionFailure? = nil, sequence: UInt64 = 0) {
        self.items = items
        self.sequence = sequence
        self.failure = failure
        self.reachedStart = reachedStart
        self.capacityReached = capacityReached
    }
}

/// One section, one SDK timeline/cursor, on the existing account's client.
/// paginate must return after its preceding diff publications have applied.
@MainActor
public protocol SharedCollectionSource: AnyObject {
    var updates: AsyncStream<SharedCollectionSnapshot> { get }
    func start() async throws -> SharedCollectionSnapshot
    func paginate(events: UInt16) async throws -> SharedCollectionSnapshot
    func close()
}

/// Diff projection used by the SDK adapter and synthetic tests. The index
/// buffer retains only identities; content/keys are discarded after mapping.
/// Never truncate an SDK-indexed list: stop the reader at its explicit cap.
public struct SharedCollectionsProjection: Sendable {
    private var buffer = TimelineBuffer()
    private var rows: [String: [SharedCollectionItem]] = [:]
    public private(set) var capacityReached = false
    public init() {}

    public mutating func apply(_ diffs: [ChatDiff], contentJSON: [String: String],
                               section: SharedCollectionSection, encrypted: Bool) throws -> [SharedCollectionItem] {
        var nextRows = rows
        func compact(_ item: ChatItem) -> ChatItem {
            nextRows[item.id] = SharedCollectionsPolicy.items(section: section, item: item,
                                                              latestContentJSON: contentJSON[item.id], encrypted: encrypted)
            return ChatItem(id: item.id, kind: .roomState)
        }
        let compactDiffs: [ChatDiff] = diffs.map { diff in
            switch diff {
            case let .append(items): .append(items.map(compact))
            case let .reset(items): .reset(items.map(compact))
            case let .pushFront(item): .pushFront(compact(item))
            case let .pushBack(item): .pushBack(compact(item))
            case let .insert(index, item): .insert(index: index, item: compact(item))
            case let .set(index, item): .set(index: index, item: compact(item))
            case .clear, .popFront, .popBack, .remove, .truncate: diff
            }
        }
        var candidate = buffer
        try candidate.apply(compactDiffs)
        guard candidate.items.count <= SharedCollectionsPolicy.maximumTimelineEntries else {
            capacityReached = true
            throw SharedCollectionFailure.capacity
        }
        let live = Set(candidate.items.map(\.id))
        nextRows = nextRows.filter { live.contains($0.key) }
        buffer = candidate
        rows = nextRows
        let ordered = SharedCollectionsPolicy.newestFirst(buffer.items.map { rows[$0.id] ?? [] })
        capacityReached = ordered.count >= SharedCollectionsPolicy.maximumRetainedItems
        return Array(ordered.prefix(SharedCollectionsPolicy.maximumRetainedItems))
    }
}

/// UI-independent observable state. Empty is authoritative only after the
/// room start; a zero-item bounded read with older history is partial.
@available(macOS 14.0, *)
@MainActor @Observable
public final class SharedCollectionsModel {
    public enum State: Equatable, Sendable { case loading, partial, empty, ready, failed, offline }
    public let section: SharedCollectionSection
    public private(set) var state: State = .loading
    public private(set) var items: [SharedCollectionItem] = []
    public private(set) var isReading = false
    public private(set) var reachedStart = false
    public private(set) var capacityReached = false
    public private(set) var failure: SharedCollectionFailure?
    public private(set) var requiresReopen = false
    public private(set) var revision: UInt64 = 0
    /// Intentionally absent: onlyMessage timelines do not reliably retain UTDs.
    public var unreadableCount: Int? { nil }
    public var canLoadMore: Bool {
        !closed && (items.count < snapshot.items.count
            || (!capacityReached && !reachedStart && !requiresReopen && state != .offline))
    }
    public var previewItems: [SharedCollectionItem] { Array(items.prefix(section.previewCount)) }

    @ObservationIgnored private let source: any SharedCollectionSource
    @ObservationIgnored private var snapshot = SharedCollectionSnapshot()
    @ObservationIgnored private var target: Int
    @ObservationIgnored private var offline = false
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var epoch: UInt64 = 0

    public init(section: SharedCollectionSection, source: any SharedCollectionSource) {
        self.section = section
        self.source = source
        target = section.previewCount
    }

    /// Membership in the retained window, including cached rows beyond the
    /// current visible page. An open viewer remains valid when new rows arrive.
    public func contains(_ item: SharedCollectionItem) -> Bool { !closed && snapshot.items.contains(item) }

    public func loadPreview() async { await read() }
    public func seeAll() async {
        target = max(target, SharedCollectionsPolicy.pageItems)
        await read()
    }
    public func loadMore() async {
        guard !isReading, canLoadMore else { return }
        target = min(SharedCollectionsPolicy.maximumRetainedItems, target + SharedCollectionsPolicy.pageItems)
        await read()
    }
    public func retry() async { await read() }

    /// Feed from SessionLifecycle's connection state. Cached rows remain
    /// visible, including when no rows are cached. Recovery is explicit retry.
    public func setOffline(_ value: Bool) {
        offline = value
        publish()
    }

    public func close() {
        guard !closed else { return }
        closed = true
        epoch &+= 1
        consumer?.cancel()
        consumer = nil
        source.close()
        snapshot = SharedCollectionSnapshot()
        items = []
        reachedStart = false
        capacityReached = false
        isReading = false
        failure = nil
        requiresReopen = false
        state = .loading
    }

    private func read() async {
        guard !closed, !isReading else { return }
        let readEpoch = epoch
        isReading = true
        failure = snapshot.failure
        state = offline ? .offline : .loading
        defer { if epoch == readEpoch { isReading = false; publish() } }
        do {
            if !started {
                let updates = source.updates
                consumer = Task { [weak self] in
                    for await value in updates {
                        guard let self, !self.closed else { return }
                        self.accept(value)
                    }
                }
                let initial = try await source.start()
                guard !closed, epoch == readEpoch else { return }
                started = true
                accept(initial)
            }
            for _ in 0..<SharedCollectionsPolicy.maximumPagesPerRead {
                try Task.checkCancellation()
                guard !offline, !requiresReopen, !snapshot.reachedStart, !snapshot.capacityReached,
                      snapshot.items.count < target else { break }
                let value = try await source.paginate(events: SharedCollectionsPolicy.pageEvents)
                guard !closed, epoch == readEpoch else { return }
                accept(value)
            }
        } catch is CancellationError {
            // Cancellation preserves a truthful partial cached subset.
        } catch {
            guard !closed, epoch == readEpoch else { return }
            failure = error as? SharedCollectionFailure ?? .unavailable
        }
    }

    private func accept(_ value: SharedCollectionSnapshot) {
        guard !closed, value.sequence >= snapshot.sequence else { return }
        if value.items != snapshot.items { revision &+= 1 }
        snapshot = value
        requiresReopen = value.failure != nil
        if let error = value.failure { failure = error }
        publish()
    }
    private func publish() {
        guard !closed else { return }
        items = Array(snapshot.items.prefix(target))
        reachedStart = snapshot.reachedStart
        capacityReached = snapshot.capacityReached
        if offline { state = .offline }
        else if failure != nil { state = .failed }
        else if isReading { state = .loading }
        else if !started { state = .loading }
        else if !reachedStart || capacityReached { state = .partial }
        else { state = items.isEmpty ? .empty : .ready }
    }
}
