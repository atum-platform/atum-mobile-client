import Foundation

/// Words for Settings › Approve on this iPhone (phone approvals slice 2b,
/// `phone-approvals-ux.md` revision 2, §2.6, §2.9, §3.3, §3.6, §3.7).
///
/// PENDING-COPY: none of these keys is in the pinned design export yet
/// (listed in docs/ports/phone-approvals-2b.md). Each key is the proposed
/// export key; the app reads the export first, so the next re-pin replaces a
/// value with no wording change. Sources:
/// - en and vi: the UX document's tables, verbatim.
/// - `desktop.cloud.enrollFailure.offline`: desktop's own five-locale string
///   (atum-desktop `apps/desktop/src/i18n/*.ts`), verbatim.
/// - ja, zh and zh-Hant of the NEW keys, and the three keys marked
///   "phone-proposed": written on the phone, pending desktop's translation.
/// `%1$@` is the one argument.
public enum PhoneApprovalPendingCopy {
    public enum Key: String, CaseIterable, Sendable {
        case settingsTitle = "approvalSettingsTitle"
        case settingsHelp = "approvalSettingsHelp"
        /// "On · since {date}".
        case settingsOn = "approvalSettingsOn"
        case settingsRemove = "approvalSettingsRemove"
        case settingsRemoveTitle = "approvalSettingsRemoveTitle"
        case settingsRemoveConfirm = "approvalSettingsRemoveConfirm"
        case settingsPreferFaceID = "approvalSettingsPreferFaceID"
        case settingsSettingUp = "approvalSettingsSettingUp"
        case enrollCancelled = "approvalEnrollCancelled"
        case enrollNoPrompt = "approvalEnrollNoPrompt"
        case enrollOffline = "enrollFailure.offline"
        case enrollRefused = "approvalEnrollRefused"
        case enrollGeneric = "approvalEnrollGeneric"
        case setUpFaceID = "approvalSetUpFaceID"
        /// Phone-proposed: the iPhone SE wording of `approvalSetUpFaceID`.
        case setUpTouchID = "approvalSetUpTouchID"
        /// Phone-proposed: no biometric enrolled, passcode set.
        case setUpPasscode = "approvalSetUpPasscode"
        case noPasscode = "approvalNoPasscode"
        case noPasscodeHelp = "approvalNoPasscodeHelp"
        case keyMissing = "approvalKeyMissing"
        case keyMissingHelp = "approvalKeyMissingHelp"
        case setUpAgain = "approvalSetUpAgain"
        /// Phone-proposed key name for UX §3.7's enrolment `localizedReason`.
        case enrollReason = "approvalEnrollReason"

        public var exportKey: String {
            self == .enrollOffline ? "desktop.cloud." + rawValue
                : "src.matrix.mobile-device-copy.mobileDeviceCopy." + rawValue
        }
    }

    public static let locales = ["en", "vi", "ja", "zh", "zh-Hant"]

    /// The value in `locale` (English for a locale without a table), with
    /// `argument` in place of `%1$@`.
    public static func text(_ key: Key, locale: String, argument: String? = nil) -> String {
        let template = tables[normalized(locale)]?[key] ?? tables["en"]?[key] ?? key.rawValue
        guard let argument else { return template }
        return template.replacingOccurrences(of: "%1$@", with: argument)
    }

    /// en, vi, ja, zh or zh-Hant from any spelling of the app language.
    public static func normalized(_ locale: String) -> String {
        let code = locale.lowercased().replacingOccurrences(of: "_", with: "-")
        if code.hasPrefix("zh-hant") || code.hasPrefix("zh-tw") || code.hasPrefix("zh-hk") { return "zh-Hant" }
        return String(code.prefix(2))
    }

    /// `NSFaceIDUsageDescription` (UX §3.7), projected into
    /// `ios/App/InfoPlist.xcstrings` by `scripts/generate-info-plist-localization.py`.
    public static let faceIDUsage: [String: String] = [
        "en": "Atum uses Face ID so only you can approve what your assistants ask to do.",
        "vi": "Atum dùng Face ID để chỉ bạn mới có thể cho phép những việc trợ lý xin làm.",
        "ja": "アシスタントが求める操作をあなただけが許可できるよう、Atum は Face ID を使用します。",
        "zh": "Atum 使用面容 ID，确保只有你能批准助手请求执行的操作。",
        "zh-Hant": "Atum 使用 Face ID，確保只有你能核准助理請求執行的操作。",
    ]

    static let tables: [String: [Key: String]] = [
        "en": [
            .settingsTitle: "Approve on this iPhone",
            .settingsHelp: "Answer your assistants’ requests with Face ID when you’re away from your Mac.",
            .settingsOn: "On · since %1$@",
            .settingsRemove: "Remove from this iPhone",
            .settingsRemoveTitle: "Remove approvals from this iPhone?",
            .settingsRemoveConfirm: "This iPhone will no longer be able to approve. You can still answer on your other devices.",
            .settingsPreferFaceID: "You can approve with your passcode, or set up Face ID in Settings.",
            .settingsSettingUp: "Setting up…",
            .enrollCancelled: "Face ID was cancelled, so this iPhone wasn’t set up. Try again when you’re ready.",
            .enrollNoPrompt: "This iPhone couldn’t ask for Face ID or your passcode. Unlock it and try again.",
            .enrollOffline: "Could not reach Atum’s cloud. Check your internet connection and try again.",
            .enrollRefused: "Atum’s cloud did not accept this iPhone. Try again; if it keeps happening, contact support.",
            .enrollGeneric: "This iPhone wasn’t set up. Try again.",
            .setUpFaceID: "Set up with Face ID",
            .setUpTouchID: "Set up with Touch ID",
            .setUpPasscode: "Set up with passcode",
            .noPasscode: "Set a passcode on this iPhone to approve here.",
            .noPasscodeHelp: "In Settings, open Face ID & Passcode and turn on a passcode.",
            .keyMissing: "Approvals need setting up again on this iPhone.",
            .keyMissingHelp: "This can happen after restoring this iPhone or turning its passcode off.",
            .setUpAgain: "Set up again",
            .enrollReason: "Set up approvals on this iPhone",
        ],
        "vi": [
            .settingsTitle: "Cho phép trên iPhone này",
            .settingsHelp: "Dùng Face ID để trả lời yêu cầu của trợ lý khi bạn không ở bên máy Mac.",
            .settingsOn: "Đang bật · từ %1$@",
            .settingsRemove: "Gỡ khỏi iPhone này",
            .settingsRemoveTitle: "Gỡ việc cho phép khỏi iPhone này?",
            .settingsRemoveConfirm: "iPhone này sẽ không thể cho phép nữa. Bạn vẫn trả lời được trên các thiết bị khác.",
            .settingsPreferFaceID: "Bạn có thể cho phép bằng mật mã, hoặc thiết lập Face ID trong Cài đặt.",
            .settingsSettingUp: "Đang thiết lập…",
            .enrollCancelled: "Face ID đã bị huỷ nên iPhone này chưa được thiết lập. Hãy thử lại khi bạn sẵn sàng.",
            .enrollNoPrompt: "iPhone này chưa hỏi được Face ID hoặc mật mã. Hãy mở khóa rồi thử lại.",
            .enrollOffline: "Chưa kết nối được tới đám mây của Atum. Hãy kiểm tra kết nối internet rồi thử lại.",
            .enrollRefused: "Đám mây của Atum chưa chấp nhận iPhone này. Hãy thử lại; nếu vẫn lỗi, hãy liên hệ hỗ trợ.",
            .enrollGeneric: "iPhone này chưa được thiết lập. Hãy thử lại.",
            .setUpFaceID: "Thiết lập bằng Face ID",
            .setUpTouchID: "Thiết lập bằng Touch ID",
            .setUpPasscode: "Thiết lập bằng mật mã",
            .noPasscode: "Hãy đặt mật mã cho iPhone này để cho phép tại đây.",
            .noPasscodeHelp: "Trong Cài đặt, mở Face ID & Mật mã và bật mật mã.",
            .keyMissing: "Cần thiết lập lại việc cho phép trên iPhone này.",
            .keyMissingHelp: "Điều này có thể xảy ra sau khi khôi phục iPhone hoặc tắt mật mã.",
            .setUpAgain: "Thiết lập lại",
            .enrollReason: "Thiết lập việc cho phép trên iPhone này",
        ],
        "ja": [
            .settingsTitle: "このiPhoneで許可",
            .settingsHelp: "Mac から離れているときも、Face ID でアシスタントのリクエストに応答できます。",
            .settingsOn: "オン · %1$@から",
            .settingsRemove: "このiPhoneから削除",
            .settingsRemoveTitle: "このiPhoneでの許可を削除しますか？",
            .settingsRemoveConfirm: "このiPhoneでは許可できなくなります。ほかのデバイスでは引き続き応答できます。",
            .settingsPreferFaceID: "パスコードで許可できます。設定で Face ID を設定することもできます。",
            .settingsSettingUp: "設定しています…",
            .enrollCancelled: "Face ID がキャンセルされたため、このiPhoneは設定されませんでした。準備ができたらもう一度お試しください。",
            .enrollNoPrompt: "このiPhoneで Face ID またはパスコードを求めることができませんでした。ロックを解除してもう一度お試しください。",
            .enrollOffline: "Atum のクラウドに接続できませんでした。インターネット接続を確認して、もう一度お試しください。",
            .enrollRefused: "Atum のクラウドがこのiPhoneを受け付けませんでした。もう一度お試しください。続く場合はサポートにお問い合わせください。",
            .enrollGeneric: "このiPhoneは設定されませんでした。もう一度お試しください。",
            .setUpFaceID: "Face ID で設定",
            .setUpTouchID: "Touch ID で設定",
            .setUpPasscode: "パスコードで設定",
            .noPasscode: "ここで許可するには、このiPhoneにパスコードを設定してください。",
            .noPasscodeHelp: "設定で「Face IDとパスコード」を開き、パスコードをオンにしてください。",
            .keyMissing: "このiPhoneでの許可をもう一度設定する必要があります。",
            .keyMissingHelp: "このiPhoneを復元したり、パスコードをオフにしたりすると、こうなることがあります。",
            .setUpAgain: "もう一度設定",
            .enrollReason: "このiPhoneで許可を設定",
        ],
        "zh": [
            .settingsTitle: "在这台 iPhone 上批准",
            .settingsHelp: "不在 Mac 旁边时，也能用面容 ID 回应助手的请求。",
            .settingsOn: "已开启 · 自 %1$@ 起",
            .settingsRemove: "从这台 iPhone 移除",
            .settingsRemoveTitle: "要从这台 iPhone 移除批准功能吗？",
            .settingsRemoveConfirm: "这台 iPhone 将无法再批准。你仍可在其他设备上回应。",
            .settingsPreferFaceID: "你可以用密码批准，也可以在“设置”中设置面容 ID。",
            .settingsSettingUp: "正在设置…",
            .enrollCancelled: "面容 ID 已取消，因此这台 iPhone 未完成设置。准备好后请重试。",
            .enrollNoPrompt: "这台 iPhone 无法请求面容 ID 或密码。请解锁后重试。",
            .enrollOffline: "无法连接到 Atum 云端。请检查网络连接后重试。",
            .enrollRefused: "Atum 云端未接受这台 iPhone。请重试；如果一直出现，请联系支持。",
            .enrollGeneric: "这台 iPhone 未完成设置。请重试。",
            .setUpFaceID: "使用面容 ID 设置",
            .setUpTouchID: "使用触控 ID 设置",
            .setUpPasscode: "使用密码设置",
            .noPasscode: "请为这台 iPhone 设置密码，才能在这里批准。",
            .noPasscodeHelp: "在“设置”中打开“面容 ID 与密码”，然后打开密码。",
            .keyMissing: "需要在这台 iPhone 上重新设置批准功能。",
            .keyMissingHelp: "恢复这台 iPhone 或关闭其密码后可能会出现这种情况。",
            .setUpAgain: "重新设置",
            .enrollReason: "在这台 iPhone 上设置批准功能",
        ],
        "zh-Hant": [
            .settingsTitle: "在這支 iPhone 上核准",
            .settingsHelp: "不在 Mac 旁邊時，也能用 Face ID 回應助理的請求。",
            .settingsOn: "已開啟 · 自 %1$@ 起",
            .settingsRemove: "從這支 iPhone 移除",
            .settingsRemoveTitle: "要從這支 iPhone 移除核准功能嗎？",
            .settingsRemoveConfirm: "這支 iPhone 將無法再核准。你仍可在其他裝置上回應。",
            .settingsPreferFaceID: "你可以用密碼核准，也可以在「設定」中設定 Face ID。",
            .settingsSettingUp: "正在設定…",
            .enrollCancelled: "Face ID 已取消，因此這支 iPhone 未完成設定。準備好後請再試一次。",
            .enrollNoPrompt: "這支 iPhone 無法要求 Face ID 或密碼。請解鎖後再試一次。",
            .enrollOffline: "無法連線到 Atum 雲端。請檢查網路連線後再試一次。",
            .enrollRefused: "Atum 雲端未接受這支 iPhone。請再試一次；如果持續發生，請聯絡支援。",
            .enrollGeneric: "這支 iPhone 未完成設定。請再試一次。",
            .setUpFaceID: "使用 Face ID 設定",
            .setUpTouchID: "使用 Touch ID 設定",
            .setUpPasscode: "使用密碼設定",
            .noPasscode: "請為這支 iPhone 設定密碼，才能在這裡核准。",
            .noPasscodeHelp: "在「設定」中打開「Face ID 與密碼」，然後開啟密碼。",
            .keyMissing: "需要在這支 iPhone 上重新設定核准功能。",
            .keyMissingHelp: "回復這支 iPhone 或關閉其密碼後可能會發生這種情況。",
            .setUpAgain: "重新設定",
            .enrollReason: "在這支 iPhone 上設定核准功能",
        ],
    ]
}
