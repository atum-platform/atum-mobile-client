import SwiftUI

/// B15: a quiet "Tin nhắn mới" line where the SDK put the read marker when
/// the chat opened. The projection hides it when it would be the last row.
struct ReadMarkerRow: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let theme {
            let muted = theme.color("muted", scheme)
            HStack(spacing: 10) {
                Rectangle().fill(muted.opacity(0.35)).frame(height: 1).accessibilityHidden(true)
                Text(theme.copy.text(.readMarker))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.quiet(scheme))
                    .fixedSize()
                Rectangle().fill(muted.opacity(0.35)).frame(height: 1).accessibilityHidden(true)
            }
        }
    }
}
