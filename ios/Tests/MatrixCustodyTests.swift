import XCTest
import Foundation
import Security
import CryptoKit
@testable import AtumNativeAPI

final class MatrixCustodyTests: XCTestCase {
    @MainActor private final class Operations: OIDCKeychainOperations {
        var item: [String: Any]?
        var calls: [String] = []
        var failure: String?
        var failingUpdateNumber: Int?
        func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
            calls.append("copy")
            if failure == "copy" { return (errSecInteractionNotAllowed, nil) }
            if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                return item.map { (errSecSuccess, [$0] as CFArray) } ?? (errSecItemNotFound, nil)
            }
            return item.map { (errSecSuccess, $0 as CFDictionary) } ?? (errSecItemNotFound, nil)
        }
        func add(_ attributes: [String: Any]) -> OSStatus {
            calls.append("add")
            if failure == "add" { return errSecInteractionNotAllowed }
            guard item == nil else { return errSecDuplicateItem }
            item = attributes; return errSecSuccess
        }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            calls.append("update")
            let updateNumber = calls.filter { $0 == "update" }.count
            if failure == "update" || failingUpdateNumber == updateNumber { return errSecInteractionNotAllowed }
            if failure == "readback" { item = nil; return errSecSuccess }
            item?.merge(attributes) { _, v in v }; return errSecSuccess
        }
        func delete(_ query: [String: Any]) -> OSStatus { calls.append("delete"); XCTFail("Custody must not delete survivors"); return errSecParam }
    }
    private static func clients() throws -> MASPublicClients { try .init(matrix: "01JPHNMXPQ7R8S9T0V2W3X4Y5Z", domain: "01JPHNDXPQ7R8S9T0V2W3X4Y5Z") }
    private static func metadata() throws -> MASMetadata {
        try .decode(JSONSerialization.data(withJSONObject: ["issuer": "https://auth.atum.test/",
            "authorization_endpoint": "https://auth.atum.test/authorize", "token_endpoint": "https://auth.atum.test/token",
            "jwks_uri": "https://auth.atum.test/keys", "revocation_endpoint": "https://auth.atum.test/revoke",
            "id_token_signing_alg_values_supported": ["ES256"], "code_challenge_methods_supported": ["S256"]]), expectedIssuer: "https://auth.atum.test/")
    }
    @MainActor static func grant(_ kind: OIDCFlow.Kind = .matrix(deviceID: "P2-SYNTHETIC"), scope: String? = nil) throws -> OIDCVerifiedGrant {
        let flows = OIDCFlows(), key = P256.Signing.PrivateKey(), m = try Self.metadata()
        let flow = try flows.begin(kind, clients: Self.clients(), metadata: m)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "p2"]).base64URL
        let claims = try JSONSerialization.data(withJSONObject: ["iss": m.issuer, "sub": "synthetic-subject", "aud": flow.clientID,
            "nonce": flow.nonce, "iat": 0, "exp": 3600]).base64URL
        let input = header + "." + claims
        let jwt = input + "." + (try key.signature(for: Data(input.utf8))).rawRepresentation.base64URL
        let publicKey = key.publicKey.x963Representation
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "EC", "kid": "p2", "crv": "P-256",
            "x": publicKey.subdata(in: 1..<33).base64URL, "y": publicKey.subdata(in: 33..<65).base64URL]]])
        var url = URLComponents(url: MASPublicClients.callback, resolvingAgainstBaseURL: false)!
        url.queryItems = [.init(name: "state", value: flow.state), .init(name: "code", value: "synthetic-code")]
        let callback = try flows.consume(url.url!)
        var response: [String: Any] = ["token_type": "Bearer", "access_token": "p2-not-an-access-token",
            "refresh_token": "p2-not-a-refresh-token", "expires_in": 200, "id_token": jwt]
        response["scope"] = scope
        return try callback.verifyGrant(.decode(JSONSerialization.data(withJSONObject: response)), jwks: jwks, metadata: m, now: Date(timeIntervalSince1970: 100))
    }
    func whoami(_ device: String = "P2-SYNTHETIC", guest: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["user_id": "@p2-synthetic:atum.invalid", "device_id": device, "is_guest": guest])
    }
    @MainActor private func setup() throws -> (Operations, MatrixSessionKeychain, OIDCInstallationMarker, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), generation = UUID()
        let marker = OIDCInstallationMarker(directory: directory)
        _ = try marker.createForExplicitSignIn(generation: generation)
        let operations = Operations()
        let store = MatrixSessionKeychain(generation: generation, clients: try Self.clients(), metadata: try Self.metadata(), operations: operations, refreshLockURL: directory.appendingPathComponent("refresh.lock"))
        return (operations, store, marker, directory)
    }
    @MainActor private func prepared(_ store: MatrixSessionKeychain, _ marker: OIDCInstallationMarker, scope: String? = nil) throws -> MatrixCustodyTicket {
        let g = try Self.grant(scope: scope)
        let receipt = try MatrixAuthenticatedDevice.delivered(whoami(), grant: g, requested: "P2-SYNTHETIC")
        return try store.prepare(device: receipt, marker: marker, requestStartedAt: Date(timeIntervalSince1970: 100))
    }
    private let key = Data(repeating: 42, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")

    /// A copy-only Security fixture with synchronization at the same boundary as
    /// the SDK's background synchronous callback. It never writes real Keychain.
    private final class ReaderOperations: MatrixKeychainReading, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: Any]]
        private var status: OSStatus = errSecSuccess
        private var queries: [[String: Any]] = []
        init(_ items: [[String: Any]]) { self.items = items }
        func replace(_ items: [[String: Any]], status: OSStatus = errSecSuccess) {
            lock.withLock { self.items = items; self.status = status }
        }
        func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
            lock.withLock {
                queries.append(query)
                if status != errSecSuccess { return (status, nil) }
                if items.isEmpty { return (errSecItemNotFound, nil) }
                if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                    return (errSecSuccess, items.map { item in
                        var attributes = item; attributes.removeValue(forKey: kSecValueData as String); return attributes
                    } as CFArray)
                }
                return items.first.map { (errSecSuccess, $0 as CFDictionary) } ?? (errSecItemNotFound, nil)
            }
        }
        var materialReads: Int { lock.withLock { queries.filter { $0[kSecReturnData as String] as? Bool == true }.count } }
        var onlyMatrixQueries: Bool { lock.withLock { queries.allSatisfy {
            $0[kSecAttrAccessGroup as String] as? String == MatrixCustodyRecord.accessGroup &&
            $0[kSecAttrService as String] as? String == MatrixCustodyRecord.service
        } } }
    }

    @MainActor func testReadyReaderWorksWithoutPrivateMarkerButExpiryAndPreparationRefuse() throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let preparedTicket = try prepared(store, marker)
        XCTAssertThrowsError(try preparedTicket.requiredDeviceKeys())
        let memory = ReaderOperations([try XCTUnwrap(ops.item)])
        let reader = MatrixSessionReader(clients: try Self.clients(), metadata: try Self.metadata(), operations: memory)
        XCTAssertThrowsError(try reader.loadCurrent(now: Date(timeIntervalSince1970: 100))) {
            XCTAssertEqual($0 as? MatrixCustodyFailure, .interruptedPreparation)
        }
        let ready = try store.commitPrepared(preparedTicket, marker: marker, curve25519: key, ed25519: key)
        memory.replace([try XCTUnwrap(ops.item)])
        try marker.remove(try XCTUnwrap(marker.load()))
        XCTAssertThrowsError(try store.resume(marker: marker))
        let current = try reader.loadCurrent(now: Date(timeIntervalSince1970: 299))
        XCTAssertEqual(current.session, ready.session); XCTAssertEqual(current.generation, ready.generation)
        XCTAssertEqual(current.passphrase, ready.passphrase)
        XCTAssertEqual(try current.requiredDeviceKeys().curve25519, key)
        XCTAssertNoThrow(try reader.recheck(current, now: Date(timeIntervalSince1970: 299)))
        XCTAssertThrowsError(try reader.loadCurrent(now: Date(timeIntervalSince1970: 300))) {
            XCTAssertEqual($0 as? MatrixCustodyFailure, .expired)
        }
        XCTAssertTrue(memory.onlyMatrixQueries)
    }

    @MainActor func testPreJournalV1PreparedAndReadyRecordsDecodeWithoutRewrite() throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let preparedTicket = try prepared(store, marker)
        var preparedItem = try XCTUnwrap(ops.item)
        var preparedJSON = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(preparedItem[kSecValueData as String] as? Data)) as! [String: Any]
        preparedJSON.removeValue(forKey: "refreshAttempt")
        preparedItem[kSecValueData as String] = try JSONSerialization.data(withJSONObject: preparedJSON)
        ops.item = preparedItem
        let preparedReader = MatrixSessionReader(clients: try Self.clients(), metadata: try Self.metadata(),
                                                 operations: ReaderOperations([preparedItem]))
        XCTAssertThrowsError(try preparedReader.loadCurrent(now: Date(timeIntervalSince1970: 100))) {
            XCTAssertEqual($0 as? MatrixCustodyFailure, .interruptedPreparation)
        }

        let ready = try store.commitPrepared(preparedTicket, marker: marker,
                                             curve25519: key, ed25519: key)
        var readyItem = try XCTUnwrap(ops.item)
        var readyJSON = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(readyItem[kSecValueData as String] as? Data)) as! [String: Any]
        readyJSON.removeValue(forKey: "refreshAttempt")
        readyItem[kSecValueData as String] = try JSONSerialization.data(withJSONObject: readyJSON)
        ops.item = readyItem
        let fresh = MatrixSessionKeychain(generation: ready.generation, clients: try Self.clients(),
                                          metadata: try Self.metadata(), operations: ops)
        let resumed = try fresh.resume(marker: marker)
        XCTAssertEqual(resumed.envelope, ready.envelope)
    }

    @MainActor func testExpiredGrantRotatesBeforeResumeWithoutChangingMatrixIdentity() async throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let ready = try store.commitPrepared(prepared(store, marker), marker: marker,
                                             curve25519: key, ed25519: key)
        let original = ready.envelope
        let refresh = try OIDCGrantRefresh(resuming: store.resumeGrantForRefresh(marker: marker))
        let scope = "openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:P2-SYNTHETIC"
        let response = try OIDCTokenResponse.decode(JSONSerialization.data(withJSONObject: [
            "token_type": "Bearer", "access_token": "rotated-access",
            "refresh_token": "rotated-refresh", "expires_in": 400, "scope": scope]))
        var exchanges = 0
        let access = try await refresh.accessToken(now: Date(timeIntervalSince1970: 300)) { _ in
            exchanges += 1
            return OIDCRefreshReply(response: response, jwks: Data())
        }
        XCTAssertEqual(access, "rotated-access"); XCTAssertEqual(exchanges, 1)

        let current = try store.resume(marker: marker)
        XCTAssertEqual(current.session.userID, original.session.userID)
        XCTAssertEqual(current.session.deviceID, original.session.deviceID)
        XCTAssertEqual(current.session.homeserver, original.session.homeserver)
        XCTAssertEqual(current.session.clientID, original.session.clientID)
        XCTAssertEqual(current.generation, original.generation)
        XCTAssertEqual(current.passphrase, original.passphrase)
        XCTAssertEqual(try current.requiredDeviceKeys().curve25519, original.deviceKeys?.curve)
        XCTAssertEqual(try current.requiredDeviceKeys().ed25519, original.deviceKeys?.ed)
        XCTAssertEqual(current.session.accessToken, "rotated-access")
        XCTAssertEqual(current.session.refreshToken, "rotated-refresh")
        XCTAssertEqual(current.session.expiresAt, Date(timeIntervalSince1970: 700))
        XCTAssertThrowsError(try store.recheck(ready, marker: marker))

        let reader = MatrixSessionReader(clients: try Self.clients(), metadata: try Self.metadata(),
                                         operations: ReaderOperations([try XCTUnwrap(ops.item)]))
        XCTAssertNoThrow(try reader.loadCurrent(now: Date(timeIntervalSince1970: 400)))
    }

    @MainActor func testNotificationAndAppRefreshAreSingleFlightAcrossCoordinators() async throws {
        let (_, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let ready = try store.commitPrepared(prepared(store, marker), marker: marker, curve25519: key, ed25519: key)
        let app = try OIDCGrantRefresh(resuming: store.resumeGrantForRefresh(marker: marker))
        let extensionRefresh = try OIDCGrantRefresh(resuming: store.resumeGrantForNotificationRefresh(ticket: ready))
        let response = try OIDCTokenResponse.decode(JSONSerialization.data(withJSONObject: [
            "token_type": "Bearer", "access_token": "rotated", "refresh_token": "replacement", "expires_in": 400]))
        var calls = 0
        _ = try await app.refresh(now: Date(timeIntervalSince1970: 300), preflight: {
            do {
                _ = try await extensionRefresh.refresh(now: Date(timeIntervalSince1970: 300)) { _ in
                    calls += 1; return .init(response: response, jwks: Data())
                }
                XCTFail("Second coordinator must not enter the spend")
            } catch { XCTAssertEqual(error as? MatrixRefreshFailure, .busy) }
        }) { _ in
            calls += 1
            // App launch/continuity must treat the live journal as busy.
            XCTAssertThrowsError(try store.resume(marker: marker)) {
                XCTAssertEqual($0 as? MatrixRefreshFailure, .busy)
            }
            return .init(response: response, jwks: Data())
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try store.resume(marker: marker).session.accessToken, "rotated")
    }

    @MainActor func testAppCallerCancellationStillPersistsTheRotatedCredential() async throws {
        let (_, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.commitPrepared(prepared(store, marker), marker: marker, curve25519: key, ed25519: key)
        let refresh = try OIDCGrantRefresh(resuming: store.resumeGrantForRefresh(marker: marker))
        let response = try OIDCTokenResponse.decode(JSONSerialization.data(withJSONObject: [
            "token_type": "Bearer", "access_token": "retained", "refresh_token": "replacement", "expires_in": 400]))
        var reply: CheckedContinuation<Void, Never>?
        let caller = Task {
            try await refresh.refresh(now: Date(timeIntervalSince1970: 300)) { _ in
                await withCheckedContinuation { reply = $0 }
                XCTAssertFalse(Task.isCancelled)
                return .init(response: response, jwks: Data())
            }
        }
        while reply == nil { await Task.yield() }
        caller.cancel()
        reply?.resume()
        let token = try await caller.value
        XCTAssertEqual(token, "retained")
        XCTAssertEqual(try store.resume(marker: marker).session.accessToken, "retained")
    }

    @MainActor func testNotificationTimeoutCancelsActualCoordinatorAndPreservesJournal() async throws {
        let (_, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let ticket = try store.commitPrepared(prepared(store, marker), marker: marker, curve25519: key, ed25519: key)
        let refresh = try OIDCGrantRefresh(resuming: store.resumeGrantForNotificationRefresh(ticket: ticket))
        var requests = 0, cancelled = false
        do {
            _ = try await MatrixNotificationSession.bounded(seconds: 0.02) {
                try await refresh.refresh(now: Date(timeIntervalSince1970: 300)) { _ in
                    requests += 1
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { cancelled = true; throw error }
                    throw OIDCGrantFailure.invalidResponse
                }
            }
            XCTFail("Expected bounded cancellation")
        } catch { XCTAssertEqual(error as? MatrixRefreshFailure, .timedOut) }
        XCTAssertEqual(requests, 1); XCTAssertTrue(cancelled)
        XCTAssertThrowsError(try store.resumeGrantForRefresh(marker: marker)) {
            XCTAssertEqual($0 as? OIDCGrantFailure, .refreshInterrupted)
        }
        XCTAssertNoThrow(try MatrixRefreshLease.acquire(at: dir.appendingPathComponent("refresh.lock")))
    }

    @MainActor func testRecordChangedAfterPreflightNeverSpends() async throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.commitPrepared(prepared(store, marker), marker: marker, curve25519: key, ed25519: key)
        let refresh = try OIDCGrantRefresh(resuming: store.resumeGrantForRefresh(marker: marker))
        let writes = ops.calls.filter { $0 == "update" }.count
        do {
            _ = try await refresh.refresh(now: Date(timeIntervalSince1970: 300), preflight: {
                var record = try JSONSerialization.jsonObject(with: XCTUnwrap(ops.item?[kSecValueData as String] as? Data)) as! [String: Any]
                var session = record["session"] as! [String: Any]
                session["accessToken"] = "changed-by-other-process"
                record["session"] = session
                ops.item?[kSecValueData as String] = try JSONSerialization.data(withJSONObject: record)
            }) { _ in
                XCTFail("Changed snapshot must never spend"); throw OIDCGrantFailure.invalidResponse
            }
            XCTFail("Expected changed record")
        } catch { XCTAssertEqual(error as? MatrixRefreshFailure, .recordChanged) }
        XCTAssertEqual(ops.calls.filter { $0 == "update" }.count, writes)
    }

    @MainActor func testBusyLockCannotJournalOrSpend() async throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.commitPrepared(prepared(store, marker), marker: marker, curve25519: key, ed25519: key)
        let refresh = try OIDCGrantRefresh(resuming: store.resumeGrantForRefresh(marker: marker))
        let original = ops.item?[kSecValueData as String] as? Data
        let lease = try MatrixRefreshLease.acquire(at: dir.appendingPathComponent("refresh.lock"))
        defer { withExtendedLifetime(lease) {} }
        do {
            _ = try await refresh.refresh(now: Date(timeIntervalSince1970: 300)) { _ in
                XCTFail("Busy lock must never spend"); throw OIDCGrantFailure.invalidResponse
            }
            XCTFail("Expected busy")
        } catch { XCTAssertEqual(error as? MatrixRefreshFailure, .busy) }
        XCTAssertEqual(ops.item?[kSecValueData as String] as? Data, original)
    }

    @MainActor func testOtherProcessAlreadyRefreshedReusesCredentialAndRejectsStaleTicket() async throws {
        let (_, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try store.commitPrepared(prepared(store, marker), marker: marker, curve25519: key, ed25519: key)
        let app = try OIDCGrantRefresh(resuming: store.resumeGrantForRefresh(marker: marker))
        let notification = try OIDCGrantRefresh(resuming: store.resumeGrantForNotificationRefresh(ticket: original))
        let response = try OIDCTokenResponse.decode(JSONSerialization.data(withJSONObject: [
            "token_type": "Bearer", "access_token": "other-process-access", "refresh_token": "replacement", "expires_in": 400]))
        var calls = 0
        // Near expiry is enough; expiry is measured from real request time,
        // never inflated by the minimum-validity lead.
        _ = try await notification.accessToken(now: Date(timeIntervalSince1970: 280), minimumValidity: 30) { _ in
            calls += 1; return .init(response: response, jwks: Data())
        }
        let token = try await app.accessToken(now: Date(timeIntervalSince1970: 300), minimumValidity: 60) { _ in
            calls += 1; throw OIDCGrantFailure.invalidResponse
        }
        XCTAssertEqual(calls, 1); XCTAssertEqual(token, "other-process-access")
        XCTAssertEqual(try store.resume(marker: marker).session.expiresAt, Date(timeIntervalSince1970: 680))
        XCTAssertThrowsError(try store.resumeGrantForNotificationRefresh(ticket: original)) {
            XCTAssertEqual($0 as? MatrixRefreshFailure, .recordChanged)
        }
    }

    @MainActor func testNotificationSnapshotChangedByOtherProcessCannotSpendOrExposeIt() async throws {
        let (_, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let ticket = try store.commitPrepared(prepared(store, marker), marker: marker, curve25519: key, ed25519: key)
        let notification = try OIDCGrantRefresh(resuming: store.resumeGrantForNotificationRefresh(ticket: ticket))
        let app = try OIDCGrantRefresh(resuming: store.resumeGrantForRefresh(marker: marker))
        let response = try OIDCTokenResponse.decode(JSONSerialization.data(withJSONObject: [
            "token_type": "Bearer", "access_token": "app-rotated", "refresh_token": "replacement", "expires_in": 400]))
        _ = try await app.refresh(now: Date(timeIntervalSince1970: 300)) { _ in .init(response: response, jwks: Data()) }
        do {
            _ = try await notification.accessToken(now: Date(timeIntervalSince1970: 300)) { _ in
                XCTFail("A stale notification must not spend"); throw OIDCGrantFailure.invalidResponse
            }
            XCTFail("Changed snapshot must fall back")
        } catch { XCTAssertEqual(error as? MatrixRefreshFailure, .recordChanged) }
    }

    @MainActor func testCrashJournalSurvivesFreshNotificationAndAppCoordinators() async throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let ticket = try store.commitPrepared(prepared(store, marker), marker: marker, curve25519: key, ed25519: key)
        let refresh = try OIDCGrantRefresh(resuming: store.resumeGrantForNotificationRefresh(ticket: ticket))
        do {
            _ = try await refresh.refresh(now: Date(timeIntervalSince1970: 300)) { _ in
                // Process death after server acceptance is indistinguishable
                // from lost response: only the durable journal survives.
                throw OIDCGrantFailure.invalidResponse
            }
            XCTFail("Ambiguous spend must remain closed")
        } catch {}
        // Reconstruct adapters using only the encoded Keychain item, as after
        // process death. No coordinator/flight object is reused for recovery.
        let freshOperations = Operations()
        freshOperations.item = try XCTUnwrap(ops.item)
        let fresh = MatrixSessionKeychain(generation: ticket.generation, clients: try Self.clients(),
            metadata: try Self.metadata(), operations: freshOperations,
            refreshLockURL: dir.appendingPathComponent("refresh.lock"))
        XCTAssertThrowsError(try fresh.resumeGrantForRefresh(marker: marker)) {
            XCTAssertEqual($0 as? OIDCGrantFailure, .refreshInterrupted)
        }
        let reader = MatrixSessionReader(clients: try Self.clients(), metadata: try Self.metadata(),
            operations: ReaderOperations([try XCTUnwrap(freshOperations.item)]))
        XCTAssertThrowsError(try reader.loadForRefresh()) {
            XCTAssertEqual($0 as? OIDCGrantFailure, .refreshInterrupted)
        }
        XCTAssertThrowsError(try fresh.resumeGrantForNotificationRefresh(ticket: ticket))
        XCTAssertNoThrow(try MatrixRefreshLease.acquire(at: dir.appendingPathComponent("refresh.lock")))
    }

    @MainActor func testRefreshJournalMustPersistBeforeNetwork() async throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let ready = try store.commitPrepared(prepared(store, marker), marker: marker,
                                             curve25519: key, ed25519: key)
        let before = ops.item?[kSecValueData as String] as? Data
        let refresh = try OIDCGrantRefresh(resuming: store.resumeGrantForRefresh(marker: marker))
        ops.failure = "update"
        var exchanges = 0
        do {
            _ = try await refresh.accessToken(now: Date(timeIntervalSince1970: 300)) { _ in
                exchanges += 1
                throw OIDCGrantFailure.invalidResponse
            }
            XCTFail("A failed journal write cannot spend the refresh token")
        } catch {
            XCTAssertEqual(error as? OIDCGrantFailure, .storageUnavailable)
        }
        XCTAssertEqual(exchanges, 0)
        ops.failure = nil
        XCTAssertEqual(ops.item?[kSecValueData as String] as? Data, before)
        XCTAssertEqual(try store.resume(marker: marker).session, ready.session)
    }

    @MainActor func testAmbiguousRefreshSpendCannotResumeOrRetry() async throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.commitPrepared(prepared(store, marker), marker: marker,
                                     curve25519: key, ed25519: key)
        let refresh = try OIDCGrantRefresh(resuming: store.resumeGrantForRefresh(marker: marker))
        var exchanges = 0
        let exchange: OIDCGrantRefresh.Exchange = { _ in
            exchanges += 1
            throw OIDCGrantFailure.invalidResponse
        }
        do {
            _ = try await refresh.accessToken(now: Date(timeIntervalSince1970: 300), exchange: exchange)
            XCTFail("An ambiguous token spend cannot expose an access token")
        } catch {
            XCTAssertEqual(error as? OIDCGrantFailure, .reauthenticationRequired)
        }
        XCTAssertEqual(exchanges, 1)
        XCTAssertThrowsError(try store.resume(marker: marker)) {
            XCTAssertEqual($0 as? MatrixCustodyFailure, .refreshRequired)
        }
        XCTAssertThrowsError(try store.resumeGrantForRefresh(marker: marker)) {
            XCTAssertEqual($0 as? OIDCGrantFailure, .refreshInterrupted)
        }
        let reader = MatrixSessionReader(clients: try Self.clients(), metadata: try Self.metadata(),
                                         operations: ReaderOperations([try XCTUnwrap(ops.item)]))
        XCTAssertThrowsError(try reader.loadCurrent(now: Date(timeIntervalSince1970: 301))) {
            XCTAssertEqual($0 as? MatrixCustodyFailure, .refreshRequired)
        }
        do {
            _ = try await refresh.accessToken(now: Date(timeIntervalSince1970: 301),
                                              exchange: exchange)
            XCTFail("A journaled ambiguous spend cannot be retried")
        } catch {
            XCTAssertEqual(error as? OIDCGrantFailure, .reauthenticationRequired)
        }
        XCTAssertEqual(exchanges, 1)
    }

    @MainActor func testRotatedCredentialMustPersistBeforeExposure() async throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.commitPrepared(prepared(store, marker), marker: marker,
                                     curve25519: key, ed25519: key)
        let refresh = try OIDCGrantRefresh(resuming: store.resumeGrantForRefresh(marker: marker))
        let scope = "openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:P2-SYNTHETIC"
        let response = try OIDCTokenResponse.decode(JSONSerialization.data(withJSONObject: [
            "token_type": "Bearer", "access_token": "must-not-escape",
            "refresh_token": "rotated-refresh", "expires_in": 400, "scope": scope]))
        ops.failingUpdateNumber = ops.calls.filter { $0 == "update" }.count + 2
        var exchanges = 0
        do {
            _ = try await refresh.accessToken(now: Date(timeIntervalSince1970: 300)) { _ in
                exchanges += 1
                return OIDCRefreshReply(response: response, jwks: Data())
            }
            XCTFail("A rotated access token cannot escape before durable readback")
        } catch {
            XCTAssertEqual(error as? OIDCGrantFailure, .storageUnavailable)
        }
        XCTAssertEqual(exchanges, 1)
        XCTAssertThrowsError(try store.resume(marker: marker)) {
            XCTAssertEqual($0 as? MatrixCustodyFailure, .refreshRequired)
        }
        do {
            _ = try await refresh.accessToken(now: Date(timeIntervalSince1970: 301)) { _ in
                exchanges += 1
                throw OIDCGrantFailure.invalidResponse
            }
            XCTFail("A failed rotated-credential write cannot retry the spend")
        } catch {
            XCTAssertEqual(error as? OIDCGrantFailure, .reauthenticationRequired)
        }
        XCTAssertEqual(exchanges, 1)
    }

    func testFirstSignInPreflightAcceptsOnlyCompleteAbsence() throws {
        let empty = ReaderOperations([])
        let reader = MatrixSessionReader(clients: try Self.clients(), metadata: try Self.metadata(), operations: empty)
        XCTAssertNoThrow(try reader.requireAbsent())
        XCTAssertEqual(empty.materialReads, 0)

        var survivor = MatrixCustodyRecord.match
        survivor[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        survivor[kSecValueData as String] = Data("preserve-me".utf8)
        let occupied = ReaderOperations([survivor])
        let occupiedReader = MatrixSessionReader(clients: try Self.clients(), metadata: try Self.metadata(), operations: occupied)
        XCTAssertThrowsError(try occupiedReader.requireAbsent())
        XCTAssertEqual(occupied.materialReads, 1)

        var legacy = survivor
        legacy[kSecAttrAccount as String] = UUID().uuidString
        let legacyReader = ReaderOperations([legacy])
        XCTAssertThrowsError(try MatrixSessionReader(clients: try Self.clients(), metadata: try Self.metadata(), operations: legacyReader).requireAbsent())
        XCTAssertEqual(legacyReader.materialReads, 0)
    }

    @MainActor func testReaderCannotReuseCachedEnvelopeOrAcceptWeakUnavailableOrForeignRecord() throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let ready = try store.commitPrepared(prepared(store, marker), marker: marker, curve25519: key, ed25519: key)
        let item = try XCTUnwrap(ops.item), memory = ReaderOperations([item])
        let reader = MatrixSessionReader(clients: try Self.clients(), metadata: try Self.metadata(), operations: memory)
        let now = Date(timeIntervalSince1970: 100)
        for failure in ["missing", "locked", "corrupt", "weak", "sync", "wrong-group", "changed-session", "changed-keys", "changed-generation", "foreign-issuer", "foreign-client"] {
            var changed = item
            switch failure {
            case "missing": memory.replace([])
            case "locked": memory.replace([item], status: errSecInteractionNotAllowed)
            case "corrupt": changed[kSecValueData as String] = Data("broken".utf8); memory.replace([changed])
            case "weak": changed[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock; memory.replace([changed])
            case "sync": changed[kSecAttrSynchronizable as String] = true; memory.replace([changed])
            case "wrong-group": changed[kSecAttrAccessGroup as String] = "main-private"; memory.replace([changed])
            default:
                var value = try JSONSerialization.jsonObject(with: XCTUnwrap(item[kSecValueData as String] as? Data)) as! [String: Any]
                if failure == "changed-generation" { value["generation"] = UUID().uuidString }
                else if failure == "foreign-issuer" { value["issuer"] = "https://foreign.invalid/" }
                else if failure == "changed-keys" { value["deviceKeys"] = ["curve": Data(repeating: 43, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), "ed": key] }
                else {
                    var session = value["session"] as! [String: Any]
                    session[failure == "foreign-client" ? "clientID" : "accessToken"] = failure == "foreign-client" ? "01JPHNDXPQ7R8S9T0V2W3X4Y5Z" : "changed-synthetic-access"
                    value["session"] = session
                }
                changed[kSecValueData as String] = try JSONSerialization.data(withJSONObject: value); memory.replace([changed])
            }
            XCTAssertThrowsError(try reader.recheck(ready, now: now), failure)
        }
        memory.replace([item]); XCTAssertNoThrow(try reader.recheck(ready, now: now))
        XCTAssertTrue(memory.onlyMatrixQueries)
        XCTAssertEqual(item[kSecValueData as String] as? Data, ops.item?[kSecValueData as String] as? Data)
    }

    @MainActor func testLegacyAndCoexistingRecordsRefuseBeforeAnySecretReadOrReplacement() throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try store.commitPrepared(prepared(store, marker), marker: marker, curve25519: key, ed25519: key)
        let current = try XCTUnwrap(ops.item)
        var legacy = current; legacy[kSecAttrAccount as String] = UUID().uuidString
        for items in [[legacy], [current, legacy]] {
            let memory = ReaderOperations(items)
            let reader = MatrixSessionReader(clients: try Self.clients(), metadata: try Self.metadata(), operations: memory)
            XCTAssertThrowsError(try reader.loadCurrent(now: Date(timeIntervalSince1970: 100)))
            XCTAssertEqual(memory.materialReads, 0)
        }
        ops.item = legacy
        let survivor = legacy[kSecValueData as String] as? Data
        XCTAssertThrowsError(try prepared(store, marker))
        XCTAssertEqual(ops.item?[kSecValueData as String] as? Data, survivor)
        XCTAssertFalse(ops.calls.contains("delete"))
    }

    @MainActor func testCopyOnlyReaderRunsFromBackgroundSynchronousCallback() async throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let ready = try store.commitPrepared(prepared(store, marker), marker: marker, curve25519: key, ed25519: key)
        let memory = ReaderOperations([try XCTUnwrap(ops.item)])
        let reader = MatrixSessionReader(clients: try Self.clients(), metadata: try Self.metadata(), operations: memory)
        let same = try await Task.detached {
            try reader.loadCurrent(now: Date(timeIntervalSince1970: 100)).envelope == ready.envelope
        }.value
        XCTAssertTrue(same); XCTAssertTrue(memory.onlyMatrixQueries)
    }

    @MainActor func testPreparationIsAtomicSharedAndCannotAuthorizeResumeOrOverwrite() throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let ticket = try prepared(store, marker)
        XCTAssertTrue(ticket.isPrepared); XCTAssertEqual(Data(base64Encoded: ticket.passphrase)?.count, 32)
        XCTAssertEqual(ticket.session.expiresAt, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(ops.item?[kSecAttrAccessGroup as String] as? String, MatrixSessionKeychain.accessGroup)
        XCTAssertEqual(ops.item?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(ops.item?[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(ops.item?[kSecUseDataProtectionKeychain as String] as? Bool, true)
        let before = ops.item?[kSecValueData as String] as? Data
        XCTAssertThrowsError(try store.resume(marker: marker)) { XCTAssertEqual($0 as? MatrixCustodyFailure, .interruptedPreparation) }
        XCTAssertThrowsError(try prepared(store, marker))
        XCTAssertEqual(before, ops.item?[kSecValueData as String] as? Data)
        XCTAssertFalse(ops.calls.contains("update")); XCTAssertFalse(ops.calls.contains("delete"))
    }
    @MainActor func testPromotionRechecksRecordMarkerAndKeyIdentity() throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let ticket = try prepared(store, marker)
        XCTAssertThrowsError(try store.commitPrepared(ticket, marker: marker, curve25519: "bad", ed25519: key))
        let ready = try store.commitPrepared(ticket, marker: marker, curve25519: key, ed25519: key)
        XCTAssertFalse(ready.isPrepared)
        let fresh = MatrixSessionKeychain(generation: ready.generation, clients: try Self.clients(), metadata: try Self.metadata(), operations: ops)
        let resumed = try fresh.resume(marker: marker)
        XCTAssertEqual(resumed.session, ticket.session); XCTAssertEqual(resumed.passphrase, ticket.passphrase)
        XCTAssertNoThrow(try resumed.verifyDeviceKeys(curve25519: key, ed25519: key))
        XCTAssertThrowsError(try resumed.verifyDeviceKeys(curve25519: Data(repeating: 43, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), ed25519: key))
        XCTAssertThrowsError(try store.commitPrepared(ticket, marker: marker, curve25519: key, ed25519: key))
        let installation = try XCTUnwrap(marker.load()); try marker.remove(installation)
        XCTAssertThrowsError(try fresh.resume(marker: marker)); XCTAssertThrowsError(try fresh.recheck(ready, marker: marker))
        _ = try marker.createForExplicitSignIn(generation: ready.generation)
        XCTAssertThrowsError(try fresh.resume(marker: marker)); XCTAssertNotNil(ops.item)
    }
    @MainActor func testWriteReadbackAndWeakOrCorruptSurvivorsFailClosed() throws {
        for failure in ["add", "update", "readback", "weak", "sync", "corrupt", "copy"] {
            let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
            if failure == "add" { ops.failure = failure; XCTAssertThrowsError(try prepared(store, marker)); continue }
            let ticket = try prepared(store, marker)
            switch failure {
            case "weak": ops.item?[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            case "sync": ops.item?[kSecAttrSynchronizable as String] = true
            case "corrupt": ops.item?[kSecValueData as String] = Data("broken".utf8)
            default: ops.failure = failure
            }
            let before = ops.item?[kSecValueData as String] as? Data
            XCTAssertThrowsError(try store.commitPrepared(ticket, marker: marker, curve25519: key, ed25519: key))
            XCTAssertThrowsError(try store.resume(marker: marker))
            if failure != "readback" { XCTAssertEqual(before, ops.item?[kSecValueData as String] as? Data) }
            XCTAssertFalse(ops.calls.contains("delete"))
        }
    }
    @MainActor func testScopeDeviceGuestAndConfigurationMismatchCannotPrepare() throws {
        let (ops, store, marker, dir) = try setup(); defer { try? FileManager.default.removeItem(at: dir) }
        let g = try Self.grant()
        for data in [try whoami("OTHER"), try whoami(guest: true), Data("{}".utf8)] {
            XCTAssertThrowsError(try MatrixAuthenticatedDevice.delivered(data, grant: g, requested: "P2-SYNTHETIC"))
        }
        XCTAssertThrowsError(try prepared(store, marker, scope: "openid")); XCTAssertNil(ops.item)
        let foreign = try MASPublicClients(matrix: "01JPHNDXPQ7R8S9T0V2W3X4Y5Z", domain: "01JPHNMXPQ7R8S9T0V2W3X4Y5Z")
        let second = MatrixSessionKeychain(generation: try XCTUnwrap(marker.load()).generation, clients: foreign, metadata: try Self.metadata(), operations: ops)
        let receipt = try MatrixAuthenticatedDevice.delivered(whoami(), grant: g, requested: "P2-SYNTHETIC")
        XCTAssertThrowsError(try second.prepare(device: receipt, marker: marker, requestStartedAt: Date(timeIntervalSince1970: 100)))
        XCTAssertNil(ops.item)
    }
    func testMissingPartialAndSymlinkedStoresAreNeverRecreated() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Matrix"), directory = MatrixStoreDirectory(root: root), generation = UUID()
        XCTAssertThrowsError(try directory.requireExisting(generation: generation)); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let paths = try directory.createPrepared(generation: generation)
        XCTAssertThrowsError(try directory.createPrepared(generation: generation))
        XCTAssertThrowsError(try directory.requireExisting(generation: generation))
        for name in ["matrix-sdk-state.sqlite3", "matrix-sdk-crypto.sqlite3"] { try Data("synthetic file-presence fixture".utf8).write(to: paths.data.appendingPathComponent(name)) }
        XCTAssertEqual(try directory.requireExisting(generation: generation).data, paths.data)
        let crypto = paths.data.appendingPathComponent("matrix-sdk-crypto.sqlite3")
        try FileManager.default.removeItem(at: crypto)
        XCTAssertThrowsError(try directory.requireExisting(generation: generation)); XCTAssertFalse(FileManager.default.fileExists(atPath: crypto.path))
        try FileManager.default.createSymbolicLink(at: crypto, withDestinationURL: paths.data.appendingPathComponent("matrix-sdk-state.sqlite3"))
        XCTAssertThrowsError(try directory.requireExisting(generation: generation))
        XCTAssertTrue(FileManager.default.fileExists(atPath: crypto.path))
        XCTAssertThrowsError(try directory.requireExisting(generation: UUID()))
    }
}
