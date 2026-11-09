import SwiftUI

/// B16: a centred time label after a gap of 60 minutes or more, unless a day
/// divider already sits there (grouping decides).
struct TimeLabelRow: View {
    let date: Date

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let theme {
            Text(verbatim: theme.time(date))
                .font(.caption)
                .foregroundStyle(theme.quiet(scheme))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
                .accessibilityHidden(true) // each row's label carries its time
        }
    }
}
