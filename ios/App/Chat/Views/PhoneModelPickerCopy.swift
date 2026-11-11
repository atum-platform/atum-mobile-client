import AtumDesign
import AtumNativeAPI
import Foundation

/// The model picker's keys in the pinned atum-app catalog.
enum PhonePickerCopyKey: String, CaseIterable {
    case accountFilter = "src.matrix.model-picker-copy.COPY.accountFilter"
    case atumProvider = "src.matrix.model-picker-copy.COPY.atumProvider"
    case backToAtum = "src.matrix.model-picker-copy.COPY.backToAtum"
    case changesCloudAssistant = "src.matrix.model-picker-copy.COPY.changesCloudAssistant"
    case changesConversation = "src.matrix.model-picker-copy.COPY.changesConversation"
    case clearSearch = "src.matrix.model-picker-copy.COPY.clearSearch"
    case cloud = "src.matrix.model-picker-copy.COPY.cloud"
    case current = "src.matrix.model-picker-copy.COPY.current"
    case effort = "src.matrix.model-picker-copy.COPY.effort"
    case effortProtons = "src.matrix.model-picker-copy.COPY.effortProtons"
    case favorite = "src.matrix.model-picker-copy.COPY.favorite"
    case favoritesEmpty = "src.matrix.model-picker-copy.COPY.favoritesEmpty"
    case keyAccount = "src.matrix.model-picker-copy.COPY.keyAccount"
    case modelList = "src.matrix.model-picker-copy.COPY.modelList"
    case modelsFailed = "src.matrix.model-picker-copy.COPY.modelsFailed"
    case modelsRetry = "src.matrix.model-picker-copy.COPY.modelsRetry"
    case modelsSignedOut = "src.matrix.model-picker-copy.COPY.modelsSignedOut"
    case modelsUnavailable = "src.matrix.model-picker-copy.COPY.modelsUnavailable"
    case noMatches = "src.matrix.model-picker-copy.COPY.noMatches"
    case noModels = "src.matrix.model-picker-copy.COPY.noModels"
    case planAccount = "src.matrix.model-picker-copy.COPY.planAccount"
    case searchPlaceholder = "src.matrix.model-picker-copy.COPY.searchPlaceholder"
    case switchProblemUnavailable = "src.matrix.model-picker-copy.COPY.switchProblem.unavailable"
    case thisMac = "src.matrix.model-picker-copy.COPY.thisMac"
    case unfavorite = "src.matrix.model-picker-copy.COPY.unfavorite"
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
    // `desktop-model-picker-t3-layout` adds these to its table; they are not in
    // this pin yet, so `PhoneModelPickerPendingCopy` answers with the desktop's
    // own values until the next `export:mobile` pin carries them.
    case allConnections = "src.matrix.model-picker-copy.COPY.allConnections"
    case badgeDefault = "src.matrix.model-picker-copy.COPY.badgeDefault"
    case defaultsAndFavorites = "src.matrix.model-picker-copy.COPY.defaultsAndFavorites"
    case favoritesOnly = "src.matrix.model-picker-copy.COPY.favoritesOnly"
    case filter = "src.matrix.model-picker-copy.COPY.filter"
    case filterWith = "src.matrix.model-picker-copy.COPY.filterWith"

    // Atum's line-up and the connected subscriptions (desktop
    // `matrixShell.modelDefault|modelHard|modelFlagship` and
    // `model-picker-copy.subscriptions`). Not in this pin yet; the pending
    // table carries the desktop's own words until the next export.
    case taglineEveryday = "src.matrix.model-picker-copy.COPY.taglineEveryday"
    case taglineHard = "src.matrix.model-picker-copy.COPY.taglineHard"
    case taglineFlagship = "src.matrix.model-picker-copy.COPY.taglineFlagship"
    case subscriptions = "src.matrix.model-picker-copy.COPY.subscriptions"
}

enum PhoneModelPickerStateCopyKey: String, CaseIterable {
    case title = "src.matrix.mobile-device-copy.mobileDeviceCopy.modelPickerTitle"
    case saveFailed = "src.matrix.mobile-device-copy.mobileDeviceCopy.modelPickerStatesSaveFailedText"
}

/// Every picker word the phone shows. A key the pin carries resolves from the
/// pin; a key it does not carry yet resolves from `PhoneModelPickerPendingCopy`.
/// `LiveDesign.text` stops the app on an unknown key, so the pin is asked first.
@MainActor
struct PhoneModelPickerCopy {
    let design: LiveDesign

    func text(_ key: PhonePickerCopyKey, _ arguments: [AtumCopy.Argument] = []) -> String {
        if design.copy.contains(key.rawValue) {
            return design.text(key.rawValue, arguments: arguments)
        }
        return PhoneModelPickerPendingCopy.text(key, arguments: arguments, locale: design.locale)
    }

    func state(_ key: PhoneModelPickerStateCopyKey) -> String { design.text(key.rawValue) }

    /// Desktop's words for a subscription model the cloud cannot run now.
    /// `chatgptCloudNotReady` ("Not ready for your assistants yet") is not in
    /// the pin, nor in the desktop export at atum-desktop 583ae946; until an
    /// export carries it the row says the pinned `switchProblem.unavailable`
    /// ("Couldn't choose this model for this assistant right now."), never a
    /// string written here. See `docs/ports/phone-subscription-models.md`.
    func unavailable(_ reason: PhoneModelPickerProjection.Row.Unavailable) -> String {
        switch reason {
        case .notReady:
            design.copy.contains(Self.chatgptCloudNotReady)
                ? design.text(Self.chatgptCloudNotReady) : text(.switchProblemUnavailable)
        case .signedOut:
            text(.modelsSignedOut)
        }
    }

    static let chatgptCloudNotReady = "src.matrix.model-picker-copy.COPY.chatgptCloudNotReady"

    /// Atum's own one-line description under a line-up model's name.
    func tagline(_ tagline: ManagedModelLineup.Tagline) -> String {
        switch tagline {
        case .everyday: text(.taglineEveryday)
        case .hard: text(.taglineHard)
        case .flagship: text(.taglineFlagship)
        }
    }

    /// "Quick", "Balanced", "Thorough": the level's name.
    func effortName(_ level: ManagedModelEffort) -> String {
        design.text("src.matrix.model-picker-copy.COPY.efforts." + level.rawValue)
    }

    /// One line on what the level does.
    func effortHelp(_ level: ManagedModelEffort) -> String {
        design.text("src.matrix.model-picker-copy.COPY.effortHelp." + level.rawValue)
    }
}

/// The keys this pin does not carry yet, with the exact values of the desktop
/// tables (`apps/desktop/src/matrix/model-picker-copy.ts` and the line-up
/// taglines beside it at release/0.20.21), so the pin replaces them with no
/// wording change. `filterWith` keeps the export's `%1$@` placeholder. Listed
/// in the session log; nothing here is hand-edited into `ios/Vendor/AtumDesign`.
enum PhoneModelPickerPendingCopy {
    static let keys: [PhonePickerCopyKey] = [
        .allConnections, .badgeDefault, .defaultsAndFavorites, .favoritesOnly, .filter, .filterWith,
        .taglineEveryday, .taglineHard, .taglineFlagship, .subscriptions,
    ]

    private static let tables: [String: [PhonePickerCopyKey: String]] = [
        "en": [
            .allConnections: "All connections",
            .badgeDefault: "Default",
            .defaultsAndFavorites: "Defaults & favorites",
            .favoritesOnly: "Favorites only",
            .filter: "Filter",
            .filterWith: "Filter: %1$@",
            .taglineEveryday: "Good for everyday tasks",
            .taglineHard: "Good for hard tasks",
            .taglineFlagship: "The most powerful model",
            .subscriptions: "Subscriptions",
        ],
        "vi": [
            .allConnections: "Mọi kết nối",
            .badgeDefault: "Mặc định",
            .defaultsAndFavorites: "Mặc định & yêu thích",
            .favoritesOnly: "Chỉ yêu thích",
            .filter: "Lọc",
            .filterWith: "Lọc: %1$@",
            .taglineEveryday: "Phù hợp tác vụ hàng ngày",
            .taglineHard: "Phù hợp với tác vụ khó khăn",
            .taglineFlagship: "Mô hình quyền năng nhất",
            .subscriptions: "Gói đăng ký",
        ],
        "ja": [
            .allConnections: "すべての接続",
            .badgeDefault: "デフォルト",
            .defaultsAndFavorites: "デフォルトとお気に入り",
            .favoritesOnly: "お気に入りのみ",
            .filter: "フィルター",
            .filterWith: "フィルター: %1$@",
            .taglineEveryday: "日常のタスクに適しています",
            .taglineHard: "難しいタスクに適しています",
            .taglineFlagship: "最も強力なモデル",
            .subscriptions: "サブスクリプション",
        ],
        "zh": [
            .allConnections: "所有连接",
            .badgeDefault: "默认",
            .defaultsAndFavorites: "默认与收藏",
            .favoritesOnly: "仅看收藏",
            .filter: "筛选",
            .filterWith: "筛选：%1$@",
            .taglineEveryday: "适合日常任务",
            .taglineHard: "适合困难任务",
            .taglineFlagship: "最强大的模型",
            .subscriptions: "订阅",
        ],
        "zh-Hant": [
            .allConnections: "所有連接",
            .badgeDefault: "預設",
            .defaultsAndFavorites: "預設與收藏",
            .favoritesOnly: "僅看收藏",
            .filter: "篩選",
            .filterWith: "篩選：%1$@",
            .taglineEveryday: "適合日常任務",
            .taglineHard: "適合困難任務",
            .taglineFlagship: "最強大的模型",
            .subscriptions: "訂閱",
        ],
    ]

    static var locales: [String] { tables.keys.sorted() }

    /// The pending value for `key` in `locale` (English for a locale without a
    /// table), with the first text argument in place of `%1$@`.
    static func text(_ key: PhonePickerCopyKey, arguments: [AtumCopy.Argument] = [],
                     locale: String) -> String {
        let template = tables[locale]?[key] ?? tables["en"]?[key] ?? key.rawValue
        guard case let .text(value)? = arguments.first else { return template }
        return template.replacingOccurrences(of: "%1$@", with: value)
    }
}
