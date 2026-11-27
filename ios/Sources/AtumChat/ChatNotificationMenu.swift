import Foundation

/// The four room notification choices, in the desktop menu's order
/// (`notification-level-menu.tsx`, `MatrixRoomNotificationMenu`).
public enum ChatNotificationMenuOption: String, CaseIterable, Identifiable, Sendable {
    case restoreDefault
    case all
    case mentionsAndKeywords
    case off

    public var id: String { rawValue }

    public var choice: ChatNotificationChoice {
        switch self {
        case .restoreDefault: .restoreDefault
        case .all: .set(.all)
        case .mentionsAndKeywords: .set(.mentionsAndKeywords)
        case .off: .set(.off)
        }
    }

    public init(_ choice: ChatNotificationChoice) {
        switch choice {
        case .restoreDefault: self = .restoreDefault
        case .set(.all): self = .all
        case .set(.mentionsAndKeywords): self = .mentionsAndKeywords
        case .set(.off): self = .off
        }
    }

    public init(_ mode: ChatNotificationMode) { self.init(.set(mode)) }

    public var title: ChatNotificationCopyKey {
        switch self {
        case .restoreDefault: .modeRestoreDefault
        case .all: .modeAll
        case .mentionsAndKeywords: .modeMentions
        case .off: .modeOff
        }
    }
}

/// The menu's words: desktop #155 `apps/desktop/shared/matrix-notification-copy.ts`.
/// PENDING-COPY: the pinned design export does not carry these keys yet. The
/// app reads the export first and falls back to `ChatNotificationPendingCopy`.
public enum ChatNotificationCopyKey: String, CaseIterable, Sendable {
    case notifications = "shared.matrix-notification-copy.copy.notifications"
    case failed = "shared.matrix-notification-copy.copy.failed"
    case encryptedMentions = "shared.matrix-notification-copy.copy.encryptedMentionsHelp"
    case modeRestoreDefault = "shared.matrix-notification-copy.copy.roomModes.inherit"
    case modeAll = "shared.matrix-notification-copy.copy.roomModes.all"
    case modeMentions = "shared.matrix-notification-copy.copy.roomModes.mentions"
    case modeOff = "shared.matrix-notification-copy.copy.roomModes.nothing"
    case helpAll = "shared.matrix-notification-copy.copy.roomModeHelp.all"
    case helpMentions = "shared.matrix-notification-copy.copy.roomModeHelp.mentions"
    case helpOff = "shared.matrix-notification-copy.copy.roomModeHelp.nothing"
}

/// What the chat info notification row shows. It keeps the confirmed Matrix
/// snapshot on screen while a change is written and until sync confirms it,
/// and lets a failed choice be retried even when it now reads as selected.
public struct ChatNotificationMenuState: Equatable, Sendable {
    public struct InFlight: Equatable, Sendable {
        public let choice: ChatNotificationChoice
        public let attempt: UInt64
        /// The write returned; the menu waits for the synced snapshot.
        public fileprivate(set) var isWritten: Bool
    }

    public private(set) var isAvailable: Bool
    public private(set) var settings: ChatNotificationSettings?
    /// A quieter pre-parity Atum channel preference (Mentions or Off) that still
    /// narrows an inherited Team Space room. Desktop shows it as the choice.
    public private(set) var legacyChannel: ChatNotificationMode?
    public private(set) var inFlight: InFlight?
    public private(set) var failedChoice: ChatNotificationChoice?
    private var attempts: UInt64 = 0

    public init(isAvailable: Bool = false) {
        self.isAvailable = isAvailable
    }

    // MARK: Inputs

    /// A complete SDK read: the first one, a synced change, or this device's own write.
    public mutating func receive(_ snapshot: ChatNotificationSettings) {
        isAvailable = true
        // A still-inherited room keeps its legacy level until the caller re-reads it.
        if !snapshot.isInherited { legacyChannel = nil }
        settings = snapshot
        if inFlight?.isWritten == true { inFlight = nil }
    }

    /// The legacy channel level read for `snapshot`. Ignored once a newer snapshot
    /// arrived or the room has an explicit Matrix mode. Only quieter levels count.
    public mutating func receiveLegacyChannel(_ level: ChatNotificationMode?, for snapshot: ChatNotificationSettings) {
        guard settings == snapshot, snapshot.isInherited else { return }
        legacyChannel = level == .mentionsAndKeywords || level == .off ? level : nil
    }

    /// The session went away or the room can no longer be read.
    public mutating func becomeUnavailable() {
        isAvailable = false
        inFlight = nil
    }

    /// Starts a write, or returns nil when the tap changes nothing.
    public mutating func begin(_ option: ChatNotificationMenuOption) -> UInt64? {
        guard shouldWrite(option) else { return nil }
        attempts += 1
        inFlight = InFlight(choice: option.choice, attempt: attempts, isWritten: false)
        failedChoice = nil
        return attempts
    }

    public mutating func finish(_ attempt: UInt64, succeeded: Bool) {
        guard var current = inFlight, current.attempt == attempt, !current.isWritten else { return }
        if succeeded {
            current.isWritten = true
            inFlight = current
        } else {
            inFlight = nil
            failedChoice = current.choice
        }
    }

    /// Sync did not change the snapshot (an unchanged retry, or a slow sync):
    /// stop waiting and show the confirmed read again.
    public mutating func stopWaiting(_ attempt: UInt64) {
        guard inFlight?.attempt == attempt, inFlight?.isWritten == true else { return }
        inFlight = nil
    }

    // MARK: Presentation

    /// The checked option. An inherited room with a quieter legacy channel level
    /// shows that level, as the desktop menu does.
    public var selected: ChatNotificationMenuOption? {
        guard let settings else { return nil }
        if settings.isInherited, let legacyChannel { return ChatNotificationMenuOption(legacyChannel) }
        return ChatNotificationMenuOption(settings.selection)
    }

    /// What the room currently does for this person.
    public var displayedMode: ChatNotificationMode? {
        guard let settings else { return nil }
        if settings.isInherited, let legacyChannel { return legacyChannel }
        return settings.effectiveMode
    }

    /// Observing, before the first complete read.
    public var isLoading: Bool { isAvailable && settings == nil }
    public var isWorking: Bool { inFlight != nil }
    public var isEnabled: Bool { isAvailable && settings != nil && inFlight == nil }
    public var hasFailed: Bool { failedChoice != nil }

    /// The row's value: the name of what the room does.
    public var value: ChatNotificationCopyKey? {
        displayedMode.map { ChatNotificationMenuOption($0).title }
    }

    /// The row's one quiet line: the failure, else what the current mode means.
    public var quietLine: ChatNotificationCopyKey? {
        if hasFailed { return .failed }
        guard let displayedMode else { return nil }
        return help(for: displayedMode)
    }

    /// Each option's hint. Restore default names the inherited mode it keeps;
    /// the explicit-mode default is not read, so it carries no hint then.
    public func hint(for option: ChatNotificationMenuOption) -> ChatNotificationCopyKey? {
        switch option {
        case .restoreDefault:
            guard let settings, settings.isInherited else { return nil }
            return ChatNotificationMenuOption(settings.effectiveMode).title
        case .all: return help(for: .all)
        case .mentionsAndKeywords: return help(for: .mentionsAndKeywords)
        case .off: return help(for: .off)
        }
    }

    /// Whether choosing `option` writes. Picking the current Matrix choice is a
    /// no-op unless a legacy level still needs retiring or that choice just failed.
    public func shouldWrite(_ option: ChatNotificationMenuOption) -> Bool {
        guard isEnabled, let settings else { return false }
        return option.choice != settings.selection || legacyChannel != nil || failedChoice == option.choice
    }

    private func help(for mode: ChatNotificationMode) -> ChatNotificationCopyKey {
        switch mode {
        case .all: .helpAll
        case .mentionsAndKeywords: settings?.hasEncryptedMentionCaveat == true ? .encryptedMentions : .helpMentions
        case .off: .helpOff
        }
    }
}

// GENERATED from atum-desktop c2099ee65b5254a0d4447c429ba61d9ad43a029a (#155)
// `apps/desktop/shared/matrix-notification-copy.ts`, verbatim. Never hand-edit a value.
public enum ChatNotificationPendingCopy {
    public static func text(_ key: ChatNotificationCopyKey, locale: String) -> String {
        let table = tables[key.rawValue]
        return table?[locale] ?? table?["en"] ?? key.rawValue
    }

    public static let tables: [String: [String: String]] = [
        "shared.matrix-notification-copy.copy.notifications": [
            "en": "Notifications",
            "vi": "Thông báo",
            "ja": "通知",
            "zh": "通知",
            "zh-Hant": "通知",
        ],
        "shared.matrix-notification-copy.copy.failed": [
            "en": "Could not save notification settings. Try again.",
            "vi": "Không lưu được cài đặt thông báo. Hãy thử lại.",
            "ja": "通知設定を保存できませんでした。もう一度お試しください。",
            "zh": "无法保存通知设置，请重试。",
            "zh-Hant": "無法儲存通知設定，請再試一次。",
        ],
        "shared.matrix-notification-copy.copy.encryptedMentionsHelp": [
            "en": "Mentions may be missed in encrypted chats",
            "vi": "Có thể bỏ sót lượt nhắc đến trong cuộc trò chuyện mã hóa",
            "ja": "暗号化されたチャットではメンションが届かないことがあります",
            "zh": "加密聊天中的提及可能无法通知",
            "zh-Hant": "加密聊天室中的提及可能無法通知",
        ],
        "shared.matrix-notification-copy.copy.roomModes.inherit": [
            "en": "Restore default",
            "vi": "Khôi phục mặc định",
            "ja": "既定に戻す",
            "zh": "恢复默认",
            "zh-Hant": "恢復預設",
        ],
        "shared.matrix-notification-copy.copy.roomModes.all": [
            "en": "All",
            "vi": "Tất cả",
            "ja": "すべて",
            "zh": "全部",
            "zh-Hant": "全部",
        ],
        "shared.matrix-notification-copy.copy.roomModes.mentions": [
            "en": "Mentions & keywords",
            "vi": "Nhắc đến và từ khóa",
            "ja": "メンションとキーワード",
            "zh": "提及和关键词",
            "zh-Hant": "提及與關鍵字",
        ],
        "shared.matrix-notification-copy.copy.roomModes.nothing": [
            "en": "Off",
            "vi": "Tắt",
            "ja": "オフ",
            "zh": "关闭",
            "zh-Hant": "關閉",
        ],
        "shared.matrix-notification-copy.copy.roomModeHelp.all": [
            "en": "Every new message",
            "vi": "Mọi tin nhắn mới",
            "ja": "すべての新着メッセージ",
            "zh": "每条新消息",
            "zh-Hant": "每則新訊息",
        ],
        "shared.matrix-notification-copy.copy.roomModeHelp.mentions": [
            "en": "Mentions and your keywords",
            "vi": "Lượt nhắc đến và từ khóa của bạn",
            "ja": "メンションと登録済みのキーワード",
            "zh": "提及和你设置的关键词",
            "zh-Hant": "提及和你設定的關鍵字",
        ],
        "shared.matrix-notification-copy.copy.roomModeHelp.nothing": [
            "en": "Silence this chat",
            "vi": "Tắt thông báo cuộc trò chuyện này",
            "ja": "このチャットの通知を停止",
            "zh": "关闭此聊天的通知",
            "zh-Hant": "關閉此聊天室的通知",
        ],
    ]
}
