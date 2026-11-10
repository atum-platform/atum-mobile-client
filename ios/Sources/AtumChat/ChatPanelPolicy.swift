import Foundation

/// The phone's side panel container.
///
/// One panel per chat. The chat's title and its "…" open it at its home; pages push inside it
/// (Members, a shared section's See all, an app's page). On iPhone it is a sheet with a medium and
/// a large height; on iPad it is the trailing inspector column. What it holds depends on the chat,
/// as on the desktop. This file is the pure part: which page, which height, and when it closes.
public enum ChatPanelPolicy {
    /// What kind of chat the panel belongs to.
    public enum Surface: Equatable, Sendable {
        case person
        case group
        case assistant
        case app
        case teamSpace
    }

    /// The panel's two heights on iPhone. iPad's column ignores them.
    public enum Height: Equatable, Sendable {
        case medium
        case large
    }

    /// A page pushed on the panel's home. The home itself is the empty path.
    public enum Page: Hashable, Sendable {
        /// A group's people, with what can be done about each of them.
        case members
        /// Every shared photo and video, file or link (plan M3).
        case shared(SharedSection)
        /// One of an app's declared pages, under Atum's bar (plan M5).
        case appPage(routeID: String)
    }

    public enum SharedSection: String, Hashable, Sendable, CaseIterable {
        case media
        case files
        case links
    }

    /// Where the panel opens. The assistant card is long and edited where it stands, so it opens
    /// tall; an app page fills the panel like a browser. Everything else opens at medium, with the
    /// chat still in view above it.
    public static func openingHeight(for surface: Surface, page: Page? = nil) -> Height {
        if case .appPage? = page { return .large }
        return surface == .assistant ? .large : .medium
    }

    /// The height after a page is pushed: an app page raises the panel to large; any other page
    /// keeps the height the person chose. Going back never shrinks it.
    public static func height(afterPushing page: Page, from current: Height) -> Height {
        if case .appPage = page { return .large }
        return current
    }

    /// What the panel belongs to. A panel never outlives its chat or its account: a new room, a
    /// new account or a signed-out session closes it, and its pages go with it.
    public struct Scope: Equatable, Sendable {
        public let accountID: String
        public let roomID: String

        public init(accountID: String, roomID: String) {
            self.accountID = accountID
            self.roomID = roomID
        }
    }

    public static func staysOpen(from old: Scope?, to new: Scope?) -> Bool {
        guard let old, let new else { return false }
        return old == new
    }
}
