// The phone trust screens' own words (chat parity S7–S9, mockup M4).
// PENDING-COPY: the pinned design export does not carry these keys yet. Each key
// is the proposed export key; the app reads the export first and falls back to
// this table, so the next repin replaces a value with no wording change.
// Locales the table lacks fall back to English. Templates use {0}.
// Exported keys the screens reuse (security-copy, approval-copy) are not here.

public enum PhoneTrustCopyKey: String, CaseIterable, Sendable {
    // S7 · emoji verification
    case confirmTitle = "shared.matrix-phone-trust-copy.copy.confirmTitle"
    case confirmStartBody = "shared.matrix-phone-trust-copy.copy.confirmStartBody"
    case confirmWaitingBody = "shared.matrix-phone-trust-copy.copy.confirmWaitingBody"
    case useKeyInstead = "shared.matrix-phone-trust-copy.copy.useKeyInstead"
    case incomingTitle = "shared.matrix-phone-trust-copy.copy.incomingTitle"
    case incomingBody = "shared.matrix-phone-trust-copy.copy.incomingBody"
    case incomingBodyUnnamed = "shared.matrix-phone-trust-copy.copy.incomingBodyUnnamed"
    case compareTitle = "shared.matrix-phone-trust-copy.copy.compareTitle"
    case compareBody = "shared.matrix-phone-trust-copy.copy.compareBody"
    case confirmedToast = "shared.matrix-phone-trust-copy.copy.confirmedToast"
    case notConfirmedTitle = "shared.matrix-phone-trust-copy.copy.notConfirmedTitle"
    case mismatchBody = "shared.matrix-phone-trust-copy.copy.mismatchBody"
    case peerCancelledBody = "shared.matrix-phone-trust-copy.copy.peerCancelledBody"
    case timedOutBody = "shared.matrix-phone-trust-copy.copy.timedOutBody"
    case unavailableBody = "shared.matrix-phone-trust-copy.copy.unavailableBody"
    // S8 · recovery key
    case keyTitle = "shared.matrix-phone-trust-copy.copy.keyTitle"
    case keyBody = "shared.matrix-phone-trust-copy.copy.keyBody"
    case saveToPasswords = "shared.matrix-phone-trust-copy.copy.saveToPasswords"
    case keySavedToast = "shared.matrix-phone-trust-copy.copy.keySavedToast"
    case verifyFirstBody = "shared.matrix-phone-trust-copy.copy.verifyFirstBody"
    case existingBody = "shared.matrix-phone-trust-copy.copy.existingBody"
    case setUpElsewhereBody = "shared.matrix-phone-trust-copy.copy.setUpElsewhereBody"
    case retryBusy = "shared.matrix-phone-trust-copy.copy.retryBusy"
    case retryNotReady = "shared.matrix-phone-trust-copy.copy.retryNotReady"
    case retryStorage = "shared.matrix-phone-trust-copy.copy.retryStorage"
    case readyBody = "shared.matrix-phone-trust-copy.copy.readyBody"
    // Security entry
    case securityTitle = "shared.matrix-phone-trust-copy.copy.securityTitle"
    case securityLead = "shared.matrix-phone-trust-copy.copy.securityLead"
    case thisIPhone = "shared.matrix-phone-trust-copy.copy.thisIPhone"
    case keyNotSaved = "shared.matrix-phone-trust-copy.copy.keyNotSaved"
    // S9 · Private at creation
    case privateLabel = "shared.matrix-phone-trust-copy.copy.private"
    case privateHelp = "shared.matrix-phone-trust-copy.copy.privateHelp"
    case privateOneWay = "shared.matrix-phone-trust-copy.copy.privateOneWay"
    case privatePeopleOnly = "shared.matrix-phone-trust-copy.copy.privatePeopleOnly"
    case privateNotReady = "shared.matrix-phone-trust-copy.copy.privateNotReady"
}

public enum PhoneTrustPendingCopy {
    public static let locales = ["en", "vi", "ja", "zh", "zh-Hant"]

    public static func text(_ key: PhoneTrustCopyKey, locale: String) -> String {
        let table = tables[key.rawValue]
        return table?[locale] ?? table?["en"] ?? key.rawValue
    }

    public static let tables: [String: [String: String]] = [
        "shared.matrix-phone-trust-copy.copy.confirmTitle": [
            "en": "Confirm this iPhone",
            "vi": "Xác nhận iPhone này",
            "ja": "このiPhoneを確認",
            "zh": "确认这台 iPhone",
            "zh-Hant": "確認這支 iPhone",
        ],
        "shared.matrix-phone-trust-copy.copy.confirmStartBody": [
            "en": "Compare emoji with Atum on another device you’re signed in to.",
            "vi": "So sánh biểu tượng cảm xúc với Atum trên một thiết bị khác bạn đã đăng nhập.",
            "ja": "サインイン中の別のデバイスのAtumと絵文字を見比べます。",
            "zh": "与你已登录的另一台设备上的 Atum 比对表情符号。",
            "zh-Hant": "與你已登入的另一部裝置上的 Atum 比對表情符號。",
        ],
        "shared.matrix-phone-trust-copy.copy.confirmWaitingBody": [
            "en": "Open Atum on your other device. It will ask you to compare emoji.",
            "vi": "Mở Atum trên thiết bị kia của bạn. Atum sẽ nhờ bạn so sánh biểu tượng cảm xúc.",
            "ja": "別のデバイスでAtumを開いてください。絵文字の確認を求められます。",
            "zh": "在你的另一台设备上打开 Atum，它会请你比对表情符号。",
            "zh-Hant": "在你的另一部裝置上開啟 Atum，它會請你比對表情符號。",
        ],
        "shared.matrix-phone-trust-copy.copy.useKeyInstead": [
            "en": "Use recovery key instead",
            "vi": "Dùng khóa khôi phục",
            "ja": "代わりに復元キーを使う",
            "zh": "改用恢复密钥",
            "zh-Hant": "改用復原金鑰",
        ],
        "shared.matrix-phone-trust-copy.copy.incomingTitle": [
            "en": "Confirm this iPhone?",
            "vi": "Xác nhận iPhone này?",
            "ja": "このiPhoneを確認しますか？",
            "zh": "确认这台 iPhone？",
            "zh-Hant": "確認這支 iPhone？",
        ],
        "shared.matrix-phone-trust-copy.copy.incomingBody": [
            "en": "{0} asked to compare emoji with this iPhone.",
            "vi": "{0} muốn so sánh biểu tượng cảm xúc với iPhone này.",
            "ja": "{0}がこのiPhoneとの絵文字の確認を求めています。",
            "zh": "{0} 请求与这台 iPhone 比对表情符号。",
            "zh-Hant": "{0} 請求與這支 iPhone 比對表情符號。",
        ],
        "shared.matrix-phone-trust-copy.copy.incomingBodyUnnamed": [
            "en": "Your other device asked to compare emoji with this iPhone.",
            "vi": "Thiết bị kia của bạn muốn so sánh biểu tượng cảm xúc với iPhone này.",
            "ja": "別のデバイスがこのiPhoneとの絵文字の確認を求めています。",
            "zh": "你的另一台设备请求与这台 iPhone 比对表情符号。",
            "zh-Hant": "你的另一部裝置請求與這支 iPhone 比對表情符號。",
        ],
        "shared.matrix-phone-trust-copy.copy.compareTitle": [
            "en": "Do these match your other device?",
            "vi": "Các biểu tượng này có khớp với thiết bị kia không?",
            "ja": "別のデバイスの表示と一致しますか？",
            "zh": "这些与你另一台设备上的一致吗？",
            "zh-Hant": "這些與你另一部裝置上的一致嗎？",
        ],
        "shared.matrix-phone-trust-copy.copy.compareBody": [
            "en": "Same emoji, same order.",
            "vi": "Cùng biểu tượng, cùng thứ tự.",
            "ja": "同じ絵文字が同じ順番で並んでいるか確認してください。",
            "zh": "表情相同，顺序相同。",
            "zh-Hant": "表情相同，順序相同。",
        ],
        "shared.matrix-phone-trust-copy.copy.confirmedToast": [
            "en": "iPhone confirmed",
            "vi": "Đã xác nhận iPhone",
            "ja": "iPhoneを確認しました",
            "zh": "iPhone 已确认",
            "zh-Hant": "iPhone 已確認",
        ],
        "shared.matrix-phone-trust-copy.copy.notConfirmedTitle": [
            "en": "Not confirmed",
            "vi": "Chưa xác nhận",
            "ja": "確認できませんでした",
            "zh": "未确认",
            "zh-Hant": "未確認",
        ],
        "shared.matrix-phone-trust-copy.copy.mismatchBody": [
            "en": "The emoji didn’t match, so nothing was shared.",
            "vi": "Biểu tượng không khớp nên không có gì được chia sẻ.",
            "ja": "絵文字が一致しなかったため、何も共有されていません。",
            "zh": "表情不一致，因此没有共享任何内容。",
            "zh-Hant": "表情不一致，因此沒有分享任何內容。",
        ],
        "shared.matrix-phone-trust-copy.copy.peerCancelledBody": [
            "en": "Your other device stopped the check, so nothing was shared.",
            "vi": "Thiết bị kia đã dừng kiểm tra nên không có gì được chia sẻ.",
            "ja": "別のデバイスで確認が中止されたため、何も共有されていません。",
            "zh": "你的另一台设备停止了确认，因此没有共享任何内容。",
            "zh-Hant": "你的另一部裝置停止了確認，因此沒有分享任何內容。",
        ],
        "shared.matrix-phone-trust-copy.copy.timedOutBody": [
            "en": "That took too long, so nothing was shared.",
            "vi": "Quá thời gian chờ nên không có gì được chia sẻ.",
            "ja": "時間がかかりすぎたため、何も共有されていません。",
            "zh": "等待时间过长，因此没有共享任何内容。",
            "zh-Hant": "等待時間過長，因此沒有分享任何內容。",
        ],
        "shared.matrix-phone-trust-copy.copy.unavailableBody": [
            "en": "Couldn’t reach your other device. Check that Atum is open there, then try again.",
            "vi": "Không kết nối được với thiết bị kia. Hãy mở Atum trên đó rồi thử lại.",
            "ja": "別のデバイスに接続できませんでした。そちらでAtumを開いてから、もう一度お試しください。",
            "zh": "无法连接你的另一台设备。请确认那里已打开 Atum，然后重试。",
            "zh-Hant": "無法連線你的另一部裝置。請確認那裡已開啟 Atum，然後再試一次。",
        ],
        "shared.matrix-phone-trust-copy.copy.keyTitle": [
            "en": "Save your recovery key",
            "vi": "Lưu khóa khôi phục",
            "ja": "復元キーを保存",
            "zh": "保存你的恢复密钥",
            "zh-Hant": "儲存你的復原金鑰",
        ],
        "shared.matrix-phone-trust-copy.copy.keyBody": [
            "en": "You’ll need it to read private chats on a new phone.",
            "vi": "Bạn sẽ cần khóa này để đọc các cuộc trò chuyện riêng tư trên điện thoại mới.",
            "ja": "新しいスマートフォンでプライベートチャットを読むときに必要です。",
            "zh": "在新手机上阅读私密聊天时需要它。",
            "zh-Hant": "在新手機上閱讀私密聊天時需要它。",
        ],
        "shared.matrix-phone-trust-copy.copy.saveToPasswords": [
            "en": "Save to Passwords",
            "vi": "Lưu vào Mật khẩu",
            "ja": "パスワードに保存",
            "zh": "存储到“密码”",
            "zh-Hant": "儲存到「密碼」",
        ],
        "shared.matrix-phone-trust-copy.copy.keySavedToast": [
            "en": "Recovery key saved",
            "vi": "Đã lưu khóa khôi phục",
            "ja": "復元キーを保存しました",
            "zh": "恢复密钥已保存",
            "zh-Hant": "復原金鑰已儲存",
        ],
        "shared.matrix-phone-trust-copy.copy.verifyFirstBody": [
            "en": "Confirm this iPhone first: compare emoji with your other device, or use your recovery key.",
            "vi": "Hãy xác nhận iPhone này trước: so sánh biểu tượng cảm xúc với thiết bị kia, hoặc dùng khóa khôi phục.",
            "ja": "まずこのiPhoneを確認してください。別のデバイスと絵文字を見比べるか、復元キーを使います。",
            "zh": "请先确认这台 iPhone：与你的另一台设备比对表情符号，或使用恢复密钥。",
            "zh-Hant": "請先確認這支 iPhone：與你的另一部裝置比對表情符號，或使用復原金鑰。",
        ],
        "shared.matrix-phone-trust-copy.copy.existingBody": [
            "en": "You already have a recovery key. Use it to unlock private chats on this iPhone.",
            "vi": "Bạn đã có khóa khôi phục. Hãy dùng khóa đó để mở trò chuyện riêng tư trên iPhone này.",
            "ja": "復元キーはすでにあります。そのキーでこのiPhoneのプライベートチャットを開いてください。",
            "zh": "你已有恢复密钥。用它在这台 iPhone 上解锁私密聊天。",
            "zh-Hant": "你已有復原金鑰。用它在這支 iPhone 上解鎖私密聊天。",
        ],
        "shared.matrix-phone-trust-copy.copy.setUpElsewhereBody": [
            "en": "Set up security from another device you’re signed in to, or do it later. Your chats keep working.",
            "vi": "Hãy thiết lập bảo mật từ một thiết bị khác bạn đã đăng nhập, hoặc làm sau. Các cuộc trò chuyện vẫn hoạt động bình thường.",
            "ja": "サインイン中の別のデバイスでセキュリティを設定するか、後で設定してください。チャットはそのまま使えます。",
            "zh": "请在你已登录的另一台设备上设置安全功能，或稍后再设置。你的聊天照常可用。",
            "zh-Hant": "請在你已登入的另一部裝置上設定安全功能，或稍後再設定。你的聊天照常可用。",
        ],
        "shared.matrix-phone-trust-copy.copy.retryBusy": [
            "en": "Another step is still finishing. Try again in a moment.",
            "vi": "Một bước khác vẫn đang chạy. Hãy thử lại sau giây lát.",
            "ja": "別の処理がまだ完了していません。少し待ってからもう一度お試しください。",
            "zh": "另一个步骤仍在进行中，请稍后重试。",
            "zh-Hant": "另一個步驟仍在進行中，請稍後再試。",
        ],
        "shared.matrix-phone-trust-copy.copy.retryNotReady": [
            "en": "That didn’t finish. Try again in a moment.",
            "vi": "Chưa hoàn tất. Hãy thử lại sau giây lát.",
            "ja": "完了しませんでした。少し待ってからもう一度お試しください。",
            "zh": "未能完成，请稍后重试。",
            "zh-Hant": "未能完成，請稍後再試。",
        ],
        "shared.matrix-phone-trust-copy.copy.retryStorage": [
            "en": "This iPhone couldn’t keep the key safely. Try again.",
            "vi": "iPhone này không lưu khóa an toàn được. Hãy thử lại.",
            "ja": "このiPhoneにキーを安全に保管できませんでした。もう一度お試しください。",
            "zh": "这台 iPhone 无法安全保存密钥，请重试。",
            "zh-Hant": "這支 iPhone 無法安全保存金鑰，請再試一次。",
        ],
        "shared.matrix-phone-trust-copy.copy.readyBody": [
            "en": "Private chats are ready. Turn on Private when you start a chat with people.",
            "vi": "Đã sẵn sàng trò chuyện riêng tư. Bật Riêng tư khi bạn bắt đầu trò chuyện với mọi người.",
            "ja": "プライベートチャットの準備ができました。人とのチャットを始めるときに「プライベート」をオンにしてください。",
            "zh": "私密聊天已就绪。与他人开始聊天时打开“私密”即可。",
            "zh-Hant": "私密聊天已就緒。與他人開始聊天時開啟「私密」即可。",
        ],
        "shared.matrix-phone-trust-copy.copy.securityTitle": [
            "en": "Private chats",
            "vi": "Trò chuyện riêng tư",
            "ja": "プライベートチャット",
            "zh": "私密聊天",
            "zh-Hant": "私密聊天",
        ],
        "shared.matrix-phone-trust-copy.copy.securityLead": [
            "en": "Private chats are encrypted end to end. Set them up once on this iPhone.",
            "vi": "Trò chuyện riêng tư được mã hóa đầu cuối. Chỉ cần thiết lập một lần trên iPhone này.",
            "ja": "プライベートチャットはエンドツーエンドで暗号化されます。このiPhoneで一度だけ設定します。",
            "zh": "私密聊天采用端到端加密。在这台 iPhone 上设置一次即可。",
            "zh-Hant": "私密聊天採用端對端加密。在這支 iPhone 上設定一次即可。",
        ],
        "shared.matrix-phone-trust-copy.copy.thisIPhone": [
            "en": "This iPhone",
            "vi": "iPhone này",
            "ja": "このiPhone",
            "zh": "这台 iPhone",
            "zh-Hant": "這支 iPhone",
        ],
        "shared.matrix-phone-trust-copy.copy.keyNotSaved": [
            "en": "Not saved yet",
            "vi": "Chưa lưu",
            "ja": "未保存",
            "zh": "尚未保存",
            "zh-Hant": "尚未儲存",
        ],
        "shared.matrix-phone-trust-copy.copy.private": [
            "en": "Private",
            "vi": "Riêng tư",
            "ja": "プライベート",
            "zh": "私密",
            "zh-Hant": "私密",
        ],
        "shared.matrix-phone-trust-copy.copy.privateHelp": [
            "en": "Encrypted end to end. Assistants can’t join.",
            "vi": "Mã hóa đầu cuối. Trợ lý không thể tham gia.",
            "ja": "エンドツーエンドで暗号化されます。アシスタントは参加できません。",
            "zh": "端到端加密。助理无法加入。",
            "zh-Hant": "端對端加密。助理無法加入。",
        ],
        "shared.matrix-phone-trust-copy.copy.privateOneWay": [
            "en": "Can’t be turned off later.",
            "vi": "Không thể tắt sau này.",
            "ja": "後からオフにはできません。",
            "zh": "之后无法关闭。",
            "zh-Hant": "之後無法關閉。",
        ],
        "shared.matrix-phone-trust-copy.copy.privatePeopleOnly": [
            "en": "Private chats can only include people Atum can confirm.",
            "vi": "Cuộc trò chuyện riêng tư chỉ gồm những người Atum xác nhận được.",
            "ja": "プライベートチャットには、Atumが確認できる人だけが参加できます。",
            "zh": "私密聊天只能包含 Atum 能确认身份的人。",
            "zh-Hant": "私密聊天只能包含 Atum 能確認身分的人。",
        ],
        "shared.matrix-phone-trust-copy.copy.privateNotReady": [
            "en": "Private chats need setting up again on this iPhone.",
            "vi": "Cần thiết lập lại trò chuyện riêng tư trên iPhone này.",
            "ja": "このiPhoneでプライベートチャットをもう一度設定する必要があります。",
            "zh": "需要在这台 iPhone 上重新设置私密聊天。",
            "zh-Hant": "需要在這支 iPhone 上重新設定私密聊天。",
        ],
    ]
}
