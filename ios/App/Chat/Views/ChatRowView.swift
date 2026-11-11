import AtumChat
import SwiftUI

/// One display row (plan §2.2): picks the row view for the row's kind and
/// the room's kind (§2.7), and adds the spacing and the centred time label
/// grouping decided (B16). `Equatable`, so an unchanged row is skipped.
///
/// The event rows carry WS3's long-press menu (B20–B22, `chatRowMenu`): on
/// a bubble, the bubble; on an answer, its quote and text.
struct ChatRowView: View, Equatable {
    let row: ChatRow
    let kind: RoomKind
    let roomTitle: String
    let parsedBody: AttributedString?
    /// The newest answer in an assistant or app chat carries its actions.
    var isLatestAnswer = false
    /// HC-6: the open search's matches in this row's words, if any.
    var searchHighlight: ChatSearchHighlight? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let time = row.grouping.timeLabel {
                TimeLabelRow(date: time)
            }
            content
        }
        .padding(.top, topSpacing)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch row.item.kind {
        case .message, .image, .file, .placeholder:
            MessageBubbleRow(row: row, kind: kind, roomTitle: roomTitle, parsedBody: parsedBody,
                             isLatestAnswer: isLatestAnswer, searchHighlight: searchHighlight)
        case .notice:
            if row.item.isProgressLine || Self.isRetiredWaitLine(row.item) {
                WorkingLineRow(row: row)
            } else {
                NoticeRow(row: row, kind: kind, parsedBody: parsedBody)
            }
        case let .dayDivider(day):
            DayDividerRow(day: day)
        case .readMarker:
            ReadMarkerRow()
        case .timelineStart:
            TimelineStartRow()
        case let .typing(names):
            TypingRow(names: names)
        case .loadingEarlier:
            LoadingEarlierRow()
        case .roomState:
            EmptyView() // never projected (§2.3 rule 4)
        }
    }

    /// Tighter inside a sender run, normal between runs (B16).
    private var topSpacing: CGFloat {
        switch row.item.kind {
        case .message, .image, .file, .placeholder:
            switch row.grouping.position {
            case .middle?, .last?: return 2
            default: return 14
            }
        case .notice: return 10
        case .dayDivider: return 22
        case .readMarker: return 14
        case .timelineStart: return 0
        case .typing: return 12
        case .loadingEarlier: return 4
        case .roomState: return 0
        }
    }
}

extension View {
    /// B20: the long-press menu (WS3's `messageMenu`) on an event row's
    /// content, from what the chat screen put in the environment: the copy,
    /// the row actions (with the reaction tick and the link gate), my user ID
    /// for the palette's marks and the presenter for its sheets. Rows with
    /// nothing to act on (notices, placeholders, virtual rows) get no menu.
    func chatRowMenu(_ row: ChatRow, kind: RoomKind, roomTitle: String,
                     parsedBody: AttributedString?) -> some View {
        modifier(ChatRowMenu(row: row, kind: kind, roomTitle: roomTitle, parsedBody: parsedBody))
    }
}

private struct ChatRowMenu: ViewModifier {
    let row: ChatRow
    let kind: RoomKind
    let roomTitle: String
    let parsedBody: AttributedString?

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatActions) private var actions
    @Environment(\.chatOwnUserID) private var ownUserID
    @Environment(\.chatNonPersonSenders) private var nonPersonSenders
    @Environment(\.messageActions) private var presenter

    func body(content: Content) -> some View {
        if let theme, let presenter {
            content.messageMenu(row: row, kind: kind, roomTitle: roomTitle,
                                ownUserID: ownUserID.isEmpty ? nil : ownUserID,
                                nonPersonSenders: nonPersonSenders, parsedBody: parsedBody,
                                design: theme.design, actions: actions, presenter: presenter)
        } else {
            content
        }
    }
}

/// Which look an event row gets (§9.1: agent chat like a person's).
enum ChatRowStyle {
    /// Flipped by the owner's 2026-10-20 direction: agent and bot messages
    /// are left bubbles like a person's, never bare full-width answers.
    static func isAnswer(_ item: ChatItem, kind: RoomKind) -> Bool {
        false
    }
}

extension ChatRowView {
    /// A live retired fixed wait line (older builds, no marker) is working
    /// text too: the muted row, never a centred notice. Ended ones never
    /// reach a view (`TransientLines`).
    static func isRetiredWaitLine(_ item: ChatItem) -> Bool {
        TransientLines.retiredWaitLines.contains(item.body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum ChatLayout {
    static let sideMargin: CGFloat = 16
    /// Bubbles are at most 78% of the row (desktop geometry, B17), and hug
    /// their content below that (`BubbleGeometry`, `BubbleStack`).
    static let bubbleFraction = CGFloat(BubbleGeometry.maxFraction)
    static let bubbleRadius: CGFloat = 20
    /// The inner corner between two bubbles of one run.
    static let runRadius: CGFloat = 6
}

/// Words for rows: sender names and what a row says when read aloud.
@MainActor
enum ChatRowText {
    /// The sender as the chat shows it: "Bạn" for me, the profile name, or
    /// the room's title (an agent, a bot or the other person); never a raw
    /// Matrix ID.
    static func senderName(_ row: ChatRow, roomTitle: String, copy: ChatCopy) -> String {
        if row.item.isOwn { return copy.text(.you) }
        if let name = row.item.senderName, !name.isEmpty { return name }
        return roomTitle
    }

    /// The row's content in words (VoiceOver, the incoming announcement).
    static func spokenBody(_ row: ChatRow, copy: ChatCopy) -> String {
        switch row.item.kind {
        case .message, .notice: return row.item.body
        case .image: return copy.text(.photo)
        case let .file(name): return name.isEmpty ? copy.text(.file) : name
        case let .placeholder(reason): return placeholder(reason, copy: copy)
        default: return ""
        }
    }

    /// B19: one line per reason, from the exported copy.
    static func placeholder(_ reason: ChatItem.PlaceholderReason, copy: ChatCopy) -> String {
        switch reason {
        case .redacted: copy.text(.redacted)
        case .undecryptableOldHistory: copy.text(.undecryptableOldHistory)
        case .undecryptable: copy.text(.undecryptable)
        case .unsupported: copy.text(.unsupported)
        }
    }

    /// B7: the delivery mark in words; nil when it shows nothing.
    static func delivery(_ mark: DeliveryMark, kind: RoomKind, copy: ChatCopy) -> String? {
        switch mark {
        case .none: nil
        case .sending: copy.text(.pending)
        case .failed: copy.text(.notSent)
        case .sent: copy.text(.sent)
        case let .seen(readerCount):
            kind == .group && readerCount > 0 ? copy.text(.seenBy, .number(Int64(readerCount))) : copy.text(.seen)
        }
    }

    /// B16: every event row's accessibility label carries sender, time and
    /// delivery state with the content, as separate parts the system joins
    /// (`RowSpeech`), so no separator is written here (WS-C inventory).
    static func speech(_ row: ChatRow, kind: RoomKind, roomTitle: String, theme: ChatTheme) -> RowSpeech {
        let body = spokenBody(row, copy: theme.copy)
        let edited = row.item.isEdited && (kind == .person || kind == .group || row.item.isOwn)
        return RowSpeech(sender: senderName(row, roomTitle: roomTitle, copy: theme.copy),
                         time: theme.time(row.item.timestamp),
                         body: body.isEmpty ? nil : body,
                         edited: edited ? theme.copy.text(.edited) : nil,
                         delivery: delivery(row.delivery, kind: kind, copy: theme.copy),
                         noAnswer: nil)
    }
}

/// The parts of one row's accessibility label, in reading order.
struct RowSpeech: Equatable {
    var sender: String
    var time: String
    var body: String?
    var edited: String?
    var delivery: String?
    var noAnswer: String?
}

extension View {
    /// One accessibility element whose label is the row's parts, joined by
    /// the system (`accessibilityLabel(content:)`), never by a separator
    /// written in Swift.
    func rowSpeech(_ speech: RowSpeech) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel { _ in
                Text(verbatim: speech.sender)
                Text(verbatim: speech.time)
                if let body = speech.body { Text(verbatim: body) }
                if let edited = speech.edited { Text(verbatim: edited) }
                if let delivery = speech.delivery { Text(verbatim: delivery) }
                if let noAnswer = speech.noAnswer { Text(verbatim: noAnswer) }
            }
    }
}

/// Places one bubble at most `fraction` of the row wide, on the leading or
/// trailing side (B17: 78%). A `Layout`, so no geometry reader sits in the
/// lazy stack.
struct BubbleColumn: Layout {
    var trailing: Bool
    var fraction: CGFloat = ChatLayout.bubbleFraction

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 360
        let height = subviews.map { $0.sizeThatFits(childProposal(width)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let size = subview.sizeThatFits(childProposal(bounds.width))
            let x = trailing ? bounds.maxX - size.width : bounds.minX
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
        }
    }

    private func childProposal(_ width: CGFloat) -> ProposedViewSize {
        ProposedViewSize(width: (width * fraction).rounded(.down), height: nil)
    }
}

/// A bubble's parts stacked top to bottom, as wide as the widest part needs
// Preserve user-visible identity, state and recovery behavior across connection changes.
/// whole offered width as soon as one part is stretchy (a code block, a table,
/// a rule, a row of Bot API buttons), so one short line with a button would
/// fill the widest bubble. Here each part counts the narrower of its width at
/// the offered width and its natural width (`BubbleGeometry.hugWidth`), then
/// every part is laid out at the result, so stretchy parts fill the bubble the
/// text set. A `Layout`: no geometry feedback in the lazy transcript (G-scroll).
struct BubbleStack: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 0

    /// The width worked out for the last offered width: the transcript lays
    /// every row out eagerly, so each part is measured once per width, not on
    /// every pass. SwiftUI drops the cache when the parts change.
    struct Cache {
        var limit: CGFloat?
        var width: CGFloat?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = contentWidth(limit: proposal.width, subviews: subviews, cache: &cache)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        let gaps = spacing * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: heights.reduce(0, +) + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let width = bounds.width
        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let x: CGFloat
            switch alignment {
            case .center: x = bounds.minX + (width - size.width) / 2
            case .trailing: x = bounds.maxX - size.width
            default: x = bounds.minX
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, width),
                                                                              height: size.height))
            y += size.height + spacing
        }
    }

    private func contentWidth(limit: CGFloat?, subviews: Subviews, cache: inout Cache) -> CGFloat {
        if let width = cache.width, cache.limit == limit { return width }
        let natural = subviews.map { Double($0.sizeThatFits(.unspecified).width) }
        let width: CGFloat
        if let limit, limit.isFinite {
            let fitted = subviews.map { Double($0.sizeThatFits(ProposedViewSize(width: limit, height: nil)).width) }
            width = CGFloat(BubbleGeometry.hugWidth(fitted: fitted, natural: natural, limit: Double(limit)))
        } else {
            width = CGFloat(natural.max() ?? 0)
        }
        cache = Cache(limit: limit, width: width)
        return width
    }
}
