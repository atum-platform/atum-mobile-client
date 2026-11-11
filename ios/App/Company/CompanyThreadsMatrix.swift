import AtumChat
import AtumNativeAPI
import Foundation
import MatrixRustSDK

// TS-6b: the Matrix calls behind Team Space threads. The thread list is the
// SDK's `ThreadListService` (the homeserver's `/threads`, one page per room),
// the follow preference is the desktop's own room account data, and reading a
// thread is a private threaded receipt, as `threads.ts` does on the desktop.

/// One server thread of a room, before the policy projects it.
struct CompanyThreadRoot: Sendable {
    let root: CompanyThreadMessage
    let latest: CompanyThreadMessage?
    let replyCount: Int
}

enum CompanyThreadsMatrixFailure: Error { case invalid, refused, limit }

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
        return service.items().map { item in
            CompanyThreadRoot(root: Self.threadMessage(item.rootEvent, ownUserID: ownUserID),
                              latest: item.latestEvent.map { Self.threadMessage($0, ownUserID: ownUserID) },
                              replyCount: Int(item.numReplies))
        }
    }

    /// The person's follow choices in a room (`io.atum.thread_attention.v1`), from the local store.
    func companyThreadAttention(roomID: String) async -> CompanyThreadAttention {
        guard let room = try? room(id: roomID),
              let json = try? await room.accountDataRaw(eventType: CompanyThreadAttention.accountDataType)
        else { return CompanyThreadAttention() }
        return CompanyThreadAttention.parse(json)
    }

    /// Follow or unfollow one thread: the desktop's record, rewritten whole
    /// (Matrix room account data is last-write-wins across devices). The pinned
    /// SDK can read room account data but not write it, so this one write is
    /// `PUT /user/{me}/rooms/{room}/account_data/{type}` to the session's own
    /// homeserver with its bearer (HTTPS only, no cookies, no redirects).
    func companySetThreadFollow(roomID: String, rootID: String, followed: Bool) async throws {
        try runtime.requireCurrent()
        let current = await companyThreadAttention(roomID: roomID)
        guard let next = current.setting(rootID, followed: followed) else { throw CompanyThreadsMatrixFailure.limit }
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

private final class CompanyThreadsNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async
        -> URLRequest? { nil }
}
