import AtumChat
import Foundation

/// The Settings information architecture is product state, not a reflection of
/// whichever providers happened to answer most recently. Keep these identifiers
/// and this order stable while capabilities load, fail, or remain unsupported.
/// The order and ids mirror the desktop's destinations (atum-app
/// `MATRIX_SETTINGS_DESTINATIONS`). Every id still opens something, so deep
/// links keep working; `page` says which page draws it.
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

    /// The page a destination is drawn on, as the desktop's `settingsPageOf`
    /// (atum-app `settings-revamp.tsx`, 050ede8edf5): Protons and Privacy are
    /// sections of Account. The desktop folds "This Mac" into Connections but
    /// no longer draws it there (DESIGN.md: no This Mac section); this phone's
    /// own row is in Account's devices list, so `devices` opens Account.
    /// Advanced holds only desktop-only tools (local model setup, repair of a
    /// local assistant, developer pages; parity audit lane 5 §2.9), so the
    /// phone has no Advanced page and its id opens Help, its group's sibling.
    var page: AccountSettingsSectionID {
        switch self {
        case .protons, .privacy, .devices: .account
        case .advanced: .help
        default: self
        }
    }
}

/// The index's quiet groups, separated only by space, with the desktop's pages
/// in the desktop's order (atum-app `settings-revamp.tsx` `SETTINGS_NAV`): you
/// (Account, Assistants, Connections), then the app (General, Help). The
/// desktop's third group holds only Advanced, which is desktop-only by design.
enum AccountSettingsGroupID: String, CaseIterable, Identifiable, Sendable {
    case you
    case app

    var id: String { rawValue }

    var sections: [AccountSettingsSectionID] {
        switch self {
        case .you: [.account, .assistants, .connections]
        case .app: [.general, .help]
        }
    }

    /// The group's name for assistive technology. It is never drawn: the groups
    /// are told apart by space alone, as on the desktop.
    var accessibilityName: AccountSettingsText {
        switch self {
        case .you: .groupYou
        case .app: .groupApp
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

/// What a capability row says. The desktop's own words: "Not available yet"
/// while there is no phone adapter; nothing at all once it is live.
enum AccountSettingsCapabilityStatus: Equatable, Sendable {
    case loading
    case notAvailableYet
    case live

    init(_ capability: AccountSettingsCapability) {
        switch capability {
        case .unknown: self = .loading
        case .unavailable: self = .notAvailableYet
        case .available: self = .live
        }
    }
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

/// The order of the Account page's sections, after the profile, as the
/// desktop's `AccountPane` then `PrivacyPane` draw them (050ede8edf5): how Atum
/// answers, your devices, chats, memory, activity, ignored people, and the
/// recovery key last, unless this phone must restore messages first.
enum AccountPageSection: String, CaseIterable, Sendable {
    case howAtumAnswers
    case recovery
    case devices
    case chats
    case memory
    case activity
    case ignored

    static func order(restoresFirst: Bool) -> [AccountPageSection] {
        let everyone: [AccountPageSection] = [.devices, .chats, .memory, .activity, .ignored]
        return restoresFirst
            ? [.howAtumAnswers, .recovery] + everyone
            : [.howAtumAnswers] + everyone + [.recovery]
    }
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

/// Help › Contact us when no Founder is reachable: desktop's "Email support"
/// (`founder/contact-us.tsx`), a mail draft to Atum's support mailbox.
enum AccountSupportMail {
    static let mailbox = "support@atumplatform.com"

    static func url(subject: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = mailbox
        components.queryItems = [URLQueryItem(name: "subject", value: subject)]
        return components.url
    }
}

/// Phone fallbacks for Settings copy the pinned design export does not carry
/// yet. A key the export has always wins (`resolved`); the text below is used
/// until it does, and should disappear once the coordinator re-pins.
///
/// Desktop-owned keys use the desktop namespace and are the desktop's own
/// five-locale wording (atum-app `shared/matrix-settings-revamp-copy.ts` at
/// 050ede8edf5); phone-only keys use the `phoneSettingsCopy` namespace. A
/// locale a key has no text for reads English.
enum AccountSettingsText: String, CaseIterable, Sendable {
    // Desktop keys from `shared/matrix-settings-revamp-copy.ts`.
    case destinationConnections
    case destinationPrivacy
    case destinationHelp
    case destinationAdvanced
    case groupYou
    case groupApp
    case assistantsLead
    case assistantPrepared
    case assistantReady
    case assistantPreparing
    case openAssistant
    case howAtumAnswers
    case protonsLeft
    case topUp
    case walletUnavailableHelp
    case yourSubscription
    case subscriptionHelp
    case notAvailableYet
    case google
    case apps
    case otherDevices
    case memory
    case remembers
    case remembersHelp
    case memoryDisclosure
    case activity
    case shareActivity
    case shareActivityHelp
    case chats
    case chatsStored
    case chatsStoredHelp
    case encryptionDetail
    // Phone-only keys (`phoneSettingsCopy`).
    case thisIPhone
    case thisIPad
    case nameRequired
    case shareCrashReports
    case shareCrashReportsHelp
    case shareUsageData
    case shareUsageDataHelp
    case reportingFooter
    case usesIOSSettings
    case opensIOSSettings

    var exportKey: String {
        switch self {
        case .destinationConnections: Self.desktopKey + "destinations.connections"
        case .destinationPrivacy: Self.desktopKey + "destinations.privacy"
        case .destinationHelp: Self.desktopKey + "destinations.help"
        case .destinationAdvanced: Self.desktopKey + "destinations.advanced"
        case .groupYou: Self.desktopKey + "groups.you"
        case .groupApp: Self.desktopKey + "groups.app"
        case .assistantPrepared: Self.desktopKey + "assistantsEmpty"
        case .assistantsLead, .assistantReady, .assistantPreparing, .openAssistant,
             .howAtumAnswers, .protonsLeft, .topUp, .walletUnavailableHelp,
             .yourSubscription, .subscriptionHelp, .notAvailableYet, .google, .apps,
             .otherDevices, .memory, .remembers, .remembersHelp, .memoryDisclosure,
             .activity, .shareActivity, .shareActivityHelp, .chats, .chatsStored,
             .chatsStoredHelp, .encryptionDetail:
            Self.desktopKey + rawValue
        case .thisIPhone, .thisIPad, .nameRequired, .shareCrashReports,
             .shareCrashReportsHelp, .shareUsageData, .shareUsageDataHelp,
             .reportingFooter, .usesIOSSettings, .opensIOSSettings:
            "shared.matrix-settings-revamp-copy.phoneSettingsCopy." + rawValue
        }
    }

    private static let desktopKey = "shared.matrix-settings-revamp-copy.copies."

    /// Keys the pinned export carries with words the desktop has since
    /// replaced. The desktop renamed "What Atum knows" back to "Connections"
    /// in atum-app `1043f1b48d7` (2026-10-31); the pinned export
    /// (atum-desktop `c14d74a`) predates it. Until the re-pin, the desktop's
    /// current words are read here instead of the stale export.
    static let staleInPinnedExport: Set<AccountSettingsText> = [.destinationConnections]

    /// The export's text when it carries the key, else the phone's fallback.
    func resolved(locale: String, exported: (String) -> String?) -> String {
        if Self.staleInPinnedExport.contains(self) { return fallback(locale: locale) }
        return exported(exportKey) ?? fallback(locale: locale)
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

    private static func t(_ en: String, _ vi: String, ja: String, zh: String,
                          zhHant: String) -> [String: String] {
        ["en": en, "vi": vi, "ja": ja, "zh": zh, "zh-hant": zhHant]
    }

    private var texts: [String: String] {
        switch self {
        case .destinationConnections:
            Self.t("Connections", "Kết nối", ja: "接続", zh: "连接", zhHant: "連接")
        case .destinationPrivacy:
            Self.t("Privacy & security", "Riêng tư & bảo mật", ja: "プライバシーと安全",
                   zh: "隐私与安全", zhHant: "隱私與安全")
        case .destinationHelp:
            Self.t("Help", "Trợ giúp", ja: "ヘルプ", zh: "帮助", zhHant: "說明")
        case .destinationAdvanced:
            Self.t("Advanced", "Nâng cao", ja: "詳細", zh: "高级", zhHant: "進階")
        case .groupYou:
            Self.t("You", "Bạn", ja: "あなた", zh: "你", zhHant: "你")
        case .groupApp:
            Self.t("Atum", "Atum", ja: "Atum", zh: "Atum", zhHant: "Atum")
        case .assistantsLead:
            Self.t("Open an assistant to change its name, photo and how it works.",
                   "Mở một trợ lý để đổi tên, ảnh và cách trợ lý làm việc.",
                   ja: "アシスタントを開くと、名前・写真・働き方を変更できます。",
                   zh: "打开助手即可更改它的名字、照片和工作方式。",
                   zhHant: "開啟助理即可變更它的名字、照片和工作方式。")
        case .assistantPrepared:
            Self.t("Your assistant is being prepared", "Trợ lý đang được chuẩn bị",
                   ja: "アシスタントを準備しています", zh: "正在准备你的助手",
                   zhHant: "正在準備你的助理")
        case .assistantReady:
            Self.t("Ready", "Sẵn sàng", ja: "準備完了", zh: "已就绪", zhHant: "已就緒")
        case .assistantPreparing:
            Self.t("Being prepared", "Đang được chuẩn bị", ja: "準備中", zh: "正在准备",
                   zhHant: "正在準備")
        case .openAssistant:
            Self.t("Open assistant", "Mở trợ lý", ja: "アシスタントを開く", zh: "打开助手",
                   zhHant: "開啟助理")
        case .howAtumAnswers:
            Self.t("How Atum answers", "Cách Atum trả lời", ja: "Atum の回答方法",
                   zh: "Atum 的回答方式", zhHant: "Atum 的回答方式")
        case .protonsLeft:
            // `%1$@` is the whole-Proton balance, already formatted.
            Self.t("%1$@ left · used for Atum’s built-in models and the Store",
                   "Còn %1$@ · dùng cho mô hình tích hợp của Atum và Cửa hàng",
                   ja: "残り %1$@ · Atum の内蔵モデルとストアで使用",
                   zh: "剩余 %1$@ · 用于 Atum 内置模型和商店",
                   zhHant: "剩餘 %1$@ · 用於 Atum 內建模型和商店")
        case .topUp:
            Self.t("Top up", "Nạp thêm", ja: "チャージ", zh: "充值", zhHant: "儲值")
        case .walletUnavailableHelp:
            Self.t("Proton balance and activity will appear here when the wallet is available.",
                   "Số dư và hoạt động Proton sẽ xuất hiện tại đây khi ví khả dụng.",
                   ja: "ウォレットが利用可能になると、Proton の残高と履歴がここに表示されます。",
                   zh: "钱包可用后，Proton 余额和活动会显示在这里。",
                   zhHant: "錢包可用後，Proton 餘額與活動會顯示在這裡。")
        case .yourSubscription:
            Self.t("Your subscription", "Gói đăng ký của bạn", ja: "あなたのサブスクリプション",
                   zh: "你的订阅", zhHant: "你的訂閱")
        case .subscriptionHelp:
            Self.t("Use ChatGPT, Claude or Gemini you already pay for",
                   "Dùng ChatGPT, Claude hoặc Gemini bạn đang trả phí",
                   ja: "契約中の ChatGPT、Claude、Gemini を使う",
                   zh: "使用你已付费的 ChatGPT、Claude 或 Gemini",
                   zhHant: "使用你已付費的 ChatGPT、Claude 或 Gemini")
        case .notAvailableYet:
            Self.t("Not available yet", "Chưa khả dụng", ja: "まだ利用できません",
                   zh: "暂不可用", zhHant: "暫時無法使用")
        case .google:
            Self.t("Google", "Google", ja: "Google", zh: "Google", zhHant: "Google")
        case .apps:
            Self.t("Apps", "Ứng dụng", ja: "アプリ", zh: "应用", zhHant: "應用程式")
        case .otherDevices:
            Self.t("Other devices", "Thiết bị khác", ja: "ほかのデバイス", zh: "其他设备",
                   zhHant: "其他裝置")
        case .memory:
            Self.t("Memory", "Trí nhớ", ja: "メモリ", zh: "记忆", zhHant: "記憶")
        case .remembers:
            Self.t("Atum remembers", "Atum ghi nhớ", ja: "Atum のメモリ", zh: "Atum 会记忆",
                   zhHant: "Atum 會記憶")
        case .remembersHelp:
            Self.t("Helps your assistants remember context between conversations.",
                   "Giúp các trợ lý nhớ ngữ cảnh giữa những lần trò chuyện.",
                   ja: "会話をまたいでアシスタントが文脈を覚えるのに役立ちます。",
                   zh: "帮助你的助手在不同对话间记住上下文。",
                   zhHant: "幫助你的助理在不同對話間記住脈絡。")
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
        case .chats:
            Self.t("Chats", "Cuộc trò chuyện", ja: "チャット", zh: "聊天", zhHant: "聊天")
        case .chatsStored:
            Self.t("Kept on Atum’s servers", "Được lưu trên máy chủ của Atum",
                   ja: "Atum のサーバーに保存されます", zh: "保存在 Atum 的服务器上",
                   zhHant: "儲存在 Atum 的伺服器上")
        case .chatsStoredHelp:
            Self.t("They aren’t end-to-end encrypted by default. You can turn encryption on for a single chat, in that chat’s info.",
                   "Mặc định không mã hóa đầu cuối. Bạn có thể bật mã hóa cho từng cuộc trò chuyện, trong thông tin của cuộc trò chuyện đó.",
                   ja: "デフォルトではエンドツーエンド暗号化されません。チャットごとに、そのチャットの情報から暗号化をオンにできます。",
                   zh: "默认不做端到端加密。你可以在某个聊天的信息中为它单独开启加密。",
                   zhHant: "預設不做端對端加密。你可以在某個聊天的資訊中為它單獨開啟加密。")
        case .encryptionDetail:
            Self.t("An encrypted chat stays out of Atum’s memory. Turning encryption on doesn’t erase memory already saved.",
                   "Cuộc trò chuyện đã mã hóa không vào trí nhớ của Atum. Bật mã hóa không xóa trí nhớ đã lưu.",
                   ja: "暗号化したチャットは Atum のメモリに入りません。暗号化をオンにしても、保存済みのメモリは削除されません。",
                   zh: "加密的聊天不会进入 Atum 的记忆。开启加密不会删除已保存的记忆。",
                   zhHant: "加密的聊天不會進入 Atum 的記憶。開啟加密不會刪除已儲存的記憶。")
        case .thisIPhone:
            Self.t("This iPhone", "iPhone này", ja: "この iPhone", zh: "这台 iPhone",
                   zhHant: "這台 iPhone")
        case .thisIPad:
            Self.t("This iPad", "iPad này", ja: "この iPad", zh: "这台 iPad", zhHant: "這台 iPad")
        case .nameRequired:
            Self.t("Enter a name.", "Hãy nhập tên.", ja: "名前を入力してください。",
                   zh: "请输入名字。", zhHant: "請輸入名字。")
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
        // Phone-only words for iOS-owned settings (Dynamic Type and the
        // notification permission). ja/zh/zh-Hant are phone fallbacks until
        // the export carries `phoneSettingsCopy.usesIOSSettings`/`opensIOSSettings`.
        case .usesIOSSettings:
            Self.t("Uses iOS settings", "Theo cài đặt iOS", ja: "iOS の設定に従います",
                   zh: "跟随 iOS 设置", zhHant: "依照 iOS 設定")
        case .opensIOSSettings:
            Self.t("Opens iOS Settings", "Mở Cài đặt iOS", ja: "iOS の設定を開きます",
                   zh: "打开 iOS 设置", zhHant: "開啟 iOS 設定")
        }
    }
}
