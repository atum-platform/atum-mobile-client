import AtumNativeAPI
import CryptoKit
import Foundation
import MatrixRustSDK
import Network
import XCTest
@testable import AtumMobile

@MainActor
final class MatrixSecurityTests: XCTestCase {
    func testSASRequiresMatchingCurrentEmojiAndNativeCompletion() async throws {
        let native = NativeSAS()
        let controller = makeController(native)
        await controller.request()
        guard case .requested(let id) = controller.state else { return XCTFail() }
        native.emit { $0.didAcceptVerificationRequest() }
        await waitFor { native.actions.contains(.start) }
        native.emit { $0.didStartSasVerification() }
        native.emit { $0.didReceiveVerificationData(data: Self.emoji) }
        await waitFor {
            if case .comparing = controller.state { return true }
            return false
        }
        await controller.compare(UUID(), matches: true)
        XCTAssertFalse(native.actions.contains(.approve))
        await controller.compare(id, matches: true)
        XCTAssertEqual(controller.state, .waitingForPeer(id))
        XCTAssertEqual(native.actions, [.request, .start, .approve])
        native.emit { $0.didFinish() }
        await waitFor { controller.state == .finished(.matched) }
        controller.invalidate()
    }

    func testMismatchCallsNativeDeclineAndSuppressesLateFinish() async throws {
        let native = NativeSAS()
        let controller = makeController(native)
        let id = await beginComparison(controller, native: native)
        await controller.compare(id, matches: false)
        native.emit { $0.didFinish() }
        await controller.compare(id, matches: true)
        XCTAssertEqual(controller.state, .finished(.mismatch))
        XCTAssertEqual(native.actions, [.request, .start, .decline])
        controller.invalidate()
    }

    func testCancelClearsDisplayedSASAndBlocksLateTap() async throws {
        let native = NativeSAS()
        let controller = makeController(native)
        let id = await beginComparison(controller, native: native)
        await controller.cancel(id)
        await controller.compare(id, matches: true)
        native.emit { $0.didFinish() }
        XCTAssertEqual(controller.state, .finished(.cancelled))
        XCTAssertEqual(native.actions, [.request, .start, .cancel])
        controller.invalidate()
    }

    func testIncomingOnlyAcceptsSameAccountAndWaitsForRequesterToStart() async throws {
        let native = NativeSAS()
        let controller = makeController(native)
        await controller.listen()
        native.emit { $0.didReceiveVerificationRequest(details: Self.invite(userID: "@other:example.org")) }
        native.emit { $0.didReceiveVerificationRequest(details: Self.invite(deviceID: "PHONE")) }
        native.emit { $0.didReceiveVerificationRequest(details: Self.invite()) }
        await waitFor {
            if case .incoming = controller.state { return true }
            return false
        }
        guard case .incoming(let offer) = controller.state else { return XCTFail() }
        XCTAssertEqual(native.actions, [.acknowledge])
        await controller.accept(offer.id)
        native.emit { $0.didAcceptVerificationRequest() }
        native.emit { $0.didStartSasVerification() }
        native.emit { $0.didReceiveVerificationData(data: Self.emoji) }
        await waitFor {
            if case .comparing = controller.state { return true }
            return false
        }
        XCTAssertEqual(native.actions, [.acknowledge, .accept])
        native.receivePeerCancel()
        await waitFor { controller.state == .finished(.peerCancelled) }
        await controller.compare(offer.id, matches: true)
        XCTAssertFalse(native.actions.contains(.approve))
        controller.invalidate()
    }

    func testSASDeadlineAndSessionChangeCannotApprove() async throws {
        let native = NativeSAS()
        let timed = makeController(native, timeout: .milliseconds(300))
        await timed.request()
        guard case .requested(let id) = timed.state else { return XCTFail() }
        await waitFor { timed.state == .finished(.timedOut) && native.actions.contains(.cancel) }
        native.emit { $0.didFinish() }
        await timed.compare(id, matches: true)
        XCTAssertEqual(timed.state, .finished(.timedOut))
        timed.invalidate()

        let current = NativeSAS()
        let authority = TestAuthority()
        let controller = MatrixSASVerification(
            userID: "@me:example.org", deviceID: "PHONE",
            requireCurrent: {
                guard authority.current else { throw MatrixSecurityFailure.sessionUnavailable }
            },
            load: { current }
        )
        let oldID = await beginComparison(controller, native: current)
        authority.current = false
        await controller.compare(oldID, matches: true)
        current.emit { $0.didFinish() }
        await waitFor { controller.state == .finished(.cancelled) }
        XCTAssertFalse(current.actions.contains(.approve))
    }

    func testPrivateRequiresAllFourDistinctFacts() {
        for bitmask in 0..<16 {
            let snapshot = MatrixSecuritySnapshot(
                sessionVerified: bitmask & 1 != 0, recoveryEnabled: bitmask & 2 != 0,
                backupEnabled: bitmask & 4 != 0, recoveryKeyConfirmed: bitmask & 8 != 0,
                pendingSaveID: nil
            )
            XCTAssertEqual(snapshot.canCreatePrivateChat, bitmask == 15)
        }
    }

    func testPrivateRoomRecipeAndParticipantEvidence() throws {
        let person = try Self.lookup(kind: "human", user: "@person:example.org")
        let targets = try PrivatePeopleChat.people([person], ownUserID: "@me:example.org")
        let plain = PrivatePeopleChat.parameters(name: nil, isDirect: true, targets: targets)
        let encrypted = PrivatePeopleChat.parameters(
            name: "Fixture", isDirect: false, targets: targets, encrypted: true
        )
        XCTAssertFalse(plain.isEncrypted)
        XCTAssertEqual(plain.historyVisibilityOverride, .shared)
        XCTAssertEqual(encrypted.invite, ["@person:example.org"])
        XCTAssertTrue(encrypted.isEncrypted)
        XCTAssertEqual(encrypted.historyVisibilityOverride, .joined)
        for kind in ["agent", "app", "organization"] {
            let nonHuman = try Self.lookup(kind: kind, user: "@nonhuman:example.org")
            XCTAssertThrowsError(try PrivatePeopleChat.people([person, nonHuman], ownUserID: "@me:example.org")) {
                XCTAssertEqual($0 as? MatrixSecurityFailure, .notHuman)
            }
        }
        XCTAssertThrowsError(try PrivatePeopleChat.people([person, person], ownUserID: "@me:example.org"))
        XCTAssertThrowsError(try PrivatePeopleChat.people([person], ownUserID: "@person:example.org"))
    }

    func testRecoveryReceiptUsesExactDefaultKeyIDAndRejectsEmptyState() {
        XCTAssertEqual(MatrixRecoverySaveStore.defaultKeyID(in: #"{"type":"m.secret_storage.default_key","content":{"key":"one"}}"#), "one")
        XCTAssertEqual(MatrixRecoverySaveStore.defaultKeyID(in: #"{"key":"two"}"#), "two")
        XCTAssertNil(MatrixRecoverySaveStore.defaultKeyID(in: #"{"content":{}}"#))
        XCTAssertNil(MatrixRecoverySaveStore.defaultKeyID(in: #"{"key":"not valid"}"#))
    }

    func testPinnedBinaryBootstrapRecoveryAndRoomCreationAgainstLoopback() async throws {
        let server = try SecurityFixtureHomeserver()
        defer { server.stop() }
        let endpoint = try await server.start()
        let unconfigured = try await fixtureClient(endpoint, device: "BEFORE", autoCrossSigning: false)
        await unconfigured.encryption().waitForE2eeInitializationTasks()
        do {
            _ = try await unconfigured.getSessionVerificationController()
            XCTFail("A client without an identity should have no native SAS controller")
        } catch {
            XCTAssertNotEqual(unconfigured.encryption().verificationState(), .verified)
        }
        try await unconfigured.pause()

        // Probe the selected artifact's separate builder-only bootstrap on
        // a fixture that accepts first signing upload without interactive auth.
        let owner = try await fixtureClient(endpoint, device: "OWNER", autoCrossSigning: true, oauth: true)
        await owner.encryption().waitForE2eeInitializationTasks()
        XCTAssertEqual(server.signingUploads, [200])
        let sdk = owner.encryption()
        let native = try await owner.getSessionVerificationController()
        let identity = try await sdk.userIdentity(userId: "@me:example.org", fallbackToServer: false)
        XCTAssertNotNil(identity)
        let backupBefore = try await sdk.backupExistsOnServer()
        XCTAssertFalse(backupBefore)
        let recoveryKey = try await sdk.enableRecovery(
            waitForBackupsToUpload: false, passphrase: nil, progressListener: MatrixRecoverySetupProgress()
        )
        XCTAssertTrue(!recoveryKey.isEmpty)
        XCTAssertEqual(sdk.recoveryState(), .enabled)
        XCTAssertEqual(sdk.backupState(), .enabled)

        let replacement = try await fixtureClient(endpoint, device: "REPLACEMENT", autoCrossSigning: false)
        await replacement.encryption().waitForE2eeInitializationTasks()
        try await replacement.encryption().recover(recoveryKey: recoveryKey)
        XCTAssertEqual(replacement.encryption().recoveryState(), .enabled)
        try await native.requestDeviceVerification()
        try await native.cancelVerification()

        let target = try NativeMatrixUser("@person:example.org")
        _ = try await owner.createRoom(request: PrivatePeopleChat.parameters(
            name: nil, isDirect: true, targets: [target]
        ))
        _ = try await owner.createRoom(request: PrivatePeopleChat.parameters(
            name: "Fixture", isDirect: false, targets: [target], encrypted: true
        ))
        let observed = server.roomEncryptionEvents
        XCTAssertEqual(observed.count, 2)
        XCTAssertNil(observed.first ?? nil)
        XCTAssertEqual(observed.last ?? nil, "m.megolm.v1.aes-sha2")
        try await owner.pause()
        try await replacement.pause()
    }

    func testPinnedBinaryAutoBootstrapPreservesExistingIdentityAndRecovery() async throws {
        let server = try SecurityFixtureHomeserver()
        defer { server.stop() }
        let endpoint = try await server.start()
        let owner = try await fixtureClient(endpoint, device: "OWNER", autoCrossSigning: true, oauth: true)
        let sdk = owner.encryption()
        await sdk.waitForE2eeInitializationTasks()
        _ = try await sdk.enableRecovery(
            waitForBackupsToUpload: false, passphrase: nil, progressListener: MatrixRecoverySetupProgress()
        )
        let original = try server.recoveryFingerprint()
        let second = try await fixtureClient(endpoint, device: "SECOND", autoCrossSigning: true, oauth: true)
        let otherSDK = second.encryption()
        await otherSDK.waitForE2eeInitializationTasks()
        let existing = try await otherSDK.userIdentity(userId: "@me:example.org", fallbackToServer: false)
        XCTAssertNotNil(existing)
        XCTAssertNotEqual(otherSDK.verificationState(), .verified)
        do {
            _ = try await otherSDK.enableRecovery(
                waitForBackupsToUpload: false, passphrase: nil, progressListener: MatrixRecoverySetupProgress()
            )
            XCTFail("This device must not be able to replace the existing backup")
        } catch RecoveryError.BackupExistsOnServer {
            // The stock SDK checks for the current server backup before creating one.
        }
        XCTAssertEqual(server.signingUploads, [200])
        XCTAssertEqual(try server.recoveryFingerprint(), original)
        try await second.pause()
        try await owner.pause()
    }

    func testPinnedBinaryAutoBootstrapDoesNotSurfaceOAuthChallenge() async throws {
        let server = try SecurityFixtureHomeserver(requireSigningApproval: true)
        defer { server.stop() }
        let endpoint = try await server.start()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let deviceKey: String
        do {
            let client = try await fixtureClient(
                endpoint, device: "PHONE", autoCrossSigning: true, oauth: true, storeDirectory: directory
            )
            let sdk = client.encryption()
            await sdk.waitForE2eeInitializationTasks()
            let localIdentity = try await sdk.userIdentity(userId: "@me:example.org", fallbackToServer: true)
            XCTAssertNotNil(localIdentity, "A generated local identity does not prove upload succeeded")
            XCTAssertNotEqual(sdk.verificationState(), .verified)
            let ed25519 = await sdk.ed25519Key()
            deviceKey = try XCTUnwrap(ed25519)
            try await client.pause()
        }
        XCTAssertEqual(server.signingUploads, [401])

        // Restore the exact same device store. The rejected identity is still
        // cached, so a second enable-on-restore does not send an upload.
        let retry = try await fixtureClient(
            endpoint, device: "PHONE", autoCrossSigning: true, oauth: true, storeDirectory: directory
        )
        let retrySDK = retry.encryption()
        await retrySDK.waitForE2eeInitializationTasks()
        let resumedDeviceKey = await retrySDK.ed25519Key()
        XCTAssertEqual(resumedDeviceKey, deviceKey)
        XCTAssertEqual(server.signingUploads, [401])
        XCTAssertFalse(server.hasServerIdentity)
        XCTAssertNotEqual(retrySDK.verificationState(), .verified)
        XCTAssertEqual(server.recoveryWrites, [])
        try await retry.pause()
    }

    func testPinnedBinaryEnableRecoveryDoesNotBootstrapCrossSigning() async throws {
        let server = try SecurityFixtureHomeserver()
        defer { server.stop() }
        let endpoint = try await server.start()
        let phone = try await fixtureClient(endpoint, device: "PHONE", autoCrossSigning: false, oauth: true)
        let sdk = phone.encryption()
        await sdk.waitForE2eeInitializationTasks()
        _ = try await sdk.enableRecovery(
            waitForBackupsToUpload: false, passphrase: nil, progressListener: MatrixRecoverySetupProgress()
        )
        XCTAssertEqual(server.signingUploads, [])
        XCTAssertFalse(server.hasServerIdentity)
        XCTAssertTrue(server.recoveryWrites.contains("create backup"))
        XCTAssertNotEqual(sdk.verificationState(), .verified)
        try await phone.pause()
    }

    func testPinnedBinaryCanSupersedeBackupCreatedAfterAbsenceCheck() async throws {
        let server = try SecurityFixtureHomeserver(insertCompetingBackupBeforeCreate: true)
        defer { server.stop() }
        let endpoint = try await server.start()
        let phone = try await fixtureClient(endpoint, device: "PHONE", autoCrossSigning: true, oauth: true)
        let sdk = phone.encryption()
        await sdk.waitForE2eeInitializationTasks()
        let backupExists = try await sdk.backupExistsOnServer()
        XCTAssertFalse(backupExists)
        _ = try await sdk.enableRecovery(
            waitForBackupsToUpload: false, passphrase: nil, progressListener: MatrixRecoverySetupProgress()
        )
        XCTAssertEqual(server.activeBackupVersion, "2")
        XCTAssertEqual(server.recoveryWrites.filter { $0.contains("backup") },
                       ["create competing backup", "create backup"])
        try await phone.pause()
    }

    func testPinnedBinaryResetDeletesRecoveryBeforeOAuthApproval() async throws {
        let server = try SecurityFixtureHomeserver()
        defer { server.stop() }
        let endpoint = try await server.start()
        let owner = try await fixtureClient(endpoint, device: "OWNER", autoCrossSigning: true, oauth: true)
        let sdk = owner.encryption()
        await sdk.waitForE2eeInitializationTasks()
        _ = try await sdk.enableRecovery(
            waitForBackupsToUpload: false, passphrase: nil, progressListener: MatrixRecoverySetupProgress()
        )
        XCTAssertTrue(server.hasServerBackup)
        let handle = try await sdk.resetIdentity()
        let reset = try XCTUnwrap(handle)
        guard case .oAuth = reset.authType() else { return XCTFail("Expected OAuth reset approval") }
        XCTAssertEqual(server.signingUploads, [200, 401])
        XCTAssertFalse(server.hasServerBackup)
        XCTAssertEqual(Array(server.recoveryWrites.suffix(2)), ["delete backup", "clear default key"])
        await reset.cancel()
        try await owner.pause()
    }

    private func fixtureClient(
        _ endpoint: String, device: String, autoCrossSigning: Bool, oauth: Bool = false,
        storeDirectory: URL? = nil
    ) async throws -> Client {
        var builder = ClientBuilder()
            .homeserverUrl(url: endpoint)
            .disableWellKnownLookup(disableWellKnownLookup: true)
            .disableAutomaticTokenRefresh()
            .autoEnableCrossSigning(autoEnableCrossSigning: autoCrossSigning)
            .autoEnableBackups(autoEnableBackups: false)
            .requestConfig(config: RequestConfig(retryLimit: 0, timeout: 3_000,
                                                  maxConcurrentRequests: 4, maxRetryTime: 3_000))
        if let storeDirectory {
            builder = builder.sqliteStore(config: SqliteStoreBuilder(
                dataPath: storeDirectory.path, cachePath: storeDirectory.path
            ).passphrase(passphrase: "fixture"))
        }
        let client = try await builder.build()
        try await client.restoreSession(session: Session(
            accessToken: "fixture-" + device, refreshToken: nil, userId: "@me:example.org",
            deviceId: device, homeserverUrl: endpoint,
            oauthData: oauth ? #"{"client_id":"fixture-mobile"}"# : nil, slidingSyncVersion: .native
        ))
        return client
    }

    private func makeController(_ native: NativeSAS, timeout: Duration = .seconds(30)) -> MatrixSASVerification {
        MatrixSASVerification(userID: "@me:example.org", deviceID: "PHONE", timeout: timeout,
                              requireCurrent: { try Task.checkCancellation() }, load: { native })
    }

    private func beginComparison(_ controller: MatrixSASVerification, native: NativeSAS) async -> UUID {
        await controller.request()
        guard case .requested(let id) = controller.state else { XCTFail(); return UUID() }
        native.emit { $0.didAcceptVerificationRequest() }
        await waitFor { native.actions.contains(.start) }
        native.emit { $0.didStartSasVerification() }
        native.emit { $0.didReceiveVerificationData(data: Self.emoji) }
        await waitFor {
            if case .comparing = controller.state { return true }
            return false
        }
        return id
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private static var emoji: SessionVerificationData {
        .emojis(emojis: (0..<7).map { _ in TestEmoji(noHandle: .init()) }, indices: Data(repeating: 1, count: 7))
    }

    private static func invite(userID: String = "@me:example.org", deviceID: String = "MAC") -> SessionVerificationRequestDetails {
        SessionVerificationRequestDetails(
            senderProfile: .init(userId: userID, displayName: nil, avatarUrl: nil, status: nil, call: nil),
            flowId: "fixture-flow", deviceId: deviceID, deviceDisplayName: "Fixture Mac",
            firstSeenTimestamp: 1
        )
    }

    private static func lookup(kind: String, user: String) throws -> AliasLookupResponse {
        try NativeAPI.decode(AliasLookupResponse.self, from: JSONSerialization.data(withJSONObject: [
            "state": "assigned", "handle": "person", "principal": "00000000-0000-4000-8000-175097128f22",
            "kind": kind, "generation": 1, "matrixUser": user
        ]))
    }
}

@MainActor private final class TestAuthority { var current = true }

private final class TestEmoji: SessionVerificationEmoji, @unchecked Sendable {
    override func symbol() -> String { "🌳" }
    override func description() -> String { "Tree" }
}

private final class NativeSAS: SessionVerificationControllerProtocol, @unchecked Sendable {
    enum Action: Equatable { case acknowledge, accept, start, request, approve, decline, cancel }

    private let lock = NSLock()
    private var delegate: SessionVerificationControllerDelegate?
    private var calls: [Action] = []
    private var cancellation: SessionVerificationCancelInfo?
    var actions: [Action] { lock.withLock { calls } }

    func setDelegate(delegate: SessionVerificationControllerDelegate?) { lock.withLock { self.delegate = delegate } }
    func emit(_ event: (SessionVerificationControllerDelegate) -> Void) {
        if let delegate = lock.withLock({ delegate }) { event(delegate) }
    }
    func receivePeerCancel() {
        lock.withLock { cancellation = .init(reason: "fixture", cancelCode: "m.user", cancelledByUs: false) }
        emit { $0.didCancel() }
    }
    private func append(_ action: Action) { lock.withLock { calls.append(action) } }
    func acceptVerificationRequest() async throws { append(.accept) }
    func acknowledgeVerificationRequest(senderId: String, flowId: String) async throws { append(.acknowledge) }
    func approveVerification() async throws { append(.approve) }
    func cancelVerification() async throws { append(.cancel) }
    func declineVerification() async throws { append(.decline) }
    func requestCancelInfo() -> SessionVerificationCancelInfo? { lock.withLock { cancellation } }
    func sasCancelInfo() -> SessionVerificationCancelInfo? { nil }
    func requestDeviceVerification() async throws { append(.request) }
    func requestUserVerification(userId: String) async throws { XCTFail("Expected self-verification") }
    func startSasVerification() async throws { append(.start) }
}

/// A loopback protocol fixture for the native library. The only keys seen here
/// are ephemeral test keys generated by the selected simulator binary.
private final class SecurityFixtureHomeserver: @unchecked Sendable {
    private enum Failure: Error { case unreachable }
    private let listener: NWListener
    private let requireSigningApproval: Bool
    private let insertCompetingBackupBeforeCreate: Bool
    private let queue = DispatchQueue(label: "MatrixSecurityTests.fixture")
    private var accountData: [String: [String: Any]] = [:]
    private var deviceKeys: [String: [String: Any]] = [:]
    private var identity: [String: [String: Any]] = [:]
    private var backup: [String: Any]?
    private var roomEvents: [String?] = []
    private var signingStatuses: [Int] = []
    private var writes: [String] = []

    init(requireSigningApproval: Bool = false, insertCompetingBackupBeforeCreate: Bool = false) throws {
        self.requireSigningApproval = requireSigningApproval
        self.insertCompetingBackupBeforeCreate = insertCompetingBackupBeforeCreate
        let config = NWParameters.tcp
        config.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: config)
    }

    var roomEncryptionEvents: [String?] { queue.sync { roomEvents } }
    var signingUploads: [Int] { queue.sync { signingStatuses } }
    var recoveryWrites: [String] { queue.sync { writes } }
    var hasServerBackup: Bool { queue.sync { backup != nil } }
    var activeBackupVersion: String? { queue.sync { backup?["version"] as? String } }
    var hasServerIdentity: Bool { queue.sync { !identity.isEmpty } }

    func recoveryFingerprint() throws -> SHA256.Digest {
        try queue.sync {
            let state: [String: Any] = ["identity": identity, "backup": backup ?? [:], "accountData": accountData]
            return SHA256.hash(data: try JSONSerialization.data(withJSONObject: state, options: .sortedKeys))
        }
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: queue)
                receive(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port {
                        continuation.resume(returning: "http://127.0.0.1:\(port.rawValue)")
                    } else {
                        continuation.resume(throwing: Failure.unreachable)
                    }
                case .failed:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: Failure.unreachable)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, buffer: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, error == nil, let data else { connection.cancel(); return }
            let message = buffer + data
            if replyIfComplete(message, connection: connection) { return }
            guard !complete, message.count < 2_000_000 else { connection.cancel(); return }
            receive(connection, buffer: message)
        }
    }

    private func replyIfComplete(_ message: Data, connection: NWConnection) -> Bool {
        guard let separator = message.range(of: Data([13, 10, 13, 10])),
              let header = String(data: message[..<separator.lowerBound], encoding: .utf8),
              let first = header.components(separatedBy: "\r\n").first
        else { return false }
        let request = first.split(separator: " ")
        guard request.count >= 2 else { connection.cancel(); return true }
        let length = header.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = message[separator.upperBound...]
        guard body.count >= length else { return false }
        let path = String(request[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        let payload = (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any] ?? [:]
        let (status, response) = reply(method: String(request[0]), path: path, payload: payload)
        let responseData = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(responseData.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8) + responseData,
                        completion: .contentProcessed { _ in connection.cancel() })
        return true
    }

    private func reply(method: String, path: String, payload: [String: Any]) -> (String, [String: Any]) {
        let ok = "200 OK"
        let notFound: (String, [String: Any]) = ("404 Not Found", [
            "errcode": "M_NOT_FOUND", "error": "Fixture resource does not exist"
        ])
        if path.hasSuffix("/versions") {
            return (ok, ["versions": ["v1.17"], "unstable_features": [:]])
        }
        if path.hasSuffix("/keys/query") {
            var keys: [String: Any] = ["failures": [:], "device_keys": ["@me:example.org": deviceKeys]]
            for (kind, key) in identity { keys[kind] = ["@me:example.org": key] }
            return (ok, keys)
        }
        if path.hasSuffix("/keys/upload") {
            if let key = payload["device_keys"] as? [String: Any], let device = key["device_id"] as? String {
                deviceKeys[device] = key
            }
            return (ok, ["one_time_key_counts": ["signed_curve25519": 50]])
        }
        if path.hasSuffix("/keys/device_signing/upload") {
            if requireSigningApproval || !identity.isEmpty {
                signingStatuses.append(401)
                return ("401 Unauthorized", [
                    "session": "fixture-approval",
                    "flows": [["stages": ["m.oauth"]], ["stages": ["org.matrix.cross_signing_reset"]]],
                    "params": [
                        "m.oauth": ["url": "https://example.invalid/account?action=org.matrix.cross_signing_reset"],
                        "org.matrix.cross_signing_reset": [
                            "url": "https://example.invalid/account?action=org.matrix.cross_signing_reset"
                        ]
                    ]
                ])
            }
            signingStatuses.append(200)
            for kind in ["master_key", "self_signing_key", "user_signing_key"] {
                identity[kind + "s"] = payload[kind] as? [String: Any]
            }
            return (ok, [:])
        }
        if path.hasSuffix("/keys/signatures/upload") { return (ok, ["failures": [:]]) }
        if let eventType = path.components(separatedBy: "/account_data/").last,
           path.contains("/account_data/") {
            let key = eventType.removingPercentEncoding ?? eventType
            if method == "PUT" {
                if key == "m.secret_storage.default_key", payload["key"] == nil {
                    writes.append("clear default key")
                } else {
                    writes.append("write account data")
                }
                accountData[key] = payload
                return (ok, [:])
            }
            return accountData[key].map { (ok, $0) } ?? notFound
        }
        if path.hasSuffix("/room_keys/version") || path.hasSuffix("/room_keys/version/1") {
            if method == "POST" {
                // Model an independent device's create between the native
                // GET for the current version and this unconditional POST.
                if insertCompetingBackupBeforeCreate, backup == nil {
                    writes.append("create competing backup")
                    backup = ["version": "1"]
                }
                let version = backup == nil ? "1" : "2"
                writes.append("create backup")
                backup = payload.merging(["version": version, "count": 0, "etag": "fixture"]) { _, new in new }
                return (ok, ["version": version])
            }
            if method == "DELETE" {
                writes.append("delete backup")
                backup = nil
                return (ok, [:])
            }
            return backup.map { (ok, $0) } ?? notFound
        }
        if path.hasSuffix("/room_keys/keys") { return (ok, ["rooms": [:], "etag": "fixture", "count": 0]) }
        if path.contains("/sendToDevice/") { return (ok, [:]) }
        if path.hasSuffix("/createRoom") {
            let events = payload["initial_state"] as? [[String: Any]] ?? []
            let encryption = events.first { $0["type"] as? String == "m.room.encryption" }
            let content = encryption?["content"] as? [String: Any]
            roomEvents.append(content?["algorithm"] as? String)
            return (ok, ["room_id": "!fixture\(roomEvents.count):example.org"])
        }
        return notFound
    }
}
