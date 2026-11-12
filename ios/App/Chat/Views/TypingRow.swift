import AtumChat
import SwiftUI

/// B10 in my assistant's chat, as desktop draws it (`MatrixAgentWorking`,
/// `src/matrix/typing-indicator.tsx`): while the agent's real `m.typing` is
/// active and its turn has no live working line yet, the turning atom sits
/// alone in the face slot as the transcript's last row. No bubble, no name,
/// no dots. Once a working line lives, the same synthetic footer carries its
/// body (`Projection`, `WorkingLineRow`). Every other chat says who is typing in
/// the line above the composer (`TypingNames.presentation`).
/// Accessibility label "{name} đang soạn tin…" (desktop's `aria-label`).
struct TypingRow: View {
    let names: [String]

    @Environment(\.chatTheme) private var theme

    var body: some View {
        if let theme {
            AgentWorkingLayout(text: WorkingLineText(current: nil, steps: []))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(theme.copy.text(.typingOne, .text(names.first ?? "")))
                .accessibilityAddTraits(.updatesFrequently)
                .accessibilityIdentifier(AccessibilityID.rowTyping)
        }
    }
}

/// Desktop's working row: the atom centred in a face-wide slot, then the
/// current step in body type and, under it, the quiet step card. Kit tokens
/// as desktop uses them: `--atum-avatar-md` 28 pt slot, `ak-icon` 18 pt
/// atom, `--ak-s1`/`--ak-s2` gaps, `ink-2` line, `ink-3` caption steps on
/// `fill-quiet` with the `lg` radius.
struct AgentWorkingLayout: View {
    let text: WorkingLineText

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    static let slot: CGFloat = 28
    static let atom: CGFloat = 18

    var body: some View {
        if let theme {
            let kit = theme.design.kit
            HStack(alignment: .top, spacing: kit.space(.s2)) {
                AtomWait()
                    .frame(width: Self.atom, height: Self.atom)
                    .foregroundStyle(kit.color(.ink2, scheme: scheme))
                    .frame(width: Self.slot)
                    .padding(.top, kit.space(.s1))
                    .accessibilityHidden(true)
                if let current = text.current {
                    VStack(alignment: .leading, spacing: kit.space(.s1)) {
                        Text(verbatim: current)
                            .font(kit.font(.body))
                            .foregroundStyle(kit.color(.ink2, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                        if !text.steps.isEmpty {
                            steps(kit)
                        }
                    }
                }
            }
            .padding(.vertical, kit.space(.s2))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func steps(_ kit: AtumKit) -> some View {
        VStack(alignment: .leading, spacing: kit.space(.s1)) {
            ForEach(Array(text.steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: kit.space(.s2)) {
                    if step.done, let theme {
                        Image(theme.design.symbol("Check"))
                            .font(.caption)
                            .frame(width: 16, height: 16)
                    } else {
                        Circle()
                            .strokeBorder(kit.color(.ink3, scheme: scheme),
                                          style: StrokeStyle(lineWidth: 1, dash: [1, 2]))
                            .frame(width: 16, height: 16)
                    }
                    Text(verbatim: step.text)
                        .font(kit.font(.caption))
                }
                .foregroundStyle(kit.color(.ink3, scheme: scheme))
            }
        }
        .padding(kit.space(.s2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kit.color(.fillQuiet, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: kit.radius(.lg), style: .continuous))
    }
}
