import Foundation

/// The platform's canonical-room arbitration for a catalog app bot:
/// `POST /api/matrix/v1/apps/{slug}/bot/start` (MAS bearer, native clients).
/// The platform names the one room a person has with a bot; a device that has
/// to create one asks again with the room it made, and the loser leaves.
/// Nothing here names an app.
public struct AppBotStartRequest: Encodable, Equatable, Sendable {
    /// A fresh UUID per start attempt, reused across that attempt's retries.
    public let requestID: String
    public let appVersion: String?
    /// A verified plain DM this device already holds (adoption), or the room it
    /// just created for the second call.
    public let roomID: String?

    public init(requestID: UUID = UUID(), appVersion: String? = nil, roomID: String? = nil) throws {
        if let appVersion {
            _ = try checkedString(appVersion, minimum: 1, maximum: 64)
        }
        if let roomID {
            _ = try checkedString(roomID, minimum: 2, maximum: 255, pattern: "![^\\s]+")
        }
        self.requestID = requestID.uuidString.lowercased()
        self.appVersion = appVersion
        self.roomID = roomID
    }

    /// The same attempt's next call: the same request ID, now naming a room.
    public func naming(roomID: String) throws -> AppBotStartRequest {
        guard let id = UUID(uuidString: requestID) else { throw ContractViolation.invalidValue }
        return try AppBotStartRequest(requestID: id, appVersion: appVersion, roomID: roomID)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(requestID, forKey: Field("requestId"))
        try c.encodeIfPresent(appVersion, forKey: Field("appVersion"))
        try c.encodeIfPresent(roomID, forKey: Field("roomId"))
    }
}

/// What the platform answered. Unknown fields are ignored; the state and the
/// identifiers this phone acts on are read exactly.
public enum AppBotStartAnswer: Decodable, Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable {
        case appUnavailable = "app_unavailable"
        case botUnavailable = "bot_unavailable"
        case notPublished = "not_published"
        /// A newer reason: still unavailable, never read as a grant.
        case other
    }

    /// Open this room.
    case ready(roomID: String, botUserID: String)
    /// Make a plain direct room, invite this bot, and ask again naming it.
    case create(botUserID: String)
    case unavailable(Reason)
    /// An older Shell without the route answers "not found".
    case notFound

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        let state: String = try c.value("state")
        func room() throws -> String {
            let value: String = try c.value("roomId")
            _ = try checkedString(value, minimum: 2, maximum: 255, pattern: "![^\\s]+")
            return value
        }
        func bot() throws -> String { try c.value("botUserId", as: NativeMatrixUser.self).rawValue }
        switch state {
        case "ready": self = .ready(roomID: try room(), botUserID: try bot())
        case "create": self = .create(botUserID: try bot())
        case "unavailable":
            let reason: String? = try c.optional("reason")
            self = .unavailable(reason.flatMap(Reason.init(rawValue:)) ?? .other)
        case "not_found": self = .notFound
        default: throw ContractViolation.invalidValue
        }
    }
}

/// The result of one call: an answer, or "this Shell has no such route".
public enum AppBotStartResult: Equatable, Sendable {
    case answer(AppBotStartAnswer)
    /// 404 (or an explicit `not_found`) from a Shell that predates the route:
    /// the caller falls back to local resolution.
    case routeAbsent
}
