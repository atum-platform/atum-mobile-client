import Foundation

/// The semantic time label for a Home row (S2 §3.2.2). The view formats these
/// cases with exported copy and Foundation formatters in the app locale.
public enum RowTime {
    public enum Display: Equatable, Sendable {
        case justNow
        case relative(value: Int, unit: RelativeUnit)
        case yesterday
        case weekday(Date)
        case date(Date, includesYear: Bool)
    }

    public enum RelativeUnit: Equatable, Sendable { case minute, hour }

    /// `locale` is an explicit dependency of the call site: it is used by the
    /// renderer for relative/day formatting after this policy chooses its
    /// semantic form. No device locale or wall clock is read here.
    public static func display(for event: Date, now: Date, calendar: Calendar,
                               locale: Locale) -> Display {
        _ = locale
        let age = max(0, now.timeIntervalSince(event))
        if age < 60 { return .justNow }
        if age < 60 * 60 { return .relative(value: max(1, Int(age / 60)), unit: .minute) }
        if calendar.isDate(event, inSameDayAs: now) {
            return .relative(value: max(1, Int(age / (60 * 60))), unit: .hour)
        }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: event)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? Int.max
        switch days {
        case 1: return .yesterday
        case 2...6: return .weekday(event)
        default:
            return .date(event, includesYear: !calendar.isDate(event, equalTo: now, toGranularity: .year))
        }
    }
}
