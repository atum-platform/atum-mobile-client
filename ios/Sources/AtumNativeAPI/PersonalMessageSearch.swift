import AtumChat
import Foundation

/// The personal roster's Matrix search. It shares the authenticated company
/// transport. Desktop #158 uses a literal term and one extra page if the
/// first has no eligible hits.
@MainActor
public struct PersonalMessageSearch {
    public struct Room: Sendable {
        public let id: String
        public let name: String?
        public let isEncrypted: Bool?

        public init(id: String, name: String?, isEncrypted: Bool?) {
            self.id = id
            self.name = name
            self.isEncrypted = isEncrypted
        }
    }

    public struct Coverage: Equatable, Sendable {
        public let eligibleRooms: Int
        public let searchedRooms: Int
        public let encryptedRooms: Int
        public let truncated: Bool
    }

    public struct Page: Equatable, Sendable {
        public let results: [GlobalChatSearchHit]
        public let coverage: Coverage
    }

    private static let limit = 30
    private let transport: CompanySearchTransport
    /// The current joined, visible personal roster before text/list filters.
    private let rooms: @MainActor () -> [Room]
    private let ignoredUsers: @MainActor () async throws -> Set<String>
    private let endpoint: @MainActor () throws -> CompanySearchEndpoint

    public init(transport: CompanySearchTransport, rooms: @escaping @MainActor () -> [Room],
                ignoredUsers: @escaping @MainActor () async throws -> Set<String>,
                endpoint: @escaping @MainActor () throws -> CompanySearchEndpoint) {
        self.transport = transport
        self.rooms = rooms
        self.ignoredUsers = ignoredUsers
        self.endpoint = endpoint
    }

    public func search(_ term: String, isCurrent: @MainActor () -> Bool) async throws -> Page {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let initial = rooms()
        guard (2...200).contains(query.unicodeScalars.count),
              initial.contains(where: { $0.isEncrypted == false }) else {
            return page(results: [], current: initial, requested: [], truncated: false)
        }
        try check(isCurrent)
        let ignored = try await ignoredUsers()
        try check(isCurrent)
        let available = rooms()
        let targets = plainRooms(available)
        let requested = Set(targets.keys)
        guard !requested.isEmpty else {
            return page(results: [], current: available, requested: [], truncated: false)
        }
        let filter: [String: Any] = ["rooms": requested.sorted(), "types": ["m.room.message"],
                                     "not_senders": ignored.sorted(), "limit": Self.limit]
        let body = try JSONSerialization.data(withJSONObject: ["search_categories": ["room_events": [
            "search_term": query, "filter": filter, "order_by": "recent",
            "event_context": ["before_limit": 0, "after_limit": 0, "include_profile": false],
        ]]])
        let destination = try endpoint()
        func read(_ token: String?) async throws -> WirePage {
            try check(isCurrent)
            try destination.stillCurrent()
            let data = try await transport.search(body: body, endpoint: destination, nextBatch: token)
            try check(isCurrent)
            try destination.stillCurrent()
            return try JSONDecoder().decode(Response.self, from: data).searchCategories.roomEvents
        }
        var answer = try await read(nil)
        var ignoredNow = try await ignoredUsers()
        try check(isCurrent)
        try destination.stillCurrent()
        var current = rooms()
        var eligible = plainRooms(current).filter { requested.contains($0.key) }
        var hits = hits(in: answer, query: query, eligible: eligible, ignored: ignoredNow)
        if hits.isEmpty, let next = answer.nextBatch, !next.isEmpty,
           Set(eligible.keys) == requested, ignoredNow == ignored {
            answer = try await read(next)
            ignoredNow = try await ignoredUsers()
            try check(isCurrent)
            try destination.stillCurrent()
            current = rooms()
            eligible = plainRooms(current).filter { requested.contains($0.key) }
            hits = self.hits(in: answer, query: query, eligible: eligible, ignored: ignoredNow)
        }
        return page(results: Array(hits.prefix(Self.limit)), current: current, requested: requested,
                    truncated: answer.nextBatch?.isEmpty == false || hits.count > Self.limit)
    }

    /// Recheck current room scope when presenting a stored page.
    public func retained(_ hits: [GlobalChatSearchHit]) -> [GlobalChatSearchHit] {
        let eligible = plainRooms(rooms())
        return hits.filter { eligible[$0.id.roomID] != nil }
    }

    private func check(_ isCurrent: @MainActor () -> Bool) throws {
        guard !Task.isCancelled, isCurrent() else { throw CancellationError() }
    }

    private func plainRooms(_ rooms: [Room]) -> [String: Room] {
        Dictionary(rooms.lazy.filter { $0.isEncrypted == false }.map { ($0.id, $0) },
                   uniquingKeysWith: { first, _ in first })
    }

    private func page(results: [GlobalChatSearchHit], current: [Room], requested: Set<String>,
                      truncated: Bool) -> Page {
        let unique = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Page(results: results, coverage: Coverage(
            eligibleRooms: unique.count, searchedRooms: unique.values.count {
                $0.isEncrypted == false && requested.contains($0.id)
            }, encryptedRooms: unique.values.count { $0.isEncrypted == true }, truncated: truncated))
    }

    private func hits(in page: WirePage, query: String, eligible: [String: Room],
                      ignored: Set<String>) -> [GlobalChatSearchHit] {
        var seen = Set<ChatSearchEventTarget>()
        return (page.results ?? []).compactMap { entry in
            let event = entry.result
            guard let room = eligible[event.roomID], event.type == "m.room.message",
                  event.unsigned?.redactedBecause == nil,
                  CompanyMessageSearch.isEventID(event.eventID), CompanyMessageSearch.isUserID(event.sender),
                  !ignored.contains(event.sender), (0...8_640_000_000_000_000).contains(event.timestamp),
                  let content = event.content, content.msgtype == "m.text",
                  content.relation?.type != "m.replace", let body = content.body, body.utf16.count <= 65_536
            else { return nil }
            let threadRoot = content.relation?.type == "m.thread" ? content.relation?.eventID : nil
            if let threadRoot, !CompanyMessageSearch.isEventID(threadRoot) || threadRoot == event.eventID {
                return nil
            }
            if content.relation?.type == "m.thread", threadRoot == nil { return nil }
            let words = ChatSearchText.markdownWords(body)
            guard ChatSearchText.matches(words, query: query) else { return nil }
            let target = ChatSearchEventTarget(roomID: event.roomID, eventID: event.eventID,
                                               threadRootID: threadRoot)
            guard seen.insert(target).inserted else { return nil }
            return GlobalChatSearchHit(target: target, roomName: room.name, senderID: event.sender,
                                       snippet: CompanyMessageSearch.snippet(words, query: query),
                                       timestamp: event.timestamp)
        }
    }
}

private struct Response: Decodable {
    struct Categories: Decodable {
        let roomEvents: WirePage
        enum CodingKeys: String, CodingKey { case roomEvents = "room_events" }
    }

    let searchCategories: Categories
    enum CodingKeys: String, CodingKey { case searchCategories = "search_categories" }
}

private struct WirePage: Decodable {
    struct Entry: Decodable { let result: Event }

    struct Event: Decodable {
        struct Content: Decodable {
            struct Relation: Decodable {
                let type, eventID: String?
                enum CodingKeys: String, CodingKey { case type = "rel_type", eventID = "event_id" }
            }

            let msgtype, body: String?
            let relation: Relation?
            enum CodingKeys: String, CodingKey { case msgtype, body, relation = "m.relates_to" }
        }

        struct Unsigned: Decodable {
            struct Redaction: Decodable {}
            let redactedBecause: Redaction?
            enum CodingKeys: String, CodingKey { case redactedBecause = "redacted_because" }
        }

        let type, roomID, eventID, sender: String
        let timestamp: Int64
        let content: Content?
        let unsigned: Unsigned?
        enum CodingKeys: String, CodingKey {
            case type, sender, content, unsigned
            case roomID = "room_id", eventID = "event_id", timestamp = "origin_server_ts"
        }
    }

    let results: [Entry]?
    let nextBatch: String?
    enum CodingKeys: String, CodingKey { case results, nextBatch = "next_batch" }
}
