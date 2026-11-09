import AtumChat
import Foundation

/// The Settings information architecture is product state, not a reflection of
/// whichever providers happened to answer most recently. Keep these identifiers
/// and this order stable while capabilities load, fail, or remain unsupported.
/// The order and ids mirror the desktop's destinations (atum-app
/// `MATRIX_SETTINGS_DESTINATIONS`, 2026-10-25 reorg). `devices` keeps its id and
/// is this phone's own page, as it is the "This Mac" page on the desktop.
enum AccountSettingsSectionID: String, CaseIterable, Identifiable, Sendable {
    case account
    case assistants
    case protons
    case general
    case connections
    case devices
    case privacy
    case help
    case advanced

    var id: String { rawValue }
}

/// The index's three quiet groups, separated only by space, with the desktop's
/// six pages in the desktop's order (atum-app `settings-revamp.tsx`
/// `SETTINGS_NAV`, Atum Kit Settings 2026-10-28): you (Account, Assistants,
/// Connections), the app (General, Help), then the expert corner (Advanced).
/// Protons and Privacy are sections of Account, and this phone's own page is a
/// section of Connections, as "This Mac" is on the desktop; their ids stay so
/// deep links keep opening them.
enum AccountSettingsGroupID: String, CaseIterable, Identifiable, Sendable {
    case you
    case app
    case support

    var id: String { rawValue }

    var sections: [AccountSettingsSectionID] {
        switch self {
        case .you: [.account, .assistants, .connections]
        case .app: [.general, .help]
        case .support: [.advanced]
        }
    }

    /// The group's name for assistive technology. It is never drawn: the groups
    /// are told apart by space alone, as on the desktop.
    var accessibilityName: AccountSettingsText {
        switch self {
        case .you: .groupYou
        case .app: .groupApp
        case .support: .groupSupport
        }
    }
}

extension AccountSettingsSectionID {
    /// Where a destination's title comes from.
    enum Title: Equatable {
        /// Words the pinned export already carries (shared with the desktop).
        case exported(String)
        /// Words the export does not carry yet: the key is read first, then the
        /// phone's five-locale fallback.
        case owed(AccountSettingsText)
    }

    func title(isPad: Bool) -> Title {
        switch self {
        case .account: .exported("desktop.atum.settings.account")
        case .assistants: .exported("desktop.atum.roster.assistants")
        case .protons: .exported("desktop.atum.protons.title")
        case .general: .exported("desktop.atum.settings.general")
        case .connections: .owed(.destinationConnections)
        case .devices: .owed(isPad ? .thisIPad : .thisIPhone)
        case .privacy: .owed(.destinationPrivacy)
        case .help: .owed(.destinationHelp)
        case .advanced: .owed(.destinationAdvanced)
        }
    }
}

enum AccountSettingsCapability: Equatable, Sendable {
    case unknown
    case unavailable
    case available
}

/// Phone adapters that may eventually make currently unavailable rows live.
/// Memory deliberately defaults to unavailable until its real account-wide
/// adapter exists; it is never inferred from local UI state.
struct AccountSettingsCapabilities: Equatable, Sendable {
    var memory: AccountSettingsCapability
    var pairedDevices: AccountSettingsCapability
    var google: AccountSettingsCapability
    var advanced: AccountSettingsCapability

    init(memory: AccountSettingsCapability = .unavailable,
         pairedDevices: AccountSettingsCapability = .unavailable,
         google: AccountSettingsCapability = .unavailable,
         advanced: AccountSettingsCapability = .unavailable) {
        self.memory = memory
        self.pairedDevices = pairedDevices
        self.google = google
        self.advanced = advanced
    }

    static let phone = AccountSettingsCapabilities()
}

struct AccountSettingsState: Equatable, Sendable {
    private(set) var accountID: String
    private(set) var capabilities: AccountSettingsCapabilities
    private(set) var selectedSection: AccountSettingsSectionID?

    init(accountID: String,
         capabilities: AccountSettingsCapabilities = .phone) {
        self.accountID = accountID
        self.capabilities = capabilities
    }

    var sections: [AccountSettingsSectionID] {
        AccountSettingsSectionID.allCases
    }

    var groups: [AccountSettingsGroupID] {
        AccountSettingsGroupID.allCases
    }

    mutating func select(_ section: AccountSettingsSectionID?) {
        selectedSection = section
    }

    /// A different signed-in account must not inherit a pushed detail or its
    /// actions. Capability refreshes for the same account keep the current
    /// destination and preserve unknown as unknown.
    mutating func reconcile(accountID: String,
                            capabilities: AccountSettingsCapabilities) {
        if self.accountID != accountID {
            self.accountID = accountID
            selectedSection = nil
        }
        self.capabilities = capabilities
    }

    static func signOutPrompt(holdsRecoveryKey: Bool,
                              recoveryKeySavedOnThisPhone: Bool) -> SignOutPrompt {
        SignOutPrompt.decide(
            holdsRecoveryKey: holdsRecoveryKey,
            confirmedSavedOnThisPhone: recoveryKeySavedOnThisPhone
        )
    }
}

/// Phone fallbacks for Settings copy the pinned design export does not carry
/// yet. A key the export has always wins (`resolved`); the text below is used
/// until it does, and should disappear once the coordinator re-pins.
///
/// Desktop-owned keys use the desktop namespace and mirror the desktop's own
/// five-locale wording (`shared/matrix-settings-revamp-copy.ts`); phone-only
/// keys use the `phoneSettingsCopy` namespace and carry five locales authored
/// here (en, vi, ja, zh, zh-Hant). A locale a key has no text for reads English.
enum AccountSettingsText: String, CaseIterable, Sendable {
    // Desktop keys from `shared/matrix-settings-revamp-copy.ts` that the
    // desktop reorg asked to promote into the phone export.
    case destinationConnections
    case destinationPrivacy
    case destinationHelp
    case destinationAdvanced
    case providersAndRepair
    // The index's groups (assistive technology only) and the Assistants page.
    case groupYou
    case groupApp
    case groupSupport
    case assistantsLead
    case assistantReady
    case assistantPreparing
    case openAssistant
    // Phone-only keys.
    case thisIPhone
    case thisIPad
    case onYourMac
    case macAccessHelp
    case nameRequired
    case profile
    case contactAtum
    case contactUnavailable
    case assistantPrepared
    case thisDevice
    case connected
    case otherDevices
    case manageOnMac
    case availability
    case macAccess
    case notAvailable
    case loadingSettings
    case apps
    case memory
    case remembers
    case memoryDisclosure
    case activity
    case shareActivity
    case shareActivityHelp
    case reportingData
    case shareCrashReports
    case shareCrashReportsHelp
    case shareUsageData
    case shareUsageDataHelp
    case reportingFooter
    case chats
    case chatEncryption
    case display
    case appearance
    case textSize
    case usesIOSSettings
    case opensIOSSettings
    case notifications
    case protonBalance
    case noStoreKitPurchase
    case providersAndChatGPT
    case expertTools
    case technicalDetails

    var exportKey: String {
        switch self {
        case .destinationConnections: Self.desktopKey + "destinations.connections"
        case .destinationPrivacy: Self.desktopKey + "destinations.privacy"
        case .destinationHelp: Self.desktopKey + "destinations.help"
        case .destinationAdvanced: Self.desktopKey + "destinations.advanced"
        case .providersAndRepair: Self.desktopKey + "providersAndRepair"
        case .groupYou: Self.desktopKey + "groups.you"
        case .groupApp: Self.desktopKey + "groups.app"
        case .groupSupport: Self.desktopKey + "groups.support"
        case .assistantsLead: Self.desktopKey + "assistantsLead"
        case .assistantPrepared: Self.desktopKey + "assistantsEmpty"
        case .assistantReady: Self.desktopKey + "assistantReady"
        case .assistantPreparing: Self.desktopKey + "assistantPreparing"
        case .openAssistant: Self.desktopKey + "openAssistant"
        default: "shared.matrix-settings-revamp-copy.phoneSettingsCopy." + rawValue
        }
    }

    private static let desktopKey = "shared.matrix-settings-revamp-copy.copies."

    /// The export's text when it carries the key, else the phone's fallback.
    func resolved(locale: String, exported: (String) -> String?) -> String {
        exported(exportKey) ?? fallback(locale: locale)
    }

    func fallback(locale: String) -> String {
        let table = texts
        return table[Self.normalizedLocale(locale)] ?? table["en"] ?? rawValue
    }

    /// The five locales the design export knows, from any spelling of them:
    /// en, vi, ja, zh and zh-hant.
    static func normalizedLocale(_ locale: String) -> String {
        let code = locale.lowercased().replacingOccurrences(of: "_", with: "-")
        if code.hasPrefix("zh-hant") || code.hasPrefix("zh-tw") || code.hasPrefix("zh-hk") {
            return "zh-hant"
        }
        return String(code.prefix(2))
    }

    private static func t(_ en: String, _ vi: String, ja: String? = nil, zh: String? = nil,
                          zhHant: String? = nil) -> [String: String] {
        var table = ["en": en, "vi": vi]
        if let ja { table["ja"] = ja }
        if let zh { table["zh"] = zh }
        if let zhHant { table["zh-hant"] = zhHant }
        return table
    }

    private var texts: [String: String] {
        switch self {
        case .destinationConnections:
            Self.t("What Atum knows", "Atum biết gì", ja: "Atum が知っていること",
                   zh: "Atum 了解的内容", zhHant: "Atum 了解的內容")
        case .destinationPrivacy:
            Self.t("Privacy & security", "Riêng tư & bảo mật", ja: "プライバシーと安全",
                   zh: "隐私与安全", zhHant: "隱私與安全")
        case .destinationHelp:
            Self.t("Help", "Trợ giúp", ja: "ヘルプ", zh: "帮助", zhHant: "說明")
        case .destinationAdvanced:
            Self.t("Advanced", "Nâng cao", ja: "詳細", zh: "高级", zhHant: "進階")
        case .providersAndRepair:
            Self.t("AI model & repair", "Mô hình AI & sửa lỗi", ja: "AI モデルと修復",
                   zh: "AI 模型与修复", zhHant: "AI 模型與修復")
        case .groupYou:
            Self.t("You", "Bạn", ja: "あなた", zh: "你", zhHant: "你")
        case .groupApp:
            Self.t("Atum", "Atum", ja: "Atum", zh: "Atum", zhHant: "Atum")
        case .groupSupport:
            Self.t("Help and advanced", "Trợ giúp và nâng cao", ja: "ヘルプと詳細",
                   zh: "帮助与高级", zhHant: "說明與進階")
        case .assistantsLead:
            Self.t("Open an assistant to change its name, photo and how it works.",
                   "Mở một trợ lý để đổi tên, ảnh và cách trợ lý làm việc.",
                   ja: "アシスタントを開くと、名前・写真・働き方を変更できます。",
                   zh: "打开助手即可更改它的名字、照片和工作方式。",
                   zhHant: "開啟助理即可變更它的名字、照片和工作方式。")
        case .assistantReady:
            Self.t("Ready", "Sẵn sàng", ja: "準備完了", zh: "已就绪", zhHant: "已就緒")
        case .assistantPreparing:
            Self.t("Being prepared", "Đang được chuẩn bị", ja: "準備中", zh: "正在准备",
                   zhHant: "正在準備")
        case .openAssistant:
            Self.t("Open assistant", "Mở trợ lý", ja: "アシスタントを開く", zh: "打开助手",
                   zhHant: "開啟助理")
        case .thisIPhone:
            Self.t("This iPhone", "iPhone này", ja: "この iPhone", zh: "这台 iPhone",
                   zhHant: "這台 iPhone")
        case .thisIPad:
            Self.t("This iPad", "iPad này", ja: "この iPad", zh: "这台 iPad", zhHant: "這台 iPad")
        case .onYourMac:
            Self.t("On your Mac", "Trên máy Mac", ja: "お使いの Mac で", zh: "在你的 Mac 上",
                   zhHant: "在你的 Mac 上")
        case .macAccessHelp:
            Self.t("Your assistants work on your Mac. What they may do there is set on that Mac.",
                   "Trợ lý làm việc trên máy Mac của bạn. Những gì trợ lý được làm ở đó được đặt trên chính máy Mac ấy.",
                   ja: "アシスタントはお使いの Mac で作業します。そこで許可する内容は、その Mac 側で設定します。",
                   zh: "你的助手在你的 Mac 上工作。它们在那里可以做什么，由那台 Mac 来设置。",
                   zhHant: "你的助理在你的 Mac 上工作。它們在那裡可以做什麼，由那台 Mac 來設定。")
        case .nameRequired:
            Self.t("Enter a name.", "Hãy nhập tên.", ja: "名前を入力してください。",
                   zh: "请输入名字。", zhHant: "請輸入名字。")
        case .profile:
            Self.t("Profile", "Hồ sơ", ja: "プロフィール", zh: "个人资料", zhHant: "個人資料")
        case .contactAtum:
            Self.t("Contact Atum", "Liên hệ Atum")
        case .contactUnavailable:
            Self.t("In-app contact is not available yet.", "Chưa có cách liên hệ trong ứng dụng.")
        case .assistantPrepared:
            Self.t("Your assistant is being prepared", "Trợ lý đang được chuẩn bị",
                   ja: "アシスタントを準備しています", zh: "正在准备你的助手",
                   zhHant: "正在準備你的助理")
        case .thisDevice:
            Self.t("This device", "Thiết bị này")
        case .connected:
            Self.t("Connected", "Đã kết nối")
        case .otherDevices:
            Self.t("Other devices", "Thiết bị khác", ja: "ほかのデバイス", zh: "其他设备",
                   zhHant: "其他裝置")
        case .manageOnMac:
            Self.t("Manage on your Mac", "Quản lý trên máy Mac", ja: "Mac で管理",
                   zh: "在 Mac 上管理", zhHant: "在 Mac 上管理")
        case .availability:
            Self.t("Availability", "Sẵn sàng giúp bạn", ja: "利用可能性", zh: "可用性",
                   zhHant: "可用性")
        case .macAccess:
            Self.t("Access on your Mac", "Quyền truy cập trên máy Mac", ja: "Mac でのアクセス権",
                   zh: "Mac 上的访问权限", zhHant: "Mac 上的存取權限")
        case .notAvailable:
            Self.t("Not available in this version. You can still chat.",
                   "Chưa khả dụng trên phiên bản này. Bạn vẫn có thể trò chuyện.")
        case .loadingSettings:
            Self.t("Loading settings…", "Đang tải cài đặt…")
        case .apps:
            Self.t("Apps", "Ứng dụng", ja: "アプリ", zh: "应用", zhHant: "應用程式")
        case .memory:
            Self.t("Memory", "Trí nhớ", ja: "メモリ", zh: "记忆", zhHant: "記憶")
        case .remembers:
            Self.t("Atum remembers", "Atum ghi nhớ", ja: "Atum のメモリ", zh: "Atum 会记忆",
                   zhHant: "Atum 會記憶")
        case .memoryDisclosure:
            Self.t("Messages in your chats, including other people’s messages, may be processed by model providers and stored as searchable memory.",
                   "Tin nhắn trong các cuộc trò chuyện của bạn, kể cả của người khác, có thể được nhà cung cấp mô hình xử lý và lưu thành trí nhớ có thể tìm kiếm.",
                   ja: "あなたのチャット内のメッセージは、ほかの人のメッセージを含め、モデル提供者によって処理され、検索可能なメモリとして保存される場合があります。",
                   zh: "你聊天中的消息（包括其他人的消息）可能会由模型提供商处理，并存储为可搜索的记忆。",
                   zhHant: "你聊天中的訊息（包括其他人的訊息）可能會由模型供應商處理，並儲存為可搜尋的記憶。")
        case .activity:
            Self.t("Activity", "Hoạt động", ja: "アクティビティ", zh: "活动", zhHant: "活動")
        case .shareActivity:
            Self.t("Share activity", "Chia sẻ hoạt động", ja: "アクティビティを共有",
                   zh: "共享活动状态", zhHant: "分享活動狀態")
        case .shareActivityHelp:
            Self.t("Let others see your read receipts and typing.",
                   "Cho người khác thấy bạn đã xem và đang soạn.",
                   ja: "既読と入力中の状態をほかの人に表示します。",
                   zh: "让其他人看到你的已读和正在输入状态。",
                   zhHant: "讓其他人看到你的已讀與正在輸入狀態。")
        case .reportingData:
            Self.t("Reports & data", "Báo cáo & dữ liệu", ja: "レポートとデータ",
                   zh: "报告与数据", zhHant: "報告與資料")
        case .shareCrashReports:
            Self.t("Share crash reports", "Chia sẻ báo cáo sự cố",
                   ja: "クラッシュレポートを共有", zh: "共享崩溃报告",
                   zhHant: "分享當機報告")
        case .shareCrashReportsHelp:
            Self.t("Send crash details to help fix problems. No message content or account details are sent.",
                   "Gửi chi tiết sự cố để giúp khắc phục. Không gửi nội dung tin nhắn hay thông tin tài khoản.",
                   ja: "問題の修正に役立てるため、クラッシュの詳細を送信します。メッセージの内容やアカウント情報は送信しません。",
                   zh: "发送崩溃详情以帮助修复问题。不会发送消息内容或账户信息。",
                   zhHant: "傳送當機詳情以協助修正問題。不會傳送訊息內容或帳戶資訊。")
        case .shareUsageData:
            Self.t("Share usage data", "Chia sẻ dữ liệu sử dụng",
                   ja: "使用データを共有", zh: "共享使用数据", zhHant: "分享使用資料")
        case .shareUsageDataHelp:
            Self.t("Send anonymous app usage to help improve Atum. It is not linked to your account.",
                   "Gửi dữ liệu sử dụng ẩn danh để giúp cải thiện Atum. Dữ liệu không gắn với tài khoản của bạn.",
                   ja: "匿名のアプリ利用データを送信し、Atum の改善に役立てます。アカウントには紐付けられません。",
                   zh: "发送匿名的应用使用数据，帮助改进 Atum。这些数据不会关联到你的账户。",
                   zhHant: "傳送匿名的應用程式使用資料，協助改進 Atum。這些資料不會連結到你的帳戶。")
        case .reportingFooter:
            Self.t("You can turn either report off at any time. Turning one off stops sending immediately.",
                   "Bạn có thể tắt từng báo cáo bất cứ lúc nào. Tắt sẽ dừng gửi ngay.",
                   ja: "どちらのレポートもいつでもオフにできます。オフにするとすぐに送信が止まります。",
                   zh: "你可以随时关闭任一报告。关闭后立即停止发送。",
                   zhHant: "你可以隨時關閉任一報告。關閉後立即停止傳送。")
        case .chats:
            Self.t("Chats", "Cuộc trò chuyện", ja: "チャット", zh: "聊天", zhHant: "聊天")
        case .chatEncryption:
            Self.t("Encryption for each chat", "Mã hóa theo cuộc trò chuyện",
                   ja: "チャットごとの暗号化", zh: "按聊天加密", zhHant: "按聊天加密")
        case .display:
            Self.t("Display", "Hiển thị")
        case .appearance:
            Self.t("Appearance", "Giao diện")
        case .textSize:
            Self.t("Text size", "Cỡ chữ")
        case .usesIOSSettings:
            Self.t("Uses iOS settings", "Theo cài đặt iOS")
        case .opensIOSSettings:
            Self.t("Opens iOS Settings", "Mở Cài đặt iOS")
        case .notifications:
            Self.t("Notifications", "Thông báo")
        case .protonBalance:
            Self.t("Proton balance", "Số dư Proton")
        case .noStoreKitPurchase:
            Self.t("Proton purchases stay unavailable until StoreKit is ready.",
                   "Chưa thể mua Proton khi StoreKit chưa sẵn sàng.")
        case .providersAndChatGPT:
            Self.t("Providers & ChatGPT", "Nhà cung cấp & ChatGPT")
        case .expertTools:
            Self.t("Expert tools", "Công cụ chuyên sâu")
        case .technicalDetails:
            Self.t("Technical details", "Chi tiết kỹ thuật")
        }
    }
}
