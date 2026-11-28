import Foundation

/// ML3 Home search and filter words that the pinned design export does not
/// carry yet. The app reads the export first (`AtumCopy.contains`) and falls
/// back to these tables, so a repin that carries a key takes over with no
/// code change; delete the entry in that repin.
///
/// Sources:
/// - `filter*`: desktop #154 (`49e7b533`) `roster-create-copy.ts`.
/// - `plain`, `device`, `latest`, `company`, `searched`, `skipped`, `partial`:
///   desktop #158 (`a4126a36`) `roster-message-results.tsx` `copy`. That table
///   is not exported yet; the keys below are the proposed export keys.
/// - `phone*`: PROPOSED phone wording with no desktop source. The phone
///   searches an SDK index rather than desktop's loaded history, so desktop's
///   "loaded" placeholder and coverage do not apply. Needs export review.
public enum ChatSearchCopyKey: String, CaseIterable, Sendable {
    // PENDING-COPY:src.matrix.roster-create-copy.copies.*
    case filterMenu = "src.matrix.roster-create-copy.copies.filterMenu"
    case filterAll = "src.matrix.roster-create-copy.copies.filterAll"
    case filterUnread = "src.matrix.roster-create-copy.copies.filterUnread"
    case filterFavourites = "src.matrix.roster-create-copy.copies.filterFavourites"
    // PENDING-COPY:src.matrix.roster-message-results.copy.*
    case plain = "src.matrix.roster-message-results.copy.plain"
    case device = "src.matrix.roster-message-results.copy.device"
    case latest = "src.matrix.roster-message-results.copy.latest"
    case company = "src.matrix.roster-message-results.copy.company"
    case searchedOne = "src.matrix.roster-message-results.copy.searched.one"
    case searchedOther = "src.matrix.roster-message-results.copy.searched.other"
    case skipped = "src.matrix.roster-message-results.copy.skipped"
    case partial = "src.matrix.roster-message-results.copy.partial"
    // PROPOSED phone copy.
    case phonePrivatePlaceholder = "src.matrix.roster-message-results.copy.phone.privatePlaceholder"
    case phoneDeviceChatsOne = "src.matrix.roster-message-results.copy.phone.deviceChats.one"
    case phoneDeviceChatsOther = "src.matrix.roster-message-results.copy.phone.deviceChats.other"
    case phoneEarliestMatch = "src.matrix.roster-message-results.copy.phone.earliestMatch"
    case phoneHistoryIncomplete = "src.matrix.roster-message-results.copy.phone.historyIncomplete"
    case phoneDeviceUnavailable = "src.matrix.roster-message-results.copy.phone.deviceUnavailable"
    case phonePlainFailed = "src.matrix.roster-message-results.copy.phone.plainFailed"
}

public enum ChatSearchPendingCopy {
    public static let locales = ["en", "vi", "ja", "zh", "zh-Hant"]

    /// The table's words; `%d` and `%@` are filled by `format`.
    public static func text(_ key: ChatSearchCopyKey, locale: String) -> String {
        let table = tables[key.rawValue]
        return table?[locale] ?? table?["en"] ?? key.rawValue
    }

    /// Fills `%d` with `count` and `%@` with `value`, in that order.
    public static func format(_ template: String, count: Int? = nil, value: String? = nil) -> String {
        var text = template
        if let count { text = text.replacingOccurrences(of: "%d", with: String(count)) }
        if let value { text = text.replacingOccurrences(of: "%@", with: value) }
        return text
    }

    /// English is the only table locale with a singular form here.
    public static func countKey(one: ChatSearchCopyKey, other: ChatSearchCopyKey, count: Int) -> ChatSearchCopyKey {
        count == 1 ? one : other
    }

    public static let tables: [String: [String: String]] = [
        ChatSearchCopyKey.filterMenu.rawValue: [
            "en": "Filter", "vi": "Lọc", "ja": "フィルター", "zh": "筛选", "zh-Hant": "篩選",
        ],
        ChatSearchCopyKey.filterAll.rawValue: [
            "en": "All", "vi": "Tất cả", "ja": "すべて", "zh": "全部", "zh-Hant": "全部",
        ],
        ChatSearchCopyKey.filterUnread.rawValue: [
            "en": "Unread", "vi": "Chưa đọc", "ja": "未読", "zh": "未读", "zh-Hant": "未讀",
        ],
        ChatSearchCopyKey.filterFavourites.rawValue: [
            "en": "Favourites", "vi": "Yêu thích", "ja": "お気に入り", "zh": "收藏", "zh-Hant": "我的最愛",
        ],
        ChatSearchCopyKey.plain.rawValue: [
            "en": "Plain chats", "vi": "Trò chuyện thường", "ja": "通常のチャット", "zh": "普通聊天",
            "zh-Hant": "一般聊天",
        ],
        ChatSearchCopyKey.device.rawValue: [
            "en": "Private · This device", "vi": "Riêng tư · Thiết bị này", "ja": "プライベート · この端末",
            "zh": "私密 · 此设备", "zh-Hant": "私密 · 此裝置",
        ],
        ChatSearchCopyKey.latest.rawValue: [
            "en": "Back to latest", "vi": "Về tin nhắn mới nhất", "ja": "最新に戻る", "zh": "返回最新消息",
            "zh-Hant": "返回最新訊息",
        ],
        ChatSearchCopyKey.company.rawValue: [
            "en": "Company", "vi": "Công ty", "ja": "会社", "zh": "公司", "zh-Hant": "公司",
        ],
        ChatSearchCopyKey.searchedOne.rawValue: [
            "en": "Searched %d chat", "vi": "Đã tìm trong %d cuộc trò chuyện", "ja": "%d件のチャットを検索済み",
            "zh": "已搜索 %d 个聊天", "zh-Hant": "已搜尋 %d 個聊天",
        ],
        ChatSearchCopyKey.searchedOther.rawValue: [
            "en": "Searched %d chats", "vi": "Đã tìm trong %d cuộc trò chuyện", "ja": "%d件のチャットを検索済み",
            "zh": "已搜索 %d 个聊天", "zh-Hant": "已搜尋 %d 個聊天",
        ],
        ChatSearchCopyKey.skipped.rawValue: [
            "en": "%d private not searched", "vi": "Bỏ qua %d cuộc trò chuyện riêng tư",
            "ja": "プライベート%d件は対象外", "zh": "%d 个私密聊天未搜索", "zh-Hant": "%d 個私密聊天未搜尋",
        ],
        ChatSearchCopyKey.partial.rawValue: [
            "en": "Partial results", "vi": "Kết quả một phần", "ja": "一部の結果", "zh": "部分结果",
            "zh-Hant": "部分結果",
        ],
        ChatSearchCopyKey.phonePrivatePlaceholder.rawValue: [
            "en": "Search private messages on this device", "vi": "Tìm tin nhắn riêng tư trên thiết bị này",
            "ja": "この端末のプライベートメッセージを検索", "zh": "搜索此设备上的私密消息",
            "zh-Hant": "搜尋此裝置上的私密訊息",
        ],
        ChatSearchCopyKey.phoneDeviceChatsOne.rawValue: [
            "en": "%d private chat on this device", "vi": "%d cuộc trò chuyện riêng tư trên thiết bị này",
            "ja": "この端末のプライベートチャット%d件", "zh": "此设备上的 %d 个私密聊天",
            "zh-Hant": "此裝置上的 %d 個私密聊天",
        ],
        ChatSearchCopyKey.phoneDeviceChatsOther.rawValue: [
            "en": "%d private chats on this device", "vi": "%d cuộc trò chuyện riêng tư trên thiết bị này",
            "ja": "この端末のプライベートチャット%d件", "zh": "此设备上的 %d 个私密聊天",
            "zh-Hant": "此裝置上的 %d 個私密聊天",
        ],
        ChatSearchCopyKey.phoneEarliestMatch.rawValue: [
            "en": "earliest match %@", "vi": "kết quả cũ nhất %@", "ja": "最も古い一致 %@",
            "zh": "最早的匹配 %@", "zh-Hant": "最早的符合 %@",
        ],
        ChatSearchCopyKey.phoneHistoryIncomplete.rawValue: [
            "en": "older messages may not be indexed yet", "vi": "tin nhắn cũ hơn có thể chưa được lập chỉ mục",
            "ja": "古いメッセージはまだ索引されていない場合があります", "zh": "较早的消息可能尚未编入索引",
            "zh-Hant": "較早的訊息可能尚未建立索引",
        ],
        ChatSearchCopyKey.phoneDeviceUnavailable.rawValue: [
            "en": "Private search isn’t available on this device right now",
            "vi": "Hiện chưa thể tìm riêng tư trên thiết bị này",
            "ja": "この端末では現在プライベート検索を利用できません", "zh": "此设备暂时无法进行私密搜索",
            "zh-Hant": "此裝置暫時無法進行私密搜尋",
        ],
        ChatSearchCopyKey.phonePlainFailed.rawValue: [
            "en": "Some chats couldn’t be searched", "vi": "Không tìm được trong một số cuộc trò chuyện",
            "ja": "一部のチャットを検索できませんでした", "zh": "部分聊天无法搜索", "zh-Hant": "部分聊天無法搜尋",
        ],
    ]
}

extension ChatSearchCoverageLine {
    /// The one line, segments joined by " · " (M1). `word` resolves a key
    /// export-first; `day` formats a match timestamp (milliseconds) as a
    /// short date in the reader's locale.
    public func text(word: (ChatSearchCopyKey) -> String, day: (Int64) -> String) -> String {
        func counted(_ one: ChatSearchCopyKey, _ other: ChatSearchCopyKey, _ count: Int) -> String {
            ChatSearchPendingCopy.format(word(ChatSearchPendingCopy.countKey(one: one, other: other, count: count)),
                                         count: count)
        }
        var parts = [String]()
        switch self {
        case let .plain(searched, skipped, partial):
            parts.append(counted(.searchedOne, .searchedOther, searched))
            if skipped > 0 { parts.append(ChatSearchPendingCopy.format(word(.skipped), count: skipped)) }
            if partial { parts.append(word(.partial)) }
        case let .plainFailed(searched):
            if searched > 0 { parts.append(counted(.searchedOne, .searchedOther, searched)) }
            parts.append(word(.phonePlainFailed))
        case let .device(chats, earliest, partial):
            parts.append(counted(.phoneDeviceChatsOne, .phoneDeviceChatsOther, chats))
            if let earliest { parts.append(ChatSearchPendingCopy.format(word(.phoneEarliestMatch), value: day(earliest))) }
            // The index watermark is unknown at this SDK pin: always disclose.
            parts.append(word(.phoneHistoryIncomplete))
            if partial { parts.append(word(.partial)) }
        case .deviceUnavailable:
            parts.append(word(.phoneDeviceUnavailable))
        }
        return parts.joined(separator: " · ")
    }
}
