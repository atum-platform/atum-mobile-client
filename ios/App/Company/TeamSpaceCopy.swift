import AtumDesign
import AtumNativeAPI
import Foundation

/// The wave 2 Team Space words (pages, company menu and overview, sidebar,
/// Activity, Saved, channel chrome). Each reads its proposed design-export key
/// first; until the export carries it, the desktop's own value comes from
/// `TeamSpacePendingCopy` (generated verbatim). Words the export already has
/// are read from it directly. The missing keys are listed in
/// `docs/ports/team-space-structure.md` (PENDING-COPY).
@MainActor
struct TeamSpaceCopy {
    let design: LiveDesign

    private var locale: String { design.locale }

    /// The exported value, else the pending desktop value, else English.
    func text(_ key: String) -> String {
        if design.copy.contains(key) { return design.text(key) }
        let table = TeamSpacePendingCopy.tables[key]
        return table?[locale] ?? table?["en"] ?? key
    }

    /// A one-argument phrase ({0} in the pending table, `%1$@` in the export).
    func text(_ key: String, _ argument: String) -> String {
        if design.copy.contains(key) { return design.text(key, arguments: [.text(argument)]) }
        let table = TeamSpacePendingCopy.tables[key]
        return (table?[locale] ?? table?["en"] ?? key).replacingOccurrences(of: "{0}", with: argument)
    }

    private static let board = "shared.matrix-company-board-copy.copy."
    private static let company = "shared.matrix-company-copy.copy."
    private static let team = "shared.matrix-team-space-copy.copy."
    private static let layout = "src.matrix.team-space.layout-copy.copy."
    private static let activity = "src.matrix.team-space.activity-copy.copy."
    private static let saved = "src.matrix.team-space.saved-messages-copy.copy."
    private static let pinned = "src.matrix.team-space.pinned-copy.copy."

    // MARK: Pages (TS-10)

    var pagesLabel: String { text(Self.board + "tabs") }
    func page(_ tab: CompanySpaceTab) -> String {
        switch tab {
        case .chat: text(Self.board + "chat")
        case .board: text(Self.board + "board")
        case .marketplace: text(Self.board + "marketplace")
        }
    }
    var boardUnavailable: String { text(Self.board + "unavailable") }

    // MARK: Company menu and overview (TS-8)

    var companyOverview: String { text(Self.company + "companyOverview") }
    var invitePeople: String { text(Self.team + "invitePeople") }
    var companySettings: String { text(Self.team + "companySettings") }
    var addCompany: String { text(Self.layout + "addCompany") }
    /// The Chief of Staff (exported from the board copy).
    var chiefOfStaff: String { design.text("shared.matrix-company-board-copy.copy.chiefOfStaff") }

    // MARK: Sidebar (TS-6)

    func sidebarSearch(company: String) -> String { text(Self.team + "sidebarSearch", company) }
    var inviteTeammates: String { text(Self.team + "inviteTeammates") }
    /// Exported from the thread copy.
    var threads: String { design.text("src.matrix.thread-copy.copy.threads") }
    var savedTitle: String { text(Self.saved + "title") }
    var savedEmptyTitle: String { text(Self.saved + "emptyTitle") }
    var savedEmptyBody: String { text(Self.saved + "emptyBody") }
    var savedUnavailable: String { text(Self.saved + "unavailable") }
    var savedUnavailableBody: String { text(Self.saved + "unavailableBody") }
    var savedFailed: String { text(Self.saved + "failed") }
    var savedYou: String { text(Self.saved + "you") }

    // MARK: Activity (TS-7)

    var activityTitle: String { text(Self.activity + "title") }
    var activityAll: String { text(Self.activity + "all") }
    var activityMentions: String { text(Self.activity + "mentions") }
    var activityFilterLabel: String { text(Self.activity + "filterLabel") }
    var activityMention: String { text(Self.activity + "mention") }
    var activityThreadReply: String { text(Self.activity + "threadReply") }
    var activityUnread: String { text(Self.activity + "unread") }
    var activityEmptyAllTitle: String { text(Self.activity + "emptyAllTitle") }
    var activityEmptyAllBody: String { text(Self.activity + "emptyAllBody") }
    var activityEmptyMentionsTitle: String { text(Self.activity + "emptyMentionsTitle") }
    var activityEmptyMentionsBody: String { text(Self.activity + "emptyMentionsBody") }
    var activityLoadMore: String { text(Self.activity + "loadMore") }
    var activityFailed: String { text(Self.activity + "failed") }
    var activitySomeone: String { text(Self.activity + "someone") }
    func activityOpen(room: String) -> String { text(Self.activity + "open", room) }

    // MARK: Channel chrome (TS-9)

    var channelDetails: String { text(Self.company + "channelDetails") }
    var channelMembersTitle: String { text(Self.team + "channelMembersTitle") }
    var favoriteChannel: String { text(Self.team + "favoriteChannel") }
    var unfavoriteChannel: String { text(Self.team + "unfavoriteChannel") }
    var channelTopicLabel: String { text(Self.team + "channelTopicLabel") }
    var defaultChannelPurpose: String { text(Self.team + "defaultChannelPurpose") }
    var leaveChannel: String { text(Self.team + "leaveChannel") }
    func channelStartTitle(_ channel: String) -> String { text(Self.team + "channelStartTitle", channel) }
    func channelCreatedOn(_ date: String) -> String { text(Self.team + "channelCreatedOn", date) }
    var pinnedMessages: String { text(Self.pinned + "pinnedMessages") }
    var noPinnedMessages: String { text(Self.pinned + "noPinnedMessages") }
    var pinnedMessageUnavailable: String { text(Self.pinned + "pinnedMessageUnavailable") }
    func pinnedMessageCount(_ count: Int) -> String {
        text(Self.pinned + (count == 1 ? "pinnedMessageCount.one" : "pinnedMessageCount.other"),
             count.formatted())
    }
}
