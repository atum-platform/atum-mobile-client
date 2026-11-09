/// How a batch of diffs changed the buffer (plan §2.3 rule 5). Computed from
/// the diff operations on the buffer, never from the display rows.
/// FollowPolicy reads only this (through `FollowInput.from(_:)`); the view
/// never diffs arrays.
///
/// Each item a batch inserts is placed relative to the batch's *anchors*: the
/// items from before the batch that survive it, are event content and are not
/// local echoes. Raw SDK indices are not enough, for two reasons:
/// - matrix-sdk-ui keeps local echoes (pending, failed, or sent but not yet
///   replaced by their remote copy) at the bottom and inserts remote events
///   above them. While one of my messages shows a clock or a warning, every
///   incoming message is an `insert` in front of it, not a `pushBack`.
/// - the SDK's date-divider adjuster removes, moves and inserts dividers
///   inside the same batch as a back-pagination or a new-day message.
///
/// The rules:
/// - after the last anchor: added at the end, even with older local echoes
///   below it; before the first anchor: added at the start (older history);
///   between anchors: a middle insert. With no anchors at all (an empty
///   buffer, or only virtual items and my own echoes) everything is added at
///   the end.
/// - virtual items (`dayDivider`, `readMarker`, `timelineStart`) ride with
///   their side: at the start they add to the prepend, at the end they belong
///   to the append and are never counted, in the middle they change nothing.
///   Removing one changes nothing either.
/// - an item whose ID was already in the buffer before the batch is a move,
///   not a new message: the SDK re-places a local echo's remote copy with
///   `remove` + `insert` when the echo is not the last item, under the same
///   unique ID (the `ItemMapper` alias table keeps the display ID stable if
///   S0 shows otherwise, §2.3 rule 2). A move is structural and never counted.
/// - removing an event item that was there before the batch is structural.
/// - `set` never changes the kind.
///
/// While detached, the view keeps the top visible row in place for every
/// change (B4) with its measured geometry; `prependedAtStart` tells the
/// policy only that older history arrived and must not increment the pill.
public enum SnapshotChange: Equatable, Sendable {
    /// `reset` or `clear` somewhere in the batch: the whole list is new.
    case reset
    /// Only items added at the end (plus any in-place `set`s and neutral
    /// virtual-item changes). `count` is how many of them the jump pill counts
    /// (`ChatItem.countsAsNewMessage`); `localEcho` is true when one of them
    /// was sent from this device.
    case appendedAtEnd(count: Int, localEcho: Bool)
    /// Only items added before the old content (plus any `set`s): older
    /// history. `count` is the buffer items added there, dividers and the
    /// start item included.
    case prependedAtStart(count: Int)
    /// Only `set`s (edits, receipts, send-state changes), neutral virtual-item
    /// changes, or nothing.
    case inPlace
    /// Any other structural change: middle inserts, moves, removals of event
    /// items, or both ends at once. Rows above the viewport may have moved.
    /// Carries the end appends, so a new message is never lost from the pill
    /// count.
    case mixed(appendedAtEnd: Int, localEcho: Bool)
}

public enum TimelineReducerError: Error, Equatable, Sendable {
    /// The diff at `diffIndex` named an index the buffer does not have. The
    /// buffer is left as it was before the batch; the caller rebuilds the
    /// timeline (today's code does the same, `LiveMatrixSession` `apply`).
    case indexOutOfRange(diffIndex: Int)
}

/// The unfiltered buffer: one `ChatItem` per SDK `TimelineItem`, at the same
/// index (plan §2.3 rule 4). Every diff is applied verbatim, `truncate`,
/// `clear` and `reset` included. It never hides, drops or inserts anything,
/// so SDK indices stay valid; hiding and synthetic rows happen only in
/// `Projection`. There is no front cap (dropping items would break the index
/// alignment); closing the chat frees the buffer.
public struct TimelineBuffer: Equatable, Sendable {
    public private(set) var items: [ChatItem]

    public init(items: [ChatItem] = []) {
        self.items = items
    }

    /// Applies one SDK batch atomically and reports what kind of change it
    /// was. On an out-of-range index nothing is applied.
    @discardableResult
    public mutating func apply(_ diffs: [ChatDiff]) throws -> SnapshotChange {
        var working = items
        // Parallel to `working`: true for an item this batch inserted. A `set`
        // keeps the flag, so an edited old item stays old.
        var inserted = [Bool](repeating: false, count: items.count)
        var sawReset = false
        var removedOldEvent = false

        func insert(_ item: ChatItem, at index: Int) {
            working.insert(item, at: index)
            inserted.insert(true, at: index)
        }

        func remove(at index: Int) {
            if !inserted[index], working[index].kind.isEventContent { removedOldEvent = true }
            working.remove(at: index)
            inserted.remove(at: index)
        }

        for (offset, diff) in diffs.enumerated() {
            switch diff {
            case let .append(values):
                working.append(contentsOf: values)
                inserted.append(contentsOf: repeatElement(true, count: values.count))
            case .clear:
                working.removeAll()
                inserted.removeAll()
                sawReset = true
            case let .pushFront(value):
                insert(value, at: 0)
            case let .pushBack(value):
                insert(value, at: working.count)
            case .popFront:
                guard !working.isEmpty else { throw TimelineReducerError.indexOutOfRange(diffIndex: offset) }
                remove(at: 0)
            case .popBack:
                guard !working.isEmpty else { throw TimelineReducerError.indexOutOfRange(diffIndex: offset) }
                remove(at: working.count - 1)
            case let .insert(index, value):
                guard index >= 0, index <= working.count else {
                    throw TimelineReducerError.indexOutOfRange(diffIndex: offset)
                }
                insert(value, at: index)
            case let .set(index, value):
                guard index >= 0, index < working.count else {
                    throw TimelineReducerError.indexOutOfRange(diffIndex: offset)
                }
                working[index] = value
            case let .remove(index):
                guard index >= 0, index < working.count else {
                    throw TimelineReducerError.indexOutOfRange(diffIndex: offset)
                }
                remove(at: index)
            case let .truncate(length):
                guard length >= 0, length <= working.count else {
                    throw TimelineReducerError.indexOutOfRange(diffIndex: offset)
                }
                while working.count > length { remove(at: working.count - 1) }
            case let .reset(values):
                working = values
                inserted = [Bool](repeating: true, count: values.count)
                sawReset = true
            }
        }

        let previous = items
        items = working
        if sawReset { return .reset }
        return Self.classify(working, inserted: inserted, previous: previous, removedOldEvent: removedOldEvent)
    }

    /// The anchor rules of `SnapshotChange`, on the buffer after the batch.
    private static func classify(_ items: [ChatItem], inserted: [Bool], previous: [ChatItem],
                                 removedOldEvent: Bool) -> SnapshotChange {
        guard inserted.contains(true) else {
            return removedOldEvent ? .mixed(appendedAtEnd: 0, localEcho: false) : .inPlace
        }
        var firstAnchor: Int?
        var lastAnchor: Int?
        for index in items.indices where !inserted[index] {
            let item = items[index]
            guard item.kind.isEventContent, !item.isLocalEcho else { continue }
            if firstAnchor == nil { firstAnchor = index }
            lastAnchor = index
        }
        let previousIDs = Set(previous.lazy.map(\.id))

        enum Side { case start, middle, end }
        var structural = removedOldEvent
        var addedAtEnd = false
        var counted = 0
        var localEcho = false
        var prepended = 0
        for index in items.indices where inserted[index] {
            let item = items[index]
            let side: Side
            if let firstAnchor, let lastAnchor {
                side = index < firstAnchor ? .start : (index > lastAnchor ? .end : .middle)
            } else {
                side = .end
            }
            if item.kind.isVirtual {
                switch side {
                case .start: prepended += 1
                case .end: addedAtEnd = true
                case .middle: break
                }
                continue
            }
            if previousIDs.contains(item.id) {
                structural = true // moved, not new
                continue
            }
            switch side {
            case .start:
                prepended += 1
            case .middle:
                structural = true
            case .end:
                addedAtEnd = true
                if item.countsAsNewMessage { counted += 1 }
                if item.isLocalEcho { localEcho = true }
            }
        }

        switch (addedAtEnd, prepended > 0, structural) {
        case (false, false, false): return .inPlace
        case (true, false, false): return .appendedAtEnd(count: counted, localEcho: localEcho)
        case (false, true, false): return .prependedAtStart(count: prepended)
        default: return .mixed(appendedAtEnd: counted, localEcho: localEcho)
        }
    }
}
