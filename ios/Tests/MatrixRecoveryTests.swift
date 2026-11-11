import XCTest
import Foundation
import Security
@testable import AtumNativeAPI

final class MatrixRecoveryTests: XCTestCase {
    @MainActor private final class Operations: OIDCKeychainOperations {
        var items: [[String: Any]] = []
        var failure: String?
        var additions = 0, replacements = 0, secretReads = 0
        var recoveryItems: [[String: Any]] { items.filter { $0[kSecAttrService as String] as? String == MatrixRecoveryKeychain.service } }
        func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
            let recovery = query[kSecAttrService as String] as? String == MatrixRecoveryKeychain.service
            if recovery && (
                failure == "copy" ||
                    (failure == "readback" && !recoveryItems.isEmpty) ||
                    (failure == "replaceReadback" && replacements > 0)
            ) { return (errSecInteractionNotAllowed, nil) }
            let matches = items.filter { item in
                for key in [kSecAttrService, kSecAttrAccessGroup, kSecAttrAccount] {
                    if let expected = query[key as String] as? String, item[key as String] as? String != expected { return false }
                }
                return true
            }
            if matches.isEmpty { return (errSecItemNotFound, nil) }
            if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                return (errSecSuccess, matches.map { item in
                    var value = item; value.removeValue(forKey: kSecValueData as String); return value
                } as CFArray)
            }
            if recovery { secretReads += 1 }
            return (errSecSuccess, matches[0] as CFDictionary)
        }
        func add(_ attributes: [String: Any]) -> OSStatus {
            let recovery = attributes[kSecAttrService as String] as? String == MatrixRecoveryKeychain.service
            if recovery { additions += 1; if failure == "add" { return errSecInteractionNotAllowed } }
            if items.contains(where: {
                $0[kSecAttrService as String] as? String == attributes[kSecAttrService as String] as? String &&
                $0[kSecAttrAccount as String] as? String == attributes[kSecAttrAccount as String] as? String
            }) { return errSecDuplicateItem }
            items.append(attributes); return errSecSuccess
        }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            let recovery = query[kSecAttrService as String] as? String == MatrixRecoveryKeychain.service
            if recovery {
                replacements += 1
                if failure == "update" { return errSecInteractionNotAllowed }
            }
            guard let index = items.firstIndex(where: { $0[kSecAttrService as String] as? String == query[kSecAttrService as String] as? String }) else { return errSecItemNotFound }
            items[index].merge(attributes) { _, new in new }; return errSecSuccess
        }
        func delete(_ query: [String: Any]) -> OSStatus { XCTFail("Root and session must survive"); return errSecParam }
    }
    @MainActor private struct Context {
        let operations: Operations, session: MatrixCustodyTicket, sessions: MatrixSessionKeychain
        let marker: OIDCInstallationMarker, directory: URL
    }
    @MainActor private func setup() throws -> Context {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let marker = OIDCInstallationMarker(directory: directory), generation = UUID()
        _ = try marker.createForExplicitSignIn(generation: generation)
        let metadata = try MASMetadata.decode(JSONSerialization.data(withJSONObject: [
            "issuer": "https://auth.atum.test/", "authorization_endpoint": "https://auth.atum.test/authorize",
            "token_endpoint": "https://auth.atum.test/token", "jwks_uri": "https://auth.atum.test/keys",
            "revocation_endpoint": "https://auth.atum.test/revoke", "id_token_signing_alg_values_supported": ["ES256"],
            "code_challenge_methods_supported": ["S256"]]), expectedIssuer: "https://auth.atum.test/")
        let operations = Operations(), clients = try MASPublicClients(matrix: "01JPHNMXPQ7R8S9T0V2W3X4Y5Z", domain: "01JPHNDXPQ7R8S9T0V2W3X4Y5Z")
        let sessions = MatrixSessionKeychain(generation: generation, clients: clients, metadata: metadata,
            operations: operations, refreshLockURL: directory.appendingPathComponent("refresh.lock"))
        let whoami = try JSONSerialization.data(withJSONObject: ["user_id": "@p2-synthetic:atum.invalid", "device_id": "P2-SYNTHETIC", "is_guest": false])
        let device = try MatrixAuthenticatedDevice.delivered(whoami, grant: MatrixCustodyTests.grant(), requested: "P2-SYNTHETIC")
        let prepared = try sessions.prepare(device: device, marker: marker, requestStartedAt: Date(timeIntervalSince1970: 100))
        let key = Data(repeating: 42, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let session = try sessions.commitPrepared(prepared, marker: marker, curve25519: key, ed25519: key)
        return Context(operations: operations, session: session, sessions: sessions, marker: marker, directory: directory)
    }
    private func input() throws -> MatrixRecoveryInput {
        let iv = Data(repeating: 1, count: 16).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let mac = Data(repeating: 2, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let json = "{\"algorithm\":\"m.secret_storage.v1.aes-hmac-sha2\",\"iv\":\"\(iv)\",\"mac\":\"\(mac)\"}"
        // Shape-only fake, intentionally not a valid SDK root key. MAC proof is
        // tested with the actual generated SDK in the separate runtime study.
        return try MatrixRecoveryInput(recoveryKey: "p2 synthetic root input", keyID: String(repeating: "P", count: 32), metadataJSON: json)
    }
    @MainActor private func prepare(_ journal: MatrixRecoveryKeychain, _ c: Context, generate: () throws -> MatrixRecoveryInput) throws -> MatrixRecoveryTicket {
        try journal.prepare(session: c.session, sessionStore: c.sessions, marker: c.marker, generate: generate)
    }
    @MainActor func testPreparedRootIsPrivateDeviceOnlyAndFreshProcessUsesIdenticalInput() throws {
        let c = try setup(); defer { try? FileManager.default.removeItem(at: c.directory) }
        let input = try input(), journal = MatrixRecoveryKeychain(operations: c.operations)
        let ticket = try prepare(journal, c) { input }
        let item = try XCTUnwrap(c.operations.recoveryItems.first)
        XCTAssertTrue(item[kSecAttrAccessGroup as String] as? String == OIDCDomainKeychain.accessGroup)
        XCTAssertTrue(item[kSecAttrAccessGroup as String] as? String != MatrixSessionKeychain.accessGroup)
        XCTAssertTrue(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(item[kSecAttrSynchronizable as String] as? Bool, false)
        let fresh = MatrixRecoveryKeychain(operations: c.operations)
        let resumed = try fresh.resumeForExplicitReconciliation(session: c.session, sessionStore: c.sessions, marker: c.marker)
        XCTAssertEqual(resumed.preparedInput, ticket.preparedInput)
        XCTAssertEqual(resumed.preparedInput, input)
        try fresh.recheck(resumed, session: c.session, sessionStore: c.sessions, marker: c.marker)
        var called = false
        XCTAssertThrowsError(try prepare(fresh, c) { called = true; return input })
        XCTAssertFalse(called); XCTAssertEqual(c.operations.additions, 1)
        XCTAssertFalse(String(reflecting: ticket).contains(input.recoveryKey))
    }

    @MainActor func testBoundInputCanBeSavedBeforeRuntimeButNeverCrossesInstallations() throws {
        let c = try setup(); defer { try? FileManager.default.removeItem(at: c.directory) }
        let input = try input(), journal = MatrixRecoveryKeychain(operations: c.operations)
        _ = try prepare(journal, c) { input }
        let installation = try XCTUnwrap(c.marker.load())

        XCTAssertEqual(try journal.currentInput(installation: installation,
                                                marker: c.marker), input)
        let other = OIDCInstallation(id: UUID(), generation: installation.generation)
        XCTAssertThrowsError(try journal.currentInput(installation: other,
                                                      marker: c.marker)) {
            XCTAssertEqual($0 as? MatrixRecoveryFailure, .identityChanged)
        }
    }

    @MainActor func testMatrixRefreshPreservesRecoveryBindingAndPreparedInput() async throws {
        let c = try setup(); defer { try? FileManager.default.removeItem(at: c.directory) }
        let input = try input(), journal = MatrixRecoveryKeychain(operations: c.operations)
        let recovery = try prepare(journal, c) { input }
        let refresh = try OIDCGrantRefresh(resuming: c.sessions.resumeGrantForRefresh(marker: c.marker))
        let scope = "openid urn:matrix:org.matrix.msc2967.client:api:* urn:matrix:org.matrix.msc2967.client:device:P2-SYNTHETIC"
        let response = try OIDCTokenResponse.decode(JSONSerialization.data(withJSONObject: [
            "token_type": "Bearer", "access_token": "rotated-access",
            "refresh_token": "rotated-refresh", "expires_in": 400, "scope": scope]))
        _ = try await refresh.accessToken(now: Date(timeIntervalSince1970: 300)) { _ in
            OIDCRefreshReply(response: response, jwks: Data())
        }
        let current = try c.sessions.resume(marker: c.marker)
        XCTAssertEqual(current.envelope.installationID, c.session.envelope.installationID)
        XCTAssertEqual(current.envelope.issuer, c.session.envelope.issuer)
        XCTAssertEqual(current.envelope.subject, c.session.envelope.subject)
        let resumed = try journal.resumeForExplicitReconciliation(
            session: current, sessionStore: c.sessions, marker: c.marker)
        XCTAssertEqual(resumed.preparedInput, recovery.preparedInput)
        XCTAssertEqual(resumed.preparedInput, input)
    }

    @MainActor func testVerifiedRecoveryAtomicallyReplacesOnlyTheBoundDeviceRoot() throws {
        let c = try setup(); defer { try? FileManager.default.removeItem(at: c.directory) }
        let journal = MatrixRecoveryKeychain(operations: c.operations)
        let original = try input()
        _ = try prepare(journal, c) { original }
        let imported = try MatrixRecoveryInput(
            recoveryKey: "imported server root",
            keyID: "PUBLIC_FIXTU",
            metadataJSON: original.metadataJSON
        )

        let ticket = try journal.replaceAfterVerifiedRecovery(
            imported,
            session: c.session,
            sessionStore: c.sessions,
            marker: c.marker
        )

        XCTAssertEqual(ticket.preparedInput, imported)
        XCTAssertEqual(c.operations.additions, 1)
        XCTAssertEqual(c.operations.replacements, 1)
        XCTAssertEqual(c.operations.recoveryItems.count, 1)
        XCTAssertEqual(
            try journal.resumeForExplicitReconciliation(
                session: c.session,
                sessionStore: c.sessions,
                marker: c.marker
            ).preparedInput,
            imported
        )
    }

    @MainActor func testVerifiedRecoveryReplacementFailsClosedOnUpdateOrReadbackFailure() throws {
        for failure in ["update", "replaceReadback"] {
            let c = try setup(); defer { try? FileManager.default.removeItem(at: c.directory) }
            let journal = MatrixRecoveryKeychain(operations: c.operations)
            let original = try input()
            _ = try prepare(journal, c) { original }
            let imported = try MatrixRecoveryInput(
                recoveryKey: "imported server root",
                keyID: "server-key",
                metadataJSON: original.metadataJSON
            )
            c.operations.failure = failure
            XCTAssertThrowsError(
                try journal.replaceAfterVerifiedRecovery(
                    imported,
                    session: c.session,
                    sessionStore: c.sessions,
                    marker: c.marker
                )
            ) {
                XCTAssertEqual($0 as? MatrixRecoveryFailure, .storageUnavailable)
            }
            XCTAssertEqual(c.operations.additions, 1)
            XCTAssertEqual(c.operations.replacements, 1)
            XCTAssertEqual(c.operations.recoveryItems.count, 1)
        }
    }

    @MainActor func testFreshInstallRecoveryInventoryRefusesSurvivorWithoutGenerating() throws {
        let c = try setup(); defer { try? FileManager.default.removeItem(at: c.directory) }
        let journal = MatrixRecoveryKeychain(operations: c.operations)
        XCTAssertNoThrow(try journal.requireAbsentForExplicitSignIn())
        let input = try input()
        _ = try prepare(journal, c) { input }
        let additions = c.operations.additions
        XCTAssertThrowsError(try journal.requireAbsentForExplicitSignIn()) {
            XCTAssertEqual($0 as? MatrixRecoveryFailure, .survivorRequiresRecovery)
        }
        XCTAssertEqual(c.operations.additions, additions)
        XCTAssertEqual(c.operations.recoveryItems.count, 1)
    }
    @MainActor func testWriteReadbackFailureNeverReleasesInputOrRegeneratesSurvivor() throws {
        for failure in ["copy", "add", "readback"] {
            let c = try setup(); defer { try? FileManager.default.removeItem(at: c.directory) }
            let input = try input(), journal = MatrixRecoveryKeychain(operations: c.operations)
            c.operations.failure = failure; var generated = 0
            XCTAssertThrowsError(try prepare(journal, c) { generated += 1; return input })
            XCTAssertEqual(generated, failure == "copy" ? 0 : 1)
            c.operations.failure = nil
            if failure == "readback" {
                let fresh = MatrixRecoveryKeychain(operations: c.operations)
                let resumed = try fresh.resumeForExplicitReconciliation(session: c.session, sessionStore: c.sessions, marker: c.marker)
                XCTAssertEqual(resumed.preparedInput, input)
                XCTAssertThrowsError(try prepare(fresh, c) { generated += 1; return input })
                XCTAssertEqual(generated, 1)
            }
        }
    }
    @MainActor func testWeakSyncedLegacyAndCoexistingSurvivorsRefuseBeforeSecretRead() throws {
        for failure in ["weak", "sync", "legacy", "two"] {
            let c = try setup(); defer { try? FileManager.default.removeItem(at: c.directory) }
            let input = try input(), journal = MatrixRecoveryKeychain(operations: c.operations)
            _ = try prepare(journal, c) { input }
            let index = try XCTUnwrap(c.operations.items.firstIndex { $0[kSecAttrService as String] as? String == MatrixRecoveryKeychain.service })
            switch failure {
            case "weak": c.operations.items[index][kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            case "sync": c.operations.items[index][kSecAttrSynchronizable as String] = true
            case "legacy": c.operations.items[index][kSecAttrAccount as String] = UUID().uuidString
            default: c.operations.items.append(c.operations.items[index])
            }
            let reads = c.operations.secretReads
            XCTAssertThrowsError(try journal.resumeForExplicitReconciliation(session: c.session, sessionStore: c.sessions, marker: c.marker))
            var generated = false
            XCTAssertThrowsError(try prepare(journal, c) { generated = true; return input })
            XCTAssertFalse(generated); XCTAssertEqual(c.operations.secretReads, reads)
        }
    }
    @MainActor func testMissingMarkerCorruptionChangedBindingAndCachedTicketPreserveRoot() throws {
        for failure in ["marker", "corrupt", "foreign"] {
            let c = try setup(); defer { try? FileManager.default.removeItem(at: c.directory) }
            let input = try input(), journal = MatrixRecoveryKeychain(operations: c.operations)
            let ticket = try prepare(journal, c) { input }
            let index = try XCTUnwrap(c.operations.items.firstIndex { $0[kSecAttrService as String] as? String == MatrixRecoveryKeychain.service })
            if failure == "marker" { try c.marker.remove(try XCTUnwrap(c.marker.load())) }
            else if failure == "corrupt" { c.operations.items[index][kSecValueData as String] = Data("broken".utf8) }
            else {
                var json = try JSONSerialization.jsonObject(with: XCTUnwrap(c.operations.items[index][kSecValueData as String] as? Data)) as! [String: Any]
                var binding = json["binding"] as! [String: Any]; binding["installationID"] = UUID().uuidString; json["binding"] = binding
                c.operations.items[index][kSecValueData as String] = try JSONSerialization.data(withJSONObject: json)
            }
            XCTAssertThrowsError(try journal.recheck(ticket, session: c.session, sessionStore: c.sessions, marker: c.marker))
            XCTAssertThrowsError(try journal.resumeForExplicitReconciliation(session: c.session, sessionStore: c.sessions, marker: c.marker))
            XCTAssertEqual(c.operations.recoveryItems.count, 1); XCTAssertEqual(c.operations.additions, 1)
        }
    }
    func testStorageShapeRejectsIncompleteMetadataAndExtraSecretFields() throws {
        let input = try input()
        for field in ["iv", "mac"] {
            var json = try JSONSerialization.jsonObject(with: Data(input.metadataJSON.utf8)) as! [String: Any]; json.removeValue(forKey: field)
            XCTAssertThrowsError(try MatrixRecoveryInput(recoveryKey: input.recoveryKey, keyID: input.keyID, metadataJSON: String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self)))
        }
        for field in ["passphrase", "key_id", "name", "access_token"] {
            var json = try JSONSerialization.jsonObject(with: Data(input.metadataJSON.utf8)) as! [String: Any]; json[field] = "unexpected"
            XCTAssertThrowsError(try MatrixRecoveryInput(recoveryKey: input.recoveryKey, keyID: input.keyID, metadataJSON: String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self)))
        }
    }
}
