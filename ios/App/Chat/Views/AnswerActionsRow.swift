import AtumChat
import SwiftUI

/// FlowPhone › Chat: the actions under the newest answer in an assistant or
/// app chat, drawn by `MessageBubbleRow` (the renderer every answer uses).
/// Copy is a 40 pt `ink-3` icon button, 8 pt left of the card's edge; it
/// reads "Sao chép", then "Đã sao chép" for a moment after a tap (desktop's
/// words). The board's thumbs-up waits for its exported label ("Good answer",
/// atum-app copy gap F5); an icon button without words is not drawn.
struct LatestAnswerCopyRow: View {
    let itemID: String

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatActions) private var actions
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    var body: some View {
        if let theme {
            Button {
                actions.copy(itemID)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                // FlowPhone: a 40 pt icon button in ink-3, 8 pt left of the
                // card's edge; the words stay its accessibility label.
                Image(theme.design.symbol(copied ? "Check" : "Copy"))
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(theme.color("muted", scheme))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.leading, -8)
            .accessibilityLabel(Text(theme.copy.text(copied ? .copied : .copy)))
            // Not the menu's "Sao chép": UI tests tell the two apart.
            .accessibilityIdentifier(Self.copyID)
        }
    }

    static let copyID = "answer.copy"
}
