import AtumChat
import AtumDesign
import AtumNativeAPI
import ImageIO
import SwiftUI
import Textual
import UIKit

// The long-press menu (revamp plan B20–B22, §2.7, §3.5), drawn to the Kit's
// FlowPhone3 › Message actions: over a dimmed chat, a glass reaction capsule
// (desktop's set) above the message and a short glass menu under it: "Trả
// lời", "Sao chép", "Chọn văn bản" on answers, "Sửa" on my messages in people
// chats, "Xóa" (danger) on my messages. The system `contextMenu(menuItems:
// preview:)` was weighed first (review A1): its preview is not interactive,
// so it cannot carry the reaction capsule, and it has no reaction accessory
// API. So this stays a custom overlay presented from the long press, laid out
// as the system lifts a preview (see `MessageActionsOverlay`). Which items a
// row offers is `MessageMenuRules` (tested); every action goes through the
// frozen `ChatActions`, which the store enforces again.
//
// The sheets the menu and the failed-send mark open (select text, the delete
// confirmation, "Thử lại" / "Xóa") hang once on the chat screen
// (`messageActionSheets`), driven by one `MessageActionsPresenter`, so a row
// recycled by the lazy stack never owns a presentation.

/// What the menu and the failed-send mark ask the chat screen to present.
/// One per chat screen, handed to rows through the environment
/// (`messageActions`).
@MainActor
@Observable
final class MessageActionsPresenter {
    var selectText: SelectTextRequest?
    var deleteRequest: DeleteRequest?
    var failedSend: FailedSendRequest?
    /// The message-actions overlay on screen, if any.
    var actionsOverlay: MessageOverlayRequest?
    /// A link tapped in the select-text sheet (B17): the sheet closes first
    /// and the link is routed once it has gone, because the chat screen
    /// presents the in-app page or the held-link line, and SwiftUI presents
    /// nothing from under a presented sheet.
    @ObservationIgnored var linkAfterSelectText: String?

    /// The select-text sheet's link tap: close the sheet, then route.
    func openLinkFromSelectText(_ url: String) {
        linkAfterSelectText = url
        selectText = nil
    }

    /// A system menu, sheet or delete confirmation covers the chat: its bottom does
    /// not count as visible, so no receipt goes out meanwhile (B13).
    var covers: Bool {
        actionsOverlay != nil || selectText != nil || deleteRequest != nil || failedSend != nil
    }

    /// B8: tapping "Chưa gửi được" under a failed bubble (the row view's
    /// mark) offers "Thử lại" and "Xóa".
    func showFailedSend(_ row: ChatRow) {
        failedSend = FailedSendRequest(itemID: row.id, body: row.item.body,
                                       kind: row.item.kind, media: row.item.media)
    }
}

/// "Xóa với mọi người?" for one of my messages (B20; desktop asks the same).
struct DeleteRequest: Identifiable, Equatable {
    let itemID: String
    /// My assistant's name in an assistant chat: it may still remember what
    /// it read (desktop's note).
    let assistantName: String?
    var id: String { itemID }
}

extension EnvironmentValues {
    /// The chat screen's presenter, for row views (the failed-send mark).
    @Entry var messageActions: MessageActionsPresenter?
}

extension View {
    /// B20: the long-press menu for one row. Rows with nothing to act on
    /// (notices, placeholders, virtual rows) get no menu. `ownUserID` marks
    /// the reactions I already gave (nil: none marked); `parsedBody` is the
    /// store's parse of an answer (`ConversationStore.parsedBody(for:)`), so
    /// the preview and the select-text sheet never parse again.
    func messageMenu(row: ChatRow, kind: RoomKind, roomTitle: String, ownUserID: String?,
                     parsedBody: AttributedString?, design: LiveDesign, actions: ChatActions,
                     presenter: MessageActionsPresenter) -> some View {
        modifier(MessageMenuModifier(row: row, kind: kind, roomTitle: roomTitle, ownUserID: ownUserID,
                                     parsedBody: parsedBody, design: design, actions: actions, presenter: presenter))
    }

    /// The menu's and the failed-send mark's presentations, once per chat
    /// screen: the select-text sheet, the delete confirmation and the
    /// failed-send sheet.
    func messageActionSheets(_ presenter: MessageActionsPresenter, design: LiveDesign,
                             actions: ChatActions) -> some View {
        modifier(MessageActionSheets(presenter: presenter, design: design, actions: actions))
    }
}

/// One long press on an event row opens the actions overlay for it.
struct MessageOverlayRequest: Identifiable {
    let row: ChatRow
    let kind: RoomKind
    let roomTitle: String
    let ownUserID: String?
    let parsedBody: AttributedString?
    let items: [MessageMenuItem]
    /// The row's frame on screen when it was pressed.
    let sourceFrame: CGRect
    var id: String { row.id }
}

private struct MessageMenuModifier: ViewModifier {
    let row: ChatRow
    let kind: RoomKind
    let roomTitle: String
    let ownUserID: String?
    let parsedBody: AttributedString?
    let design: LiveDesign
    let actions: ChatActions
    let presenter: MessageActionsPresenter

    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        let items = MessageMenuRules.items(for: row.item, in: kind)
        if items.isEmpty {
            content
        } else {
            // Review A1: while its menu is open the row is lifted, so the
            // original is hidden and only the overlay's copy shows (the
            // system context menu does the same). The overlay is modal, so
            // VoiceOver never reaches the hidden row either.
            let lifted = presenter.actionsOverlay?.id == row.id
            content
                .opacity(lifted ? 0 : 1)
                .accessibilityHidden(lifted)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
                // Simultaneous, so the answer's own text views (links, the
                // markdown renderer) never swallow the press.
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in open(items) })
                .sensoryFeedback(.impact(weight: .medium), trigger: presenter.actionsOverlay?.id == row.id)
                // VoiceOver: every item is an action on the message itself.
                .accessibilityActions {
                    ForEach(items.filter { $0 != .react }, id: \.self) { item in
                        Button(MessageMenuActions.title(item, design: design)) {
                            MessageMenuActions.perform(item, row: row, kind: kind, roomTitle: roomTitle,
                                                       parsedBody: parsedBody, actions: actions,
                                                       presenter: presenter)
                        }
                    }
                    if items.contains(.react) {
                        Button(ChatCopy.text(design, ChatCopy.Key.react)) { open(items) }
                    }
                }
        }
    }

    private func open(_ items: [MessageMenuItem]) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            presenter.actionsOverlay = MessageOverlayRequest(row: row, kind: kind, roomTitle: roomTitle,
                                                             ownUserID: ownUserID, parsedBody: parsedBody,
                                                             items: items, sourceFrame: frame)
        }
    }
}

/// What each menu item says, shows and does; shared by the overlay and the
/// VoiceOver actions.
@MainActor
enum MessageMenuActions {
    static func title(_ item: MessageMenuItem, design: LiveDesign) -> String {
        switch item {
        case .react: ChatCopy.text(design, ChatCopy.Key.react)
        case .reply: ChatCopy.text(design, ChatCopy.Key.reply)
        case .copy: ChatCopy.text(design, ChatCopy.Key.copy)
        case .selectText: ChatCopy.text(design, ChatCopy.Key.selectText)
        case .edit: ChatCopy.text(design, ChatCopy.Key.edit)
        case .delete: ChatCopy.text(design, ChatCopy.Key.delete)
        }
    }

    static func glyph(_ item: MessageMenuItem) -> AtumGlyph {
        switch item {
        case .react: .smiley
        case .reply: .arrowBackUp
        case .copy: .copy
        case .selectText: .fileText
        case .edit: .pencil
        case .delete: .trash
        }
    }

    static func perform(_ item: MessageMenuItem, row: ChatRow, kind: RoomKind, roomTitle: String,
                        parsedBody: AttributedString?, actions: ChatActions,
                        presenter: MessageActionsPresenter) {
        switch item {
        case .react: break
        case .reply: actions.reply(row.id)
        case .copy: actions.copy(row.id)
        case .selectText:
            presenter.selectText = SelectTextRequest(itemID: row.id, body: row.item.body,
                                                     parsed: parsedBody)
        case .edit: actions.edit(row.id)
        case .delete:
            if MessageMenuRules.deleteNeedsConfirmation(row.item) {
                presenter.deleteRequest = DeleteRequest(itemID: row.id,
                                                        assistantName: kind == .assistant ? roomTitle : nil)
            } else {
                actions.delete(row.id)
            }
        }
    }
}

/// FlowPhone3 › Message actions, laid out the way the system lifts a context
/// menu (review A1): the pressed row is hidden (`MessageMenuModifier`), so only
/// its lifted copy shows; the chat behind sits under a material blur plus the
/// Kit scrim, which separates the layers in light and dark (and turns opaque
/// under Reduce Transparency); and `MessageMenuLayout` keeps the copy where it
/// was pressed with the glass reaction capsule and the glass menu on opposite
/// sides of it, flipping them for a message low on the screen, so neither
/// ever covers the copy, the other, or the bars. A tap outside closes it.
struct MessageActionsOverlay: View {
    let request: MessageOverlayRequest
    let design: LiveDesign
    let actions: ChatActions
    let presenter: MessageActionsPresenter

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var reactionsHeight: CGFloat = 0
    @State private var previewHeight: CGFloat = 0
    @State private var menuHeight: CGFloat = 0
    /// Review A2: the palette and the menu follow Dynamic Type, within limits
    /// that keep six reactions on one line of a phone.
    @ScaledMetric(relativeTo: .title2) private var emojiSize: CGFloat = 26
    @ScaledMetric(relativeTo: .title2) private var reactionTarget: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var menuWidth: CGFloat = 250

    private var kit: AtumKit { design.kit }
    private var own: Bool { request.row.item.isOwn }
    private var hasReactions: Bool { request.items.contains(.react) }
    private var menuRows: [MessageMenuItem] { request.items.filter { $0 != .react } }

    /// Space kept from the safe area's edges, and between the parts.
    private static let margin: CGFloat = 8
    private static let gap: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).minY
            let top = Double(Self.margin)
            let bottom = Double(max(Self.margin, proxy.size.height - Self.margin))
            let layout = MessageMenuLayout.place(
                sourceTop: Double(request.sourceFrame.minY - origin), bounds: top...bottom,
                reactions: hasReactions ? Double(reactionsHeight) : nil,
                preview: Double(previewHeight), menu: Double(menuHeight), gap: Double(Self.gap))
            // The most the copy may take, whatever its own height.
            let room = bottom - top - (hasReactions ? Double(reactionsHeight + Self.gap) : 0)
                - (menuRows.isEmpty ? 0 : Double(menuHeight + Self.gap))
            let measured = previewHeight > 0 && (menuRows.isEmpty || menuHeight > 0)
                && (!hasReactions || reactionsHeight > 0)
            ZStack(alignment: .topLeading) {
                backdrop
                ZStack(alignment: .topLeading) {
                    if hasReactions {
                        reactions
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { reactionsHeight = $0 }
                            .modifier(Placed(top: layout.reactionsTop ?? 0, own: own))
                    }
                    MessageMenuPreview(row: request.row, kind: request.kind, parsedBody: request.parsedBody,
                                       design: design, maxHeight: CGFloat(max(0, room)))
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                        .modifier(Placed(top: layout.previewTop, own: own))
                    if !menuRows.isEmpty {
                        menu(width: min(menuWidth, proxy.size.width - 2 * ChatLayout.sideMargin))
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeight = $0 }
                            .modifier(Placed(top: layout.menuTop, own: own))
                    }
                }
                .scaleEffect(shown || reduceMotion ? 1 : 0.96)
                // Nothing shows until every part has been measured once, so
                // the first frame never draws a part in the wrong place.
                .opacity(shown && measured ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(reduceMotion ? .linear(duration: 0.12) : .spring(duration: 0.28, bounce: 0.18)) {
                shown = true
            }
        }
        .accessibilityAction(.escape) { close() }
        .atumDesign(design)
    }

    /// The material dim: blur, then the Kit scrim over it.
    private var backdrop: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            kit.color(.scrim, scheme: scheme)
        }
        .opacity(shown ? 1 : 0)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { close() }
        .accessibilityHidden(true)
        .accessibilityIdentifier(Self.backdropID)
    }

    private var reactions: some View {
        let choices = MessageMenuRules.reactionChoices(for: request.row.item, ownUserID: request.ownUserID)
        let target = min(reactionTarget, 52)
        return HStack(spacing: 2) {
            ForEach(choices, id: \.key) { choice in
                Button {
                    actions.toggleReaction(request.row.id, choice.key)
                    close()
                } label: {
                    Text(verbatim: choice.key)
                        .font(.system(size: min(emojiSize, 34)))
                        // At least 44 pt to tap (the Kit's phone control height).
                        .frame(width: target, height: target)
                        .background {
                            if choice.isSelected {
                                Circle().fill(kit.color(.fillSelected, scheme: scheme)).padding(4)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ChatCopy.text(design, ChatCopy.Key.reactWith, [.text(choice.key)]))
                .accessibilityAddTraits(choice.isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .modifier(LiveGlass(design: design, radius: 26))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.reactionsID)
    }

    private func menu(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(menuRows.enumerated()), id: \.element) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(kit.color(.line, scheme: scheme))
                        .frame(height: 0.5)
                        .padding(.leading, 16)
                }
                Button {
                    close()
                    let request = request
                    let run = {
                        MessageMenuActions.perform(item, row: request.row, kind: request.kind,
                                                   roomTitle: request.roomTitle, parsedBody: request.parsedBody,
                                                   actions: actions, presenter: presenter)
                    }
                    // A sheet or the delete alert can only be presented once
                    // the cover has gone; the rest act at once.
                    if item == .selectText || item == .delete {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(120))
                            run()
                        }
                    } else {
                        run()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text(MessageMenuActions.title(item, design: design))
                            .font(.body)
                        Spacer(minLength: 8)
                        Image(design.symbol(MessageMenuActions.glyph(item).rawValue))
                            .font(.body)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(kit.color(item == .delete ? .danger : .ink, scheme: scheme))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(MessageMenuActions.title(item, design: design))
            }
        }
        .frame(width: width)
        .modifier(LiveGlass(design: design, radius: 22))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Self.menuID)
    }

    private func close() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { presenter.actionsOverlay = nil }
    }

    /// The overlay's parts, for UI tests (beside the frozen row IDs).
    static let reactionsID = "menu.reactions"
    static let previewID = "menu.preview"
    static let menuID = "menu.items"
    static let backdropID = "menu.backdrop"

    /// One part at its layout top, on the message's side of the screen.
    private struct Placed: ViewModifier {
        let top: Double
        let own: Bool

        func body(content: Content) -> some View {
            content
                .frame(maxWidth: .infinity, alignment: own ? .trailing : .leading)
                .padding(.horizontal, ChatLayout.sideMargin)
                .offset(y: CGFloat(top))
        }
    }
}

/// Offers its child at most `maxWidth` and takes the child's own size, so a
/// short message keeps a short bubble and a long one wraps. `maxHeight`
/// caps the height without ever growing a short message to it (a flexible
/// `.frame(maxHeight:)` takes the whole cap when offered more).
private struct HugWidth: Layout {
    let maxWidth: CGFloat
    var maxHeight: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: nil))
        return CGSize(width: size.width, height: min(size.height, maxHeight ?? .infinity))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        // The child keeps its own height; a cut one runs past the bottom and
        // is clipped by the caller.
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// The pressed message, lifted above the dimmed chat as a Kit bubble: yours
/// on `bubble-own`, everyone else's on `surface` (FlowPhone3).
private struct MessageMenuPreview: View {
    let row: ChatRow
    let kind: RoomKind
    let parsedBody: AttributedString?
    let design: LiveDesign
    /// The most the bubble may take (`MessageMenuLayout`'s room); a longer
    /// message is cut at the bottom inside its bubble.
    var maxHeight: CGFloat? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let own = row.item.isOwn
        let shape = RoundedRectangle(cornerRadius: ChatLayout.bubbleRadius, style: .continuous)
        HugWidth(maxWidth: 292, maxHeight: maxHeight.map { max(0, $0 - 18) }) { content }
            .clipped()
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .foregroundStyle(design.kit.color(own ? .onBubbleOwn : .ink, scheme: scheme))
            .background(design.kit.color(own ? .bubbleOwn : .surface, scheme: scheme), in: shape)
            .atumKitElevation(.one, in: shape)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(MessageActionsOverlay.previewID)
    }

    @ViewBuilder private var content: some View {
        switch row.item.kind {
        case .image where row.item.media != nil:
            MessageMenuImagePreview(row: row, design: design)
        case .image:
            Label(ChatCopy.text(design, ChatCopy.Key.photo), image: design.symbol("Photo"))
        case let .file(name):
            if let media = row.item.media {
                let kind = media.presentationKind(fallbackFilename: name)
                HStack(spacing: 12) {
                    Image(design.symbol(kind.glyphAlias)).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: media.filename ?? name).lineLimit(2).truncationMode(.middle)
                        Text(ChatCopy.text(design, kind.copyKey)).font(.footnote)
                            .foregroundStyle(design.color("soft", scheme: scheme))
                    }
                }
                .padding(12)
                .background(design.color("cell", scheme: scheme),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Label(name, image: design.symbol("File"))
            }
        default:
            if MessageMenuRules.isAnswer(row.item, in: kind) {
                // Answers render as markdown, from the store's parse.
                // Textual turns line limits off inside, so a long answer is
                // cut by height: the preview stays a preview.
                StructuredText(row.item.body, parser: ParsedOrFreshMarkdown(parsed: parsedBody))
                    .font(.body)
                    .textual.inlineStyle(design.chatInlineStyle(scheme))
                    .frame(maxHeight: Self.maximumContentHeight, alignment: .top)
                    .clipped()
            } else {
                // People's and my own messages show literally (B6).
                Text(verbatim: row.item.body)
                    .font(.body)
                    .lineLimit(14)
            }
        }
    }

    /// About 14 lines of body text.
    private static let maximumContentHeight: CGFloat = 330
}

private struct MessageMenuImagePreview: View {
    let row: ChatRow
    let design: LiveDesign
    @Environment(\.chatMediaAccess) private var access
    @Environment(\.chatLocalMediaFiles) private var localFiles
    @Environment(\.colorScheme) private var scheme
    @State private var image: Image?

    private var size: CGSize {
        guard case let .image(width, height) = row.item.kind,
              let width, let height, width > 0, height > 0 else {
            return CGSize(width: 288, height: 216)
        }
        let previewHeight = 288 * CGFloat(height) / CGFloat(width)
        return CGSize(width: 288, height: min(360, max(120, previewHeight)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                design.color("bubble", scheme: scheme)
                if let image { image.resizable().scaledToFill() }
                else { Image(design.symbol("Photo")).font(.title2) }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            if !row.item.body.isEmpty {
                Text(verbatim: row.item.body).font(.body).lineLimit(6)
            }
        }
        .task(id: row.item.media) {
            let data: Data?
            if let local = localFiles[row.id] {
                data = try? Data(contentsOf: local, options: [.mappedIfSafe])
            } else if let media = row.item.media {
                data = await access.thumbnail(media, Int(size.width * 3), Int(size.height * 3))
            } else {
                data = nil
            }
            guard let data,
                  !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let value = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height) * 3),
                  ] as CFDictionary), !Task.isCancelled else { return }
            image = Image(uiImage: UIImage(cgImage: value))
        }
    }
}

extension LiveDesign {
    /// Textual's inline style for the chat's markdown outside the transcript
    /// (the menu preview, the select-text sheet): links ink and underlined,
    /// as `NativeRichText` draws them. Textual's default link colour is its
    /// own blue and ignores `.tint` (§0.2: monochrome ink accent, never iOS
    /// blue; seen in the S1 review's screenshots).
    func chatInlineStyle(_ scheme: ColorScheme) -> InlineStyle {
        InlineStyle.default.link(.foregroundColor(color("ink", scheme: scheme)), .underlineStyle(.single))
    }
}

/// Hands Textual the store's parse when it is current, so the preview and
/// the select-text sheet never parse on the main actor; parses only when the
/// store has none yet (an answer opened before its parse landed).
struct ParsedOrFreshMarkdown: MarkupParser {
    let parsed: AttributedString?

    func attributedString(for input: String) throws -> AttributedString {
        parsed ?? MessageMarkup.parse(input)
    }
}

/// The presentations, once per chat screen.
private struct MessageActionSheets: ViewModifier {
    @Bindable var presenter: MessageActionsPresenter
    let design: LiveDesign
    let actions: ChatActions

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $presenter.actionsOverlay) { request in
                MessageActionsOverlay(request: request, design: design, actions: actions, presenter: presenter)
                    .presentationBackground(.clear)
            }
            .sheet(item: $presenter.selectText, onDismiss: {
                guard let link = presenter.linkAfterSelectText else { return }
                presenter.linkAfterSelectText = nil
                actions.openLink(link)
            }) { request in
                SelectTextSheet(request: request, design: design) { url in
                    presenter.openLinkFromSelectText(url)
                }
            }
            .sheet(item: $presenter.failedSend) { request in
                FailedSendSheet(request: request, design: design, actions: actions)
            }
            .alert(ChatCopy.text(design, ChatCopy.Key.deleteMessageTitle),
                   isPresented: Binding(get: { presenter.deleteRequest != nil },
                                        set: { if !$0 { presenter.deleteRequest = nil } }),
                   presenting: presenter.deleteRequest) { request in
                Button(ChatCopy.text(design, ChatCopy.Key.delete), role: .destructive) {
                    actions.delete(request.itemID)
                }
                Button(ChatCopy.text(design, ChatCopy.Key.cancel), role: .cancel) {}
            } message: { request in
                Text(message(request))
            }
    }

    private func message(_ request: DeleteRequest) -> String {
        let body = ChatCopy.text(design, ChatCopy.Key.deleteMessageBody)
        guard let name = request.assistantName, !name.isEmpty else { return body }
        // Two exported sentences, one per line: no separator is written here.
        return body + "\n" + ChatCopy.text(design, ChatCopy.Key.deleteMessageAssistantNote, [.text(name)])
    }
}
