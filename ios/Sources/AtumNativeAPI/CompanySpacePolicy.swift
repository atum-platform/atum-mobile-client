import AtumChat
import Foundation

// Team Space structure (wave 2, TS-6..TS-10): the company pages, the company
// menu, the sidebar's utility rows and search, Saved messages and the Activity
// inbox. Every rule here is the desktop's (atum-app `050ede8edf5`); nothing
// here holds authority or does I/O.

// MARK: Company pages (TS-10, desktop `company-marketplace-store.ts:51–61`)

public enum CompanySpaceTab: String, CaseIterable, Sendable, Equatable, Hashable {
    case chat, board, marketplace
}

public enum CompanySpaceTabs {
    /// The company's pages, in order: Chat · Board, then Marketplace while the
    /// company Store answers with something to get (never a dead tab).
    public static func ids(marketplaceAvailable: Bool) -> [CompanySpaceTab] {
        marketplaceAvailable ? [.chat, .board, .marketplace] : [.chat, .board]
    }

    /// A remembered page that is not there any more opens Chat.
    public static func effective(_ tab: CompanySpaceTab?, marketplaceAvailable: Bool) -> CompanySpaceTab {
        guard let tab, ids(marketplaceAvailable: marketplaceAvailable).contains(tab) else { return .chat }
        return tab
    }
}

// MARK: Company menu (TS-8, desktop `company-menu.tsx:26–36`, `company-workspace.tsx:2717–2725`)

/// What the viewer may do from the company menu. An entry they may not use is
/// not drawn at all (never drawn disabled), as on the desktop.
public struct CompanyMenuAllowed: Equatable, Sendable {
    public var overview: Bool
    public var wallet: Bool
    public var invite: Bool
    public var settings: Bool
    public var members: Bool
    public var create: Bool
    public var leave: Bool

    public init(overview: Bool = false, wallet: Bool = false, invite: Bool = false, settings: Bool = false,
                members: Bool = false, create: Bool = false, leave: Bool = false) {
        self.overview = overview
        self.wallet = wallet
        self.invite = invite
        self.settings = settings
        self.members = members
        self.create = create
        self.leave = leave
    }

    /// - Parameters:
    ///   - companySelected: a company is open.
    ///   - snapshotLoaded: its member snapshot has been read.
    ///   - viewerIsAdmin: the snapshot's own row is an admin (owners are admins on the 1.1 wire).
    ///   - inviteAvailable: the phone has a way to invite (the invite sheet, TS-11). Desktop's
    ///     legacy profile lets owners and admins invite.
    ///   - teamAdminAvailable: the team-admin profile (wire 1.3 admin read) is active; Company
    ///     settings (policies, logo) needs it.
    ///   - walletAvailable: the phone can open the company wallet (TS-15). Owners and admins only.
    ///   - canCreate: the directory says this person may create a company.
    ///   - canLeave: the person can leave now (a member, not already leaving).
    public static func resolve(companySelected: Bool, snapshotLoaded: Bool, viewerIsAdmin: Bool,
                               inviteAvailable: Bool, teamAdminAvailable: Bool, walletAvailable: Bool,
                               canCreate: Bool, canLeave: Bool) -> CompanyMenuAllowed {
        CompanyMenuAllowed(
            overview: companySelected,
            wallet: companySelected && walletAvailable && viewerIsAdmin,
            invite: snapshotLoaded && inviteAvailable && viewerIsAdmin,
            settings: snapshotLoaded && teamAdminAvailable && viewerIsAdmin,
            members: snapshotLoaded,
            create: canCreate,
            leave: companySelected && canLeave)
    }

    /// Entries about the open company (the first group of the menu).
    public var inCompany: Bool { overview || wallet || invite || settings }
    /// Add company and Leave company (the last group).
    public var exits: Bool { create || leave }
}

// MARK: Sidebar utility rows (TS-6, desktop `team-space/sidebar-entry-visibility.ts`)

/// Threads, Saved and Drafts stay out of a new team's way: each appears once it
/// has something to open. Activity is not a row; it is the header icon.
public struct TeamSpaceSidebarEntries: Equatable, Sendable {
    public let threads: Bool
    public let saved: Bool
    public let drafts: Bool

    public init(threads: Int, saved: Int, drafts: Int) {
        self.threads = threads > 0
        self.saved = saved > 0
        self.drafts = drafts > 0
    }
}

// MARK: Sidebar search (TS-6, desktop `channel-sections.tsx:69–73`, `conversation-sections.tsx:115–139`)

public enum TeamSpaceSearch {
    /// The trimmed, lowercased query; nil when there is nothing to filter by.
    public static func needle(_ query: String, locale: Locale) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased(with: locale)
    }

    /// A row stays when there is no needle or any of its words contains it.
    public static func matches(_ values: [String], needle: String?, locale: Locale) -> Bool {
        guard let needle else { return true }
        return values.contains { $0.lowercased(with: locale).contains(needle) }
    }
}

// MARK: Saved messages (TS-6, desktop `shared/matrix-saved-messages.ts`)

public struct CompanySavedMessagePointer: Equatable, Sendable, Identifiable {
    public let roomID: String
    public let eventID: String
    /// Milliseconds since 1970, as the desktop writes it.
    public let savedAt: Int64

    public var id: String { roomID + "\u{0}" + eventID }

    public init(roomID: String, eventID: String, savedAt: Int64) {
        self.roomID = roomID
        self.eventID = eventID
        self.savedAt = savedAt
    }
}

/// The account's private Saved list (`com.atum.saved_messages`), shared with the
/// desktop. The phone only reads it; a malformed or newer record reads as nil,
/// so the row stays hidden rather than showing a guess.
public enum CompanySavedMessages {
    public static let accountDataType = "com.atum.saved_messages"
    public static let maximum = 200
    private static let maximumDateMS: Int64 = 8_640_000_000_000_000

    /// Nil content (never saved) is an empty list; unreadable content is nil.
    public static func parse(_ contentJSON: String?) -> [CompanySavedMessagePointer]? {
        guard let contentJSON else { return [] }
        guard let data = contentJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? NSNumber, !isBool(version), version.intValue == 1,
              let messages = root["messages"] as? [Any], messages.count <= maximum else { return nil }
        var seen = Set<String>()
        var result = [CompanySavedMessagePointer]()
        for candidate in messages {
            guard let item = candidate as? [String: Any],
                  let roomID = item["room_id"] as? String, isRoomID(roomID),
                  let eventID = item["event_id"] as? String, isEventID(eventID),
                  let saved = item["saved_at"] as? NSNumber, !isBool(saved),
                  let savedAt = exactInteger(saved), savedAt >= 0, savedAt <= maximumDateMS else { return nil }
            let pointer = CompanySavedMessagePointer(roomID: roomID, eventID: eventID, savedAt: savedAt)
            guard seen.insert(pointer.id).inserted else { return nil }
            result.append(pointer)
        }
        return result.sorted { left, right in
            if left.savedAt != right.savedAt { return left.savedAt > right.savedAt }
            if left.roomID != right.roomID { return left.roomID < right.roomID }
            return left.eventID < right.eventID
        }
    }

    static func isRoomID(_ value: String) -> Bool {
        value.range(of: #"^![!-9;-~]{1,255}:[!-~]{1,255}$"#, options: .regularExpression) != nil
    }

    static func isEventID(_ value: String) -> Bool {
        value.range(of: #"^\$[!-~]{1,1023}$"#, options: .regularExpression) != nil
    }
}

// MARK: Activity (TS-7, desktop `team-space/activity.tsx`, `shared/matrix-company-activity.ts`)

public enum CompanyActivityKind: String, Equatable, Sendable {
    case mention
    case threadReply = "thread_reply"
}

/// One entry of the company's Activity inbox: a mention of the viewer, or a
/// reply in a thread. Display-only; the room stays the source.
public struct CompanyActivityItem: Equatable, Sendable, Identifiable {
    public let roomID: String
    public let eventID: String
    public let kind: CompanyActivityKind
    public let body: String
    public let senderID: String
    /// Milliseconds since 1970.
    public let sentAt: Int64
    public let unread: Bool
    public let threadRootID: String?

    public var id: String { roomID + "\u{0}" + eventID }

    public init(roomID: String, eventID: String, kind: CompanyActivityKind, body: String, senderID: String,
                sentAt: Int64, unread: Bool, threadRootID: String? = nil) {
        self.roomID = roomID
        self.eventID = eventID
        self.kind = kind
        self.body = body
        self.senderID = senderID
        self.sentAt = sentAt
        self.unread = unread
        self.threadRootID = threadRootID
    }
}

public enum CompanyActivityFilter: String, CaseIterable, Sendable {
    case all, mentions
}

/// The phone reads Activity from the homeserver's own notification list
/// (`GET /_matrix/client/v3/notifications`): the server-side view of the same
/// two things desktop projects from its synced tail (a message that mentions
/// the viewer, a reply in a thread). Only rooms the company directory lists
/// survive (desktop `authorizedCompanyActivity`).
public enum CompanyActivityFeed {
    /// The desktop never keeps more than this (`MATRIX_COMPANY_ACTIVITY_MAX`).
    public static let maximum = 200
    /// One page of the view (desktop `pageSize = 25`).
    public static let pageSize = 25
    static let bodyMaximum = 600

    public static func parse(notificationsJSON data: Data, ownUserID: String,
                             roomIDs: Set<String>) -> [CompanyActivityItem]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notifications = root["notifications"] as? [Any] else { return nil }
        var seen = Set<String>()
        var items = [CompanyActivityItem]()
        for candidate in notifications {
            guard let notification = candidate as? [String: Any],
                  let roomID = notification["room_id"] as? String, roomIDs.contains(roomID),
                  let event = notification["event"] as? [String: Any],
                  let eventID = event["event_id"] as? String,
                  let sender = event["sender"] as? String, sender != ownUserID,
                  let type = event["type"] as? String, type == "m.room.message",
                  let content = event["content"] as? [String: Any],
                  let body = content["body"] as? String else { continue }
            let relation = content["m.relates_to"] as? [String: Any]
            let threadRoot = (relation?["rel_type"] as? String) == "m.thread"
                ? relation?["event_id"] as? String : nil
            let kind: CompanyActivityKind
            if highlights(notification["actions"]) || mentions(content, userID: ownUserID) {
                kind = .mention
            } else if threadRoot != nil {
                kind = .threadReply
            } else {
                continue
            }
            let item = CompanyActivityItem(
                roomID: roomID, eventID: eventID, kind: kind,
                body: String(body.prefix(bodyMaximum)), senderID: sender,
                sentAt: (event["origin_server_ts"] as? NSNumber).flatMap(exactInteger)
                    ?? (notification["ts"] as? NSNumber).flatMap(exactInteger) ?? 0,
                unread: (notification["read"] as? Bool).map { !$0 } ?? false,
                threadRootID: threadRoot)
            guard seen.insert(item.id).inserted else { continue }
            items.append(item)
        }
        return Array(items.sorted { left, right in
            if left.sentAt != right.sentAt { return left.sentAt > right.sentAt }
            return left.id < right.id
        }.prefix(maximum))
    }

    public static func filtered(_ items: [CompanyActivityItem], by filter: CompanyActivityFilter) -> [CompanyActivityItem] {
        filter == .mentions ? items.filter { $0.kind == .mention } : items
    }

    /// The header icon's mark (desktop `company-workspace.tsx:2748–2754` with
    /// `companyBadge`): unread mentions as a count, else a dot for an unread
    /// thread reply.
    public static func badge(_ items: [CompanyActivityItem]) -> Badge {
        let unread = items.filter(\.unread)
        let mentions = unread.filter { $0.kind == .mention }.count
        if mentions > 0 { return .mention(mentions) }
        return unread.contains { $0.kind == .threadReply } ? .dot : .none
    }

    private static func highlights(_ actions: Any?) -> Bool {
        (actions as? [Any] ?? []).contains { action in
            guard let tweak = action as? [String: Any], (tweak["set_tweak"] as? String) == "highlight" else {
                return false
            }
            // A highlight tweak with no value means true (Matrix push rules).
            return (tweak["value"] as? Bool) ?? true
        }
    }

    private static func mentions(_ content: [String: Any], userID: String) -> Bool {
        ((content["m.mentions"] as? [String: Any])?["user_ids"] as? [String] ?? []).contains(userID)
    }
}

private func isBool(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
}

private func exactInteger(_ number: NSNumber) -> Int64? {
    let double = number.doubleValue
    guard double.isFinite, double.rounded() == double, abs(double) <= 9_007_199_254_740_991 else { return nil }
    return Int64(double)
}
