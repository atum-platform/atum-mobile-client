/// Who is typing, as the chat shows it (plan B10, B11, §2.7).
///
/// Real signals only: these names come from the SDK's typing listener
/// (`Room.subscribeToTypingNotifications`), never from a guess that an agent
/// is working. Nothing here invents a typer.
public enum TypingNames {
    /// The others typing, in the SDK's order. My own user is dropped (the
    /// bindings do not say whether the SDK already drops it), and so are
    /// empty and repeated IDs.
    public static func others(_ typingUserIDs: [String], ownUserID: String) -> [String] {
        var seen = Set<String>()
        return typingUserIDs.filter { userID in
            !userID.isEmpty && userID != ownUserID && seen.insert(userID).inserted
        }
    }

    /// Display names for the typing row and the people line, in the SDK's
    /// order. `name` returns the name the chat already shows for that sender
    /// (the app applies `MobileSenderLabelPolicy`, which never shows a raw
    /// Matrix ID), or nil while it has none.
    ///
    /// A typer with no usable name:
    /// - in an agent or bot room shows as the room's title (once), so a real
    ///   `m.typing` from the agent always shows the dots (B10), also before a
    ///   profile lookup lands;
    /// - in a people or group room is left out of the line (never a raw ID).
    public static func displayNames(_ typingUserIDs: [String], ownUserID: String, kind: RoomKind,
                                    roomTitle: String?, name: (String) -> String?) -> [String] {
        let fallback = unnamedTyperName(kind: kind, roomTitle: roomTitle)
        var names: [String] = []
        var usedFallback = false
        for userID in others(typingUserIDs, ownUserID: ownUserID) {
            if let value = name(userID), !value.isEmpty {
                names.append(value)
            } else if let fallback, !usedFallback {
                usedFallback = true
                names.append(fallback)
            }
        }
        return names
    }

    /// What an unnamed typer shows as: the room's title in agent and bot
    /// rooms (the title is the agent's or bot's name); nothing in people and
    /// group rooms.
    public static func unnamedTyperName(kind: RoomKind, roomTitle: String?) -> String? {
        switch kind {
        case .assistant, .appBot:
            guard let roomTitle, !roomTitle.isEmpty else { return nil }
            return roomTitle
        case .person, .group:
            return nil
        }
    }

    /// B11: one to three names are named; more is "many".
    public static func line(_ names: [String]) -> TypingLine {
        switch names.count {
        case 0: return .nobody
        case 1...TypingLine.maximumNamed: return .names(names)
        default: return .many
        }
    }

    /// Where typing shows in this room (§2.7): agents and bots get the dots
    /// as the transcript's last row; people and groups get one quiet line
    /// above the composer and no row. The projection shows a typing row for
    /// any non-empty `rowNames`, so people rooms must pass it an empty list.
    public static func presentation(kind: RoomKind, names: [String]) -> TypingPresentation {
        switch kind {
        case .assistant, .appBot:
            return TypingPresentation(rowNames: names, line: .nobody)
        case .person, .group:
            return TypingPresentation(rowNames: [], line: line(names))
        }
    }
}

/// The quiet people line above the composer (B11). Formatting is the view's:
/// "{names} đang soạn tin…" and "Nhiều người đang soạn tin…" come from the
/// exported copy, never from Swift.
public enum TypingLine: Equatable, Hashable, Sendable {
    case nobody
    /// One to three names, in the SDK's order.
    case names([String])
    /// More than three people.
    case many

    public static let maximumNamed = 3
}

/// Typing for one room, split by where it shows (§2.7).
public struct TypingPresentation: Equatable, Hashable, Sendable {
    /// Names for the projection's typing row (`Projection.rows(typingNames:)`).
    public var rowNames: [String]
    /// The line above the composer.
    public var line: TypingLine

    public init(rowNames: [String], line: TypingLine) {
        self.rowNames = rowNames
        self.line = line
    }
}
