import Foundation

/// The text of a day divider (B14): "Hôm nay", "Hôm qua", the weekday for
/// two to six days ago ("Thứ Hai"), otherwise the date.
///
/// - The day is judged in `calendar` (the app passes `Calendar.current`, the
///   device time zone).
/// - The words come from the app's language, not the device locale, so a
///   Vietnamese app on an English phone still says "Hôm nay". The caller
///   passes the locale the app's copy uses (`Locale(identifier:
///   LiveDesign.locale)`), the one source of the app language.
/// - Only today and yesterday use the system's relative formatting. On its
///   own it would say "Hôm kia" for two days ago in Vietnamese, which this
///   spec does not use; two to six days ago use an explicit weekday format.
/// - Words are Foundation's own date vocabulary, not app copy.
public enum DayLabel {
    public static func text(for day: Date, now: Date, calendar: Calendar = .current,
                            locale: Locale) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day),
                                           to: calendar.startOfDay(for: now)).day ?? .max
        switch days {
        case 0, 1:
            // The relative formatter judges "today" against the real clock,
            // not `now`, so the day is decided here and only its word is
            // borrowed: the formatter is given the real today (or yesterday).
            let realToday = Date()
            let word = days == 0
                ? realToday
                : calendar.date(byAdding: .day, value: -1, to: realToday) ?? realToday
            return formatter(.relative, calendar: calendar, locale: locale).string(from: word)
        case 2...6:
            return formatter(.weekday, calendar: calendar, locale: locale).string(from: day)
        default:
            let style: Style = calendar.isDate(day, equalTo: now, toGranularity: .year) ? .dayMonth : .dayMonthYear
            return formatter(style, calendar: calendar, locale: locale).string(from: day)
        }
    }

    // MARK: Formatter cache

    private enum Style: String {
        case relative, weekday, dayMonth, dayMonthYear
    }

    private struct Key: Hashable {
        let style: Style
        let locale: String
        let timeZone: String
        let calendar: Calendar.Identifier
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var formatters = [Key: DateFormatter]()
    }

    private static let cache = Cache()

    /// Formatters are expensive to build, so one per style, language, time
    /// zone and calendar is kept. `DateFormatter` is thread-safe for
    /// formatting once configured.
    private static func formatter(_ style: Style, calendar: Calendar, locale: Locale) -> DateFormatter {
        let key = Key(style: style, locale: locale.identifier, timeZone: calendar.timeZone.identifier,
                      calendar: calendar.identifier)
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let formatter = cache.formatters[key] { return formatter }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        // A divider stands alone: "Today", not "today".
        formatter.formattingContext = .standalone
        switch style {
        case .relative:
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.doesRelativeDateFormatting = true
        case .weekday:
            formatter.setLocalizedDateFormatFromTemplate("EEEE")
        case .dayMonth:
            formatter.setLocalizedDateFormatFromTemplate("dMMMM")
        case .dayMonthYear:
            formatter.setLocalizedDateFormatFromTemplate("dMMMMy")
        }
        cache.formatters[key] = formatter
        return formatter
    }
}
