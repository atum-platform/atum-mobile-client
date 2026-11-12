import Foundation

/// The fold toggle's words (`MessageFold`), which the pinned design export
/// does not carry: the control is phone-only (desktop has no fold), so no
/// desktop table holds them yet. They are owed to the next `export:mobile`
/// under `mobileChatCopy` (docs/ports/bubble-width-collapse.md). The app
/// asks the pin first; these answer until it carries the keys. The ja, zh
/// and zh-Hant words were written for the phone and need copy review.
/// Nothing here is hand-edited into `ios/Vendor/AtumDesign`.
public enum MessageFoldPendingCopy {
    public enum Key: String, CaseIterable, Sendable {
        case showMore
        case showLess

        /// The export key the pin will carry.
        public var exportKey: String {
            "src.matrix.mobile-copy.mobileChatCopy." + rawValue
        }
    }

    public static let locales = ["en", "ja", "vi", "zh", "zh-Hant"]

    private static let tables: [String: [Key: String]] = [
        "en": [.showMore: "Show more", .showLess: "Show less"],
        "vi": [.showMore: "Xem thêm", .showLess: "Thu gọn"],
        "ja": [.showMore: "もっと見る", .showLess: "折りたたむ"],
        "zh": [.showMore: "展开", .showLess: "收起"],
        "zh-Hant": [.showMore: "展開", .showLess: "收合"],
    ]

    /// The pending value in `locale` (English for a locale without a table).
    public static func text(_ key: Key, locale: String) -> String {
        tables[locale]?[key] ?? tables["en"]?[key] ?? key.rawValue
    }
}
