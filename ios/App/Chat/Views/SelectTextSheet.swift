import AtumChat
import SwiftUI
import Textual

// "Chọn văn bản" (revamp plan B20): an answer's text in a sheet where any
// part of it can be selected and copied. The transcript keeps inline
// selection off, so a long-press there always opens the menu; this sheet is
// where selection lives. Links inside it go through `LinkPolicy` like every
// other link tap (`ChatActions.openLink`, B17): the sheet closes, then the
// chat screen opens the in-app page or shows the held-link line
// (`MessageActionsPresenter.openLinkFromSelectText`).

/// The answer to show, with the store's parse of it.
struct SelectTextRequest: Identifiable {
    let itemID: String
    let body: String
    /// `ConversationStore.parsedBody(for:)`; nil while the parse is pending.
    let parsed: AttributedString?
    var id: String { itemID }
}

struct SelectTextSheet: View {
    let request: SelectTextRequest
    let design: LiveDesign
    /// A link tap, routed by the chat screen once the sheet has closed.
    let openLink: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            ScrollView {
                StructuredText(request.body, parser: ParsedOrFreshMarkdown(parsed: request.parsed))
                    .font(.body)
                    .textual.textSelection(.enabled)
                    .textual.inlineStyle(design.chatInlineStyle(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("selectText.body")
                    // The structured text keeps its line layout across a
                    // Dynamic Type change (list items clipped at larger sizes,
                    // accessibility audit, S1 U run): laid out again per size.
                    .id(dynamicTypeSize)
            }
            .environment(\.openURL, OpenURLAction { url in
                openLink(url.absoluteString)
                return .handled
            })
            .navigationTitle(ChatCopy.text(design, ChatCopy.Key.selectText))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ChatCopy.text(design, ChatCopy.Key.done)) { dismiss() }
                        .accessibilityIdentifier("selectText.done")
                }
            }
        }
        .foregroundStyle(design.color("ink", scheme: scheme))
        .tint(design.color("ink", scheme: scheme))
        // The answer is content, and content is opaque (§3.9): on the glass
        // sheet the chat behind showed through the text (accessibility
        // audit, contrast, S1 U run). The opaque glass colour, as under
        // Reduce Transparency.
        .presentationBackground(design.color("glassOpaque", scheme: scheme))
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
