import Foundation

/// HC-5: what the Start chat search field holds (desktop `people.ts`
/// `parsePersonQuery`). A query that could be someone's public @name, or a
/// complete Matrix address, offers "Find @x on Atum"; a plain name only
/// filters the people already known.
public enum StartChatQuery: Equatable, Sendable {
    case empty
    /// Could be a public @name (the platform's grammar: 3–32, a letter first,
    /// then lower-case letters, digits and `_`). It also filters names locally.
    case handle(String)
    /// A complete Matrix address, accepted without a lookup.
    case matrixID(String)
    /// A name: it filters people already known and finds no one new.
    case text(String)

    public static func parse(_ raw: String) -> StartChatQuery {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        if text.count <= 1024, isMatrixID(text) { return .matrixID(text) }
        var handle = text
        if handle.hasPrefix("@") { handle.removeFirst() }
        handle = handle.lowercased()
        return isHandle(handle) ? .handle(handle) : .text(text)
    }

    /// What "Find @x on Atum" names, or nil when the query finds no one new.
    /// A Matrix address is shown without its leading `@`, as on desktop.
    public var findable: String? {
        switch self {
        case let .handle(handle): handle
        case let .matrixID(userID): String(userID.dropFirst())
        case .empty, .text: nil
        }
    }

    /// `^[a-z][a-z0-9_]{2,31}$`
    static func isHandle(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (3...32).contains(scalars.count), let first = scalars.first,
              ("a"..."z").contains(first) else { return false }
        return scalars.dropFirst().allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// `^@[^:\s]+:[^\s]+$`
    static func isMatrixID(_ value: String) -> Bool {
        guard value.hasPrefix("@"), !value.contains(where: \.isWhitespace) else { return false }
        let body = value.dropFirst()
        guard let colon = body.firstIndex(of: ":") else { return false }
        return colon != body.startIndex && body.index(after: colon) != body.endIndex
    }
}
