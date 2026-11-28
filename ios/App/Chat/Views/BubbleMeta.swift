import AtumChat
import SwiftUI

/// Polish P7 (UX audit issue 4, owner 2026-11-28): the time and "đã sửa"
/// sit inside the bubble's trailing corner, Telegram-style, instead of in a
/// caption row under every bubble. Only the meaning's placement changes:
/// - The clock shows on the last bubble of each sender run only
///   (`RowGrouping.showsTime`, decided by `Grouping.layout`'s runs:
///   a change of sender or a gap of more than 5 minutes ends a run).
/// - "đã sửa" shows on every edited bubble (`RowGrouping.showsEdited`).
/// - While my message sends, its clock's place is kept, empty, so the bubble
///   does not grow when it settles; the sending glyph stays in the
///   `DeliveryLine` under it.
///
/// Drawing only: each bubble's accessibility label already carries its
/// sender, time and edit (`ChatRowText.speech`), on every bubble.
struct BubbleMeta: View {
    let row: ChatRow
    /// On my own bubble: `on-bubble-own`, softened; elsewhere the chat's
    /// quiet `soft`.
    var onOwnBubble = false
    /// On a photo: ink on a glass capsule, so it reads over any picture.
    var onMedia = false

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    /// Whether the bubble has a corner to draw (or keep) at all.
    static func shows(_ row: ChatRow) -> Bool {
        row.grouping.showsTime || row.grouping.showsEdited || keepsTimeSlot(row)
    }

    /// My newest message while it sends: the clock it will show once it is
    /// sent keeps its place, invisible.
    static func keepsTimeSlot(_ row: ChatRow) -> Bool {
        row.item.isOwn && row.delivery == .sending && row.grouping.position?.endsRun == true
    }

    /// `on-bubble-own` at this opacity keeps 8.8:1 (light) and 5.7:1 (dark)
    /// against `bubble-own` (Kit tokens), above the audit's 4.5:1.
    static let ownOpacity = 0.7

    var body: some View {
        if let theme {
            let kit = theme.design.kit
            let showsTime = row.grouping.showsTime
            let slot = !showsTime && Self.keepsTimeSlot(row)
            let label = HStack(spacing: kit.space(.s1)) {
                if row.grouping.showsEdited {
                    Text(theme.copy.text(.edited))
                    if showsTime || slot { Text(verbatim: "·") }
                }
                if showsTime || slot {
                    Text(verbatim: theme.time(row.item.timestamp))
                        .monospacedDigit()
                        .opacity(slot ? 0 : 1)
                }
            }
            .font(.caption2)
            .foregroundStyle(color(theme))
            .fixedSize(horizontal: false, vertical: true)
            Group {
                if onMedia {
                    label
                        .padding(.horizontal, kit.space(.s2))
                        .padding(.vertical, kit.space(.s1))
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(kit.color(.glass, scheme: scheme), in: Capsule())
                        .padding(kit.space(.s2))
                        .opacity(slot && !row.grouping.showsEdited ? 0 : 1)
                } else {
                    label
                }
            }
            // The clock fades in as my message settles, instead of popping.
            .chatMotion(.quick, value: showsTime)
            .accessibilityHidden(true)
        }
    }

    private func color(_ theme: ChatTheme) -> Color {
        if onMedia { return theme.design.kit.color(.ink, scheme: scheme) }
        return onOwnBubble ? theme.design.kit.color(.onBubbleOwn, scheme: scheme).opacity(Self.ownOpacity)
                           : theme.quiet(scheme)
    }
}

/// A bubble's content with its `BubbleMeta` in the trailing corner.
///
/// Telegram's placement, without measuring glyphs: when the content keeps
/// its line count with the meta's width taken off the right (`allowsInline`,
/// plain text with nothing under it), the meta sits on the last line,
/// baseline to baseline, and the bubble widens by the meta. Otherwise it
/// takes its own row under the content, at the trailing edge. Either way it
/// never covers a word, at any text size: the content is measured with the
/// meta's room taken out, never overlapped. With nothing to show the content
/// passes through untouched (the content keeps its place and identity, so a
/// file's download state survives the clock moving to a newer bubble).
struct BubbleMetaLayout: Layout {
    var showsMeta: Bool
    var allowsInline: Bool
    /// The content's own padding on the trailing side and at the bottom.
    var contentTrailing: CGFloat
    var contentBottom: CGFloat
    /// Between the last word and the meta on a shared line.
    var gap: CGFloat
    /// The meta's inset from the bubble's trailing edge and, on its own row,
    /// from the bottom.
    var edge: CGFloat
    var bottom: CGFloat

    struct Frame {
        var size: CGSize
        var contentProposal: ProposedViewSize
        var metaFrame: CGRect
    }

    struct Cache {
        var limit: CGFloat?
        var frame: Frame?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        frame(limit: proposal.width, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let frame = frame(limit: bounds.width, subviews: subviews, cache: &cache)
        guard let content = subviews.first else { return }
        content.place(at: bounds.origin, proposal: frame.contentProposal)
        for meta in subviews.dropFirst() {
            meta.place(at: CGPoint(x: bounds.minX + frame.metaFrame.minX, y: bounds.minY + frame.metaFrame.minY),
                       proposal: ProposedViewSize(frame.metaFrame.size))
        }
    }

    private func frame(limit: CGFloat?, subviews: Subviews, cache: inout Cache) -> Frame {
        if let frame = cache.frame, cache.limit == limit { return frame }
        let frame = measure(limit: limit, subviews: subviews)
        cache = Cache(limit: limit, frame: frame)
        return frame
    }

    private func measure(limit: CGFloat?, subviews: Subviews) -> Frame {
        let full = ProposedViewSize(width: limit, height: nil)
        guard let content = subviews.first else { return Frame(size: .zero, contentProposal: full, metaFrame: .zero) }
        let whole = content.sizeThatFits(full)
        guard showsMeta, subviews.count > 1 else {
            return Frame(size: whole, contentProposal: full, metaFrame: .zero)
        }
        let meta = subviews[1]
        let finite = limit.flatMap { $0.isFinite ? $0 : nil }
        let metaSize = meta.sizeThatFits(ProposedViewSize(width: finite.map { max($0 - 2 * edge, 0) }, height: nil))

        // On the last line: the content laid out with the meta's room taken
        // off, if that keeps its line count.
        if allowsInline {
            let extra = max(gap + metaSize.width + edge - contentTrailing, 0)
            let narrow = finite.map { $0 - extra }
            if narrow.map({ $0 > 0 }) ?? true {
                let proposal = ProposedViewSize(width: narrow, height: nil)
                let fitted = narrow == nil ? whole : content.sizeThatFits(proposal)
                if abs(fitted.height - whole.height) < 0.5 {
                    let width = fitted.width + extra
                    // Baseline to baseline where the content reports its
                    // last line; a custom layout (`BubbleStack`) reports only
                    // its bottom edge, so then the meta's bottom meets the
                    // last line's box, above the content's bottom padding.
                    let lastLine = content.dimensions(in: proposal)[VerticalAlignment.lastTextBaseline]
                    let metaLine = meta.dimensions(in: ProposedViewSize(metaSize))[VerticalAlignment.lastTextBaseline]
                    let reportsLine = lastLine < fitted.height - contentBottom / 2
                    let y = max(reportsLine ? lastLine - metaLine
                                            : fitted.height - contentBottom - metaSize.height, 0)
                    let height = max(fitted.height, y + metaSize.height)
                    return Frame(size: CGSize(width: width, height: height), contentProposal: proposal,
                                 metaFrame: CGRect(x: width - edge - metaSize.width, y: y,
                                                   width: metaSize.width, height: metaSize.height))
                }
            }
        }

        // Its own row under the content, at the trailing edge.
        let width = min(max(whole.width, metaSize.width + 2 * edge), finite ?? .infinity)
        let y = max(whole.height - contentBottom, 0)
        return Frame(size: CGSize(width: width, height: y + metaSize.height + bottom), contentProposal: full,
                     metaFrame: CGRect(x: max(width - edge - metaSize.width, 0), y: y,
                                       width: metaSize.width, height: metaSize.height))
    }
}
