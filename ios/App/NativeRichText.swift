import SwiftUI
import AtumChat
import AtumNativeAPI

/// Markdown text in the chat (B17): agent and bot answers, notices and
/// people's messages. Foundation parses the markup (`MessageMarkup`, which
/// drops image loads and links that are not web links, and links bare web
/// addresses); this view lays the blocks out with plain SwiftUI text.
///
/// - The blocks come from `MarkdownBlocks` (AtumNativeAPI, tested): a table
///   keeps its header row and its columns.
/// - Every row knows its final height on its first layout (G-scroll, plan
///   §2.4): no state set after appearing and no geometry feedback. Textual's
///   `StructuredText` did both (its text fragments read their container
///   size through geometry actions), and inside the lazy transcript that
///   feedback hung the main thread when content changed size
///   (`docs/decisions/2026-10-11-g-scroll.md`).
/// - Text uses the given Dynamic Type style (`.body` for messages, D7), never
///   a fixed size.
/// - `parsed` is the store's parse, made once per `(row id, body)` off the
///   main actor (§2.3 rule 3); the view parses only when it has none yet.
/// - Every link tap goes to the chat's `ChatActions.openLink`, which asks
///   `LinkPolicy` and opens allowed links inside the app (§4.2 item 6);
///   nothing is handed to the Safari app.
/// - No inline text selection, so a long press always reaches the message
///   menu (B20); "Chọn văn bản" offers selection in a sheet.
/// - Links are ink, like the text (§0.2: never iOS blue), and underlined so
///   they read as links (judged on the device round).
struct NativeRichText: View {
    let bodyText: String
    var parsed: AttributedString?
    var font: Font = .body

    @Environment(\.chatActions) private var actions
    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.multilineTextAlignment) private var alignment

    var body: some View {
        let blocks = MarkdownBlocks.blocks(parsed ?? MessageMarkup.parse(bodyText))
        // `BubbleStack`, not a `VStack`: a code block, a table or a rule
        // would stretch a VStack (and its bubble) to the widest bubble even
        // under one short line; here they take the text's width, or their
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
        BubbleStack(alignment: horizontalAlignment, spacing: 8) {
            ForEach(blocks) { block in
                view(for: block)
            }
        }
        .font(font)
        .environment(\.openURL, OpenURLAction { url in
            actions.openLink(url.absoluteString)
            return .handled
        })
    }

    /// The text with its links underlined (their colour stays the ink).
    static func linked(_ text: AttributedString) -> AttributedString {
        guard text.runs.contains(where: { $0.link != nil }) else { return text }
        var result = text
        for run in text.runs where run.link != nil {
            result[run.range].underlineStyle = .single
        }
        return result
    }

    private var horizontalAlignment: HorizontalAlignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }

    @ViewBuilder private func view(for block: MarkdownBlocks.Block) -> some View {
        switch block.kind {
        case .paragraph:
            Text(Self.linked(block.text))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("rich-text.paragraph")
        case let .heading(level):
            Text(Self.linked(block.text))
                .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                .fixedSize(horizontal: false, vertical: true)
        case let .listItem(marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: marker)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
                Text(Self.linked(block.text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(block.depth) * 16)
        case .continuation:
            Text(Self.linked(block.text))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, CGFloat(block.depth) * 16 + 20)
        case .code:
            Text(block.text)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(theme?.color("cell", scheme) ?? Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme?.color("frame", scheme) ?? Color.secondary.opacity(0.2), lineWidth: 1))
        case .quote:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(theme?.color("muted", scheme).opacity(0.6) ?? Color.secondary)
                    .frame(width: 2)
                Text(Self.linked(block.text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        case let .tableRow(cells, isHeader):
            VStack(alignment: .leading, spacing: 6) {
                TableColumns(spacing: 12) {
                    ForEach(cells.indices, id: \.self) { index in
                        Text(Self.linked(cells[index]))
                            .fontWeight(isHeader ? .semibold : nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if isHeader { Divider() }
            }
        }
    }
}

/// One table row: equal columns, as the `HStack` of stretchy cells drew them,
/// so every row of a table lines up at the same width. Its natural width is
/// enough for the widest cell in every column, so a small table in a bubble
/// that hugs its content (`BubbleStack`) keeps each cell on one line when it
/// fits; offered less, the columns share the width and the cells wrap.
struct TableColumns: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let gaps = spacing * CGFloat(subviews.count - 1)
        let width = proposal.width ?? (CGFloat(subviews.count) * widestCell(subviews) + gaps)
        let column = columnWidth(width, count: subviews.count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = columnWidth(bounds.width, count: subviews.count)
        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index) * (column + spacing)
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          proposal: ProposedViewSize(width: column, height: nil))
        }
    }

    private func widestCell(_ subviews: Subviews) -> CGFloat {
        subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    }

    private func columnWidth(_ width: CGFloat, count: Int) -> CGFloat {
        max(0, (width - spacing * CGFloat(count - 1)) / CGFloat(max(1, count)))
    }
}
