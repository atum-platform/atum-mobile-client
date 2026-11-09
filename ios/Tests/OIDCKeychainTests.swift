import XCTest
import Security
import CryptoKit
@testable import AtumNativeAPI

final class OIDCKeychainTests: XCTestCase {
    @MainActor private final class Operations: OIDCKeychainOperations {
        var item: [String: Any]?
        var calls: [String] = []
        var queries: [[String: Any]] = []
        var failure: String?
        var badReadback = false
        func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
            calls.append("read"); queries.append(query)
            if failure == "read" { return (errSecInteractionNotAllowed, nil) }
            guard var item else { return (errSecItemNotFound, nil) }
            if badReadback, calls.contains("update") { item[kSecValueData as String] = Data("broken".utf8) }
            return (errSecSuccess, item as CFDictionary)
        }
        func add(_ attributes: [String: Any]) -> OSStatus {
            calls.append("add"); queries.append(attributes)
            if failure == "add" { return errSecDuplicateItem }
            guard item == nil else { return errSecDuplicateItem }
            item = attributes; return errSecSuccess
        }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            calls.append("update"); queries.append(query)
            if failure == "update" { return errSecInteractionNotAllowed }
            guard item != nil else { return errSecItemNotFound }
            item?.merge(attributes) { _, new in new }; return errSecSuccess
        }
        func delete(_ query: [String: Any]) -> OSStatus {
            calls.append("delete"); queries.append(query)
            if failure == "delete" { return errSecInteractionNotAllowed }
            item = nil; return errSecSuccess
        }
    }
    private func clients() throws -> MASPublicClients { try .init(matrix: "01JPHNMXPQ7R8S9T0V2W3X4Y5Z", domain: "01JPHNDXPQ7R8S9T0V2W3X4Y5Z") }
    private func metadata() throws -> MASMetadata {
        try MASMetadata.decode(JSONSerialization.data(withJSONObject: ["issuer": "https://auth.atum.test/",
            "authorization_endpoint": "https://auth.atum.test/authorize", "token_endpoint": "https://auth.atum.test/token",
            "jwks_uri": "https://auth.atum.test/keys", "revocation_endpoint": "https://auth.atum.test/revoke",
            "id_token_signing_alg_values_supported": ["ES256"], "code_challenge_methods_supported": ["S256"]]), expectedIssuer: "https://auth.atum.test/")
    }
    private func record(_ generation: UUID, phase: OIDCStoredGrant.Phase = .ready) throws -> OIDCStoredGrant {
        OIDCStoredGrant(generation: generation, issuer: try metadata().issuer, clientID: try clients().domain,
            subject: "synthetic-subject", accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
            expiresAt: Date(timeIntervalSince1970: 300), phase: phase, attempt: phase == .spending ? UUID() : nil)
    }
    @MainActor private func store(_ generation: UUID, _ operations: Operations) throws -> OIDCDomainKeychain {
        OIDCDomainKeychain(generation: generation, clients: try clients(), metadata: try metadata(), operations: operations)
    }

    @MainActor private func proof(clients other: MASPublicClients? = nil, principal: String = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", access: String = "synthetic-access") throws -> (binding: OIDCAccountBinding, grant: OIDCVerifiedGrant) {
        let clients = try other ?? self.clients(), metadata = try metadata(), flows = OIDCFlows(), key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "EC", "kid": "ephemeral", "crv": "P-256",
            "x": publicKey.subdata(in: 1..<33).base64URL, "y": publicKey.subdata(in: 33..<65).base64URL]]])
        func token(_ flow: OIDCFlow) throws -> String {
            let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "ephemeral"]).base64URL
            let claims = try JSONSerialization.data(withJSONObject: ["iss": flow.issuer, "sub": "synthetic-subject", "aud": flow.clientID,
                "nonce": flow.nonce, "iat": 0, "exp": 3600]).base64URL
            let input = header + "." + claims
            let token = input + "." + (try key.signature(for: Data(input.utf8))).rawRepresentation.base64URL
            return token
        }
        let matrix = try flows.begin(.matrix(deviceID: "P2-DEVICE"), clients: clients, metadata: metadata)
        let domain = try flows.begin(.domain, clients: clients, metadata: metadata)
        var callback = URLComponents(url: MASPublicClients.callback, resolvingAgainstBaseURL: false)!
        callback.queryItems = [.init(name: "state", value: domain.state), .init(name: "code", value: "synthetic-code")]
        let accepted = try flows.consume(callback.url!)
        let response = try OIDCTokenResponse.decode(JSONSerialization.data(withJSONObject: ["token_type": "Bearer",
            "access_token": access, "refresh_token": "synthetic-refresh", "expires_in": 200, "scope": "openid", "id_token": token(domain)]))
        let grant = try accepted.verifyGrant(response, jwks: jwks, metadata: metadata, now: Date(timeIntervalSince1970: 100))
        let me = try NativeAPI.decode(OIDCMe.self, from: JSONSerialization.data(withJSONObject: [
            "issuer": metadata.issuer, "subject": "synthetic-subject", "principal": principal]))
        let matrixIdentity = try OIDCVerifier.verify(token(matrix), jwks: jwks, for: matrix, metadata: metadata, now: Date(timeIntervalSince1970: 100))
        return (try OIDCAccountBinding.bind(matrix: matrixIdentity, domain: grant.identity, me: me, clients: clients), grant)
    }
    @MainActor private func binding(clients: MASPublicClients? = nil, principal: String = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa") throws -> OIDCAccountBinding {
        try proof(clients: clients, principal: principal).binding
    }

    @MainActor func testMarkerReadingDoesNotCreateAndExplicitCreationCannotReplace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = OIDCInstallationMarker(directory: directory)
        XCTAssertNil(try marker.load()); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        let generation = UUID(), installation = try marker.createForExplicitSignIn(generation: generation)
        XCTAssertEqual(installation.generation, generation); XCTAssertEqual(try marker.load(), installation)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertThrowsError(try marker.createForExplicitSignIn(generation: generation))
        XCTAssertThrowsError(try marker.createForExplicitSignIn(generation: UUID()))
        XCTAssertEqual(try marker.load(), installation)
    }

    @MainActor func testFreshInstallDomainInventoryRefusesEverySurvivorBeforeSignIn() throws {
        let generation = UUID(), operations = Operations(), store = try store(generation, operations)
        XCTAssertNoThrow(try store.requireAbsentForExplicitSignIn())
        let query = try XCTUnwrap(operations.queries.last)
        XCTAssertNil(query[kSecAttrAccount as String])
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? String,
                       kSecAttrSynchronizableAny as String)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitAll as String)
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, false)

        try store.save(record(generation))
        let before = operations.item?[kSecValueData as String] as? Data
        XCTAssertThrowsError(try store.requireAbsentForExplicitSignIn()) {
            XCTAssertEqual($0 as? OIDCGrantFailure, .reauthenticationRequired)
        }
        XCTAssertEqual(operations.item?[kSecValueData as String] as? Data, before)
        XCTAssertFalse(operations.calls.contains("delete"))
    }

    @MainActor func testLegacyDriveGrantWithdrawsOnceWithoutTouchingAccountGrant() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = OIDCInstallationMarker(directory: directory), generation = UUID()
        let installation = try marker.createForExplicitSignIn(generation: generation)
        let domainOperations = Operations(), driveOperations = Operations()
        let domain = try store(generation, domainOperations)
        try domain.save(record(generation))
        try domain.bind(binding(), domainGrant: proof().grant, installation: installation)
        let account = try domain.resume(installation: marker).account
        let legacy = OIDCDriveKeychain(generation: generation, account: account,
                                       metadata: try metadata(), operations: driveOperations)
        let old = OIDCStoredGrant(generation: generation, issuer: try metadata().issuer,
                                  clientID: MASPublicClients.drive, subject: account.subject,
                                  accessToken: "legacy-access", refreshToken: "legacy-refresh",
                                  expiresAt: Date(timeIntervalSince1970: 300), phase: .ready, attempt: nil)
        try legacy.save(old)
        XCTAssertEqual(try legacy.withdraw(), old, "returned only for best-effort remote revocation")
        XCTAssertNil(try legacy.load())
        XCTAssertNil(try legacy.withdraw(), "subsequent access has no legacy chain")
        XCTAssertEqual(try domain.resume(installation: marker).account, account)
        XCTAssertEqual(try domain.load()?.accessToken, "synthetic-access")
    }

    @MainActor func testForcedDriveWithdrawalTargetsOnlyTheExactGeneration() throws {
        let generation = UUID(), operations = Operations()
        operations.item = [kSecValueData as String: Data("drive-token-envelope".utf8)]
        try OIDCDriveKeychain.forceWithdraw(generation: generation, operations: operations)
        XCTAssertNil(operations.item)
        let query = try XCTUnwrap(operations.queries.last)
        XCTAssertEqual(query[kSecAttrService as String] as? String,
                       "com.atum.mobile.oidc.drive.v1")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, generation.uuidString)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String,
                       OIDCDriveKeychain.accessGroup)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
    }

    @MainActor func testCorruptWeakOversizedOrFutureMarkerNeverReplaced() throws {
        for variant in ["corrupt", "weak", "oversized", "future"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = OIDCInstallationMarker(directory: directory)
            _ = try marker.createForExplicitSignIn(generation: UUID())
            let file = directory.appendingPathComponent("installation-v1.json")
            switch variant {
            case "corrupt": try Data("broken".utf8).write(to: file)
            case "weak": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            case "oversized": try Data(repeating: 32, count: 4097).write(to: file)
            default:
                var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
                value["version"] = 2; try JSONSerialization.data(withJSONObject: value).write(to: file)
            }
            let before = try Data(contentsOf: file)
            XCTAssertThrowsError(try marker.load())
            XCTAssertThrowsError(try marker.createForExplicitSignIn(generation: UUID()))
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    @MainActor func testBoundRecordResumesWithoutInitialGrantAndRotationPreservesBinding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = OIDCInstallationMarker(directory: directory), generation = UUID(), operations = Operations()
        let installation = try marker.createForExplicitSignIn(generation: generation), store = try store(generation, operations)
        try store.save(record(generation))
        XCTAssertThrowsError(try store.resume(installation: marker)) // Raw persisted facts are not provenance.
        let binding = try binding()
        try store.bind(binding, domainGrant: proof().grant, installation: installation)
        let resumed = try self.store(generation, operations).resume(installation: marker)
        XCTAssertEqual(resumed.account.issuer, binding.issuer); XCTAssertEqual(resumed.account.subject, binding.subject)
        XCTAssertEqual(resumed.account.principal, binding.principal)
        let controller = try OIDCGrantRefresh(resuming: resumed)
        XCTAssertThrowsError(try controller.install(now: Date(timeIntervalSince1970: 100)))
        var calls = 0
        let response = try OIDCTokenResponse.decode(JSONSerialization.data(withJSONObject: ["token_type": "Bearer",
            "access_token": "rotated-access", "refresh_token": "rotated-refresh", "expires_in": 120, "scope": "openid"]))
        let exchange: OIDCGrantRefresh.Exchange = { _ in calls += 1; return .init(response: response, jwks: Data()) }
        let current = try await controller.accessToken(now: Date(timeIntervalSince1970: 100), exchange: exchange)
        XCTAssertEqual(current, "synthetic-access"); XCTAssertEqual(calls, 0)
        let rotated = try await controller.refresh(now: Date(timeIntervalSince1970: 100), exchange: exchange)
        XCTAssertEqual(rotated, "rotated-access"); XCTAssertEqual(calls, 1)
        let next = try self.store(generation, operations).resume(installation: marker)
        XCTAssertEqual(next.account, resumed.account)
        let nextController = try OIDCGrantRefresh(resuming: next)
        let nextAccess = try await nextController.accessToken(now: Date(timeIntervalSince1970: 101), exchange: exchange)
        XCTAssertEqual(nextAccess, "rotated-access"); XCTAssertEqual(calls, 1)
        XCTAssertFalse(String(describing: resumed).contains("synthetic-access"))
        XCTAssertFalse(String(describing: resumed.account).contains("synthetic-subject"))
    }

    @MainActor func testMissingChangedMarkerClosesExistingControllerAndPreservesKeychain() async throws {
        for sameGeneration in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = OIDCInstallationMarker(directory: directory), generation = UUID(), operations = Operations()
            let installation = try marker.createForExplicitSignIn(generation: generation), store = try store(generation, operations)
            try store.save(record(generation)); try store.bind(binding(), domainGrant: proof().grant, installation: installation)
            let controller = try OIDCGrantRefresh(resuming: store.resume(installation: marker))
            let before = operations.item![kSecValueData as String] as! Data
            try marker.remove(installation)
            XCTAssertThrowsError(try store.resume(installation: marker))
            var calls = 0
            let exchange: OIDCGrantRefresh.Exchange = { _ in calls += 1; throw OIDCGrantFailure.invalidResponse }
            do { _ = try await controller.accessToken(now: Date(timeIntervalSince1970: 100), exchange: exchange); XCTFail("Missing marker cannot expose a token") }
            catch { XCTAssertEqual(error as? OIDCGrantFailure, .reauthenticationRequired) }
            _ = try marker.createForExplicitSignIn(generation: sameGeneration ? generation : UUID())
            XCTAssertThrowsError(try store.resume(installation: marker))
            XCTAssertEqual(operations.item?[kSecValueData as String] as? Data, before); XCTAssertEqual(calls, 0)
        }
    }

    @MainActor func testBindingWriteFailureWrongClientsAndIdentitySwitchCannotAuthorizeResume() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = OIDCInstallationMarker(directory: directory), generation = UUID(), operations = Operations()
        let installation = try marker.createForExplicitSignIn(generation: generation), store = try store(generation, operations)
        try store.save(record(generation))
        let otherClients = try MASPublicClients(matrix: "01JPHNMXPQ7R8S9T0V2W3X4Y5X", domain: "01JPHNDXPQ7R8S9T0V2W3X4Y5X")
        XCTAssertThrowsError(try store.bind(binding(clients: otherClients), domainGrant: proof(clients: otherClients).grant, installation: installation))
        let foreignResponse = try proof(access: "other-response-access")
        XCTAssertThrowsError(try store.bind(foreignResponse.binding, domainGrant: foreignResponse.grant, installation: installation))
        XCTAssertThrowsError(try store.resume(installation: marker))
        operations.failure = "update"
        XCTAssertThrowsError(try store.bind(binding(), domainGrant: proof().grant, installation: installation))
        operations.failure = nil; XCTAssertThrowsError(try store.resume(installation: marker))
        try store.bind(binding(), domainGrant: proof().grant, installation: installation)
        let before = operations.item![kSecValueData as String] as! Data
        XCTAssertThrowsError(try store.bind(binding(principal: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"), domainGrant: proof().grant, installation: installation))
        let initial = try record(generation)
        let other = OIDCStoredGrant(generation: generation, issuer: initial.issuer, clientID: initial.clientID,
            subject: "foreign-subject", accessToken: initial.accessToken, refreshToken: initial.refreshToken,
            expiresAt: initial.expiresAt, phase: .ready, attempt: nil)
        XCTAssertThrowsError(try store.save(other))
        XCTAssertEqual(operations.item?[kSecValueData as String] as? Data, before)
    }

    @MainActor func testInterruptedSpendCannotResumeOrBeReboundAndMeMustMatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = OIDCInstallationMarker(directory: directory), generation = UUID(), operations = Operations()
        let installation = try marker.createForExplicitSignIn(generation: generation), store = try store(generation, operations)
        try store.save(record(generation)); try store.bind(binding(), domainGrant: proof().grant, installation: installation)
        let resume = try store.resume(installation: marker)
        for changed in ["good", "issuer", "subject", "principal"] {
            let me = try NativeAPI.decode(OIDCMe.self, from: JSONSerialization.data(withJSONObject: [
                "issuer": changed == "issuer" ? "https://foreign.test/" : resume.account.issuer,
                "subject": changed == "subject" ? "foreign-subject" : resume.account.subject,
                "principal": changed == "principal" ? "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb" : resume.account.principal.rawValue]))
            if changed == "good" { XCTAssertNoThrow(try resume.account.reconcile(me)) }
            else { XCTAssertThrowsError(try resume.account.reconcile(me)) }
        }
        let controller = try OIDCGrantRefresh(resuming: store.resume(installation: marker))
        var refreshRequests = 0
        do {
            _ = try await controller.refresh(now: Date(timeIntervalSince1970: 301)) { _ in
                refreshRequests += 1
                throw URLError(.networkConnectionLost)
            }
            XCTFail("an ambiguous refresh response must not release the old grant")
        } catch {
            XCTAssertEqual(error as? OIDCGrantFailure, .reauthenticationRequired)
        }
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(try store.load()?.phase, .spending)
        XCTAssertThrowsError(try store.resume(installation: marker)) {
            XCTAssertEqual($0 as? OIDCGrantFailure, .refreshInterrupted)
        }
        XCTAssertThrowsError(try OIDCGrantRefresh(resuming: resume))
        XCTAssertThrowsError(try store.bind(binding(), domainGrant: proof().grant, installation: installation))
        XCTAssertEqual(try store.load()?.phase, .spending)
    }

    @MainActor func testMarkerRemovalDuringRefreshCannotRestoreAccessOrOverwriteSurvivors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = OIDCInstallationMarker(directory: directory), generation = UUID(), operations = Operations()
        let installation = try marker.createForExplicitSignIn(generation: generation), store = try store(generation, operations)
        let proof = try proof()
        try store.save(record(generation)); try store.bind(proof.binding, domainGrant: proof.grant, installation: installation)
        let controller = try OIDCGrantRefresh(resuming: store.resume(installation: marker))
        let response = try OIDCTokenResponse.decode(JSONSerialization.data(withJSONObject: ["token_type": "Bearer", "scope": "openid",
            "access_token": "new-access-must-not-escape", "refresh_token": "new-refresh", "expires_in": 120]))
        var calls = 0
        let exchange: OIDCGrantRefresh.Exchange = { _ in
            calls += 1
            XCTAssertEqual(try store.load()?.phase, .spending)
            await Task.yield()
            try marker.remove(installation)
            return .init(response: response, jwks: Data())
        }
        do { _ = try await controller.refresh(now: Date(timeIntervalSince1970: 100), exchange: exchange); XCTFail("A revoked local context cannot accept a delayed reply") }
        catch { XCTAssertEqual(error as? OIDCGrantFailure, .reauthenticationRequired) }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try store.load()?.phase, .spending)
        XCTAssertEqual(try store.load()?.accessToken, "synthetic-access")
        XCTAssertEqual(try store.load()?.refreshToken, "synthetic-refresh")
        XCTAssertThrowsError(try store.resume(installation: marker))
    }

    @MainActor func testAtomicReplacementRecreatedAdapterAndExactPrivateAttributes() throws {
        let generation = UUID(), operations = Operations(), first = try record(generation)
        let store = try store(generation, operations)
        try store.save(first)
        let spending = try record(generation, phase: .spending)
        try store.save(spending)
        XCTAssertEqual(operations.calls, ["read", "add", "read", "read", "update", "read"])
        XCTAssertFalse(operations.calls.contains("delete"))
        XCTAssertEqual(try self.store(generation, operations).load(), spending)
        for query in operations.queries {
            XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, "7D5FC62RXD.com.atum.mobile")
            XCTAssertEqual(query[kSecAttrAccount as String] as? String, generation.uuidString)
            XCTAssertEqual(query[kSecAttrService as String] as? String, "com.atum.mobile.oidc.domain.v1")
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertNil(query[kSecAttrLabel as String]) // No subject/email in searchable metadata.
        }
        XCTAssertEqual(operations.item?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        let envelope = try JSONSerialization.jsonObject(with: operations.item![kSecValueData as String] as! Data) as! [String: Any]
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual((envelope["grant"] as? [String: Any])?["phase"] as? String, "spending")
    }

    @MainActor func testWrongAttributesAndCorruptRecordsArePreserved() throws {
        for variant in ["weak", "sync", "shared", "foreign-generation", "corrupt", "unknown-version"] {
            let generation = UUID(), operations = Operations(), record = try record(generation)
            let store = try store(generation, operations)
            try store.save(record)
            switch variant {
            case "weak": operations.item?[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            case "sync": operations.item?[kSecAttrSynchronizable as String] = true
            case "shared": operations.item?[kSecAttrAccessGroup as String] = "7D5FC62RXD.com.atum.mobile.matrix"
            case "foreign-generation": operations.item?[kSecAttrAccount as String] = UUID().uuidString
            case "corrupt": operations.item?[kSecValueData as String] = Data("broken".utf8)
            default:
                let data = operations.item![kSecValueData as String] as! Data
                var envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                envelope["version"] = 2; operations.item?[kSecValueData as String] = try JSONSerialization.data(withJSONObject: envelope)
            }
            let before = operations.item![kSecValueData as String] as! Data
            operations.calls = []
            XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? OIDCGrantFailure, .storageUnavailable) }
            XCTAssertThrowsError(try store.save(record))
            XCTAssertEqual(operations.calls, ["read", "read"])
            XCTAssertEqual(operations.item?[kSecValueData as String] as? Data, before)
        }
    }

    @MainActor func testWriteFailuresAndFailedReadbackNeverReportSuccessOrRetry() throws {
        for failure in ["read", "add", "update", "readback"] {
            let generation = UUID(), operations = Operations(), record = try record(generation)
            let store = try store(generation, operations)
            if failure == "update" || failure == "readback" { try store.save(record) }
            let before = operations.item?[kSecValueData as String] as? Data
            operations.calls = []; operations.failure = failure; operations.badReadback = failure == "readback"
            XCTAssertThrowsError(try store.save(self.record(generation, phase: .spending))) {
                XCTAssertEqual($0 as? OIDCGrantFailure, .storageUnavailable)
            }
            XCTAssertFalse(operations.calls.contains("delete"))
            XCTAssertLessThanOrEqual(operations.calls.filter { $0 == "add" || $0 == "update" }.count, 1)
            if failure != "readback" { XCTAssertEqual(operations.item?[kSecValueData as String] as? Data, before) }
        }
    }

    @MainActor func testRemovalTargetsOnlyItsExactGenerationAndChecksReadback() throws {
        let generation = UUID(), operations = Operations(), store = try store(generation, operations)
        try store.save(record(generation)); operations.calls = []; operations.failure = "delete"
        XCTAssertThrowsError(try store.remove()); XCTAssertNotNil(operations.item)
        XCTAssertEqual(operations.calls, ["read", "delete"])
        operations.failure = nil; operations.calls = []
        try store.remove(); XCTAssertEqual(operations.calls, ["read", "delete", "read"])
        XCTAssertNil(try store.load())
        try store.remove() // Idempotent exact-record removal.
        let query = operations.queries.last!
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, generation.uuidString)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, OIDCDomainKeychain.accessGroup)
        XCTAssertNotNil(query[kSecAttrService as String])
    }

    @MainActor func testWrongGrantBindingOrInvalidJournalMakesNoSecurityCall() throws {
        let generation = UUID(), operations = Operations(), store = try store(generation, operations)
        let good = try record(generation)
        let bad = [try record(UUID()), OIDCStoredGrant(generation: generation, issuer: good.issuer, clientID: try clients().matrix,
            subject: good.subject, accessToken: good.accessToken, refreshToken: good.refreshToken, expiresAt: good.expiresAt,
            phase: .ready, attempt: nil), OIDCStoredGrant(generation: generation, issuer: good.issuer, clientID: good.clientID,
            subject: good.subject, accessToken: "bad\r\nheader", refreshToken: good.refreshToken, expiresAt: good.expiresAt,
            phase: .ready, attempt: nil), OIDCStoredGrant(generation: generation, issuer: good.issuer, clientID: good.clientID,
            subject: good.subject, accessToken: good.accessToken, refreshToken: good.refreshToken, expiresAt: good.expiresAt,
            phase: .spending, attempt: nil)]
        for record in bad { XCTAssertThrowsError(try store.save(record)) }
        XCTAssertTrue(operations.calls.isEmpty)
    }
}
