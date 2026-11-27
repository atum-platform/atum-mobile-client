import AtumChat
import AtumNativeAPI
import Foundation
import MatrixRustSDK

// The Matrix reads behind wave 2's Team Space structure: the homeserver's
// notification list (Activity), the account's Saved list, a channel's pinned
// events and its create date, and one event's display summary.

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

enum RoomPinFailure: Error, Equatable {
    case unavailable, forbidden, invalidTarget, invalidState, limit, awaitingSync, failed
}

struct RoomPinSnapshot: Equatable, Sendable {
    let eventIDs: [String]
    let canChange: Bool
    let awaitingSync: Bool
}

/// A room's shared pins. Each mutation applies a single intent to SDK state;
/// it never submits the list rendered by the caller.
@MainActor
final class RoomPins {
    static let maximum = 100

    private enum WritePhase {
        case sending
        case awaitingSync(previousEventID: String?)
    }

    private struct Write {
        weak var session: LiveMatrixSession?
        let phase: WritePhase
    }

    private struct WriteKey: Hashable {
        let session: ObjectIdentifier
        let roomID: String
    }

    private static var writes = [WriteKey: Write]()
    private let roomID: String
    private let session: LiveMatrixSession
    private let room: Room
    private let isEligible: @MainActor () -> Bool

    init(roomID: String, session: LiveMatrixSession, room: Room, isEligible: @escaping @MainActor () -> Bool) {
        self.roomID = roomID
        self.session = session
        self.room = room
        self.isEligible = isEligible
    }

    /// Re-read `snapshot()` after a signal. A power-level change, pin sync
    /// or membership change can change what the current account may do.
    func updates() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard isCurrent else {
            continuation.finish()
            return stream
        }
        let handle = room.subscribeToRoomInfoUpdates(listener: RoomPinUpdateListener(continuation))
        continuation.onTermination = { _ in handle.cancel() }
        return stream
    }

    func snapshot() async throws -> RoomPinSnapshot {
        guard isCurrent else { throw RoomPinFailure.unavailable }
        let canChange = await mayChange()
        let state = try await pinnedState()
        guard isCurrent else { throw RoomPinFailure.unavailable }
        return RoomPinSnapshot(eventIDs: state.ids, canChange: canChange,
                               awaitingSync: writeIsPending(syncedEventID: state.eventID))
    }

    /// Use pinned-events focus to hydrate the current IDs. Keep the state
    /// order and unavailable entries, while omitting SDK-known redactions.
    func entries(for snapshot: RoomPinSnapshot) async throws -> [CompanyPinnedRow] {
        guard isCurrent else { throw RoomPinFailure.unavailable }
        guard !snapshot.eventIDs.isEmpty else { return [] }
        let configuration = TimelineConfiguration(focus: .pinnedEvents, filter: .all, internalIdPrefix: nil,
                                                  dateDividerMode: .daily, trackReadReceipts: .disabled,
                                                  reportUtds: false)
        let timeline = try await room.timelineWithConfiguration(configuration: configuration)
        let (updates, continuation) = AsyncStream<[TimelineItem]>.makeStream()
        let handle = await timeline.addListener(listener: RoomPinnedTimelineSnapshot(continuation))
        defer { handle.cancel() }
        let encryption = await SDKTimelineSource.encryption(of: room)
        var iterator = updates.makeAsyncIterator()
        guard let items = await iterator.next(), isCurrent else {
            throw RoomPinFailure.unavailable
        }
        var shown = [String: CompanyPinnedRow]()
        var redacted = Set<String>()
        for item in items {
            guard let event = item.asEvent(), case let .eventId(eventID) = event.eventOrTransactionId,
                  case let .msgLike(content) = event.content else { continue }
            if case .redacted = content.kind { redacted.insert(eventID) }
            guard case let .message(message) = content.kind else { continue }
            // Respect the app's existing plaintext-in-encrypted-room rule.
            let clear: Bool
            if encryption != false, case .red(code: .sentInClear) = event.lazyProvider.getShields(strict: false) {
                clear = true
            } else {
                clear = false
            }
            guard MobilePlaintextEventPolicy.shows(roomEncrypted: encryption, sentInClear: clear) else { continue }
            let name = MatrixPersonName.name(ChatItem.senderName(event.senderProfile), userID: event.sender)
            let summary = CompanyEventSummary(senderID: event.sender, senderName: name, body: message.body,
                                              sentAt: Int64(clamping: event.timestamp), threadRootID: content.threadRoot)
            shown[eventID] = CompanyPinnedRow(eventID: eventID, summary: summary, isOwn: event.isOwn)
        }
        return snapshot.eventIDs.filter { !redacted.contains($0) }.map {
            shown[$0] ?? CompanyPinnedRow(eventID: $0, summary: nil, isOwn: false)
        }
    }

    /// An authorized no-op succeeds. A second tap before the first edit
    /// reaches sync is recoverable, so it cannot write a stale whole list.
    func setPinned(_ pinned: Bool, eventID: String) async throws {
        guard isCurrent else { throw RoomPinFailure.unavailable }
        guard MessageMenuRules.isPinEventID(eventID) else { throw RoomPinFailure.invalidTarget }
        guard await mayChange() else { throw RoomPinFailure.forbidden }
        let event: TimelineEvent
        do {
            event = try await room.loadOrFetchEvent(eventId: eventID)
        } catch ClientError.MatrixApi(kind: .notFound, code: _, msg: _, details: _) {
            throw RoomPinFailure.invalidTarget
        } catch {
            throw isCurrent ? RoomPinFailure.failed : .unavailable
        }
        guard event.eventId() == eventID, case .messageLike(.roomMessage)? = try? event.content() else {
            throw RoomPinFailure.invalidTarget
        }
        guard let timeline = try? await room.timeline() else {
            throw isCurrent ? RoomPinFailure.failed : .unavailable
        }
        let canChange = await mayChange()
        let state = try await pinnedState()
        guard let info = try? await room.roomInfo(), isCurrent else { throw RoomPinFailure.unavailable }
        guard canChange else { throw RoomPinFailure.forbidden }
        // Native mutation reads RoomInfo. A sync can publish cached state
        // and room info across our awaits, so retry once they agree.
        guard info.pinnedEventIds == state.ids else { throw RoomPinFailure.awaitingSync }
        guard !writeIsPending(syncedEventID: state.eventID) else { throw RoomPinFailure.awaitingSync }
        guard state.ids.contains(eventID) != pinned else { return }
        guard !pinned || state.ids.count < Self.maximum else { throw RoomPinFailure.limit }

        Self.writes = Self.writes.filter { $0.value.session != nil }
        Self.writes[writeKey] = Write(session: session, phase: .sending)
        var sent = false
        defer {
            Self.writes[writeKey] = sent
                ? Write(session: session, phase: .awaitingSync(previousEventID: state.eventID))
                : nil
        }
        do {
            sent = if pinned {
                try await timeline.pinEvent(eventId: eventID)
            } else {
                try await timeline.unpinEvent(eventId: eventID)
            }
        } catch ClientError.MatrixApi(kind: .forbidden, code: _, msg: _, details: _) {
            throw RoomPinFailure.forbidden
        } catch {
            guard isCurrent else { throw RoomPinFailure.unavailable }
            throw RoomPinFailure.failed
        }
        guard isCurrent else { throw RoomPinFailure.unavailable }
    }

    private var writeKey: WriteKey { WriteKey(session: ObjectIdentifier(session), roomID: roomID) }

    private var isCurrent: Bool {
        !Task.isCancelled && isEligible() && room.membership() == .joined
            && (try? session.runtime.requireCurrent()) != nil
    }

    private func mayChange() async -> Bool {
        guard isCurrent, let levels = try? await room.getPowerLevels() else { return false }
        return isCurrent && (try? levels.canUserSendState(userId: room.ownUserId(), stateEvent: .roomPinnedEvents)) == true
    }

    private func pinnedState() async throws -> (ids: [String], eventID: String?) {
        guard let events = try? await room.stateEvents(eventType: .roomPinnedEvents) else {
            throw RoomPinFailure.unavailable
        }
        guard let event = events.first(where: { $0.stateKey.isEmpty }) else { return ([], nil) }
        guard let content = (try? JSONSerialization.jsonObject(with: Data(event.contentJson.utf8))) as? [String: Any]
        else { throw RoomPinFailure.invalidState }
        guard let value = content["pinned"] else { return ([], event.eventId) }
        guard let ids = value as? [String], ids.count <= Self.maximum,
              Set(ids).count == ids.count, ids.allSatisfy(MessageMenuRules.isPinEventID) else {
            throw RoomPinFailure.invalidState
        }
        return (ids, event.eventId)
    }

    private func writeIsPending(syncedEventID: String?) -> Bool {
        guard let entry = Self.writes[writeKey], entry.session === session else { return false }
        switch entry.phase {
        case .sending: return true
        case let .awaitingSync(previousEventID):
            guard syncedEventID != previousEventID else { return true }
            Self.writes[writeKey] = nil
            return false
        }
    }
}

private final class RoomPinUpdateListener: RoomInfoListener {
    private let continuation: AsyncStream<Void>.Continuation

    init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }

    func call(roomInfo: RoomInfo) { continuation.yield(()) }
}

private final class RoomPinnedTimelineSnapshot: TimelineListener {
    private let continuation: AsyncStream<[TimelineItem]>.Continuation

    init(_ continuation: AsyncStream<[TimelineItem]>.Continuation) { self.continuation = continuation }

    func onUpdate(diff: [TimelineDiff]) {
        guard case let .reset(items)? = diff.first else { return }
        continuation.yield(items)
        continuation.finish()
    }
}

extension LiveAppModel {
    func openRoomPins(roomID: String) -> RoomPins? {
        guard sharedChatActions(roomID: roomID).offersPins, let session = liveMatrix,
              let room = try? session.room(id: roomID), room.membership() == .joined else { return nil }
        return RoomPins(roomID: roomID, session: session, room: room) { [weak self, weak session] in
            guard let self, let session else { return false }
            return self.liveMatrix === session && self.sharedChatActions(roomID: roomID).offersPins
        }
    }
}

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

    /// Where Home search's `POST /_matrix/client/v3/search` goes: the
    /// session's own homeserver (HTTPS only) with its bearer. The pinned SDK
    /// has no `/search` binding, so this mirrors the notifications read.
    func companySearchEndpoint() throws -> CompanySearchEndpoint {
        try runtime.requireCurrent()
        let session = try runtime.client.session()
        guard var components = URLComponents(string: session.homeserverUrl), components.scheme == "https",
              components.host?.isEmpty == false else { throw CompanySpaceMatrixFailure.invalid }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path)
            + "/_matrix/client/v3/search"
        guard let url = components.url else { throw CompanySpaceMatrixFailure.invalid }
        let runtime = runtime
        return CompanySearchEndpoint(url: url, bearer: session.accessToken,
                                     stillCurrent: { try runtime.requireCurrent() })
    }

    /// `from:@name`'s matches among one room's members, every membership
    /// (desktop `room.getMembers()`), read from the SDK store in bounded chunks
    /// with no cap on how many are read (`CompanySearchMemberReader`). The
    /// no-sync iterator yields every membership; nothing is filtered here.
    func companySearchSenders(roomID: String, from: String) async -> [String] {
        guard let room = try? room(id: roomID), let iterator = try? await room.membersNoSync() else { return [] }
        return CompanySearchMemberReader.senders(from: from) {
            iterator.nextChunk(chunkSize: CompanySearchMemberReader.chunkSize)?.map {
                CompanySearchMember(userID: $0.userId, names: [$0.displayName].compactMap { $0 },
                                    membership: String(describing: $0.membership))
            }
        }
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

/// Home search's one transport: a single ephemeral URL session (no cookies,
/// no cache, redirects refused) for every request; the bearer travels per
/// request and the session is checked again when the answer lands.
@MainActor
final class LiveCompanySearchTransport: CompanySearchTransport {
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: CompanySpaceNoRedirect(), delegateQueue: nil)
    }()

    func search(body: Data, endpoint: CompanySearchEndpoint, nextBatch: String?) async throws -> Data {
        var url = endpoint.url
        if let nextBatch {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw CompanySpaceMatrixFailure.refused
            }
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "next_batch", value: nextBatch)]
            // Matrix tokens are opaque. Keep '+' from becoming a form-encoded space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let pageURL = components.url else { throw CompanySpaceMatrixFailure.refused }
            url = pageURL
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer " + endpoint.bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try endpoint.stillCurrent()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CompanySpaceMatrixFailure.refused }
        return data
    }
}

private final class CompanySpaceNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async
        -> URLRequest? { nil }
}
