import AtumChat
import SwiftUI

/// agent-turns/1.4 §3: the one live `io.atum.progress` working line, drawn as
/// desktop's `MatrixAgentWorking` (`src/matrix/typing-indicator.tsx`): the
/// turning atom in the face slot, the current step beside it ("Đang chạy tác
/// vụ…") and any checklist lines in the quiet step card under it. It is the
/// synthetic typing footer's body, updated in place as the turn moves on.
/// The progress event itself is never a transcript row. It never notifies, never says "(đã sửa)" and
/// disappears when its turn ends (the projection hides it; this view only
/// draws what survived).
struct WorkingLineRow: View {
    let row: ChatRow

    @Environment(\.chatTheme) private var theme

    var body: some View {
        let text = WorkingLineText(body: row.item.body, presentation: row.item.progress?.presentation) { key, minutes in
            guard let design = theme?.design, design.copy.contains(key) else { return nil }
            return design.text(key, arguments: minutes.map { [.number(Int64($0))] } ?? [])
        }
        AgentWorkingLayout(text: text)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier(row.accessibilityID)
    }
}
