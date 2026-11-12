import AtumChat
import AtumNativeAPI
import SwiftUI

/// A bubble row (B16, B17, B19): my messages on the right in the Kit's
/// `bubble-own` (ink in light, a lifted grey in dark) with `on-bubble-own`
/// text, people's on the left on `surface` with `shadow-1`, with
/// first/middle/last corner shapes inside a sender run. A bubble hugs its
/// content and grows with longer text up to the widest bubble (the row less a
/// 48 pt far-side gap, `BubbleGeometry`), then wraps
// Preserve user-visible identity, state and recovery behavior across connection changes.
/// placeholders share it.
///
// Preserve user-visible identity, state and recovery behavior across connection changes.
/// assistant, an app) shows no face and no face gutter. A group shows the
/// sender's name above the first bubble of a run and the sender's face beside
/// the last one, aligned to its bottom; the run's other bubbles keep an empty
/// face-wide gutter so the run lines up (`RowGrouping.showsFace`).
///
/// Under the bubble: reaction chips (B22) and my delivery mark (B7, B8) or
/// the no-answer line (B10). A long press on the bubble opens the menu (B20).
///
/// VoiceOver reads the bubble as one element: sender, time, content and
/// delivery (B16), with an action per link. A reply's quote is its own
/// button inside the bubble, read after the message, as in answers (B21).
struct MessageBubbleRow: View {
    let row: ChatRow
    let kind: RoomKind
    let roomTitle: String
    let parsedBody: AttributedString?
    /// The newest answer in an assistant or app chat: copy sits under it.
    var isLatestAnswer = false
    /// HC-6: the open search's matches in this message.
    var searchHighlight: ChatSearchHighlight? = nil
    /// The agent may still be writing this message: it never folds.
    var isGrowing = false

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatActions) private var actions
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chatRoomFace) private var roomFace
    @Environment(\.chatMembers) private var members
    @Environment(\.chatFlatRuns) private var flat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatRowInteractions) private var interactions
    /// Bumped by the fold toggle: the session's fold book is not observed.
    @State private var foldTick = 0

    /// Mine sit on the right in a bubble, except in a team space's flat runs,
    /// where everyone's sit on the left.
    private var trailing: Bool { row.item.isOwn && !flat }

    /// The sender's face: beside the last bubble of an incoming run in a
    /// group, and at the top of a team space's flat run. Nil elsewhere.
    private var face: ChatFace? {
        guard flat ? row.grouping.position?.startsRun ?? true : showsAvatar else { return nil }
        return ChatFace.incoming(row.item, kind: kind, roomTitle: roomTitle,
                                 roomFace: roomFace, members: members)
    }

    /// Grouping decides (`RowGrouping.showsFace`): groups only, the run's
    /// last bubble only, never mine.
    private var showsAvatar: Bool { !trailing && row.grouping.showsFace }
    /// The face gutter is kept for every incoming bubble of a group, drawn
    /// or not, so a run's bubbles line up. A 1:1 chat has none: its bubbles
    /// start at the side margin.
    private var reservesAvatar: Bool { !trailing && kind.showsSenderFace }
    private var avatarSlot: CGFloat { reservesAvatar ? Self.avatarSize + Self.avatarGap : 0 }

    /// Links in a person's message (mine show literally, B6), for VoiceOver.
    private var links: [(text: String, url: URL)] {
        guard !trailing, case .message = row.item.kind else { return [] }
        return MarkdownBlocks.links(in: parsedBody ?? MessageMarkup.parse(row.item.markdownBody))
    }

    var body: some View {
        if let theme, flat {
            flatRun(theme)
        } else if let theme {
            VStack(alignment: trailing ? .trailing : .leading, spacing: 4) {
                if row.showsSender {
                    SenderLine(name: ChatRowText.senderName(row, roomTitle: roomTitle, copy: theme.copy),
                               showsAvatar: false, avatarKind: .person)
                        .padding(.leading, avatarSlot)
                }
                BubbleWithAvatarLayout(trailing: trailing, reservesAvatar: reservesAvatar,
                                       showsAvatar: showsAvatar,
                                       avatarSize: Self.avatarSize, gap: Self.avatarGap) {
                    bubble(theme)
                        .chatRowMenu(row, kind: kind, roomTitle: roomTitle, parsedBody: parsedBody)
                    if showsAvatar, let face {
                        ChatFaceView(face: face, size: Self.avatarSize)
                    }
                }
                if !row.item.reactions.isEmpty {
                    ReactionChips(row: row, trailing: trailing)
                        .padding(.leading, avatarSlot)
                }
                if DeliveryLine.shows(row, isLatestAnswer: isLatestAnswer && !trailing, flat: false) {
                    DeliveryLine(row: row, kind: kind, isLatestAnswer: isLatestAnswer && !trailing)
                        .padding(.leading, avatarSlot)
                }
            }
            .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(row.accessibilityID)
        }
    }

    /// FlowPhone3 › Team channel: a 36 pt round face, the bold name and the
    /// time open a run; the text follows edge to edge in `.body` ink, with no
    /// bubble; later lines of the run sit under the name. Files and images
    /// keep their cards.
    private func flatRun(_ theme: ChatTheme) -> some View {
        let startsRun = row.grouping.position?.startsRun ?? true
        let kit = theme.design.kit
        return HStack(alignment: .top, spacing: Self.flatGap) {
            if let face {
                ChatFaceView(face: face, size: Self.flatFace)
            } else {
                Color.clear.frame(width: Self.flatFace, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                if startsRun {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: flatName(theme))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(kit.color(.ink, scheme: scheme))
                            .lineLimit(1)
                        Text(verbatim: theme.time(row.item.timestamp))
                            .font(.caption2)
                            .foregroundStyle(kit.color(.ink3, scheme: scheme))
                    }
                    .accessibilityHidden(true)
                }
                flatContent(theme)
                    .chatRowMenu(row, kind: kind, roomTitle: roomTitle, parsedBody: parsedBody)
                if !row.item.reactions.isEmpty {
                    ReactionChips(row: row, trailing: false)
                }
                if DeliveryLine.shows(row, isLatestAnswer: false, flat: true) {
                    DeliveryLine(row: row, kind: kind)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(row.accessibilityID)
    }

    /// The run's name: the member's own name (mine too), as Slack shows it.
    private func flatName(_ theme: ChatTheme) -> String {
        if let name = face?.name, !name.isEmpty { return name }
        return ChatRowText.senderName(row, roomTitle: roomTitle, copy: theme.copy)
    }

    @ViewBuilder private func flatContent(_ theme: ChatTheme) -> some View {
        let speech = ChatRowText.speech(row, kind: kind, roomTitle: roomTitle, theme: theme)
        switch row.item.kind {
        case .message:
            VStack(alignment: .leading, spacing: 6) {
                if row.showsQuote {
                    QuoteView(row: row, roomTitle: roomTitle)
                }
                let fold = foldState()
                messageText(theme)
                    .messageFold(fold.folded, lineHeight: foldLineHeight)
                    .spokenMessage(speech, links: links, actions: actions)
                    .accessibilityIdentifier("message.body.\(row.id)")
                    .accessibilitySortPriority(1)
                if fold.showsToggle {
                    foldToggle(theme, folded: fold.folded)
                }
                botAPIKeyboard(theme)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            bubble(theme)
        }
    }

    static let flatFace: CGFloat = 36
    static let flatGap: CGFloat = 10

    @ViewBuilder private func bubble(_ theme: ChatTheme) -> some View {
        let shape = Self.shape(position: row.grouping.position, trailing: trailing)
        let kit = theme.design.kit
        let fill = kit.color(trailing ? .bubbleOwn : .surface, scheme: scheme)
        let speech = ChatRowText.speech(row, kind: kind, roomTitle: roomTitle, theme: theme)
        switch row.item.kind {
        case let .image(width, height):
            if row.item.media != nil {
                let size = ImageBox.size(width: width, height: height)
                VStack(alignment: .leading, spacing: 0) {
                    MediaImageContent(row: row, width: size.width, height: size.height,
                                      fill: fill, shape: AnyShape(shape),
                                      roomTitle: roomTitle, kind: kind)
                    if !row.item.body.isEmpty {
                        mediaCaption(theme)
                            .accessibilityHidden(true)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 10)
                    }
                    botAPIKeyboard(theme)
                }
                .frame(width: row.item.body.isEmpty ? size.width : max(size.width, 200), alignment: .leading)
                .background(fill, in: shape)
                .clipShape(shape)
            } else {
                ImageBox(width: width, height: height, fill: fill, shape: shape)
                    .rowSpeech(speech)
            }
        case let .file(name):
            // Kit file card (STYLE §10): `surface` with `shadow-1` on either
            // side, a 40 pt `fill-quiet` tile; never the ink bubble.
            let card = kit.color(.surface, scheme: scheme)
            if row.item.media != nil {
                MediaFileContent(row: row, fill: card,
                                 tileFill: kit.color(.fillQuiet, scheme: scheme),
                                 shape: AnyShape(shape), roomTitle: roomTitle, roomKind: kind)
                    .atumKitElevation(.one, in: shape)
            } else {
                FileCard(name: name)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(card, in: shape)
                    .atumKitElevation(.one, in: shape)
                    .rowSpeech(speech)
            }
        case let .placeholder(reason):
            // Never cut short: at the largest text sizes the line wraps and
            // keeps its meaning (B19).
            Text(ChatRowText.placeholder(reason, copy: theme.copy))
                .font(.body.italic())
                .foregroundStyle(theme.quiet(scheme))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .overlay(shape.strokeBorder(theme.color("frame", scheme), lineWidth: 1))
                .rowSpeech(speech)
        default:
            if row.showsQuote {
                // The quote and the message are two elements in one bubble;
                // the message is read first (B16), then the quote (B21).
                let fold = foldState()
                BubbleStack(tightens: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        QuoteView(row: row, roomTitle: roomTitle)
                        messageText(theme)
                            .messageFold(fold.folded, lineHeight: foldLineHeight)
                            .spokenMessage(speech, links: links, actions: actions)
                            .accessibilityIdentifier("message.body.\(row.id)")
                            .accessibilitySortPriority(1)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 9)
                    .padding(.bottom, fold.showsToggle ? 0 : 9)
                    if fold.showsToggle {
                        foldToggle(theme, folded: fold.folded)
                            .padding(.horizontal, 14)
                    }
                    botAPIKeyboard(theme)
                }
                .background(fill, in: shape)
                .modifier(IncomingElevation(trailing: trailing, shape: shape))
                .accessibilityElement(children: .contain)
            } else {
                let fold = foldState()
                BubbleStack(tightens: true) {
                    messageText(theme)
                        .messageFold(fold.folded, lineHeight: foldLineHeight)
                        .padding(.horizontal, 14)
                        .padding(.top, 9)
                        .padding(.bottom, fold.showsToggle ? 0 : 9)
                        .spokenMessage(speech, links: links, actions: actions)
                        .accessibilityIdentifier("message.body.\(row.id)")
                    if fold.showsToggle {
                        foldToggle(theme, folded: fold.folded)
                            .padding(.horizontal, 14)
                    }
                    botAPIKeyboard(theme)
                }
                .background(fill, in: shape)
                .modifier(IncomingElevation(trailing: trailing, shape: shape))
            }
        }
    }

    // MARK: Long messages fold (`MessageFold`)

    private struct FoldState {
        var folded = false
        var showsToggle = false
    }

    /// Whether this message folds now, and whether it shows its toggle. Only
    /// text messages fold, and never while the open search marks words in
    /// them (a match could sit under the fold).
    private func foldState() -> FoldState {
        _ = foldTick
        guard case .message = row.item.kind, searchHighlight == nil else { return FoldState() }
        let width = MessageFoldMeasure.textWidth(gutter: avatarSlot, flat: flat)
        let long = MessageFoldMeasure.isLong(id: row.id, body: row.item.body, parsed: parsedBody,
                                             isOwn: row.item.isOwn, textWidth: width, size: dynamicTypeSize)
        return FoldState(folded: MessageFoldStore.session.isFolded(row.id, isLong: long, isGrowing: isGrowing),
                         showsToggle: MessageFoldBook.showsToggle(isLong: long, isGrowing: isGrowing))
    }

    private var foldLineHeight: CGFloat { MessageFoldMeasure.lineHeight(dynamicTypeSize) }

    private func foldToggle(_ theme: ChatTheme, folded: Bool) -> some View {
        MessageFoldToggle(rowID: row.id, folded: folded) {
            MessageFoldStore.session.toggle(row.id, wasFolded: folded)
            foldTick &+= 1
            if !folded { interactions.folded(row.id) }
        }
        .foregroundStyle(trailing ? theme.design.kit.color(.onBubbleOwn, scheme: scheme)
                                  : theme.color("ink", scheme))
    }

    /// Native URL-only buttons from authenticated per-message Bot API
    /// metadata. The contract's nested arrays are kept as rows; every tap
    /// goes through the same LinkPolicy/in-app Safari router as body links.
    @ViewBuilder private func botAPIKeyboard(_ theme: ChatTheme) -> some View {
        if let keyboard = row.item.botAPI?.keyboard, !keyboard.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(keyboard.enumerated()), id: \.offset) { rowIndex, buttons in
                    HStack(spacing: 6) {
                        ForEach(Array(buttons.enumerated()), id: \.offset) { buttonIndex, button in
                            Button {
                                actions.openLink(button.url.absoluteString)
                            } label: {
                                Text(verbatim: button.label)
                                    .font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, minHeight: 34)
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.roundedRectangle(radius: 9))
                            .tint(theme.color("actionStrong", scheme))
                            .accessibilityIdentifier(
                                "bot-api.button.\(row.id).\(rowIndex).\(buttonIndex)"
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder private func mediaCaption(_ theme: ChatTheme) -> some View {
        if trailing {
            Text(verbatim: row.item.body)
                .font(.body)
                .foregroundStyle(theme.design.kit.color(.onBubbleOwn, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
        } else {
            NativeRichText(bodyText: row.item.markdownBody, parsed: parsedBody)
        }
    }

    /// The text. Its "đã sửa" is in the line under the bubble (TL-5,
    /// `DeliveryLine`), as on desktop.
    private func messageText(_ theme: ChatTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if row.item.isOwn {
                // B6: what I type is sent and shown as plain text.
                if let searchHighlight {
                    Text(searchPainted(AttributedString(row.item.body), searchHighlight, theme))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(verbatim: row.item.body)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let searchHighlight {
                NativeRichText(bodyText: row.item.markdownBody,
                               parsed: searchPainted(parsedBody ?? MessageMarkup.parse(row.item.markdownBody),
                                                     searchHighlight, theme))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                NativeRichText(bodyText: row.item.markdownBody, parsed: parsedBody)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(trailing ? theme.design.kit.color(.onBubbleOwn, scheme: scheme)
                                  : theme.color("ink", scheme))
    }

    /// HC-6: desktop paints every match as a 16% ink wash and the current
    /// one in ink with the on-accent colour; in my own bubble the bubble's
    /// text colour plays the ink.
    private func searchPainted(_ text: AttributedString, _ highlight: ChatSearchHighlight,
                               _ theme: ChatTheme) -> AttributedString {
        let ink = trailing ? theme.design.kit.color(.onBubbleOwn, scheme: scheme) : theme.color("ink", scheme)
        let onInk = trailing ? theme.design.kit.color(.bubbleOwn, scheme: scheme)
                             : theme.design.kit.color(.onInk, scheme: scheme)
        return ChatSearchPaint.paint(text, highlight: highlight, wash: ink.opacity(0.16), current: ink, onCurrent: onInk)
    }

    static let avatarSize: CGFloat = 24
    static let avatarGap: CGFloat = 7

    /// B16: round everywhere except the inner corners between two bubbles of
    /// one run, on the sender's side.
    static func shape(position: RunPosition?, trailing: Bool) -> UnevenRoundedRectangle {
        let big = ChatLayout.bubbleRadius
        let small = ChatLayout.runRadius
        let position = position ?? .single
        let top = position == .middle || position == .last ? small : big
        let bottom = position == .first || position == .middle ? small : big
        return trailing
            ? UnevenRoundedRectangle(topLeadingRadius: big, bottomLeadingRadius: big,
                                     bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                     bottomTrailingRadius: big, topTrailingRadius: big, style: .continuous)
    }
}

/// B19: an image is a box of its final size (from `ImageInfo`) with a photo
/// glyph and no download in S1; S4 draws the thumbnail in the same box, so
/// nothing shifts.
struct ImageBox: View {
    let width: Double?
    let height: Double?
    let fill: Color
    let shape: UnevenRoundedRectangle

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let size = Self.size(width: width, height: height)
        ZStack {
            shape.fill(fill)
            Image(theme?.design.symbol("Photo") ?? "ph.image")
                .font(.title2)
                .foregroundStyle(theme?.color("muted", scheme) ?? .secondary)
        }
        .frame(width: size.width, height: size.height)
    }

    static let maxSide: CGFloat = 240
    static let minSide: CGFloat = 96

    /// The box keeps the image's aspect ratio inside 240 × 240 pt, never
    /// thinner than 96 pt; with no size, a 4:3 box.
    static func size(width: Double?, height: Double?) -> CGSize {
        guard let width, let height, width > 0, height > 0 else {
            return CGSize(width: maxSide, height: maxSide * 3 / 4)
        }
        let aspect = width / height
        var box = aspect >= 1
            ? CGSize(width: maxSide, height: maxSide / aspect)
            : CGSize(width: maxSide * aspect, height: maxSide)
        box.width = max(minSide, box.width.rounded())
        box.height = max(minSide, box.height.rounded())
        return box
    }
}

/// B19: a file (or a video or audio clip in v1) is a row with its name; S4
/// adds the size and Quick Look.
struct FileCard: View {
    let name: String

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            Image(theme?.design.symbol("File") ?? "ph.file")
                .font(.title3)
                .foregroundStyle(theme?.color("muted", scheme) ?? .secondary)
            Text(verbatim: name.isEmpty ? (theme?.copy.text(.file) ?? "") : name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// B16: the sender's name above the first bubble of a run, in groups only
// Preserve user-visible identity, state and recovery behavior across connection changes.
/// name, like a person's or my assistant's). The face sits beside the run's
/// last bubble instead (`BubbleWithAvatarLayout`); `showsAvatar` is kept for
/// callers that want a small face beside the name.
struct SenderLine: View {
    let name: String
    let showsAvatar: Bool
    var avatarKind: AtumAvatarKind = .person
    var appBot: AppBotPresentation? = nil

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            if showsAvatar {
                if let appBot { AppBotAvatar(app: appBot, size: 20) }
                else { AtumAvatar(kind: avatarKind, name: name, size: 20) }
            }
            Text(verbatim: name)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme?.quiet(scheme) ?? .secondary)
                .lineLimit(1)
        }
        .padding(.leading, 4)
        .accessibilityHidden(true) // the row's label names the sender
    }
}

private extension View {
    /// The message as one element (B16) with an action per link in it (B17).
    func spokenMessage(_ speech: RowSpeech, links: [(text: String, url: URL)], actions: ChatActions) -> some View {
        rowSpeech(speech)
            .accessibilityActions {
                ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                    Button(link.text) { actions.openLink(link.url.absoluteString) }
                }
            }
    }
}

/// A bubble, with the sender's face beside the last bubble of a group run,
// Preserve user-visible identity, state and recovery behavior across connection changes.
/// do the same). The face gutter is reserved for every incoming bubble in a
/// group so the run never jumps sideways; a 1:1 chat reserves none. The
/// bubble is offered the widest-bubble width (`BubbleGeometry.maxWidth`:
/// the row less the gutter and the far-side gap) and takes only what its
/// content needs. My own bubbles
/// keep the trailing edge with no gutter.
struct BubbleWithAvatarLayout: Layout {
    var trailing: Bool
    var reservesAvatar: Bool
    var showsAvatar: Bool
    var avatarSize: CGFloat
    var gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let full = proposal.width ?? 360
        let bubble = subviews[0].sizeThatFits(childProposal(row: full))
        let height = max(bubble.height, showsAvatar ? avatarSize : 0)
        return CGSize(width: full, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let bubble = subviews[0].sizeThatFits(childProposal(row: bounds.width))
        let x = trailing ? bounds.maxX - bubble.width : bounds.minX + inset
        let height = max(bubble.height, showsAvatar ? avatarSize : 0)
        subviews[0].place(at: CGPoint(x: x, y: bounds.minY + height - bubble.height),
                          proposal: ProposedViewSize(bubble))
        guard showsAvatar, subviews.count > 1 else { return }
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + height - avatarSize),
                          proposal: ProposedViewSize(width: avatarSize, height: avatarSize))
    }

    private var inset: CGFloat { reservesAvatar ? avatarSize + gap : 0 }

    private func childProposal(row: CGFloat) -> ProposedViewSize {
        let width = BubbleGeometry.maxWidth(row: Double(row), gutter: Double(inset),
                                            margin: Double(ChatLayout.sideMargin))
        return ProposedViewSize(width: CGFloat(width).rounded(.down), height: nil)
    }
}

/// Kit: a person's bubble sits on `surface` with `shadow-1`; your own ink
/// bubble needs no lift.
private struct IncomingElevation<S: InsettableShape>: ViewModifier {
    let trailing: Bool
    let shape: S

    func body(content: Content) -> some View {
        if trailing {
            content
        } else {
            content.atumKitElevation(.one, in: shape)
        }
    }
}
