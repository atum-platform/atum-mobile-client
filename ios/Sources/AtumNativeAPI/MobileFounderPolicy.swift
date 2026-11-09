import Foundation

/// The two `io.atum.founder_chat` records from the canonical desktop contract
/// (`apps/desktop/shared/matrix-founder.ts`): the person's account-data record
/// `{v:1, founder, room, at}` and the room's own state marker
/// `{v:1, founder}`. Only the platform-named `user_id` may become a Founder
/// chat; a name, handle, avatar, room name or look-alike proves nothing.
public enum MobileFounderPolicy {
    public static let markerEventType = "io.atum.founder_chat"

    private static let matrixUser = "\\A@[^:\\s]+:\\S+\\z"
    private static let matrixRoom = "\\A!\\S+\\z"

    /// The synchronized account-data record: unknown until the session has
    /// completed its initial sync, absent only on a successful no-event read,
    /// and present for any record this build can or cannot read. An unreadable
    /// present record keeps `founder` and `roomID` nil and still blocks every
    /// automatic creation.
    public enum ChatMarker: Equatable, Sendable {
        case unknown
        case absent
        case present(founder: String?, roomID: String?)

        public var hasRecord: Bool {
            if case .present = self { return true }
            return false
        }

        public var readableFounder: String? {
            guard case let .present(founder, _) = self else { return nil }
            return founder
        }

        public var readableRoomID: String? {
            guard case let .present(_, roomID) = self else { return nil }
            return roomID
        }
    }

    public struct ChatRecord: Equatable, Sendable {
        public let founder: String
        public let roomID: String
        public let atMilliseconds: Int64

        public init(founder: String, roomID: String, atMilliseconds: Int64) {
            self.founder = founder
            self.roomID = roomID
            self.atMilliseconds = atMilliseconds
        }
    }

    public enum WaitReason: String, Equatable, Sendable {
        case notReady = "not_ready"
        case notSynced = "not_synced"
        case unknownMarker = "unknown_marker"
        case unknownRoom = "unknown_room"
    }

    /// The recorded room can be known-good, known-bad, or unreadable because
    /// the SDK cache has not supplied its room/membership facts yet. Unknown
    /// must never be treated as permission to replace a chat.
    public enum RoomUsability: Equatable, Sendable {
        case usable
        case unusable
        case unknown
    }
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
    /// and never opens one: the person's first message makes the chat.
    public static let draftRowID = "founder-draft"

    /// Whether this account has sent a message in a room this call created.
    /// Only a proved `absent` authorizes destructive race-loser cleanup.
    public enum OwnMessageState: Equatable, Sendable {
        case absent
        case present
        case unknown
    }
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
    /// clicking a handle never invites). It only binds a chat that already exists; with no
    /// record it offers the roster's local draft and creates nothing. Only the person's own
    /// first message (or Contact us) may make the chat.
    public enum AutoAction: Equatable, Sendable {
        case unavailable
        case founderMode
        case wait(WaitReason)
        case bindExisting(roomID: String)
        case decline
        case suppressed
        case draft
    }

    /// Contact us is the person's explicit request. It opens a usable existing
    /// Founder chat, or replaces a record whose chat was left or is otherwise
    /// unusable. It never creates for no Founder, the Founder's own account,
    /// an unready session or an unknown marker.
    public enum ExplicitAction: Equatable, Sendable {
        case unavailable
        case founderMode
        case wait(WaitReason)
        case bindExisting(roomID: String)
        case createReplacement
    }

    /// Settings' Contact us. While the roster offers the local Founder draft (no chat exists),
    /// Message opens that draft and makes nothing; only its first message makes the room. A
    /// known record takes the explicit path (its chat, or a replacement for one that was left).
    public enum ContactAction: Equatable, Sendable {
        case openDraft
        case contactFounder
    }

    public struct RoomCandidate: Equatable, Sendable {
        public let roomID: String
        public let creatorUserID: String?
        public let markerSenderUserID: String?
        public let markerFounderUserID: String?
        public let isJoined: Bool
        public let membershipKnown: Bool
        public let memberCount: UInt64
        public let memberUserIDs: [String]
        public let createdAtMilliseconds: Int64?

        public init(roomID: String, creatorUserID: String?, markerSenderUserID: String?,
                    markerFounderUserID: String?, isJoined: Bool, memberCount: UInt64,
                    memberUserIDs: [String], createdAtMilliseconds: Int64?,
                    membershipKnown: Bool = true) {
            self.roomID = roomID
            self.creatorUserID = creatorUserID
            self.markerSenderUserID = markerSenderUserID
            self.markerFounderUserID = markerFounderUserID
            self.isJoined = isJoined
            self.membershipKnown = membershipKnown
            self.memberCount = memberCount
            self.memberUserIDs = memberUserIDs
            self.createdAtMilliseconds = createdAtMilliseconds
        }
    }

    public static func marker(accountDataJSON: String?) -> ChatMarker {
        guard let accountDataJSON else { return .absent }
        guard let record = record(JSON: accountDataJSON) else {
            return .present(founder: nil, roomID: nil)
        }
        return .present(founder: record.founder, roomID: record.roomID)
    }

    /// Reads only the canonical v1 record; extra fields are additive and
    /// ignored. Anything else is nil, which still counts as a record.
    public static func record(JSON: String?) -> ChatRecord? {
        guard let JSON,
              let data = JSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any],
              let version = integer(object["v"]), version == 1,
              let founder = object["founder"] as? String, isMatrixUserID(founder),
              let roomID = object["room"] as? String, isMatrixRoomID(roomID),
              let at = integer(object["at"]), at >= 0,
              at <= 9_007_199_254_740_991 else {
            return nil
        }
        return ChatRecord(founder: founder, roomID: roomID, atMilliseconds: at)
    }

    public static func roomMark(JSON: String?) -> String? {
        guard let JSON,
              let data = JSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any],
              let version = integer(object["v"]), version == 1,
              let founder = object["founder"] as? String, isMatrixUserID(founder) else {
            return nil
        }
        return founder
    }

    public static func roomMarkJSON(founder: String) -> String? {
        guard isMatrixUserID(founder) else { return nil }
        return encoded(["v": 1, "founder": founder])
    }

    public static func accountRecordJSON(founder: String, roomID: String,
                                         atMilliseconds: Int64) -> String? {
        guard isMatrixUserID(founder), isMatrixRoomID(roomID), atMilliseconds >= 0 else {
            return nil
        }
        return encoded(["v": 1, "founder": founder, "room": roomID, "at": atMilliseconds])
    }

    public static func autoAction(founder: String?,
                                  roster: OfficialFounderRoster?,
                                  marker: ChatMarker,
                                  ownUserID: String,
                                  sessionReady: Bool,
                                  completedInitialSync: Bool,
                                  existingRoomUsability: RoomUsability) -> AutoAction {
        guard let founder else { return .unavailable }
        if founder == ownUserID { return .founderMode }
        if !sessionReady { return .wait(.notReady) }
        if !completedInitialSync { return .wait(.notSynced) }

        switch marker {
        case .unknown:
            return .wait(.unknownMarker)
        case let .present(markedFounder, roomID):
            guard markedFounder == founder, let roomID else {
                return .decline
            }
            switch existingRoomUsability {
            case .usable: return .bindExisting(roomID: roomID)
            case .unusable: return .decline
            case .unknown: return .wait(.unknownRoom)
            }
        case .absent:
            let effective = roster ?? OfficialFounderRoster(defaultVisible: true, order: 0,
                                                            state: .available)
            guard effective.defaultVisible, effective.state != .comingSoon else {
                return .suppressed
            }
            return .draft
        }
    }

    public static func explicitAction(founder: String?,
                                      marker: ChatMarker,
                                      ownUserID: String,
                                      sessionReady: Bool,
                                      completedInitialSync: Bool,
                                      existingRoomUsability: RoomUsability) -> ExplicitAction {
        guard let founder else { return .unavailable }
        if founder == ownUserID { return .founderMode }
        if !sessionReady { return .wait(.notReady) }
        if !completedInitialSync { return .wait(.notSynced) }

        switch marker {
        case .unknown:
            return .wait(.unknownMarker)
        case let .present(markedFounder, roomID):
            guard markedFounder == founder, let roomID else {
                return .createReplacement
            }
            switch existingRoomUsability {
            case .usable: return .bindExisting(roomID: roomID)
            case .unusable: return .createReplacement
            case .unknown: return .wait(.unknownRoom)
            }
        case .absent:
            return .createReplacement
        }
    }

    public static func contactAction(founderDraftAvailable: Bool) -> ContactAction {
        founderDraftAvailable ? .openDraft : .contactFounder
    }

    /// The draft's first message goes only into the room that same send opened. A chat opened
    /// in the gap (another row, a notification) is a different room and never receives it.
    public static func draftSendAllowed(roomID: String, conversationRoomID: String?) -> Bool {
        guard let conversationRoomID else { return false }
        return conversationRoomID == roomID
    }

    /// Desktop's usability rule on the SDK cache: this account is joined and
    /// the configured Founder is joined or invited. Extra members do not make
    /// the recorded room unusable. Missing room/member facts are unknown.
    public static func roomUsability(_ candidate: RoomCandidate?,
                                     founder: String) -> RoomUsability {
        guard let candidate else { return .unknown }
        guard candidate.isJoined else { return .unusable }
        guard candidate.membershipKnown else { return .unknown }
        return candidate.memberUserIDs.contains(founder) ? .usable : .unusable
    }

    /// The oldest joined room this account itself created, marked with this
    /// same Founder, containing exactly the owner and that Founder (joined or
    /// invited). A room with a different creator, marker sender, Founder,
    /// member count or an unreadable marker is never adopted.
    public static func adoptableRoomID(_ candidates: [RoomCandidate], founder: String,
                                       ownUserID: String) -> String? {
        let expectedMembers = Set([ownUserID, founder])
        return candidates
            .filter { candidate in
                candidate.isJoined
                    && candidate.creatorUserID == ownUserID
                    && candidate.markerSenderUserID == ownUserID
                    && candidate.markerFounderUserID == founder
                    && candidate.memberCount == 2
                    && Set(candidate.memberUserIDs) == expectedMembers
            }
            .sorted { left, right in
                let leftAt = left.createdAtMilliseconds ?? .max
                let rightAt = right.createdAtMilliseconds ?? .max
                return leftAt == rightAt
                    ? left.roomID < right.roomID
                    : leftAt < rightAt
            }
            .first?.roomID
    }

    /// The record is the race winner when it names another room for this same
    /// Founder. An absent, unknown or unreadable record keeps the room this
    /// device made.
    public static func raceWinner(createdRoomID: String, founder: String,
                                  marker: ChatMarker) -> String {
        guard case let .present(markedFounder, roomID) = marker,
              markedFounder == founder, let roomID else {
            return createdRoomID
        }
        return roomID
    }

    /// The canonical marker decides the winner. `retainedLoserRoomID` is the
    /// only room the establishment flow may clean up: it was created by this
    /// call and lost to another authoritative record. Message-state proof then
    /// decides leave+forget versus phone-local hiding.
    public struct RaceResolution: Equatable, Sendable {
        public let winnerRoomID: String
        /// The created room when the marker chose another room; otherwise nil.
        public let retainedLoserRoomID: String?

        public init(winnerRoomID: String, retainedLoserRoomID: String?) {
            self.winnerRoomID = winnerRoomID
            self.retainedLoserRoomID = retainedLoserRoomID
        }
    }

    public static func raceResolution(createdRoomID: String, founder: String,
                                      marker: ChatMarker) -> RaceResolution {
        let winner = raceWinner(createdRoomID: createdRoomID, founder: founder, marker: marker)
        return RaceResolution(winnerRoomID: winner,
                              retainedLoserRoomID: winner == createdRoomID ? nil : createdRoomID)
    }

    public enum EstablishResult: Equatable, Sendable {
        case ready(roomID: String)
        /// The room exists but its account marker write failed. The caller
        /// keeps and retries this exact room; it must not create another one.
        case unrecorded(roomID: String)
        case wait
        case declined
        case failed
    }

    /// The live app adapts its current Matrix runtime and phone-hidden-room
    /// ledger to this surface. Package tests use a fake port, so creation,
    /// adoption, authoritative ordering and loser cleanup are exercised
    /// without the binary SDK.
    @MainActor
    public protocol FounderRoomPort: AnyObject {
        func serverMarker(anchorRoomID: String?) async -> ChatMarker
        func roomUsability(roomID: String, founder: String) async -> RoomUsability
        func adoptableRoomID(founder: String, ownUserID: String) async -> String?
        func createRoom(founder: String) async throws -> String
        func writeMarker(founder: String, roomID: String) async throws
        func rememberDirect(founder: String, roomID: String) async
        func ownMessageState(roomID: String, ownUserID: String) async -> OwnMessageState
        func leaveAndForget(roomID: String) async -> Bool
        func hide(roomID: String)
    }

    /// Desktop's `ensure` order on plain values, for the person's own request (their first
    /// message or Contact us). Nothing calls this on a platform read.
    ///
    /// 1. read the server marker before any create;
    /// 2. bind/wait (or replace an unusable record) from that authoritative answer;
    /// 3. adopt or create, write the marker, then re-read it;
    /// 4. if this call's created room lost, leave+forget only after proving
    ///    this account sent no message there; otherwise keep it out of the
    ///    roster with the phone's hidden-room ledger.
    @MainActor
    public static func establishRoom(founder: String, ownUserID: String,
                                     port: any FounderRoomPort) async -> EstablishResult {
        let before = await port.serverMarker(anchorRoomID: nil)
        switch before {
        case .unknown:
            return .wait
        case let .present(markedFounder, roomID):
            if markedFounder == founder, let roomID {
                switch await port.roomUsability(roomID: roomID, founder: founder) {
                case .usable:
                    return .ready(roomID: roomID)
                case .unknown:
                    return .wait
                case .unusable:
                    break
                }
            }
        case .absent:
            break
        }

        let adopted = await port.adoptableRoomID(founder: founder, ownUserID: ownUserID)
        let roomID: String
        let created: Bool
        if let adopted {
            roomID = adopted
            created = false
        } else {
            do {
                roomID = try await port.createRoom(founder: founder)
                created = true
            } catch {
                return .failed
            }
        }

        do {
            try await port.writeMarker(founder: founder, roomID: roomID)
        } catch {
            return .unrecorded(roomID: roomID)
        }
        await port.rememberDirect(founder: founder, roomID: roomID)

        let after = await port.serverMarker(anchorRoomID: roomID)
        let resolution = raceResolution(createdRoomID: roomID, founder: founder,
                                        marker: after)
        if created, let loser = resolution.retainedLoserRoomID {
            let ownMessage = await port.ownMessageState(roomID: loser,
                                                        ownUserID: ownUserID)
            let removed = ownMessage == .absent
                ? await port.leaveAndForget(roomID: loser)
                : false
            if !removed {
                port.hide(roomID: loser)
            }
        }
        return .ready(roomID: resolution.winnerRoomID)
    }

    /// One local draft's creation, shared by every send tapped while it runs
    /// (Element's LocalRoom: the first message makes the DM). A rapid double
    /// send therefore makes exactly one room; a failed attempt can be retried.
    @MainActor
    public final class DraftOpen {
        private let create: @MainActor () async -> String?
        private var roomID: String?
        private var opening: Task<String?, Never>?

        public init(create: @escaping @MainActor () async -> String?) {
            self.create = create
        }

        public func room() async -> String? {
            if let roomID { return roomID }
            if let opening { return await opening.value }
            let attempt = Task { await create() }
            opening = attempt
            let created = await attempt.value
            if let created { roomID = created }
            opening = nil
            return created
        }

        /// The account or Founder changed: nothing made for the old one may be reused.
        public func reset() {
            roomID = nil
            opening = nil
        }
    }

    /// Only the exact Founder row may keep the platform account's image. A
    /// copied name or copied Matrix avatar remains an initials-only ordinary
    /// person, with no effect on trust or room selection.
    public static func presentedAvatarURL(roomAvatarURL: String?, roomName: String,
                                          founderName: String?, founderAvatarURL: String?,
                                          isFounder: Bool) -> String? {
        guard !isFounder else { return founderAvatarURL }
        let copiedName = founderName.map { roomName == $0 } == true
        let copiedAvatar = founderAvatarURL != nil && roomAvatarURL == founderAvatarURL
        return copiedName || copiedAvatar ? nil : roomAvatarURL
    }

    private static func isMatrixUserID(_ value: String) -> Bool {
        value.utf8.count <= 255
            && value.range(of: matrixUser, options: .regularExpression) != nil
    }

    private static func isMatrixRoomID(_ value: String) -> Bool {
        value.utf8.count >= 2 && value.utf8.count <= 255
            && value.range(of: matrixRoom, options: .regularExpression) != nil
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c",
              String(cString: number.objCType) != "B" else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double,
              double >= Double(Int64.min), double <= Double(Int64.max) else { return nil }
        return number.int64Value
    }

    private static func encoded(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
