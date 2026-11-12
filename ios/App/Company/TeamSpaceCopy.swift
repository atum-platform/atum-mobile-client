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
        let table = Self.pending(key)
        return table?[locale] ?? table?["en"] ?? key
    }

    /// The wave 2 and wave 3 generated desktop tables.
    private static func pending(_ key: String) -> [String: String]? {
        TeamSpacePendingCopy.tables[key] ?? TeamSpaceWave3PendingCopy.tables[key]
    }

    /// A two-argument phrase ({0}, {1} in the pending table, `%1$@`, `%2$@` in the export).
    func text(_ key: String, _ first: String, _ second: String) -> String {
        if design.copy.contains(key) {
            return design.text(key, words: [first, second])
        }
        let table = Self.pending(key)
        return (table?[locale] ?? table?["en"] ?? key)
            .replacingOccurrences(of: "{0}", with: first)
            .replacingOccurrences(of: "{1}", with: second)
    }

    /// A count phrase: `.one` for 1, `.other` with the count, as the desktop function says it.
    func count(_ key: String, _ value: Int) -> String {
        text(key + (value == 1 ? ".one" : ".other"), value.formatted())
    }

    /// A one-argument phrase ({0} in the pending table, `%1$@` in the export).
    func text(_ key: String, _ argument: String) -> String {
        if design.copy.contains(key) { return design.text(key, words: [argument]) }
        let table = Self.pending(key)
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

    // MARK: Invite people (TS-11, `shared/matrix-team-space-copy.ts` `inviteSheet`)

    private static let sheet = team + "inviteSheet."
    func inviteSheetTitle(company: String) -> String { text(Self.sheet + "title", company) }
    var inviteSearch: String { text(Self.sheet + "search") }
    var inviteAdd: String { text(Self.sheet + "add") }
    var inviteInvite: String { text(Self.sheet + "invite") }
    var inviteAlreadyMember: String { text(Self.sheet + "alreadyMember") }
    var inviteAlreadyInvited: String { text(Self.sheet + "alreadyInvited") }
    func inviteInvited(_ name: String) -> String { text(Self.sheet + "invited", name) }
    var inviteNotAllowed: String { text(Self.sheet + "notAllowed") }
    var inviteCantInvite: String { text(Self.sheet + "cantInvite") }
    var inviteEmailOff: String { text(Self.sheet + "emailOff") }
    var peopleNoMatch: String { text(Self.team + "peopleNoMatch") }
    var working: String { text(Self.team + "working") }
    func refusal(_ reason: String) -> String? {
        let key = Self.team + "refusal." + reason
        return design.copy.contains(key) || TeamSpaceWave3PendingCopy.tables[key] != nil ? text(key) : nil
    }

    // MARK: Invite links (TS-11)

    var inviteLinkSection: String { text(Self.team + "inviteLinkSection") }
    var copyInviteLink: String { text(Self.team + "copyInviteLink") }
    var inviteLinkCreating: String { text(Self.team + "inviteLinkCreating") }
    var inviteLinkCopied: String { text(Self.team + "inviteLinkCopied") }
    var inviteLinkAudience: String { text(Self.team + "inviteLinkAudience") }
    func inviteLinkDuration(days: Int) -> String { count(Self.team + "inviteLinkDuration", days) }
    func inviteLinkCapacity(uses: Int) -> String { count(Self.team + "inviteLinkCapacity", uses) }
    var inviteLinkReplayed: String { text(Self.team + "inviteLinkReplayed") }
    var inviteLinksActive: String { text(Self.team + "inviteLinksActive") }
    func inviteLinkUsage(used: Int, max: Int) -> String {
        text(Self.team + "inviteLinkUsage", String(used), String(max))
    }
    func inviteLinkExpires(days: Int) -> String { count(Self.team + "inviteLinkExpires", days) }
    var inviteLinkRevoke: String { text(Self.team + "inviteLinkRevoke") }
    var inviteLinkRevoked: String { text(Self.team + "inviteLinkRevoked") }

    // MARK: Join with an invite link (`src/matrix/team-space/layout-copy.ts`)

    var joinWithInviteLink: String { text(Self.layout + "joinWithInviteLink") }
    var joinInviteTitle: String { text(Self.layout + "joinInviteTitle") }
    var inviteLinkLabel: String { text(Self.layout + "inviteLinkLabel") }
    var inviteLinkHint: String { text(Self.layout + "inviteLinkHint") }
    var previewInvite: String { text(Self.layout + "previewInvite") }
    var previewingInvite: String { text(Self.layout + "previewingInvite") }
    func invitedTo(_ company: String) -> String { text(Self.layout + "invitedTo", company) }
    func inviteFrom(_ inviter: String) -> String { text(Self.layout + "inviteFrom", inviter) }
    func inviteExpires(_ when: String) -> String { text(Self.layout + "inviteExpires", when) }
    var joinInvite: String { text(Self.layout + "joinInvite") }
    var joiningInvite: String { text(Self.layout + "joiningInvite") }
    func joinFailure(_ failure: CompanyInviteJoinFailure) -> String {
        switch failure {
        case .invalid: text(Self.layout + "invalidInviteLink")
        case .expired: text(Self.layout + "expiredInviteLink")
        case .revoked: text(Self.layout + "revokedInviteLink")
        case .exhausted: text(Self.layout + "exhaustedInviteLink")
        case .unavailable: text(Self.layout + "inviteUnavailable")
        }
    }
    func joinCompletion(_ completion: CompanyInviteJoinCompletion) -> String {
        completion == .alreadyMember ? text(Self.layout + "alreadyMemberInvite") : text(Self.layout + "inviteJoined")
    }

    // MARK: Channel sections and create (TS-13)

    var favorites: String { text(Self.team + "favorites") }
    var archivedSection: String { text(Self.team + "archivedSection") }
    var addChannels: String { text(Self.team + "addChannels") }
    var createChannelItem: String { text(Self.team + "createChannelItem") }
    var createChannelTitle: String { text(Self.team + "createChannelTitle") }
    var createChannelBody: String { text(Self.team + "createChannelBody") }
    var channelNameLabel: String { text(Self.team + "channelNameLabel") }
    var channelNamePlaceholder: String { text(Self.team + "channelNamePlaceholder") }
    var channelNameRequired: String { text(Self.team + "channelNameRequired") }
    var channelNameTooLong: String { text(Self.team + "channelNameTooLong") }
    var createChannelSubmit: String { text(Self.team + "createChannelSubmit") }
    var creatingChannel: String { text(Self.team + "creatingChannel") }
}
