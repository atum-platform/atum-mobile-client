import Foundation
import CryptoKit
import Security

/// Constructed only after signature and flow-bound claims verification.
/// This is deliberately not Decodable: fixture facts cannot create authority.
public struct VerifiedOIDCIdentity: Sendable, Equatable {
    public let issuer, subject, audience: String
    let isAuthorizationCode: Bool
    fileprivate init(issuer: String, subject: String, audience: String, isAuthorizationCode: Bool) {
        self.issuer = issuer; self.subject = subject; self.audience = audience
        self.isAuthorizationCode = isAuthorizationCode
    }
}

/// Pairs an actual token response with the signature-verified identity from
/// that response. Callers cannot mix another response into an initial install.
public struct OIDCVerifiedGrant: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let identity: VerifiedOIDCIdentity
    public let response: OIDCTokenResponse
    let requestedDeviceID: String?
    fileprivate init(identity: VerifiedOIDCIdentity, response: OIDCTokenResponse, requestedDeviceID: String?) {
        self.identity = identity; self.response = response; self.requestedDeviceID = requestedDeviceID
    }
    public var description: String { "OIDCVerifiedGrant(<secrets redacted>)" }
    public var debugDescription: String { description }
}

extension OIDCAcceptedCallback {
    public func verifyGrant(_ response: OIDCTokenResponse, jwks: Data, metadata: MASMetadata, now: Date) throws -> OIDCVerifiedGrant {
        guard let token = response.idToken else { throw OIDCFailure.invalidToken }
        let identity = try verifyIdentity(token, jwks: jwks, metadata: metadata, now: now, accessToken: response.accessToken)
        return OIDCVerifiedGrant(identity: identity, response: response, requestedDeviceID: flow.requestedDeviceID)
    }
}

public enum OIDCVerifier {
    public static func verify(_ token: String, jwks: Data, for flow: OIDCFlow, metadata: MASMetadata,
                              now: Date, accessToken: String? = nil, authorizationCode: String? = nil) throws -> VerifiedOIDCIdentity {
        try verify(token, jwks: jwks, issuer: flow.issuer, audience: flow.clientID, nonce: flow.nonce,
                   subject: nil, metadata: metadata, now: now, accessToken: accessToken, authorizationCode: authorizationCode)
    }
    /// Refresh never establishes an initial account binding. A nonce-bearing
    /// refresh ID token is refused: flow nonces are never persisted on disk.
    static func verifyRefresh(_ token: String, jwks: Data, issuer: String, audience: String, subject: String,
                              metadata: MASMetadata, now: Date, accessToken: String) throws {
        _ = try verify(token, jwks: jwks, issuer: issuer, audience: audience, nonce: nil, subject: subject,
                       metadata: metadata, now: now, accessToken: accessToken, authorizationCode: nil)
    }
    private static func verify(_ token: String, jwks: Data, issuer: String, audience: String, nonce: String?, subject: String?,
                               metadata: MASMetadata, now: Date, accessToken: String?, authorizationCode: String?) throws -> VerifiedOIDCIdentity {
        guard token.utf8.count <= 98_304, jwks.count <= 262_144, metadata.issuer == issuer else { throw OIDCFailure.invalidToken }
        do {
            let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let headerData = Data(base64URL: parts[0]), let body = Data(base64URL: parts[1]),
                  let signature = Data(base64URL: parts[2]), headerData.count <= 4096, body.count <= 65_536 else { throw OIDCFailure.invalidToken }
            let header = try NativeAPI.decode(Header.self, from: headerData, forbidden: [])
            guard ["RS256", "ES256"].contains(header.algorithm), metadata.signingAlgorithms.contains(header.algorithm) else { throw OIDCFailure.unsupportedAlgorithm }
            let keys = try NativeAPI.decode(KeySet.self, from: jwks, forbidden: [])
            let matching = keys.keys.filter { $0.kid == header.kid }
            guard matching.count == 1 else { throw OIDCFailure.invalidSignature }
            let key = matching[0]
            guard key.use == nil || key.use == "sig", key.algorithm == nil || key.algorithm == header.algorithm,
                  key.operations == nil || key.operations!.contains("verify") else { throw OIDCFailure.invalidSignature }
            let signed = Data((parts[0] + "." + parts[1]).utf8)
            guard try key.verifies(signature, signed: signed, algorithm: header.algorithm) else { throw OIDCFailure.invalidSignature }
            let claims = try NativeAPI.decode(Claims.self, from: body, forbidden: [])
            let seconds = now.timeIntervalSince1970
            guard seconds.isFinite, seconds >= 0, seconds < Double(NativeAPI.maximumInteger) else { throw OIDCFailure.invalidClaims }
            let epoch = Int64(seconds.rounded(.down))
            guard claims.issuer == issuer, claims.nonce == nonce, subject == nil || claims.subject == subject,
                  claims.audiences.contains(audience), claims.audiences.count == 1 || claims.authorizedParty == audience,
                  claims.authorizedParty == nil || claims.authorizedParty == audience,
                  claims.expiresAt > epoch, claims.issuedAt <= epoch + 5, claims.issuedAt <= claims.expiresAt,
                  claims.notBefore.map({ $0 <= epoch + 5 && $0 < claims.expiresAt }) ?? true else { throw OIDCFailure.invalidClaims }
            if let hash = claims.accessTokenHash { try check(hash, value: accessToken) }
            if let hash = claims.codeHash { try check(hash, value: authorizationCode) }
            return .init(issuer: claims.issuer, subject: claims.subject, audience: audience, isAuthorizationCode: nonce != nil)
        } catch let failure as OIDCFailure { throw failure }
        catch { throw OIDCFailure.invalidToken }
    }
    private static func check(_ claimed: String, value: String?) throws {
        guard let value, claimed == Data(SHA256.hash(data: Data(value.utf8))).prefix(16).base64URL else { throw OIDCFailure.invalidClaims }
    }

    private struct Header: Decodable {
        let algorithm, kid: String
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            algorithm = try c.string("alg", minimum: 1, maximum: 32)
            kid = try c.string("kid", minimum: 1, maximum: 256)
            // No unverified header can select a URL or change signing input.
            guard !c.contains(Field("jku")), !c.contains(Field("x5u")), !c.contains(Field("jwk")),
                  !c.contains(Field("crit")), !c.contains(Field("b64")) else { throw OIDCFailure.invalidToken }
            if let type: String = try c.optional("typ"), type != "JWT" { throw OIDCFailure.invalidToken }
        }
    }
    private struct Claims: Decodable {
        let issuer, subject: String
        let nonce: String?
        let audiences: [String]
        let authorizedParty, accessTokenHash, codeHash: String?
        let expiresAt, issuedAt: Int64
        let notBefore: Int64?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            issuer = try c.string("iss", minimum: 9, maximum: 2048)
            subject = try c.string("sub", minimum: 1, maximum: 1024)
            nonce = try c.optional("nonce")
            if let nonce, !(1...1024).contains(nonce.unicodeScalars.count) { throw OIDCFailure.invalidClaims }
            if let string = try? c.value("aud", as: String.self) { audiences = [string] }
            else { audiences = try c.value("aud") }
            guard (1...32).contains(audiences.count), Set(audiences).count == audiences.count,
                  audiences.allSatisfy({ (1...1024).contains($0.unicodeScalars.count) }) else { throw OIDCFailure.invalidClaims }
            authorizedParty = try c.optional("azp"); accessTokenHash = try c.optional("at_hash"); codeHash = try c.optional("c_hash")
            expiresAt = try c.integer("exp"); issuedAt = try c.integer("iat")
            notBefore = c.contains(Field("nbf")) ? try c.integer("nbf") : nil
        }
    }
    private struct KeySet: Decodable {
        let keys: [Key]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            keys = try c.value("keys")
            guard (1...64).contains(keys.count) else { throw OIDCFailure.invalidToken }
        }
    }
    private struct Key: Decodable {
        let kid, kind: String
        let algorithm, use: String?
        let operations: [String]?
        let modulus, exponent, curve, x, y: String?
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            guard Set(["d", "p", "q", "dp", "dq", "qi", "oth", "k"]).isDisjoint(with: c.allKeys.map(\.stringValue)) else { throw OIDCFailure.invalidToken }
            kid = try c.string("kid", minimum: 1, maximum: 256); kind = try c.string("kty", minimum: 1, maximum: 16)
            algorithm = try c.optional("alg"); use = try c.optional("use"); operations = try c.optional("key_ops")
            modulus = try c.optional("n"); exponent = try c.optional("e"); curve = try c.optional("crv")
            x = try c.optional("x"); y = try c.optional("y")
        }
        func verifies(_ signature: Data, signed: Data, algorithm: String) throws -> Bool {
            switch (algorithm, kind) {
            case ("ES256", "EC"):
                guard curve == "P-256", let x, let y, let xb = Data(base64URL: x), let yb = Data(base64URL: y),
                      xb.count == 32, yb.count == 32, signature.count == 64 else { throw OIDCFailure.invalidSignature }
                let key = try P256.Signing.PublicKey(x963Representation: Data([4]) + xb + yb)
                return key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: signed)
            case ("RS256", "RSA"):
                guard let modulus, let exponent, let n = Data(base64URL: modulus), let e = Data(base64URL: exponent),
                      (256...1024).contains(n.count), n.first != 0, (n.count > 256 || n.first! >= 128),
                      (1...8).contains(e.count), e.first != 0,
                      signature.count == n.count else { throw OIDCFailure.invalidSignature }
                // SecKey accepts PKCS#1 RSAPublicKey DER. Crypto stays in Security.
                let der = Self.der(0x30, Self.integer(n) + Self.integer(e))
                let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
                guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil),
                      SecKeyIsAlgorithmSupported(key, .verify, .rsaSignatureMessagePKCS1v15SHA256) else { throw OIDCFailure.invalidSignature }
                return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, signature as CFData, nil)
            default: throw OIDCFailure.unsupportedAlgorithm
            }
        }
        private static func integer(_ bytes: Data) -> Data { der(0x02, bytes.first! >= 128 ? Data([0]) + bytes : bytes) }
        private static func der(_ tag: UInt8, _ bytes: Data) -> Data {
            var count = bytes.count
            var length: [UInt8] = []
            if count < 128 { length = [UInt8(count)] }
            else {
                while count > 0 { length.insert(UInt8(count & 255), at: 0); count >>= 8 }
                length.insert(128 | UInt8(length.count), at: 0)
            }
            return Data([tag] + length) + bytes
        }
    }
}

public struct OIDCMe: Decodable, Sendable, Equatable {
    public let issuer, subject: String
    public let principal: NativeID
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self); try c.closed(["issuer", "subject", "principal"])
        issuer = try c.string("issuer", minimum: 9, maximum: 2048, pattern: "https://[!-~]+")
        subject = try c.string("subject", minimum: 1, maximum: 1024); principal = try c.value("principal")
    }
}

public struct OIDCAccountBinding: Sendable, Equatable {
    public let issuer, subject: String
    public let principal: NativeID
    let matrixClientID, domainClientID: String
    public static func bind(matrix: VerifiedOIDCIdentity, domain: VerifiedOIDCIdentity, me: OIDCMe, clients: MASPublicClients) throws -> Self {
        guard matrix.isAuthorizationCode, domain.isAuthorizationCode,
              matrix.audience == clients.matrix else { throw OIDCFailure.subjectMismatch }
        return try bind(matrixIssuer: matrix.issuer, matrixSubject: matrix.subject,
                        matrixClientID: matrix.audience, domain: domain, me: me,
                        clients: clients)
    }
    /// A ready custody ticket carries the issuer/subject/client facts from the
    /// signature-verified Matrix ID token. This permits the independent domain
    /// grant to be retried after relaunch without retaining an ID token or
    /// transient PKCE material.
    static func bind(matrix: MatrixCustodyTicket, domain: VerifiedOIDCIdentity,
                     me: OIDCMe, clients: MASPublicClients) throws -> Self {
        _ = try matrix.requiredDeviceKeys()
        return try bind(matrixIssuer: matrix.envelope.issuer,
                        matrixSubject: matrix.envelope.subject,
                        matrixClientID: matrix.envelope.session.clientID,
                        domain: domain, me: me, clients: clients)
    }
    private static func bind(matrixIssuer: String, matrixSubject: String,
                             matrixClientID: String, domain: VerifiedOIDCIdentity,
                             me: OIDCMe, clients: MASPublicClients) throws -> Self {
        guard domain.isAuthorizationCode,
              matrixClientID == clients.matrix, domain.audience == clients.domain,
              matrixIssuer == domain.issuer, domain.issuer == me.issuer,
              matrixSubject == domain.subject, domain.subject == me.subject else { throw OIDCFailure.subjectMismatch }
        return Self(issuer: me.issuer, subject: me.subject, principal: me.principal,
                    matrixClientID: clients.matrix, domainClientID: clients.domain)
    }
}

/// Untrusted provider conformance facts; never converted to verified identities.
public struct OIDCBindingFacts: Decodable, Sendable {
    private struct Token: Decodable, Sendable {
        let issuer, subject, audience: String
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self); try c.closed(["iss", "sub", "aud", "nonceMatches"])
            issuer = try c.string("iss", minimum: 9, maximum: 2048, pattern: "https://[!-~]+")
            subject = try c.string("sub", minimum: 1, maximum: 1024)
            audience = try c.string("aud", minimum: 26, maximum: 26, pattern: "[0-9A-HJKMNP-TV-Z]{26}")
            guard try c.value("nonceMatches", as: Bool.self) else { throw ContractViolation.invariant }
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self); try c.closed(["matrixClientId", "domainClientId", "matrixIdToken", "domainIdToken", "me"])
        let clients = try MASPublicClients(matrix: c.value("matrixClientId"), domain: c.value("domainClientId"))
        let matrix: Token = try c.value("matrixIdToken"), domain: Token = try c.value("domainIdToken"), me: OIDCMe = try c.value("me")
        guard matrix.audience == clients.matrix, domain.audience == clients.domain,
              matrix.issuer == domain.issuer, domain.issuer == me.issuer,
              matrix.subject == domain.subject, domain.subject == me.subject else { throw ContractViolation.invariant }
    }
}
