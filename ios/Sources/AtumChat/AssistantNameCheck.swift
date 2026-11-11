import Foundation

/// The new-assistant sheet's name check before anything is created, a
/// deliberately narrow subset of desktop `checkAssistantName`
/// (`apps/desktop/shared/matrix-assistant-name.ts`). It refuses only what the
/// platform certainly refuses too, so a good name is never stopped here; the
/// script, look-alike and skeleton rules stay with the platform, whose
/// refusal the sheet now shows (lane 3 D-1).
public enum AssistantNameCheck {
    /// The card's problem line (`assistantCardCopies.problems.<rawValue>`).
    public enum Problem: String, Equatable, Sendable {
        case empty
        case tooLong
        case reserved
        case duplicate
        case checkMark
    }

    /// The platform's limit: 1–40 code points of the trimmed name.
    public static let maximum = 40

    /// Desktop `ASSISTANT_RESERVED_NAMES`, compared whole with accents kept
    /// ("Bến" is not Ben), plus the `atum` prefix no other assistant may use.
    public static let reservedNames: Set<String> = [
        "atum", "moon", "ben", "andy", "taylor", "admin", "founder", "support",
    ]

    private static let checkMarks: Set<Unicode.Scalar> = ["\u{2713}", "\u{2714}", "\u{2611}", "\u{2705}"]

    /// The name as it would be stored: trimmed, inner spaces collapsed.
    public static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    public static func problem(_ value: String, others: [String]) -> Problem? {
        let name = normalized(value)
        guard !name.isEmpty else { return .empty }
        guard name.unicodeScalars.count <= maximum else { return .tooLong }
        if name.unicodeScalars.contains(where: checkMarks.contains) { return .checkMark }
        let key = name.lowercased()
        if reservedNames.contains(key) || key.hasPrefix("atum") { return .reserved }
        if others.contains(where: { normalized($0).lowercased() == key }) { return .duplicate }
        return nil
    }
}

/// Desktop `assistantPersona`: the two create-sheet answers as the
/// assistant's instructions ("# Name", "## Who you are", "## What you do"),
/// or nil when both are empty and the platform's default stays.
public enum AssistantCreatePersona {
    public static let answerMaximum = 8_000

    public static func soul(name: String, who: String, job: String) -> String? {
        let who = who.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = job.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []
        if !who.isEmpty { sections.append("## " + AssistantPersonaPolicy.whoTitle + "\n\n" + who) }
        if !job.isEmpty { sections.append("## " + AssistantPersonaPolicy.whatTitle + "\n\n" + job) }
        guard !sections.isEmpty else { return nil }
        return (["# " + name.trimmingCharacters(in: .whitespacesAndNewlines)] + sections)
            .joined(separator: "\n\n")
    }
}
