import AtumChat
import SwiftUI

/// agent-turns/1.4 §3: the one live `io.atum.progress` working line, drawn as
/// desktop's `MatrixAgentWorking` (`src/matrix/typing-indicator.tsx`): the
/// turning atom in the face slot, the current step beside it ("Đang chạy tác
/// vụ…") and any checklist lines in the quiet step card under it. It is the
/// transcript's last row, standing for the typing row too, and is edited in
/// place as the turn moves on. It never notifies, never says "(đã sửa)" and
/// disappears when its turn ends (the projection hides it; this view only
/// draws what survived).
struct WorkingLineRow: View {
    let row: ChatRow

    var body: some View {
        AgentWorkingLayout(text: WorkingLineText(body: row.item.body))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier(row.accessibilityID)
    }
}
