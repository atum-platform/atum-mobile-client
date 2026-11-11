import AtumDesign
import AtumNativeAPI
import Foundation

/// The TS-6b thread words. Exported desktop keys (`src.matrix.thread-copy.*`)
/// are read from the design export; the rest read their proposed export key
/// first and fall back to `TeamSpaceThreadsPendingCopy` (the desktop's own
/// values, generated verbatim). Listed in `docs/ports/team-space-threads.md`.
@MainActor
struct CompanyThreadsCopy {
    let design: LiveDesign

    private static let thread = "src.matrix.thread-copy.copy."
    private static let company = "src.matrix.team-space.company-threads-copy.copy."

    /// The exported value, else the pending desktop value, else English.
    func text(_ key: String) -> String {
        if design.copy.contains(key) { return design.text(key) }
        let table = TeamSpaceThreadsPendingCopy.tables[key]
        return table?[design.locale] ?? table?["en"] ?? key
    }

    /// A one-argument phrase ({0} in the pending table, `%1$@` in the export).
    func text(_ key: String, _ argument: String) -> String {
        if design.copy.contains(key) { return design.text(key, arguments: [.text(argument)]) }
        let table = TeamSpaceThreadsPendingCopy.tables[key]
        return (table?[design.locale] ?? table?["en"] ?? key).replacingOccurrences(of: "{0}", with: argument)
    }

    // MARK: The room's thread panel and a thread (desktop `thread-copy.ts`)

    var threads: String { text(Self.thread + "threads") }
    var thread: String { text(Self.thread + "thread") }
    var openThreads: String { text(Self.thread + "openThreads") }
    var closeThreads: String { text(Self.thread + "closeThreads") }
    var backToThreads: String { text(Self.thread + "backToThreads") }
    var follow: String { text(Self.thread + "follow") }
    var unfollow: String { text(Self.thread + "unfollow") }
    var following: String { text(Self.thread + "following") }
    var noThreads: String { text(Self.thread + "noThreads") }
    var noFilteredThreads: String { text(Self.thread + "noFilteredThreads") }
    var threadUnavailable: String { text(Self.thread + "threadUnavailable") }
    var reply: String { text(Self.thread + "reply") }
    var unread: String { text(Self.thread + "unread") }
    func panelFilter(_ filter: CompanyThreadFilter) -> String {
        switch filter {
        case .recent: text(Self.thread + "recent")
        case .following: text(Self.thread + "following")
        case .unread: text(Self.thread + "unread")
        }
    }
    /// The exported plural (`src.matrix.thread-copy.copy.replies`).
    func panelReplies(_ count: Int) -> String {
        let key = Self.thread + "replies"
        if design.copy.contains(key) { return design.text(key, arguments: [.number(Int64(count))]) }
        return companyReplies(count)
    }

    // MARK: Team Space Threads (desktop `team-space/company-threads-copy.ts`)

    var companyTitle: String { text(Self.company + "title") }
    var filterLabel: String { text(Self.company + "filterLabel") }
    func companyFilter(_ filter: CompanyThreadFilter) -> String {
        switch filter {
        case .recent: text(Self.company + "recent")
        case .following: text(Self.company + "following")
        case .unread: text(Self.company + "unread")
        }
    }
    var companyFollow: String { text(Self.company + "follow") }
    var companyUnfollow: String { text(Self.company + "unfollow") }
    var companyUnread: String { text(Self.company + "unread") }
    var markRead: String { text(Self.company + "markRead") }
    func companyReplies(_ count: Int) -> String {
        text(Self.company + (count == 1 ? "replies.one" : "replies.other"), count.formatted())
    }
    func lastReply(_ when: String) -> String { text(Self.company + "lastReply", when) }
    func emptyTitle(_ filter: CompanyThreadFilter) -> String {
        switch filter {
        case .recent: text(Self.company + "emptyRecentTitle")
        case .following: text(Self.company + "emptyFollowingTitle")
        case .unread: text(Self.company + "emptyUnreadTitle")
        }
    }
    func emptyBody(_ filter: CompanyThreadFilter) -> String {
        switch filter {
        case .recent: text(Self.company + "emptyRecentBody")
        case .following: text(Self.company + "emptyFollowingBody")
        case .unread: text(Self.company + "emptyUnreadBody")
        }
    }
    var loadMore: String { text(Self.company + "loadMore") }
    func open(room: String) -> String { text(Self.company + "open", room) }
    var actionFailed: String { text(Self.company + "actionFailed") }
    var noPreview: String { text(Self.company + "noPreview") }
}
