import AtumChat
import SwiftUI

/// Polish P7 (UX audit issue 4, owner 2026-11-28): the time, "đã sửa" and,
/// while my message sends, the sending clock sit inside the bubble's
/// trailing corner, Telegram-style, as desktop draws them (`bubbleMeta` in
/// `src/matrix/app.tsx`, `.matrix-bubble-meta` in `styles.css`):
/// - The time shows on every settled bubble (`RowGrouping.showsTime`,
///   desktop `timeEligible`), not only at the end of a run.
/// - "đã sửa" comes before it on every edited bubble
///   (`RowGrouping.showsEdited`, desktop `personEdited`); no separator.
/// - While my message sends, the corner draws its time and a clock glyph
///   after it, so the corner (and the bubble) never jumps when it settles:
///   the clock simply goes. `DeliveryLine` under the bubble keeps only the
///   failed mark and the readers' faces.
///
/// Drawing only: each bubble's accessibility label already carries its
/// sender, time, edit and delivery (`ChatRowText.speech`).
struct BubbleMeta: View {
    let row: ChatRow
    /// On my own bubble: `on-bubble-own`, quietened; elsewhere desktop's
    /// faint ink.
    var onOwnBubble = false
    /// On a photo: ink on a glass capsule, so it reads over any picture.
    var onMedia = false

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    /// Whether the bubble has a corner to draw at all.
    static func shows(_ row: ChatRow) -> Bool {
        showsClock(row) || row.grouping.showsEdited
    }

    /// The time shows once settled, and on my message while it sends.
    static func showsClock(_ row: ChatRow) -> Bool {
        row.grouping.showsTime || isSending(row)
    }

    /// My message on its way: the time with the sending clock after it.
    static func isSending(_ row: ChatRow) -> Bool {
        row.item.isOwn && row.delivery == .sending
    }

    /// Desktop's own-bubble corner: the bubble's ink at 0.66
    /// (`.composer-human-message .matrix-bubble-meta`). On `bubble-own` that
    /// keeps about 7.9:1 (light) and 5.2:1 (dark); desktop's own-bubble inks
    /// are being reworked on its `feat/dark-own-bubble` branch, so recheck
    /// these when that lands.
    static let ownOpacity = 0.66

    /// The corner's type: desktop's 11 px with tabular digits.
    static let font = Font.caption2.monospacedDigit()

    var body: some View {
        if let theme {
            let kit = theme.design.kit
            let label = HStack(spacing: Self.innerGap) {
                if row.grouping.showsEdited {
                    Text(theme.copy.text(.edited))
                }
                if Self.showsClock(row) {
                    Text(verbatim: theme.time(row.item.timestamp))
                }
                if Self.isSending(row) {
                    Image(theme.design.symbol("Clock"))
                        .transition(.opacity)
                }
            }
            .font(Self.font)
            .foregroundStyle(color(theme))
            .lineLimit(1)
            .fixedSize()
            Group {
                if onMedia {
                    label
                        .padding(.horizontal, kit.space(.s2))
                        .padding(.vertical, kit.space(.s1))
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(kit.color(.glass, scheme: scheme), in: Capsule())
                        .padding(kit.space(.s2))
                } else {
                    label
                }
            }
            // The sending clock fades out as my message settles.
            .chatMotion(.quick, value: Self.isSending(row))
            .accessibilityHidden(true)
        }
    }

    /// Desktop's `gap: 0.1875rem` between "đã sửa", the time and the clock.
    static let innerGap: CGFloat = 3

    private func color(_ theme: ChatTheme) -> Color {
        let kit = theme.design.kit
        if onMedia { return kit.color(.ink, scheme: scheme) }
        // Desktop `--atum-ink-faint` (#9096A0 light, #666B74 dark) is closest
        // to the Kit's `ink-4` (#8A8F98, #6E737C) on people's bubbles:
        // about 3.2:1 on `surface` in light and 3.4:1 in dark, a touch above
        // desktop's own 3.0:1. Like desktop, it is quiet secondary type that
        // VoiceOver never reads (the bubble's label carries the time).
        return onOwnBubble ? kit.color(.onBubbleOwn, scheme: scheme).opacity(Self.ownOpacity)
                           : kit.color(.ink4, scheme: scheme)
    }

    // MARK: The room on the last line (desktop `--matrix-meta-room`)

    /// The invisible run that ends the last line of a bubble's text, as wide
    /// as its corner: desktop's `::after` spacer. A last line that has the
    /// room keeps the corner beside its last word; one that does not wraps
    /// the spacer, and with it the corner, to a line of its own. The text
    /// never runs under the corner, at any text size, in any script, and
    /// every other line keeps the bubble's full width.
    ///
    /// It is the corner's own characters, in the corner's type, cleared:
    /// one breakable space, a figure space of air, then the corner glued
    /// together with no-break spaces, and three figure spaces for the
    /// sending clock. It never needs to be exact, only never narrower than
    /// the corner (it sits 2 pt into the text's own trailing padding).
    static func room(_ row: ChatRow, theme: ChatTheme) -> AttributedString? {
        guard shows(row) else { return nil }
        var parts: [String] = []
        if row.grouping.showsEdited { parts.append(theme.copy.text(.edited)) }
        if showsClock(row) { parts.append(theme.time(row.item.timestamp)) }
        var glued = "\u{2007}" + parts.joined(separator: "\u{00A0}").replacingOccurrences(of: " ", with: "\u{00A0}")
        if isSending(row) { glued += "\u{2007}\u{2007}\u{2007}" }
        var room = AttributedString(" " + glued)
        let corner: Font = font
        room.font = corner
        room.foregroundColor = Color.clear
        return room
    }

    /// Whether `text`'s last paragraph runs right to left (its first strong
    /// letter is Hebrew or Arabic script), so its last line ends on the left
    /// and the corner goes there, over its room.
    static func endsRightToLeft(_ text: String) -> Bool {
        let last = text.split(whereSeparator: \.isNewline).last(where: { !$0.allSatisfy(\.isWhitespace) }) ?? ""
        for scalar in last.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF, 0x10800...0x10FFF, 0x1E800...0x1EFFF:
                return true
            default:
                return false
            }
        }
        return false
    }
}

extension AttributedString {
    /// The text with `room` at its end, if any.
    func endingIn(_ room: AttributedString?) -> AttributedString {
        guard let room else { return self }
        var result = self
        result.append(room)
        return result
    }
}

/// Where a bubble's corner goes.
enum BubbleCornerPlacement: Equatable {
    /// Nothing to draw: the content passes through.
    case hidden
    /// Over the room at the end of the content's last line
    /// (`BubbleMeta.room`), baseline to baseline with it; on the left when
    /// that line runs right to left.
    case inline(rightToLeft: Bool)
    /// A line of its own under the content, at the trailing edge (desktop
    /// `data-matrix-meta-flow='row'`: a code block, a table, a quote, a fold
    /// toggle or Bot API buttons last, or a file without a size line).
    case row
}

/// A bubble's content with its `BubbleMeta` in its corner.
///
/// The content is never narrowed for the corner: with `.inline` the text
/// already ends in the corner's room, so the content is laid out once, at
/// the offered width, and the corner is placed over that room. Each answer
/// is cached by the offered width and by the resulting width (SwiftUI offers
/// the bubble its own width again before placing it), and placement uses the
/// frame worked out while sizing, never a fresh measure. With nothing to
/// show the content passes through (it keeps its place and identity either
/// way, so a file's download state survives the corner changing).
struct BubbleCornerLayout: Layout {
    var placement: BubbleCornerPlacement
    /// The content's own padding at the bottom, which a corner on its own
    /// row sits inside.
    var contentBottom: CGFloat
    /// The corner's inset from the bubble's side edge and, on its own row,
    /// from the bottom.
    var edge: CGFloat
    var bottom: CGFloat

    struct Frame {
        var size: CGSize
        var contentSize: CGSize
        var metaFrame: CGRect
    }

    struct Cache {
        var entries: [(width: CGFloat?, frame: Frame)] = []

        func frame(for width: CGFloat?) -> Frame? {
            entries.first { BubbleCornerLayout.same($0.width, width) }?.frame
        }

        mutating func store(_ frame: Frame, for width: CGFloat?) {
            entries.removeAll { BubbleCornerLayout.same($0.width, width) || BubbleCornerLayout.same($0.width, frame.size.width) }
            entries.append((width, frame))
            entries.append((frame.size.width, frame))
            if entries.count > 8 { entries.removeFirst(entries.count - 8) }
        }
    }

    static func same(_ a: CGFloat?, _ b: CGFloat?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a - b) < 0.5
        default: false
        }
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        frame(proposal.width, subviews: subviews, cache: &cache).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        // The bubble is placed at the size it asked for: look its frame up by
        // that width (stored with the offered one while sizing).
        let frame = cache.frame(for: bounds.width) ?? frame(proposal.width, subviews: subviews, cache: &cache)
        guard let content = subviews.first else { return }
        content.place(at: bounds.origin, proposal: ProposedViewSize(frame.contentSize))
        for meta in subviews.dropFirst() {
            meta.place(at: CGPoint(x: bounds.minX + frame.metaFrame.minX, y: bounds.minY + frame.metaFrame.minY),
                       proposal: ProposedViewSize(frame.metaFrame.size))
        }
    }

    private func frame(_ width: CGFloat?, subviews: Subviews, cache: inout Cache) -> Frame {
        if let frame = cache.frame(for: width) { return frame }
        let frame = measure(width, subviews: subviews)
        cache.store(frame, for: width)
        return frame
    }

    private func measure(_ limit: CGFloat?, subviews: Subviews) -> Frame {
        let proposal = ProposedViewSize(width: limit, height: nil)
        guard let content = subviews.first else { return Frame(size: .zero, contentSize: .zero, metaFrame: .zero) }
        let whole = content.sizeThatFits(proposal)
        guard placement != .hidden, subviews.count > 1 else {
            return Frame(size: whole, contentSize: whole, metaFrame: .zero)
        }
        let meta = subviews[1]
        let metaSize = meta.sizeThatFits(.unspecified)

        switch placement {
        case let .inline(rightToLeft):
            // Baseline to baseline with the content's last line, which ends
            // in the corner's room.
            let dimensions = content.dimensions(in: ProposedViewSize(whole))
            let lastLine = dimensions[VerticalAlignment.lastTextBaseline]
            let metaLine = meta.dimensions(in: ProposedViewSize(metaSize))[VerticalAlignment.lastTextBaseline]
            // Content that reports no text baseline (it reads as its bottom
            // edge) puts the corner's bottom on its bottom padding instead.
            let reportsLine = lastLine < whole.height - 0.5
            let y = reportsLine ? min(max(lastLine - metaLine, 0), max(whole.height - metaSize.height, 0))
                                : max(whole.height - contentBottom - metaSize.height, 0)
            let x = rightToLeft ? edge : max(whole.width - edge - metaSize.width, 0)
            return Frame(size: whole, contentSize: whole,
                         metaFrame: CGRect(x: x, y: y, width: metaSize.width, height: metaSize.height))
        default:
            // Its own row under the content, at the trailing edge.
            let finite = limit.flatMap { $0.isFinite ? $0 : nil }
            let width = min(max(whole.width, metaSize.width + 2 * edge), finite ?? .infinity)
            let y = max(whole.height - contentBottom, 0)
            return Frame(size: CGSize(width: width, height: y + metaSize.height + bottom),
                         contentSize: CGSize(width: width, height: whole.height),
                         metaFrame: CGRect(x: max(width - edge - metaSize.width, 0), y: y,
                                           width: metaSize.width, height: metaSize.height))
        }
    }
}
