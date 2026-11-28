import AtumChat
import SwiftUI
import UIKit

// MARK: Environment

/// The open chat's Forward route as the long-press menu needs it (S10).
/// Nil: this chat has no picker route (`roomForwardMenuContext` is nil).
struct ChatForwardMenu {
    let context: ForwardMenuContext
    /// The source event, and the row and chat title its preview card names.
    let open: (_ eventID: String, _ row: ChatRow, _ roomTitle: String) -> Void
}

/// One link card's data, ready to draw. The picture is decoded once, here,
/// from the bounded Matrix thumbnail the engine accepted.
struct ChatLinkCard {
    let preview: LinkPreview
    let image: UIImage?
}

/// Link cards of the open chat (S11), for its current Matrix session. A row
/// asks from its visibility task; nothing is drawn or reserved until a card
/// arrives (desktop `MatrixLinkPreviewCard`). Results are keyed by event and
/// URL, so a reused bubble never shows an earlier row's card.
@MainActor
@Observable
final class ChatLinkPreviewCards {
    private(set) var cards = [String: ChatLinkCard]()
    /// Desktop's per-message "Hide preview", for this chat while it is open.
    private(set) var hidden = Set<String>()

    @ObservationIgnored private let url: @MainActor (ChatItem) -> URL?
    @ObservationIgnored private let read: @MainActor (ChatItem) async -> LinkPreview?
    @ObservationIgnored private let onClose: @MainActor () -> Void
    @ObservationIgnored private var order = [String]()
    @ObservationIgnored private var loading = Set<String>()
    @ObservationIgnored private var closed = false
    /// The engine caches 32 reads per open chat; the drawn cards keep the same bound.
    static let capacity = 32

    init(url: @escaping @MainActor (ChatItem) -> URL?, read: @escaping @MainActor (ChatItem) async -> LinkPreview?,
         onClose: @escaping @MainActor () -> Void = {}) {
        self.url = url
        self.read = read
        self.onClose = onClose
    }

    func key(for item: ChatItem) -> String? {
        guard let eventID = item.eventID, let url = url(item) else { return nil }
        return eventID + "\u{1F}" + url.absoluteString
    }

    func card(for item: ChatItem) -> ChatLinkCard? {
        guard let eventID = item.eventID, !hidden.contains(eventID), let key = key(for: item) else { return nil }
        return cards[key]
    }

    func load(_ item: ChatItem) async {
        guard !closed, let key = key(for: item), cards[key] == nil, loading.insert(key).inserted else { return }
        defer { loading.remove(key) }
        guard let preview = await read(item), !Task.isCancelled, !closed else { return }
        let image = preview.image.flatMap(UIImage.init(data:))
        if order.count >= Self.capacity { cards.removeValue(forKey: order.removeFirst()) }
        order.append(key)
        cards[key] = ChatLinkCard(preview: preview, image: image)
    }

    func hide(_ item: ChatItem) {
        if let eventID = item.eventID { hidden.insert(eventID) }
    }

    func close() {
        guard !closed else { return }
        closed = true
        cards.removeAll()
        order.removeAll()
        onClose()
    }
}

extension EnvironmentValues {
    @Entry var chatForwardMenu: ChatForwardMenu?
    @Entry var chatLinkPreviews: ChatLinkPreviewCards?
}

// MARK: S11 link card

/// Asks for the row's card while the row is on screen. On the bubble, which
/// always exists, so the attachment itself can stay empty until a card lands.
struct LinkPreviewLoading: ViewModifier {
    let item: ChatItem
    @Environment(\.chatLinkPreviews) private var previews

    func body(content: Content) -> some View {
        if let previews, let key = previews.key(for: item) {
            content.task(id: key) { await previews.load(item) }
        } else {
            content
        }
    }
}

/// The card under a message with a web link, in a confirmed plain room
/// only. Empty (no subview, no stack spacing) until the homeserver answered.
struct LinkPreviewAttachment: View {
    let row: ChatRow
    var leading: CGFloat = 0
    var trailing = false

    @Environment(\.chatLinkPreviews) private var previews
    @Environment(\.chatActions) private var actions
    @Environment(\.chatTheme) private var theme

    var body: some View {
        if let previews, let theme, let card = previews.card(for: row.item) {
            LinkPreviewCardView(card: card, design: theme.design,
                                open: { actions.openLink(card.preview.url.absoluteString) },
                                hide: { previews.hide(row.item) })
                .padding(.leading, leading)
                .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
                .transition(.opacity)
        }
    }
}

/// Desktop `MatrixLinkPreviewView` / `link-preview-card.css`: a file-card
/// shell (hairline, `xl` corners, surface), the page's picture as a 56 pt
/// leading tile (card 20 − padding 12 = picture 8), then the site, the title
/// and the description, two lines each. Desktop shows × on hover or focus; a
/// phone has neither, so × always shows, with a 44 pt target.
struct LinkPreviewCardView: View {
    let card: ChatLinkCard
    let design: LiveDesign
    let open: () -> Void
    let hide: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.chatReducesMotion) private var reduceMotion
    @State private var shown = false

    private var kit: AtumKit { design.kit }
    private var copy: ChatActionsCopy { ChatActionsCopy(design: design) }
    private var preview: LinkPreview { card.preview }
    private var lines: Int { dynamicTypeSize.isAccessibilitySize ? 4 : 2 }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                HStack(alignment: .top, spacing: kit.space(.s3)) {
                    if let image = card.image, !dynamicTypeSize.isAccessibilitySize {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .background(kit.color(.sunk, scheme: scheme))
                            .clipShape(RoundedRectangle(cornerRadius: kit.radius(.sm), style: .continuous))
                            .accessibilityHidden(true)
                    }
                    words
                }
                .padding(kit.space(.s3))
                // Room for × (desktop: padding-inline-end s3 + h-sm).
                .padding(.trailing, kit.space(.s3) + kit.space(.s4))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: kit.radius(.xl), style: .continuous))
            }
            .buttonStyle(LinkPreviewPressStyle(kit: kit, scheme: scheme))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isLink)
            .accessibilityIdentifier("chat.linkPreview")

            Button(action: hide) {
                Image(design.symbol("X"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: copy.hideLinkPreview))
            .accessibilityIdentifier("chat.linkPreview.hide")
        }
        .frame(maxWidth: 360)
        .background(RoundedRectangle(cornerRadius: kit.radius(.xl), style: .continuous)
            .fill(kit.color(.surface, scheme: scheme)))
        .overlay(RoundedRectangle(cornerRadius: kit.radius(.xl), style: .continuous)
            .strokeBorder(kit.color(.line, scheme: scheme), lineWidth: 1))
        .opacity(shown || reduceMotion ? 1 : 0)
        .onAppear {
            withAnimation(ChatMotion.animation(.standard, reduceMotion: reduceMotion)) { shown = true }
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 2) { // design-lint: allow: desktop .atum-link-preview__words gap is 2px
            Text(verbatim: preview.siteName ?? preview.host)
                .font(kit.font(.caption))
                .foregroundStyle(kit.color(.ink3, scheme: scheme))
                .lineLimit(1)
                .truncationMode(.tail)
            if let title = preview.title {
                Text(verbatim: title)
                    .font(kit.font(.bodyStrong))
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                    .lineLimit(lines)
            }
            if let description = preview.description {
                Text(verbatim: description)
                    .font(kit.font(.callout))
                    .foregroundStyle(kit.color(.ink2, scheme: scheme))
                    .lineLimit(lines)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Desktop `:hover` fill, as the press state.
private struct LinkPreviewPressStyle: ButtonStyle {
    let kit: AtumKit
    let scheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: kit.radius(.xl), style: .continuous)
                .fill(configuration.isPressed ? kit.color(.fillHover, scheme: scheme) : .clear))
    }
}

// MARK: S15 room upgrade band

/// What the band shows (desktop #160 `RoomUpgradeBand`).
struct RoomUpgradeBandState: Equatable {
    var continuity = RoomUpgradeContinuity()
    /// The explicit join or open failed: one line, the old room stays.
    var followFailed = false

    var isEmpty: Bool { continuity.successor == nil && continuity.earlierRoomID == nil }
}

/// One band at the top of an upgraded chat: on the old room, "moved" with
/// one action (join or open the replacement, on this tap only); on the new
/// room, "continues" with "See earlier messages". A replacement that cannot
/// be confirmed or reached is one line with no action; the old history is
/// never hidden by any of it.
struct RoomUpgradeBand: View {
    let state: RoomUpgradeBandState
    let design: LiveDesign
    let busy: Bool
    let follow: () -> Void
    let openEarlier: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var kit: AtumKit { design.kit }
    private var copy: ChatActionsCopy { ChatActionsCopy(design: design) }

    var body: some View {
        if !state.isEmpty {
            VStack(spacing: 0) {
                if let successor = state.continuity.successor {
                    switch (state.followFailed, successor) {
                    case (true, _):
                        RoomUpgradeLine(label: copy.upgrade(.unavailable), action: nil, design: design)
                            .accessibilityIdentifier("chat.upgrade.unavailable")
                    case (false, .waitingForState), (false, .unavailable):
                        RoomUpgradeLine(label: copy.upgrade(.unconfirmed), action: nil, design: design)
                            .accessibilityIdentifier("chat.upgrade.unconfirmed")
                    case (false, .join):
                        RoomUpgradeLine(label: copy.upgrade(.moved),
                                        action: (copy.upgrade(.join), busy, follow), design: design)
                            .accessibilityIdentifier("chat.upgrade.join")
                    case (false, .open):
                        RoomUpgradeLine(label: copy.upgrade(.moved),
                                        action: (copy.upgrade(.open), busy, follow), design: design)
                            .accessibilityIdentifier("chat.upgrade.open")
                    }
                }
                if state.continuity.successor != nil, state.continuity.earlierRoomID != nil {
                    Rectangle().fill(kit.color(.line, scheme: scheme)).frame(height: 0.5)
                }
                if state.continuity.earlierRoomID != nil {
                    RoomUpgradeLine(label: copy.upgrade(.continues),
                                    action: (copy.upgrade(.earlier), busy, openEarlier), design: design)
                        .accessibilityIdentifier("chat.upgrade.earlier")
                }
            }
            .modifier(LiveGlass(design: design, radius: kit.radius(.lg)))
            .padding(.horizontal, kit.space(.s3))
            .padding(.top, kit.space(.s1))
            .transition(.opacity)
        }
    }
}

/// Desktop `Line`: an info mark, the sentence in muted ink, and a small
/// text button. At accessibility sizes the button goes under the sentence.
private struct RoomUpgradeLine: View {
    let label: String
    let action: (title: String, busy: Bool, run: () -> Void)?
    let design: LiveDesign

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var kit: AtumKit { design.kit }

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: kit.space(.s2)))
            : AnyLayout(HStackLayout(spacing: kit.space(.s3)))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: kit.space(.s3)) {
                Image(design.symbol("Info"))
                    .font(kit.font(.callout))
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
                    .accessibilityHidden(true)
                Text(verbatim: label)
                    .font(kit.font(.callout))
                    .foregroundStyle(kit.color(.ink2, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let action {
                Button(action: action.run) {
                    Text(verbatim: action.title)
                        .font(kit.font(.callout).weight(.semibold))
                        .foregroundStyle(kit.color(.ink, scheme: scheme))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(action.busy)
                .opacity(action.busy ? 0.5 : 1)
            }
        }
        .padding(.horizontal, kit.space(.s4))
        .padding(.vertical, action == nil ? kit.space(.s3) : 0)
        .accessibilityElement(children: .contain)
    }
}

// MARK: S14 room mention row

/// The `@room` suggestion in the composer's `@` list (desktop's role-gated
/// `@channel` row: a round mark, then the token). The token is Matrix
/// syntax, not copy; desktop's hint line names a channel, which a people
/// group is not, so the phone shows the token alone (doc: missing key).
struct RoomMentionSuggestionRow: View {
    let design: LiveDesign
    let pick: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: pick) {
            HStack(spacing: 10) { // design-lint: allow: same row metrics as ComposerMentionPicker
                Image(design.symbol("Users"))
                    .font(.title3)
                    .foregroundStyle(design.color("muted", scheme: scheme))
                    .accessibilityHidden(true)
                Text(verbatim: RoomMentionRules.token)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(design.color("ink", scheme: scheme))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14) // design-lint: allow: same row metrics as ComposerMentionPicker
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("composer.mention.room")
    }
}
