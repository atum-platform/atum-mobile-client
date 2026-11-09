import Foundation

/// Where a bubble sits in its sender run (B16): it picks the corner shape and
/// the spacing above it. Runs are a layout fact, so they are computed on the
/// display rows, after the projection has hidden what it hides.
public enum RunPosition: Equatable, Hashable, Sendable {
    /// The only bubble of its run.
    case single
    case first
    case middle
    case last

    /// The sender line (in rooms that show one) sits above the first bubble.
    public var startsRun: Bool { self == .single || self == .first }
    /// Normal spacing follows the last bubble; inside a run it is tighter.
    /// In a group, the sender's face sits beside this bubble (owner,
    /// 2026-11-05).
    public var endsRun: Bool { self == .single || self == .last }
}

/// What grouping decided about one display row (B16).
public struct RowGrouping: Equatable, Hashable, Sendable {
    /// The row's place in its run. Nil for rows that are not bubbles: notices,
    /// virtual rows (day divider, read marker, start header) and the typing
    /// and loading rows.
    public var position: RunPosition?
    /// The sender's name above this row: only at the start of a run, never
    /// on my own messages, and only in rooms whose kind shows sender lines
    /// (`RoomKind.showsSenderLine`).
    public var showsSender: Bool
    /// The sender's face beside this row, aligned to the bubble's bottom:
    /// only on the last bubble of a run, never on my own messages, and only
    /// in rooms whose kind shows faces (`RoomKind.showsSenderFace`: groups).
    /// The other bubbles of the run keep an empty face-wide gutter, so the
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
    public var showsFace: Bool
    /// A centred time label above this row: the gap since the previous event
    /// row is 60 minutes or more and no day divider already sits between them
    /// (the divider wins). Nil otherwise.
    public var timeLabel: Date?

    public init(position: RunPosition? = nil, showsSender: Bool = false, showsFace: Bool = false,
                timeLabel: Date? = nil) {
        self.position = position
        self.showsSender = showsSender
        self.showsFace = showsFace
        self.timeLabel = timeLabel
    }

    public static let none = RowGrouping()
}

/// Sender runs, sender lines, sender faces and time labels (B16), on plain
/// values.
///
/// The Matrix SDK's timeline gives each event its sender, `isOwn`, the
/// sender's profile and a timestamp, and inserts the day dividers, the read
/// marker and the timeline start as virtual items (`SDKTimelineSource`,
/// `dateDividerMode: .daily`). It says nothing about runs: no first or last
/// in a group. Runs are derived here, on the display rows.
///
/// - A run is consecutive bubbles from one sender, with no visible divider
///   between them (day divider, read marker, start header), on the same
///   calendar day, each within 5 minutes of the previous one (desktop
///   `MESSAGE_RUN_MS`). My own messages form runs too, whichever device sent
///   them: the Mac and the phone are the same sender.
/// - Notices are quiet centred lines, not bubbles: they are not in a run and,
///   as in S0, they do not break one either (a working line between two
///   answers does not repeat the agent's name).
/// - The time label compares each event row with the previous event row,
///   notices included, whoever sent them.
/// - In a group, the sender's name opens a run and the sender's face closes
///   it (beside the last bubble, as in Messages and WhatsApp). A 1:1 chat
// Preserve user-visible identity, state and recovery behavior across connection changes.
public enum Grouping {
    /// Desktop `MESSAGE_RUN_MS`: the most time between two bubbles of a run.
    public static let runGap: TimeInterval = 5 * 60
    /// A gap this long or longer gets a centred time label.
    public static let timeLabelGap: TimeInterval = 60 * 60

    /// One `RowGrouping` per row, aligned with `rows`.
    public static func layout(_ rows: [ChatRow], context: RoomContext,
                              calendar: Calendar = .current) -> [RowGrouping] {
        var result = [RowGrouping](repeating: .none, count: rows.count)

        // Runs: walk the bubbles; a visible divider or synthetic row breaks.
        var runStart: Int?
        var previousBubble: Int?
        func closeRun(endingAt last: Int?) {
            guard let start = runStart, let last else { return }
            if start == last {
                result[start].position = .single
            } else {
                result[start].position = .first
                result[last].position = .last
                for index in rows.indices where index > start && index < last && result[index].position != nil {
                    result[index].position = .middle
                }
            }
        }
        for (index, row) in rows.enumerated() {
            let item = row.item
            if isBubble(item.kind) {
                if let previous = previousBubble, runStart != nil,
                   continuesRun(rows[previous].item, item, calendar: calendar) {
                    result[index].position = .middle // provisional, fixed in closeRun
                } else {
                    closeRun(endingAt: previousBubble)
                    runStart = index
                    result[index].position = .middle
                }
                previousBubble = index
            } else if item.kind == .notice {
                continue // neither in a run nor a break
            } else {
                // Day divider, read marker, start header, typing, loading.
                closeRun(endingAt: previousBubble)
                runStart = nil
                previousBubble = nil
            }
        }
        closeRun(endingAt: previousBubble)

        // Sender lines: the start of a run, someone else's, in a room that
        // shows them.
        if context.kind.showsSenderLine {
            for (index, row) in rows.enumerated() where !row.item.isOwn {
                if result[index].position?.startsRun == true { result[index].showsSender = true }
            }
        }

        // Faces: the end of a run, someone else's, in a room that shows them.
        if context.kind.showsSenderFace {
            for (index, row) in rows.enumerated() where !row.item.isOwn {
                if result[index].position?.endsRun == true { result[index].showsFace = true }
            }
        }

        // Time labels: a 60-minute gap since the previous event row, unless a
        // day divider sits between them.
        var previousEvent: ChatItem?
        var dividerSincePrevious = false
        for (index, row) in rows.enumerated() {
            let item = row.item
            if case .dayDivider = item.kind {
                dividerSincePrevious = true
                continue
            }
            guard item.kind.isEventContent, item.kind != .roomState,
                  !item.isProgressLine else { continue }
            if let previousEvent, !dividerSincePrevious,
               item.timestamp.timeIntervalSince(previousEvent.timestamp) >= timeLabelGap {
                result[index].timeLabel = item.timestamp
            }
            previousEvent = item
            dividerSincePrevious = false
        }
        return result
    }

    /// The rows with their run layout set (`ChatRow.grouping`). With
    /// `groupsRuns` the sender line follows the layout too (S1: only at the
    /// start of a run); without, each row keeps the sender line it has.
    /// Used by the projection, and by the store's core whenever it composes
    /// rows the projection did not lay out (held sends, a renewal handover).
    public static func apply(to rows: [ChatRow], context: RoomContext, groupsRuns: Bool,
                             calendar: Calendar = .current) -> [ChatRow] {
        let layout = layout(rows, context: context, calendar: calendar)
        var rows = rows
        for index in rows.indices {
            rows[index].grouping = layout[index]
            if groupsRuns { rows[index].showsSender = layout[index].showsSender }
        }
        return rows
    }

    /// Whether `next` continues the run that `previous` (the bubble before it)
    /// belongs to: same sender, same calendar day, at most 5 minutes later.
    /// A clock that runs backwards (a local echo next to server times) never
    /// splits a run.
    public static func continuesRun(_ previous: ChatItem, _ next: ChatItem,
                                    calendar: Calendar = .current) -> Bool {
        guard previous.sender == next.sender, !next.sender.isEmpty else { return false }
        guard calendar.isDate(previous.timestamp, inSameDayAs: next.timestamp) else { return false }
        return next.timestamp.timeIntervalSince(previous.timestamp) <= runGap
    }

    /// Rows drawn as bubbles (or bare answers) that take part in runs.
    public static func isBubble(_ kind: ChatItem.Kind) -> Bool {
        switch kind {
        case .message, .image, .file, .placeholder: true
        default: false
        }
    }
}
