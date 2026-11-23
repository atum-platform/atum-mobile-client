import Foundation

public struct AssistantPersona: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case template, primary, custom }
    fileprivate struct Section: Equatable, Sendable {
        let title: String
        let raw: String
    }

    public let kind: Kind
    public let heading: String?
    /// The primary assistant's built-in first line, exactly as written. The
    /// platform keeps its name line in step, so a card render never rewrites it.
    public let nameLine: String?
    public let who: String
    public let what: String
    /// Custom only: the whole text after the heading line, except its
    /// `Who you are` sections (those are the personality field).
    public let instructions: String
    fileprivate let head: String
    fileprivate let sections: [Section]
    /// The text reads differently to a fence-aware parse than to desktop's
    /// (a template title inside a code fence, a repeated `Who you are` or
    /// `What you do` section, an unclosed fence). The card shows it but does
    /// not offer per-field editing, and `AssistantPersonaMerge` never writes
    /// over it.
    public fileprivate(set) var isAmbiguous = false
}

/// One editable persona field on the card (desktop `PersonaChange['field']`).
public enum AssistantPersonaField: String, CaseIterable, Sendable {
    case who, what, instructions
}

/// The desktop-compatible projection of an assistant definition's `soul`
/// (port of desktop `shared/matrix-assistant-persona.ts` at `46f5a518`,
/// including PR #95). Known templates and hand-written definitions both show
/// a main field and a personality; rendering preserves sections the phone
/// does not own instead of flattening an imported definition.
///
/// A field may contain `## ` headings of its own, including the template's
/// titles. Those are written behind a Markdown comment marker
/// (`<!-- atum:persona-heading -->`) so they round-trip inside their field
/// instead of splitting it into new sections.
public enum AssistantPersonaPolicy {
    public static let whoTitle = "Who you are"
    public static let whatTitle = "What you do"
    /// Hermes' shared context-file budget (`hermes_cli/data/context-file-limits.json`
    /// `defaultMaxChars`, desktop PR #95). The effective limit can vary by
    /// model or profile; this is the default the desktop warning uses.
    public static let contextFileMaxChars = 20_000

    static let fieldHeading = "<!-- atum:persona-heading -->"

    /// Desktop's parse (`parsePersona`), which the card shows and edits,
    /// with `isAmbiguous` set when a fence-aware reading of the same text
    /// disagrees with it. The phone never grows a second interpretation:
    /// such a persona is read-only here.
    public static func parse(_ soul: String, inherited: Bool = false,
                             primary: Bool = false) -> AssistantPersona {
        var persona = parse(soul, inherited: inherited, primary: primary, fenceAware: false)
        let aware = parse(soul, inherited: inherited, primary: primary, fenceAware: true)
        persona.isAmbiguous = persona.kind != aware.kind
            || persona.nameLine != aware.nameLine
            || persona.who != aware.who
            || persona.what != aware.what
            || persona.instructions != aware.instructions
            || repeatsAField(persona) || repeatsAField(aware)
            || fences(soul).unclosed
        return persona
    }

    private static func repeatsAField(_ persona: AssistantPersona) -> Bool {
        [whoTitle, whatTitle].contains { title in
            persona.sections.filter { $0.title == title }.count > 1
        }
    }

    private static func parse(_ soul: String, inherited: Bool, primary: Bool,
                              fenceAware: Bool) -> AssistantPersona {
        let ns = soul as NSString
        let fenced = fenceAware ? fences(soul).ranges : []
        let starts: [(location: Int, title: String)] = h2Regex
            .matches(in: soul, range: NSRange(location: 0, length: ns.length))
            .filter { $0.range(at: 1).location == NSNotFound }
            .filter { match in !fenced.contains { NSLocationInRange(match.range.location, $0) } }
            .map { ($0.range.location, ns.substring(with: $0.range(at: 2)).trimmed) }
        let head = starts.first.map { ns.substring(to: $0.location) } ?? soul
        let sections = starts.enumerated().map { index, start in
            let end = starts.indices.contains(index + 1) ? starts[index + 1].location : ns.length
            return AssistantPersona.Section(
                title: start.title,
                raw: ns.substring(with: NSRange(location: start.location, length: end - start.location))
            )
        }
        let heading: String? = if soul.drop(while: { $0.isWhitespace }).hasPrefix("# "),
                                  let match = headingRegex.firstMatch(
                                      in: soul, range: NSRange(location: 0, length: ns.length)) {
            ns.substring(with: match.range(at: 1)).trimmed
        } else { nil }
        func find(_ title: String) -> AssistantPersona.Section? {
            sections.first(where: { $0.title == title })
        }
        let who = find(whoTitle).map(sectionBody) ?? ""

        // The primary's built-in persona is the same kind of tool as any
        // other assistant's: a "what" and a personality. It carries no
        // `## What you do` section and starts with the name line instead, so
        // it is recognized here. A custom persona the person wrote keeps its
        // own text shape; only the built-in shape becomes primary.
        if primary, find(whatTitle) == nil,
           let builtIn = primaryParts(soul, heading: heading, sections: sections) {
            return AssistantPersona(
                kind: .primary, heading: heading, nameLine: builtIn.nameLine,
                who: who, what: builtIn.what, instructions: "",
                head: head, sections: sections
            )
        }

        // A `Who you are` section can be added to a hand-written persona by
        // the card; that keeps it custom. The template is identified by its
        // `What you do` section, or by a heading followed directly by `Who
        // you are`.
        let headAfterHeading = withoutHeading(head, heading: heading)
        let isTemplate = soul.trimmed.isEmpty
            || inherited
            || (heading != nil && find(whatTitle) != nil)
            || (heading != nil && headAfterHeading.isEmpty && sections.first?.title == whoTitle)
        let customText = head + sections.filter { $0.title != whoTitle }.map(\.raw).joined()
        return AssistantPersona(
            kind: isTemplate ? .template : .custom,
            heading: heading,
            nameLine: nil,
            who: who,
            what: find(whatTitle).map(sectionBody) ?? "",
            instructions: isTemplate ? "" : fieldBody(withoutHeading(customText, heading: heading)),
            head: head,
            sections: sections
        )
    }

    /// The persona with the given fields set. Untouched sections and the head
    /// are kept byte for byte (line endings, trailing spaces, the final
    /// newline); a changed field replaces only its own slice, and a new
    /// boundary gets just the separator it needs, in the text's own line
    /// ending. An emptied field drops its section; a new one is added in the
    /// template's order. With no persona at all and nothing typed, the
    /// result is empty (the assistant keeps Atum's own).
    public static func render(_ parsed: AssistantPersona, name: String,
                              who: String? = nil, what: String? = nil,
                              instructions: String? = nil) -> String {
        let original = rawPersona(parsed)
        let newline = original.contains("\r\n") ? "\r\n" : "\n"
        let soul: String
        switch parsed.kind {
        case .primary:
            soul = renderPrimary(parsed, name: name, who: (who ?? parsed.who).trimmed,
                                 what: (what ?? parsed.what).trimmed, newline: newline)
        case .custom:
            let main = (instructions ?? parsed.instructions).trimmed
            let who = (who ?? parsed.who).trimmed
            let mainChanged = instructions != nil && main != parsed.instructions.trimmed
            let whoChanged = who != parsed.who.trimmed
            if !mainChanged && !whoChanged { return original }
            if !mainChanged {
                soul = renderCustomWho(parsed, who: who, newline: newline)
                break
            }
            var text = renderCustomMain(parsed, instructions: markFieldHeadings(main, customMain: true))
            let whoSections = parsed.sections.filter { $0.title == whoTitle }
            if whoChanged, !who.isEmpty { text = appendSection(text, section(whoTitle, who, newline)) }
            for item in whoChanged ? Array(whoSections.dropFirst()) : whoSections {
                text = appendSection(text, item.raw)
            }
            soul = text
        case .template:
            soul = renderTemplate(parsed, name: name, who: (who ?? parsed.who).trimmed,
                                  what: (what ?? parsed.what).trimmed, newline: newline)
        }
        return keepingEnd(soul, of: original)
    }

    private static func renderTemplate(_ parsed: AssistantPersona, name: String,
                                       who: String, what: String, newline: String) -> String {
        let values = [whoTitle: who, whatTitle: what]
        var body = ""
        var seen = Set<String>()
        for item in parsed.sections {
            if let value = values[item.title], seen.insert(item.title).inserted {
                if value == sectionBody(item) { body += item.raw }
                else if !value.isEmpty { body += section(item.title, value, newline) + separator(item.raw) }
            } else {
                body += item.raw
            }
        }
        // New sections, in the template's order: who before what.
        for title in [whoTitle, whatTitle] where !seen.contains(title) {
            guard let value = values[title], !value.isEmpty else { continue }
            body = appendSection(body, section(title, value, newline))
        }
        let head = parsed.head
        let onlyHeading = head.trimmed.isEmpty
            || head.range(of: #"^\s*# [^\r\n]*\s*$"#, options: .regularExpression) != nil
        // Nothing left but (at most) a heading: no persona.
        if body.isEmpty && onlyHeading { return "" }
        if head.trimmed.isEmpty { return "# \(name)" + newline + newline + body }
        if parsed.sections.isEmpty { return appendSection(head, body) }
        return head + body
    }

    private static func renderPrimary(_ parsed: AssistantPersona, name: String,
                                      who: String, what: String, newline: String) -> String {
        var prefix = parsed.head
        if parsed.heading != nil {
            // The platform keeps the heading in step with the name.
            prefix = prefix.replacingOccurrences(
                of: #"^(\s*)# [^\r\n]*"#,
                with: "$1# " + NSRegularExpression.escapedTemplate(for: name),
                options: .regularExpression)
        }
        if what != parsed.what.trimmed, let nameLine = parsed.nameLine,
           let line = prefix.range(of: nameLine) {
            prefix = String(prefix[..<line.upperBound])
                + (what.isEmpty ? "" : newline + newline + markFieldHeadings(what))
            if !parsed.sections.isEmpty { prefix += newline + newline }
        }
        var body = ""
        var found = false
        for item in parsed.sections {
            guard item.title == whoTitle, !found else {
                body += item.raw
                continue
            }
            found = true
            if who == sectionBody(item) { body += item.raw }
            else if !who.isEmpty { body += section(whoTitle, who, newline) + separator(item.raw) }
        }
        guard !who.isEmpty, !found else { return prefix + body }
        // A new personality goes before the primary's other sections.
        return body.isEmpty
            ? appendSection(prefix, section(whoTitle, who, newline))
            : prefix + section(whoTitle, who, newline) + newline + newline + body
    }

    /// The text's own ending (final newline, trailing spaces) stays as it
    /// was, whatever the last slice became.
    private static func keepingEnd(_ soul: String, of original: String) -> String {
        guard !soul.isEmpty else { return "" }
        return soul.trimmedEnd + String(original[original.trimmedEndIndex...])
    }

    /// Desktop's quiet length hint: the combined instructions are longer than
    /// what the agent loads. Hermes counts Unicode code points after the file
    /// read normalizes newlines.
    public static func exceedsContextBudget(_ soul: String,
                                            limit: Int = contextFileMaxChars) -> Bool {
        // Hermes reads SOUL.md as utf-8-sig, so a leading BOM is not counted.
        var scalars = Substring(soul).unicodeScalars
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        let text = String(scalars)
        guard text.utf16.count > limit else { return false }
        let normalized = text.trimmed
            .replacingOccurrences(of: "\r\n?", with: "\n", options: .regularExpression)
        return normalized.unicodeScalars.count > limit
    }

    // MARK: Field headings

    /// A `## ` line, optionally preceded by one or more field-heading markers
    /// (group 1: the marker; group 2: the title).
    private static let h2Regex = try! NSRegularExpression(
        pattern: #"^(?:(<!-- atum:persona-heading -->)(?:\r?\n<!-- atum:persona-heading -->)*\r?\n)?## ([^\r\n]+)"#,
        options: [.anchorsMatchLines]
    )

    /// The UTF-16 ranges of fenced code blocks (CommonMark: a line of three
    /// or more backticks or tildes, indented at most three spaces, closed by
    /// a line of the same character at least as long; an unclosed fence runs
    /// to the end). Only used to detect text desktop's parser would read
    /// differently, never to decide structure.
    static func fencedRanges(_ text: String) -> [NSRange] { fences(text).ranges }

    static func fences(_ text: String) -> (ranges: [NSRange], unclosed: Bool) {
        let ns = text as NSString
        var ranges = [NSRange]()
        var open: (start: Int, char: Character, count: Int)?
        var location = 0
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line)
            let indent = content.prefix(while: { $0 == " " }).count
            let rest = content.dropFirst(indent)
            if indent <= 3, let char = rest.first, char == "`" || char == "~" {
                let count = rest.prefix(while: { $0 == char }).count
                let tail = rest.dropFirst(count)
                if let fence = open {
                    if char == fence.char, count >= fence.count, tail.allSatisfy(\.isWhitespace) {
                        ranges.append(NSRange(location: fence.start,
                                              length: line.location + line.length - fence.start))
                        open = nil
                    }
                } else if count >= 3, !(char == "`" && tail.contains("`")) {
                    open = (line.location, char, count)
                }
            }
            location = line.location + line.length
        }
        if let fence = open {
            ranges.append(NSRange(location: fence.start, length: ns.length - fence.start))
        }
        return (ranges, open != nil)
    }

    private static let headingRegex = try! NSRegularExpression(
        pattern: #"^# (.+)$"#, options: [.anchorsMatchLines]
    )

    /// Marks the H2s a field body carries so they stay inside the field. In
    /// a custom main field only the template's own titles need the marker;
    /// its other sections are the owner's and stay plain.
    static func markFieldHeadings(_ body: String, customMain: Bool = false) -> String {
        replaceH2(body) { whole, marked, title in
            marked || !customMain || title.trimmed == whoTitle || title.trimmed == whatTitle
                ? fieldHeading + "\n" + whole
                : whole
        }
    }

    /// A field's text as the person wrote it: one marker line removed from
    /// each marked heading.
    static func fieldBody(_ raw: String) -> String {
        replaceH2(raw) { whole, marked, _ in
            guard marked, let newline = whole.firstIndex(where: \.isNewline) else { return whole }
            return String(whole[whole.index(after: newline)...])
        }.trimmed
    }

    private static func replaceH2(_ text: String,
                                  _ transform: (_ whole: String, _ marked: Bool, _ title: String) -> String)
        -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in h2Regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(ns.substring(with: match.range),
                                match.range(at: 1).location != NSNotFound,
                                ns.substring(with: match.range(at: 2)))
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    // MARK: Parts

    /// The primary's built-in first line, for any name and either D1 answer
    /// (`atum-soul.ts` writes it; this only has to recognize it so the card
    /// shows the same two fields as any other assistant). A hand-written
    /// persona that happens to start this way is still the owner's text.
    private static let primaryNameLinePattern = #"^You are [^\n]{1,80}, the person’s own assistant in the Atum app\. (?:If they give you another name, use it from then on and remember it\.|If they want to call you something else, tell them they can change your picture and how you work from your card, and that your name stays [^\n]{1,80}\.)$"#

    private static func primaryParts(
        _ soul: String, heading: String?, sections: [AssistantPersona.Section]
    ) -> (nameLine: String, what: String)? {
        let rest: String
        if heading != nil,
           let range = soul.range(of: #"^\s*# [^\r\n]*(?:\r?\n|$)"#, options: .regularExpression) {
            rest = String(soul[range.upperBound...])
        } else {
            rest = soul
        }
        let line = String(rest.drop(while: { $0.isWhitespace })
            .prefix(while: { !$0.isNewline }))
        guard !line.isEmpty,
              line.range(of: primaryNameLinePattern, options: [.regularExpression]) != nil else {
            return nil
        }
        let searchStart: String.Index
        if heading != nil, let newline = soul.firstIndex(where: \.isNewline) {
            searchStart = soul.index(after: newline)
        } else {
            searchStart = soul.startIndex
        }
        guard let lineRange = soul.range(of: line, range: searchStart..<soul.endIndex) else {
            return nil
        }
        let bodyStart = lineRange.upperBound
        let bodyEnd = sections.first
            .flatMap { soul.range(of: $0.raw, range: bodyStart..<soul.endIndex)?.lowerBound }
            ?? soul.endIndex
        return (line, fieldBody(String(soul[bodyStart..<bodyEnd])))
    }

    private static func sectionBody(_ section: AssistantPersona.Section) -> String {
        fieldBody(section.raw.replacingOccurrences(of: #"^## .*(?:\r?\n|$)"#, with: "",
                                                   options: .regularExpression))
    }

    private static func rawPersona(_ parsed: AssistantPersona) -> String {
        parsed.head + parsed.sections.map(\.raw).joined()
    }

    private static func withoutHeading(_ text: String, heading: String?) -> String {
        guard heading != nil else { return text.trimmed }
        return text.replacingOccurrences(of: #"^\s*# [^\r\n]*(?:\r?\n|$)"#, with: "",
                                         options: .regularExpression).trimmed
    }

    private static func section(_ title: String, _ body: String, _ newline: String = "\n") -> String {
        "## \(title)" + newline + newline + markFieldHeadings(body.trimmed)
    }

    private static func appendSection(_ soul: String, _ raw: String) -> String {
        guard !soul.isEmpty else { return raw }
        let newline = soul.contains("\r\n") ? "\r\n" : "\n"
        let gap = soul.hasSuffix(newline + newline) ? "" : soul.hasSuffix(newline) ? newline : newline + newline
        return soul + gap + raw
    }

    private static func renderCustomWho(_ parsed: AssistantPersona, who: String,
                                        newline: String) -> String {
        var found = false
        var soul = parsed.head
        for item in parsed.sections {
            guard item.title == whoTitle else {
                soul += item.raw
                continue
            }
            // A second `Who you are` section is not shown; keep it as written.
            if found {
                soul += item.raw
                continue
            }
            found = true
            if who == sectionBody(item) {
                soul += item.raw
            } else if !who.isEmpty {
                soul += section(whoTitle, who, newline) + separator(item.raw)
            }
        }
        return !who.isEmpty && !found ? appendSection(soul, section(whoTitle, who, newline)) : soul
    }

    private static func renderCustomMain(_ parsed: AssistantPersona, instructions: String) -> String {
        let original = rawPersona(parsed)
        guard parsed.heading != nil,
              let range = original.range(of: #"^\s*# [^\r\n]*"#, options: .regularExpression) else {
            return instructions
        }
        let heading = String(original[range])
        let newline = original.contains("\r\n") ? "\r\n" : "\n"
        return instructions.isEmpty ? heading : heading + newline + newline + instructions
    }

    private static func separator(_ raw: String) -> String {
        String(raw[raw.trimmedEndIndex...])
    }
}

/// Desktop's field-level merge (PR #95): each persona edit is a field delta
/// (`before` → `after`) rendered against the latest confirmed definition when
/// it is dispatched. A change elsewhere to the same field is a conflict; a
/// change to the other field is kept.
public enum AssistantPersonaMerge {
    public enum Outcome: Equatable, Sendable {
        /// The soul to write, built on the latest confirmed one.
        case write(String)
        /// The latest definition already says `after`: nothing to write.
        case unchanged
        /// This field changed elsewhere since the edit began (or the persona
        /// changed shape): show the latest version, do not write.
        case elsewhere
        /// The latest persona is ambiguous, or the assembled text would not
        /// read back as intended (or would read differently on desktop): do
        /// not write; the draft stays and the save fails with Retry.
        case unsafe
    }

    /// The field an edit lands in for this persona: the personality is always
    /// `who`; the main field is `instructions` for a custom persona and
    /// `what` otherwise.
    public static func visibleField(_ persona: AssistantPersona,
                                    _ field: AssistantPersonaField) -> AssistantPersonaField {
        field == .who ? .who : persona.kind == .custom ? .instructions : .what
    }

    public static func value(_ persona: AssistantPersona, _ field: AssistantPersonaField) -> String {
        switch field {
        case .who: persona.who
        case .what: persona.what
        case .instructions: persona.instructions
        }
    }

    public static func prepare(field: AssistantPersonaField, before: String, after: String,
                               soul: String, name: String, primary: Bool) -> Outcome {
        let current = AssistantPersonaPolicy.parse(soul, primary: primary)
        if current.isAmbiguous { return .unsafe }
        let currentField = visibleField(current, field)
        if field != .who, field != currentField { return .elsewhere }
        let latest = value(current, currentField).trimmed
        if latest == after.trimmed { return .unchanged }
        if latest != before.trimmed { return .elsewhere }
        let written = AssistantPersonaPolicy.render(
            current, name: name,
            who: field == .who ? after : nil,
            what: field == .what ? after : nil,
            instructions: field == .instructions ? after : nil
        )
        // Round-trip guard: both fields must read back exactly as intended,
        // and desktop's parser must agree with a fence-aware one.
        let reread = AssistantPersonaPolicy.parse(written, primary: primary)
        let expectedWho = field == .who ? after.trimmed : current.who
        let expectedMain = field == .who ? value(current, visibleField(current, .what)) : after.trimmed
        guard !reread.isAmbiguous, reread.who == expectedWho,
              value(reread, visibleField(reread, .what)) == expectedMain else { return .unsafe }
        return .write(written)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var trimmedStart: String { String(drop(while: { $0.isWhitespace })) }

    var trimmedEndIndex: Index {
        var end = endIndex
        while end > startIndex, self[index(before: end)].isWhitespace { end = index(before: end) }
        return end
    }

    var trimmedEnd: String { String(self[..<trimmedEndIndex]) }
}
