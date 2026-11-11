import AtumChat
import Foundation

// Team Space threads (TS-6b): the follow preference the desktop keeps in room
// account data, the company-wide thread list behind the sidebar's Threads row,
// its filters and badge, and the row overrides that bridge a tap and the next
// sync. Every rule is the desktop's (atum-desktop `apps/desktop/src/matrix/threads.ts`,
// `team-space/company-threads.tsx`, `company-workspace.tsx`); nothing here holds
// authority or does I/O.

// MARK: Follow preference (desktop `threads.ts` `MATRIX_THREAD_ATTENTION`)

/// The person's private follow choices in one room: `io.atum.thread_attention.v1`
/// room account data, `{"v":1,"followed":[…],"unfollowed":[…]}`. It changes
/// attention only, never who may read a thread. Malformed data reads as no
/// choices (fail closed to the automatic rule), as on the desktop.
public struct CompanyThreadAttention: Equatable, Sendable {
    public static let accountDataType = "io.atum.thread_attention.v1"
    /// Each list holds at most this many roots (desktop `MATRIX_THREAD_PREFERENCES_MAX`).
    public static let maximum = 1_000

    public let followed: Set<String>
    public let unfollowed: Set<String>

    public init(followed: Set<String> = [], unfollowed: Set<String> = []) {
        self.followed = followed
        self.unfollowed = unfollowed
    }

    /// Nil content (never written) and anything the desktop would not accept read as empty.
    public static func parse(_ contentJSON: String?) -> CompanyThreadAttention {
        guard let contentJSON, let data = contentJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["followed", "unfollowed", "v"],
              let version = root["v"] as? NSNumber, !isBool(version), version.intValue == 1,
              version.doubleValue == 1,
              let followed = ids(root["followed"]), let unfollowed = ids(root["unfollowed"]),
              followed.isDisjoint(with: unfollowed) else { return CompanyThreadAttention() }
        return CompanyThreadAttention(followed: followed, unfollowed: unfollowed)
    }

    /// The desktop's thread-root rule (`validThreadRootId`): `$` and 1…1023 more characters.
    public static func isRootID(_ value: String) -> Bool {
        value.hasPrefix("$") && (2...1_024).contains(value.unicodeScalars.count)
            && !value.unicodeScalars.contains { "\n\r\u{2028}\u{2029}".unicodeScalars.contains($0) }
    }

    /// The record after one follow or unfollow, sorted as the desktop writes it.
    /// Nil when either list would pass the limit (desktop `matrix_thread_limit`).
    public func setting(_ rootID: String, followed follow: Bool) -> CompanyThreadAttention? {
        guard Self.isRootID(rootID) else { return nil }
        var yes = followed
        var no = unfollowed
        if follow {
            yes.insert(rootID)
            no.remove(rootID)
        } else {
            no.insert(rootID)
            yes.remove(rootID)
        }
        guard yes.count <= Self.maximum, no.count <= Self.maximum else { return nil }
        return CompanyThreadAttention(followed: yes, unfollowed: no)
    }

    /// The account-data content, keys and lists sorted (`{"followed":…,"unfollowed":…,"v":1}`).
    public var contentJSON: String {
        let body: [String: Any] = ["v": 1, "followed": followed.sorted(), "unfollowed": unfollowed.sorted()]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{\"followed\":[],\"unfollowed\":[],\"v\":1}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The desktop's `followed`: an explicit unfollow wins, then an explicit
    /// follow, then the automatic rule (taking part, or being mentioned).
    public func isFollowed(_ rootID: String, automatic: Bool) -> Bool {
        if unfollowed.contains(rootID) { return false }
        return followed.contains(rootID) || automatic
    }

    private static func ids(_ value: Any?) -> Set<String>? {
        guard let list = value as? [Any], list.count <= maximum else { return nil }
        var result = Set<String>()
        for item in list {
            guard let id = item as? String, isRootID(id), result.insert(id).inserted else { return nil }
        }
        return result
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

// MARK: One thread (desktop `MatrixCompanyThread`)

/// One message of a thread as the list shows it.
public struct CompanyThreadMessage: Equatable, Sendable {
    public let eventID: String
    public let senderID: String
    /// The sender's display name, never a Matrix ID (nil when the profile has none).
    public let senderName: String?
    public let senderAvatarURI: String?
    public let isOwn: Bool
    /// The message's text; empty when it has none to show (the row says "Message unavailable").
    public let body: String
    /// Milliseconds since 1970.
    public let sentAt: Int64
    /// `m.mentions.user_ids` names this account.
    public let mentionsViewer: Bool

    public init(eventID: String, senderID: String, senderName: String?, senderAvatarURI: String? = nil,
                isOwn: Bool, body: String, sentAt: Int64, mentionsViewer: Bool = false) {
        self.eventID = eventID
        self.senderID = senderID
        self.senderName = senderName
        self.senderAvatarURI = senderAvatarURI
        self.isOwn = isOwn
        self.body = body
        self.sentAt = sentAt
        self.mentionsViewer = mentionsViewer
    }
}

/// One standard Matrix thread in a company channel or conversation.
public struct CompanyThread: Equatable, Sendable, Identifiable {
    public let roomID: String
    public let root: CompanyThreadMessage
    /// The newest reply, when the server named one.
    public let latest: CompanyThreadMessage?
    public let replyCount: Int
    /// Milliseconds since 1970: the newest reply, else the root.
    public let lastActivityAt: Int64
    public var unread: Bool
    /// Unread mentions of the viewer in the thread.
    public var highlights: Int
    public var followed: Bool

    /// Desktop `companyThreadKey`.
    public var id: String { roomID + "\u{0}" + root.eventID }

    public init(roomID: String, root: CompanyThreadMessage, latest: CompanyThreadMessage?, replyCount: Int,
                unread: Bool = false, highlights: Int = 0, followed: Bool = false) {
        self.roomID = roomID
        self.root = root
        self.latest = latest
        self.replyCount = max(0, replyCount)
        lastActivityAt = latest.map { max($0.sentAt, root.sentAt) } ?? root.sentAt
        self.unread = unread
        self.highlights = max(0, highlights)
        self.followed = followed
    }

    /// The people whose faces the row shows: the root's sender, then the latest replier.
    public var faces: [CompanyThreadMessage] {
        guard let latest, latest.senderID != root.senderID else { return [root] }
        return [root, latest]
    }
}

/// The list's segments (desktop `CompanyThreadFilter` / `MatrixThreadFilter`).
public enum CompanyThreadFilter: String, CaseIterable, Sendable, Equatable, Hashable {
    case recent, following, unread
}

public enum CompanyThreads {
    /// The company list pages 25 at a time (desktop `pageSize`).
    public static let pageSize = 25
    /// A room's panel keeps at most this many (desktop `MATRIX_THREADS_MAX`).
    public static let roomMaximum = 100
    /// The company list keeps at most this many (desktop `MATRIX_COMPANY_THREADS_MAX`).
    public static let companyMaximum = 200

    /// Projects one room's server thread list onto the desktop's rows. The
    /// unread state and mentions come from the homeserver's notification list
    /// (`activity`: this room's items), the follow state from the room's
    /// attention record and the automatic rule.
    ///
    /// Taking part is what the phone can see: the root or the newest reply is
    /// yours. Being mentioned: the root or the newest reply names you, or a
    /// notification in the thread did.
    public static func project(roomID: String, roots: [(root: CompanyThreadMessage, latest: CompanyThreadMessage?,
                                                        replyCount: Int)],
                               attention: CompanyThreadAttention,
                               activity: [CompanyActivityItem]) -> [CompanyThread] {
        var seen = Set<String>()
        var threads = [CompanyThread]()
        for entry in roots {
            let rootID = entry.root.eventID
            guard CompanyThreadAttention.isRootID(rootID), seen.insert(rootID).inserted else { continue }
            let inThread = activity.filter { $0.roomID == roomID && $0.threadRootID == rootID }
            let unreadItems = inThread.filter(\.unread)
            let participated = entry.root.isOwn || entry.latest?.isOwn == true
            let mentioned = entry.root.mentionsViewer || entry.latest?.mentionsViewer == true
                || inThread.contains { $0.kind == .mention }
            threads.append(CompanyThread(
                roomID: roomID, root: entry.root, latest: entry.latest, replyCount: entry.replyCount,
                unread: !unreadItems.isEmpty,
                highlights: unreadItems.filter { $0.kind == .mention }.count,
                followed: attention.isFollowed(rootID, automatic: participated || mentioned)))
        }
        return Array(sorted(threads).prefix(roomMaximum))
    }

    /// Newest activity first, then the root ID, then the room (desktop `matrixCompanyThreads`).
    public static func sorted(_ threads: [CompanyThread]) -> [CompanyThread] {
        threads.sorted { left, right in
            if left.lastActivityAt != right.lastActivityAt { return left.lastActivityAt > right.lastActivityAt }
            if left.root.eventID != right.root.eventID { return left.root.eventID < right.root.eventID }
            return left.roomID < right.roomID
        }
    }

    /// The company list: only rooms the company's current directory lists
    /// (desktop `authorizedCompanyThreads`), newest first, at most 200.
    public static func company(_ threads: [CompanyThread], allowedRoomIDs: Set<String>) -> [CompanyThread] {
        Array(sorted(threads.filter { allowedRoomIDs.contains($0.roomID) }).prefix(companyMaximum))
    }

    public static func filter(_ threads: [CompanyThread], by filter: CompanyThreadFilter) -> [CompanyThread] {
        switch filter {
        case .recent: threads
        case .following: threads.filter(\.followed)
        case .unread: threads.filter(\.unread)
        }
    }

    /// The Threads row's mark (desktop `companyBadge`): unread mentions as a
    /// count, else a dot while any thread is unread.
    public static func badge(_ threads: [CompanyThread]) -> Badge {
        let mentions = threads.reduce(0) { $0 + $1.highlights }
        if mentions > 0 { return .mention(mentions) }
        return threads.contains(where: \.unread) ? .dot : .none
    }
}

// MARK: Row overrides (desktop `CompanyThreadsView` `ThreadOverride`)

/// What a tap changed before sync caught up. Once the synced thread says the
/// same thing (or a newer reply arrives) the override is dropped, so another
/// device and a later reply still win.
public struct CompanyThreadOverride: Equatable, Sendable {
    public var followed: Bool?
    public var unread: Bool?
    /// The thread's `lastActivityAt` when it was marked read.
    public var readAt: Int64?

    public init(followed: Bool? = nil, unread: Bool? = nil, readAt: Int64? = nil) {
        self.followed = followed
        self.unread = unread
        self.readAt = readAt
    }

    public var isEmpty: Bool { followed == nil && unread == nil && readAt == nil }

    /// The thread as the row shows it.
    public func applied(to thread: CompanyThread) -> CompanyThread {
        var shown = thread
        if let followed { shown.followed = followed }
        if let unread, thread.lastActivityAt <= (readAt ?? .max) {
            shown.unread = unread
        }
        return shown
    }

    /// The overrides still needed after a new read of the threads.
    public static func reconcile(_ overrides: [String: CompanyThreadOverride],
                                 with threads: [CompanyThread]) -> [String: CompanyThreadOverride] {
        let byID = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept = [String: CompanyThreadOverride]()
        for (key, value) in overrides {
            guard let thread = byID[key] else { continue }
            var next = value
            if next.followed == thread.followed { next.followed = nil }
            if next.unread == false, !thread.unread || thread.lastActivityAt > (next.readAt ?? 0) {
                next.unread = nil
                next.readAt = nil
            }
            if !next.isEmpty { kept[key] = next }
        }
        return kept
    }
}
