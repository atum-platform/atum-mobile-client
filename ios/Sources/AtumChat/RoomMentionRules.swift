public enum RoomMentionRules {
    public static let token = "@room"

    public static func offersSuggestion(for query: String, canNotifyRoom: Bool) -> Bool {
        canNotifyRoom && "room".hasPrefix(query.lowercased())
    }

    public static func insert(into draft: String, canNotifyRoom: Bool) -> (draft: String, offset: Int)? {
        guard let query = MentionRules.activeQuery(in: draft),
              offersSuggestion(for: query, canNotifyRoom: canNotifyRoom),
              let marker = draft.lastIndex(of: "@") else { return nil }
        let prefix = draft[..<marker]
        return (String(prefix) + token + " ", prefix.count)
    }

    static func containsPickedToken(in text: String, at offset: Int) -> Bool {
        let count = token.count
        guard offset >= 0, offset + count <= text.count else { return false }
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: count)
        guard text[start..<end] == token else { return false }
        if start > text.startIndex {
            let before = text[text.index(before: start)]
            guard before.isWhitespace || "([{\"'".contains(before) else { return false }
        }
        if end < text.endIndex {
            let after = text[end]
            return !(after.isLetter || after.isNumber || after == "_")
        }
        return true
    }

    /// Preserve a selected occurrence across a single changed range outside
    /// it. If an edit makes duplicate occurrences ambiguous, require a new pick.
    static func retainedOffset(_ offset: Int, from previous: String, to text: String) -> Int? {
        let old = Array(previous)
        let new = Array(text)
        let prefix = zip(old, new).prefix(while: { $0 == $1 }).count
        let suffix = zip(old.dropFirst(prefix).reversed(), new.dropFirst(prefix).reversed())
            .prefix(while: { $0 == $1 }).count
        if old.count != new.count {
            let oldMatches = previous.split(separator: "@").count { $0.hasPrefix("room") }
            if oldMatches > 1, text.split(separator: "@").count(where: { $0.hasPrefix("room") }) < oldMatches {
                return nil
            }
        }
        let next: Int
        if offset + token.count <= prefix {
            next = offset
        } else if offset >= old.count - suffix {
            next = offset + new.count - old.count
        } else {
            return nil
        }
        return containsPickedToken(in: text, at: next) ? next : nil
    }
}
