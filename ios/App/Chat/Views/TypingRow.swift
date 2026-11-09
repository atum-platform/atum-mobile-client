import AtumChat
import SwiftUI

/// B10: the agent's or bot's name and three soft dots as the last row, only
/// while a real `m.typing` is active (the projection adds the row; people
/// rooms show a line above the composer instead). Static dots under Reduce
/// Motion. Accessibility label "{name} đang soạn tin…".
struct TypingRow: View {
    let names: [String]

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatReducesMotion) private var chatReducesMotion

    var body: some View {
        if let theme {
            let muted = theme.color("muted", scheme)
            // §9.1/Dot: a small agent bubble, not a bare name-and-dots line.
            // The working line renders under this bubble (`Projection`). The
            // row only shows in my assistant's or an app's 1:1 chat, which
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
            // does this one; the name is in the bubble.
            HStack(alignment: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    Text(verbatim: names.first ?? "")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.quiet(scheme))
                        .lineLimit(1)
                    TypingDots(color: muted, animated: !(reduceMotion || chatReducesMotion))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(theme.color("cell", scheme),
                            in: RoundedRectangle(cornerRadius: ChatLayout.bubbleRadius, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(theme.copy.text(.typingOne, .text(names.first ?? "")))
            .accessibilityIdentifier(AccessibilityID.rowTyping)
        }
    }
}

/// Three soft dots; they breathe in turn unless motion is off.
struct TypingDots: View {
    let color: Color
    let animated: Bool

    var body: some View {
        if animated {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                dots(phase: context.date.timeIntervalSinceReferenceDate)
            }
        } else {
            dots(phase: nil)
        }
    }

    private func dots(phase: TimeInterval?) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .opacity(opacity(index: index, phase: phase))
            }
        }
        .frame(height: 18)
    }

    private func opacity(index: Int, phase: TimeInterval?) -> Double {
        guard let phase else { return 0.6 }
        let cycle = 1.2
        let t = (phase + Double(index) * cycle / 3).truncatingRemainder(dividingBy: cycle) / cycle
        return 0.3 + 0.6 * (0.5 - 0.5 * cos(t * 2 * .pi))
    }
}
