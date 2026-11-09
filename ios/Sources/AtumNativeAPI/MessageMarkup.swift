import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Prevent a decrypted message from triggering unauthenticated URL image loads.
public enum MessageMarkup {
    public static func parse(_ input: String) -> AttributedString {
        var value = (try? AttributedString(markdown: input, options: .init(interpretedSyntax: .full))) ?? AttributedString(input)
        sanitize(&value)
        return value
    }

    /// Bot API without `parse_mode` is literal text, not phone-inferred
    /// Markdown. Safe bare web addresses retain the ordinary chat behavior.
    public static func parsePlain(_ input: String) -> AttributedString {
        var value = AttributedString(input)
        sanitize(&value)
        return value
    }

    /// Render only the platform's bounded Matrix-HTML subset after exact
    /// `io.atum.bot_api/1` metadata authorized the message. Unsupported HTML
    /// degrades to the literal fallback body; it is never inserted into a web
    /// view and no image/resource tag reaches Foundation's HTML reader.
    public static func parseBotAPIHTML(_ input: String, fallback: String) -> AttributedString {
        guard safeBotAPIHTML(input),
              let parsed = try? NSAttributedString(
                  data: Data(input.utf8),
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                  ],
                  documentAttributes: nil
              ) else { return parsePlain(fallback) }

        var value = AttributedString()
        parsed.enumerateAttributes(in: NSRange(location: 0, length: parsed.length)) { attributes, range, _ in
            var fragment = AttributedString(parsed.attributedSubstring(from: range).string)
            var intent: InlinePresentationIntent = []
            let traits = fontTraits(attributes[.font])
            if traits.bold { intent.insert(.stronglyEmphasized) }
            if traits.italic { intent.insert(.emphasized) }
            if traits.monospaced { intent.insert(.code) }
            if ((attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0 {
                intent.insert(.strikethrough)
            }
            if !intent.isEmpty { fragment.inlinePresentationIntent = intent }
            if let link = safeLink(attributes[.link]) { fragment.link = link }
            value.append(fragment)
        }
        sanitize(&value)
        return value
    }

    private static func sanitize(_ value: inout AttributedString) {
        for run in Array(value.runs) {
            if run.imageURL != nil { value[run.range].imageURL = nil }
            if let link = run.link, !canOpen(link) { value[run.range].link = nil }
        }
        linkBareWebAddresses(in: &value)
    }
    public static func canOpen(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    /// Bare web addresses in the text ("xem tại https://atumplatform.com")
    /// become links, as in every messaging app; the chat's `LinkPolicy`
    /// decides what a tap does. Only http(s) addresses outside code and
    /// outside existing links; e-mail addresses and phone numbers stay text
    /// (data detectors are deferred, plan §6.2).
    private static func linkBareWebAddresses(in value: inout AttributedString) {
        guard String(value.characters).contains("://") || String(value.characters).contains("www."),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        // One block (paragraph, list item, code block) at a time: Foundation
        // joins blocks without a separator, so two addresses in adjacent
        // blocks must not read as one.
        var targets: [(Range<AttributedString.Index>, URL)] = []
        for (intent, blockRange) in value.runs[\.presentationIntent] {
            if intent?.components.contains(where: { isCodeBlock($0.kind) }) == true { continue }
            let block = value[blockRange]
            let plain = String(block.characters)
            for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
                guard let url = match.url, canOpen(url), let range = Range(match.range, in: plain) else { continue }
                let lower = plain.distance(from: plain.startIndex, to: range.lowerBound)
                let length = plain.distance(from: range.lowerBound, to: range.upperBound)
                let start = value.characters.index(blockRange.lowerBound, offsetBy: lower)
                let end = value.characters.index(start, offsetBy: length)
                let target = start..<end
                let isCodeOrLinked = value[target].runs.contains { run in
                    run.link != nil || run.inlinePresentationIntent?.contains(.code) == true
                }
                if !isCodeOrLinked { targets.append((target, url)) }
            }
        }
        for (target, url) in targets { value[target].link = url }
    }

    private static func isCodeBlock(_ kind: PresentationIntent.Kind) -> Bool {
        if case .codeBlock = kind { return true }
        return false
    }

    private static func safeLink(_ value: Any?) -> URL? {
        let url: URL?
        switch value {
        case let value as URL: url = value
        case let value as String: url = URL(string: value)
        default: url = nil
        }
        guard let url, canOpen(url), url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// The host emits only these tags. Validate the complete tag stream before
    /// asking the system HTML reader to interpret it; text must escape angle
    /// brackets, and only a bounded href or spoiler attribute is accepted.
    private static func safeBotAPIHTML(_ input: String) -> Bool {
        guard !input.isEmpty, input.utf16.count <= 16_384 else { return false }
        let expression = try! NSRegularExpression(pattern: "<[^>]*>")
        let full = NSRange(input.startIndex..., in: input)
        var cursor = input.startIndex
        for match in expression.matches(in: input, range: full) {
            guard let range = Range(match.range, in: input) else { return false }
            let text = input[cursor..<range.lowerBound]
            guard !text.contains("<"), !text.contains(">") else { return false }
            let tag = String(input[range])
            guard safeBotAPITag(tag) else { return false }
            cursor = range.upperBound
        }
        let tail = input[cursor...]
        return !tail.contains("<") && !tail.contains(">")
    }

    private static func safeBotAPITag(_ tag: String) -> Bool {
        if tag.range(of: "^</?(?:b|blockquote|code|del|em|i|p|pre|s|strong|u)>$",
                     options: .regularExpression) != nil { return true }
        if tag.range(of: "^<br ?/?>$", options: .regularExpression) != nil { return true }
        if tag == "<span data-mx-spoiler>" || tag == "</span>" { return true }
        guard tag.hasPrefix("<a href=\""), tag.hasSuffix("\">") else {
            return tag == "</a>"
        }
        let start = tag.index(tag.startIndex, offsetBy: "<a href=\"".count)
        let end = tag.index(tag.endIndex, offsetBy: -2)
        let escaped = String(tag[start..<end])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        return escaped.utf16.count <= 4_096 && safeLink(escaped) != nil
    }

    private struct FontTraits {
        var bold = false
        var italic = false
        var monospaced = false
    }

    private static func fontTraits(_ value: Any?) -> FontTraits {
        #if canImport(UIKit)
        guard let font = value as? UIFont else { return FontTraits() }
        let traits = font.fontDescriptor.symbolicTraits
        return FontTraits(bold: traits.contains(.traitBold),
                          italic: traits.contains(.traitItalic),
                          monospaced: traits.contains(.traitMonoSpace))
        #elseif canImport(AppKit)
        guard let font = value as? NSFont else { return FontTraits() }
        let traits = font.fontDescriptor.symbolicTraits
        return FontTraits(bold: traits.contains(.bold),
                          italic: traits.contains(.italic),
                          monospaced: traits.contains(.monoSpace))
        #else
        return FontTraits()
        #endif
    }
}
