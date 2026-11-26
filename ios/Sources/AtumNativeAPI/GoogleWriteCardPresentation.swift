import Foundation

/// The Google write card as the phone draws it: a port of desktop's
/// `MatrixGoogleWriteCard` (`apps/desktop/src/matrix/google-write-card.tsx`,
/// #134) from one store projection to its question, field rows, actions and
/// settled line. Every word is a pinned copy key; the view resolves them.
///
/// - Only a card the store can decide offers Approve and Decline enabled.
///   A decision in flight shows "Approving…" or "Declining…" on its own button
///   and disables both. A reconciling card (an ambiguous answer the store is
///   still checking) keeps both disabled without a busy word, since nothing is
///   known to be in flight.
/// - A settled card folds to one line naming the request and how it ended.
///   Work speaks its own lines; an assistant's "expired" reads as closed and a
///   Work card's "closed" reads as expired, as on desktop.
/// - Desktop's Work provenance line says "From Work on this Mac". The phone is
///   never that Mac and no pinned key says "your Mac", so the phone omits the
///   line (docs/ports/w4-aa2-google-write-ui.md).
/// - Unsupported proposals have no question to ask, and desktop's strict reader
///   drops them, so they draw nothing.
public struct GoogleWriteCardPresentation: Equatable, Sendable {
    public enum Glyph: Equatable, Sendable { case mail, calendar, draft, mailbox, label }

    /// A field row's value. Times and sizes stay typed for the view to format.
    public enum Value: Equatable, Sendable {
        case text(String)
        /// An RFC 3339 timestamp from Shell, shown in the owner's locale.
        case time(String)
        case attachments([GoogleWriteAttachment])
    }

    public enum Block: Equatable, Sendable {
        /// One label and value row of the field grid.
        case row(label: String, value: Value)
        /// A quiet single line (the reply note).
        case note(String)
        /// Text exactly as written: line breaks kept, never markdown.
        case text(String)
        /// The quoted original, quiet, with its label and the truncation note.
        case quote(label: String, text: String, truncatedNote: String?)
    }

    public enum Action: Equatable, Sendable { case approve, decline }

    public enum Phase: Equatable, Sendable {
        /// The full card. `busy` names the button whose request is in flight.
        case open(canDecide: Bool, busy: Action?, retryLine: String?)
        /// One line naming the request and one line for how it ended.
        case settled(summary: String, line: String)
    }

    public let glyph: Glyph
    /// The card's question, which is also its accessible name.
    public let question: String
    public let blocks: [Block]
    public let phase: Phase

    public var isOpen: Bool {
        if case .open = phase { return true }
        return false
    }

    /// Nil for a proposal the phone cannot show faithfully.
    public init?(_ card: GoogleWriteProposalCard, resolve: (String) -> String) {
        self.init(source: card.source, kind: card.kind, lines: card.previewLines,
                  operation: card.mailboxOperation, state: card.state, canDecide: card.canDecide,
                  resolve: resolve)
    }

    public init?(source: GoogleWriteProposalSource, kind: GoogleWriteProposalKind, lines: [GoogleWritePreviewLine],
          operation: GoogleMailboxOperation?, state: GoogleWriteProposalState, canDecide: Bool,
          resolve: (String) -> String) {
        let work: Bool
        switch source {
        case .work: work = true
        case .assistant: work = false
        case .unsupported: return nil
        }
        guard let questionKey = Keys.question(kind, operation: operation), state != .unsupported else { return nil }
        let glyph: Glyph = switch kind {
        case .sendEmail: .mail
        case .createEvent, .updateEvent: .calendar
        case .createDraft, .updateDraft: .draft
        case .mailbox: .mailbox
        default: .label
        }
        let question = resolve(questionKey)
        self.glyph = glyph
        self.question = question
        blocks = Self.blocks(lines, resolve: resolve)

        switch state {
        case .pending:
            phase = .open(canDecide: canDecide, busy: nil, retryLine: nil)
        case .failedRetryable:
            phase = .open(canDecide: canDecide, busy: nil, retryLine: resolve(Keys.retry))
        case let .deciding(decision):
            phase = .open(canDecide: false, busy: decision == .approve ? .approve : .decline, retryLine: nil)
        case .reconciling:
            phase = .open(canDecide: false, busy: nil, retryLine: nil)
        case .approved, .declined, .superseded, .expired, .closed, .changed, .unsupported:
            phase = .settled(summary: Self.summary(lines, question: question),
                             line: resolve(Keys.settled(state, work: work)))
        }
    }

    // MARK: Blocks

    private static func blocks(_ lines: [GoogleWritePreviewLine], resolve: (String) -> String) -> [Block] {
        var blocks = [Block]()
        var quoteTruncated = false
        for line in lines { if case .quoteTruncated = line { quoteTruncated = true } }
        for line in lines {
            switch line {
            case let .to(list) where !list.isEmpty:
                blocks.append(.row(label: resolve(Keys.to), value: .text(list.joined(separator: ", "))))
            case let .cc(list) where !list.isEmpty:
                blocks.append(.row(label: resolve(Keys.cc), value: .text(list.joined(separator: ", "))))
            case let .bcc(list) where !list.isEmpty:
                blocks.append(.row(label: resolve(Keys.bcc), value: .text(list.joined(separator: ", "))))
            case let .subject(subject):
                blocks.append(.row(label: resolve(Keys.subject), value: .text(subject)))
            case let .forwarded(from, subject):
                let value = [from, subject].filter { !$0.isEmpty }.joined(separator: " · ")
                blocks.append(.row(label: resolve(Keys.forwarded), value: .text(value)))
            case let .attachments(files) where !files.isEmpty:
                blocks.append(.row(label: resolve(Keys.attachments), value: .attachments(files)))
            case .reply:
                blocks.append(.note(resolve(Keys.inReplyTo)))
            case let .body(text):
                blocks.append(.text(text))
            case let .quote(text) where !text.isEmpty:
                blocks.append(.quote(label: resolve(Keys.quote), text: text,
                                     truncatedNote: quoteTruncated ? resolve(Keys.truncated) : nil))
            case let .title(title):
                blocks.append(.row(label: resolve(Keys.title), value: .text(title)))
            case let .start(time):
                blocks.append(.row(label: resolve(Keys.start), value: .time(time)))
            case let .end(time):
                blocks.append(.row(label: resolve(Keys.end), value: .time(time)))
            case let .location(location):
                blocks.append(.row(label: resolve(Keys.location), value: .text(location)))
            case let .description(text):
                blocks.append(.text(text))
            case let .mailboxTarget(conversation):
                blocks.append(.row(label: resolve(Keys.appliesTo),
                                   value: .text(resolve(conversation ? Keys.conversation : Keys.oneEmail))))
            case let .labels(labels):
                blocks.append(.row(label: resolve(Keys.labels), value: .text(labels.joined(separator: ", "))))
            case let .name(name):
                blocks.append(.row(label: resolve(Keys.name), value: .text(name)))
            // Identifiers are for Shell, not the owner. An empty list, body
            // or quote draws nothing, and a cleared Calendar location or
            // description has no line on desktop (`draft.location && …`).
            default:
                continue
            }
        }
        // Desktop renders the grid first, then the reply note, the body and the quote.
        let rows = blocks.filter { if case .row = $0 { true } else { false } }
        return rows + blocks.filter { if case .row = $0 { false } else { true } }
    }

    /// Desktop `summary`: the subject of a message, the labels or the question
    /// (without its question mark) of a mailbox change, the label's name, or
    /// the event's title.
    private static func summary(_ lines: [GoogleWritePreviewLine], question: String) -> String {
        var labels: [String]?
        for line in lines {
            switch line {
            case let .subject(text), let .title(text), let .name(text): return text
            case let .labels(list): labels = list
            default: continue
            }
        }
        if let labels { return labels.joined(separator: ", ") }
        var trimmed = question
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("？") { trimmed.removeLast() }
        return trimmed
    }

    // MARK: Formatting

    /// Desktop `Intl.DateTimeFormat(locale, { dateStyle: 'medium', timeStyle: 'short' })`
    /// in the owner's zone. A value Shell sent that is not a timestamp shows as written.
    public static func time(_ value: String, locale: Locale, timeZone: TimeZone) -> String {
        let parser = ISO8601DateFormatter()
        var date = parser.date(from: value)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = parser.date(from: value)
        }
        guard let date else { return value }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Desktop `files`: "name · size" for each file, decimal units with at most one decimal.
    public static func attachments(_ files: [GoogleWriteAttachment], locale: Locale) -> String {
        files.map { "\($0.filename) · \(size($0.size, locale: locale))" }.joined(separator: ", ")
    }

    static func size(_ bytes: Int64, locale: Locale) -> String {
        let unit: UnitInformationStorage = bytes >= 1_000_000 ? .megabytes : bytes >= 1_000 ? .kilobytes : .bytes
        let value = Measurement(value: Double(bytes), unit: UnitInformationStorage.bytes).converted(to: unit)
        let number = NumberFormatter()
        number.locale = locale
        number.maximumFractionDigits = 1
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = .providedUnit
        formatter.unitStyle = .medium
        formatter.numberFormatter = number
        return formatter.string(from: value)
    }

    // MARK: Copy keys

    /// Full literal keys, so the pin scan sees every one the card can speak.
    public enum Keys {
        public static let approve = "src.matrix.google-write-card-copy.copies.approve"
        public static let decline = "src.matrix.google-write-card-copy.copies.decline"
        public static let approving = "src.matrix.google-write-card-copy.copies.approving"
        public static let declining = "src.matrix.google-write-card-copy.copies.declining"
        static let retry = "src.matrix.google-write-card-copy.copies.retry"

        static let to = "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.labels.to"
        static let cc = "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.labels.cc"
        static let bcc = "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.labels.bcc"
        static let subject = "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.labels.subject"
        static let forwarded = "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.labels.forwarded"
        static let attachments = "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.labels.attachments"
        static let inReplyTo = "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.labels.inReplyTo"
        static let title = "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.labels.title"
        static let start = "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.labels.start"
        static let end = "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.labels.end"
        static let location = "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.labels.location"
        static let quote = "src.matrix.google-write-card-copy.copies.labels.quote"
        static let truncated = "src.matrix.google-write-card-copy.copies.labels.truncated"
        static let name = "src.matrix.google-write-card-copy.copies.labels.name"
        static let labels = "src.matrix.google-write-card-copy.copies.labels.labels"
        static let appliesTo = "src.matrix.google-write-card-copy.copies.labels.appliesTo"
        static let conversation = "src.matrix.google-write-card-copy.copies.labels.conversation"
        static let oneEmail = "src.matrix.google-write-card-copy.copies.labels.oneEmail"

        static func question(_ kind: GoogleWriteProposalKind, operation: GoogleMailboxOperation?) -> String? {
            switch kind {
            case .sendEmail: "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.message.send-email"
            case .createEvent: "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.message.create-event"
            case .updateEvent: "shared.matrix-google-write-copy.MATRIX_GOOGLE_WRITE_COPY.message.update-event"
            case .createDraft: "src.matrix.google-write-card-copy.copies.question.create_draft"
            case .updateDraft: "src.matrix.google-write-card-copy.copies.question.update_draft"
            case .createLabel: "src.matrix.google-write-card-copy.copies.question.create_label"
            case .mailbox: operation.map(mailbox)
            case .unsupported: nil
            }
        }

        static func mailbox(_ operation: GoogleMailboxOperation) -> String {
            switch operation {
            case .archive: "src.matrix.google-write-card-copy.copies.mailbox.archive"
            case .unarchive: "src.matrix.google-write-card-copy.copies.mailbox.unarchive"
            case .markRead: "src.matrix.google-write-card-copy.copies.mailbox.mark_read"
            case .markUnread: "src.matrix.google-write-card-copy.copies.mailbox.mark_unread"
            case .star: "src.matrix.google-write-card-copy.copies.mailbox.star"
            case .unstar: "src.matrix.google-write-card-copy.copies.mailbox.unstar"
            case .trash: "src.matrix.google-write-card-copy.copies.mailbox.trash"
            case .untrash: "src.matrix.google-write-card-copy.copies.mailbox.untrash"
            case .addLabels: "src.matrix.google-write-card-copy.copies.mailbox.add_labels"
            case .removeLabels: "src.matrix.google-write-card-copy.copies.mailbox.remove_labels"
            }
        }

        /// Desktop: `work ? copy.work[closed → expired] : copy[expired → closed]`.
        static func settled(_ state: GoogleWriteProposalState, work: Bool) -> String {
            switch (state, work) {
            case (.approved, false): "src.matrix.google-write-card-copy.copies.approved"
            case (.declined, false): "src.matrix.google-write-card-copy.copies.declined"
            case (.superseded, false): "src.matrix.google-write-card-copy.copies.superseded"
            case (.changed, false): "src.matrix.google-write-card-copy.copies.changed"
            case (_, false): "src.matrix.google-write-card-copy.copies.closed"
            case (.approved, true): "src.matrix.google-write-card-copy.copies.work.approved"
            case (.declined, true): "src.matrix.google-write-card-copy.copies.work.declined"
            case (.superseded, true): "src.matrix.google-write-card-copy.copies.work.superseded"
            case (.changed, true): "src.matrix.google-write-card-copy.copies.work.changed"
            case (_, true): "src.matrix.google-write-card-copy.copies.work.expired"
            }
        }

        /// Every key the card can speak, for the pin test.
        static var all: [String] {
            let kinds: [GoogleWriteProposalKind] = [.sendEmail, .createEvent, .updateEvent, .createDraft,
                                                    .updateDraft, .createLabel]
            let states: [GoogleWriteProposalState] = [.approved, .declined, .superseded, .changed, .closed, .expired]
            return [approve, decline, approving, declining, retry, to, cc, bcc, subject, forwarded, attachments,
                    inReplyTo, title, start, end, location, quote, truncated, name, labels, appliesTo,
                    conversation, oneEmail]
                + kinds.compactMap { question($0, operation: nil) }
                + [GoogleMailboxOperation.archive, .unarchive, .markRead, .markUnread, .star, .unstar, .trash,
                   .untrash, .addLabels, .removeLabels].map(mailbox)
                + states.flatMap { [settled($0, work: false), settled($0, work: true)] }
        }
    }
}
