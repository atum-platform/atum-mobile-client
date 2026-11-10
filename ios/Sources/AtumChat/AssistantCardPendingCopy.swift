import Foundation

/// The routine words the pinned design export does not carry yet, with the
/// exact values of desktop's `assistantCardCopies` tables
/// (`apps/desktop/src/matrix/assistant-card/copy.ts` at atum-app
/// `050ede8edf5`), in every locale the pin supports. The app asks the pin
/// first (`AssistantCardCopy`); these answer only until the next
/// `export:mobile` pin carries the keys, with no wording change. Nothing here
/// is hand-edited into `ios/Vendor/AtumDesign`.
public enum AssistantRoutinePendingCopy {
    public enum Key: String, CaseIterable, Sendable {
        case routineLoading
        case routineLoadFailed
        case routineLegacyMoving
        case routinePreparing
        case routineReadOnly

        /// The export key the pin will carry.
        public var exportKey: String {
            "src.matrix.assistant-card.copy.assistantCardCopies." + rawValue
        }
    }

    public static let locales = ["en", "ja", "vi", "zh", "zh-Hant"]

    private static let tables: [String: [Key: String]] = [
        "en": [
            .routineLoading: "Loading routines…",
            .routineLoadFailed: "Couldn’t load %1$@’s routines.",
            .routineLegacyMoving: "Moving old schedules.",
            .routinePreparing: "Getting ready…",
            .routineReadOnly: "View only",
        ],
        "vi": [
            .routineLoading: "Đang tải lịch…",
            .routineLoadFailed: "Không tải được lịch tự động của %1$@.",
            .routineLegacyMoving: "Đang chuyển lịch cũ.",
            .routinePreparing: "Đang chuẩn bị…",
            .routineReadOnly: "Chỉ xem",
        ],
        "ja": [
            .routineLoading: "ルーティンを読み込み中…",
            .routineLoadFailed: "%1$@のルーティンを読み込めませんでした。",
            .routineLegacyMoving: "古いスケジュールを移行中です。",
            .routinePreparing: "準備中…",
            .routineReadOnly: "表示のみ",
        ],
        "zh": [
            .routineLoading: "正在加载计划…",
            .routineLoadFailed: "无法加载%1$@的计划。",
            .routineLegacyMoving: "正在迁移旧计划。",
            .routinePreparing: "正在准备…",
            .routineReadOnly: "仅供参考",
        ],
        "zh-Hant": [
            .routineLoading: "正在載入排程…",
            .routineLoadFailed: "無法載入%1$@的排程。",
            .routineLegacyMoving: "正在移轉舊排程。",
            .routinePreparing: "正在準備…",
            .routineReadOnly: "僅供查看",
        ],
    ]

    /// The pending value in `locale` (English for a locale without a table),
    /// with `name` in place of `%1$@`.
    public static func text(_ key: Key, locale: String, name: String? = nil) -> String {
        let template = tables[locale]?[key] ?? tables["en"]?[key] ?? key.rawValue
        guard let name else { return template }
        return template.replacingOccurrences(of: "%1$@", with: name)
    }

    /// Desktop's `routineCount`: the value beside "Routines" on the card.
    /// Zero reads as words ("No routines", "Chưa có"), never "0".
    public static func count(_ count: Int, locale: String) -> String {
        let value = max(0, count)
        switch locale {
        case "vi": return value == 0 ? "Chưa có" : "\(value) việc"
        case "ja": return value == 0 ? "まだありません" : "\(value)件"
        case "zh": return value == 0 ? "还没有" : "\(value) 项"
        case "zh-Hant": return value == 0 ? "還沒有" : "\(value) 項"
        default: return value == 0 ? "No routines" : value == 1 ? "1 routine" : "\(value) routines"
        }
    }
}

/// A skill's name as people read it, desktop's `skillLabel`
/// (`apps/desktop/src/matrix/assistant-card/skills-popover.tsx`):
/// "google-calendar" → "Google calendar".
public enum AssistantSkillLabel {
    public static func label(_ name: String) -> String {
        let spaced = name.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let first = spaced.first else { return name }
        return first.uppercased() + spaced.dropFirst()
    }
}
