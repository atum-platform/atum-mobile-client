import Foundation

/// Exported desktop words the picker uses, from the generated `ShareLocalizable`
/// table (scripts/generate-share-localization.py binds them to the pinned export).
/// Words the export does not have yet are `SharePendingCopy` (PENDING-COPY).
enum SharePickerCopy {
    static let table = "ShareLocalizable"

    enum Key: String, CaseIterable {
        case cancel = "src.matrix.chat-copy.copies.cancel"
        /// The desktop Forward picker's own words.
        case send = "src.matrix.chat-copy.copies.forwardSend"
        case search = "src.matrix.chat-copy.copies.forwardSearch"
        case empty = "src.matrix.chat-copy.copies.forwardEmpty"
        /// The desktop group picker's section and count.
        case recent = "src.matrix.group-picker-copy.copies.recent"
        case selected = "src.matrix.group-picker-copy.copies.selected"
        case chats = "desktop.atum.roster.title"
        case done = "desktop.common.done"
        case photo = "src.matrix.mobile-copy.mobileChatCopy.photo"
        case video = "src.matrix.mobile-copy.mobileChatCopy.media.kind.video"
        case file = "src.matrix.mobile-copy.mobileChatCopy.file"
    }

    static func text(_ key: Key, bundle: Bundle = .main) -> String {
        bundle.localizedString(forKey: key.rawValue, value: nil, table: table)
    }

    /// "3 selected", with the export's plural rule.
    static func selected(_ count: Int, bundle: Bundle = .main) -> String {
        String.localizedStringWithFormat(text(.selected, bundle: bundle), count)
    }
}
