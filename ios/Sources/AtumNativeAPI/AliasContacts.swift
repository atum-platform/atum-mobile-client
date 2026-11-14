import Foundation

/// Public-handle backfill by permanent Matrix identity (public-handles/v1.1).
/// No room, domain principal or reason for a missing handle crosses this boundary.
public struct AliasContactsRequest: Encodable, Equatable, Sendable {
    public static let maximumCount = 50
    public let matrixUsers: [String]
    public let schemaVersion: Int?

    public init(matrixUsers: [String], versioned: Bool = true) throws {
        guard (1...Self.maximumCount).contains(matrixUsers.count),
              Set(matrixUsers).count == matrixUsers.count,
              matrixUsers.allSatisfy(Self.accepts) else { throw ContractViolation.invalidValue }
        self.matrixUsers = matrixUsers
        schemaVersion = versioned ? 2 : nil
    }

    public static func accepts(_ userID: String) -> Bool {
        userID.utf8.count <= 255 && userID.range(
            of: "^@[a-z0-9._=/-]{1,255}:[A-Za-z0-9.-]{1,253}(?::[0-9]{1,5})?$",
            options: .regularExpression) == userID.startIndex..<userID.endIndex
    }
}

public struct AliasContact: Decodable, Equatable, Sendable {
    public enum Status: String, Decodable, Sendable { case resolved, notVisible = "not_visible", unknown }
    public let matrixUser: NativeMatrixUser
    public let handle: NativeHandle?
    public let status: Status?
    public let generation: Int64?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["matrixUser", "handle", "status", "generation"])
        matrixUser = try c.value("matrixUser")
        guard AliasContactsRequest.accepts(matrixUser.rawValue) else { throw ContractViolation.invalidValue }
        handle = try c.nullable("handle")
        status = try c.optional("status")
        if let status {
            generation = try c.nullableInteger("generation", minimum: 1)
            guard status == .resolved ? (handle != nil && generation != nil)
                : (handle == nil && generation == nil) else { throw ContractViolation.invariant }
        } else {
            guard !c.contains(Field("generation")) else { throw ContractViolation.unknownField }
            generation = nil
        }
    }
}

public struct AliasContactsResponse: Decodable, Equatable, Sendable {
    public let contacts: [AliasContact]
    public let revision: Int64?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["contacts", "schemaVersion", "revision"])
        contacts = try c.value("contacts")
        guard contacts.count <= AliasContactsRequest.maximumCount else { throw ContractViolation.invalidValue }
        if c.contains(Field("schemaVersion")) {
            guard try c.integer("schemaVersion") == 2,
                  contacts.allSatisfy({ $0.status != nil }) else { throw ContractViolation.invariant }
            revision = try c.integer("revision")
        } else {
            guard !c.contains(Field("revision")), contacts.allSatisfy({ $0.status == nil }) else {
                throw ContractViolation.invariant
            }
            revision = nil
        }
    }
}
