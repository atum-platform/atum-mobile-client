import AtumChat
import SwiftUI

// The header a thread's `ChatScreen` draws: "Thread" with its place under it,
// the follow control and the composer's placeholder. Shared by Team Space's
// thread panel (TS-6b) and the pushed group thread (chat parity S4, M2).

/// What `ChatScreen` draws for a thread.
struct ChatThreadChrome {
    let title: String
    let place: String
    let composerPlaceholder: String
    let followed: Bool
    let followPending: Bool
    /// The capsule's word: "Following" or "Follow" (desktop `data-matrix-thread-follow`).
    let followText: String
    /// What a tap does: "Unfollow" or "Follow" (the desktop's tooltip).
    let followHint: String
    let toggleFollow: () -> Void
    /// Team Space threads read as flat runs; a group thread keeps the group's
    /// bubbles (M2 `m2-p-thread`).
    var flatRuns = true
    /// M2: the group thread's trailing "…" holds Follow / Unfollow, so the
    /// bar matches the chat's own (back · title capsule · "…"). Nil keeps
    /// Team Space's Follow capsule.
    var optionsLabel: String? = nil
}

struct ChatThreadTitle: View {
    let design: LiveDesign
    let chrome: ChatThreadChrome

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Team Space keeps its centred title; the group thread sits in the
        // left-aligned capsule M2 draws.
        ChatThreadHeading(design: design, title: chrome.title, place: chrome.place,
                          alignment: chrome.optionsLabel == nil ? .center : .leading)
            .accessibilityIdentifier("chat.thread.title")
    }
}

/// "Thread" or "Threads" with the chat's name under it (M2 header capsule).
struct ChatThreadHeading: View {
    let design: LiveDesign
    let title: String
    let place: String
    var alignment: HorizontalAlignment = .leading

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if !place.isEmpty, !typeSize.isAccessibilitySize {
                Text(verbatim: place)
                    .font(.caption)
                    .foregroundStyle(AtumVisualSystem(design: design).color(.muted, scheme: scheme))
                    .lineLimit(1)
                    .accessibilityIdentifier("chat.thread.place")
            }
        }
        // M2: the leading heading fills the bar's middle like the chat's title capsule.
        .frame(maxWidth: alignment == .leading ? .infinity : nil, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityShowsLargeContentViewer {
            Text(verbatim: place.isEmpty ? title : title + "\n" + place)
        }
    }
}

struct ChatThreadFollowButton: View {
    let design: LiveDesign
    let chrome: ChatThreadChrome

    var body: some View {
        if let optionsLabel = chrome.optionsLabel {
            Menu {
                Button(action: chrome.toggleFollow) {
                    Label {
                        Text(verbatim: chrome.followed ? chrome.followHint : chrome.followText)
                    } icon: {
                        Image(AtumVisualSystem(design: design).symbol(chrome.followed ? .bellOff : .bell))
                    }
                }
                .disabled(chrome.followPending)
                .accessibilityIdentifier(chrome.followed ? "chat.thread.unfollow" : "chat.thread.follow")
            } label: {
                AtumVisualSystem(design: design).barIcon(.moreHorizontal)
            }
            .accessibilityLabel(Text(verbatim: optionsLabel))
            .accessibilityIdentifier("chat.thread.options")
        } else {
            Button(action: chrome.toggleFollow) {
                Text(verbatim: chrome.followText)
                    .font(.subheadline.weight(chrome.followed ? .semibold : .regular))
                    .lineLimit(1)
            }
            .disabled(chrome.followPending)
            .accessibilityHint(Text(verbatim: chrome.followHint))
            .accessibilityIdentifier(chrome.followed ? "chat.thread.following" : "chat.thread.follow")
        }
    }
}
