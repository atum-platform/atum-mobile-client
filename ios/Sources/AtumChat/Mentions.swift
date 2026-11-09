import Foundation

/// A person the composer can mention (Matrix `m.mentions`, spec 1.7). Pure
/// values: the app turns the room's cached members, and in a company channel
/// the company roster's names and handles, into candidates.
public struct MentionCandidate: Equatable, Hashable, Identifiable, Sendable {
    public let userID: String
    /// The name typed into the message after the `@`.
    public let name: String
    /// The Atum handle, shown quietly and searchable.
    public let handle: String?

    public var id: String { userID }

    public init(userID: String, name: String, handle: String? = nil) {
        self.userID = userID
        self.name = name
        self.handle = handle
    }

    /// `@alice:server` → `alice`.
    public var localpart: String {
        let bare = userID.hasPrefix("@") ? String(userID.dropFirst()) : userID
        return bare.split(separator: ":", maxSplits: 1).first.map(String.init) ?? bare
    }
}

/// A roster entry for a company channel: the platform's name and handle for a
/// member. The Matrix user's localpart is the handle.
public struct MentionRosterEntry: Equatable, Sendable {
    public let handle: String
    public let name: String?

    public init(handle: String, name: String?) {
        self.handle = handle
        self.name = name
    }
}

/// What a send carries beyond the text: the mentioned users and the HTML body
/// that turns each mention into a matrix.to pill. Empty when the text mentions
/// nobody, so an ordinary message stays plain text exactly as typed (B6).
public struct OutgoingMentions: Equatable, Sendable {
    public let userIDs: [String]
    public let formattedHTML: String?

    public static let none = OutgoingMentions(userIDs: [], formattedHTML: nil)

    public var isEmpty: Bool { userIDs.isEmpty }

    public init(userIDs: [String], formattedHTML: String?) {
        self.userIDs = userIDs
        self.formattedHTML = formattedHTML
    }
}

/// The mentions a draft has picked: the exact text each pick put into the
/// draft, and who it stands for. It is resolved against the final text at send
/// time, so a pick that was edited away or deleted sends no mention.
public struct MentionDraft: Equatable, Sendable {
    public private(set) var picks = [String: String]()

    public init() {}

    public var isEmpty: Bool { picks.isEmpty }

    public mutating func register(token: String, userID: String) {
        picks[token] = userID
    }

    public mutating func removeAll() { picks.removeAll() }

    mutating func keepOnly(_ isIncluded: (String, String) -> Bool) {
        picks = picks.filter { isIncluded($0.key, $0.value) }
    }
}

/// Who each message mentions, per message and not per chat. The picks of the
/// draft being typed are `current`; when a message leaves the composer they
/// move into a snapshot for that message's text (`stage`) and `current`
/// starts empty, so a later `@Anna` typed by hand resolves to nobody. A send
/// the SDK refuses gets its picks back with its text (`refused`).
public struct MentionLedger: Equatable, Sendable {
    private struct Staged: Equatable, Sendable {
        let text: String
        let picks: MentionDraft
    }

    public private(set) var current = MentionDraft()
    private var staged = [Staged]()

    public init() {}

    public mutating func register(token: String, userID: String) {
        current.register(token: token, userID: userID)
    }

    /// The draft text changed: a pick whose text is no longer in it is
    /// forgotten at once, so deleting a mention and typing the name again
    /// is a new, unpicked `@word`.
    public mutating func draftChanged(to text: String) {
        guard !current.isEmpty else { return }
        guard text.contains("@") else {
            current.removeAll()
            return
        }
        current.keepOnly { token, userID in
            var one = MentionDraft()
            one.register(token: token, userID: userID)
            return !MentionRules.resolve(text: text, draft: one).isEmpty
        }
    }

    /// A message with this text leaves the composer: it takes the picks of
    /// the draft, and the next draft starts with none.
    public mutating func stage(text: String) {
        draftChanged(to: text)
        staged.append(Staged(text: text, picks: current))
        current.removeAll()
    }

    /// The mentions of the oldest staged message with this text. Held sends
    /// that go out later, or again after a session renewal, ask again.
    public func mentions(for text: String) -> OutgoingMentions {
        guard let message = staged.first(where: { $0.text == text }) else { return .none }
        return MentionRules.resolve(text: text, draft: message.picks)
    }

    /// The SDK took the message: its snapshot is not needed any more.
    public mutating func delivered(text: String) {
        guard let index = staged.firstIndex(where: { $0.text == text }) else { return }
        staged.remove(at: index)
    }

    /// The message came back to the composer (refused, or held and returned):
    /// its picks come back with it, unless the draft already picked the token.
    public mutating func refused(text: String, draft: String) {
        guard let index = staged.firstIndex(where: { $0.text == text }) else { return }
        let message = staged.remove(at: index)
        for (token, userID) in message.picks.picks where current.picks[token] == nil {
            current.register(token: token, userID: userID)
        }
        draftChanged(to: draft)
    }

    /// Every snapshot whose text is in the draft goes back to the composer.
    public mutating func restoreStaged(in draft: String) {
        for text in staged.map(\.text) where draft.contains(text) { refused(text: text, draft: draft) }
    }
}

public enum MentionRules {
    public static let maximumSuggestions = 6
    /// A trailing `@word` longer than this is ordinary text, not a query.
    public static let maximumQueryLength = 40

    // MARK: Candidates

    /// Joined members, newest-known name first: the company roster's name wins
    /// when the Matrix display name is just the user ID, and its handle is kept
    /// for search. The person's own account is never a candidate.
    public static func candidates(members: [(userID: String, displayName: String)],
                                  roster: [MentionRosterEntry] = [],
                                  ownUserID: String) -> [MentionCandidate] {
        var byHandle = [String: MentionRosterEntry]()
        for entry in roster { byHandle[entry.handle.lowercased()] = entry }
        var seen = Set<String>()
        var result = [MentionCandidate]()
        for member in members where member.userID != ownUserID && seen.insert(member.userID).inserted {
            let provisional = MentionCandidate(userID: member.userID, name: "")
            let entry = byHandle[provisional.localpart.lowercased()]
            let matrixName = member.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if !matrixName.isEmpty, matrixName != member.userID {
                name = matrixName
            } else if let rosterName = entry?.name, !rosterName.isEmpty {
                name = rosterName
            } else {
                name = provisional.localpart
            }
            result.append(MentionCandidate(userID: member.userID, name: name,
                                           handle: entry?.handle ?? provisional.localpart))
        }
        return result
    }

    // MARK: Query

    /// The `@word` at the very end of the draft, without the `@`. The field
    /// exposes no caret, so only the text being typed at the end is a query.
    /// An `@` inside a word (an e-mail address) is not one.
    public static func activeQuery(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex {
            let before = draft[draft.index(before: at)]
            guard before.isWhitespace else { return nil }
        }
        let tail = draft[draft.index(after: at)...]
        guard tail.count <= maximumQueryLength, !tail.contains(where: \.isWhitespace) else { return nil }
        return String(tail)
    }

    public static func suggestions(for query: String, in candidates: [MentionCandidate],
                                   limit: Int = maximumSuggestions) -> [MentionCandidate] {
        let needle = normalize(query)
        var ranked = [(rank: Int, candidate: MentionCandidate)]()
        for candidate in candidates {
            let name = normalize(candidate.name)
            let handle = normalize(candidate.handle ?? candidate.localpart)
            let rank: Int
            if needle.isEmpty {
                rank = 3
            } else if name.hasPrefix(needle) {
                rank = 0
            } else if handle.hasPrefix(needle) {
                rank = 1
            } else if name.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) {
                rank = 2
            } else {
                continue
            }
            ranked.append((rank, candidate))
        }
        ranked.sort { left, right in
            if left.rank != right.rank { return left.rank < right.rank }
            let order = left.candidate.name.compare(right.candidate.name,
                                                    options: [.caseInsensitive, .diacriticInsensitive])
            if order != .orderedSame { return order == .orderedAscending }
            return left.candidate.userID < right.candidate.userID
        }
        return ranked.prefix(max(0, limit)).map(\.candidate)
    }

    // MARK: Insert

    /// The text a pick puts into the draft: `@Name`, or `@Name (handle)` when
    /// another candidate shares the name, so the text itself tells them apart.
    public static func token(for candidate: MentionCandidate,
                             among candidates: [MentionCandidate]) -> String {
        let sameName = candidates.contains {
            $0.userID != candidate.userID
                && $0.name.compare(candidate.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return sameName ? "@\(candidate.name) (\(candidate.handle ?? candidate.localpart))"
                        : "@\(candidate.name)"
    }

    /// Replaces the trailing `@word` with the pick and a space. The caller
    /// registers the returned token on its `MentionDraft`.
    public static func insert(_ candidate: MentionCandidate, among candidates: [MentionCandidate],
                              into draft: String) -> (draft: String, token: String)? {
        guard activeQuery(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return nil }
        let token = token(for: candidate, among: candidates)
        return (String(draft[..<at]) + token + " ", token)
    }

    // MARK: Resolve

    /// Finds each picked token in the final text (at a word start, not inside a
    /// longer word) and builds the user IDs and the pill HTML. Text with no
    /// surviving pick resolves to `.none`.
    public static func resolve(text: String, draft: MentionDraft) -> OutgoingMentions {
        guard !draft.isEmpty, text.contains("@") else { return .none }
        let characters = Array(text)
        var spans = [(start: Int, end: Int, token: String, userID: String)]()
        let ordered = draft.picks.sorted { $0.key.count != $1.key.count ? $0.key.count > $1.key.count
                                                                         : $0.key < $1.key }
        for (token, userID) in ordered {
            let needle = Array(token)
            guard !needle.isEmpty, needle.count <= characters.count else { continue }
            var index = 0
            while index + needle.count <= characters.count {
                if matches(characters, at: index, needle: needle),
                   startsWord(characters, at: index), endsWord(characters, after: index + needle.count),
                   !spans.contains(where: { index < $0.end && $0.start < index + needle.count }) {
                    spans.append((index, index + needle.count, token, userID))
                    index += needle.count
                } else {
                    index += 1
                }
            }
        }
        guard !spans.isEmpty else { return .none }
        spans.sort { $0.start < $1.start }
        var userIDs = [String]()
        for span in spans where !userIDs.contains(span.userID) { userIDs.append(span.userID) }

        var html = ""
        var cursor = 0
        for span in spans {
            html += escape(String(characters[cursor..<span.start]))
            html += "<a href=\"https://matrix.to/#/\(userID: span.userID)\">\(escape(span.token))</a>"
            cursor = span.end
        }
        html += escape(String(characters[cursor...]))
        return OutgoingMentions(userIDs: userIDs, formattedHTML: html)
    }

    // MARK: Helpers

    private static func matches(_ text: [Character], at index: Int, needle: [Character]) -> Bool {
        for offset in needle.indices where text[index + offset] != needle[offset] { return false }
        return true
    }

    private static func startsWord(_ text: [Character], at index: Int) -> Bool {
        index == 0 || text[index - 1].isWhitespace || "([{\"'".contains(text[index - 1])
    }

    /// A token ends where the text ends, at whitespace, or at punctuation; a
    /// letter or digit after it means the person typed a longer name.
    private static func endsWord(_ text: [Character], after index: Int) -> Bool {
        guard index < text.count else { return true }
        let next = text[index]
        return !(next.isLetter || next.isNumber || next == "_")
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n", "\r\n": out += "<br>"
            default: out.append(character)
            }
        }
        return out
    }

    static func normalize(_ source: String) -> String {
        source.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "d")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String.StringInterpolation {
    /// A Matrix user ID inside an `href`: HTML-attribute safe; `@` and `:` stay
    /// as written, as in a matrix.to user link.
    mutating func appendInterpolation(userID: String) {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "@:._=-/+")
        appendLiteral(userID.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }
}
