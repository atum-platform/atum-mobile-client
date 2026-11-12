import AtumChat
import SwiftUI

/// B14: "Hôm nay", "Hôm qua", the weekday for two to six days ago, otherwise
/// the date, in the app's language (`DayLabel`). Drawn as desktop's day line
/// (`TeamSpaceDayDivider`, `src/matrix/team-space/message-parts.tsx`, and
/// `.atum-divider` in `styles.css`): a hairline across the column with the
/// day in a pill at its centre, the pill on the page's ground with a `line`
/// border and `soft` semibold caption words.
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
            let kit = theme.design.kit
            let ground = theme.color("ground", scheme)
            let line = kit.color(.line, scheme: scheme)
            Text(verbatim: DayLabel.text(for: day, now: today, calendar: .current, locale: theme.locale))
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.quiet(scheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .background(ground, in: Capsule())
                .overlay(Capsule().strokeBorder(line, lineWidth: 1))
                .frame(maxWidth: .infinity, minHeight: 28)
                .background {
                    Rectangle().fill(line).frame(height: 1)
                }
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
        }
    }
}
