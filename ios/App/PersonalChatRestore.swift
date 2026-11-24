import AtumNativeAPI
import CryptoKit
import Foundation

/// A device-local pointer, scoped to an exact Matrix account. The value is
/// the canonical room ID from the joined room list, including for app rows.
struct LastPersonalChatStore {
    private let key: String
    private let defaults: UserDefaults

    init(matrixUserID: String, defaults: UserDefaults = .standard) {
        let digest = SHA256.hash(data: Data(matrixUserID.utf8))
        key = "atum.live.lastPersonalChat.v1." + digest.map { String(format: "%02x", $0) }.joined()
        self.defaults = defaults
    }

    func roomID() -> String? {
        defaults.string(forKey: key).flatMap { try? MatrixRoomID($0).rawValue }
    }

    func remember(_ roomID: String) {
        guard let room = try? MatrixRoomID(roomID), self.roomID() != room.rawValue else { return }
        defaults.set(room.rawValue, forKey: key)
    }

    func forget(_ roomID: String) {
        if self.roomID() == roomID { defaults.removeObject(forKey: key) }
    }
}

struct PersonalChatRestoreSession {
    private var installationID: UUID?
    private var signOutStarted = false
    private(set) var exitedRoomIDs = Set<String>()

    mutating func begin(installationID: UUID) {
        guard self.installationID != installationID else { return }
        self.installationID = installationID
        signOutStarted = false
        exitedRoomIDs.removeAll()
    }

    mutating func beginSignOut() { signOutStarted = true }

    func canRestore(installationID: UUID, signOutInProgress: Bool) -> Bool {
        self.installationID == installationID && !signOutInProgress && !signOutStarted
    }

    mutating func beginExit(_ roomID: String, store: LastPersonalChatStore) {
        store.forget(roomID)
        exitedRoomIDs.insert(roomID)
    }

    mutating func reconcileJoinedRooms(_ roomIDs: Set<String>) {
        exitedRoomIDs.formIntersection(roomIDs)
    }
}

enum PersonalChatRestoreEntry {
    case launch
    case chatsTap
}

enum PersonalChatCompanyClaim: Equatable {
    static let eventType = "io.atum.company_private_cos"
    case checking, absent, claimed, unavailable

    static func read(status: Int?, body: Data) -> Self {
        struct MatrixError: Decodable { let errcode: String }
        if status == 200 { return .claimed }
        if status == 404, (try? JSONDecoder().decode(MatrixError.self, from: body))?.errcode == "M_NOT_FOUND" {
            return .absent
        }
        return .unavailable
    }
}

enum PersonalChatRestoreDecision: Equatable {
    case checkCompanyClaim(String)
    case open(LiveProductRoom)
}

enum PersonalChatRestorePolicy {
    private static let assistantRoomType = "io.atum.assistant"
    private static let companyChannelType = "io.atum.company_channel.v1"

    /// Check the Matrix room as well as the platform's agent identities. A
    /// former assistant's marked room can project as an ordinary people row.
    static func mayRemember(_ room: LiveMatrixRoomRow, classification: CompanyRoomClassification,
                            agents: [AgentsResponse.Agent]) -> Bool {
        guard classification == .personal || classification == .unknown else { return false }
        guard room.hasCreateState,
              !ConversationRoomType.isClaimed(room.roomType),
              !MobileRoomTypePolicy.isHiddenFromChats(room.roomType),
              room.roomType != companyChannelType,
              room.legacyAppBotMove == nil else { return false }

        if room.roomType == assistantRoomType {
            return agents.contains { $0.canOpenChat && isDirectChat(room, with: $0) }
        }
        // An older untyped DM can also be recognized when /agents still
        // names its inactive Matrix user. Groups with an agent stay personal.
        guard agents.contains(where: { isDirectChat(room, with: $0) }) else { return true }
        return agents.contains { $0.canOpenChat && isDirectChat(room, with: $0) }
    }

    static func decision(
        for entry: PersonalChatRestoreEntry, rememberedRoomID: String?,
        joinedRooms: [LiveMatrixRoomRow], rows: [LiveProductRoom], agents: [AgentsResponse.Agent]?,
        hasExplicitRoute: Bool, isCurrent: Bool, exitedRoomIDs: Set<String>,
        classification: (String) -> CompanyRoomClassification,
        companyClaim: (String) -> PersonalChatCompanyClaim?
    ) -> PersonalChatRestoreDecision? {
        guard isCurrent, !hasExplicitRoute else { return nil }
        let knownAgents = agents ?? []
        var eligibleRooms = [String: LiveMatrixRoomRow]()
        for room in joinedRooms {
            let roomID = room.roomID
            let claim = companyClaim(roomID)
            guard !exitedRoomIDs.contains(roomID), claim != .claimed, claim != .unavailable,
                  classification(roomID) == .personal,
                  // Untyped DMs can be former assistants until the roster identifies their peers.
                  agents != nil || room.roomType != nil || !(room.isDirect || room.memberCount == 2),
                  mayRemember(room, classification: .personal, agents: knownAgents) else { continue }
            eligibleRooms[roomID] = room
        }
        let eligibleRows = rows.filter { $0.canOpen && !$0.isInvitation && eligibleRooms[$0.id] != nil }
        func decide(_ row: LiveProductRoom) -> PersonalChatRestoreDecision? {
            switch companyClaim(row.id) {
            case .none: return .checkCompanyClaim(row.id)
            case .absent: return .open(row)
            case .checking, .claimed, .unavailable: return nil
            }
        }
        if let remembered = eligibleRows.first(where: { $0.id == rememberedRoomID }) {
            return decide(remembered)
        }

        if let primary = knownAgents.first(where: { $0.isDefault && $0.status == .active }) {
            let primaryRow = eligibleRows.first { row in
                guard row.assistant?.id == primary.id.rawValue, let room = eligibleRooms[row.id] else {
                    return false
                }
                return isDirectChat(room, with: primary)
            }
            return primaryRow.flatMap(decide)
        }

        // Only a known agent roster without an active agent permits the
        // explicit Chats tap to pick a different conversation.
        guard entry == .chatsTap, let agents, agents.allSatisfy({ $0.status == .retired }) else {
            return nil
        }
        let first = eligibleRows.min { left, right in
            if left.isPinned != right.isPinned { return left.isPinned }
            if left.isPinned {
                let leftOrder = eligibleRooms[left.id]?.favouriteOrder ?? 2
                let rightOrder = eligibleRooms[right.id]?.favouriteOrder ?? 2
                if leftOrder != rightOrder { return leftOrder < rightOrder }
            } else if left.isLowPriority != right.isLowPriority {
                return !left.isLowPriority
            }
            let leftTime = eligibleRooms[left.id]?.latestTimestamp ?? 0
            let rightTime = eligibleRooms[right.id]?.latestTimestamp ?? 0
            return leftTime == rightTime ? left.id < right.id : leftTime > rightTime
        }
        return first.flatMap(decide)
    }

    private static func isDirectChat(_ room: LiveMatrixRoomRow, with agent: AgentsResponse.Agent) -> Bool {
        guard room.memberCount == 2, let userID = agent.matrixUser?.rawValue else { return false }
        return room.memberUserIDs == [userID]
    }

    /// Desktop uses the optional numeric order of the Matrix m.favourite tag.
    static func favouriteOrder(eventJSON: String?) -> Double? {
        struct Event: Decodable {
            struct Content: Decodable {
                struct Tag: Decodable { let order: Double? }
                let tags: [String: Tag]
            }
            let type: String
            let content: Content
        }
        guard let eventJSON,
              let event = try? JSONDecoder().decode(Event.self, from: Data(eventJSON.utf8)),
              event.type == "m.tag", let order = event.content.tags["m.favourite"]?.order,
              (0...1).contains(order) else { return nil }
        return order
    }
}
