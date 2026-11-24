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

    /// `apps` are the names the catalog's apps go by (desktop
    /// `appCatalogNames`); a name that is one of them is refused as reserved.
    public static func problem(_ value: String, others: [String], apps: [String] = []) -> Problem? {
        let name = normalized(value)
        guard !name.isEmpty else { return .empty }
        guard name.unicodeScalars.count <= maximum else { return .tooLong }
        if name.unicodeScalars.contains(where: checkMarks.contains) { return .checkMark }
        let lowered = name.lowercased()
        if reservedNames.contains(lowered) || lowered.hasPrefix("atum") { return .reserved }
        if isCatalogName(name, apps: apps) { return .reserved }
        let own = key(name)
        if !own.isEmpty, others.contains(where: { key($0) == own }) { return .duplicate }
        return nil
    }

    // MARK: The platform's keys (0192, desktop `matrix-assistant-name.ts`)

    /// Drawn alike in a chat font, in this order (`ASSISTANT_NAME_LOOK_MERGES`).
    static let lookMerges: [(String, String)] = [
        ("rn", "m"), ("vv", "w"), ("i", "l"), ("1", "l"), ("0", "o"), ("5", "s"), ("cl", "d"),
    ]

    /// Read alike aloud, then drawn alike (`ASSISTANT_NAME_FOLD_MERGES`).
    static let foldMerges: [(String, String)] = [("y", "i")] + lookMerges

    /// Latin letters that do not decompose (`ASSISTANT_NAME_SKELETON_LETTERS`).
    static let skeletonLetters: [Character: String] = [
        "Æ": "ae", "Ø": "o", "ß": "ss", "æ": "ae", "ø": "o", "Đ": "d", "đ": "d",
        "ı": "i", "Ł": "l", "ł": "l", "Œ": "oe", "œ": "oe", "ẞ": "ss",
    ]

    /// The Latin letters a name may use (`ASSISTANT_NAME_LETTERS.latin`).
    static let latinRanges: [ClosedRange<UInt32>] = [
        0x41...0x5a, 0x61...0x7a, 0xc0...0xcf, 0xd1...0xd6, 0xd8...0xdd, 0xdf...0xef,
        0xf1...0xf6, 0xf8...0xfd, 0xff...0x125, 0x128...0x131, 0x134...0x137, 0x139...0x13e,
        0x141...0x148, 0x14c...0x165, 0x168...0x17e, 0x1a0...0x1a1, 0x1af...0x1b0,
        0x1cd...0x1dc, 0x1de...0x1e1, 0x1e6...0x1ed, 0x1f0...0x1f0, 0x1f4...0x1f5,
        0x1f8...0x1fb, 0x200...0x21b, 0x21e...0x21f, 0x226...0x233, 0x1e00...0x1e99,
        0x1e9e...0x1e9e, 0x1ea0...0x1ef9,
    ]

    /// A catalog name shorter than this is not kept (`ASSISTANT_CATALOG_NAME_MIN`).
    static let catalogNameMinimum = 3

    private static func merged(_ text: String, _ merges: [(String, String)]) -> String {
        merges.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// Emoji count for nothing in a name's key (desktop `keyOf` drops them),
    /// keycaps included.
    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            $0.properties.isEmojiPresentation || $0.value == 0xfe0f || $0.value == 0x20e3
                || (0x1f1e6...0x1f1ff).contains($0.value)
        }
    }

    /// The key two names are "the same name" by (`assistantNameKey`, platform
    /// `assistant_name_key`): letters, digits and accents in any script,
    /// lowercase, with spaces, punctuation and emoji left out and the shapes a
    /// chat font draws alike merged. "Re-searcher" is Researcher, "Ian" is
    /// lan; "Mãi" is not Mai.
    public static func key(_ value: String) -> String {
        let compatible = String(normalized(value).precomposedStringWithCompatibilityMapping
            .filter { !isEmoji($0) })
        let scalars = compatible.decomposedStringWithCanonicalMapping.lowercased().unicodeScalars.filter {
            guard !$0.properties.isDefaultIgnorableCodePoint else { return false }
            switch $0.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber,
                 .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return false
            }
        }
        var text = String(String.UnicodeScalarView(scalars))
        text = merged(text, lookMerges)
        return text.precomposedStringWithCanonicalMapping
    }

    /// A Latin text's skeleton: accents gone, the letters that do not
    /// decompose spelled out, lowercase, then the sound and look merges.
    private static func skeleton(_ text: String) -> String {
        let bare = text.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { $0.properties.generalCategory != .nonspacingMark
                && $0.properties.generalCategory != .spacingMark
                && $0.properties.generalCategory != .enclosingMark }
        let spelled = String(String.UnicodeScalarView(bare)).map { skeletonLetters[$0] ?? String($0) }.joined()
        return merged(spelled.lowercased(), foldMerges)
    }

    /// The name's Latin letters and digits only, through the skeleton
    /// (`foldAssistantName`, platform `fold_name`). Not for display: "Moon",
    /// "M o o n" and "M00n" all give "moon".
    public static func fold(_ value: String) -> String {
        skeleton(latinText(value))
    }

    private static func latinText(_ value: String) -> String {
        let compatible = normalized(value).precomposedStringWithCompatibilityMapping.filter { !isEmoji($0) }
        let latin = compatible.unicodeScalars.filter { scalar in
            (0x30...0x39).contains(scalar.value) || latinRanges.contains { $0.contains(scalar.value) }
        }
        return String(String.UnicodeScalarView(latin))
    }

    /// Whether the name is one an app in the catalog goes by, read whole as
    /// desktop does (`reservedFolds` with `apps`): the same key, or the same
    /// Latin skeleton with or without a number at either end ("Researcher 2"
    /// is still Researcher). Desktop's word, role and pair rules for app
    /// names stay with the platform, whose refusal the sheet shows.
    public static func isCatalogName(_ value: String, apps: [String]) -> Bool {
        guard !apps.isEmpty else { return false }
        var keys = Set<String>()
        var folds = Set<String>()
        for app in apps.prefix(512) {
            let text = String(app.prefix(maximum * 2))
            let appKey = key(text)
            let appFold = fold(text)
            if appKey.count >= catalogNameMinimum { keys.insert(appKey) }
            if appFold.count >= catalogNameMinimum { folds.insert(appFold) }
        }
        if keys.contains(key(value)) { return true }
        let latin = latinText(value)
        guard !latin.isEmpty else { return false }
        let bare = latin.replacingOccurrences(of: "^[0-9]+|[0-9]+$", with: "", options: .regularExpression)
        return [latin, bare].contains { !$0.isEmpty && folds.contains(skeleton($0)) }
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
