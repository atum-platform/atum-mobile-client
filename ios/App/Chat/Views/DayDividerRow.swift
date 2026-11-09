import AtumChat
import SwiftUI

/// B14: "Hôm nay", "Hôm qua", the weekday for two to six days ago, otherwise
/// the date, in the app's language (`DayLabel`).
struct DayDividerRow: View {
    let day: Date

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatToday) private var today
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let theme {
            // `today` comes from the screen, so the label changes at midnight
            // even though the row itself is unchanged (`ChatRowView` is
            // equatable and skips unchanged rows).
            Text(verbatim: DayLabel.text(for: day, now: today, calendar: .current, locale: theme.locale))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.quiet(scheme))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
