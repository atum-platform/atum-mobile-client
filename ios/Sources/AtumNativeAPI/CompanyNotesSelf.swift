import Foundation

/// A company's "You" row: the person's own notes room for that company, the
/// same Matrix room the desktop opens (atum-app `shared/matrix-notes-self.ts`,
/// `src/matrix/notes-self.ts`). It is Matrix-only, with no platform authority:
///
/// - the room's immutable `m.room.create` content carries
///   `type: "com.atum.notes.self"` and
///   `"com.atum.notes_self.company_id": <company UUID>`;
/// - the owner created it (the create event's sender) and is its only member;
/// - one account-data event per company, `com.atum.notes_self.<company UUID>`,
///   points at it as `{"version": 1, "room_id": …}`.
///
/// The create content is the authority; the pointer is only a hint the desktop
/// repairs. Of several matching rooms the earliest created wins (then the
/// lowest room ID), exactly as the desktop picks, so both devices open the same
/// room and neither makes a second one while the first is visible.
public enum CompanyNotesSelf {
    public static let roomType = "com.atum.notes.self"
    public static let accountDataPrefix = "com.atum.notes_self"
    public static let tag = "u.atum.notes_self"
    /// The immutable create-content key that makes a notes room one company's.
    public static let companyKey = "com.atum.notes_self.company_id"

    private static let maximumJSONBytes = 16 * 1_024

    /// The desktop's company ID rule: a lower-case UUID.
    public static func isCompanyID(_ value: String) -> Bool {
        value.range(of: #"^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$"#, options: .regularExpression) != nil
    }

    public static func isRoomID(_ value: String) -> Bool {
        value.range(of: #"^![!-9;-~]{1,255}:[!-~]{1,255}$"#, options: .regularExpression) != nil
    }

    /// One event per company, so two devices never clobber each other's map.
    public static func accountDataType(companyID: String) -> String {
        accountDataPrefix + "." + companyID
    }

    // MARK: Pointer

    public enum PointerRead: Equatable, Sendable {
        case absent
        case known(roomID: String)
        /// Unknown or newer data: readable by no one here and never overwritten.
        case readonly
    }

    /// Exactly `{"version": 1, "room_id": "!…"}`; anything else is read-only.
    public static func readPointer(json: String?) -> PointerRead {
        guard let json, !json.isEmpty, json != "null" else { return .absent }
        guard let data = json.data(using: .utf8), data.count <= maximumJSONBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 2,
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.intValue == 1, version.doubleValue == 1,
              let roomID = object["room_id"] as? String, isRoomID(roomID)
        else { return .readonly }
        return .known(roomID: roomID)
    }

    public static func pointerJSON(roomID: String) -> String? {
        guard isRoomID(roomID),
              let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "room_id": roomID],
                                                     options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Create content

    /// The company a room's create content assigns it to, when it is a notes
    /// room for a company. A personal (unscoped) notes room, another room type,
    /// or a malformed company ID is nil.
    public static func companyID(createContentJSON: String?) -> String? {
        guard let createContentJSON, let data = createContentJSON.data(using: .utf8),
              data.count <= maximumJSONBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == roomType,
              let company = object[companyKey] as? String, isCompanyID(company)
        else { return nil }
        return company
    }

    /// The desktop's `createRoom` body for a company's notes room: private,
    /// unencrypted by preset default, nobody invited, history visible only to
    /// joined members, guests forbidden.
    public static func createRoomBody(companyID: String) -> Data? {
        guard isCompanyID(companyID) else { return nil }
        let body: [String: Any] = [
            "preset": "private_chat",
            "creation_content": ["type": roomType, companyKey: companyID],
            "initial_state": [
                ["type": "m.room.history_visibility", "state_key": "",
                 "content": ["history_visibility": "joined"]],
                ["type": "m.room.guest_access", "state_key": "",
                 "content": ["guest_access": "forbidden"]],
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// `room_id` from a `createRoom` answer.
    public static func createdRoomID(responseJSON data: Data) -> String? {
        guard data.count <= maximumJSONBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roomID = object["room_id"] as? String, isRoomID(roomID) else { return nil }
        return roomID
    }

    // MARK: Inspection

    /// One room the client knows whose create type is the notes type.
    public struct Candidate: Equatable, Sendable {
        public let roomID: String
        public let createContentJSON: String?
        public let creatorUserID: String?
        public let createdAtMilliseconds: Int64?
        public let isJoined: Bool
        /// Joined plus invited members, the owner included.
        public let activeMemberCount: UInt64
        /// Joined or invited members other than the owner.
        public let otherMemberUserIDs: [String]

        public init(roomID: String, createContentJSON: String?, creatorUserID: String?,
                    createdAtMilliseconds: Int64?, isJoined: Bool, activeMemberCount: UInt64,
                    otherMemberUserIDs: [String]) {
            self.roomID = roomID
            self.createContentJSON = createContentJSON
            self.creatorUserID = creatorUserID
            self.createdAtMilliseconds = createdAtMilliseconds
            self.isJoined = isJoined
            self.activeMemberCount = activeMemberCount
            self.otherMemberUserIDs = otherMemberUserIDs
        }
    }

    public struct Inspection: Equatable, Sendable {
        /// The room both devices open.
        public let winner: String?
        /// Owner-created company notes rooms whose audience is no longer the owner alone.
        public let quarantined: [String]
    }

    /// The desktop's `inspectMatrixNotesSelfRooms` for one company: joined,
    /// the notes type with this company's ID, created by the owner; a changed
    /// audience quarantines it; of the rest the earliest wins.
    public static func inspect(_ candidates: [Candidate], ownerUserID: String,
                               companyID: String) -> Inspection {
        var eligible = [Candidate]()
        var quarantined = [String]()
        for candidate in candidates where candidate.isJoined {
            guard self.companyID(createContentJSON: candidate.createContentJSON) == companyID,
                  candidate.creatorUserID == ownerUserID else { continue }
            if candidate.activeMemberCount != 1 || !candidate.otherMemberUserIDs.isEmpty {
                quarantined.append(candidate.roomID)
                continue
            }
            eligible.append(candidate)
        }
        eligible.sort { left, right in
            let l = left.createdAtMilliseconds ?? .max
            let r = right.createdAtMilliseconds ?? .max
            return l != r ? l < r : left.roomID < right.roomID
        }
        return Inspection(winner: eligible.first?.roomID, quarantined: quarantined.sorted())
    }

    // MARK: Opening

    /// What tapping "You" may do.
    public enum OpenDecision: Equatable, Sendable {
        case open(roomID: String)
        /// The pointer names a room this device has not synced yet: wait, never create.
        case wait
        /// Nothing anywhere: this device may make the room.
        case create
        /// Unknown pointer data, or the sync is not complete: neither open nor create.
        case refuse
    }

    /// A local winner opens. Otherwise only a completed sync and a server-read
    /// absent pointer allow a create; a known pointer to a room not seen here
    /// means another device made it, so this one waits.
    public static func openDecision(inspection: Inspection, pointer: PointerRead,
                                    initialSyncComplete: Bool) -> OpenDecision {
        if let winner = inspection.winner { return .open(roomID: winner) }
        guard initialSyncComplete else { return .refuse }
        switch pointer {
        case .absent: return .create
        // A changed audience disqualifies that room, not the owner's notes (desktop `ensure`).
        case let .known(roomID): return inspection.quarantined.contains(roomID) ? .create : .wait
        case .readonly: return .refuse
        }
    }
}
