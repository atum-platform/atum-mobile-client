import AtumChat
import AtumDesign
import AtumNativeAPI
import Foundation

/// Every Team Space word the phone shows. Exported keys resolve from the
/// pinned atum-app catalog. The S3 additions that are not in this pin yet
/// resolve from `CompanyPendingCopy` with the exact desktop table values; the
/// session log lists them for the next `export:mobile` pin. Nothing here is
/// hand-edited into `ios/Vendor/AtumDesign`.
struct CompanyCopyKey: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(_ key: String) { rawValue = "shared.matrix-company-copy.copy." + key }
}

@MainActor
struct CompanyCopy {
    let design: LiveDesign

    func text(_ key: CompanyCopyKey) -> String {
        if design.copy.contains(key.rawValue) { return design.text(key.rawValue) }
        return CompanyPendingCopy.text(key.rawValue, locale: design.locale)
    }

    func text(_ key: String) -> String { text(CompanyCopyKey(key)) }

    func openChannel(_ name: String) -> String {
        let key = CompanyCopyKey("openChannel")
        if design.copy.contains(key.rawValue) {
            return design.text(key.rawValue, arguments: [.text(name)])
        }
        return CompanyPendingCopy.openChannel(name, locale: design.locale)
    }

    func memberCount(_ count: Int) -> String {
        let key = CompanyCopyKey("members")
        if design.copy.contains(key.rawValue) {
            return design.text(key.rawValue, arguments: [.number(Int64(count))])
        }
        return CompanyPendingCopy.memberCount(count, locale: design.locale)
    }

    func channelState(_ state: String) -> String {
        // The pin carries the source formatter flattened to one word
        // ("Preparing"), so the six wire states use the table until the
        // export emits per-state values (S4 follow-up).
        CompanyPendingCopy.channelState(state, locale: design.locale)
    }

    /// "A mời bạn vào công ty B", with a neutral word when the inviter is gone.
    func joinInvitation(inviter: String?, company: String) -> String {
        let name = inviter.flatMap { $0.isEmpty ? nil : $0 } ?? text(CompanyCopyKey("someone"))
        return CompanyPendingCopy.joinInvitation(inviter: name, company: company,
                                                  locale: design.locale)
    }

    func role(_ role: CompanyRole) -> String {
        text(CompanyCopyKey(role == .admin ? "admin" : "member"))
    }

    func memberState(_ state: CompanyMemberState) -> String? {
        switch state {
        case .active: nil
        case .invited: text(CompanyCopyKey("memberStateInvited"))
        case .revoking: text(CompanyCopyKey("memberStateRevoking"))
        case .removed: text(CompanyCopyKey("memberStateRemoved"))
        }
    }

    /// The seeded default channel's label (`#chung` in Vietnamese).
    func channelName(_ name: String, isDefault: Bool) -> String {
        isDefault ? text(CompanyCopyKey("defaultChannelName")) : name
    }

    var channelsTitle: String { text(CompanyCopyKey("channels")) }
    var invitationsTitle: String { text(CompanyCopyKey("invitations")) }

    // The switcher sheet and the create flow.
    var companiesTitle: String { text(CompanyCopyKey("companies")) }
    var createAction: String { text(CompanyCopyKey("createCompany")) }
    var newCompanyTitle: String { text(CompanyCopyKey("newCompany")) }
    var companyNameLabel: String { text(CompanyCopyKey("companyName")) }
    var createSubmit: String { text(CompanyCopyKey("create")) }
    var emptyTitle: String { text(CompanyCopyKey("emptyTitle")) }
    var emptyBody: String { text(CompanyCopyKey("emptyBody")) }
    var creationClosed: String { text(CompanyCopyKey("creationClosed")) }
    var noCompanies: String { text(CompanyCopyKey("noCompanies")) }

    /// The line under the name field after a create did not happen. Every
    /// refusal reuses the desktop's wording; a lost answer says the companies
    /// cannot be reached, and the same name can be tried again.
    func createFailure(_ failure: CompanyCreateFailure) -> String {
        switch failure {
        case .closed, .denied: creationClosed
        case .invalidName: text(CompanyCopyKey("invalid"))
        case .conflict: text(CompanyCopyKey("conflict"))
        case .limit: text(CompanyCopyKey("limit"))
        case .authentication: text(CompanyCopyKey("authentication"))
        case .unavailable: text(CompanyCopyKey("unavailable"))
        }
    }

    /// Mute and unmute reuse the Home row's exported wording.
    func muteTitle(isMuted: Bool) -> String {
        design.text(isMuted ? "src.matrix.chat-copy.copies.unmute" : "src.matrix.chat-copy.copies.mute")
    }

    /// What VoiceOver says for a mark, in the Home row's exported words.
    func markDescription(_ badge: Badge) -> [String] {
        switch badge {
        case let .mention(count):
            [design.text("desktop.atum.roster.unread", arguments: [.number(Int64(count))]),
             design.text("src.matrix.mobile-copy.mobileChatCopy.home.mentions")]
        case let .count(count):
            [design.text("desktop.atum.roster.unread", arguments: [.number(Int64(count))])]
        case .dot, .quietDot:
            [design.text("src.matrix.mobile-copy.mobileChatCopy.home.newMessages")]
        case .none:
            []
        }
    }

    /// What VoiceOver says for the Workplace tab's mark, with its numbers:
    /// "4 unread, Mentions you", "Invitations: 2", "New messages". The tab's
    /// `.count` is waiting invitations. There is no exported "N invitations"
    /// phrase yet, so the count follows the exported title; wanted key
    /// `shared.matrix-company-copy.copy.invitationsBadge` (plural; en "1
    /// invitation" / "%lld invitations", vi "%lld lời mời") to replace it.
    func tabMarkDescription(_ badge: Badge) -> String {
        switch badge {
        case let .count(count):
            "\(invitationsTitle): \(count.formatted())"
        default:
            markDescription(badge).joined(separator: ", ")
        }
    }

    func channelLabel(_ channel: CompanyChannelRow) -> String {
        var parts = [openChannel(channel.title)]
        parts += markDescription(channel.badge)
        if channel.isMuted { parts.append(design.text("src.matrix.mobile-copy.mobileChatCopy.home.muted")) }
        if !channel.canOpen { parts.append(channel.state) }
        return parts.joined(separator: ", ")
    }

    var notEncrypted: String { text(CompanyCopyKey("notEncrypted")) }
    var leavePending: String { text(CompanyCopyKey("leavePendingCopy")) }
    var lastAdmin: String { text(CompanyCopyKey("lastAdmin")) }
    var convergeFailed: String { text(CompanyCopyKey("convergeFailed")) }
    var membersTitle: String { text(CompanyCopyKey("membersTitle")) }
    var joinAction: String { text(CompanyCopyKey("joinAction")) }
    var laterAction: String { text(CompanyCopyKey("laterAction")) }
    var leaveAction: String { text(CompanyCopyKey("leaveAction")) }
    /// "Leave Anka?": the confirm names the company.
    func leaveTitle(company: String) -> String {
        let key = CompanyCopyKey("leaveTitleNamed")
        if design.copy.contains(key.rawValue) {
            return design.text(key.rawValue, arguments: [.text(company)])
        }
        return CompanyPendingCopy.leaveTitle(company: company, locale: design.locale)
    }

    /// What the person loses, then that they need an invite to return.
    var leaveMessage: String { text(CompanyCopyKey("leaveReturnBody")) }
    var leaveConfirm: String { text(CompanyCopyKey("leaveConfirm")) }
}

/// The keys this pin does not carry yet. Values are copied verbatim from
/// atum-app `apps/desktop/shared/matrix-company-copy.ts` (PR #648; the
/// 2026-10-24 switcher adds `emptyTitle`, `emptyBody` and `creationClosed`) so
/// the pin replaces them with no wording change. Listed in the session logs.
enum CompanyPendingCopy {
    private static let tables: [String: [String: String]] = [
        "en": [
            "membersTitle": "Members",
            "memberStateInvited": "Invited",
            "memberStateRevoking": "Removing access",
            "memberStateRemoved": "Removed",
            "joinAction": "Join",
            "laterAction": "Not now",
            "notEncrypted": "Company channels are not end-to-end encrypted",
            "defaultChannelName": "general",
            "convergeFailed": "The channel is still being prepared. You can open it when it is ready.",
            "leavePendingCopy": "Finishing your departure…",
            "lastAdmin": "Make another person an admin before you leave.",
            "leaveAction": "Leave company",
            "leaveTitle": "Leave company?",
            "leaveBody": "You will not read new messages. Messages you already sent stay visible to everyone.",
            "leaveReturnBody": "You will not read new messages. Messages you already sent stay visible to everyone. You will need an invite to come back.",
            "leaveConfirm": "Leave company",
            "someone": "Someone",
            "emptyTitle": "Create your company",
            "emptyBody": "Give your team one place to talk. You can add channels later.",
            "creationClosed": "Creating companies is not open yet.",
        ],
        "vi": [
            "membersTitle": "Thành viên",
            "memberStateInvited": "Đang mời",
            "memberStateRevoking": "Đang gỡ quyền",
            "memberStateRemoved": "Đã gỡ",
            "joinAction": "Tham gia",
            "laterAction": "Để sau",
            "notEncrypted": "Kênh công ty không mã hóa đầu cuối",
            "defaultChannelName": "chung",
            "convergeFailed": "Kênh đang được chuẩn bị. Bạn có thể mở khi kênh sẵn sàng.",
            "leavePendingCopy": "Đang hoàn tất việc rời công ty…",
            "lastAdmin": "Hãy chuyển quyền quản trị cho người khác trước khi rời.",
            "leaveAction": "Rời công ty",
            "leaveTitle": "Rời công ty?",
            "leaveBody": "Bạn sẽ không đọc được tin mới. Tin nhắn đã gửi vẫn hiển thị với mọi người.",
            "leaveReturnBody": "Bạn sẽ không đọc được tin mới. Tin nhắn đã gửi vẫn hiển thị với mọi người. Bạn sẽ cần được mời lại để quay về.",
            "leaveConfirm": "Rời công ty",
            "someone": "Một người",
            "emptyTitle": "Tạo công ty của bạn",
            "emptyBody": "Cho cả nhóm một nơi chung để trò chuyện. Bạn có thể thêm kênh sau.",
            "creationClosed": "Hiện chưa mở tạo công ty.",
        ],
        "ja": [
            "membersTitle": "メンバー",
            "memberStateInvited": "招待中",
            "memberStateRevoking": "アクセス解除中",
            "memberStateRemoved": "解除済み",
            "joinAction": "参加",
            "laterAction": "後で",
            "notEncrypted": "会社のチャンネルはエンドツーエンド暗号化されていません",
            "defaultChannelName": "general",
            "convergeFailed": "チャンネルを準備しています。準備ができたら開けます。",
            "leavePendingCopy": "退出を完了しています…",
            "lastAdmin": "退出する前に他の人を管理者にしてください。",
            "leaveAction": "会社を退出",
            "leaveTitle": "会社を退出しますか？",
            "leaveBody": "新しいメッセージは読めなくなります。すでに送信したメッセージは全員に表示されたままです。",
            "leaveReturnBody": "新しいメッセージは読めなくなります。すでに送信したメッセージは全員に表示されたままです。戻るには、あらためて招待が必要です。",
            "leaveConfirm": "会社を退出",
            "someone": "誰か",
            "emptyTitle": "会社を作成",
            "emptyBody": "チームが話せる場所を一つ用意します。チャンネルは後から追加できます。",
            "creationClosed": "会社の作成はまだ利用できません。",
        ],
        "zh": [
            "membersTitle": "成员",
            "memberStateInvited": "邀请中",
            "memberStateRevoking": "正在移除权限",
            "memberStateRemoved": "已移除",
            "joinAction": "加入",
            "laterAction": "稍后",
            "notEncrypted": "公司频道未进行端到端加密",
            "defaultChannelName": "general",
            "convergeFailed": "频道仍在准备中。就绪后即可打开。",
            "leavePendingCopy": "正在完成退出…",
            "lastAdmin": "离开前请先将另一位成员设为管理员。",
            "leaveAction": "离开公司",
            "leaveTitle": "离开公司？",
            "leaveBody": "你将无法阅读新消息。已发送的消息仍对所有人可见。",
            "leaveReturnBody": "你将无法阅读新消息。已发送的消息仍对所有人可见。如需回来，需要再次收到邀请。",
            "leaveConfirm": "离开公司",
            "someone": "某人",
            "emptyTitle": "创建你的公司",
            "emptyBody": "给团队一个共同的交流空间。之后可以再添加频道。",
            "creationClosed": "暂未开放创建公司。",
        ],
        "zh-Hant": [
            "membersTitle": "成員",
            "memberStateInvited": "邀請中",
            "memberStateRevoking": "正在移除權限",
            "memberStateRemoved": "已移除",
            "joinAction": "加入",
            "laterAction": "稍後",
            "notEncrypted": "公司頻道未進行端對端加密",
            "defaultChannelName": "general",
            "convergeFailed": "頻道仍在準備中。就緒後即可開啟。",
            "leavePendingCopy": "正在完成退出…",
            "lastAdmin": "離開前請先將另一位成員設為管理員。",
            "leaveAction": "離開公司",
            "leaveTitle": "離開公司？",
            "leaveBody": "你將無法閱讀新訊息。已傳送的訊息仍對所有人可見。",
            "leaveReturnBody": "你將無法閱讀新訊息。已傳送的訊息仍對所有人可見。如需回來，需要再次收到邀請。",
            "leaveConfirm": "離開公司",
            "someone": "某人",
            "emptyTitle": "建立你的公司",
            "emptyBody": "給團隊一個共同的交流空間。之後可以再新增頻道。",
            "creationClosed": "暫未開放建立公司。",
        ],
    ]

    private static func table(_ locale: String) -> [String: String] {
        tables[locale] ?? tables["en"]!
    }

    static func text(_ key: String, locale: String) -> String {
        let name = key.replacingOccurrences(of: "shared.matrix-company-copy.copy.", with: "")
        return table(locale)[name] ?? tables["en"]![name] ?? name
    }

    static func openChannel(_ name: String, locale: String) -> String {
        switch locale {
        case "vi": return "Mở # \(name)"
        case "ja": return "# \(name) を開く"
        case "zh": return "打开 # \(name)"
        case "zh-Hant": return "開啟 # \(name)"
        default: return "Open # \(name)"
        }
    }

    static func memberCount(_ count: Int, locale: String) -> String {
        switch locale {
        case "vi": return "\(count) thành viên"
        case "ja": return "\(count)人のメンバー"
        case "zh": return "\(count) 名成员"
        case "zh-Hant": return "\(count) 位成員"
        default: return count == 1 ? "1 member" : "\(count) members"
        }
    }

    static func channelState(_ state: String, locale: String) -> String {
        let values: [String: [String: String]] = [
            "en": ["ready": "Ready", "not_provisioned": "Preparing", "provisioning": "Preparing",
                   "reconciling": "Updating", "failed": "Needs attention", "archived": "Archived"],
            "vi": ["ready": "Sẵn sàng", "not_provisioned": "Đang chuẩn bị", "provisioning": "Đang chuẩn bị",
                   "reconciling": "Đang cập nhật", "failed": "Cần xử lý", "archived": "Đã lưu trữ"],
            "ja": ["ready": "準備完了", "not_provisioned": "準備中", "provisioning": "準備中",
                   "reconciling": "更新中", "failed": "対応が必要", "archived": "アーカイブ済み"],
            "zh": ["ready": "已就绪", "not_provisioned": "准备中", "provisioning": "准备中",
                   "reconciling": "更新中", "failed": "需要处理", "archived": "已归档"],
            "zh-Hant": ["ready": "已就緒", "not_provisioned": "準備中", "provisioning": "準備中",
                        "reconciling": "更新中", "failed": "需要處理", "archived": "已封存"],
        ]
        return values[locale]?[state] ?? values["en"]?[state] ?? "Preparing"
    }

    static func leaveTitle(company: String, locale: String) -> String {
        switch locale {
        case "vi": return "Rời công ty \(company)?"
        case "ja": return "\(company) を退出しますか？"
        case "zh": return "离开 \(company)？"
        case "zh-Hant": return "離開 \(company)？"
        default: return "Leave \(company)?"
        }
    }

    static func joinInvitation(inviter: String, company: String, locale: String) -> String {
        switch locale {
        case "vi": return "\(inviter) mời bạn vào công ty \(company)"
        case "ja": return "\(inviter) さんが \(company) に招待しました"
        case "zh": return "\(inviter) 邀请你加入 \(company)"
        case "zh-Hant": return "\(inviter) 邀請你加入 \(company)"
        default: return "\(inviter) invited you to \(company)"
        }
    }
}
