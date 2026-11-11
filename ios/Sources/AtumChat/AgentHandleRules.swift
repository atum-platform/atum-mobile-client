import Foundation

/// An assistant's public handle as a person types it, ported from desktop
/// `apps/desktop/src/matrix/handle-rules.ts`. The phone checks only the
/// grammar and the `_bot` ending, to save a request; the platform decides
/// availability, reserved names and the 30-day rule.
public enum AgentHandleRules {
    /// Why a handle cannot be had, in the alias copy's terms
    /// (`shared.matrix-alias-copy.copy.<rawValue>`).
    public enum Problem: String, Equatable, Sendable, CaseIterable {
        case invalid
        case botRequired
        case botReserved
        case reserved
        case unavailable
    }

    public static let botSuffix = "_bot"
    /// Room for an assistant's handle before its fixed `_bot` ending.
    public static let stemMaximum = 32 - botSuffix.count
    /// The stem used when a name gives none, or when the directory reserves
    /// the name's own: Vietnamese for "helper" (desktop `FALLBACK_AGENT_STEM`).
    public static let fallbackStem = "tro_thu"

    public static func isWellFormed(_ handle: String) -> Bool {
        let scalars = Array(handle.unicodeScalars)
        guard (3...32).contains(scalars.count), let first = scalars.first, isLower(first) else { return false }
        return scalars.dropFirst().allSatisfy { isLower($0) || isDigit($0) || $0 == "_" }
    }

    /// The grammar and the ending for an assistant; nil when it may ask.
    public static func localProblem(_ handle: String) -> Problem? {
        guard isWellFormed(handle) else { return .invalid }
        return handle.hasSuffix(botSuffix) ? nil : .botRequired
    }

    /// A check's refusal code (`alias_*`) as a problem; an unknown code is
    /// just unavailable.
    public static func checkProblem(_ code: String?) -> Problem? {
        guard let code else { return nil }
        switch code {
        case "alias_invalid": return .invalid
        case "alias_bot_suffix_required": return .botRequired
        case "alias_bot_suffix_reserved": return .botReserved
        case "alias_reserved": return .reserved
        default: return .unavailable
        }
    }

    /// A first handle to offer an assistant, from its name
    /// ("Trợ lý Đức" → "tro_ly_duc_bot"), or "".
    public static func suggested(forName name: String?) -> String {
        let stem = nameStem(name)
        return stem.isEmpty ? "" : stem + botSuffix
    }

    /// The part of a handle the field shows ("tiep_thi_bot" → "tiep_thi").
    public static func stem(ofHandle handle: String) -> String {
        handle.hasSuffix(botSuffix) ? String(handle.dropLast(botSuffix.count)) : handle
    }

    /// The whole handle for a stem, or "" for an empty field.
    public static func handle(fromStem stem: String) -> String {
        stem.isEmpty ? "" : stem + botSuffix
    }

    /// The stem a person's typing stands for: read the way a name is, with
    /// a typed `@`, a final `_bot` and trailing `_` dropped (the field shows
    /// `@` and `_bot` itself). A `_bot` inside ("tro_ly_botanic") is kept.
    public static func typedStem(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("@") { text.removeFirst() }
        var value = fold(text, keepUnderscore: true)
        value = trimTrailingUnderscores(value)
        if value.hasSuffix(botSuffix) { value = String(value.dropLast(botSuffix.count)) }
        value = String(value.unicodeScalars.prefix(stemMaximum).map(Character.init))
        return trimTrailingUnderscores(value)
    }

    /// The handles a new assistant tries, best first, in groups that share a
    /// stem: a stem the person chose, then the name's own, then the fallback,
    /// each followed by the same with a short number. A reserved stem stays
    /// reserved with any number, so a claim walk moves to the next group.
    public static func candidates(name: String?, chosenStem: String? = nil,
                                  random: () -> Double = { Double.random(in: 0..<1) }) -> [[String]] {
        var stems: [String] = []
        for stem in [chosenStem, nameStem(name), fallbackStem] {
            guard let stem, !stem.isEmpty, isWellFormed(stem + botSuffix), !stems.contains(stem) else { continue }
            stems.append(stem)
        }
        return stems.map { group(for: $0, random: random) }
    }

    /// The same handle with a short number, offered when the plain one is
    /// taken ("tiep_thi42_bot").
    public static func numbered(stem: String,
                                random: () -> Double = { Double.random(in: 0..<1) }) -> String? {
        group(for: stem, random: random).first { $0 != stem + botSuffix }
    }

    // MARK: Private

    private static func group(for stem: String, random: () -> Double) -> [String] {
        func numbered(_ value: Int) -> String {
            let digits = String(value)
            var cut = String(stem.prefix(32 - botSuffix.count - digits.count - 1))
            cut = trimTrailingUnderscores(cut)
            let separator = cut.last.map { $0.isASCII && $0.isNumber } == true ? "_" : ""
            return cut + separator + digits + botSuffix
        }
        func between(_ low: Int, _ high: Int) -> Int {
            low + Int((random() * Double(high - low + 1)).rounded(.down))
        }
        var ordered: [String] = [stem + botSuffix]
        for (low, high) in [(10, 99), (10, 99), (100, 999), (1000, 9999)] {
            let value = numbered(between(low, high))
            if !ordered.contains(value) { ordered.append(value) }
        }
        return ordered.filter { localProblem($0) == nil }
    }

    /// Desktop `agentHandleStem`: diacritics stripped, đ read as d, anything
    /// else folded to `_`, leading non-letters dropped, cut to the room before
    /// `_bot`; "" when nothing usable is left.
    private static func nameStem(_ name: String?) -> String {
        var value = fold(name ?? "", keepUnderscore: false)
        while let first = value.unicodeScalars.first, !isLower(first) { value.removeFirst() }
        value = String(value.unicodeScalars.prefix(stemMaximum).map(Character.init))
        value = trimTrailingUnderscores(value)
        return !value.isEmpty && isWellFormed(value + botSuffix) ? value : ""
    }

    /// NFD, combining marks U+0300–U+036F removed, đ/Đ → d, lower-cased, and
    /// every run of other characters folded to one `_`.
    private static func fold(_ text: String, keepUnderscore: Bool) -> String {
        var output = ""
        var inRun = false
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
            if (0x300...0x36F).contains(scalar.value) { continue }
            var mapped = scalar
            if scalar == "đ" || scalar == "Đ" { mapped = "d" }
            let lowered = String(mapped).lowercased()
            let allowed = lowered.unicodeScalars.count == 1
                && lowered.unicodeScalars.allSatisfy { isLower($0) || isDigit($0) || (keepUnderscore && $0 == "_") }
            if allowed {
                output += lowered
                inRun = false
            } else if !inRun {
                output += "_"
                inRun = true
            }
        }
        return output
    }

    private static func trimTrailingUnderscores(_ value: String) -> String {
        var value = value
        while value.hasSuffix("_") { value.removeLast() }
        return value
    }

    private static func isLower(_ scalar: Unicode.Scalar) -> Bool { ("a"..."z").contains(scalar) }
    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }
}
