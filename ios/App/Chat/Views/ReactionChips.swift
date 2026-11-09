import AtumChat
import SwiftUI

/// B22: one chip per reaction with its count under the message. Tapping a
/// chip toggles mine; the screen's actions tick on the tap (B26,
/// `ChatHaptics`), never when someone else's reaction or my reaction from
/// another device arrives. Chips need no words: the emoji, the count and the
/// selected trait.
struct ReactionChips: View {
    let row: ChatRow
    let trailing: Bool

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatActions) private var actions
    @Environment(\.chatOwnUserID) private var ownUserID
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let theme {
            ChipFlow(spacing: 6, trailing: trailing) {
                ForEach(row.item.reactions, id: \.key) { reaction in
                    chip(reaction, theme: theme)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(_ reaction: ChatReaction, theme: ChatTheme) -> some View {
        let mine = reaction.includes(ownUserID)
        let ink = theme.color("ink", scheme)
        return Button {
            actions.toggleReaction(row.id, reaction.key)
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: reaction.key)
                Text(verbatim: String(reaction.count))
                    .font(.footnote.weight(.medium).monospacedDigit())
            }
            .font(.footnote)
            .padding(.horizontal, 9)
            .frame(minHeight: 28)
            .background(mine ? ink.opacity(0.12) : theme.color("cell", scheme), in: Capsule())
            .overlay(Capsule().strokeBorder(mine ? ink.opacity(0.6) : theme.color("frame", scheme), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(mine ? .isSelected : [])
        .accessibilityIdentifier("reaction." + reaction.key)
    }
}

/// Lays chips out in lines that wrap, aligned to the message's side.
struct ChipFlow: Layout {
    var spacing: CGFloat
    var trailing: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            var x = trailing ? bounds.maxX - line.width : bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                lines.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}
