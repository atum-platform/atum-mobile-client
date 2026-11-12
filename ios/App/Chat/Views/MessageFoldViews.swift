import AtumChat
import AtumNativeAPI
import SwiftUI
import UIKit

/// The session's fold book (`MessageFoldBook`): one for the app's life, so a
/// reader's Show more survives scrolling, timeline diffs and reopening the
/// chat. Not observed: a row re-reads it when its own inputs change, and the
/// toggle redraws its row itself.
@MainActor
final class MessageFoldStore {
    static let session = MessageFoldStore()

    private(set) var book = MessageFoldBook()

    func readerSees(_ reading: Set<String>, among growing: Set<String>) {
        guard !growing.isEmpty else { return }
        book.readerSees(reading, among: growing)
    }

    func isFolded(_ id: String, isLong: Bool, isGrowing: Bool) -> Bool {
        book.isFolded(id, isLong: isLong, isGrowing: isGrowing)
    }

    func toggle(_ id: String, wasFolded folded: Bool) {
        book.toggle(id, wasFolded: folded)
    }
}

/// How many lines a message body takes in its bubble, worked out before
/// layout so the row knows on its first pass whether it folds (G-scroll: no
/// state set after appearing, no geometry feedback). TextKit measures each
/// markdown block with the fonts `NativeRichText` draws it in, at the widest
/// bubble's text width for this window. An estimate for a threshold with
/// eight lines of slack (`MessageFold`); the fold itself clips the real
/// layout.
@MainActor
enum MessageFoldMeasure {
    /// The bubble's horizontal padding on both sides (`MessageBubbleRow`).
    static let bubblePadding: CGFloat = 28

    /// The body's line height at `size`: the unit of the fold.
    static func lineHeight(_ size: DynamicTypeSize) -> CGFloat {
        font(.body, size).lineHeight.rounded(.up)
    }

    /// Whether the body folds: longer than `MessageFold.foldsAfterLines`.
    static func isLong(id: String, body: String, parsed: AttributedString?, isOwn: Bool,
                       textWidth: CGFloat, size: DynamicTypeSize) -> Bool {
        // Cheap first: a body this short never reaches 20 lines, even in a
        // narrow bubble with CJK text.
        let breaks = body.reduce(0) { $1.isNewline ? $0 + 1 : $0 }
        if body.utf16.count < 200, breaks < MessageFold.foldsAfterLines { return false }
        let key = CacheKey(id: id, body: body.hashValue, width: Int(textWidth), size: size)
        if let known = cache[key] { return known }
        let height = isOwn
            ? textHeight(body, font: font(.body, size), width: textWidth)
            : blocksHeight(MarkdownBlocks.blocks(parsed ?? MessageMarkup.parse(body)), width: textWidth, size: size)
        let long = MessageFold.isLong(lines: MessageFold.lines(height: Double(height),
                                                               lineHeight: Double(lineHeight(size))))
        if cache.count > 2_000 { cache.removeAll() }
        cache[key] = long
        return long
    }

    /// The text width of the widest bubble in this window, with a face gutter
    /// `gutter` points wide (`BubbleGeometry.maxWidth`), or of a flat run's
    /// text column.
    static func textWidth(gutter: CGFloat, flat: Bool) -> CGFloat {
        let window = windowWidth()
        let row = window - 2 * ChatLayout.sideMargin
        if flat { return max(120, row - MessageBubbleRow.flatFace - MessageBubbleRow.flatGap) }
        let bubble = BubbleGeometry.maxWidth(row: Double(row), gutter: Double(gutter),
                                             margin: Double(ChatLayout.sideMargin))
        return max(60, CGFloat(bubble) - bubblePadding)
    }

    private struct CacheKey: Hashable {
        var id: String
        var body: Int
        var width: Int
        var size: DynamicTypeSize
    }

    private static var cache: [CacheKey: Bool] = [:]

    private static func windowWidth() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let window = scene?.keyWindow ?? scene?.windows.first
        return window?.bounds.width ?? 390
    }

    private static func font(_ style: UIFont.TextStyle, _ size: DynamicTypeSize, weight: UIFont.Weight? = nil,
                             monospaced: Bool = false) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        if monospaced { return UIFont.monospacedSystemFont(ofSize: base.pointSize, weight: weight ?? .regular) }
        if let weight { return UIFont.systemFont(ofSize: base.pointSize, weight: weight) }
        return base
    }

    private static func textHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = (text as NSString).boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: [.font: font], context: nil)
        return rect.height.rounded(.up)
    }

    /// `NativeRichText`'s blocks, stacked with its 8 pt spacing.
    private static func blocksHeight(_ blocks: [MarkdownBlocks.Block], width: CGFloat, size: DynamicTypeSize) -> CGFloat {
        let body = font(.body, size)
        var total: CGFloat = 0
        for (index, block) in blocks.enumerated() {
            if index > 0 { total += 8 }
            let text = String(block.text.characters)
            switch block.kind {
            case .paragraph:
                total += textHeight(text, font: body, width: width)
            case let .heading(level):
                let heading = level <= 2 ? font(.title3, size, weight: .semibold) : font(.headline, size)
                total += textHeight(text, font: heading, width: width)
            case .listItem:
                total += textHeight(text, font: body, width: width - CGFloat(block.depth) * 16 - 20)
            case .continuation:
                total += textHeight(text, font: body, width: width - CGFloat(block.depth) * 16 - 20)
            case .code:
                total += textHeight(text, font: font(.callout, size, monospaced: true), width: width - 20) + 20
            case .quote:
                total += textHeight(text, font: body, width: width - 10)
            case .rule:
                total += 1
            case let .tableRow(cells, isHeader):
                let count = CGFloat(max(1, cells.count))
                let column = max(1, (width - 12 * (count - 1)) / count)
                let cellFont = isHeader ? font(.body, size, weight: .semibold) : body
                total += cells.map { textHeight(String($0.characters), font: cellFont, width: column) }.max() ?? 0
                if isHeader { total += 7 }
            }
        }
        return total
    }
}

extension View {
    /// A folded body: its first `MessageFold.foldedLines` lines, the last one
    /// fading out. The text keeps its full layout under the clip, so its
    /// width (and the bubble's) does not change when it folds.
    @ViewBuilder func messageFold(_ folded: Bool, lineHeight: CGFloat) -> some View {
        if folded {
            self
                .frame(height: lineHeight * CGFloat(MessageFold.foldedLines), alignment: .top)
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                            .frame(height: lineHeight)
                    }
                }
        } else {
            self
        }
    }
}

/// The fold's toggle: a full-width label at the bottom of the bubble, "Show
/// more" when folded and "Show less" when open (`MessageFoldPendingCopy`
/// until the export carries the keys). Its own button for VoiceOver; the
/// message element above it reads the whole text either way.
struct MessageFoldToggle: View {
    let rowID: String
    let folded: Bool
    let action: () -> Void

    @Environment(\.chatTheme) private var theme

    var body: some View {
        Button(action: action) {
            Text(verbatim: word)
                .font(.subheadline.weight(.semibold))
                // 44 pt: the Kit's smallest tap target (the accessibility
                // audit's hit-area rule).
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("message.fold.\(rowID)")
    }

    private var word: String {
        let key: MessageFoldPendingCopy.Key = folded ? .showMore : .showLess
        guard let design = theme?.design else { return MessageFoldPendingCopy.text(key, locale: "en") }
        // PENDING-COPY: src.matrix.mobile-copy.mobileChatCopy.showMore / showLess
        if design.copy.contains(key.exportKey) { return design.text(key.exportKey) }
        return MessageFoldPendingCopy.text(key, locale: design.locale)
    }
}
