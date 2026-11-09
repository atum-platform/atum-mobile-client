import AtumChat
import SwiftUI

// A failed send (revamp plan B8): tapping "Chưa gửi được" under the bubble
// offers "Thử lại" and "Xóa". The text is never lost: the SDK keeps the
// parked request until it is retried or aborted, and "Thử lại" picks the
// right call by `isRecoverable` (`ChatActions.retrySend` → the store →
// `Delivery.retry`). "Xóa" aborts only this send (`ChatActions.deleteSend`);
// the message never left this phone, so it asks nothing first.

/// The failed send to act on.
struct FailedSendRequest: Identifiable, Equatable {
    let itemID: String
    /// The text, so the sheet shows which message it is about.
    let body: String
    let kind: ChatItem.Kind
    let media: ChatMedia?
    var id: String { itemID }
}

struct FailedSendSheet: View {
    let request: FailedSendRequest
    let design: LiveDesign
    let actions: ChatActions

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Fixed detents and a scroll view: a detent that followed the
        // content's measured height moved the sheet each time the text size
        // changed, and squeezed the content until it caught up (the title,
        // the message or "Thử lại" clipped at larger sizes, accessibility
        // audit, S1 U run). Half height holds the content at every standard
        // size; at the largest sizes it scrolls, or the sheet pulls up.
        ScrollView {
            content
                // Laid out again per text size, as the select-text sheet's
                // body (the sheet's texts were reported clipped at larger
                // sizes while their old layout lasted).
                .id(dynamicTypeSize)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The message is content, and content is opaque (§3.9): through the
        // glass, the red "Chưa gửi được" under the bubble behind showed in
        // the message's text (contrast, dark mode, S1 U run). The opaque
        // glass colour, as under Reduce Transparency and in the select-text
        // sheet.
        .presentationBackground(design.color("glassOpaque", scheme: scheme))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var content: some View {
        VStack(spacing: 14) {
            Text(ChatCopy.text(design, ChatCopy.Key.notSent))
                .font(.headline)
            mediaPreview
            if !request.body.isEmpty {
                Text(verbatim: request.body)
                    .font(.subheadline)
                    // `soft`, the chat's colour for small secondary words.
                    .foregroundStyle(design.color("soft", scheme: scheme))
                    .multilineTextAlignment(.center)
                    // Two lines say which message it is; at the accessibility
                    // sizes two lines hold a few words, so the whole text shows
                    // (the sheet scrolls past the screen).
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            VStack(spacing: 10) {
                Button {
                    dismiss()
                    actions.retrySend(request.itemID)
                } label: {
                    Text(ChatCopy.text(design, ChatCopy.Key.retry))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(design.color("ground", scheme: scheme))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Capsule().fill(design.color("ink", scheme: scheme)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.sendRetry)

                Button(role: .destructive) {
                    dismiss()
                    actions.deleteSend(request.itemID)
                } label: {
                    Text(ChatCopy.text(design, ChatCopy.Key.delete))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(design.color("danger", scheme: scheme))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        // Opaque: the sheet is already glass, and glass
                        // never stacks on glass (§3.9).
                        .background(Capsule().fill(design.color("bubble", scheme: scheme)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.sendDelete)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var mediaPreview: some View {
        switch request.kind {
        case .image:
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(design.color("bubble", scheme: scheme))
                .frame(width: 64, height: 64)
                .overlay {
                    Image(design.symbol("Photo"))
                        .foregroundStyle(design.color("muted", scheme: scheme))
                }
                .accessibilityHidden(true)
        case let .file(name):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(design.color("bubble", scheme: scheme))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(design.symbol(MediaKind(
                            mimetype: request.media?.mimetype,
                            filename: request.media?.filename ?? name
                        ).glyphAlias))
                    }
                Text(verbatim: request.media?.filename ?? name)
                    .font(.subheadline)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        default:
            EmptyView()
        }
    }
}
