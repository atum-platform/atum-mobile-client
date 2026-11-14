import Foundation
import CryptoKit

public struct PhoneRegistryRecord: Codable, Equatable, Sendable {
    public enum Platform: String, Codable, Sendable { case ios, macos }
    public enum State: String, Codable, Sendable { case active, revoked }
    public struct Matrix: Codable, Equatable, Sendable { public let deviceId: String; public let fingerprint: String }
    public let deviceServiceId: UUID
    public let displayName: String
    public let platform: Platform
    public let identityKeyId: String
    public let approvalKeyId: String
    public let matrix: Matrix
    public let enrollmentEpoch: Int64
    public let scopes: [String]
    public let pinnedControllerKeys: [String]
    public let state: State
    public let revokeSeq: Int64
    public let createdAt: Int64
    public let rotatedAt: Int64?
    public let revokedAt: Int64?
}
public struct PhoneRegistryList: Decodable, Sendable { public let deviceServices: [PhoneRegistryRecord] }

public extension NativeDomainClient {
    func enrollPhone(body: Data, keys: PhoneApprovalKeyStore, reason: String) async throws -> PhoneRegistryRecord {
        let request = try PhoneEnrollment.request(body: body, keys: keys, reason: reason)
        return try JSONDecoder().decode(PhoneRegistryRecord.self, from: await phoneDeviceServices(request: request))
    }
    func rotatePhone(body: Data, keys: PhoneApprovalKeyStore, previous: PhoneApprovalKeyStore, reason: String) async throws -> PhoneRegistryRecord {
        let request = try PhoneEnrollment.request(body: body, keys: keys, rotatingFrom: previous, reason: reason)
        return try JSONDecoder().decode(PhoneRegistryRecord.self, from: await phoneDeviceServices(request: request))
    }
    func listPhoneRegistrations() async throws -> [PhoneRegistryRecord] {
        try JSONDecoder().decode(PhoneRegistryList.self, from: await phoneDeviceServices()).deviceServices
    }
    func revokePhone(id: UUID) async throws -> PhoneRegistryRecord {
        try JSONDecoder().decode(PhoneRegistryRecord.self, from: await phoneDeviceServices(revoking: id))
    }
    /// The active pinned controller key IDs (`GET /cloud/controller-keys`), for
    /// an enrolment body's `controllerKeys`. Retired keys are left out.
    func phoneControllerKeyIDs() async throws -> [String] {
        let list = try JSONDecoder().decode(PhoneControllerKeys.self, from: await phoneDeviceServices(controllerKeys: true))
        let active = list.keys.filter { $0.state == "active" }.map(\.kid)
        guard (1...8).contains(active.count), Set(active).count == active.count,
              active.allSatisfy({ $0.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil })
        else { throw NativeDomainClientFailure.invalidResponse }
        return active
    }
    /// Whether this server implements the negotiated device-service 1.3 phone
    /// registry. The contract publishes no capability flag, so this asks the
    /// one thing only a 1.3 server does: it refuses a version it does not
    /// know with `matrix_400` (`spec/device-service/v1.3/README.md`, "Legacy
    /// response compatibility"). An older server ignores the header and lists
    /// Macs (200): that is "no". Anything else (503 cloud gate, transport)
    /// throws, so the caller keeps failing closed.
    func phoneRegistrySupported() async throws -> Bool {
        do {
            _ = try await phoneDeviceServices(listVersion: PhoneRegistryContract.probeVersion)
            return false
        } catch let failure as PhoneRegistryError where failure.error == .invalid {
            return true
        }
    }
}

/// device-service 1.3 wire constants the phone negotiates with.
public enum PhoneRegistryContract {
    public static let versionHeader = "Atum-Device-Service-Version"
    /// Lists both platforms, including revoked records.
    public static let listVersion = "1.3"
    /// A version no server publishes; only the capability probe sends it.
    public static let probeVersion = "0.0"
}

struct PhoneControllerKeys: Decodable {
    struct Key: Decodable { let kid: String; let state: String }
    let keys: [Key]
}

/// Use a new generation for rotation, retaining the previous generation until admission.
public struct PhoneKeyNamespace: Sendable {
    public let value: String
    public let installation: UUID
    public let generation: UUID
    public init(owner: String, installation: UUID, generation: UUID) {
        self.installation = installation
        self.generation = generation
        let account = Data(SHA256.hash(data: Data(owner.utf8))).phoneBase64URL
        value = "com.atum.phone-approval.\(account).\(installation.uuidString).\(generation.uuidString)"
    }
}

/// Atomic, credential-free queue. Store under Application Support, outside caches.
/// Actor serialization prevents concurrent sign-outs/retries from losing entries.
public actor PhoneRevocationQueue {
    public struct Entry: Codable, Equatable, Sendable { public let owner: String; public let id: UUID }
    private let file: URL
    private var entries: [Entry]
    public init(file: URL) throws {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))
        } else { entries = [] }
    }
    public func pending(owner: String) -> [Entry] { entries.filter { $0.owner == owner } }
    private func write(_ next: [Entry]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: file, options: .atomic)
        entries = next
    }
    public func enqueue(owner: String, id: UUID) throws {
        let entry = Entry(owner: owner, id: id)
        if !entries.contains(entry) { try write(entries + [entry]) }
    }
    public func retry(owner: String, revoke: (UUID) async throws -> Void) async throws {
        for entry in entries.filter({ $0.owner == owner }) {
            do { try await revoke(entry.id) }
            catch let error as PhoneRegistryError where error.error == .notFound { /* Already absent. */ }
            try write(entries.filter { $0 != entry })
        }
    }
    /// Persist first, attempt online revocation, then discard local authority even offline.
    /// The caller may discard its bearer after this returns, including on transport failure.
    public func signOut(owner: String, id: UUID, keys: PhoneApprovalKeyStore,
                        revoke: (UUID) async throws -> Void) async throws {
        try enqueue(owner: owner, id: id)
        var failure: Error?
        do { try await retry(owner: owner, revoke: revoke) } catch { failure = error }
        var deletionError: Error?
        for role in [PhoneKeyRole.approval, .identity] {
            do { try keys.remove(role) } catch { deletionError = error }
        }
        if let deletionError { throw deletionError }
        if let failure { throw failure }
    }
}

public extension PhoneEnrollment {
    /// Builds the exact iOS wire body from registry/account metadata and key exports.
    static func body(id: UUID, displayName: String, osVersion: String,
                     matrixUserID: String, matrixDeviceID: String, matrixFingerprint: String,
                     epoch: Int64 = 1, controllerKeyIDs: [String], issuedAt: Int64,
                     keys: PhoneApprovalKeyStore, previous: PhoneApprovalKeyStore? = nil) throws -> Data {
        var object: [String: Any] = ["deviceServiceId": id.uuidString.lowercased(),
            "displayName": displayName, "platform": "ios", "osVersion": osVersion,
            "identityKey": try keys.publicKey(.identity).phoneBase64URL,
            "approvalKey": try keys.publicKey(.approval).phoneBase64URL,
            "matrix": ["userId": matrixUserID, "deviceId": matrixDeviceID, "fingerprint": matrixFingerprint],
            "enrollmentEpoch": epoch, "scopes": [String](), "controllerKeys": controllerKeyIDs, "issuedAt": issuedAt]
        if let previous { object["previousApprovalKid"] = keyID(spki: try previous.publicKey(.approval)) }
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        _ = try canonicalBytes(body: body)
        return body
    }
}
