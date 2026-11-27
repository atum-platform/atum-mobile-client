/// Applies one filter to each existing room-list section. The caller keeps
/// its row IDs, section order and unfiltered scroll anchor.
public enum ChatRoomListFilter: String, CaseIterable, Sendable {
    case all, unread, favourites

    public struct Row: Sendable {
        public let hasRoom: Bool
        public let badge: Badge.Input
        public let isFavourite: Bool

        public init(hasRoom: Bool, badge: Badge.Input, isFavourite: Bool) {
            self.hasRoom = hasRoom
            self.badge = badge
            self.isFavourite = isFavourite
        }
    }

    public func includes(_ row: Row) -> Bool {
        switch self {
        case .all: true
        case .unread: row.hasRoom && Badge.mark(for: row.badge) != .none
        case .favourites: row.hasRoom && row.isFavourite
        }
    }

    public static func available(in rows: [Row]) -> [Self] {
        allCases.filter { filter in filter == .all || rows.contains(where: filter.includes) }
    }

    public func effective(in available: [Self]) -> Self {
        available.contains(self) ? self : .all
    }
}
