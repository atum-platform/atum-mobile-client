import XCTest
import Foundation
import CryptoKit
import Security
import AtumPrototype
@testable import AtumNativeAPI

final class OIDCTests: XCTestCase {
    private func metadata() throws -> MASMetadata {
        try MASMetadata.decode(JSONSerialization.data(withJSONObject: [
            "issuer": "https://auth.atum.test/", "authorization_endpoint": "https://auth.atum.test/oauth2/authorize",
            "token_endpoint": "https://auth.atum.test/oauth2/token", "jwks_uri": "https://auth.atum.test/oauth2/keys",
            "revocation_endpoint": "https://auth.atum.test/oauth2/revoke", "id_token_signing_alg_values_supported": ["ES256", "RS256"],
            "code_challenge_methods_supported": ["plain", "S256"]]), expectedIssuer: "https://auth.atum.test/")
    }
    private func clients() throws -> MASPublicClients {
        try .init(matrix: "01JPHNMXPQ7R8S9T0V2W3X4Y5Z", domain: "01JPHNDXPQ7R8S9T0V2W3X4Y5Z")
    }
    private func callback(_ flow: OIDCFlow, code: String = "synthetic+code & 🌗") -> URL {
        var value = URLComponents(url: MASPublicClients.callback, resolvingAgainstBaseURL: false)!
        value.queryItems = [.init(name: "state", value: flow.state), .init(name: "code", value: code)]
        return value.url!
    }
    private func claims(_ flow: OIDCFlow) -> [String: Any] {
        ["iss": flow.issuer, "sub": "synthetic-subject", "aud": flow.clientID, "nonce": flow.nonce, "exp": 3600, "iat": 0]
    }
    private func signingInput(header: [String: Any], claims: [String: Any]) throws -> String {
        try JSONSerialization.data(withJSONObject: header, options: .sortedKeys).base64URL + "." + JSONSerialization.data(withJSONObject: claims, options: .sortedKeys).base64URL
    }
    private func jwt(_ claims: [String: Any], key: P256.Signing.PrivateKey, header: [String: Any]? = nil) throws -> String {
        let input = try signingInput(header: header ?? ["alg": "ES256", "kid": "p2-ephemeral", "typ": "JWT"], claims: claims)
        return input + "." + (try key.signature(for: Data(input.utf8))).rawRepresentation.base64URL
    }
    private func jwk(_ key: P256.Signing.PrivateKey) -> [String: Any] {
        let bytes = key.publicKey.x963Representation
        return ["kty": "EC", "kid": "p2-ephemeral", "alg": "ES256", "use": "sig", "crv": "P-256",
                "x": bytes.subdata(in: 1..<33).base64URL, "y": bytes.subdata(in: 33..<65).base64URL]
    }
    private func jwks(_ key: P256.Signing.PrivateKey) throws -> Data { try JSONSerialization.data(withJSONObject: ["keys": [jwk(key)]]) }

    @MainActor private final class MemoryGrantStore: OIDCGrantStore {
        var record: OIDCStoredGrant?
        var writes = 0
        var failWrite: Int?
        var phases: [OIDCStoredGrant.Phase] = []
        func load() throws -> OIDCStoredGrant? { record }
        func save(_ value: OIDCStoredGrant) throws {
            writes += 1
            if writes == failWrite { throw OIDCGrantFailure.storageUnavailable }
            record = value; phases.append(value.phase)
        }
    }
    private func tokenResponse(access: String = "synthetic-access", refresh: String = "synthetic-refresh", expires: Any = 1,
                               id: String? = nil, scope: String? = "openid") throws -> OIDCTokenResponse {
        var body: [String: Any] = ["token_type": "Bearer", "access_token": access, "refresh_token": refresh, "expires_in": expires]
        body["id_token"] = id; body["scope"] = scope
        return try OIDCTokenResponse.decode(JSONSerialization.data(withJSONObject: body))
    }
    @MainActor private func initialGrant() throws -> OIDCVerifiedGrant {
        let registry = OIDCFlows(), metadata = try metadata(), key = P256.Signing.PrivateKey()
        let flow = try registry.begin(.domain, clients: clients(), metadata: metadata)
        let accepted = try registry.consume(callback(flow))
        return try accepted.verifyGrant(tokenResponse(id: jwt(claims(flow), key: key)), jwks: jwks(key), metadata: metadata, now: Date(timeIntervalSince1970: 100))
    }

    @MainActor func testRefreshSingleFlightAndPersistenceBeforeExposure() async throws {
        let store = MemoryGrantStore(), grant = try initialGrant(), generation = UUID()
        let controller = try OIDCGrantRefresh(store: store, metadata: metadata(), grant: grant, generation: generation, kind: .domain, clients: clients())
        try controller.install(now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.record?.expiresAt, Date(timeIntervalSince1970: 101))
        var requests = 0
        let reply = OIDCRefreshReply(response: try tokenResponse(access: "rotated-access", refresh: "rotated-refresh", expires: 120), jwks: Data())
        let exchange: OIDCGrantRefresh.Exchange = { request in
            requests += 1
            XCTAssertEqual(store.record?.phase, .spending)
            XCTAssertNotNil(store.record?.attempt)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(String(decoding: request.httpBody!, as: UTF8.self), "grant_type=refresh_token&client_id=\(grant.identity.audience)&refresh_token=synthetic-refresh")
            await Task.yield()
            return reply
        }
        async let first = controller.refresh(now: Date(timeIntervalSince1970: 102), exchange: exchange)
        async let second = controller.refresh(now: Date(timeIntervalSince1970: 102), exchange: exchange)
        let tokens = try await [first, second]
        XCTAssertEqual(tokens, ["rotated-access", "rotated-access"])
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(store.phases, [.ready, .spending, .ready])
        XCTAssertEqual(store.record?.refreshToken, "rotated-refresh")
        XCTAssertEqual(store.record?.expiresAt, Date(timeIntervalSince1970: 222))
        XCTAssertNil(store.record?.attempt)
        XCTAssertThrowsError(try controller.install(now: Date(timeIntervalSince1970: 100))) // Cannot reinstall stale credentials.
    }

    @MainActor func testRefreshPreflightFailureDoesNotJournalOrSpendTheReadyGrant() async throws {
        let store = MemoryGrantStore(), grant = try initialGrant(), generation = UUID()
        let controller = try OIDCGrantRefresh(
            store: store, metadata: metadata(), grant: grant,
            generation: generation, kind: .domain, clients: clients()
        )
        try controller.install(now: Date(timeIntervalSince1970: 100))
        var preflights = 0
        var exchanges = 0
        do {
            _ = try await controller.accessToken(
                now: Date(timeIntervalSince1970: 102),
                preflight: {
                    preflights += 1
                    throw MASHTTPFailure.transportUnavailable
                },
                exchange: { _ in
                    exchanges += 1
                    throw MASHTTPFailure.invalidResponse
                }
            )
            XCTFail("offline preflight reached the refresh exchange")
        } catch {
            XCTAssertEqual(error as? MASHTTPFailure, .transportUnavailable)
        }
        XCTAssertEqual(preflights, 1)
        XCTAssertEqual(exchanges, 0)
        XCTAssertEqual(store.phases, [.ready])
        XCTAssertEqual(store.record?.phase, .ready)

        let reply = OIDCRefreshReply(
            response: try tokenResponse(access: "rotated-access", refresh: "rotated-refresh", expires: 120),
            jwks: Data()
        )
        let token = try await controller.accessToken(
            now: Date(timeIntervalSince1970: 102),
            preflight: { preflights += 1 },
            exchange: { _ in exchanges += 1; return reply }
        )
        XCTAssertEqual(token, "rotated-access")
        XCTAssertEqual(preflights, 2)
        XCTAssertEqual(exchanges, 1)
        XCTAssertEqual(store.phases, [.ready, .spending, .ready])
    }

    @MainActor func testRefreshStorageFailuresAndInterruptedSpendNeverReuseToken() async throws {
        let store = MemoryGrantStore(), grant = try initialGrant(), generation = UUID()
        let controller = try OIDCGrantRefresh(store: store, metadata: metadata(), grant: grant, generation: generation, kind: .domain, clients: clients())
        try controller.install(now: Date(timeIntervalSince1970: 100))
        let reply = OIDCRefreshReply(response: try tokenResponse(access: "rotated-access", refresh: "rotated-refresh"), jwks: Data())
        var calls = 0
        let exchange: OIDCGrantRefresh.Exchange = { _ in calls += 1; return reply }
        store.failWrite = 2
        do { _ = try await controller.refresh(now: Date(timeIntervalSince1970: 102), exchange: exchange); XCTFail("Storage failure must refuse spending") }
        catch { XCTAssertEqual(error as? OIDCGrantFailure, .storageUnavailable) }
        XCTAssertEqual(calls, 0); XCTAssertEqual(store.record?.phase, .ready)
        store.failWrite = 4 // Pending succeeds; rotated credential persistence fails.
        do { _ = try await controller.refresh(now: Date(timeIntervalSince1970: 102), exchange: exchange); XCTFail("New token must not escape before persistence") }
        catch { XCTAssertEqual(error as? OIDCGrantFailure, .storageUnavailable) }
        XCTAssertEqual(calls, 1); XCTAssertEqual(store.record?.phase, .spending)
        XCTAssertEqual(store.record?.accessToken, "synthetic-access")
        let resumed = try OIDCGrantRefresh(store: store, metadata: metadata(), grant: grant, generation: generation, kind: .domain, clients: clients())
        do { _ = try await resumed.refresh(now: Date(timeIntervalSince1970: 103), exchange: exchange); XCTFail("Unresolved spend requires reauthentication") }
        catch { XCTAssertEqual(error as? OIDCGrantFailure, .reauthenticationRequired) }
        XCTAssertEqual(calls, 1)
    }

    @MainActor func testRefreshLostResponseAndSignOutDuringExchangeStayClosed() async throws {
        for signedOut in [false, true] {
            let store = MemoryGrantStore(), grant = try initialGrant()
            let controller = try OIDCGrantRefresh(store: store, metadata: metadata(), grant: grant, generation: UUID(), kind: .domain, clients: clients())
            try controller.install(now: Date(timeIntervalSince1970: 100))
            let reply = OIDCRefreshReply(response: try tokenResponse(access: "rotated-access", refresh: "rotated-refresh"), jwks: Data())
            var calls = 0
            let exchange: OIDCGrantRefresh.Exchange = { _ in
                calls += 1
                if signedOut { store.record = nil; return reply }
                throw URLError(.networkConnectionLost)
            }
            do { _ = try await controller.refresh(now: Date(timeIntervalSince1970: 102), exchange: exchange); XCTFail("Unresolved/stale response must not escape") }
            catch { XCTAssertEqual(error as? OIDCGrantFailure, .reauthenticationRequired) }
            XCTAssertEqual(calls, 1)
            if signedOut { XCTAssertNil(store.record) }
            else { XCTAssertEqual(store.record?.phase, .spending) }
            do { _ = try await controller.refresh(now: Date(timeIntervalSince1970: 103), exchange: exchange); XCTFail("Cannot spend twice") }
            catch { XCTAssertEqual(error as? OIDCGrantFailure, .reauthenticationRequired) }
            XCTAssertEqual(calls, 1)
        }
    }

    @MainActor func testRefreshRejectsScopeSubjectNonceAndUnrotatedCredential() async throws {
        let key = P256.Signing.PrivateKey(), keys = try jwks(key), grant = try initialGrant()
        let goodClaims: [String: Any] = ["iss": grant.identity.issuer, "sub": grant.identity.subject,
            "aud": grant.identity.audience, "exp": 3600, "iat": 100]
        for variant in ["good", "wider-scope", "unrotated", "wrong-subject", "nonce"] {
            let store = MemoryGrantStore()
            let controller = try OIDCGrantRefresh(store: store, metadata: metadata(), grant: grant, generation: UUID(), kind: .domain, clients: clients())
            try controller.install(now: Date(timeIntervalSince1970: 100))
            var claims = goodClaims
            if variant == "wrong-subject" { claims["sub"] = "other-subject" }
            if variant == "nonce" { claims["nonce"] = "unretained-flow-nonce" }
            let response = try tokenResponse(access: "rotated-access", refresh: variant == "unrotated" ? "synthetic-refresh" : "rotated-refresh",
                id: jwt(claims, key: key), scope: variant == "wider-scope" ? "openid profile" : "openid")
            do {
                let token = try await controller.refresh(now: Date(timeIntervalSince1970: 102), exchange: { _ in .init(response: response, jwks: keys) })
                XCTAssertEqual(variant, "good"); XCTAssertEqual(token, "rotated-access")
            } catch { XCTAssertNotEqual(variant, "good"); XCTAssertEqual(error as? OIDCGrantFailure, .invalidResponse) }
            XCTAssertEqual(store.record?.phase, variant == "good" ? .ready : .spending)
        }
        for invalid in [true as Any, 1.5, 0, -1] { XCTAssertThrowsError(try tokenResponse(expires: invalid)) }
        XCTAssertThrowsError(try tokenResponse(access: "unsafe\r\nheader"))
        XCTAssertFalse(String(describing: grant).contains("synthetic-access"))
    }

    @MainActor func testIndependentFlowsS256AndExactTokenForm() throws {
        let registry = OIDCFlows(), client = try clients(), metadata = try metadata()
        let matrix = try registry.begin(.matrix(deviceID: "P2-DEVICE"), clients: client, metadata: metadata)
        let domain = try registry.begin(.domain, clients: client, metadata: metadata)
        XCTAssertEqual(registry.activeCount, 2)
        XCTAssertEqual(Set([matrix.state, matrix.nonce, matrix.verifier, domain.state, domain.nonce, domain.verifier]).count, 6)
        XCTAssertTrue([matrix.state, matrix.nonce, matrix.verifier].allSatisfy { Data(base64URL: $0)?.count == 32 })
        // RFC 7636 Appendix B known S256 relationship, not an implementation snapshot.
        XCTAssertEqual(OIDCFlows.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let items = URLComponents(url: matrix.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertTrue(query["scope"]!.contains("client:device:P2-DEVICE"))
        XCTAssertNil(query["prompt"]) // M1 never creates a new account implicitly.
        let accepted = try registry.consume(callback(matrix))
        let request = accepted.tokenRequest()
        let form = String(decoding: request.httpBody!, as: UTF8.self)
        XCTAssertTrue(form.contains("code=synthetic%2Bcode%20%26%20%F0%9F%8C%97"))
        XCTAssertTrue(form.contains("code_verifier=" + matrix.verifier))
        XCTAssertFalse(form.contains("client_secret"))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(registry.activeCount, 1)
        XCTAssertThrowsError(try registry.consume(callback(matrix)))
        try matrix.checkWhoAmI(deviceID: "P2-DEVICE")
        XCTAssertThrowsError(try matrix.checkWhoAmI(deviceID: "OTHER"))
        XCTAssertThrowsError(try registry.begin(.matrix(deviceID: "* openid"), clients: client, metadata: metadata))
        registry.cancel(domain.state)
        XCTAssertEqual(registry.activeCount, 0)
    }

    func testMetadataIssuerAndEndpointTrustBoundary() throws {
        let good = try metadata()
        let base: [String: Any] = ["issuer": good.issuer,
            "authorization_endpoint": good.authorizationEndpoint.absoluteString,
            "token_endpoint": good.tokenEndpoint.absoluteString,
            "jwks_uri": good.jwksURI.absoluteString,
            "revocation_endpoint": good.revocationEndpoint.absoluteString,
            "id_token_signing_alg_values_supported": ["RS256"], "code_challenge_methods_supported": ["S256"]]
        func decode(_ object: [String: Any], issuer: String = "https://auth.atum.test/") throws -> MASMetadata {
            try MASMetadata.decode(JSONSerialization.data(withJSONObject: object), expectedIssuer: issuer)
        }
        XCTAssertNoThrow(try decode(base))
        XCTAssertThrowsError(try decode(base, issuer: "https://foreign.test/"))
        for field in ["issuer", "authorization_endpoint", "token_endpoint", "jwks_uri", "revocation_endpoint"] {
            for invalid in ["http://auth.atum.test/path", "https://user:pass@auth.atum.test/path", "https://auth.atum.test/path#fragment", "https://auth.atum.test/path?secret=synthetic"] {
                var altered = base; altered[field] = invalid
                XCTAssertThrowsError(try decode(altered), field)
            }
        }
        var noS256 = base; noS256["code_challenge_methods_supported"] = ["plain"]
        XCTAssertThrowsError(try decode(noS256))
        XCTAssertThrowsError(try MASPublicClients(matrix: "01JPHNMXPQ7R8S9T0V2W3X4Y5Z", domain: "01JPHNMXPQ7R8S9T0V2W3X4Y5Z"))
        XCTAssertThrowsError(try MASPublicClients(matrix: "fixture-not-a-client", domain: "01JPHNDXPQ7R8S9T0V2W3X4Y5Z"))
    }

    @MainActor func testCallbackNearMissDeniedMalformedAndWrongFlow() throws {
        let registry = OIDCFlows(), metadata = try metadata(), clients = try clients()
        let matrix = try registry.begin(.matrix(deviceID: "P2-DEVICE"), clients: clients, metadata: metadata)
        let domain = try registry.begin(.domain, clients: clients, metadata: metadata)
        for prefix in ["http://api.atumplatform.com/oauth/ios/callback", "https://evil.test/oauth/ios/callback",
                       "https://api.atumplatform.com/oauth/ios/callback/", "https://api.atumplatform.com:443/oauth/ios/callback",
                       "https://api.atumplatform.com/%6fauth/ios/callback"] {
            var value = URLComponents(string: prefix)!
            value.queryItems = [.init(name: "state", value: matrix.state), .init(name: "code", value: "synthetic")]
            XCTAssertThrowsError(try registry.consume(value.url!))
        }
        XCTAssertEqual(registry.activeCount, 2)
        XCTAssertThrowsError(try registry.consume(callback(domain), expectedState: matrix.state))
        XCTAssertEqual(registry.activeCount, 2)
        var denied = URLComponents(url: callback(matrix), resolvingAgainstBaseURL: false)!
        denied.queryItems = [.init(name: "state", value: matrix.state), .init(name: "error", value: "access_denied")]
        XCTAssertThrowsError(try registry.consume(denied.url!)) { XCTAssertEqual($0 as? OIDCFailure, .authorizationDenied) }
        XCTAssertEqual(registry.activeCount, 1)
        var malformed = URLComponents(url: callback(domain), resolvingAgainstBaseURL: false)!
        malformed.queryItems = [.init(name: "state", value: domain.state)]
        XCTAssertThrowsError(try registry.consume(malformed.url!))
        XCTAssertEqual(registry.activeCount, 0)
        XCTAssertThrowsError(try registry.consume(callback(domain)))
    }

    @MainActor func testCallbackIgnoresFragmentOnlyAfterExactQueryValidation() throws {
        let registry = OIDCFlows(), metadata = try metadata(), clients = try clients()
        let acceptedFlow = try registry.begin(.domain, clients: clients, metadata: metadata)
        var withResidue = URLComponents(url: callback(acceptedFlow), resolvingAgainstBaseURL: false)!
        withResidue.fragment = "browser-residue"
        XCTAssertNoThrow(try registry.consume(try XCTUnwrap(withResidue.url)))

        let fragmentOnlyFlow = try registry.begin(.domain, clients: clients, metadata: metadata)
        var fragmentOnly = URLComponents(url: MASPublicClients.callback, resolvingAgainstBaseURL: false)!
        fragmentOnly.fragment = "state=\(fragmentOnlyFlow.state)&code=synthetic"
        XCTAssertThrowsError(try registry.consume(try XCTUnwrap(fragmentOnly.url))) {
            XCTAssertEqual($0 as? OIDCFailure, .unknownOrUsedState)
        }
        XCTAssertTrue(registry.isIssued(fragmentOnlyFlow.state))
    }

    @MainActor func testActualES256SignatureNonceIssuerAudienceAndTime() throws {
        let metadata = try metadata(), registry = OIDCFlows()
        let flow = try registry.begin(.domain, clients: clients(), metadata: metadata)
        let key = P256.Signing.PrivateKey(), keys = try jwks(key)
        let good = try jwt(claims(flow), key: key)
        let verified = try OIDCVerifier.verify(good, jwks: keys, for: flow, metadata: metadata, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(verified.subject, "synthetic-subject")
        XCTAssertThrowsError(try OIDCVerifier.verify(good, jwks: jwks(P256.Signing.PrivateKey()), for: flow, metadata: metadata, now: Date(timeIntervalSince1970: 100)))
        for (field, value) in [("nonce", "wrong" as Any), ("iss", "https://foreign.test/"), ("aud", "01JPHNMXPQ7R8S9T0V2W3X4Y5Z"),
                              ("exp", 100), ("iat", 106), ("nbf", 106), ("exp", true), ("exp", 1000.5)] {
            var altered = claims(flow); altered[field] = value
            let signed = try jwt(altered, key: key)
            XCTAssertThrowsError(try OIDCVerifier.verify(signed, jwks: keys, for: flow, metadata: metadata, now: Date(timeIntervalSince1970: 100)), field)
        }
        var body = claims(flow); body["sub"] = "tampered"
        let input = try signingInput(header: ["alg": "ES256", "kid": "p2-ephemeral", "typ": "JWT"], claims: body)
        let tampered = input + "." + good.split(separator: ".").last!
        XCTAssertThrowsError(try OIDCVerifier.verify(tampered, jwks: keys, for: flow, metadata: metadata, now: Date(timeIntervalSince1970: 100)))
    }

    @MainActor func testAudienceAzpTokenHashesAndUntrustedKeyHeaders() throws {
        let metadata = try metadata(), registry = OIDCFlows()
        let flow = try registry.begin(.domain, clients: clients(), metadata: metadata), key = P256.Signing.PrivateKey(), keys = try jwks(key)
        let accepted = try registry.consume(callback(flow, code: "synthetic-code"))
        var body = claims(flow)
        body["aud"] = [flow.clientID, "another-client"]
        XCTAssertThrowsError(try accepted.verifyIdentity(jwt(body, key: key), jwks: keys, metadata: metadata, now: Date(timeIntervalSince1970: 100), accessToken: "synthetic-access"))
        body["azp"] = flow.clientID
        body["at_hash"] = Data(SHA256.hash(data: Data("synthetic-access".utf8))).prefix(16).base64URL
        body["c_hash"] = Data(SHA256.hash(data: Data("synthetic-code".utf8))).prefix(16).base64URL
        let token = try jwt(body, key: key)
        XCTAssertNoThrow(try accepted.verifyIdentity(token, jwks: keys, metadata: metadata, now: Date(timeIntervalSince1970: 100), accessToken: "synthetic-access"))
        XCTAssertThrowsError(try accepted.verifyIdentity(token, jwks: keys, metadata: metadata, now: Date(timeIntervalSince1970: 100), accessToken: "wrong-access"))
        for header in [["alg": "none", "kid": "p2-ephemeral"], ["alg": "HS256", "kid": "p2-ephemeral"],
                       ["alg": "ES256", "kid": "p2-ephemeral", "jku": "https://evil.test/keys"]] {
            XCTAssertThrowsError(try OIDCVerifier.verify(jwt(claims(flow), key: key, header: header), jwks: keys, for: flow, metadata: metadata, now: Date(timeIntervalSince1970: 100)))
        }
        let duplicate = try JSONSerialization.data(withJSONObject: ["keys": [jwk(key), jwk(key)]])
        XCTAssertThrowsError(try OIDCVerifier.verify(jwt(claims(flow), key: key), jwks: duplicate, for: flow, metadata: metadata, now: Date(timeIntervalSince1970: 100)))
    }

    @MainActor func testThreeWayVerifiedBindingAndDomainIndependence() throws {
        let registry = OIDCFlows(), metadata = try metadata(), client = try clients(), key = P256.Signing.PrivateKey(), keys = try jwks(key)
        let matrix = try registry.begin(.matrix(deviceID: "P2-DEVICE"), clients: client, metadata: metadata)
        let domain = try registry.begin(.domain, clients: client, metadata: metadata)
        let matrixID = try OIDCVerifier.verify(jwt(claims(matrix), key: key), jwks: keys, for: matrix, metadata: metadata, now: Date(timeIntervalSince1970: 100))
        let domainID = try OIDCVerifier.verify(jwt(claims(domain), key: key), jwks: keys, for: domain, metadata: metadata, now: Date(timeIntervalSince1970: 100))
        func me(_ subject: String) throws -> OIDCMe {
            try NativeAPI.decode(OIDCMe.self, from: JSONSerialization.data(withJSONObject: ["issuer": metadata.issuer, "subject": subject, "principal": "00000000-0000-4000-8000-038d3d87b15e"]))
        }
        let binding = try OIDCAccountBinding.bind(matrix: matrixID, domain: domainID, me: me("synthetic-subject"), clients: client)
        XCTAssertThrowsError(try OIDCAccountBinding.bind(matrix: matrixID, domain: domainID, me: me("another-subject"), clients: client))
        XCTAssertThrowsError(try OIDCAccountBinding.bind(matrix: domainID, domain: matrixID, me: me("synthetic-subject"), clients: client))
        var lifecycle = OIDCDomainLifecycle()
        XCTAssertFalse(lifecycle.activate(binding))
        XCTAssertTrue(lifecycle.start()); XCTAssertTrue(lifecycle.activate(binding))
        XCTAssertTrue(lifecycle.revokedElsewhere()); XCTAssertEqual(lifecycle.state, .reauthRequired)
        XCTAssertEqual(matrixID.subject, "synthetic-subject") // Domain has no Matrix teardown operation.
        XCTAssertTrue(lifecycle.start()); XCTAssertTrue(lifecycle.cancel()); XCTAssertEqual(lifecycle.state, .signedOut)
        XCTAssertNil(lifecycle.binding)
    }

    func testFrozenClientBindingAndDomainFixtures() throws {
        struct Sequence: Decodable {
            struct Step: Decodable { let from, to: OIDCDomainLifecycle.State; let event: OIDCDomainLifecycle.Event }
            let steps: [Step]
        }
        let fixtures = try NativeAuthFixtures()
        for entry in fixtures.manifest.fixtures {
            let data = try fixtures.data(entry.file)
            if let message = entry.message {
                func decode() throws {
                    if message == "ios.client_registration" { _ = try NativeAPI.decode(OIDCClientRegistration.self, from: data) }
                    else { _ = try NativeAPI.decode(OIDCBindingFacts.self, from: data) }
                }
                if entry.expect == "accept" { XCTAssertNoThrow(try decode(), entry.file) }
                else { XCTAssertThrowsError(try decode(), entry.file) }
            } else {
                let sequence = try JSONDecoder().decode(Sequence.self, from: data)
                var machine = OIDCDomainLifecycle()
                let valid = sequence.steps.allSatisfy { machine.state == $0.from && machine.advance($0.event) && machine.state == $0.to }
                XCTAssertEqual(valid, entry.expect == "accept", entry.file)
            }
        }
    }

    @MainActor func testActualRS256SecurityVerificationUsesPublicJWKOnly() throws {
        // Ephemeral test key: no Keychain entry, file, log or escrow credential.
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let bytes = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var cursor = 0
        func element(_ tag: UInt8) throws -> Data {
            guard cursor + 2 <= bytes.count, bytes[cursor] == tag else { throw OIDCFailure.invalidToken }
            cursor += 1
            let first = Int(bytes[cursor]); cursor += 1
            var count = first
            if first >= 128 {
                let length = first & 127
                guard (1...4).contains(length), cursor + length <= bytes.count else { throw OIDCFailure.invalidToken }
                count = 0
                for _ in 0..<length { count = count * 256 + Int(bytes[cursor]); cursor += 1 }
            }
            guard cursor + count <= bytes.count else { throw OIDCFailure.invalidToken }
            if tag == 0x30 { return Data() } // Leave cursor at sequence contents.
            let value = bytes.subdata(in: cursor..<cursor + count); cursor += count
            return value.first == 0 ? Data(value.dropFirst()) : value
        }
        _ = try element(0x30)
        let n = try element(0x02), e = try element(0x02)
        let metadata = try metadata(), flow = try OIDCFlows().begin(.domain, clients: clients(), metadata: metadata)
        let input = try signingInput(header: ["alg": "RS256", "kid": "p2-rsa"], claims: claims(flow))
        let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)) as Data
        let token = input + "." + signature.base64URL
        var key: [String: Any] = ["kty": "RSA", "kid": "p2-rsa", "alg": "RS256", "n": n.base64URL, "e": e.base64URL]
        func keys() throws -> Data { try JSONSerialization.data(withJSONObject: ["keys": [key]]) }
        XCTAssertNoThrow(try OIDCVerifier.verify(token, jwks: keys(), for: flow, metadata: metadata, now: Date(timeIntervalSince1970: 100)))
        key["d"] = "synthetic-private-field"
        XCTAssertThrowsError(try OIDCVerifier.verify(token, jwks: keys(), for: flow, metadata: metadata, now: Date(timeIntervalSince1970: 100)))
        key.removeValue(forKey: "d"); key["use"] = "enc"
        XCTAssertThrowsError(try OIDCVerifier.verify(token, jwks: keys(), for: flow, metadata: metadata, now: Date(timeIntervalSince1970: 100)))
    }
}
