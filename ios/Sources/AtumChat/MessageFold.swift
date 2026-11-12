import Foundation

/// Long messages fold (owner, 2026-11-11): a text bubble longer than
/// `foldsAfterLines` rendered lines shows its first `foldedLines` lines,
/// the last of them fading, and a full-width "Show more" at the bottom of
/// the bubble; open, it shows "Show less". Desktop has no such control; this
/// is a phone addition.
///
/// - The threshold has slack (20 lines fold to 12), so a fold always hides
///   at least eight lines: a message is never folded to save one line.
/// - A message still growing (the agent is still working after it) never
///   folds, and one the reader saw growing stays open once it is final: a
///   fold never shrinks a bubble under the reader. Only a message that is
///   final when it first shows starts folded.
/// - The reader's choice is kept per event for the app session
///   (`MessageFoldBook`), so scrolling, timeline diffs and reopening the chat
///   do not undo it.
/// - VoiceOver reads the whole text either way; the toggle is its own button.
public enum MessageFold {
    /// A text body longer than this many rendered lines folds.
    public static let foldsAfterLines = 20
    /// A folded body shows this many lines.
    public static let foldedLines = 12

    /// Whether a body `lines` rendered lines long is long enough to fold.
    public static func isLong(lines: Int) -> Bool {
        lines > foldsAfterLines
    }

    /// `height` points of text in lines of `lineHeight` points, rounded to
    /// the nearest line (rich text adds a little spacing between blocks).
    public static func lines(height: Double, lineHeight: Double) -> Int {
        guard lineHeight > 0, height > 0 else { return 0 }
        return Int((height / lineHeight).rounded())
    }

    /// The incoming messages that may still grow: those after my newest
    /// message while the sender still shows it is working after them (its
    /// typing row, or a live `io.atum.progress` line). Only text kinds fold,
    /// so only they are named.
    public static func growingIDs(in rows: [ChatRow]) -> Set<String> {
        var working = false
        var growing = Set<String>()
        for row in rows.reversed() {
            let item = row.item
            switch item.kind {
            case .typing:
                working = true
            case .message, .notice:
                if item.isProgressLine {
                    if item.progress?.phase != .settled { working = true }
                    continue
                }
                if item.isOwn { return growing }
                if working { growing.insert(row.id) }
            case .image, .file:
                if item.isOwn { return growing }
            default:
                continue
            }
        }
        return growing
    }
}

/// The fold state of every message the reader has met this session, by row
/// ID (the event ID for a remote event, kept through a local echo's
/// settling). Plain values; the app keeps one for the session.
public struct MessageFoldBook: Equatable, Sendable {
    /// The reader's own choices: true = open, false = folded.
    private var choices: [String: Bool] = [:]
    /// Messages first seen while they were still growing: they stay open.
    private var keptOpen: Set<String> = []

    public init() {}

    /// The rows still growing: each stays open from now on, unless the
    /// reader folds it.
    public mutating func sawGrowing(_ ids: some Sequence<String>) {
        for id in ids where choices[id] == nil { keptOpen.insert(id) }
    }

    /// Whether the message `id` shows folded now.
    public func isFolded(_ id: String, isLong: Bool, isGrowing: Bool) -> Bool {
        guard isLong, !isGrowing else { return false }
        if let open = choices[id] { return !open }
        return !keptOpen.contains(id)
    }

    /// Whether the message shows the Show more / Show less toggle: any long
    /// message once it is final, folded or not.
    public static func showsToggle(isLong: Bool, isGrowing: Bool) -> Bool {
        isLong && !isGrowing
    }

    /// The reader tapped the toggle on `id`, which showed `folded`.
    public mutating func toggle(_ id: String, wasFolded folded: Bool) {
        choices[id] = folded
    }
}
