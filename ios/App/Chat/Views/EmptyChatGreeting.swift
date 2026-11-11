import AtumChat
import SwiftUI

/// HC-4: an assistant's empty chat, as desktop's `AssistantGreeting`
/// (`greeting.tsx`) draws it: the assistant's face, the time of day's
/// greeting, one line of invitation, and three starters that fill the
/// composer without sending. Centred above the composer. Kit Display role for
/// the greeting (system semibold, STYLE §10); the Kit boards allow no serif.
struct EmptyChatGreeting<Face: View>: View {
    /// The assistant's own face, drawn by the chat (the same one the title
    /// capsule shows).
    let face: Face
    /// Nil while the composer cannot take a starter (no composer, read-only):
    /// then no chips are offered, as desktop shows none without a composer.
    let onPickStarter: ((String) -> Void)?

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let theme {
            // The hour is read when the chat draws, as desktop does on render.
            let period = EmptyChatPolicy.period(hour: Calendar.current.component(.hour, from: Date()))
            VStack(spacing: 0) {
                face
                    .accessibilityHidden(true)
                Text(theme.copy.text(EmptyChatPolicy.greetingKey(period)))
                    .font(.system(.title, weight: .semibold))
                    .foregroundStyle(theme.color("ink", scheme))
                    .padding(.top, 16)
                    .accessibilityAddTraits(.isHeader)
                Text(theme.copy.text(.greetingPrompt))
                    .font(.body)
                    .foregroundStyle(theme.quiet(scheme))
                    .padding(.top, 8)
                if let onPickStarter {
                    StarterChips(theme: theme, onPick: onPickStarter)
                        .padding(.top, 24)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.chatGreeting)
        }
    }
}

/// Desktop's three starters (`chat-copy.ts` `starters`): capsule outlines that
/// wrap and centre. Each one puts its words in the composer; nothing is sent.
private struct StarterChips: View {
    let theme: ChatTheme
    let onPick: (String) -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        CenteredChipFlow(spacing: 8) {
            ForEach(Array(EmptyChatPolicy.starters.enumerated()), id: \.offset) { index, starter in
                Button {
                    onPick(theme.copy.text(starter.text))
                } label: {
                    Text(theme.copy.text(starter.label))
                        .font(.subheadline)
                        .foregroundStyle(theme.color("soft", scheme))
                        // Wraps instead of clipping at the largest text sizes
                        // (the audit's "Text clipped"); one line is a capsule.
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minHeight: 36)
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(theme.color("frame", scheme), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("chat.starter.\(index)")
            }
        }
    }
}

/// Centred wrapping rows, as desktop's `flex-wrap justify-center`.
private struct CenteredChipFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.indices {
                let size = fitted(subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// A chip never grows past the line (a long translation wraps).
    private func fitted(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let natural = subview.sizeThatFits(.unspecified)
        guard natural.width > width else { return natural }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row]()
        var current = Row()
        for index in subviews.indices {
            let size = fitted(subviews[index], width: width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A person's or a group's empty chat: desktop's quiet "No messages yet."
/// (`copy.ts` `empty`), never the assistant greeting.
struct EmptyChatNote: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let theme {
            Text(theme.copy.text(.noMessages))
                .font(.body)
                .foregroundStyle(theme.quiet(scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .accessibilityIdentifier("chat.empty")
        }
    }
}
