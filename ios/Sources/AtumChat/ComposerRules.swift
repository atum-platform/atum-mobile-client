import Foundation

/// The composer's decisions on plain values (plan B6, B11, B20, B21, B25,
/// B26, §3.4). The view draws what these return; the store owns the draft,
/// the reply target and the edit target.
public enum ComposerRules {
    /// B25: the field grows from one to six lines, then scrolls inside.
    public static let maximumLines = 6

    /// B25: the send circle shows only for a draft with something besides
    /// whitespace. The store applies the same test before it sends.
    public static func canSend(_ draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The `+` at the leading edge of the controls row. Every chat kind has
    /// one except while a message is being edited; an app bot has it only when
    /// its app offers a composer action (apps are not known to accept files).
    public static func showsAddButton(kind: RoomKind, isEditing: Bool, hasAppComposerAction: Bool) -> Bool {
        guard !isEditing else { return false }
        switch kind {
        case .person, .group, .assistant: return true
        case .appBot: return hasAppComposerAction
        }
    }

    /// Whether the `+` menu offers Photo Library and Choose File: every kind
    /// that has a `+` except an app bot, whose menu is its one app action.
    public static func addMenuOffersFiles(kind: RoomKind) -> Bool { kind != .appBot }

    /// The mic sits in the controls row of every chat except while editing.
    public static func showsMicButton(isEditing: Bool) -> Bool { !isEditing }

    /// The `@` member picker is for chats with another human to mention: a
    /// people chat and a group (a company channel is a group). Assistant and
    /// app-bot rooms have no one to pick.
    public static func offersMentions(kind: RoomKind) -> Bool { kind == .person || kind == .group }

    /// B21: the reply chip for `replyTarget` (an event ID, the store's
    /// `replyTarget`), or nil when there is none. The original is looked up
    /// in the loaded rows; one no longer loaded still shows a chip, unnamed
    /// and without a preview, because the reply still goes out.
    public static func replyChip(replyTarget eventID: String?, rows: [ChatRow], kind: RoomKind,
                                 roomTitle: String) -> ComposerChip? {
        guard let eventID else { return nil }
        guard let item = rows.first(where: { $0.item.eventID == eventID })?.item else {
            return ComposerChip(who: .unnamed, preview: .none)
        }
        return ComposerChip(who: who(item, kind: kind, roomTitle: roomTitle), preview: preview(item))
    }

    /// B20: the edit chip for `editTarget` (a row ID), with the message
    /// being changed as its preview.
    public static func editChip(editTarget itemID: String?, rows: [ChatRow]) -> ComposerChip? {
        guard let itemID else { return nil }
        let item = rows.first { $0.id == itemID }?.item
        return ComposerChip(who: .me, preview: item.map(preview) ?? .none)
    }

    /// B11: the words of the people line above the composer. Two or three
    /// names are joined in the app's language, as desktop's
    /// `Intl.ListFormat` conjunction does ("Lan và Minh", "Lan, Minh và
    /// Hoa"); the sentence around them is exported copy.
    public static func typingCopy(_ line: TypingLine, locale: Locale) -> TypingLineCopy? {
        switch line {
        case .nobody:
            return nil
        case let .names(names):
            guard let first = names.first else { return nil }
            guard names.count > 1 else { return .one(first) }
            let formatter = ListFormatter()
            formatter.locale = locale
            return .some(formatter.string(from: names) ?? names.joined(separator: ", "))
        case .many:
            return .many
        }
    }

    private static func who(_ item: ChatItem, kind: RoomKind, roomTitle: String) -> ComposerChip.Who {
        if item.isOwn { return .me }
        if let name = item.senderName, !name.isEmpty { return .named(name) }
        switch kind {
        // One other sender: the room's title is their name.
        case .assistant, .appBot, .person:
            return roomTitle.isEmpty ? .unnamed : .named(roomTitle)
        // Never a raw Matrix ID.
        case .group:
            return .unnamed
        }
    }

    private static func preview(_ item: ChatItem) -> ComposerChip.Preview {
        switch item.kind {
        case .image:
            return .photo
        case let .file(name):
            return .file(name)
        case .message, .notice:
            let line = item.body.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return line.map { .text($0) } ?? .none
        default:
            return .none
        }
    }
}

/// The reply or edit chip inside the composer pill (B20, B21, §3.4).
public struct ComposerChip: Equatable, Sendable {
    public enum Who: Equatable, Sendable {
        /// My own message ("Bạn").
        case me
        case named(String)
        /// No usable name (a group member without a profile, or an original
        /// that is not loaded): the chip says "Trả lời" alone.
        case unnamed
    }

    /// One quiet line of the original.
    public enum Preview: Equatable, Sendable {
        /// The first non-empty line of the text.
        case text(String)
        /// An image box ("Ảnh", exported copy).
        case photo
        /// A file row: its name.
        case file(String)
        case none
    }

    public var who: Who
    public var preview: Preview

    public init(who: Who, preview: Preview) {
        self.who = who
        self.preview = preview
    }
}

/// Which exported sentence the people line uses (B11), with its argument.
public enum TypingLineCopy: Equatable, Sendable {
    /// "{name} đang soạn tin…"
    case one(String)
    /// "{names} đang soạn tin…", the names already joined.
    case some(String)
    /// "Nhiều người đang soạn tin…"
    case many
}

/// B26: one warning haptic when a send of mine fails while I am in the chat.
/// Failures already there when the chat opens (or when a renewed timeline
/// rebuilds the rows) are taken as the baseline and never buzz; a message
/// that is retried and fails again buzzes again.
public struct SendFailureWatch: Equatable, Sendable {
    private var failed: Set<String> = []
    private var generation: UInt64?

    public init() {}

    /// Feeds one published snapshot; true when the warning should play.
    public mutating func observe(_ snapshot: Snapshot) -> Bool {
        let current = Set(snapshot.rows.lazy.filter { $0.delivery == .failed }.map(\.id))
        defer {
            failed = current
            generation = snapshot.generation
        }
        guard generation == snapshot.generation, snapshot.change != .reset else { return false }
        return !current.subtracting(failed).isEmpty
    }
}
