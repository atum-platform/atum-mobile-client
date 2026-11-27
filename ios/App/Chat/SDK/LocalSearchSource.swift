import AtumChat
import AtumNativeAPI
import CryptoKit
import Foundation
import MatrixRustSDK

/// Owns the pinned SDK's on-device search for one live session. The SDK
/// resolves hits from the event cache or by event ID. The query goes to
/// the local index, and this adapter never forwards it to a remote source.
@MainActor
final class LocalSearchSource {
    struct Page: Equatable, Sendable {
        let results: [GlobalChatSearchHit]
        let eligibleRooms: Int
        /// Lower bounds measured from admitted index matches. The FFI does
        /// not expose index-wide coverage or a per-room history watermark.
        let roomsWithMatches: Int
        let oldestMatchTimestamp: Int64?
        let truncated: Bool
    }

    private let session: LiveMatrixSession
    /// Current visible chats, including authorized company rooms. Omit
    /// locally deleted rooms and private assistant work rooms.
    private let roomIDs: @MainActor () -> Set<String>
    private var backfill: TaskHandle?
    private var redactions: [TaskHandle] = []

    init(session: LiveMatrixSession, roomIDs: @escaping @MainActor () -> Set<String>) {
        self.session = session
        self.roomIDs = roomIDs
    }

    deinit {
        backfill?.cancel()
        redactions.forEach { $0.cancel() }
    }

    /// Call once on entering the device-only scope while foregrounded,
    /// independently of typing. SDK backfill covers joined rooms and fetches
    /// history, with its own pacing and time bounds.
    func startBackfill() {
        guard backfill == nil, !eligibleRooms().isEmpty else { return }
        backfill = session.runtime.client.runSearchBackfill(strategy: .foreground)
    }

    func stopBackfill() {
        backfill?.cancel()
        backfill = nil
    }

    /// Watch the rooms of the currently displayed hits. A sync redaction
    /// makes those rows stale even if no roster preview changes. The caller
    /// drops the affected page and refreshes within the same input token.
    func observeRedactions(for hits: [GlobalChatSearchHit],
                           onChange: @escaping @MainActor @Sendable () -> Void) {
        stopObservingRedactions()
        let event = messageLikeEventTypeFromString(s: "m.room.redaction")
        let rooms = eligibleRooms()
        for id in Set(hits.map(\.id.roomID)) {
            guard let room = rooms[id] else { continue }
            redactions.append(room.subscribeToMessageLikeEvents(
                eventType: event, listener: SearchRedactionListener(onChange: onChange)))
        }
    }

    func stopObservingRedactions() {
        redactions.forEach { $0.cancel() }
        redactions.removeAll()
    }

    func search(_ term: String, isCurrent: @MainActor () -> Bool) async throws -> Page {
        try check(isCurrent)
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let initial = eligibleRooms()
        guard !initial.isEmpty, (2...200).contains(query.unicodeScalars.count) else {
            return Page(results: [], eligibleRooms: initial.count, roomsWithMatches: 0,
                        oldestMatchTimestamp: nil, truncated: false)
        }

        // A dedicated handle per query prevents callbacks or pages from a
        // cancelled query from being attributed to the next one.
        let service = session.runtime.client.searchService()
        try await service.setQuery(query: query)
        let limit = 30
        let maximumPages = 3
        for page in 1...maximumPages {
            try check(isCurrent)
            let snapshot = await Self.snapshot(of: service)
            let ignored = try await session.searchIgnoredUsers()
            try check(isCurrent)
            let rooms = eligibleRooms()
            let hits = Self.admitted(snapshot, rooms: rooms.mapValues { MatrixPersonName.readableRoomName($0.displayName()) },
                                     ignored: ignored, query: query)
            let finished = service.paginationState() == .idle(endReached: true)
            if rooms.isEmpty || hits.count >= limit || finished || page == maximumPages {
                let results = Array(hits.prefix(limit))
                return Page(results: results, eligibleRooms: rooms.count,
                            roomsWithMatches: Set(results.map(\.id.roomID)).count,
                            oldestMatchTimestamp: results.map(\.timestamp).min(),
                            truncated: !rooms.isEmpty && (!finished || hits.count > limit))
            }
            try await service.paginate()
        }
        // The final iteration returns regardless of the SDK pagination state.
        throw CancellationError()
    }

    func retained(_ hits: [GlobalChatSearchHit]) -> [GlobalChatSearchHit] {
        let eligible = eligibleRooms()
        return hits.filter { eligible[$0.id.roomID] != nil }
    }

    private func eligibleRooms() -> [String: Room] {
        guard !session.runtime.oldHistoryUnavailable else { return [:] }
        var rooms = [String: Room]()
        for id in roomIDs() {
            guard let room = session.joinedSearchRoom(id), room.encryptionState() == .encrypted else { continue }
            rooms[id] = room
        }
        return rooms
    }

    private func check(_ isCurrent: @MainActor () -> Bool) throws {
        guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
        try session.runtime.requireCurrent()
    }

    /// The SDK starts each subscription with one coherent reset, including
    /// an empty reset. Subscribe after setQuery/paginate settles, so there is
    /// no dependence on a result diff arriving before a pagination callback.
    static func snapshot(of service: SearchService) async -> [SearchServiceResult] {
        let (stream, continuation) = AsyncStream<[SearchServiceResult]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let handle = await service.subscribeToResults(listener: LocalSearchSnapshot(continuation: continuation))
        defer { handle.cancel() }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? []
    }

    static func admitted(_ snapshot: [SearchServiceResult], rooms: [String: String?],
                         ignored: Set<String>, query: String) -> [GlobalChatSearchHit] {
        var seen = Set<ChatSearchEventTarget>()
        return snapshot.compactMap { value in
            guard case let .message(roomID, result) = value, let roomName = rooms[roomID],
                  !ignored.contains(result.sender),
                  // Redacted and undecryptable events have their own SDK cases.
                  case let .msgLike(content) = result.content, case let .message(message) = content.kind,
                  case .text = message.msgType, message.body.utf16.count <= 65_536 else { return nil }
            let words = ChatSearchText.markdownWords(message.body)
            guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let root = content.threadRoot == result.eventId ? nil : content.threadRoot
            let target = ChatSearchEventTarget(roomID: roomID, eventID: result.eventId, threadRootID: root)
            guard seen.insert(target).inserted else { return nil }
            let senderName: String?
            if case let .ready(name, _, _, _, _) = result.senderProfile {
                senderName = MatrixPersonName.name(name, userID: result.sender)
            } else {
                senderName = nil
            }
            return GlobalChatSearchHit(
                target: target, roomName: roomName, senderID: result.sender, senderName: senderName,
                snippet: CompanyMessageSearch.snippet(words, query: query),
                timestamp: Int64(clamping: result.timestamp))
        }
    }
}

private final class LocalSearchSnapshot: SearchServiceResultsListener {
    private let continuation: AsyncStream<[SearchServiceResult]>.Continuation

    init(continuation: AsyncStream<[SearchServiceResult]>.Continuation) {
        self.continuation = continuation
    }

    func onUpdate(updates: [SearchServiceResultsUpdate]) {
        guard case let .reset(values)? = updates.first else { return }
        continuation.yield(values)
        continuation.finish()
    }
}

private final class SearchRedactionListener: RoomMessageLikeEventsListener {
    private let onChange: @MainActor @Sendable () -> Void

    init(onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange
    }

    func onEvent(event _: RoomMessageLikeEvent) {
        Task { @MainActor in onChange() }
    }
}

enum MatrixLocalSearchStore {
    static func configure(_ builder: ClientBuilder, cacheDirectory: URL,
                          sessionSecret: String) -> ClientBuilder {
        let path = cacheDirectory.appendingPathComponent("search-index-v1", isDirectory: true).path
        // Derive a separate key from the random per-session secret which is
        // already held in the device-only Keychain. Existing sign-out purges
        // the entire generation, including this index, and deletes the secret.
        let key = HMAC<SHA256>.authenticationCode(
            for: Data("atum.mobile.matrix.search-index.v1".utf8),
            using: SymmetricKey(data: Data(sessionSecret.utf8)))
        return builder.withSearchIndexStore(path: path, key: Data(key).base64EncodedString())
            .enableAutomaticBackPagination(enableAutomaticBackPagination: true)
    }
}
