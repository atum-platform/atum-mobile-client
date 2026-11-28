import Foundation

// GENERATED from atum-desktop PR #160 merge 3424194e0c176ef92d9d979c1176ee2e03698b74
// (`apps/desktop/src/matrix/room-upgrade-copy.ts`, verbatim). PENDING-COPY: the
// pinned design export (a13e7275) predates #160. The app asks the pin first, so
// the next repin replaces these with no wording change. Never hand-edit a value.
public enum RoomUpgradePendingCopy {
    public enum Key: String, CaseIterable, Sendable {
        case moved, open, join, unconfirmed, unavailable, continues, earlier

        /// The export key the pin will carry (desktop `const copies` in
        /// `room-upgrade-copy.ts`, exported like `chat-copy.copies`).
        public var exportKey: String { "src.matrix.room-upgrade-copy.copies." + rawValue }
    }

    public static let locales = ["en", "vi", "ja", "zh", "zh-Hant"]

    private static let tables: [String: [Key: String]] = [
        "en": [
            .moved: "This chat moved to a new room.",
            .open: "Open new room",
            .join: "Join new room",
            .unconfirmed: "This chat moved, but the new room can’t be confirmed.",
            .unavailable: "The new room isn’t available. Earlier messages stay here.",
            .continues: "This room continues an earlier one.",
            .earlier: "See earlier messages",
        ],
        "vi": [
            .moved: "Cuộc trò chuyện này đã chuyển sang phòng mới.",
            .open: "Mở phòng mới",
            .join: "Vào phòng mới",
            .unconfirmed: "Cuộc trò chuyện đã chuyển, nhưng chưa xác nhận được phòng mới.",
            .unavailable: "Không vào được phòng mới. Tin nhắn cũ vẫn ở đây.",
            .continues: "Phòng này tiếp nối một phòng trước.",
            .earlier: "Xem tin nhắn trước đó",
        ],
        "ja": [
            .moved: "この会話は新しいルームに移動しました。",
            .open: "新しいルームを開く",
            .join: "新しいルームに参加",
            .unconfirmed: "会話は移動しましたが、新しいルームを確認できません。",
            .unavailable: "新しいルームを利用できません。以前のメッセージはここに残ります。",
            .continues: "このルームは以前のルームの続きです。",
            .earlier: "以前のメッセージを見る",
        ],
        "zh": [
            .moved: "此对话已移至新房间。",
            .open: "打开新房间",
            .join: "加入新房间",
            .unconfirmed: "对话已移动，但无法确认新房间。",
            .unavailable: "无法使用新房间。更早的消息仍保留在此。",
            .continues: "此房间延续自之前的房间。",
            .earlier: "查看更早的消息",
        ],
        "zh-Hant": [
            .moved: "此對話已移至新房間。",
            .open: "開啟新房間",
            .join: "加入新房間",
            .unconfirmed: "對話已移動，但無法確認新房間。",
            .unavailable: "無法使用新房間。更早的訊息仍保留於此。",
            .continues: "此房間延續自先前的房間。",
            .earlier: "查看更早的訊息",
        ],
    ]

    /// The pending value in `locale` (English for a locale without a table).
    public static func text(_ key: Key, locale: String) -> String {
        tables[locale]?[key] ?? tables["en"]?[key] ?? key.rawValue
    }
}
