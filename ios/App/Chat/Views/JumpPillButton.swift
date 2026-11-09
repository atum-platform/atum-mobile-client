import AtumChat
import SwiftUI

/// B4: the jump pill. Following: nothing. Scrolled up with nothing new: a
/// down arrow, once more than one screen up ("Đến tin nhắn mới nhất" for
/// VoiceOver). New messages: "N tin nhắn mới". Tapping animates to the
/// bottom; the store clears it when the bottom is reached by any means.
struct JumpPillButton: View {
    let pill: JumpPill
    let action: () -> Void

    @Environment(\.chatTheme) private var theme

    var body: some View {
        if let theme, pill != .hidden {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(theme.design.symbol("ArrowDown"))
                        .font(.footnote.weight(.semibold))
                    if case let .count(count) = pill {
                        Text(theme.copy.text(.newMessages, .number(Int64(count))))
                            .font(.footnote.weight(.semibold))
                    }
                }
                .padding(.horizontal, pill == .arrow ? 0 : 14)
                .frame(minWidth: 40, minHeight: 40)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityIdentifier(AccessibilityID.pillLatest)
            .modifier(PillLabel(pill: pill, theme: theme))
        }
    }
}

private struct PillLabel: ViewModifier {
    let pill: JumpPill
    let theme: ChatTheme

    func body(content: Content) -> some View {
        if pill == .arrow {
            content.accessibilityLabel(theme.copy.text(.jumpToLatest))
        } else {
            content.accessibilityHint(theme.copy.text(.jumpToLatest))
        }
    }
}
