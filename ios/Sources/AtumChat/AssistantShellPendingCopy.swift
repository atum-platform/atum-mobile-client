import Foundation

/// Desktop shell words for deleting (retiring) an assistant and for a name
/// the platform refuses, with the exact values of desktop's `t.matrixShell`
/// tables (`apps/desktop/src/i18n/{en,vi,ja,zh,zh-hant}.ts`) in every locale
/// the pin supports. The pinned export does not carry `desktop.matrixShell.*`
/// yet; the app asks the pin first (`AssistantRetireCopy`), and these answer
/// only until the next `export:mobile` pin carries the keys, with no wording
/// change (PENDING-COPY, docs/ports/w3-assistants.md).
public enum AssistantShellPendingCopy {
    public enum Key: String, CaseIterable, Sendable {
        /// "Delete {name} permanently?"
        case agentRetireTitle
        /// What deleting does, with the name twice.
        case agentRetireBody
        case agentRetireConfirm
        case agentRetireFailed
        case agentCancel
        /// The platform refused a new assistant's name for a reason the
        /// card's own problem lines do not cover.
        case agentNameRefused

        public var exportKey: String { "desktop.matrixShell." + rawValue }
    }

    public static let locales = ["en", "ja", "vi", "zh", "zh-Hant"]

    private static let tables: [String: [Key: String]] = [
        "en": [
            .agentRetireTitle: "Delete %1$@ permanently?",
            .agentRetireBody: "%1$@ stops answering for good and can't be brought back. Your private chats with %1$@ disappear from your chat list on all your devices, and you can't open them again. Group chats stay.",
            .agentRetireConfirm: "Delete",
            .agentRetireFailed: "Couldn't delete the assistant. Try again.",
            .agentCancel: "Cancel",
            .agentNameRefused: "That name can't be used. Try another one.",
        ],
        "vi": [
            .agentRetireTitle: "Xóa %1$@ vĩnh viễn?",
            .agentRetireBody: "%1$@ sẽ ngừng trả lời và không thể khôi phục. Các cuộc trò chuyện riêng với %1$@ sẽ bị xóa khỏi danh sách trò chuyện trên mọi thiết bị của bạn và bạn sẽ không xem lại được. Các cuộc trò chuyện nhóm vẫn được giữ lại.",
            .agentRetireConfirm: "Xóa",
            .agentRetireFailed: "Chưa xóa được trợ lý. Hãy thử lại.",
            .agentCancel: "Hủy",
            .agentNameRefused: "Không dùng được tên này. Hãy thử tên khác.",
        ],
        "ja": [
            .agentRetireTitle: "%1$@ を完全に削除しますか？",
            .agentRetireBody: "%1$@ は今後応答せず、元に戻せません。%1$@ との個別チャットは、すべてのデバイスのチャット一覧から消え、再び開くことはできません。グループチャットはそのまま残ります。",
            .agentRetireConfirm: "削除",
            .agentRetireFailed: "アシスタントを削除できませんでした。もう一度お試しください。",
            .agentCancel: "キャンセル",
            .agentNameRefused: "この名前は使えません。別の名前をお試しください。",
        ],
        "zh": [
            .agentRetireTitle: "永久删除 %1$@？",
            .agentRetireBody: "%1$@ 将不再回复，且无法恢复。你与 %1$@ 的单独对话会从你所有设备的对话列表中消失，之后无法再查看。群聊不受影响。",
            .agentRetireConfirm: "删除",
            .agentRetireFailed: "未能删除助手，请重试。",
            .agentCancel: "取消",
            .agentNameRefused: "此名称无法使用，请换一个。",
        ],
        "zh-Hant": [
            .agentRetireTitle: "永久刪除 %1$@？",
            .agentRetireBody: "%1$@ 將不再回覆，且無法復原。你與 %1$@ 的單獨對話會從你所有裝置的對話清單中消失，之後無法再查看。群組對話不受影響。",
            .agentRetireConfirm: "刪除",
            .agentRetireFailed: "無法刪除助理，請再試一次。",
            .agentCancel: "取消",
            .agentNameRefused: "此名稱無法使用，請換一個。",
        ],
    ]

    /// The pending value in `locale` (English for a locale without a table),
    /// with `name` in place of every `%1$@`.
    public static func text(_ key: Key, locale: String, name: String? = nil) -> String {
        let template = tables[locale]?[key] ?? tables["en"]?[key] ?? key.rawValue
        guard let name else { return template }
        return template.replacingOccurrences(of: "%1$@", with: name)
    }
}

/// Whether the phone offers "Delete {name}…" for an assistant: desktop draws
/// it only for a non-primary assistant (`assistant-card.tsx:445-461`), and
/// only where the host can reach the platform's retire route. The primary is
/// never retired; the platform refuses it too.
public enum AssistantRetirePolicy {
    public static func offersDelete(isPrimary: Bool, canRetire: Bool) -> Bool {
        !isPrimary && canRetire
    }
}
