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
    public let instructions: String
    fileprivate let head: String
    fileprivate let sections: [Section]
}

/// The desktop-compatible projection of an assistant definition's `soul`.
/// Known templates expose Purpose and Personality; hand-written definitions
/// remain one Instructions field. Rendering preserves sections the phone does
/// not own instead of flattening an imported definition.
public enum AssistantPersonaPolicy {
    public static let whoTitle = "Who you are"
    public static let whatTitle = "What you do"

    public static func parse(_ soul: String, inherited: Bool = false,
                             primary: Bool = false) -> AssistantPersona {
        let matches = sectionRegex.matches(in: soul, range: NSRange(soul.startIndex..., in: soul))
        let starts: [(index: String.Index, title: String)] = matches.compactMap { match in
            guard let whole = Range(match.range(at: 0), in: soul),
                  let title = Range(match.range(at: 1), in: soul) else { return nil }
            return (whole.lowerBound,
                    String(soul[title]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let head = starts.first.map { String(soul[..<$0.index]) } ?? soul
        let sections = starts.enumerated().map { index, start in
            let end = starts.indices.contains(index + 1) ? starts[index + 1].index : soul.endIndex
            return AssistantPersona.Section(title: start.title, raw: String(soul[start.index..<end]))
        }
        let trimmedStart = soul.drop(while: { $0.isWhitespace })
        let heading: String? = if trimmedStart.hasPrefix("# ") {
            trimmedStart.split(maxSplits: 1, omittingEmptySubsequences: false,
                               whereSeparator: \.isNewline).first
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        } else { nil }
        let known = sections.filter { $0.title == whoTitle || $0.title == whatTitle }
        let isTemplate = soul.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || inherited || (heading != nil && !known.isEmpty)
        let afterHeading: String
        if heading != nil, let range = soul.range(of: #"^\s*# .*?(?:\r?\n|$)"#,
                                                   options: .regularExpression) {
            afterHeading = String(soul[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            afterHeading = soul.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func body(_ title: String) -> String {
            sections.first(where: { $0.title == title }).map(sectionBody) ?? ""
        }
        // The primary's built-in persona is the same kind of tool as any
        // other assistant's: a "what" and a personality. It carries no
        // `## What you do` section and starts with the name line instead, so
        // it is recognized here. A custom persona the person wrote keeps its
        // one field; only the built-in shape becomes two.
        if primary, !sections.contains(where: { $0.title == whatTitle }),
           let builtIn = primaryParts(soul, heading: heading, sections: sections) {
            return AssistantPersona(
                kind: .primary, heading: heading, nameLine: builtIn.nameLine,
                who: body(whoTitle), what: builtIn.what, instructions: "",
                head: head, sections: sections
            )
        }
        return AssistantPersona(
            kind: isTemplate ? .template : .custom,
            heading: heading,
            nameLine: nil,
            who: body(whoTitle),
            what: body(whatTitle),
            instructions: isTemplate ? "" : afterHeading,
            head: head,
            sections: sections
        )
    }

    public static func render(_ parsed: AssistantPersona, name: String,
                              who: String? = nil, what: String? = nil,
                              instructions: String? = nil) -> String {
        if parsed.kind == .primary {
            let who = (who ?? parsed.who).trimmingCharacters(in: .whitespacesAndNewlines)
            let what = (what ?? parsed.what).trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = parsed.heading != nil ? "# \(name)" : nil
            let head = [heading, parsed.nameLine].compactMap { $0 }.joined(separator: "\n\n")
            var sections = ""
            for item in parsed.sections {
                if item.title == whoTitle {
                    if who == sectionBody(item) {
                        sections += item.raw
                    } else if !who.isEmpty {
                        sections += section(whoTitle, who) + separator(item.raw)
                    }
                } else {
                    sections += item.raw
                }
            }
            if !who.isEmpty, !parsed.sections.contains(where: { $0.title == whoTitle }) {
                sections = section(whoTitle, who)
                    + (sections.isEmpty ? "" : "\n\n" + sections.trimmingCharacters(in: .whitespaces))
            }
            let body = what.isEmpty ? "" : "\n\n\(what)"
            let combined = [head + body, sections.trimmingCharacters(in: .whitespacesAndNewlines)]
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            return combined.replacingOccurrences(of: #"\s+$"#, with: "",
                                                 options: .regularExpression)
        }

        if parsed.kind == .custom {
            let text = (instructions ?? parsed.instructions).trimmingCharacters(in: .whitespacesAndNewlines)
            guard parsed.heading != nil else { return text }
            return text.isEmpty ? "# \(name)" : "# \(name)\n\n\(text)"
        }

        let values = [
            whoTitle: (who ?? parsed.who).trimmingCharacters(in: .whitespacesAndNewlines),
            whatTitle: (what ?? parsed.what).trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        var parts = [String]()
        var seen = Set<String>()
        for item in parsed.sections {
            if let value = values[item.title] {
                guard seen.insert(item.title).inserted else { continue }
                if value == sectionBody(item) { parts.append(item.raw) }
                else if !value.isEmpty { parts.append(section(item.title, value) + separator(item.raw)) }
            } else {
                parts.append(item.raw)
            }
        }
        for title in [whoTitle, whatTitle] where !seen.contains(title) {
            guard let value = values[title], !value.isEmpty else { continue }
            if let previous = parts.popLast() {
                parts.append(previous.replacingOccurrences(of: #"\s*$"#, with: "\n\n",
                                                           options: .regularExpression))
            }
            parts.append(section(title, value))
        }
        let trimmedHead = parsed.head.trimmingCharacters(in: .whitespacesAndNewlines)
        let onlyHeading = trimmedHead.isEmpty
            || trimmedHead.range(of: #"^# [^\r\n]*$"#, options: .regularExpression) != nil
        if parts.isEmpty && onlyHeading { return "" }
        let lead: String
        if trimmedHead.isEmpty { lead = "# \(name)\n\n" }
        else if !parts.isEmpty {
            lead = parsed.head.replacingOccurrences(of: #"\s*$"#, with: "\n\n",
                                                    options: .regularExpression)
        } else { lead = parsed.head }
        return (lead + parts.joined()).replacingOccurrences(of: #"\s+$"#, with: "",
                                                            options: .regularExpression)
    }

    private static let sectionRegex = try! NSRegularExpression(
        pattern: #"^## (.+?)[ \t]*$"#, options: [.anchorsMatchLines]
    )

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
            .prefix(while: { $0 != "\n" && $0 != "\r" }))
        guard !line.isEmpty,
              line.range(of: primaryNameLinePattern, options: [.regularExpression]) != nil else {
            return nil
        }
        let searchStart: String.Index
        if heading != nil, let newline = soul.firstIndex(of: "\n") {
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
        let body = String(soul[bodyStart..<bodyEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (line, body)
    }

    private static func sectionBody(_ section: AssistantPersona.Section) -> String {
        section.raw.replacingOccurrences(of: #"^## .*(?:\r?\n|$)"#, with: "",
                                         options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func section(_ title: String, _ body: String) -> String {
        "## \(title)\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    private static func separator(_ raw: String) -> String {
        guard let range = raw.range(of: #"\s*$"#, options: .regularExpression) else { return "" }
        return String(raw[range])
    }
}
