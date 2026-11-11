import XCTest
import Foundation
import Security
@testable import AtumNativeAPI

/// W4 E3, coordinator decision 11: an expired or stranded session shows
/// sign-in; "Đăng nhập lại" moves the stranded records aside, never deleting
/// or overwriting them, and a fresh sign-in starts beside them. Driven on an
/// in-memory Keychain with several items (the real Security calls' shapes),
/// from a launch with a seeded `.spending` record: the refresh-token spend
/// cut short that strands custody today.
final class StrandedSessionArchiveTests: XCTestCase {
    private typealias Policy = MobileSessionContinuityPolicy

    // MARK: An in-memory Keychain with several items

    /// Matches the queries custody, the account service and the archive
    /// send: service, account, access group and synchronization select items;
    /// an update may change any of them and fails, changing nothing, when the
    /// result would collide with another item.
    private final class Keychain: MatrixKeychainReading, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [[String: Any]] = []
        private var log: [String] = []
        var copyFailure: OSStatus?
        var failingUpdate: Int?

        var items: [[String: Any]] { lock.withLock { stored } }
        var calls: [String] { lock.withLock { log } }

        func item(service: String) -> [String: Any]? { items.first { $0[kSecAttrService as String] as? String == service } }
        func items(service: String) -> [[String: Any]] { items.filter { $0[kSecAttrService as String] as? String == service } }

        func seed(_ item: [String: Any]) { lock.withLock { stored.append(item) } }

        private static func key(_ item: [String: Any]) -> [String] {
            [item[kSecAttrService as String] as? String ?? "", item[kSecAttrAccount as String] as? String ?? "",
             item[kSecAttrAccessGroup as String] as? String ?? "",
             String(item[kSecAttrSynchronizable as String] as? Bool ?? false)]
        }

        private static func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
            for attribute in [kSecAttrService, kSecAttrAccount, kSecAttrAccessGroup] as [CFString] {
                if let wanted = query[attribute as String] as? String,
                   item[attribute as String] as? String != wanted { return false }
            }
            if let wanted = query[kSecAttrSynchronizable as String] {
                if wanted as? String == kSecAttrSynchronizableAny as String { return true }
                if let value = wanted as? Bool, (item[kSecAttrSynchronizable as String] as? Bool ?? false) != value {
                    return false
                }
            }
            return true
        }

        func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
            lock.withLock {
                log.append("copy")
                if let copyFailure { return (copyFailure, nil) }
                let found = stored.filter { Self.matches($0, query) }
                guard !found.isEmpty else { return (errSecItemNotFound, nil) }
                let withData = query[kSecReturnData as String] as? Bool == true
                let shaped = found.map { item -> [String: Any] in
                    var copy = item
                    if !withData { copy.removeValue(forKey: kSecValueData as String) }
                    return copy
                }
                if query[kSecMatchLimit as String] as? String == kSecMatchLimitAll as String {
                    return (errSecSuccess, shaped as CFArray)
                }
                return (errSecSuccess, shaped[0] as CFDictionary)
            }
        }

        func add(_ attributes: [String: Any]) -> OSStatus {
            lock.withLock {
                log.append("add")
                var item = attributes
                item.removeValue(forKey: kSecUseDataProtectionKeychain as String)
                guard !stored.contains(where: { Self.key($0) == Self.key(item) }) else { return errSecDuplicateItem }
                stored.append(item)
                return errSecSuccess
            }
        }

        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            lock.withLock {
                log.append("update")
                if failingUpdate == log.filter({ $0 == "update" }).count { return errSecInteractionNotAllowed }
                let indices = stored.indices.filter { Self.matches(stored[$0], query) }
                guard !indices.isEmpty else { return errSecItemNotFound }
                var result = stored
                for index in indices { result[index].merge(attributes) { _, new in new } }
                let keys = result.map(Self.key)
                guard Set(keys.map { $0.joined(separator: "|") }).count == keys.count else { return errSecDuplicateItem }
                stored = result
                return errSecSuccess
            }
        }

        func delete(_ query: [String: Any]) -> OSStatus {
            lock.withLock { log.append("delete") }
            return errSecParam
        }
    }

    @MainActor private final class Operations: OIDCKeychainOperations {
        let keychain: Keychain
        init(_ keychain: Keychain) { self.keychain = keychain }
        func copy(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) { keychain.copy(query) }
        func add(_ attributes: [String: Any]) -> OSStatus { keychain.add(attributes) }
        func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
            keychain.update(query, attributes: attributes)
        }
        func delete(_ query: [String: Any]) -> OSStatus { keychain.delete(query) }
    }

    // MARK: A phone with a stranded session

    private static func clients() throws -> MASPublicClients {
        try .init(matrix: "01JPHNMXPQ7R8S9T0V2W3X4Y5Z", domain: "01JPHNDXPQ7R8S9T0V2W3X4Y5Z")
    }
    private static func metadata() throws -> MASMetadata {
        try .decode(JSONSerialization.data(withJSONObject: ["issuer": "https://auth.atum.test/",
            "authorization_endpoint": "https://auth.atum.test/authorize", "token_endpoint": "https://auth.atum.test/token",
            "jwks_uri": "https://auth.atum.test/keys", "revocation_endpoint": "https://auth.atum.test/revoke",
            "id_token_signing_alg_values_supported": ["ES256"], "code_challenge_methods_supported": ["S256"]]),
            expectedIssuer: "https://auth.atum.test/")
    }
    private static let key = Data(repeating: 42, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")

    private struct Phone {
        let keychain: Keychain
        let operations: Operations
        let marker: OIDCInstallationMarker
        let directory: URL
        let generation: UUID
        let custody: MatrixSessionKeychain
        let domain: OIDCDomainKeychain
    }

    @MainActor private func phone() throws -> Phone {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let generation = UUID()
        let marker = OIDCInstallationMarker(directory: directory)
        _ = try marker.createForExplicitSignIn(generation: generation)
        let keychain = Keychain()
        let operations = Operations(keychain)
        let custody = MatrixSessionKeychain(generation: generation, clients: try Self.clients(),
            metadata: try Self.metadata(), operations: operations,
            refreshLockURL: directory.appendingPathComponent("refresh.lock"))
        let domain = OIDCDomainKeychain(generation: generation, clients: try Self.clients(),
                                        metadata: try Self.metadata(), operations: operations)
        return Phone(keychain: keychain, operations: operations, marker: marker, directory: directory,
                     generation: generation, custody: custody, domain: domain)
    }

    @MainActor private func device(_ id: String = "P2-SYNTHETIC") throws -> MatrixAuthenticatedDevice {
        let whoami = try JSONSerialization.data(withJSONObject: ["user_id": "@p2-synthetic:atum.invalid",
                                                                 "device_id": id, "is_guest": false])
        return try MatrixAuthenticatedDevice.delivered(whoami, grant: MatrixCustodyTests.grant(.matrix(deviceID: id)),
                                                       requested: id)
    }

    /// Signed in (custody ready, an account-service record), then a renewal
    /// whose spend was cut short: custody journaled the spend and refuses.
    @MainActor private func strandedPhone() async throws -> Phone {
        let phone = try phone()
        let prepared = try phone.custody.prepare(device: device(), marker: phone.marker,
                                                 requestStartedAt: Date(timeIntervalSince1970: 100))
        _ = try phone.custody.commitPrepared(prepared, marker: phone.marker, curve25519: Self.key, ed25519: Self.key)
        try phone.domain.save(OIDCStoredGrant(generation: phone.generation, issuer: try Self.metadata().issuer,
                                              clientID: try Self.clients().domain, subject: "synthetic-subject",
                                              accessToken: "domain-access", refreshToken: "domain-refresh",
                                              expiresAt: Date(timeIntervalSince1970: 400), phase: .ready, attempt: nil))
        let refresh = try OIDCGrantRefresh(resuming: phone.custody.resumeGrantForRefresh(marker: phone.marker))
        do {
            _ = try await refresh.accessToken(now: Date(timeIntervalSince1970: 300)) { _ in
                throw OIDCGrantFailure.invalidResponse // the network dropped mid-spend
            }
            XCTFail("the cut-short spend must not hand out a token")
        } catch {}
        return phone
    }

    @MainActor private func custodyGrant(_ phone: Phone) -> Policy.CustodyGrant {
        Policy.custodyGrant { try phone.custody.resume(marker: phone.marker).session.expiresAt }
    }

    private func reader(_ phone: Phone) throws -> MatrixSessionReader {
        MatrixSessionReader(clients: try Self.clients(), metadata: try Self.metadata(), operations: phone.keychain)
    }

    private func data(_ item: [String: Any]?) -> Data? { item?[kSecValueData as String] as? Data }

    // MARK: Tests

    @MainActor
    func testDomainOnlyRecoveryArchivesInterruptedGrantAndKeepsMatrixInstallationLive() throws {
        let phone = try phone()
        defer { try? FileManager.default.removeItem(at: phone.directory) }
        let prepared = try phone.custody.prepare(
            device: device(), marker: phone.marker,
            requestStartedAt: Date(timeIntervalSince1970: 100)
        )
        let ticket = try phone.custody.commitPrepared(
            prepared, marker: phone.marker, curve25519: Self.key, ed25519: Self.key
        )
        try phone.domain.save(OIDCStoredGrant(
            generation: phone.generation, issuer: try Self.metadata().issuer,
            clientID: try Self.clients().domain, subject: "synthetic-subject",
            accessToken: "domain-access", refreshToken: "domain-refresh",
            expiresAt: Date(timeIntervalSince1970: 300), phase: .spending,
            attempt: UUID()
        ))

        let matrixBefore = try XCTUnwrap(data(phone.keychain.item(service: MatrixCustodyRecord.service)))
        let domainBefore = try XCTUnwrap(data(phone.keychain.item(service: OIDCDomainKeychain.service)))
        let installationBefore = try XCTUnwrap(phone.marker.load())
        XCTAssertEqual(Policy.outcome(for: .domain(recordPresent: true)), .productWithoutDomain)
        XCTAssertThrowsError(try phone.domain.resume(installation: phone.marker)) {
            XCTAssertEqual($0 as? OIDCGrantFailure, .refreshInterrupted)
        }

        let archive = StrandedSessionArchive(marker: phone.marker, operations: phone.operations)
        XCTAssertEqual(try archive.archiveDomain(), 1)
        XCTAssertEqual(data(phone.keychain.item(service: MatrixCustodyRecord.service)), matrixBefore)
        XCTAssertEqual(data(phone.keychain.item(service: StrandedSessionArchive.domainArchiveService)),
                       domainBefore)
        XCTAssertNil(phone.keychain.item(service: OIDCDomainKeychain.service))
        XCTAssertEqual(try phone.marker.load(), installationBefore)
        XCTAssertEqual(try phone.custody.resume(marker: phone.marker).session, ticket.session)
        XCTAssertNoThrow(try phone.domain.requireEmptyForSignIn(
            installation: installationBefore,
            clients: Self.clients(), metadata: Self.metadata()
        ))
        XCTAssertFalse(phone.keychain.calls.contains("delete"))
    }

    @MainActor
    func testAStrandedSpendShowsSignInAndIsArchivedNeverDeletedThenAFreshSignInStartsBeside() async throws {
        let phone = try await strandedPhone()
        defer { try? FileManager.default.removeItem(at: phone.directory) }

        // The launch: custody refuses, so the sign-in screen, not a retry loop.
        XCTAssertThrowsError(try phone.custody.resume(marker: phone.marker)) {
            XCTAssertEqual($0 as? MatrixCustodyFailure, .refreshRequired)
        }
        XCTAssertEqual(custodyGrant(phone), .refused)
        XCTAssertEqual(Policy.outcome(for: .matrix(custody: custodyGrant(phone))), .sessionExpired)
        XCTAssertEqual(Policy.signInAgainStep(custody: custodyGrant(phone)), .archiveThenSignIn)
        // Today every sign-in preflight refuses this phone.
        XCTAssertThrowsError(try reader(phone).requireAbsent())
        XCTAssertThrowsError(try phone.domain.requireAbsentForExplicitSignIn())
        XCTAssertThrowsError(try phone.marker.createForExplicitSignIn(generation: UUID()))

        let matrixBytes = try XCTUnwrap(data(phone.keychain.item(service: MatrixCustodyRecord.service)))
        let domainBytes = try XCTUnwrap(data(phone.keychain.item(service: OIDCDomainKeychain.service)))
        let markerBytes = try Data(contentsOf: phone.directory.appendingPathComponent("installation-v1.json"))
        let archive = StrandedSessionArchive(marker: phone.marker, operations: phone.operations)
        XCTAssertEqual(try archive.survivors(), .init(matrixRecords: 1, domainRecords: 1))

        let id = UUID()
        let receipt = try archive.archive(id: id)
        XCTAssertEqual(receipt, .init(matrixRecords: 1, domainRecords: 1, installationMarkers: 1))
        XCTAssertEqual(receipt.logCode, "m1_d1_i1")

        // Nothing deleted or overwritten: the same two items, the same bytes,
        // access groups and protection, under the archive services.
        XCTAssertFalse(phone.keychain.calls.contains("delete"))
        XCTAssertEqual(phone.keychain.items.count, 2)
        let archivedMatrix = try XCTUnwrap(phone.keychain.item(service: StrandedSessionArchive.matrixArchiveService))
        XCTAssertEqual(data(archivedMatrix), matrixBytes)
        XCTAssertEqual(archivedMatrix[kSecAttrAccessGroup as String] as? String, MatrixCustodyRecord.accessGroup)
        XCTAssertEqual(archivedMatrix[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertEqual(archivedMatrix[kSecAttrAccount as String] as? String, "\(id.uuidString).0.active-v1")
        let archivedDomain = try XCTUnwrap(phone.keychain.item(service: StrandedSessionArchive.domainArchiveService))
        XCTAssertEqual(data(archivedDomain), domainBytes)
        XCTAssertEqual(archivedDomain[kSecAttrAccessGroup as String] as? String, OIDCDomainKeychain.accessGroup)
        XCTAssertEqual(archivedDomain[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        let archivedMarker = phone.directory.appendingPathComponent("archived/installation-\(id.uuidString).json")
        XCTAssertEqual(try Data(contentsOf: archivedMarker), markerBytes)

        // Every sign-in preflight now passes, and a second archive moves nothing.
        XCTAssertNoThrow(try reader(phone).requireAbsent())
        XCTAssertNoThrow(try phone.domain.requireAbsentForExplicitSignIn())
        XCTAssertNil(try phone.marker.load())
        XCTAssertEqual(try archive.archive(), .init(matrixRecords: 0, domainRecords: 0, installationMarkers: 0))

        // The fresh sign-in, beside the archive: a new installation and
        // generation, a new custody record; the archive is untouched.
        let generation = UUID()
        _ = try phone.marker.createForExplicitSignIn(generation: generation)
        let fresh = MatrixSessionKeychain(generation: generation, clients: try Self.clients(),
                                          metadata: try Self.metadata(), operations: phone.operations,
                                          refreshLockURL: phone.directory.appendingPathComponent("refresh.lock"))
        let prepared = try fresh.prepare(device: device("P2-FRESH"), marker: phone.marker,
                                         requestStartedAt: Date(timeIntervalSince1970: 500))
        let ready = try fresh.commitPrepared(prepared, marker: phone.marker, curve25519: Self.key, ed25519: Self.key)
        XCTAssertEqual(try fresh.resume(marker: phone.marker).session, ready.session)
        XCTAssertEqual(ready.session.deviceID, "P2-FRESH")
        XCTAssertEqual(data(phone.keychain.item(service: StrandedSessionArchive.matrixArchiveService)), matrixBytes)
        XCTAssertEqual(data(phone.keychain.item(service: StrandedSessionArchive.domainArchiveService)), domainBytes)
        XCTAssertFalse(phone.keychain.calls.contains("delete"))
        // The new session is the one custody and the extension read.
        XCTAssertNoThrow(try reader(phone).loadCurrent(now: Date(timeIntervalSince1970: 600)))
    }

    @MainActor
    func testAnArchiveCutShortStillReadsStrandedAndTheNextTapFinishesIt() async throws {
        let phone = try await strandedPhone()
        defer { try? FileManager.default.removeItem(at: phone.directory) }
        let archive = StrandedSessionArchive(marker: phone.marker, operations: phone.operations)
        // The custody relabel goes through; the account-service one fails.
        phone.keychain.failingUpdate = phone.keychain.calls.filter { $0 == "update" }.count + 2
        XCTAssertThrowsError(try archive.archive()) {
            XCTAssertEqual($0 as? MatrixCustodyFailure, .storageUnavailable)
        }
        XCTAssertNotNil(phone.keychain.item(service: StrandedSessionArchive.matrixArchiveService))
        XCTAssertNotNil(phone.keychain.item(service: OIDCDomainKeychain.service))
        XCTAssertNotNil(try phone.marker.load(), "the marker goes last")
        // The next launch: the marker is there and custody refuses (its record
        // is archived), so the sign-in screen again, never a retry loop.
        XCTAssertEqual(custodyGrant(phone), .refused)
        XCTAssertEqual(Policy.signInAgainStep(custody: custodyGrant(phone)), .archiveThenSignIn)

        phone.keychain.failingUpdate = nil
        XCTAssertEqual(try archive.archive(), .init(matrixRecords: 0, domainRecords: 1, installationMarkers: 1))
        XCTAssertNoThrow(try reader(phone).requireAbsent())
        XCTAssertNoThrow(try phone.domain.requireAbsentForExplicitSignIn())
        XCTAssertNil(try phone.marker.load())
        XCTAssertEqual(phone.keychain.items.count, 2)
        XCTAssertFalse(phone.keychain.calls.contains("delete"))
    }

    @MainActor
    func testAnUnreadableKeychainMovesNothing() async throws {
        let phone = try await strandedPhone()
        defer { try? FileManager.default.removeItem(at: phone.directory) }
        let before = phone.keychain.items.map { $0[kSecAttrService as String] as? String }
        let updates = phone.keychain.calls.filter { $0 == "update" }.count
        phone.keychain.copyFailure = errSecInteractionNotAllowed
        let archive = StrandedSessionArchive(marker: phone.marker, operations: phone.operations)
        XCTAssertThrowsError(try archive.survivors())
        XCTAssertThrowsError(try archive.archive())
        XCTAssertEqual(Policy.custodyGrant { try phone.custody.resume(marker: phone.marker).session.expiresAt },
                       .unreadable)
        XCTAssertEqual(Policy.signInAgainStep(custody: .unreadable), .retryLater)
        phone.keychain.copyFailure = nil
        XCTAssertEqual(phone.keychain.items.map { $0[kSecAttrService as String] as? String }, before)
        XCTAssertEqual(phone.keychain.calls.filter { $0 == "update" }.count, updates, "nothing relabelled")
        XCTAssertNotNil(try phone.marker.load())
    }

    @MainActor
    func testRecordsThatSurvivedAReinstallAreStrandedAndAllMoveAside() async throws {
        let phone = try await strandedPhone()
        defer { try? FileManager.default.removeItem(at: phone.directory) }
        // A reinstall: the marker (app data) is gone, Keychain items survive,
        // with a legacy record under a UUID account beside the current one.
        var legacy = try XCTUnwrap(phone.keychain.item(service: MatrixCustodyRecord.service))
        legacy[kSecAttrAccount as String] = UUID().uuidString
        legacy[kSecValueData as String] = Data("legacy-envelope".utf8)
        phone.keychain.seed(legacy)
        try FileManager.default.removeItem(at: phone.directory.appendingPathComponent("installation-v1.json"))
        XCTAssertNil(try phone.marker.load())

        let archive = StrandedSessionArchive(marker: phone.marker, operations: phone.operations)
        let survivors = try archive.survivors()
        XCTAssertEqual(survivors, .init(matrixRecords: 2, domainRecords: 1))
        XCTAssertFalse(survivors.isEmpty)
        XCTAssertEqual(Policy.outcome(for: .recordsWithoutInstallation), .sessionExpired)
        XCTAssertEqual(Policy.signInAgainStep(custody: nil), .archiveThenSignIn)

        let bytes = Set(phone.keychain.items(service: MatrixCustodyRecord.service).compactMap { data($0) })
        XCTAssertEqual(try archive.archive(), .init(matrixRecords: 2, domainRecords: 1, installationMarkers: 0))
        let archived = phone.keychain.items(service: StrandedSessionArchive.matrixArchiveService)
        XCTAssertEqual(Set(archived.compactMap { data($0) }), bytes)
        XCTAssertEqual(Set(archived.compactMap { $0[kSecAttrAccount as String] as? String }).count, 2)
        XCTAssertTrue(try archive.survivors().isEmpty)
        XCTAssertNoThrow(try reader(phone).requireAbsent())
        XCTAssertFalse(phone.keychain.calls.contains("delete"))
    }

    @MainActor
    func testAnArchiveLabelThatIsTakenChangesNothing() async throws {
        let phone = try await strandedPhone()
        defer { try? FileManager.default.removeItem(at: phone.directory) }
        let id = UUID()
        var squatter = try XCTUnwrap(phone.keychain.item(service: MatrixCustodyRecord.service))
        squatter[kSecAttrService as String] = StrandedSessionArchive.matrixArchiveService
        squatter[kSecAttrAccount as String] = "\(id.uuidString).0.active-v1"
        squatter[kSecValueData as String] = Data("an earlier archive".utf8)
        phone.keychain.seed(squatter)
        let original = data(phone.keychain.item(service: MatrixCustodyRecord.service))
        let archive = StrandedSessionArchive(marker: phone.marker, operations: phone.operations)
        XCTAssertThrowsError(try archive.archive(id: id))
        XCTAssertEqual(data(phone.keychain.item(service: MatrixCustodyRecord.service)), original)
        XCTAssertEqual(data(phone.keychain.items(service: StrandedSessionArchive.matrixArchiveService).first),
                       Data("an earlier archive".utf8))
        XCTAssertNotNil(try phone.marker.load())
    }

    func testSignInAgainIsDecidedFromCustodyAtTheTap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Policy.signInAgainStep(custody: .ready(expiresAt: now)), .launchAgain)
        XCTAssertEqual(Policy.signInAgainStep(custody: .refused), .archiveThenSignIn)
        XCTAssertEqual(Policy.signInAgainStep(custody: .unreadable), .retryLater)
        XCTAssertEqual(Policy.signInAgainStep(custody: nil), .archiveThenSignIn)
    }

    func testInTheProductARefusalShowsSignInOnceTheWorkingTokenExpires() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(Policy.secondsUntilSignIn(custodyRefused: false, sessionExpiresAt: now, now: now))
        XCTAssertEqual(Policy.secondsUntilSignIn(custodyRefused: true, sessionExpiresAt: now.addingTimeInterval(55),
                                                 now: now), 55)
        XCTAssertEqual(Policy.secondsUntilSignIn(custodyRefused: true, sessionExpiresAt: now.addingTimeInterval(-30),
                                                 now: now), 0)
    }
}
