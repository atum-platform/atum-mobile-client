import AtumNativeAPI
import SwiftUI

/// One chat: Home's face and name, and the Kit's selection mark (ink carries it).
struct SharePickerRow: View {
    let chat: ShareChat
    let isSelected: Bool
    let avatars: ShareAvatarSource
    let toggle: () -> Void

    @Environment(\.atumKit) private var kit
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: toggle) {
            if let kit {
                HStack(spacing: kit.space(.s3)) {
                    ShareChatAvatar(chat: chat, size: 40, avatars: avatars)
                    Text(verbatim: chat.name)
                        .font(kit.font(.body))
                        .foregroundStyle(kit.color(.ink, scheme: scheme))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SharePickerCheck(isSelected: isSelected)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.38)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: chat.name))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("share.chat.\(chat.id)")
    }
}

/// An empty ring, or an ink disc with a check: the Kit's selected state.
struct SharePickerCheck: View {
    let isSelected: Bool

    @ScaledMetric(relativeTo: .body) private var scaled = 24.0
    @Environment(\.atumKit) private var kit
    @Environment(\.colorScheme) private var scheme

    private var side: CGFloat { min(scaled, 24 * 1.35) }

    var body: some View {
        if let kit {
            ZStack {
                if isSelected {
                    Circle().fill(kit.color(.ink, scheme: scheme))
                    Image(share: .check)
                        .font(.system(size: side * 0.6, weight: .semibold))
                        .foregroundStyle(kit.color(.onInk, scheme: scheme))
                } else {
                    Circle().strokeBorder(kit.color(.ink4, scheme: scheme), lineWidth: 1.5)
                }
            }
            .frame(width: side, height: side)
            .accessibilityHidden(true)
        }
    }
}

/// `AtumAvatar` with the chat's cached face, if the App Group has one.
struct ShareChatAvatar: View {
    let chat: ShareChat
    let size: CGFloat
    let avatars: ShareAvatarSource

    @State private var art: AtumAvatarArt?

    var body: some View {
        AtumAvatar(kind: SharePickerDesign.avatarKind(chat), name: chat.name, art: art,
                   mark: chat.mark, size: size)
            .task(id: chat.avatarURI) {
                guard let uri = chat.avatarURI, !uri.isEmpty else { art = nil; return }
                let source = avatars
                let data = await Task.detached(priority: .userInitiated) { source.data(uri) }.value
                guard !Task.isCancelled, let data else { return }
                art = await AtumAvatarArt.load(data: data, pixelSide: AtumAvatar.thumbnailPixelSide(for: size * 1.35))
            }
    }
}
