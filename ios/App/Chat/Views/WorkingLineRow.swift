import AtumChat
import SwiftUI

/// agent-turns/1.4 §3: the one live `io.atum.progress` working line, shown as
/// a light muted row under the typing bubble. It never notifies, never says
/// "(đã sửa)" and disappears when its turn ends (the projection hides it;
/// this view only draws what survived).
struct WorkingLineRow: View {
    let row: ChatRow

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let theme {
            // Kit working state: the turning atom, then the step line.
            HStack(spacing: 8) {
                AtomWait()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(verbatim: row.item.body)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .foregroundStyle(theme.quiet(scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(row.accessibilityID)
        }
    }
}
