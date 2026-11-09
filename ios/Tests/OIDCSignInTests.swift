import XCTest
import Foundation
import CryptoKit
import Security
@testable import AtumNativeAPI

final class OIDCSignInTests: XCTestCase {
    override func tearDown() { MASProtocol.state.reset(); super.tearDown() }

    @MainActor private final class Operations: OIDCKeychainOperations {
        var item: [String: Any]?
        var failAdd = false
        func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
            guard let item else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, item as CFDictionary)
        }
        func add(_ attributes: [String: Any]) -> OSStatus {
            if failAdd { return errSecInteractionNotAllowed }
            guard item == nil else { return errSecDuplicateItem }
            item = attributes; return errSecSuccess
        }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            guard item != nil else { return errSecItemNotFound }
            item?.merge(attributes) { _, new in new }; return errSecSuccess
        }
        func delete(_ query: [String: Any]) -> OSStatus { item = nil; return errSecSuccess }
    }

    @MainActor private final class MatrixOperations: OIDCKeychainOperations {
        var item: [String: Any]?
        func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
            guard let item else { return (errSecItemNotFound, nil) }
            if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                var attributes = item
                attributes.removeValue(forKey: kSecValueData as String)
                return (errSecSuccess, [attributes] as CFArray)
            }
            return (errSecSuccess, item as CFDictionary)
        }
        func add(_ attributes: [String: Any]) -> OSStatus {
            guard item == nil else { return errSecDuplicateItem }
            item = attributes; return errSecSuccess
        }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            guard item != nil else { return errSecItemNotFound }
            item?.merge(attributes) { _, new in new }; return errSecSuccess
        }
        func delete(_ query: [String: Any]) -> OSStatus { XCTFail("Matrix custody must survive domain retry"); return errSecParam }
    }

    private final class PreflightOperations: MatrixKeychainReading, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: Any]] = []
        private var queries: [[String: Any]] = []
        func replace(_ items: [[String: Any]]) { lock.withLock { self.items = items } }
        func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
            lock.withLock {
                queries.append(query)
                guard !items.isEmpty else { return (errSecItemNotFound, nil) }
                if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                    return (errSecSuccess, items.map { item in
                        var attributes = item
                        attributes.removeValue(forKey: kSecValueData as String)
                        return attributes
                    } as CFArray)
                }
                return (errSecSuccess, items[0] as CFDictionary)
            }
        }
        var materialReads: Int {
            lock.withLock { queries.filter { $0[kSecReturnData as String] as? Bool == true }.count }
        }
    }

    @MainActor private final class Fixture {
        let clients: MASPublicClients, metadata: MASMetadata
        let key = P256.Signing.PrivateKey(), flows = OIDCFlows(), operations = Operations()
        let preflight = PreflightOperations()
        let marker: OIDCInstallationMarker, installation: OIDCInstallation
        let transport = MASHTTP(protocols: [MASProtocol.self])
        var issued: [OIDCFlow] = []
        var domainSubject = "synthetic-subject", meSubject = "synthetic-subject"
        var denyDomain = false, revokeStatus = 200
        var domainMeReply: MASProtocol.Reply?
        var onMe: (() -> Void)?
        var beforeDomainCallback: (() throws -> Void)?
        let principal = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        init(directory: URL) throws {
            clients = try .init(matrix: "01JPHNMXPQ7R8S9T0V2W3X4Y5Z", domain: "01JPHNDXPQ7R8S9T0V2W3X4Y5Z")
            metadata = try .decode(JSONSerialization.data(withJSONObject: ["issuer": "https://auth.atum.test/",
                "authorization_endpoint": "https://auth.atum.test/authorize", "token_endpoint": "https://auth.atum.test/token",
                "jwks_uri": "https://auth.atum.test/keys", "revocation_endpoint": "https://auth.atum.test/revoke",
                "id_token_signing_alg_values_supported": ["ES256"], "code_challenge_methods_supported": ["S256"]]),
                expectedIssuer: "https://auth.atum.test/")
            marker = OIDCInstallationMarker(directory: directory)
            installation = try marker.createForExplicitSignIn(generation: UUID())
        }
        func store() -> OIDCDomainKeychain {
            OIDCDomainKeychain(generation: installation.generation, clients: clients, metadata: metadata, operations: operations)
        }
        func reader() -> MatrixSessionReader {
            MatrixSessionReader(clients: clients, metadata: metadata, operations: preflight)
        }
        func custodyTicket(phase: MatrixCustodyRecord.Phase, installationID: UUID? = nil,
                           generation: UUID? = nil, issuer: String? = nil,
                           clientID: String? = nil, subject: String = "synthetic-subject") -> MatrixCustodyTicket {
            let stored = MatrixStoredSession(userID: "@p2-synthetic:atum.invalid", deviceID: "P2-DEVICE",
                homeserver: MatrixAuthenticatedDevice.homeserver, clientID: clientID ?? clients.matrix,
                accessToken: "p2-matrix-access", refreshToken: "p2-matrix-refresh",
                expiresAt: Date().addingTimeInterval(300))
            let key = Data(repeating: 42, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
            let envelope = MatrixCustodyRecord.Envelope(version: 1,
                installationID: installationID ?? installation.id,
                generation: generation ?? installation.generation,
                issuer: issuer ?? metadata.issuer, subject: subject, session: stored,
                passphrase: Data(repeating: 41, count: 32).base64EncodedString(), phase: phase,
                deviceKeys: phase == .ready ? .init(curve: key, ed: key) : nil)
            return MatrixCustodyTicket(envelope: envelope)
        }
        func custodyItem(phase: MatrixCustodyRecord.Phase, installationID: UUID? = nil,
                         generation: UUID? = nil, issuer: String? = nil,
                         clientID: String? = nil, subject: String = "synthetic-subject") throws -> [String: Any] {
            let ticket = custodyTicket(phase: phase, installationID: installationID,
                generation: generation, issuer: issuer, clientID: clientID, subject: subject)
            var item = MatrixCustodyRecord.match
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            item[kSecAttrSynchronizable as String] = false
            item[kSecValueData as String] = try JSONEncoder().encode(ticket.envelope)
            return item
        }
        func coordinator() -> OIDCSignIn {
            OIDCSignIn(clients: clients, metadata: metadata, flows: flows, transport: transport) { [self] flow in
                issued.append(flow)
                if flow.kind == .domain && denyDomain { throw OIDCFailure.authorizationDenied }
                let now = Int64(Date().timeIntervalSince1970)
                let subject = flow.kind == .domain ? domainSubject : "synthetic-subject"
                let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "p2-signin"]).base64URL
                let claims = try JSONSerialization.data(withJSONObject: ["iss": metadata.issuer, "sub": subject,
                    "aud": flow.clientID, "nonce": flow.nonce, "iat": now - 1, "exp": now + 300]).base64URL
                let input = header + "." + claims
                let jwt = input + "." + (try key.signature(for: Data(input.utf8))).rawRepresentation.base64URL
                let scope = URLComponents(url: flow.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "scope" }!.value!
                let response = try JSONSerialization.data(withJSONObject: ["token_type": "Bearer", "expires_in": 120,
                    "access_token": "p2-access-" + flow.clientID, "refresh_token": "p2-refresh-" + flow.clientID,
                    "scope": scope, "id_token": jwt])
                let bytes = key.publicKey.x963Representation
                let keys = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "EC", "kid": "p2-signin",
                    "crv": "P-256", "x": bytes.subdata(in: 1..<33).base64URL, "y": bytes.subdata(in: 33..<65).base64URL]]])
                let whoami = try JSONSerialization.data(withJSONObject: ["user_id": "@p2-synthetic:atum.invalid", "device_id": "P2-DEVICE"])
                let me = try JSONSerialization.data(withJSONObject: ["issuer": metadata.issuer, "subject": meSubject, "principal": principal])
                let tokenURL = metadata.tokenEndpoint, keysURL = metadata.jwksURI, revokeURL = metadata.revocationEndpoint
                let status = revokeStatus, meReply = domainMeReply, observedMe = onMe
                MASProtocol.state.handler = { request in
                    if request.url == tokenURL { return .json(response) }
                    if request.url == keysURL { return .json(keys) }
                    if request.url == MatrixAuthenticatedDevice.whoamiURL { return .json(whoami) }
                    if request.url == MASHTTP.domainMeURL { observedMe?(); return meReply ?? .json(me) }
                    if request.url == revokeURL { return .init(status: status, headers: [:]) }
                    return .init(status: 404)
                }
                if flow.kind == .domain { try beforeDomainCallback?() }
                var callback = URLComponents(url: MASPublicClients.callback, resolvingAgainstBaseURL: false)!
                callback.queryItems = [.init(name: "state", value: flow.state), .init(name: "code", value: "p2-code-" + flow.clientID)]
                return try flows.consume(callback.url!, expectedState: flow.state)
            }
        }
    }

    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("p2-signin-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    private func replacing(_ ticket: MatrixCustodyTicket, installationID: UUID? = nil,
                           generation: UUID? = nil, issuer: String? = nil,
                           clientID: String? = nil, subject: String? = nil) -> MatrixCustodyTicket {
        let original = ticket.envelope
        let session = MatrixStoredSession(userID: original.session.userID,
            deviceID: original.session.deviceID, homeserver: original.session.homeserver,
            clientID: clientID ?? original.session.clientID,
            accessToken: original.session.accessToken, refreshToken: original.session.refreshToken,
            expiresAt: original.session.expiresAt)
        return MatrixCustodyTicket(envelope: .init(version: original.version,
            installationID: installationID ?? original.installationID,
            generation: generation ?? original.generation,
            issuer: issuer ?? original.issuer, subject: subject ?? original.subject,
            session: session, passphrase: original.passphrase, phase: original.phase,
            deviceKeys: original.deviceKeys))
    }

    @MainActor func testFirstSignInRefusesEveryCustodySurvivorBeforeCreatingBrowserFlow() async throws {
        let fixture = try Fixture(directory: directory()), signIn = fixture.coordinator()
        let ready = try fixture.custodyItem(phase: .ready)
        let prepared = try fixture.custodyItem(phase: .prepared)
        var malformed = ready
        malformed[kSecValueData as String] = Data("malformed-custody".utf8)
        var legacy = ready
        legacy[kSecAttrAccount as String] = UUID().uuidString
        let cases: [(String, [[String: Any]])] = [
            ("ready", [ready]), ("prepared", [prepared]),
            ("malformed", [malformed]), ("legacy", [legacy]),
            ("coexisting", [ready, legacy])
        ]

        for (name, survivors) in cases {
            fixture.preflight.replace(survivors)
            do {
                _ = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
                XCTFail("\(name) survivor opened the browser")
            } catch {
                XCTAssertTrue(error is MatrixCustodyFailure, "\(name): \(error)")
            }
            XCTAssertTrue(fixture.issued.isEmpty, name)
            XCTAssertEqual(fixture.flows.activeCount, 0, name)
            XCTAssertTrue(MASProtocol.state.requests.isEmpty, name)
        }
        XCTAssertGreaterThan(fixture.preflight.materialReads, 0)
    }

    @MainActor func testActualTransportTwoGrantsBindBeforeDomainReadinessAndPersistForRelaunch() async throws {
        let fixture = try Fixture(directory: directory()), signIn = fixture.coordinator(), store = fixture.store()
        let matrix = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
        let domain = try await signIn.domain(matrix: matrix, installation: fixture.installation, store: store)
        XCTAssertEqual(domain.binding.principal.rawValue, fixture.principal)
        let restored = try store.resume(installation: fixture.marker)
        XCTAssertEqual(restored.account.subject, "synthetic-subject")
        XCTAssertNoThrow(try restored.account.reconcile(matrix: fixture.custodyTicket(phase: .ready)))
        XCTAssertThrowsError(try restored.account.reconcile(
            matrix: fixture.custodyTicket(phase: .ready, subject: "other-subject")
        )) {
            XCTAssertEqual($0 as? OIDCFailure, .subjectMismatch)
        }
        XCTAssertEqual(matrix.device.deviceID, "P2-DEVICE")
        XCTAssertEqual(fixture.flows.activeCount, 0)
        XCTAssertEqual(fixture.issued.count, 2)
        XCTAssertNotEqual(fixture.issued[0].state, fixture.issued[1].state)
        XCTAssertNotEqual(fixture.issued[0].nonce, fixture.issued[1].nonce)
        XCTAssertNotEqual(fixture.issued[0].verifier, fixture.issued[1].verifier)
        let requests = MASProtocol.state.requests
        XCTAssertEqual(requests.map(\.url), [fixture.metadata.tokenEndpoint, fixture.metadata.jwksURI,
            MatrixAuthenticatedDevice.whoamiURL, fixture.metadata.tokenEndpoint, fixture.metadata.jwksURI, MASHTTP.domainMeURL])
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer p2-access-" + fixture.clients.matrix)
        XCTAssertEqual(requests[5].value(forHTTPHeaderField: "Authorization"), "Bearer p2-access-" + fixture.clients.domain)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Origin") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil })
        XCTAssertEqual(fixture.operations.item?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(fixture.operations.item?[kSecAttrAccessGroup as String] as? String, OIDCDomainKeychain.accessGroup)
        XCTAssertFalse(fixture.operations.item?[kSecAttrSynchronizable as String] as? Bool ?? true)
    }

    @MainActor func testSubjectMismatchRevokesOnlyDomainAndNeverLinks() async throws {
        for mismatch in ["id-token", "me"] {
            MASProtocol.state.reset()
            let fixture = try Fixture(directory: directory()), signIn = fixture.coordinator(), store = fixture.store()
            if mismatch == "id-token" { fixture.domainSubject = "other-subject" }
            else { fixture.meSubject = "other-subject" }
            let matrix = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
            do { _ = try await signIn.domain(matrix: matrix, installation: fixture.installation, store: store); XCTFail("Mismatch linked") }
            catch { XCTAssertEqual(error as? OIDCFailure, .subjectMismatch) }
            let requests = MASProtocol.state.requests, revocations = requests.filter { $0.url == fixture.metadata.revocationEndpoint }
            XCTAssertEqual(revocations.count, 2)
            XCTAssertEqual(requests.filter { $0.url == MASHTTP.domainMeURL }.count, mismatch == "id-token" ? 0 : 1)
            XCTAssertNil(try store.load()); XCTAssertNil(fixture.operations.item)
            XCTAssertEqual(try fixture.marker.load(), fixture.installation)
            XCTAssertEqual(matrix.device.userID, "@p2-synthetic:atum.invalid")
            XCTAssertEqual(fixture.flows.activeCount, 0)
        }
    }

    @MainActor func testFailedRevocationSurvivesNewStoreAndRefusesExposureOrRemovalUntilAck() async throws {
        let fixture = try Fixture(directory: directory()), signIn = fixture.coordinator(), store = fixture.store()
        fixture.meSubject = "other-subject"; fixture.revokeStatus = 503
        let matrix = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
        do { _ = try await signIn.domain(matrix: matrix, installation: fixture.installation, store: store); XCTFail("Mismatch linked") }
        catch { XCTAssertEqual(error as? OIDCFailure, .subjectMismatch) }
        let raw = try XCTUnwrap(fixture.operations.item?[kSecValueData as String] as? Data)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        XCTAssertEqual(envelope["revoking"] as? Bool, true)
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(envelope["grant"]))
        let record = try JSONDecoder().decode(OIDCStoredGrant.self, from: data)
        let revocations = try MASHTTP.domainRevocationRequests(record, metadata: fixture.metadata)
        XCTAssertEqual(revocations.map { String(decoding: $0.httpBody!, as: UTF8.self) }, [
            "client_id=\(fixture.clients.domain)&token=p2-refresh-\(fixture.clients.domain)&token_type_hint=refresh_token",
            "client_id=\(fixture.clients.domain)&token=p2-access-\(fixture.clients.domain)&token_type_hint=access_token"])
        XCTAssertTrue(revocations.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Authorization") == nil })
        let next = fixture.store()
        XCTAssertThrowsError(try next.load())
        XCTAssertThrowsError(try next.resume(installation: fixture.marker))
        XCTAssertThrowsError(try next.remove())
        let before = fixture.issued.count
        do { _ = try await signIn.domain(matrix: matrix, installation: fixture.installation, store: next); XCTFail("Pending grant overwritten") }
        catch { XCTAssertEqual(error as? OIDCGrantFailure, .reauthenticationRequired) }
        XCTAssertEqual(fixture.issued.count, before)
        MASProtocol.state.reset()
        MASProtocol.state.handler = { _ in .init(headers: [:]) }
        try await next.revokeUnbound(using: fixture.transport)
        XCTAssertEqual(MASProtocol.state.requests.count, 2)
        XCTAssertTrue(MASProtocol.state.requests.allSatisfy { $0.url == fixture.metadata.revocationEndpoint })
        XCTAssertNil(try next.load())
        try await fixture.store().revokeUnbound(using: fixture.transport)
        XCTAssertEqual(MASProtocol.state.requests.count, 2) // No duplicate cleanup after removal.
        XCTAssertEqual(matrix.device.deviceID, "P2-DEVICE")
    }

    @MainActor func testDeniedDomainBrowserKeepsVerifiedMatrixAndDoesNotCreateDomainRecord() async throws {
        let fixture = try Fixture(directory: directory()), signIn = fixture.coordinator(), store = fixture.store()
        let matrix = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
        fixture.denyDomain = true
        do { _ = try await signIn.domain(matrix: matrix, installation: fixture.installation, store: store); XCTFail("Denied browser linked") }
        catch { XCTAssertEqual(error as? OIDCFailure, .authorizationDenied) }
        XCTAssertNil(try store.load()); XCTAssertEqual(fixture.flows.activeCount, 0)
        XCTAssertEqual(MASProtocol.state.requests.count, 3)
        XCTAssertEqual(matrix.device.deviceID, "P2-DEVICE")
    }

    @MainActor func testDeniedDomainCanRetryFromReadyMatrixCustodyAfterTransientGrantIsDiscarded() async throws {
        let fixture = try Fixture(directory: directory())
        let signIn = fixture.coordinator()
        let matrix = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
        let operations = MatrixOperations()
        let matrixStore = MatrixSessionKeychain(generation: fixture.installation.generation,
            clients: fixture.clients, metadata: fixture.metadata, operations: operations)
        let prepared = try matrixStore.prepare(device: matrix.device, marker: fixture.marker,
            requestStartedAt: matrix.delivery.requestStartedAt)
        let key = Data(repeating: 42, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let ready = try matrixStore.commitPrepared(prepared, marker: fixture.marker,
            curve25519: key, ed25519: key)

        fixture.denyDomain = true
        do {
            _ = try await signIn.domain(matrix: ready, installation: fixture.installation, store: fixture.store())
            XCTFail("Denied domain browser linked")
        } catch { XCTAssertEqual(error as? OIDCFailure, .authorizationDenied) }
        XCTAssertNil(try fixture.store().load())

        fixture.denyDomain = false
        let resumed = try await signIn.domain(matrix: ready, installation: fixture.installation, store: fixture.store())
        XCTAssertEqual(resumed.binding.principal.rawValue, fixture.principal)
        XCTAssertEqual(ready.session.userID, "@p2-synthetic:atum.invalid")
        XCTAssertNotNil(operations.item)
        XCTAssertEqual(fixture.issued.filter { $0.kind == .domain }.count, 2)
    }

    @MainActor func testCustodyRetryRejectsPreparedForeignInstallationAndProviderIdentityBeforeBrowser() async throws {
        let fixture = try Fixture(directory: directory()), signIn = fixture.coordinator()
        let matrix = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
        let operations = MatrixOperations()
        let matrixStore = MatrixSessionKeychain(generation: fixture.installation.generation,
            clients: fixture.clients, metadata: fixture.metadata, operations: operations)
        let prepared = try matrixStore.prepare(device: matrix.device, marker: fixture.marker,
            requestStartedAt: matrix.delivery.requestStartedAt)
        let key = Data(repeating: 42, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let ready = try matrixStore.commitPrepared(prepared, marker: fixture.marker,
            curve25519: key, ed25519: key)
        let matrixRecord = operations.item?[kSecValueData as String] as? Data
        let before = fixture.issued.count

        do {
            _ = try await signIn.domain(matrix: prepared, installation: fixture.installation, store: fixture.store())
            XCTFail("Prepared custody opened a browser")
        } catch { XCTAssertEqual(error as? MatrixCustodyFailure, .interruptedPreparation) }

        for (name, ticket) in [
            ("installation", replacing(ready, installationID: UUID())),
            ("generation", replacing(ready, generation: UUID()))
        ] {
            do {
                _ = try await signIn.domain(matrix: ticket, installation: fixture.installation, store: fixture.store())
                XCTFail("Foreign \(name) opened a browser")
            } catch { XCTAssertEqual(error as? MatrixCustodyFailure, .recoveryRequired, name) }
        }
        for (name, ticket) in [
            ("issuer", replacing(ready, issuer: "https://foreign.invalid/")),
            ("client", replacing(ready, clientID: fixture.clients.domain))
        ] {
            do {
                _ = try await signIn.domain(matrix: ticket, installation: fixture.installation, store: fixture.store())
                XCTFail("Foreign \(name) opened a browser")
            } catch { XCTAssertEqual(error as? OIDCGrantFailure, .invalidIdentity, name) }
        }
        XCTAssertEqual(fixture.issued.count, before)
        XCTAssertEqual(operations.item?[kSecValueData as String] as? Data, matrixRecord)
        XCTAssertNil(try fixture.store().load())
    }

    @MainActor func testCustodyRetrySubjectAndMeMismatchRevokeOnlyDomainAndPreserveMatrix() async throws {
        let fixture = try Fixture(directory: directory()), signIn = fixture.coordinator()
        let matrix = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
        let operations = MatrixOperations()
        let matrixStore = MatrixSessionKeychain(generation: fixture.installation.generation,
            clients: fixture.clients, metadata: fixture.metadata, operations: operations)
        let prepared = try matrixStore.prepare(device: matrix.device, marker: fixture.marker,
            requestStartedAt: matrix.delivery.requestStartedAt)
        let key = Data(repeating: 42, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let ready = try matrixStore.commitPrepared(prepared, marker: fixture.marker,
            curve25519: key, ed25519: key)
        let matrixRecord = operations.item?[kSecValueData as String] as? Data

        for mismatch in ["id-token", "me"] {
            MASProtocol.state.reset()
            fixture.domainSubject = mismatch == "id-token" ? "foreign-subject" : "synthetic-subject"
            fixture.meSubject = mismatch == "me" ? "foreign-subject" : "synthetic-subject"
            do {
                _ = try await signIn.domain(matrix: ready, installation: fixture.installation, store: fixture.store())
                XCTFail("\(mismatch) mismatch linked")
            } catch { XCTAssertEqual(error as? OIDCFailure, .subjectMismatch) }
            let requests = MASProtocol.state.requests
            XCTAssertEqual(requests.filter { $0.url == fixture.metadata.revocationEndpoint }.count, 2)
            XCTAssertEqual(requests.filter { $0.url == MASHTTP.domainMeURL }.count,
                           mismatch == "id-token" ? 0 : 1)
            XCTAssertNil(try fixture.store().load())
            XCTAssertEqual(operations.item?[kSecValueData as String] as? Data, matrixRecord)
        }
    }

    @MainActor func testSecondRevocationFailureKeepsJournalAndExplicitReplayRetriesBothTokens() async throws {
        let fixture = try Fixture(directory: directory()), signIn = fixture.coordinator(), store = fixture.store()
        let matrix = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
        fixture.meSubject = "other-subject"; fixture.revokeStatus = 503
        do { _ = try await signIn.domain(matrix: matrix, installation: fixture.installation, store: store) }
        catch { XCTAssertEqual(error as? OIDCFailure, .subjectMismatch) }
        MASProtocol.state.reset()
        MASProtocol.state.handler = { _ in
            .init(status: MASProtocol.state.requests.count == 1 ? 200 : 503, headers: [:])
        }
        do { try await fixture.store().revokeUnbound(using: fixture.transport); XCTFail("Partial cleanup removed journal") }
        catch { XCTAssertEqual(error as? MASHTTPFailure, .httpStatus(503)) }
        XCTAssertThrowsError(try store.load())
        XCTAssertNotNil(fixture.operations.item)
        MASProtocol.state.reset(); MASProtocol.state.handler = { _ in .init(headers: [:]) }
        try await fixture.store().revokeUnbound(using: fixture.transport)
        XCTAssertEqual(MASProtocol.state.requests.count, 2)
        XCTAssertNil(try store.load())
    }

    @MainActor func testCancellationAfterGrantCannotBindAndCleanupRunsOutsideCancelledTask() async throws {
        let fixture = try Fixture(directory: directory()), signIn = fixture.coordinator(), store = fixture.store()
        let matrix = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
        let started = expectation(description: "Authenticated me started")
        fixture.domainMeReply = .init(held: true); fixture.onMe = { started.fulfill() }
        let attempt = Task { try await signIn.domain(matrix: matrix, installation: fixture.installation, store: store) }
        await fulfillment(of: [started], timeout: 2)
        attempt.cancel()
        do { _ = try await attempt.value; XCTFail("Cancelled flow became ready") }
        catch { XCTAssertEqual(error as? MASHTTPFailure, .cancelled) }
        XCTAssertNil(try store.load())
        XCTAssertEqual(MASProtocol.state.requests.filter { $0.url == fixture.metadata.revocationEndpoint }.count, 2)
        XCTAssertEqual(matrix.device.deviceID, "P2-DEVICE")
    }

    @MainActor func testStorageFailureNeverSendsMeOrExposesDomainReadiness() async throws {
        let fixture = try Fixture(directory: directory()), signIn = fixture.coordinator(), store = fixture.store()
        let matrix = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
        fixture.operations.failAdd = true
        do { _ = try await signIn.domain(matrix: matrix, installation: fixture.installation, store: store); XCTFail("Failed storage became ready") }
        catch { XCTAssertEqual(error as? OIDCGrantFailure, .storageUnavailable) }
        XCTAssertFalse(MASProtocol.state.requests.contains { $0.url == MASHTTP.domainMeURL })
        XCTAssertEqual(MASProtocol.state.requests.filter { $0.url == fixture.metadata.revocationEndpoint }.count, 2)
        XCTAssertNil(fixture.operations.item)
    }

    @MainActor func testAnotherAttemptPublishedDuringBrowserIsNeverRevokedByRefusedInstallation() async throws {
        let fixture = try Fixture(directory: directory()), signIn = fixture.coordinator(), store = fixture.store()
        let matrix = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
        let existing = OIDCStoredGrant(generation: fixture.installation.generation, issuer: fixture.metadata.issuer,
            clientID: fixture.clients.domain, subject: "other-in-flight-subject", accessToken: "other-access",
            refreshToken: "other-refresh", expiresAt: Date().addingTimeInterval(120), phase: .ready, attempt: nil)
        fixture.beforeDomainCallback = { try store.save(existing) }
        do { _ = try await signIn.domain(matrix: matrix, installation: fixture.installation, store: store); XCTFail("Foreign record replaced") }
        catch { XCTAssertEqual(error as? OIDCGrantFailure, .invalidIdentity) }
        XCTAssertEqual(try store.load(), existing)
        XCTAssertEqual(MASProtocol.state.requests.filter { $0.url == fixture.metadata.revocationEndpoint }.count, 2)
        XCTAssertFalse(MASProtocol.state.requests.contains { $0.url == MASHTTP.domainMeURL })
        XCTAssertEqual(matrix.device.deviceID, "P2-DEVICE")
    }

    @MainActor func testMatrixGrantCannotAuthorizeDomainReadAndRedirectDoesNotLeakBearer() async throws {
        let fixture = try Fixture(directory: directory()), signIn = fixture.coordinator()
        let matrix = try await signIn.matrix(deviceID: "P2-DEVICE", sessionReader: fixture.reader())
        MASProtocol.state.reset()
        do { _ = try await fixture.transport.domainMe(grant: matrix.delivery.grant); XCTFail("Matrix grant admitted") }
        catch { XCTAssertEqual(error as? OIDCGrantFailure, .invalidIdentity) }
        XCTAssertTrue(MASProtocol.state.requests.isEmpty)
        fixture.domainMeReply = .init(redirect: URL(string: "https://foreign.test/token-target")!)
        do { _ = try await signIn.domain(matrix: matrix, installation: fixture.installation, store: fixture.store()); XCTFail("Redirect followed") }
        catch { XCTAssertEqual(error as? MASHTTPFailure, .redirectRefused) }
        XCTAssertFalse(MASProtocol.state.requests.contains { $0.url?.host == "foreign.test" })
    }
}
