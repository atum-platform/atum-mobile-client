import Foundation

/// A Home-row preview without display copy (S2 §3.2.2). The screen resolves
/// `Value` and `Prefix` through the generated copy catalog.
public enum RowPreview {
    public enum Prefix: Equatable, Codable, Sendable {
        case none
        case currentUser
        case sender(String)
    }

    public enum Value: Equatable, Codable, Sendable {
        case text(String)
        case photo
        case video
        case audio
        case file(name: String?)
        case sticker
        case redacted
        case waitingForDecryption
        case invitation
        case appNotice(String)
        case empty
    }

    public enum SendState: Equatable, Codable, Sendable { case sent, sending, cannotBeSent }

    public struct Display: Equatable, Codable, Sendable {
        public var prefix: Prefix
        public var value: Value
        public var sendState: SendState

        public init(prefix: Prefix, value: Value, sendState: SendState) {
            self.prefix = prefix
            self.value = value
            self.sendState = sendState
        }
    }

    /// A delivery-outcome notice is never a chat's preview. The app bots post
    /// the uncertain-delivery copy as an `m.notice` (usually two lines,
    /// Vietnamese and English) that names support; the row keeps the last real
    /// message instead so a person never reads a delivery warning as if
    /// someone had said it.
    public static func suppressesPreview(body: String, isOwn: Bool,
                                         isNotice: Bool = false) -> Bool {
        guard !isOwn else { return false }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard isNotice || lines.count == 2 else { return false }
        return lines.contains {
            $0.localizedCaseInsensitiveContains("support@atumplatform.com")
        }
    }

    public enum Content: Equatable, Sendable {
        case text(String)
        case image
        case video
        case audio
        case file(name: String?)
        case sticker
        case redacted
        case undecryptable
        /// A bot notice may carry exactly two localized lines; only the line
        /// matching the phone language is shown.
        case appNotice([LocalizedLine])
        case none
    }

    public struct LocalizedLine: Equatable, Sendable {
        public var localeIdentifier: String
        public var text: String

        public init(localeIdentifier: String, text: String) {
            self.localeIdentifier = localeIdentifier
            self.text = text
        }
    }

    public struct Event: Equatable, Sendable {
        public var content: Content
        public var isOwn: Bool
        public var senderName: String?
        public var roomKind: RoomKind
        public var isInvitation: Bool
        public var sendState: SendState

        public init(content: Content, isOwn: Bool = false, senderName: String? = nil,
                    roomKind: RoomKind, isInvitation: Bool = false, sendState: SendState = .sent) {
            self.content = content
            self.isOwn = isOwn
            self.senderName = senderName
            self.roomKind = roomKind
            self.isInvitation = isInvitation
            self.sendState = sendState
        }
    }

    public static func display(for event: Event, locale: Locale) -> Display {
        if event.isInvitation { return Display(prefix: .none, value: .invitation, sendState: .sent) }
        let value = value(for: event.content, locale: locale)
        let prefix: Prefix
        switch value {
        case .redacted, .waitingForDecryption, .invitation, .empty: prefix = .none
        default:
            if event.isOwn { prefix = .currentUser }
            else if event.roomKind == .group, let name = event.senderName, !name.isEmpty { prefix = .sender(name) }
            else { prefix = .none }
        }
        return Display(prefix: prefix, value: value, sendState: event.sendState)
    }

    private static func value(for content: Content, locale: Locale) -> Value {
        switch content {
        case let .text(body): return body.isEmpty ? .empty : .text(flattenMarkdown(body))
        case .image: return .photo
        case .video: return .video
        case .audio: return .audio
        case let .file(name): return .file(name: name?.isEmpty == true ? nil : name)
        case .sticker: return .sticker
        case .redacted: return .redacted
        case .undecryptable: return .waitingForDecryption
        case let .appNotice(lines):
            guard lines.count == 2 else { return .empty }
            // S1's exact two-line bot notice contract is Vietnamese first,
            // English second. Every non-Vietnamese app language uses the
            // English line; it must not blank Japanese or Chinese Home rows.
            let wanted = locale.language.languageCode?.identifier == "vi" ? "vi" : "en"
            let chosen = lines.first {
                String($0.localeIdentifier.split(separator: "-").first ?? "").lowercased() == wanted
            }
            return chosen.map { .appNotice($0.text) } ?? .empty
        case .none: return .empty
        }
    }

    /// A small, deliberately conservative Markdown flattening pass for roster
    /// summaries. Rich rendering remains the chat's job.
    public static func flattenMarkdown(_ source: String) -> String {
        var text = source.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: "\r", with: " ")
        let links = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\([^)]*\)"#)
        let range = NSRange(text.startIndex..., in: text)
        text = links.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        text.removeAll { "*_~`#>".contains($0) }
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
