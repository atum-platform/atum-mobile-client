import Foundation

public enum OIDCGrantFailure: Error, Equatable {
    case storageUnavailable, reauthenticationRequired, refreshInterrupted, invalidResponse, invalidIdentity
}

/// Secret-bearing token endpoint response. Decode errors carry no raw data.
public struct OIDCTokenResponse: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let accessToken, refreshToken: String
    public let idToken: String?
    public let expiresIn: Int64
    public let scope: String?
    public var description: String { "OIDCTokenResponse(<secrets redacted>)" }
    public var debugDescription: String { description }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 262_144 else { throw OIDCGrantFailure.invalidResponse }
        do {
            let value = try NativeAPI.decode(Payload.self, from: data, forbidden: [])
            return Self(accessToken: value.access, refreshToken: value.refresh, idToken: value.id,
                        expiresIn: value.expires, scope: value.scope)
        } catch { throw OIDCGrantFailure.invalidResponse }
    }
    private struct Payload: Decodable {
        let access, refresh: String
        let id, scope: String?
        let expires: Int64
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            guard try c.string("token_type", minimum: 1, maximum: 32).lowercased() == "bearer" else { throw OIDCGrantFailure.invalidResponse }
            access = try c.string("access_token", minimum: 1, maximum: 8192)
            refresh = try c.string("refresh_token", minimum: 1, maximum: 8192)
            guard [access, refresh].allSatisfy({ !$0.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) }) else { throw OIDCGrantFailure.invalidResponse }
            expires = try c.integer("expires_in", minimum: 1)
            id = try c.optional("id_token"); scope = try c.optional("scope")
            guard id.map({ (1...98_304).contains($0.utf8.count) }) ?? true,
                  scope.map({ $0.utf8.count <= 4096 }) ?? true else { throw OIDCGrantFailure.invalidResponse }
        }
    }
}

/// One atomic, secret-bearing Keychain record. No transient OIDC flow values.
/// Decoding it is storage input; it cannot produce VerifiedOIDCIdentity.
public struct OIDCStoredGrant: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Phase: String, Codable, Sendable { case ready, spending }
    public let generation: UUID
    public let issuer, clientID, subject: String
    public let accessToken, refreshToken: String
    public let expiresAt: Date
    public let phase: Phase
    public let attempt: UUID?
    public var description: String { "OIDCStoredGrant(<secrets redacted>)" }
    public var debugDescription: String { description }
}

/// The real adapter must replace one record atomically in its approved
/// ThisDeviceOnly Keychain class. This interface permits failure injection.
@MainActor public protocol OIDCGrantStore: AnyObject {
    func load() throws -> OIDCStoredGrant?
    func save(_ record: OIDCStoredGrant) throws
}

public struct OIDCRefreshReply: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let response: OIDCTokenResponse
    public let jwks: Data
    // Concrete HTTP uses the clock after response/JWKS delivery. Injected
    // fixtures keep the coordinator's explicit test clock.
    let verificationTime: Date?
    public init(response: OIDCTokenResponse, jwks: Data) {
        self.response = response; self.jwks = jwks; verificationTime = nil
    }
    init(response: OIDCTokenResponse, jwks: Data, verificationTime: Date) {
        self.response = response; self.jwks = jwks; self.verificationTime = verificationTime
    }
    public var description: String { "OIDCRefreshReply(<secrets redacted>)" }
    public var debugDescription: String { description }
}

/// Main process only. Each instance owns exactly one grant/generation and its
/// own flight; it has no operation capable of closing the other grant.
@MainActor public final class OIDCGrantRefresh {
    public typealias Exchange = @MainActor @Sendable (URLRequest) async throws -> OIDCRefreshReply
    public typealias Preflight = @MainActor @Sendable () async throws -> Void
    private let store: any OIDCGrantStore
    private let metadata: MASMetadata
    private let generation: UUID
    private let clientID, subject, expectedScope: String
    private let initialResponse: OIDCTokenResponse?
    private var flight: (id: UUID, task: Task<String, any Error>)?

    public init(store: any OIDCGrantStore, metadata: MASMetadata, grant: OIDCVerifiedGrant,
                generation: UUID, kind: OIDCFlow.Kind, clients: MASPublicClients) throws {
        let identity = grant.identity
        let client: String, scope: String
        switch kind {
        case .domain: client = clients.domain; scope = "openid"
        case .drive: client = MASPublicClients.drive; scope = "openid"
        case let .matrix(deviceID):
            guard deviceID.range(of: "\\A[A-Za-z0-9._-]{1,255}\\z", options: .regularExpression) != nil else { throw OIDCGrantFailure.invalidIdentity }
            client = clients.matrix
            scope = "openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:" + deviceID
        }
        guard identity.isAuthorizationCode, identity.issuer == metadata.issuer, identity.audience == client else { throw OIDCGrantFailure.invalidIdentity }
        self.store = store; self.metadata = metadata; self.generation = generation
        clientID = client; subject = identity.subject; expectedScope = scope
        initialResponse = grant.response
    }

    public init(resuming resume: OIDCDomainResume) throws {
        guard let record = try resume.store.load(), record == resume.record, record.phase == .ready else {
            throw OIDCGrantFailure.reauthenticationRequired
        }
        store = resume.store; metadata = resume.metadata; generation = record.generation
        clientID = record.clientID; subject = record.subject; expectedScope = "openid"
        initialResponse = nil // Relaunch can never reinstall the original token.
    }

    public init(resuming resume: OIDCDriveResume) throws {
        guard let record = try resume.store.load(), record == resume.record,
              record.phase == .ready, record.clientID == MASPublicClients.drive,
              record.issuer == resume.metadata.issuer,
              record.subject == resume.account.subject else {
            throw OIDCGrantFailure.reauthenticationRequired
        }
        store = resume.store
        metadata = resume.metadata
        generation = record.generation
        clientID = record.clientID
        subject = record.subject
        expectedScope = "openid"
        initialResponse = nil
    }

    public init(resuming resume: OIDCMatrixResume) throws {
        guard let record = try resume.store.load(), record == resume.record,
              record.phase == .ready else {
            throw OIDCGrantFailure.reauthenticationRequired
        }
        store = resume.store; metadata = resume.metadata; generation = record.generation
        clientID = record.clientID; subject = record.subject
        expectedScope = resume.expectedScope
        initialResponse = nil // Relaunch can never reinstall the original token.
    }

    public func install(now: Date) throws {
        guard flight == nil else { throw OIDCGrantFailure.storageUnavailable }
        guard let response = initialResponse else { throw OIDCGrantFailure.invalidIdentity }
        try checkScope(response)
        let record = OIDCStoredGrant(generation: generation, issuer: metadata.issuer, clientID: clientID, subject: subject,
            accessToken: response.accessToken, refreshToken: response.refreshToken,
            expiresAt: try expiry(response, now: now), phase: .ready, attempt: nil)
        do {
            if let existing = try store.load() {
                // Repeated initial installation cannot undo a rotated/spent token.
                guard existing == record else { throw OIDCGrantFailure.invalidIdentity }
                return
            }
            try persist(record)
        } catch let error as OIDCGrantFailure { throw error }
        catch { throw OIDCGrantFailure.storageUnavailable }
    }

    public func accessToken(now: Date, preflight: @escaping Preflight = {},
                            exchange: @escaping Exchange) async throws -> String {
        try Task.checkCancellation()
        if let flight { return try await flight.task.value }
        let current = try load()
        guard current.phase == .ready else { throw OIDCGrantFailure.reauthenticationRequired }
        if current.expiresAt > now { return current.accessToken }
        return try await refresh(now: now, preflight: preflight, exchange: exchange)
    }

    /// Explicit 401 retry uses this even before the response-derived expiry.
    public func refresh(now: Date, preflight: @escaping Preflight = {},
                        exchange: @escaping Exchange) async throws -> String {
        try Task.checkCancellation()
        if let flight { return try await flight.task.value }
        let id = UUID()
        let task = Task { try await rotate(now: now, preflight: preflight, exchange: exchange) }
        flight = (id, task)
        defer { if flight?.id == id { flight = nil } }
        return try await task.value
    }

    private func rotate(now: Date, preflight: Preflight, exchange: Exchange) async throws -> String {
        let current = try load()
        guard current.phase == .ready else { throw OIDCGrantFailure.reauthenticationRequired }
        // Match Matrix renewal: prove the issuer is reachable before writing
        // the one-way spending journal. This avoids stranding a ready grant on
        // an already-offline phone; ambiguity after the refresh request starts
        // still remains closed and requires domain-only reauthorization.
        try await preflight()
        try Task.checkCancellation()
        guard try load() == current else { throw OIDCGrantFailure.reauthenticationRequired }
        let pending = OIDCStoredGrant(generation: generation, issuer: current.issuer, clientID: clientID, subject: subject,
            accessToken: current.accessToken, refreshToken: current.refreshToken, expiresAt: current.expiresAt,
            phase: .spending, attempt: UUID())
        // Write/readback must precede spending. A relaunch refuses this record.
        try persist(pending)
        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OIDCForm.encode([("grant_type", "refresh_token"), ("client_id", clientID), ("refresh_token", current.refreshToken)])
        let reply: OIDCRefreshReply
        do { reply = try await exchange(request) }
        catch { throw OIDCGrantFailure.reauthenticationRequired } // Never retry an unresolved spend.
        try checkScope(reply.response)
        guard reply.response.refreshToken != current.refreshToken else { throw OIDCGrantFailure.invalidResponse }
        if let token = reply.response.idToken {
            do {
                try OIDCVerifier.verifyRefresh(token, jwks: reply.jwks, issuer: current.issuer, audience: clientID,
                    subject: subject, metadata: metadata, now: reply.verificationTime ?? now, accessToken: reply.response.accessToken)
            } catch { throw OIDCGrantFailure.invalidResponse }
        }
        let updated = OIDCStoredGrant(generation: generation, issuer: current.issuer, clientID: clientID, subject: subject,
            accessToken: reply.response.accessToken, refreshToken: reply.response.refreshToken,
            expiresAt: try expiry(reply.response, now: now), phase: .ready, attempt: nil)
        // Sign-out/replacement during the await cannot be undone by this reply.
        do {
            guard try store.load() == pending else { throw OIDCGrantFailure.reauthenticationRequired }
        } catch let error as OIDCGrantFailure { throw error }
        catch { throw OIDCGrantFailure.storageUnavailable }
        try persist(updated)
        return updated.accessToken // The first exposure of the new credential.
    }
    private func load() throws -> OIDCStoredGrant {
        do {
            guard let record = try store.load(), record.generation == generation, record.issuer == metadata.issuer,
                  record.clientID == clientID, record.subject == subject,
                  record.expiresAt.timeIntervalSince1970.isFinite,
                  (record.phase == .ready) == (record.attempt == nil),
                  !record.accessToken.isEmpty, !record.refreshToken.isEmpty else { throw OIDCGrantFailure.reauthenticationRequired }
            return record
        } catch let error as OIDCGrantFailure { throw error }
        catch { throw OIDCGrantFailure.storageUnavailable }
    }
    private func persist(_ record: OIDCStoredGrant) throws {
        do {
            try store.save(record)
            guard try store.load() == record else { throw OIDCGrantFailure.storageUnavailable }
        } catch { throw OIDCGrantFailure.storageUnavailable }
    }
    private func expiry(_ response: OIDCTokenResponse, now: Date) throws -> Date {
        let value = now.timeIntervalSince1970 + Double(response.expiresIn)
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0,
              value.isFinite, value < Double(NativeAPI.maximumInteger) else { throw OIDCGrantFailure.invalidResponse }
        return Date(timeIntervalSince1970: value)
    }
    private func checkScope(_ response: OIDCTokenResponse) throws {
        if let scope = response.scope {
            let values = scope.split(separator: " ").map(String.init)
            guard Set(values).count == values.count, Set(values) == Set(expectedScope.split(separator: " ").map(String.init)) else { throw OIDCGrantFailure.invalidResponse }
        }
    }
}
