import AtumChat
import AtumNativeAPI
import Foundation
import MatrixRustSDK

// Matrix thread operations shared with Team Space. Atum follow preferences
// are the desktop's room account data; server-side MSC4306 subscriptions
// are a separate SDK capability.

/// One server thread of a room, before the policy projects it.
struct CompanyThreadRoot: Sendable {
    let root: CompanyThreadMessage
    let latest: CompanyThreadMessage?
    let replyCount: Int
}

enum CompanyThreadsMatrixFailure: Error { case invalid, refused, limit }
enum RoomThreadsFailure: Error { case unavailable, invalidTarget }

/// A room-scoped native list. Keep one service for all pages of an open list.
@MainActor
final class RoomThreadList {
    private let service: ThreadListService
    private let session: LiveMatrixSession
    private let room: Room
    private let roomID: String
    private let isEligible: @MainActor () -> Bool

    init(room: Room, roomID: String, session: LiveMatrixSession, isEligible: @escaping @MainActor () -> Bool) {
        self.room = room
        self.roomID = roomID
        self.session = session
        self.isEligible = isEligible
        service = room.threadListService()
    }

    var canPaginate: Bool {
        guard isCurrent, service.items().count < CompanyThreads.roomMaximum else { return false }
        guard case .idle(endReached: false) = service.paginationState() else { return false }
        return true
    }

    func paginate() async throws {
        guard isCurrent else { throw RoomThreadsFailure.unavailable }
        guard canPaginate else { return }
        try await service.paginate()
        guard isCurrent else { throw RoomThreadsFailure.unavailable }
    }

    /// Signals when the SDK's root/reply summaries change. Cancelling the
    /// consumer also drops its Rust listener.
    func updates() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard isCurrent else {
            continuation.finish()
            return stream
        }
        let handle = service.subscribeToItemsUpdates(listener: RoomThreadListListener(continuation))
        continuation.onTermination = { _ in handle.cancel() }
        return stream
    }

    /// Native root/count/latest data, without a second homeserver request.
    func roots() -> [CompanyThreadRoot]? {
        guard isCurrent else { return nil }
        return Array(service.items().prefix(CompanyThreads.roomMaximum)).map {
            LiveMatrixSession.threadRoot($0, ownUserID: room.ownUserId())
        }
    }

    /// Atum list rows with attention and unread highlights. Use on list open
    /// and refresh. Summary consumers can use `roots()` on each SDK update.
    func threads() async -> [CompanyThread]? {
        guard isCurrent else { return nil }
        let own = room.ownUserId()
        let activity: [CompanyActivityItem]
        if let data = try? await session.companyNotificationsJSON() {
            activity = CompanyActivityFeed.parse(notificationsJSON: data, ownUserID: own, roomIDs: [roomID]) ?? []
        } else {
            activity = []
        }
        let attention = await session.companyThreadAttention(roomID: roomID)
        guard let roots = roots() else { return nil }
        return CompanyThreads.project(roomID: roomID, roots: roots.map { ($0.root, $0.latest, $0.replyCount) },
                                      attention: attention, activity: activity)
    }

    private var isCurrent: Bool {
        !Task.isCancelled && isEligible() && room.membership() == .joined
            && (try? session.runtime.requireCurrent()) != nil
    }
}

private final class RoomThreadListListener: ThreadListEntriesListener {
    private let continuation: AsyncStream<Void>.Continuation

    init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }

    func onUpdate(diff: [ThreadListUpdate]) { continuation.yield(()) }
}

extension LiveMatrixSession {
    /// The room's threads, newest first, from one page of the server's thread
    /// list. Nil when the room is not on this session or the server refused.
    func companyThreadRoots(roomID: String, ownUserID: String) async -> [CompanyThreadRoot]? {
        guard (try? runtime.requireCurrent()) != nil, let room = try? room(id: roomID) else { return nil }
        let service = room.threadListService()
        do {
            try await service.paginate()
        } catch {
            return nil
        }
        guard (try? runtime.requireCurrent()) != nil else { return nil }
        return service.items().map { Self.threadRoot($0, ownUserID: ownUserID) }
    }

    /// The person's follow choices in a room (`io.atum.thread_attention.v1`):
    /// the local store, or the record this phone wrote last while sync
    /// hasn't caught up with it yet.
    func companyThreadAttention(roomID: String) async -> CompanyThreadAttention {
        let synced = await companySyncedThreadAttention(roomID: roomID)
        guard let key = companyThreadAttentionKey(roomID: roomID) else { return synced }
        return await CompanyThreadAttentionWrites.shared.effective(key, synced: synced)
    }

    private func companySyncedThreadAttention(roomID: String) async -> CompanyThreadAttention {
        guard let room = try? room(id: roomID),
              let json = try? await room.accountDataRaw(eventType: CompanyThreadAttention.accountDataType)
        else { return CompanyThreadAttention() }
        return CompanyThreadAttention.parse(json)
    }

    private func companyThreadAttentionKey(roomID: String) -> String? {
        guard let userID = try? runtime.client.userId() else { return nil }
        return userID + "\u{0}" + roomID
    }

    /// Follow or unfollow one thread: the desktop's record, rewritten whole
    /// (Matrix room account data is last-write-wins across devices). The pinned
    /// SDK can read room account data but not write it, so this one write is
    /// `PUT /user/{me}/rooms/{room}/account_data/{type}` to the session's own
    /// homeserver with its bearer (HTTPS only, no cookies, no redirects).
    ///
    /// Writes to one room run one at a time, each built on the record the
    /// previous one wrote (kept until sync says the same), so two quick taps
    /// on different threads can't overwrite each other.
    func companySetThreadFollow(roomID: String, rootID: String, followed: Bool,
                                isEligible: @escaping @MainActor @Sendable () -> Bool = { true }) async throws {
        try runtime.requireCurrent()
        guard let key = companyThreadAttentionKey(roomID: roomID) else { throw CompanyThreadsMatrixFailure.invalid }
        try await CompanyThreadAttentionWrites.shared.serialized(key) { @MainActor in
            let current = await self.companyThreadAttention(roomID: roomID)
            guard isEligible() else { throw RoomThreadsFailure.unavailable }
            guard let next = current.setting(rootID, followed: followed) else {
                throw CompanyThreadsMatrixFailure.limit
            }
            try await self.companyPutThreadAttention(next, roomID: roomID)
            await CompanyThreadAttentionWrites.shared.remember(key, next)
        }
    }

    private func companyPutThreadAttention(_ next: CompanyThreadAttention, roomID: String) async throws {
        try runtime.requireCurrent()
        let session = try runtime.client.session()
        let userID = try runtime.client.userId()
        guard var components = URLComponents(string: session.homeserverUrl), components.scheme == "https",
              components.host?.isEmpty == false else { throw CompanyThreadsMatrixFailure.invalid }
        let encoded = components.percentEncodedPath
        let base = encoded.hasSuffix("/") ? String(encoded.dropLast()) : encoded
        components.percentEncodedPath = base + "/_matrix/client/v3/user/" + Self.pathSegment(userID)
            + "/rooms/" + Self.pathSegment(roomID) + "/account_data/"
            + Self.pathSegment(CompanyThreadAttention.accountDataType)
        guard let url = components.url else { throw CompanyThreadsMatrixFailure.invalid }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "PUT"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(next.contentJSON.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let transport = URLSession(configuration: configuration, delegate: CompanyThreadsNoRedirect(),
                                   delegateQueue: nil)
        defer { transport.finishTasksAndInvalidate() }
        let (_, response) = try await transport.data(for: request)
        try runtime.requireCurrent()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CompanyThreadsMatrixFailure.refused }
    }

    /// Marks one thread read (desktop `readMatrixThread`): a private receipt
    /// in the thread on its newest reply, so the server clears the thread's
    /// unread state on every device without telling the room.
    func companyReadThread(roomID: String, rootID: String, latestEventID: String) async throws {
        try runtime.requireCurrent()
        guard CompanyThreadAttention.isRootID(latestEventID), latestEventID != rootID else { return }
        let room = try room(id: roomID)
        try await room.sendSingleReceipt(receiptType: .readPrivate, thread: .thread(threadRootEventId: rootID),
                                         eventId: latestEventID)
    }

    static func threadRoot(_ item: ThreadListItem, ownUserID: String) -> CompanyThreadRoot {
        CompanyThreadRoot(root: threadMessage(item.rootEvent, ownUserID: ownUserID),
                          latest: item.latestEvent.map { threadMessage($0, ownUserID: ownUserID) },
                          replyCount: Int(item.numReplies))
    }

    private static func threadMessage(_ event: ThreadListItemEvent, ownUserID: String) -> CompanyThreadMessage {
        var body = ""
        var mentions = false
        if case let .msgLike(content)? = event.content, case let .message(message) = content.kind {
            body = message.body
            mentions = message.mentions?.userIds.contains(ownUserID) ?? false
        }
        var name: String?
        var avatar: String?
        if case let .ready(displayName, _, avatarUrl, _, _) = event.senderProfile {
            // Never a Matrix ID, localpart or SDK " (@id)" suffix as a name.
            name = MatrixPersonName.name(displayName, userID: event.sender)
            avatar = avatarUrl
        }
        return CompanyThreadMessage(eventID: event.eventId, senderID: event.sender, senderName: name,
                                    senderAvatarURI: avatar, isOwn: event.isOwn || event.sender == ownUserID,
                                    body: body, sentAt: Int64(clamping: event.timestamp),
                                    mentionsViewer: mentions)
    }

    /// One percent-encoded path segment (Matrix IDs carry `!`, `:`, `@`, `$`).
    private static func pathSegment(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

/// Follow writes, one room at a time, and the record each one wrote. Kept
/// until the synced copy matches it, or for `holdFor` at most so another
/// device's later choice still wins.
actor CompanyThreadAttentionWrites {
    static let shared = CompanyThreadAttentionWrites()
    static let holdFor: TimeInterval = 120

    private var written = [String: (record: CompanyThreadAttention, at: Date)]()
    private var tails = [String: Task<Void, Never>]()

    /// The record to build on: the one written last, while sync hasn't caught up.
    func effective(_ key: String, synced: CompanyThreadAttention) -> CompanyThreadAttention {
        guard let entry = written[key] else { return synced }
        if entry.record == synced || Date().timeIntervalSince(entry.at) > Self.holdFor {
            written[key] = nil
            return synced
        }
        return entry.record
    }

    func remember(_ key: String, _ record: CompanyThreadAttention) {
        written[key] = (record, Date())
    }

    /// Runs `body` after every earlier body for `key` has finished.
    func serialized(_ key: String, _ body: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tails[key]
        let task = Task<Void, Error> {
            await previous?.value
            try await body()
        }
        tails[key] = Task { _ = await task.result }
        try await task.value
    }
}

private final class CompanyThreadsNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async
        -> URLRequest? { nil }
}
