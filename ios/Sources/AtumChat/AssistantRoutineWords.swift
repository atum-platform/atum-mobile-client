import Foundation

/// The routine words AS-6 adds that the pinned design export does not carry
/// yet, with the exact values of desktop's `assistantCardCopies`
/// (`apps/desktop/src/matrix/assistant-card/copy.ts`) in every locale the pin
/// supports. Desktop's function values are written as `%1$@` / `%2$@`
/// templates in their argument order. The app asks the pin first
/// (`AssistantCardCopy.polish`); these answer only until the next
/// `export:mobile` pin carries the keys (PENDING-COPY, docs/ports/w3-assistants.md).
public enum AssistantRoutinePolishCopy {
    public enum Key: String, CaseIterable, Sendable {
        case routineDialogSubtitle
        case routineNamePlaceholder
        case routineEnabledHint
        case routineQuotaReached
        case routineSuggestBrief
        case routineSuggestBriefInstruction
        case routineSaveAndRun
        case routineDailyWords
        case routineWeeklyWords
        case routineMonthlyWords
        case routineOnceWords
        case routineUnsupported
        case routineNextToday
        case routineNextTomorrow
        case routineNextDate
        case routineNextZone

        /// The export key the pin will carry.
        public var exportKey: String {
            "src.matrix.assistant-card.copy.assistantCardCopies." + rawValue
        }
    }

    public static let locales = ["en", "ja", "vi", "zh", "zh-Hant"]

    private static let tables: [String: [Key: String]] = [
        "en": [
            .routineDialogSubtitle: "Your assistant does this on schedule, then messages you the result.",
            .routineNamePlaceholder: "Leave empty to use the first words",
            .routineEnabledHint: "A turned-off routine stays saved but does not run.",
            .routineQuotaReached: "You have %1$@ routines. Delete one to add another.",
            .routineSuggestBrief: "Morning brief",
            .routineSuggestBriefInstruction: "Summarise what matters today and send it to me.",
            .routineSaveAndRun: "Save & run now",
            .routineDailyWords: "Every day at %1$@",
            .routineWeeklyWords: "%1$@ at %2$@",
            .routineMonthlyWords: "Monthly on day %1$@ at %2$@",
            .routineOnceWords: "Once, %1$@ %2$@",
            .routineUnsupported: "Another schedule",
            .routineNextToday: "Next run: today %1$@",
            .routineNextTomorrow: "Next run: tomorrow %1$@",
            .routineNextDate: "Next run: %1$@ %2$@",
            .routineNextZone: "%1$@ (%2$@)",
        ],
        "vi": [
            .routineDialogSubtitle: "Trợ lý tự làm việc này theo lịch, rồi nhắn kết quả cho bạn.",
            .routineNamePlaceholder: "Để trống, lấy từ câu đầu tiên",
            .routineEnabledHint: "Lịch tắt vẫn được lưu nhưng không chạy.",
            .routineQuotaReached: "Đã đủ %1$@ lịch. Xóa bớt một lịch để thêm mới.",
            .routineSuggestBrief: "Bản tin sáng",
            .routineSuggestBriefInstruction: "Tóm tắt những việc quan trọng hôm nay và gửi cho tôi.",
            .routineSaveAndRun: "Lưu và chạy ngay",
            .routineDailyWords: "Hằng ngày lúc %1$@",
            // Desktop: days === 'CN' ? `Chủ nhật lúc ${time}` : `Thứ ${days} lúc ${time}`.
            .routineWeeklyWords: "Thứ %1$@ lúc %2$@",
            .routineMonthlyWords: "Ngày %1$@ hằng tháng lúc %2$@",
            .routineOnceWords: "Một lần, %1$@ %2$@",
            .routineUnsupported: "Lịch khác",
            .routineNextToday: "Lần tới: hôm nay %1$@",
            .routineNextTomorrow: "Lần tới: ngày mai %1$@",
            .routineNextDate: "Lần tới: %1$@ %2$@",
            .routineNextZone: "%1$@ (%2$@)",
        ],
        "ja": [
            .routineDialogSubtitle: "アシスタントがこの作業をスケジュールどおりに行い、結果をメッセージで知らせます。",
            .routineNamePlaceholder: "空欄なら最初の数語を使います",
            .routineEnabledHint: "オフのルーティンは保存されたままで、実行されません。",
            .routineQuotaReached: "%1$@件の上限に達しました。1件削除すると追加できます。",
            .routineSuggestBrief: "朝のブリーフ",
            .routineSuggestBriefInstruction: "今日の重要なことをまとめて送ってください。",
            .routineSaveAndRun: "保存して今すぐ実行",
            .routineDailyWords: "毎日 %1$@",
            .routineWeeklyWords: "%1$@ %2$@",
            .routineMonthlyWords: "毎月%1$@日 %2$@",
            .routineOnceWords: "1回、%1$@ %2$@",
            .routineUnsupported: "別のスケジュール",
            .routineNextToday: "次回：今日 %1$@",
            .routineNextTomorrow: "次回：明日 %1$@",
            .routineNextDate: "次回：%1$@ %2$@",
            .routineNextZone: "%1$@（%2$@）",
        ],
        "zh": [
            .routineDialogSubtitle: "助手会按计划完成这件事，然后把结果发给你。",
            .routineNamePlaceholder: "留空则使用开头几个词",
            .routineEnabledHint: "关闭的定时任务仍会保存，但不会运行。",
            .routineQuotaReached: "已有 %1$@ 项计划。删除一项后才能添加。",
            .routineSuggestBrief: "早间简报",
            .routineSuggestBriefInstruction: "总结今天的重要事项并发给我。",
            .routineSaveAndRun: "保存并立即运行",
            .routineDailyWords: "每天 %1$@",
            .routineWeeklyWords: "%1$@ %2$@",
            .routineMonthlyWords: "每月 %1$@ 日 %2$@",
            .routineOnceWords: "一次，%1$@ %2$@",
            .routineUnsupported: "其他计划",
            .routineNextToday: "下次：今天 %1$@",
            .routineNextTomorrow: "下次：明天 %1$@",
            .routineNextDate: "下次：%1$@ %2$@",
            .routineNextZone: "%1$@（%2$@）",
        ],
        "zh-Hant": [
            .routineDialogSubtitle: "助理會按排程完成這件事，然後把結果傳給你。",
            .routineNamePlaceholder: "留空則使用開頭幾個詞",
            .routineEnabledHint: "關閉的排程任務仍會儲存，但不會執行。",
            .routineQuotaReached: "已有 %1$@ 項排程。刪除一項後才能新增。",
            .routineSuggestBrief: "早晨簡報",
            .routineSuggestBriefInstruction: "總結今天的重要事項並傳送給我。",
            .routineSaveAndRun: "儲存並立即執行",
            .routineDailyWords: "每天 %1$@",
            .routineWeeklyWords: "%1$@ %2$@",
            .routineMonthlyWords: "每月 %1$@ 日 %2$@",
            .routineOnceWords: "一次，%1$@ %2$@",
            .routineUnsupported: "其他排程",
            .routineNextToday: "下次：今天 %1$@",
            .routineNextTomorrow: "下次：明天 %1$@",
            .routineNextDate: "下次：%1$@ %2$@",
            .routineNextZone: "%1$@（%2$@）",
        ],
    ]

    /// The pending value in `locale` (English for a locale without a table),
    /// with `arguments` in place of `%1$@`, `%2$@`.
    public static func text(_ key: Key, locale: String, arguments: [String] = []) -> String {
        if key == .routineWeeklyWords, locale == "vi", arguments.first == "CN" {
            return "Chủ nhật lúc " + (arguments.count > 1 ? arguments[1] : "")
        }
        var value = tables[locale]?[key] ?? tables["en"]?[key] ?? key.rawValue
        for (index, argument) in arguments.enumerated() {
            value = value.replacingOccurrences(of: "%\(index + 1)$@", with: argument)
        }
        return value
    }
}

/// A routine's schedule, as the words need it (the wire type lives in
/// AtumNativeAPI; the app maps it). Weekdays run 1 (Monday) to 7 (Sunday).
public enum AssistantRoutineScheduleShape: Equatable, Sendable {
    case once(Date)
    case daily(hour: Int, minute: Int)
    case weekly(hour: Int, minute: Int, weekdays: [Int])
    case monthly(day: Int, hour: Int, minute: Int)
    case other
}

/// Desktop's `routines-words.ts`: the schedule sentence, the next-run line
/// with the zone only when it differs from this device's, the weekday words,
/// and the stored name when the person leaves it empty.
public enum AssistantRoutineWords {
    public typealias Resolve = (AssistantRoutinePolishCopy.Key, [String]) -> String

    private static let weekdayChip: [String: [String]] = [
        "en": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
        "vi": ["Thứ 2", "Thứ 3", "Thứ 4", "Thứ 5", "Thứ 6", "Thứ 7", "CN"],
        "ja": ["月", "火", "水", "木", "金", "土", "日"],
        "zh": ["周一", "周二", "周三", "周四", "周五", "周六", "周日"],
        "zh-Hant": ["週一", "週二", "週三", "週四", "週五", "週六", "週日"],
    ]
    private static let weekdayWord: [String: [String]] = [
        "vi": ["2", "3", "4", "5", "6", "7", "CN"],
    ]
    private static let separator: [String: String] = [
        "en": ", ", "vi": ", ", "ja": "・", "zh": "、", "zh-Hant": "、",
    ]

    /// Desktop `matrixRoutineWeekdayChip`: the editor's day buttons.
    public static func weekdayChip(_ day: Int, locale: String) -> String {
        let table = weekdayChip[locale] ?? weekdayChip["en"]!
        return table.indices.contains(day - 1) ? table[day - 1] : String(day)
    }

    /// Desktop `matrixRoutineWeekdayList`: "Mon, Wed, Fri", "2, 4, 6".
    public static func weekdayList(_ days: [Int], locale: String) -> String {
        let words = weekdayWord[locale] ?? weekdayChip[locale] ?? weekdayChip["en"]!
        return days.map { words.indices.contains($0 - 1) ? words[$0 - 1] : String($0) }
            .joined(separator: separator[locale] ?? ", ")
    }

    /// Always 24-hour, as the contract stores it: "8:05", "17:30".
    public static func clock(hour: Int, minute: Int) -> String {
        "\(hour):" + (minute < 10 ? "0\(minute)" : "\(minute)")
    }

    /// "Every day at 8:00", "Mon, Wed at 9:30", "Thứ 2, 4 lúc 9:30".
    public static func schedule(_ shape: AssistantRoutineScheduleShape, timezone: String,
                                locale: String, resolve: Resolve) -> String {
        switch shape {
        case let .once(date):
            let parts = wallParts(date, timezone: timezone)
            return resolve(.routineOnceWords, [dateWords(date, timezone: timezone, locale: locale, withYear: false),
                                                clock(hour: parts.hour, minute: parts.minute)])
        case let .daily(hour, minute):
            return resolve(.routineDailyWords, [clock(hour: hour, minute: minute)])
        case let .weekly(hour, minute, weekdays):
            return resolve(.routineWeeklyWords, [weekdayList(weekdays, locale: locale),
                                                  clock(hour: hour, minute: minute)])
        case let .monthly(day, hour, minute):
            return resolve(.routineMonthlyWords, [String(day), clock(hour: hour, minute: minute)])
        case .other:
            return resolve(.routineUnsupported, [])
        }
    }

    /// The row's second line: the next run in the routine's own zone, and
    /// the zone only when its clock differs from this device's (two names for
    /// one offset read as one zone). Nil for a paused routine: the caller
    /// says "Paused".
    public static func next(at nextRunAt: Date?, enabled: Bool, timezone: String,
                            deviceTimeZone: TimeZone, now: Date = Date(),
                            locale: String, resolve: Resolve) -> String? {
        guard enabled, let nextRunAt else { return nil }
        let nextParts = wallParts(nextRunAt, timezone: timezone)
        let nowParts = wallParts(now, timezone: timezone)
        let days = dayIndex(nextParts) - dayIndex(nowParts)
        let time = clock(hour: nextParts.hour, minute: nextParts.minute)
        let line: String
        switch days {
        case 0: line = resolve(.routineNextToday, [time])
        case 1: line = resolve(.routineNextTomorrow, [time])
        default:
            line = resolve(.routineNextDate, [dateWords(nextRunAt, timezone: timezone, locale: locale,
                                                        withYear: nextParts.year != nowParts.year), time])
        }
        let zone = TimeZone(identifier: timezone)
        let same = zone.map { $0.secondsFromGMT(for: nextRunAt) == deviceTimeZone.secondsFromGMT(for: nextRunAt) } ?? true
        return same ? line : resolve(.routineNextZone, [line, timezone])
    }

    /// Desktop `matrixRoutineTitle`: the instruction's first sentence, up to
    /// eight words and 120 characters, for a routine left without a name.
    public static func title(fromInstruction instruction: String) -> String {
        let collapsed = instruction.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var sentence = collapsed
        if let range = collapsed.range(of: "(?<=[.!?…])\\s", options: .regularExpression) {
            sentence = String(collapsed[..<range.lowerBound])
        }
        let words = sentence.split(separator: " ", omittingEmptySubsequences: false).prefix(8)
            .joined(separator: " ")
        let title = String(words.prefix(120)).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? String(collapsed.prefix(120)).trimmingCharacters(in: .whitespaces) : title
    }

    // MARK: Private

    private struct WallParts { let year, month, day, hour, minute: Int }

    private static func wallParts(_ date: Date, timezone: String) -> WallParts {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return WallParts(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0,
                         hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    private static func dayIndex(_ parts: WallParts) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) ?? Date(timeIntervalSince1970: 0)
        return Int((date.timeIntervalSince1970 / 86_400).rounded())
    }

    /// Vietnamese reads "21/10" (and "/2026" when the year differs); other
    /// locales read the day and short month as their calendar writes them.
    private static func dateWords(_ date: Date, timezone: String, locale: String, withYear: Bool) -> String {
        if locale.hasPrefix("vi") {
            let parts = wallParts(date, timezone: timezone)
            let day = parts.day < 10 ? "0\(parts.day)" : "\(parts.day)"
            let month = parts.month < 10 ? "0\(parts.month)" : "\(parts.month)"
            return "\(day)/\(month)" + (withYear ? "/\(parts.year)" : "")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.timeZone = TimeZone(identifier: timezone) ?? .current
        formatter.setLocalizedDateFormatFromTemplate(withYear ? "dMMMy" : "dMMM")
        return formatter.string(from: date)
    }
}
