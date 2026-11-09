import XCTest
import Foundation
import CryptoKit
@testable import AtumNativeAPI

/// These responses never leave URLSession's synthetic .test protocol handler.
final class MASHTTPTests: XCTestCase {
    private let issuer = "https://auth.atum.test/"
    private func document() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["issuer": issuer,
            "authorization_endpoint": issuer + "authorize", "token_endpoint": issuer + "token",
            "jwks_uri": issuer + "keys", "revocation_endpoint": issuer + "revoke",
            "id_token_signing_alg_values_supported": ["ES256"], "code_challenge_methods_supported": ["S256"]])
    }
    private func metadata() throws -> MASMetadata { try .decode(document(), expectedIssuer: issuer) }
    private func http() -> MASHTTP { MASHTTP(protocols: [MASProtocol.self]) }
    private func post() throws -> URLRequest {
        var request = URLRequest(url: try metadata().tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("grant_type=refresh_token&client_id=synthetic&refresh_token=p2-not-a-token".utf8)
        return request
    }
    private func reply(_ id: String? = nil) throws -> Data {
        var object: [String: Any] = ["token_type": "Bearer", "access_token": "p2-not-an-access-token",
            "refresh_token": "p2-not-a-refresh-token", "expires_in": 120, "scope": "openid"]
        object["id_token"] = id
        return try JSONSerialization.data(withJSONObject: object)
    }
    override func tearDown() { MASProtocol.state.reset(); super.tearDown() }

    func testPublicDiscoveryUsesExactIssuerAndNoAmbientCredentials() async throws {
        let url = URL(string: issuer + "discovery")!, data = try document()
        let cookie = HTTPCookie(properties: [.domain: "auth.atum.test", .path: "/", .name: "p2", .value: "not-a-cookie-secret", .secure: "TRUE"])!
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        MASProtocol.state.handler = { request in
            XCTAssertEqual(request.url, url)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            return .json(data)
        }
        let value = try await http().discovery(at: url, expectedIssuer: issuer)
        XCTAssertEqual(value.issuer, issuer)
        do { _ = try await http().discovery(at: url, expectedIssuer: "https://foreign.test/"); XCTFail("Untrusted issuer accepted") }
        catch { XCTAssertEqual(error as? OIDCFailure, .invalidConfiguration) }
    }

    @MainActor func testMatrixWhoamiBindsExactGrantAndDeviceWithoutRedirectOrAmbientAuth() async throws {
        let grant = try MatrixCustodyTests.grant()
        let response = try JSONSerialization.data(withJSONObject: ["user_id": "@p2-synthetic:atum.invalid", "device_id": "P2-SYNTHETIC"])
        MASProtocol.state.handler = { request in
            XCTAssertEqual(request.url, MatrixAuthenticatedDevice.whoamiURL)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + grant.response.accessToken)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie")); XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.httpBody); return .json(response)
        }
        let receipt = try await http().matrixWhoami(grant: grant)
        XCTAssertEqual(receipt.deviceID, "P2-SYNTHETIC")
        XCTAssertEqual(receipt.grant.response.accessToken, grant.response.accessToken)
        MASProtocol.state.handler = { _ in .init(redirect: URL(string: "https://foreign.test/whoami")) }
        do { _ = try await http().matrixWhoami(grant: grant); XCTFail("Credential redirect accepted") }
        catch { XCTAssertEqual(error as? MASHTTPFailure, .redirectRefused) }
        XCTAssertFalse(MASProtocol.state.requests.contains { $0.url?.host == "foreign.test" })
        for data in [try JSONSerialization.data(withJSONObject: ["user_id": "@p2-synthetic:atum.invalid", "device_id": "OTHER"]),
                     try JSONSerialization.data(withJSONObject: ["user_id": "@p2-synthetic:atum.invalid", "device_id": "P2-SYNTHETIC", "is_guest": true])] {
            MASProtocol.state.handler = { _ in .json(data) }
            do { _ = try await http().matrixWhoami(grant: grant); XCTFail("Wrong device accepted") }
            catch { XCTAssertEqual(error as? OIDCFailure, .deviceMismatch) }
        }
        MASProtocol.state.reset()
        let domain = try MatrixCustodyTests.grant(.domain)
        do { _ = try await http().matrixWhoami(grant: domain); XCTFail("Domain grant used for Matrix") }
        catch { XCTAssertEqual(error as? OIDCFailure, .deviceMismatch) }
        XCTAssertTrue(MASProtocol.state.requests.isEmpty)
    }

    func testInvalidRequestsNeverReachTransport() async throws {
        MASProtocol.state.handler = { _ in XCTFail("Invalid request reached transport"); return .json(Data()) }
        for value in ["http://auth.atum.test/discovery", "https://user:pass@auth.atum.test/discovery", issuer + "discovery?secret=synthetic", issuer + "discovery#fragment"] {
            do { _ = try await http().discovery(at: URL(string: value)!, expectedIssuer: issuer); XCTFail("Invalid discovery accepted") }
            catch { XCTAssertEqual(error as? MASHTTPFailure, .invalidRequest) }
        }
        for header in ["Cookie", "Authorization", "Origin", "Content-Type"] {
            var request = try post(); request.setValue("synthetic", forHTTPHeaderField: header)
            do { _ = try await http().refresh(request, metadata: metadata()); XCTFail("Invalid header accepted") }
            catch { XCTAssertEqual(error as? MASHTTPFailure, .invalidRequest) }
        }
        for body in [Data(), Data(repeating: 120, count: 65_537)] {
            var request = try post(); request.httpBody = body
            do { _ = try await http().refresh(request, metadata: metadata()); XCTFail("Invalid body accepted") }
            catch { XCTAssertEqual(error as? MASHTTPFailure, .invalidRequest) }
        }
        var stream = try post(); stream.httpBodyStream = InputStream(data: Data("synthetic".utf8))
        do { _ = try await http().refresh(stream, metadata: metadata()); XCTFail("Caller body stream accepted") }
        catch { XCTAssertEqual(error as? MASHTTPFailure, .invalidRequest) }
        XCTAssertTrue(MASProtocol.state.requests.isEmpty)
    }

    func testStatusURLContentTypeAndStreamingSizeBoundaries() async throws {
        let url = URL(string: issuer + "discovery")!, good = try document()
        let variants: [(MASProtocol.Reply, MASHTTPFailure)] = [
            (.init(status: 429, chunks: [Data("private server error".utf8)]), .httpStatus(429)),
            (.init(headers: ["Content-Type": "text/html"], chunks: [good]), .invalidResponse),
            (.init(headers: ["Content-Type": "application/json", "Content-Length": "-1"], chunks: []), .invalidResponse),
            (.init(headers: ["Content-Type": "application/json", "Content-Length": "262145"], chunks: []), .responseTooLarge),
            (.init(chunks: [Data(repeating: 120, count: 131_072), Data(repeating: 120, count: 131_073)]), .responseTooLarge),
            (.init(chunks: [good], responseURL: URL(string: "https://foreign.test/discovery")), .invalidResponse),
            (.init(chunks: [], error: URLError(.networkConnectionLost)), .transportUnavailable),
        ]
        for (reply, expected) in variants {
            MASProtocol.state.handler = { _ in reply }
            do { _ = try await http().discovery(at: url, expectedIssuer: issuer); XCTFail("Invalid reply accepted") }
            catch { XCTAssertEqual(error as? MASHTTPFailure, expected) }
        }
        XCTAssertFalse(String(describing: MASHTTPFailure.httpStatus(429)).contains("private server error"))
    }

    func testRedirectNeverSendsRequestToRedirectTarget() async throws {
        let target = URL(string: "https://foreign.test/secret-target")!
        MASProtocol.state.handler = { _ in .init(redirect: target) }
        do { _ = try await http().discovery(at: URL(string: issuer + "discovery")!, expectedIssuer: issuer); XCTFail("Redirect accepted") }
        catch { XCTAssertEqual(error as? MASHTTPFailure, .redirectRefused) }
        do { _ = try await http().refresh(post(), metadata: metadata()); XCTFail("Token POST redirect accepted") }
        catch { XCTAssertEqual(error as? MASHTTPFailure, .redirectRefused) }
        XCTAssertTrue(MASProtocol.state.requests.allSatisfy { $0.url?.host == "auth.atum.test" })
    }

    func testCancellationFinishesPendingRequestAndDoesNotRetry() async throws {
        let started = expectation(description: "URLSession started")
        MASProtocol.state.handler = { _ in started.fulfill(); return .init(held: true) }
        let task = Task { try await self.http().discovery(at: URL(string: self.issuer + "discovery")!, expectedIssuer: self.issuer) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled operation released data") }
        catch { XCTAssertEqual(error as? MASHTTPFailure, .cancelled) }
        XCTAssertEqual(MASProtocol.state.requests.count, 1)
        let cancelledBeforeStart = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.http().discovery(at: URL(string: self.issuer + "discovery")!, expectedIssuer: self.issuer)
        }
        do { _ = try await cancelledBeforeStart.value; XCTFail("Pre-cancelled operation started") }
        catch { XCTAssertEqual(error as? MASHTTPFailure, .cancelled) }
        XCTAssertEqual(MASProtocol.state.requests.count, 1)
    }

    func testOneShotBodyKeepsExactFormAndRefusesSecondStream() throws {
        let expected = try post().httpBody!, body = MASOneShotBody(expected)
        let stream = try XCTUnwrap(body.consume()); stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 13)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            XCTAssertGreaterThanOrEqual(count, 0)
            if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertEqual(result, expected)
        XCTAssertNil(body.consume())
        let cleared = MASOneShotBody(expected); cleared.clear(); XCTAssertNil(cleared.consume())
    }

    func testRefreshWithoutIDTokenDoesNotFetchKeysAndFailureIsNotRetried() async throws {
        let metadata = try metadata(), data = try reply()
        let expectedForm = try post().httpBody!
        MASProtocol.state.handler = { request in
            XCTAssertEqual(request.url, metadata.tokenEndpoint)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var received = Data(), buffer = [UInt8](repeating: 0, count: 17)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }; received.append(contentsOf: buffer.prefix(count))
                }
                XCTAssertEqual(received, expectedForm)
            } else { XCTFail("Streamed POST body not delivered to URLProtocol") }
            return .json(data)
        }
        let result = try await http().refresh(post(), metadata: metadata)
        XCTAssertEqual(result.response.accessToken, "p2-not-an-access-token")
        XCTAssertTrue(result.jwks.isEmpty)
        XCTAssertEqual(MASProtocol.state.requests.map(\.url), [metadata.tokenEndpoint])
        MASProtocol.state.reset()
        MASProtocol.state.handler = { _ in .init(status: 503) }
        do { _ = try await http().refresh(post(), metadata: metadata); XCTFail("Failure released a reply") }
        catch { XCTAssertEqual(error as? MASHTTPFailure, .httpStatus(503)) }
        XCTAssertEqual(MASProtocol.state.requests.map(\.url), [metadata.tokenEndpoint])
    }

    @MainActor func testExchangeVerifiesDeliveredTokenAndUsesConservativeTiming() async throws {
        let metadata = try metadata(), flows = OIDCFlows(), key = P256.Signing.PrivateKey()
        let clients = try MASPublicClients(matrix: "01JPHNMXPQ7R8S9T0V2W3X4Y5Z", domain: "01JPHNDXPQ7R8S9T0V2W3X4Y5Z")
        let flow = try flows.begin(.domain, clients: clients, metadata: metadata)
        var url = URLComponents(url: MASPublicClients.callback, resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "state", value: flow.state), .init(name: "code", value: "p2-not-a-code + 🌗")]
        let accepted = try flows.consume(url.url!)
        let now = Int(Date().timeIntervalSince1970)
        let claims: [String: Any] = ["iss": flow.issuer, "sub": "p2-synthetic", "aud": flow.clientID,
            "nonce": flow.nonce, "iat": now, "exp": now + 300]
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "ephemeral", "typ": "JWT"]).base64URL
        let encoded = try JSONSerialization.data(withJSONObject: claims).base64URL
        let input = header + "." + encoded
        let token = input + "." + (try key.signature(for: Data(input.utf8))).rawRepresentation.base64URL
        let pub = key.publicKey.x963Representation
        let keys = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "EC", "kid": "ephemeral", "alg": "ES256", "use": "sig", "crv": "P-256",
            "x": pub.subdata(in: 1..<33).base64URL, "y": pub.subdata(in: 33..<65).base64URL]]])
        let data = try reply(token)
        MASProtocol.state.handler = { request in
            if request.url == metadata.tokenEndpoint { return .json(data) }
            XCTAssertEqual(request.url, metadata.jwksURI); return .json(keys)
        }
        let before = Date(), delivery = try await http().exchange(accepted, metadata: metadata), after = Date()
        XCTAssertEqual(delivery.grant.identity.subject, "p2-synthetic")
        XCTAssertTrue(before <= delivery.requestStartedAt && delivery.requestStartedAt <= delivery.responseReceivedAt && delivery.responseReceivedAt <= after)
        XCTAssertEqual(MASProtocol.state.requests.map(\.url), [metadata.tokenEndpoint, metadata.jwksURI])
        XCTAssertFalse(String(reflecting: delivery).contains(token))
        // An altered key cannot turn the same network response into authority.
        let wrong = P256.Signing.PrivateKey().publicKey.x963Representation
        let wrongKeys = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "EC", "kid": "ephemeral", "alg": "ES256", "use": "sig", "crv": "P-256",
            "x": wrong.subdata(in: 1..<33).base64URL, "y": wrong.subdata(in: 33..<65).base64URL]]])
        MASProtocol.state.handler = { request in .json(request.url == metadata.tokenEndpoint ? data : wrongKeys) }
        do { _ = try await http().exchange(accepted, metadata: metadata); XCTFail("Wrong signing key accepted") }
        catch { XCTAssertEqual(error as? OIDCFailure, .invalidSignature) }

        // The concrete HTTP boundary cannot release/reuse the old grant after
        // an ambiguous refresh. The persisted journal, not a transport retry,
        // decides what can be exposed to a caller.
        let store = MemoryStore()
        let controller = try OIDCGrantRefresh(store: store, metadata: metadata, grant: delivery.grant,
            generation: UUID(), kind: .domain, clients: clients)
        try controller.install(now: delivery.requestStartedAt)
        XCTAssertEqual(try XCTUnwrap(store.record?.expiresAt).timeIntervalSince(delivery.requestStartedAt), 120, accuracy: 0.000001)
        MASProtocol.state.reset()
        MASProtocol.state.handler = { _ in .init(status: 503) }
        let transport = http()
        let exchange: OIDCGrantRefresh.Exchange = { request in try await transport.refresh(request, metadata: metadata) }
        for _ in 0..<2 {
            do { _ = try await controller.refresh(now: delivery.requestStartedAt.addingTimeInterval(121), exchange: exchange); XCTFail("Ambiguous refresh released credentials") }
            catch { XCTAssertEqual(error as? OIDCGrantFailure, .reauthenticationRequired) }
            XCTAssertEqual(store.record?.phase, .spending)
            XCTAssertEqual(store.record?.refreshToken, "p2-not-a-refresh-token")
        }
        XCTAssertEqual(MASProtocol.state.requests.map(\.url), [metadata.tokenEndpoint])

        // A refreshed ID token expired after the request's conservative clock
        // must be checked at actual delivery, not accepted at request start.
        let secondStore = MemoryStore()
        let second = try OIDCGrantRefresh(store: secondStore, metadata: metadata, grant: delivery.grant,
            generation: UUID(), kind: .domain, clients: clients)
        try second.install(now: delivery.requestStartedAt.addingTimeInterval(-120))
        var expiredClaims = claims; expiredClaims.removeValue(forKey: "nonce")
        expiredClaims["iat"] = now - 100; expiredClaims["exp"] = now - 30
        let expiredInput = header + "." + (try JSONSerialization.data(withJSONObject: expiredClaims)).base64URL
        let expiredJWT = expiredInput + "." + (try key.signature(for: Data(expiredInput.utf8))).rawRepresentation.base64URL
        var expiredReply = try JSONSerialization.jsonObject(with: reply(expiredJWT)) as! [String: Any]
        expiredReply["refresh_token"] = "p2-not-a-rotated-refresh-token"
        let expiredData = try JSONSerialization.data(withJSONObject: expiredReply)
        MASProtocol.state.reset()
        MASProtocol.state.handler = { request in .json(request.url == metadata.tokenEndpoint ? expiredData : keys) }
        do { _ = try await second.refresh(now: delivery.requestStartedAt.addingTimeInterval(-60), exchange: exchange); XCTFail("Delivery-expired ID token accepted") }
        catch { XCTAssertEqual(error as? OIDCGrantFailure, .invalidResponse) }
        XCTAssertEqual(secondStore.record?.phase, .spending)
        XCTAssertEqual(secondStore.record?.refreshToken, "p2-not-a-refresh-token")
        XCTAssertEqual(MASProtocol.state.requests.map(\.url), [metadata.tokenEndpoint, metadata.jwksURI])
    }

    @MainActor private final class MemoryStore: OIDCGrantStore {
        var record: OIDCStoredGrant?
        func load() throws -> OIDCStoredGrant? { record }
        func save(_ value: OIDCStoredGrant) throws { record = value }
    }
}

final class MASProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: @unchecked Sendable {
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var chunks: [Data] = []
        var responseURL: URL? = nil
        var error: Error? = nil
        var redirect: URL? = nil
        var held = false
        static func json(_ data: Data) -> Self { .init(chunks: [data]) }
    }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var block: ((URLRequest) -> Reply)?
        private var observed: [URLRequest] = []
        var handler: ((URLRequest) -> Reply)? {
            get { lock.withLock { block } }
            set { lock.withLock { block = newValue } }
        }
        var requests: [URLRequest] { lock.withLock { observed } }
        func receive(_ request: URLRequest) -> Reply {
            let action = lock.withLock { observed.append(request); return block }
            return action?(request) ?? .init(error: URLError(.unsupportedURL))
        }
        func reset() { lock.withLock { block = nil; observed = [] } }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "auth.atum.test" || request.url?.host == "foreign.test" || request.url == MatrixAuthenticatedDevice.whoamiURL || request.url == MASHTTP.domainMeURL }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.receive(request)
        if reply.held { return }
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        if let target = reply.redirect {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response); return
        }
        let response = HTTPURLResponse(url: reply.responseURL ?? request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for data in reply.chunks { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
