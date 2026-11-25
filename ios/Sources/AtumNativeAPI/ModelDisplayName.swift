import Foundation

/// A model's readable name, as the desktop draws it
/// (`apps/desktop/shared/matrix-model-display-name.ts`, `matrixModelDisplayName`).
/// The catalog's own display name wins; an identifier-only entry is still shown
/// as words ("gpt-6.1" → "GPT-6.1", "gpt-5.6-luna" → "GPT-5.6 Luna") instead of a
/// raw id. The table keeps the brands whose spelling is not title case. These are
/// product names, not translated copy.
public enum ModelDisplayName {
    private static let words: [String: String] = [
        "claude": "Claude",
        "deepseek": "DeepSeek",
        "gemini": "Gemini",
        "glm": "GLM",
        "gpt": "GPT",
        "grok": "Grok",
        "kimi": "Kimi",
        "llama": "Llama",
        "minimax": "MiniMax",
        "qwen": "Qwen",
    ]

    /// Brands written with their version after a hyphen, as the products do ("GPT-5.6").
    private static let versionHyphen: Set<String> = ["GPT"]

    public static func name(model: String, displayName: String? = nil) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        // A catalog that repeats the id has no display name of its own; derive one instead.
        if let named = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !named.isEmpty, named != trimmed {
            return named
        }
        let separators = CharacterSet(charactersIn: "-_/").union(.whitespacesAndNewlines)
        var parts: [String] = []
        for word in trimmed.components(separatedBy: separators) where !word.isEmpty {
            let shown = Self.word(word)
            if let previous = parts.last, versionHyphen.contains(previous),
               let first = shown.unicodeScalars.first, ("0"..."9").contains(first) {
                parts[parts.count - 1] = previous + "-" + shown
            } else {
                parts.append(shown)
            }
        }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? model : joined
    }

    private static func word(_ word: String) -> String {
        if let known = words[word.lowercased()] { return known }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// The desktop assistant card's words for a saved external model with no
    /// catalog row (`matrixModelDestinationsView`, `external.modelLabel`):
    /// split on `-`, `_` and `/`; "gpt" is "GPT"; an all-lowercase ASCII word
    /// gets a capital first letter; anything else stays as written. So
    /// "openai/gpt-6.1-sol" reads "Openai GPT 6.1 Sol", as the desktop draws it.
    /// A catalog row's own label wins when one is given.
    public static func destinationLabel(model: String, displayName: String? = nil) -> String {
        if let named = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty {
            return named
        }
        let lowercase = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz")
        let words = model.components(separatedBy: CharacterSet(charactersIn: "-_/"))
            .filter { !$0.isEmpty }
            .map { word -> String in
                if word.lowercased() == "gpt" { return "GPT" }
                guard word.unicodeScalars.allSatisfy(lowercase.contains) else { return word }
                return word.prefix(1).uppercased() + word.dropFirst()
            }
        return words.joined(separator: " ")
    }
}
