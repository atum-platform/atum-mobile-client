import Foundation

/// Pure Home-list ordering and pin-limit rules (S2 §3.2.1). SDK and view
/// adapters translate their state into these plain values before projecting.
public enum RosterProjection {
    public static let pinLimit = 5

    public struct Input: Sendable {
        public var assistants: [Assistant]
        public var rooms: [Room]
        public var apps: [App]
        /// The platform-provided Founder room. `nil` means it is ordinary.
        public var founderRoomID: String?

        public init(assistants: [Assistant], rooms: [Room], apps: [App], founderRoomID: String? = nil) {
            self.assistants = assistants
            self.rooms = rooms
            self.apps = apps
            self.founderRoomID = founderRoomID
        }
    }

    public struct Assistant: Equatable, Sendable {
        public var id: String
        public var conversationRoomID: String?
        public var isPrimary: Bool
        /// Original `/agents` order, lower first.
        public var agentOrder: Int

        public init(id: String, conversationRoomID: String?, isPrimary: Bool = false, agentOrder: Int) {
            self.id = id
            self.conversationRoomID = conversationRoomID
            self.isPrimary = isPrimary
            self.agentOrder = agentOrder
        }
    }

    public struct App: Equatable, Sendable {
        public var id: String
        /// Catalog `rosterOrder`, lower first.
        public var rosterOrder: Int
        /// The exact room selected by `MobileAppBotRoomPolicy`; nil means the
        /// phone has no safe app destination. RosterProjection never chooses
        /// among raw bot-room candidates itself.
        public var conversationRoomID: String?
        /// A presentation-only catalog entry such as "coming soon". It is
        /// listed by its own `app:<id>` row ID, has no conversation room and
        /// grants no destination or action.
        public var isPresentationOnly: Bool
        /// The app has a chat (one the person deleted still counts, as on
        /// desktop). False for a catalog app with no chat yet: its row follows
        /// every chat, in catalog order, as desktop's
        /// `apps.filter(entry => !entry.room)` does.
        public var hasChat: Bool

        public init(id: String, rosterOrder: Int, conversationRoomID: String? = nil,
                    isPresentationOnly: Bool = false, hasChat: Bool = true) {
            self.id = id
            self.rosterOrder = rosterOrder
            self.conversationRoomID = conversationRoomID
            self.isPresentationOnly = isPresentationOnly
            self.hasChat = hasChat
        }
    }

    public struct Room: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case assistant(agentID: String)
            case person
            case group
            case app(appID: String)
        }

        public enum Membership: Equatable, Sendable { case joined, invited }

        public var id: String
        public var kind: Kind
        public var membership: Membership
        public var latestEventAt: Date?
        public var isFavourite: Bool
        /// A lower order wins; `nil` is the order desktop writes for a new pin.
        public var tagOrder: Int?
        /// A locally hidden bot room is represented by its catalog app row.
        public var isHiddenOnThisDevice: Bool
        /// Old encrypted assistant/bot rooms are never a viable conversation.
        public var isLegacyEncrypted: Bool
        /// The standard `m.lowpriority` tag: the chat sinks below every other ordinary chat, by
        /// recency among themselves (desktop `room-navigation.ts` `sortConversations`).
        public var isLowPriority: Bool

        public init(id: String, kind: Kind, membership: Membership = .joined,
                    latestEventAt: Date? = nil, isFavourite: Bool = false, tagOrder: Int? = nil,
                    isHiddenOnThisDevice: Bool = false, isLegacyEncrypted: Bool = false,
                    isLowPriority: Bool = false) {
            self.isLowPriority = isLowPriority
            self.id = id
            self.kind = kind
            self.membership = membership
            self.latestEventAt = latestEventAt
            self.isFavourite = isFavourite
            self.tagOrder = tagOrder
            self.isHiddenOnThisDevice = isHiddenOnThisDevice
            self.isLegacyEncrypted = isLegacyEncrypted
        }
    }

    public struct Row: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case assistant(agentID: String)
            case person
            case group
            case invitation
            case app(appID: String, reopensHiddenRoom: Bool)
        }

        public var id: String
        public var roomID: String
        public var kind: Kind

        public init(id: String, roomID: String, kind: Kind) {
            self.id = id
            self.roomID = roomID
            self.kind = kind
        }
    }

    public struct Output: Equatable, Sendable {
        public var assistants: [Row]
        public var chats: [Row]

        public init(assistants: [Row], chats: [Row]) {
            self.assistants = assistants
            self.chats = chats
        }
    }

    public static func project(_ input: Input) -> Output {
        // Retain the first report for a room ID. A duplicate SDK update must
        // never create a duplicate navigation destination.
        var roomsByID: [String: Room] = [:]
        for room in input.rooms where !room.id.isEmpty && roomsByID[room.id] == nil {
            roomsByID[room.id] = room
        }

        var usedRoomIDs = Set<String>()
        let assistantRows = assistantRows(input.assistants, roomsByID: roomsByID, used: &usedRoomIDs)
        let chatRows = chatRows(input, roomsByID: roomsByID, excluding: usedRoomIDs)
        return Output(assistants: assistantRows, chats: chatRows)
    }

    /// S2's five joined-room ceiling. The requested room is eligible only
    /// when it is a joined, non-hidden room and fewer than five distinct
    /// joined favourites exist.
    public static func canPin(roomID: String, rooms: [Room]) -> Bool {
        guard let target = uniqueRooms(rooms)[roomID], target.membership == .joined,
              !target.isHiddenOnThisDevice, !target.isFavourite else { return false }
        return joinedFavouriteCount(rooms) < pinLimit
    }

    /// Desktop's limit is every distinct joined `m.favourite`. A phone-local
    /// hidden app room still owns its server pin and therefore still consumes
    /// the shared five-room budget until it is unpinned.
    public static func joinedFavouriteCount(_ rooms: [Room]) -> Int {
        uniqueRooms(rooms).values.filter { $0.membership == .joined && $0.isFavourite }.count
    }

    private static func uniqueRooms(_ rooms: [Room]) -> [String: Room] {
        var result: [String: Room] = [:]
        for room in rooms where !room.id.isEmpty && result[room.id] == nil { result[room.id] = room }
        return result
    }

    private static func assistantRows(_ assistants: [Assistant], roomsByID: [String: Room],
                                      used: inout Set<String>) -> [Row] {
        // An agent ID may occur twice while `/agents` refreshes; stable first
        // occurrence wins just as it does for duplicate room IDs.
        var seenAgents = Set<String>()
        let candidates = assistants.filter { !$0.id.isEmpty && seenAgents.insert($0.id).inserted }.compactMap { assistant -> (Assistant, Room)? in
            guard let roomID = assistant.conversationRoomID, let room = roomsByID[roomID],
                  room.membership == .joined, !room.isHiddenOnThisDevice,
                  !room.isLegacyEncrypted, room.kind == .assistant(agentID: assistant.id) else { return nil }
            return (assistant, room)
        }
        // Desktop `projectMatrixRoster`: the default assistant, then `/agents`
        // order. A pin never moves an assistant (`roster-model.ts:196-246`).
        let primary = candidates.filter { $0.0.isPrimary }.sorted { $0.0.agentOrder < $1.0.agentOrder }
        let remaining = candidates.filter { !$0.0.isPrimary }
            .sorted { $0.0.agentOrder < $1.0.agentOrder }
        return (primary + remaining).compactMap { assistant, room in
            guard used.insert(room.id).inserted else { return nil }
            return Row(id: room.id, roomID: room.id, kind: .assistant(agentID: assistant.id))
        }
    }

    private static func chatRows(_ input: Input, roomsByID: [String: Room], excluding used: Set<String>) -> [Row] {
        let catalog = deduplicatedApps(input.apps)
        let catalogIDs = Set(catalog.map(\.id))
        let candidates = roomsByID.values.filter { room in
            guard !used.contains(room.id), !room.isHiddenOnThisDevice else { return false }
            switch room.kind {
            case .assistant: return false
            case .person, .group: return true
            case let .app(appID): return catalogIDs.contains(appID) && !room.isLegacyEncrypted && room.membership == .joined
            }
        }

        let founder = input.founderRoomID.flatMap { id in candidates.first { $0.id == id } }
        let pinned = candidates.filter { $0.id != founder?.id && $0.isFavourite && $0.membership == .joined }
            .sorted { pinOrder($0, $1, fallbackLeft: 0, fallbackRight: 0) }
        let pinnedIDs = Set(pinned.map(\.id))

        // Desktop `roster-conversations.tsx:948-955`: one `sortConversations`
        // over the ordinary rooms and each app's chat together, so Moon or
        // Andy with a fresh message sits among the recent chats. Then the
        // apps without a chat, then the coming-soon placeholders, each in
        // catalog order.
        var appChats = [(room: Room, row: Row)]()
        var appsWithoutChat = [Row]()
        var placeholders = [Row]()
        for app in catalog {
            if app.isPresentationOnly {
                // A coming-soon app has no conversation. It still owns one
                // inert row, mapped back by its `app:<id>` presentation ID.
                let rowID = "app:" + app.id
                guard let room = roomsByID[rowID], room.kind == .app(appID: app.id),
                      room.membership == .joined, !room.isLegacyEncrypted,
                      !pinnedIDs.contains(rowID), rowID != founder?.id else { continue }
                placeholders.append(Row(id: rowID, roomID: rowID,
                                        kind: .app(appID: app.id, reopensHiddenRoom: false)))
                continue
            }
            // Agent/bot invitations are accepted by the session before roster
            // projection; unlike person invitations they never become rows.
            guard let roomID = app.conversationRoomID, let room = roomsByID[roomID],
                  room.kind == .app(appID: app.id), room.membership == .joined,
                  !room.isLegacyEncrypted else { continue }
            guard !pinnedIDs.contains(room.id), room.id != founder?.id else { continue }
            let row = Row(id: room.id, roomID: room.id,
                          kind: .app(appID: app.id, reopensHiddenRoom: room.isHiddenOnThisDevice))
            // A chat deleted on this phone still dates its row, as desktop's
            // `appBot.hidden` room does; only an app with no chat at all waits
            // after the chats.
            if app.hasChat {
                appChats.append((room, row))
            } else {
                appsWithoutChat.append(row)
            }
        }
        func row(_ room: Room) -> Row {
            switch room.kind {
            case .person: return Row(id: room.id, roomID: room.id, kind: room.membership == .invited ? .invitation : .person)
            case .group: return Row(id: room.id, roomID: room.id, kind: room.membership == .invited ? .invitation : .group)
            case let .app(appID): return Row(id: room.id, roomID: room.id, kind: .app(appID: appID, reopensHiddenRoom: false))
            case .assistant: preconditionFailure("assistant rooms do not reach chatRows")
            }
        }
        let ordinary = candidates.filter { room in
            room.id != founder?.id && !(room.isFavourite && room.membership == .joined) && !isApp(room)
        }.map { (room: $0, row: row($0)) }
        let conversations = (ordinary + appChats).sorted { ordinaryOrder($0.room, $1.room) }.map(\.row)
        return ([founder].compactMap { $0 } + pinned).map(row) + conversations + appsWithoutChat + placeholders
    }

    private static func deduplicatedApps(_ apps: [App]) -> [App] {
        var seen = Set<String>()
        return apps.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            .sorted { $0.rosterOrder == $1.rosterOrder ? $0.id < $1.id : $0.rosterOrder < $1.rosterOrder }
    }

    private static func isApp(_ room: Room) -> Bool {
        if case .app = room.kind { return true }
        return false
    }

    private static func pinOrder(_ lhs: Room, _ rhs: Room, fallbackLeft: Int, fallbackRight: Int) -> Bool {
        switch (lhs.tagOrder, rhs.tagOrder) {
        case let (left?, right?) where left != right: return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default:
            if lhs.latestEventAt != rhs.latestEventAt { return (lhs.latestEventAt ?? .distantPast) > (rhs.latestEventAt ?? .distantPast) }
            return fallbackLeft < fallbackRight
        }
    }

    /// Whether a chat offers Low priority: an ordinary person or group chat in the chat list, where
    /// the tag orders it. The Founder chat, a pinned chat and assistant, app or invited rooms are
    /// ordered by their own place, so they don't offer it (desktop `lowPriorityEligible`).
    public static func offersLowPriority(roomID: String, rooms: [Room], founderRoomID: String?) -> Bool {
        guard roomID != founderRoomID, let room = uniqueRooms(rooms)[roomID],
              room.membership == .joined, !room.isFavourite, !room.isHiddenOnThisDevice else { return false }
        switch room.kind {
        case .person, .group: return true
        case .assistant, .app: return false
        }
    }

    private static func ordinaryOrder(_ lhs: Room, _ rhs: Room) -> Bool {
        if lhs.isLowPriority != rhs.isLowPriority { return rhs.isLowPriority }
        return recencyOrder(lhs, rhs)
    }

    private static func recencyOrder(_ lhs: Room, _ rhs: Room) -> Bool {
        let left = lhs.latestEventAt ?? .distantPast
        let right = rhs.latestEventAt ?? .distantPast
        return left == right ? lhs.id < rhs.id : left > right
    }
}
