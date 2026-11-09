import Foundation
import CryptoKit
import Security

/// Sanitized failures; no callback URL, token, verifier or server body is carried.
public enum OIDCFailure: Error, Equatable {
    case invalidConfiguration, randomUnavailable, invalidCallback, unknownOrUsedState
    case authorizationDenied, invalidToken, unsupportedAlgorithm, invalidSignature
    case invalidClaims, subjectMismatch, deviceMismatch
    case browserBusy, browserUnavailable
}

public struct MASPublicClients: Sendable {
    public static let callback = URL(string: "https://api.atumplatform.com/oauth/ios/callback")!
    /// The frozen `atum.mobile-drive/1` public audience. It deliberately is
    /// not supplied by caller configuration, so Matrix/domain delivery cannot
    /// substitute another client for Drive.
    public static let drive = "01M4SYXQ8KGGTZFVC9F484ZAA6"
    public let matrix, domain: String
    public init(matrix: String, domain: String) throws {
        guard matrix != domain else { throw OIDCFailure.invalidConfiguration }
        for value in [matrix, domain] {
            guard value.range(of: "\\A[0-9A-HJKMNP-TV-Z]{26}\\z", options: .regularExpression) != nil else { throw OIDCFailure.invalidConfiguration }
        }
        self.matrix = matrix; self.domain = domain
    }
}

public struct MASMetadata: Sendable {
    public let issuer: String
    public let authorizationEndpoint, tokenEndpoint, jwksURI, revocationEndpoint: URL
    public let signingAlgorithms: Set<String>
    public static func decode(_ data: Data, expectedIssuer: String) throws -> Self {
        guard data.count <= 262_144 else { throw OIDCFailure.invalidConfiguration }
        do {
            let value = try JSONDecoder().decode(Payload.self, from: data)
            guard value.issuer == expectedIssuer else { throw OIDCFailure.invalidConfiguration }
            return Self(issuer: value.issuer, authorizationEndpoint: value.authorizationEndpoint,
                tokenEndpoint: value.tokenEndpoint, jwksURI: value.jwksURI, revocationEndpoint: value.revocationEndpoint,
                signingAlgorithms: value.signingAlgorithms)
        } catch { throw OIDCFailure.invalidConfiguration }
    }
    private struct Payload: Decodable {
        let issuer: String
        let authorizationEndpoint, tokenEndpoint, jwksURI, revocationEndpoint: URL
        let signingAlgorithms: Set<String>
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            issuer = try c.string("issuer", minimum: 9, maximum: 2048)
            guard let issuerURL = URL(string: issuer), MASMetadata.isHTTPS(issuerURL), issuerURL.query == nil else { throw OIDCFailure.invalidConfiguration }
            func endpoint(_ key: String) throws -> URL {
                let string = try c.string(key, minimum: 9, maximum: 2048)
                guard let url = URL(string: string), MASMetadata.isHTTPS(url), url.query == nil else { throw OIDCFailure.invalidConfiguration }
                return url
            }
            authorizationEndpoint = try endpoint("authorization_endpoint"); tokenEndpoint = try endpoint("token_endpoint")
            jwksURI = try endpoint("jwks_uri"); revocationEndpoint = try endpoint("revocation_endpoint")
            let algorithms: [String] = try c.value("id_token_signing_alg_values_supported")
            guard !algorithms.isEmpty, algorithms.count <= 32 else { throw OIDCFailure.invalidConfiguration }
            signingAlgorithms = Set(algorithms)
            let methods: [String] = try c.value("code_challenge_methods_supported")
            guard methods.contains("S256") else { throw OIDCFailure.invalidConfiguration }
        }
    }
    static func isHTTPS(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.fragment == nil
    }
}

public struct OIDCFlow: Sendable, CustomDebugStringConvertible {
    public enum Kind: Equatable, Sendable { case matrix(deviceID: String), domain, drive }
    public let kind: Kind
    public let clientID, issuer, state, nonce, verifier: String
    public let authorizationURL, tokenEndpoint: URL
    public var debugDescription: String { "OIDCFlow(<in-memory secrets redacted>)" }
    public var requestedDeviceID: String? { if case let .matrix(id) = kind { return id }; return nil }
    public func checkWhoAmI(deviceID: String?) throws {
        guard requestedDeviceID != nil, requestedDeviceID == deviceID else { throw OIDCFailure.deviceMismatch }
    }
}

public struct OIDCAcceptedCallback: Sendable, CustomDebugStringConvertible {
    public let flow: OIDCFlow
    private let code: String
    fileprivate init(flow: OIDCFlow, code: String) { self.flow = flow; self.code = code }
    public var debugDescription: String { "OIDCAcceptedCallback(<in-memory secrets redacted>)" }
    public func tokenRequest() -> URLRequest {
        var request = URLRequest(url: flow.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OIDCForm.encode([("grant_type", "authorization_code"), ("client_id", flow.clientID),
            ("redirect_uri", MASPublicClients.callback.absoluteString), ("code", code), ("code_verifier", flow.verifier)])
        return request
    }
    public func verifyIdentity(_ token: String, jwks: Data, metadata: MASMetadata, now: Date, accessToken: String?) throws -> VerifiedOIDCIdentity {
        try OIDCVerifier.verify(token, jwks: jwks, for: flow, metadata: metadata, now: now, accessToken: accessToken, authorizationCode: code)
    }
}

/// Owns both independent flows only in memory. Cancel/relaunch never reuses one.
@MainActor public final class OIDCFlows {
    private var issued: [String: OIDCFlow] = [:]
    public init() {}
    public var activeCount: Int { issued.count }
    public func isIssued(_ state: String) -> Bool { issued[state] != nil }
    public func begin(_ kind: OIDCFlow.Kind, clients: MASPublicClients, metadata: MASMetadata) throws -> OIDCFlow {
        let client: String, scope: String
        switch kind {
        case let .matrix(id):
            guard id.range(of: "\\A[A-Za-z0-9._-]{1,255}\\z", options: .regularExpression) != nil else { throw OIDCFailure.invalidConfiguration }
            client = clients.matrix
            scope = "openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:" + id
        case .domain: client = clients.domain; scope = "openid"
        case .drive: client = MASPublicClients.drive; scope = "openid"
        }
        let state = try Self.random(), nonce = try Self.random(), verifier = try Self.random()
        var url = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "response_type", value: "code"), .init(name: "client_id", value: client),
            .init(name: "redirect_uri", value: MASPublicClients.callback.absoluteString), .init(name: "scope", value: scope),
            .init(name: "state", value: state), .init(name: "nonce", value: nonce), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "code_challenge", value: Self.challenge(verifier))]
        guard let authorizationURL = url.url, issued[state] == nil else { throw OIDCFailure.randomUnavailable }
        let flow = OIDCFlow(kind: kind, clientID: client, issuer: metadata.issuer, state: state, nonce: nonce,
                            verifier: verifier, authorizationURL: authorizationURL, tokenEndpoint: metadata.tokenEndpoint)
        issued[state] = flow
        return flow
    }
    public func cancel(_ state: String) { issued[state] = nil }
    public func cancelAll() { issued.removeAll() }
    public func consume(_ callback: URL, expectedState: String? = nil) throws -> OIDCAcceptedCallback {
        guard let url = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host == MASPublicClients.callback.host, url.port == nil,
              url.user == nil, url.password == nil,
              url.percentEncodedPath == MASPublicClients.callback.path else { throw OIDCFailure.invalidCallback }
        // MAS's authorization-code response is carried in the query. A browser
        // may retain or add a fragment when handing the HTTPS callback to the
        // app; fragments are never sent to the server and are deliberately
        // non-authoritative here. Exact origin/path, one-time state and code
        // validation below remain mandatory.
        let items = url.queryItems ?? []
        guard items.count <= 16, Set(items.map(\.name)).count == items.count,
              let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty,
              expectedState == nil || state == expectedState,
              let flow = issued.removeValue(forKey: state) else { throw OIDCFailure.unknownOrUsedState }
        // A recognized callback consumes state even on denial/malformed code.
        if items.contains(where: { $0.name == "error" }) { throw OIDCFailure.authorizationDenied }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              (1...8192).contains(code.utf8.count), !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw OIDCFailure.invalidCallback }
        return OIDCAcceptedCallback(flow: flow, code: code)
    }
    public static func challenge(_ verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw OIDCFailure.randomUnavailable }
        return Data(bytes).base64URL
    }
}

enum OIDCForm {
    static func encode(_ fields: [(String, String)]) -> Data {
        func escaped(_ value: String) -> String {
            value.utf8.map { byte in
                if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45, 46, 95, 126].contains(byte) { return String(UnicodeScalar(byte)) }
                return String(format: "%%%02X", byte)
            }.joined()
        }
        return Data(fields.map { escaped($0.0) + "=" + escaped($0.1) }.joined(separator: "&").utf8)
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL string: String) {
        guard !string.isEmpty, string.utf8.count <= 349_528,
              string.range(of: "\\A[A-Za-z0-9_-]+\\z", options: .regularExpression) != nil else { return nil }
        let encoded = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let value = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)), value.base64URL == string else { return nil }
        self = value
    }
}
