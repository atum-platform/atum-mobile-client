import AtumChat
import AtumNativeAPI
import Foundation
import MatrixRustSDK

// The Matrix reads behind wave 2's Team Space structure: the homeserver's
// notification list (Activity), the account's Saved list, a channel's pinned
// events and its create date, and one event's display summary. Each is a read;
// nothing here writes Matrix state.

/// One message, as a Saved, Pinned or Activity row shows it.
struct CompanyEventSummary: Equatable, Sendable {
    let senderID: String
    let senderName: String?
    let body: String
    /// Milliseconds since 1970.
    let sentAt: Int64
    let threadRootID: String?
}

enum CompanySpaceMatrixFailure: Error { case invalid, refused }

extension LiveMatrixSession {
    /// `GET /_matrix/client/v3/notifications`: the homeserver's own list of what
    /// notified this account, newest first. The pinned SDK has no binding for
    /// it, so this one read goes to the session's own homeserver with the
    /// session's bearer (HTTPS only, no cookies, no redirects followed), as the
    /// notes room's create does.
    func companyNotificationsJSON(limit: Int = CompanyActivityFeed.maximum) async throws -> Data {
        try runtime.requireCurrent()
        let session = try runtime.client.session()
        guard var components = URLComponents(string: session.homeserverUrl), components.scheme == "https",
              components.host?.isEmpty == false else { throw CompanySpaceMatrixFailure.invalid }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path)
            + "/_matrix/client/v3/notifications"
        components.queryItems = [URLQueryItem(name: "limit", value: String(max(1, min(limit, 200))))]
        guard let url = components.url else { throw CompanySpaceMatrixFailure.invalid }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let transport = URLSession(configuration: configuration, delegate: CompanySpaceNoRedirect(),
                                   delegateQueue: nil)
        defer { transport.finishTasksAndInvalidate() }
        let (data, response) = try await transport.data(for: request)
        try runtime.requireCurrent()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CompanySpaceMatrixFailure.refused }
        return data
    }

    /// `POST /_matrix/client/v3/search`: Home search's Messages and Files
    /// (desktop `searchCompanyMessages`, server side). The pinned SDK has no
    /// binding for it, so it goes the same way as the notifications read:
    /// the session's own homeserver, its bearer, HTTPS only, no cookies, no
    /// redirects followed. The body names only rooms the company directory
    /// lists (`CompanyMessageSearch.requestBody`).
    func companySearchJSON(body: Data) async throws -> Data {
        try runtime.requireCurrent()
        let session = try runtime.client.session()
        guard var components = URLComponents(string: session.homeserverUrl), components.scheme == "https",
              components.host?.isEmpty == false else { throw CompanySpaceMatrixFailure.invalid }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path)
            + "/_matrix/client/v3/search"
        guard let url = components.url else { throw CompanySpaceMatrixFailure.invalid }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await Self.companySearchTransport.data(for: request)
        try runtime.requireCurrent()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CompanySpaceMatrixFailure.refused }
        return data
    }

    /// One ephemeral session for every Home search request: no cookies, no
    /// cache, redirects refused. The bearer travels per request.
    private static let companySearchTransport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: CompanySpaceNoRedirect(), delegateQueue: nil)
    }()

    /// A room's members as `from:@name` matches them, every membership
    /// (desktop `room.getMembers()`): someone who left still wrote their old
    /// messages. Read from the SDK's store; no sync is started.
    func companySearchMembers(roomID: String) async -> [CompanySearchMember] {
        guard let room = try? room(id: roomID),
              let iterator = try? await room.membersNoSync() else { return [] }
        var members = [CompanySearchMember]()
        let maximum = min(Int(iterator.len()), 10_000)
        while members.count < maximum,
              let chunk = iterator.nextChunk(chunkSize: UInt32(min(100, maximum - members.count))),
              !chunk.isEmpty {
            for member in chunk {
                members.append(CompanySearchMember(
                    userID: member.userId, names: [member.displayName].compactMap { $0 },
                    membership: String(describing: member.membership)))
            }
        }
        return members
    }

    /// This account's Matrix user ID.
    func companyOwnUserID() throws -> String {
        try runtime.requireCurrent()
        return try runtime.client.userId()
    }

    /// A room's pinned events (`m.room.pinned_events`), from the SDK's room info.
    func companyPinnedEventIDs(roomID: String) async -> [String]? {
        guard let room = try? room(id: roomID), let info = try? await room.roomInfo() else { return nil }
        return info.pinnedEventIds
    }

    /// One event's sender, name and text, from the store or the homeserver.
    /// Nil when it is gone, hidden from this account, or not a message.
    func companyEventSummary(roomID: String, eventID: String) async -> CompanyEventSummary? {
        guard let room = try? room(id: roomID),
              let event = try? await room.loadOrFetchEvent(eventId: eventID),
              case let .messageLike(content)? = try? event.content(),
              case let .roomMessage(messageType, _) = content else { return nil }
        let body: String
        switch messageType {
        case let .text(value): body = value.body
        case let .emote(value): body = value.body
        case let .notice(value): body = value.body
        case let .image(value): body = value.caption ?? value.filename
        case let .video(value): body = value.caption ?? value.filename
        case let .audio(value): body = value.caption ?? value.filename
        case let .file(value): body = value.caption ?? value.filename
        case let .gallery(value): body = value.body
        case let .location(value): body = value.description ?? value.body
        case let .other(_, value): body = value
        }
        let sender = event.senderId()
        // Never a Matrix ID, localpart or SDK " (@id)" suffix as a name.
        let name = MatrixPersonName.name((try? await room.memberDisplayName(userId: sender)) ?? nil,
                                         userID: sender)
        return CompanyEventSummary(senderID: sender, senderName: name,
                                   body: body, sentAt: Int64(clamping: event.timestamp()),
                                   threadRootID: event.threadRootEventId())
    }

    /// A sender's room display name, for Activity rows.
    func companyMemberName(roomID: String, userID: String) async -> String? {
        guard let room = try? room(id: roomID) else { return nil }
        return MatrixPersonName.name((try? await room.memberDisplayName(userId: userID)) ?? nil,
                                     userID: userID)
    }
}

private final class CompanySpaceNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async
        -> URLRequest? { nil }
}
