import Foundation

/// Which SDK virtual items the projection shows and which S1 rules it runs.
/// S1a hides all three virtual items (§2.3 rule 4); S1 shows day dividers
/// (B14), the read marker (B15) and the start header (B5), and adds the S1
/// rules below. The S1 fields default to off, so an S1a call is unchanged.
public struct ProjectionOptions: Equatable, Sendable {
    public var showsDayDividers: Bool
    public var showsReadMarker: Bool
    public var showsTimelineStart: Bool
    /// B7 in S1: "Đã gửi" and "Đã xem" on my newest settled message
    /// (`Delivery.marks(for:context:)`). Off: the S1a clock and warning only.
    public var marksSentAndSeen: Bool
    /// B16 in S1: the sender line only at the start of a run (5-minute gap,
    /// day boundary, divider; `Grouping`). Off: the S1a rule, a sender line
    /// wherever the sender changes.
    public var groupsRuns: Bool
    /// B10: the no-answer line after this many seconds; nil turns it off.
    /// The projection needs `now` for it.
    public var noAnswerAfter: TimeInterval?

    public init(showsDayDividers: Bool, showsReadMarker: Bool, showsTimelineStart: Bool,
                marksSentAndSeen: Bool = false, groupsRuns: Bool = false,
                noAnswerAfter: TimeInterval? = nil) {
        self.showsDayDividers = showsDayDividers
        self.showsReadMarker = showsReadMarker
        self.showsTimelineStart = showsTimelineStart
        self.marksSentAndSeen = marksSentAndSeen
        self.groupsRuns = groupsRuns
        self.noAnswerAfter = noAnswerAfter
    }

    /// The demo build: no virtual items at all.
    public static let s1a = ProjectionOptions(showsDayDividers: false, showsReadMarker: false,
                                              showsTimelineStart: false)

    /// The first build (S1): every virtual item, Sent and Seen, runs, and the
    /// 2-minute no-answer line in assistant rooms.
    public static let s1 = ProjectionOptions(showsDayDividers: true, showsReadMarker: true,
                                             showsTimelineStart: true, marksSentAndSeen: true,
                                             groupsRuns: true, noAnswerAfter: Delivery.noAnswerAfter)
}

/// One display row: a buffer item (or a synthetic row) plus what the
/// projection decided about it. `Equatable`, so SwiftUI skips unchanged rows.
public struct ChatRow: Identifiable, Equatable, Hashable, Sendable {
    public var item: ChatItem
    /// B16: the sender's name above this row. The view reads this flag: with
    /// `ProjectionOptions.groupsRuns` (S1) it is `grouping.showsSender`, at
    /// the start of a run; without, wherever the sender changes (S1a).
    public var showsSender: Bool
    /// B21: whether this row draws a quote of what it replies to, judged
    /// after hiding (desktop's rule). The quote view reads it.
    public var showsQuote: Bool
    public var delivery: DeliveryMark
    /// The newest event row (accessibility ID `row.latest`).
    public var isLatest: Bool
    /// B10: the quiet no-answer line (copy key `phone.noAnswer`) under my
    /// newest message in my assistant's chat after two minutes with no
    /// answer, while no one is typing. A flag of its own, not a
    /// `DeliveryMark`, because it shows together with that message's
    /// "Đã gửi" or "Đã xem".
    public var showsNoAnswer: Bool
    /// B16: run position (corner shape, spacing), the run time and the edit
    /// mark under this row (TL-4, TL-5). `.none` for rows that
    /// are not bubbles and for a projection that has not laid out runs.
    public var grouping: RowGrouping
    /// B21: what the quote view draws, for a row that replies to an event
    /// (contract amendment, S1 day 1). Nil when the row replies to nothing
    /// or the source has no details yet.
    public var replyDetails: ChatReplyDetails?
    /// §9.1 Seen: who read this message of mine, in receipt order, with the
    /// profile their messages carry (`Delivery.readers`). Set with a `.seen`
    /// mark; empty otherwise.
    public var readers: [ChatReader]

    public init(item: ChatItem, showsSender: Bool = false, showsQuote: Bool = false,
                delivery: DeliveryMark = .none, isLatest: Bool = false, showsNoAnswer: Bool = false,
                grouping: RowGrouping = .none, replyDetails: ChatReplyDetails? = nil,
                readers: [ChatReader] = []) {
        self.item = item
        self.showsSender = showsSender
        self.showsQuote = showsQuote
        self.delivery = delivery
        self.isLatest = isLatest
        self.showsNoAnswer = showsNoAnswer
        self.grouping = grouping
        self.replyDetails = replyDetails
        self.readers = readers
    }

    public var id: String { item.id }

    public var accessibilityID: String { AccessibilityID.row(self) }
}

/// What the store publishes to the view in one step (plan §2.3 data flow).
/// `generation` lets the main actor drop a snapshot that a newer timeline
/// (a reopen or a renewed session) has already replaced.
public struct Snapshot: Equatable, Sendable {
    public var rows: [ChatRow]
    public var change: SnapshotChange
    public var generation: UInt64

    public init(rows: [ChatRow], change: SnapshotChange, generation: UInt64) {
        self.rows = rows
        self.change = change
        self.generation = generation
    }

    public static let empty = Snapshot(rows: [], change: .reset, generation: 0)
}

/// Buffer → display rows (plan §2.3 rule 4). A full pass over plain values:
/// cheap at these sizes and simpler than tracking touched indices.
public enum Projection {
    /// IDs of the synthetic rows. They cannot collide with SDK unique IDs,
    /// which never carry the `atum.` prefix.
    public static let typingRowID = "atum.typing"
    public static let loadingEarlierRowID = "atum.loading-earlier"

    public static func snapshot(buffer: TimelineBuffer, change: SnapshotChange, generation: UInt64,
                                context: RoomContext, typingNames: [String] = [],
                                isLoadingEarlier: Bool = false,
                                replyDetails: [String: ChatReplyDetails] = [:],
                                options: ProjectionOptions = .s1a, now: Date? = nil,
                                calendar: Calendar = .current) -> Snapshot {
        Snapshot(rows: rows(buffer.items, context: context, typingNames: typingNames,
                            isLoadingEarlier: isLoadingEarlier, replyDetails: replyDetails,
                            options: options, now: now, calendar: calendar),
                 change: change, generation: generation)
    }

    /// - Hidden: transient working-line events; a day divider whose day has
    ///   no visible event row (B14); the read marker when it would be the
    ///   last row (B15); virtual items `options` turns off; room-state
    ///   events, always; a second item with an ID already shown.
    /// - Added: the loading row (first) and one assistant working footer
    ///   (last), carrying the live line when present or the typing atom alone.
    /// - Per row: the sender line (B16: on a sender change in S1a, at the
    ///   start of a run with `groupsRuns`), the quote flag judged after hiding
    ///   (B21), the delivery mark (B7: S1a, or Sent and Seen with
    ///   `marksSentAndSeen`), the no-answer flag (B10, with `noAnswerAfter`
    ///   and `now`), the run layout (B16, `ChatRow.grouping`, always) and the
    ///   quote details (B21, `ChatRow.replyDetails`, from `replyDetails` by
    ///   item ID).
    /// `typingNames` are display names already filtered by `TypingNames`
    /// (my own user dropped) and split by `TypingNames.presentation`
    /// (people rooms pass none); they are shown as given.
    public static func rows(_ items: [ChatItem], context: RoomContext, typingNames: [String] = [],
                            isLoadingEarlier: Bool = false,
                            replyDetails: [String: ChatReplyDetails] = [:],
                            options: ProjectionOptions = .s1a, now: Date? = nil,
                            calendar: Calendar = .current) -> [ChatRow] {
        // agent-turns/1.4 A7: an agent's working line lives only while its
        // turn works, and a redacted agent message shows nothing. Both rules
        // run before answer detection, so a hidden line never is the newest
        // thing the agent said.
        let shownItems = TransientLines.visibleItems(items, agents: context.transientAgentUserIDs)
        let working = context.kind == .assistant
            ? TransientLines.workingLine(shownItems, agents: context.transientAgentUserIDs,
                                         sender: context.workingLineSenderID)
            : nil
        var visible = shownItems.filter { item in
            // Every transient event leaves the transcript, including older live
            // lines from legacy publishers. Only the selected line feeds the footer.
            guard !TransientLines.isTransientLine(item, agents: context.transientAgentUserIDs) else { return false }
            switch item.kind {
            case .dayDivider: return options.showsDayDividers
            case .readMarker: return options.showsReadMarker
            case .timelineStart: return options.showsTimelineStart
            case .typing, .loadingEarlier: return false // never in the buffer
            case .roomState: return false
            case .notice: return true
            case .message, .image, .file, .placeholder: return true
            }
        }
        // Two items can share a display ID for a moment (an echo and its
        // remote copy, or two dividers of one day while the SDK moves them;
        // `DisplayIdentityTable`): the first stays, so a view never sees one
        // ID twice.
        var seenIDs = Set<String>()
        visible = visible.filter { seenIDs.insert($0.id).inserted }
        // B14: a day whose rows are all hidden (room creation, name, power
        // levels, encryption) shows no divider of its own.
        if options.showsDayDividers { visible = dropEmptyDays(visible) }
        // B15: a read marker with nothing after it is noise.
        if case .readMarker? = visible.last?.kind { visible.removeLast() }

        let latestIndex = visible.lastIndex(where: { $0.kind.isEventContent })
        // B7 and B10 read the whole buffer: receipts on hidden rows count.
        let marks = options.marksSentAndSeen ? Delivery.marks(for: items, context: context) : nil
        // B10: a real typing signal is the room saying an answer is coming;
        // the quiet line waits until it ends, never sits beside the dots.
        let noAnswerID: String? = if typingNames.isEmpty, let after = options.noAnswerAfter, let now {
            Delivery.noAnswerItemID(items, context: context, now: now, after: after)
        } else {
            nil
        }
        var rows: [ChatRow] = []
        rows.reserveCapacity(visible.count + 2)
        if isLoadingEarlier {
            rows.append(ChatRow(item: ChatItem(id: loadingEarlierRowID, kind: .loadingEarlier)))
        }
        // The sender line restarts after a day divider; quotes look at the
        // previous event row and ignore virtual rows, as desktop's entries do.
        var previousForSender: ChatItem?
        var previousForQuote: ChatItem?
        // Built on the first Seen row only, then shared by every other one.
        var profileIndex: [String: ChatReader]?
        func senderProfileIndex() -> [String: ChatReader] {
            if let profileIndex { return profileIndex }
            let index = Delivery.senderProfiles(items)
            profileIndex = index
            return index
        }
        for (index, item) in visible.enumerated() {
            guard item.kind.isEventContent else {
                if case .dayDivider = item.kind { previousForSender = nil }
                rows.append(ChatRow(item: item))
                continue
            }
            var showsSender = false
            if item.kind != .notice {
                showsSender = context.kind.showsSenderLine && !item.isOwn
                    && previousForSender?.sender != item.sender
                previousForSender = item
            }
            let delivery = marks.map { $0[item.id] ?? .none } ?? Delivery.mark(for: item)
            let readers: [ChatReader] = if case .seen = delivery {
                Delivery.readers(of: item, profiles: senderProfileIndex(), context: context)
            } else {
                []
            }
            rows.append(ChatRow(item: item, showsSender: showsSender,
                                showsQuote: showsQuote(item, previous: previousForQuote, context: context),
                                delivery: delivery,
                                isLatest: index == latestIndex,
                                showsNoAnswer: item.id == noAnswerID,
                                replyDetails: item.replyTo == nil ? nil : replyDetails[item.id],
                                readers: readers))
            previousForQuote = item
        }
        // Desktop's loadingIndicator: one stable synthetic row, never the
        // progress event itself (no quote, delivery, timestamp or edited mark).
        if context.kind == .assistant, working != nil || !typingNames.isEmpty {
            rows.append(ChatRow(item: ChatItem(id: typingRowID, kind: .typing(names: typingNames),
                                               body: working?.body ?? "")))
        }
        return Grouping.apply(to: rows, context: context, groupsRuns: options.groupsRuns, calendar: calendar)
    }

    /// B21, desktop's rule (`D194: apps/desktop/src/matrix/app.tsx:498-505`):
    /// a reply shows its quote unless it sits directly under the event it
    /// answers and comes from the room's agent or bot (or carries a result).
    /// Thread messages always quote. Deleted and undecryptable rows never do.
    static func showsQuote(_ item: ChatItem, previous: ChatItem?, context: RoomContext) -> Bool {
        guard let replyTo = item.replyTo else { return false }
        switch item.kind {
        case .placeholder(.redacted), .placeholder(.undecryptable), .placeholder(.undecryptableOldHistory):
            return false
        default:
            break
        }
        let consecutiveReply = previous?.eventID == replyTo
        let fromAgent = !item.isOwn && context.agentUserIDs.contains(item.sender)
        return !consecutiveReply || item.threadRoot != nil || (!fromAgent && item.resultFor == nil)
    }

    /// Drops each day divider with no event row before the next divider or
    /// the end. Read markers and the start item do not make a day visible.
    private static func dropEmptyDays(_ items: [ChatItem]) -> [ChatItem] {
        var keep = [Bool](repeating: true, count: items.count)
        var dayHasEvent = false
        for index in items.indices.reversed() {
            if case .dayDivider = items[index].kind {
                keep[index] = dayHasEvent
                dayHasEvent = false
            } else if items[index].kind.isEventContent {
                dayHasEvent = true
            }
        }
        return items.indices.filter { keep[$0] }.map { items[$0] }
    }
}

/// What one projection pass publishes (plan §2.3 data flow): the snapshot
/// (run layout and quote details are on its rows) and when to project again.
public struct ProjectedTimeline: Equatable, Sendable {
    public var snapshot: Snapshot
    /// When the no-answer flag (B10) next changes on its own. The store
    /// re-projects at that time; nil when nothing is waiting.
    public var nextNoAnswerChange: Date?
    /// Grows with every pass of one projector, so the main actor can drop a
    /// pass that arrives after a newer one.
    public var sequence: UInt64
    /// The items the source sent a new value for in this pass (inserted or
    /// set by its batch, `ChatDiff.carriedItems`), even when the value equals
    /// the old one. Empty for passes no batch caused (typing, the loading
    /// row, the clock). The core reads it as "the source's next state" for a
    /// send it shows as retrying (U5, coordinator decision 9).
    public var touchedItemIDs: Set<String>

    public init(snapshot: Snapshot, nextNoAnswerChange: Date?, sequence: UInt64,
                touchedItemIDs: Set<String> = []) {
        self.snapshot = snapshot
        self.nextNoAnswerChange = nextNoAnswerChange
        self.sequence = sequence
        self.touchedItemIDs = touchedItemIDs
    }
}

/// The projector of one open timeline (plan §2.3): the buffer, the inputs
/// that are not diffs, and the generation of the timeline it belongs to.
/// One per `TimelineController`, owned by its projector task off the main
/// actor. It applies every batch verbatim and re-projects after a non-diff
/// input changes (typing names, the loading row, the clock).
public struct TimelineProjector: Sendable {
    public private(set) var buffer = TimelineBuffer()
    public let generation: UInt64
    public var context: RoomContext
    public var options: ProjectionOptions
    public var calendar: Calendar
    public var typingNames: [String] = []
    public var isLoadingEarlier = false
    /// B21 quote details by item ID, from the source's batches
    /// (`ChatTimelineBatch.replyDetails`).
    public var replyDetails = [String: ChatReplyDetails]()
    public private(set) var sequence: UInt64 = 0

    public init(generation: UInt64, context: RoomContext, options: ProjectionOptions = .s1,
                calendar: Calendar = .current) {
        self.generation = generation
        self.context = context
        self.options = options
        self.calendar = calendar
    }

    /// Applies one SDK batch. On an out-of-range index the buffer is left as
    /// it was and the error is thrown: the caller rebuilds the timeline.
    public mutating func apply(_ diffs: [ChatDiff], now: Date) throws -> ProjectedTimeline {
        let change = try buffer.apply(diffs)
        var projected = project(change: change, now: now)
        projected.touchedItemIDs = Set(diffs.lazy.flatMap(\.carriedItems).map(\.id))
        return projected
    }

    /// One pass over the current buffer. `change` describes what the buffer
    /// did since the last pass (`.inPlace` for typing, loading and the clock).
    public mutating func project(change: SnapshotChange = .inPlace, now: Date) -> ProjectedTimeline {
        sequence &+= 1
        let rows = Projection.rows(buffer.items, context: context, typingNames: typingNames,
                                   isLoadingEarlier: isLoadingEarlier, replyDetails: replyDetails,
                                   options: options, now: now, calendar: calendar)
        let deadline: Date? = if typingNames.isEmpty, let after = options.noAnswerAfter {
            Delivery.noAnswerDeadline(buffer.items, context: context, now: now, after: after)
        } else {
            nil
        }
        return ProjectedTimeline(snapshot: Snapshot(rows: rows, change: change, generation: generation),
                                 nextNoAnswerChange: deadline, sequence: sequence)
    }
}
