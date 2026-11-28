import Foundation

// ML3 S1/S2 Home presentation values (mockup M1, desktop #158
// `roster-message-results.tsx`). Pure: Home turns these into rows and copy.

/// One room's search hits, as one card under the room's face and name.
public struct ChatSearchResultGroup<Hit>: Identifiable {
    public let roomID: String
    /// Newest first.
    public let hits: [Hit]
    public var id: String { roomID }

    public init(roomID: String, hits: [Hit]) {
        self.roomID = roomID
        self.hits = hits
    }
}

extension ChatSearchResultGroup: Equatable where Hit: Equatable {}
extension ChatSearchResultGroup: Sendable where Hit: Sendable {}

public enum ChatSearchResultGrouping {
    /// Hits grouped by room. Each room's hits are newest first and rooms are
    /// ordered by their newest hit. Equal timestamps keep their arrival order,
    /// so a stable page never reshuffles. The same event appears only once.
    public static func groups<Hit>(_ hits: [Hit], roomID: (Hit) -> String, eventID: (Hit) -> String,
                                   timestamp: (Hit) -> Int64) -> [ChatSearchResultGroup<Hit>] {
        var seen = Set<String>()
        let ordered = hits.enumerated()
            .filter { seen.insert(roomID($0.element) + "\u{0}" + eventID($0.element)).inserted }
            .sorted { left, right in
                let l = timestamp(left.element), r = timestamp(right.element)
                return l == r ? left.offset < right.offset : l > r
            }
            .map(\.element)
        var order = [String]()
        var byRoom = [String: [Hit]]()
        for hit in ordered {
            let room = roomID(hit)
            if byRoom[room] == nil { order.append(room) }
            byRoom[room, default: []].append(hit)
        }
        return order.map { ChatSearchResultGroup(roomID: $0, hits: byRoom[$0] ?? []) }
    }

    public static func groups(_ hits: [GlobalChatSearchHit]) -> [ChatSearchResultGroup<GlobalChatSearchHit>] {
        groups(hits, roomID: \.id.roomID, eventID: \.id.eventID, timestamp: \.timestamp)
    }
}

/// Where the query is marked in a result's snippet. The snippet is never
/// searched again to choose what opens: opening uses the hit's event ID.
public enum ChatSearchSnippetMarks {
    public static func ranges(in snippet: String, query: String) -> [Range<String.Index>] {
        guard let needle = ChatSearchText.needle(query) else { return [] }
        let offsets = ChatSearchText.occurrences(of: needle, in: snippet)
        guard !offsets.isEmpty else { return [] }
        let indices = Array(snippet.indices) + [snippet.endIndex]
        return offsets.compactMap { range in
            guard range.lowerBound >= 0, range.upperBound < indices.count, range.lowerBound < range.upperBound
            else { return nil }
            return indices[range.lowerBound]..<indices[range.upperBound]
        }
    }
}

/// The single quiet coverage line under the results (M1 decision 4). It
/// reports what was searched, never more than the sources measured.
public enum ChatSearchCoverageLine: Equatable, Sendable {
    /// Plain scope. `searched` counts rooms that went into a request.
    /// `privateSkipped` counts known-encrypted personal rooms left out.
    case plain(searched: Int, privateSkipped: Int, partial: Bool)
    /// Device scope. `privateChats` counts eligible encrypted rooms on this
    /// device. `earliestMatch` is the oldest returned match only: the SDK does
    /// not report how far back its index reaches, so history may be incomplete.
    case device(privateChats: Int, earliestMatch: Int64?, partial: Bool)
    /// The device index cannot answer (no custody, old history unavailable or
    /// an SDK failure). Different from a successful empty search.
    case deviceUnavailable
    /// A plain source failed; what did answer still shows.
    case plainFailed(searched: Int)

    /// Plain coverage from the measured personal provider and the company
    /// rooms dispatched (the company provider does not yet return measured
    /// counts, so that part is the eligible-at-dispatch room count).
    public static func plain(personalSearched: Int?, personalEncrypted: Int, personalTruncated: Bool,
                             companyRooms: Int, failed: Bool) -> ChatSearchCoverageLine {
        let searched = max(0, personalSearched ?? 0) + max(0, companyRooms)
        if failed { return .plainFailed(searched: searched) }
        return .plain(searched: searched, privateSkipped: max(0, personalEncrypted), partial: personalTruncated)
    }
}

// MARK: S16 room-list filter session

/// One section of Home's roster (assistants, chats), in its existing order.
public struct ChatRoomListSection<Row>: Identifiable {
    public let id: String
    public let rows: [Row]

    public init(id: String, rows: [Row]) {
        self.id = id
        self.rows = rows
    }
}

extension ChatRoomListSection: Equatable where Row: Equatable {}
extension ChatRoomListSection: Sendable where Row: Sendable {}

/// The reversible All / Unread / Favourites choice. Availability is computed
/// on the unfiltered roster; a stale choice reads as All. Leaving All records
/// the row at the top of the unfiltered list so returning to All restores it.
public struct ChatRoomListFilterSession: Equatable, Sendable {
    public enum Scroll: Equatable, Sendable {
        case none
        case top
        case restore(rowID: String)
    }

    public private(set) var selection: ChatRoomListFilter = .all
    /// The unfiltered list's top visible row when the filter left All.
    public private(set) var allAnchor: String?

    public init() {}

    public func effective(in available: [ChatRoomListFilter]) -> ChatRoomListFilter {
        selection.effective(in: available)
    }

    /// `visibleAnchor` is the first row on screen right now, in list order.
    public mutating func select(_ requested: ChatRoomListFilter, available: [ChatRoomListFilter],
                                visibleAnchor: String?) -> Scroll {
        let current = selection.effective(in: available)
        let next = requested.effective(in: available)
        guard next != current else {
            selection = next
            return .none
        }
        if current == .all { allAnchor = visibleAnchor }
        selection = next
        guard next == .all else { return .top }
        let anchor = allAnchor
        allAnchor = nil
        return anchor.map { .restore(rowID: $0) } ?? .top
    }

    /// Each section filtered in place: section IDs and order and row order
    /// stay. Empty sections remain in the result so callers keep their IDs.
    public func sections<Row>(_ sections: [ChatRoomListSection<Row>], available: [ChatRoomListFilter],
                              row: (Row) -> ChatRoomListFilter.Row) -> [ChatRoomListSection<Row>] {
        let filter = effective(in: available)
        guard filter != .all else { return sections }
        return sections.map { section in
            ChatRoomListSection(id: section.id, rows: section.rows.filter { filter.includes(row($0)) })
        }
    }
}
