import AtumNativeAPI
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
        let timed = makeController(native, timeout: .milliseconds(70))
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
        let owner = try await fixtureClient(endpoint, device: "OWNER", autoCrossSigning: true)
        await owner.encryption().waitForE2eeInitializationTasks()
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

    private func fixtureClient(_ endpoint: String, device: String, autoCrossSigning: Bool) async throws -> Client {
        let client = try await ClientBuilder()
            .homeserverUrl(url: endpoint)
            .disableWellKnownLookup(disableWellKnownLookup: true)
            .autoEnableCrossSigning(autoEnableCrossSigning: autoCrossSigning)
            .autoEnableBackups(autoEnableBackups: false)
            .requestConfig(config: RequestConfig(retryLimit: 0, timeout: 3_000,
                                                  maxConcurrentRequests: 4, maxRetryTime: 3_000))
            .build()
        try await client.restoreSession(session: Session(
            accessToken: "fixture-" + device, refreshToken: nil, userId: "@me:example.org",
            deviceId: device, homeserverUrl: endpoint, oauthData: nil, slidingSyncVersion: .native
        ))
        return client
    }

    private func makeController(_ native: NativeSAS, timeout: Duration = .seconds(30)) -> MatrixSASVerification {
        MatrixSASVerification(userID: "@me:example.org", deviceID: "PHONE", timeout: timeout,
                              requireCurrent: {}, load: { native })
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
        try JSONDecoder().decode(AliasLookupResponse.self, from: JSONSerialization.data(withJSONObject: [
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
    private let queue = DispatchQueue(label: "MatrixSecurityTests.fixture")
    private var accountData: [String: [String: Any]] = [:]
    private var deviceKeys: [String: [String: Any]] = [:]
    private var identity: [String: [String: Any]] = [:]
    private var backup: [String: Any]?
    private var roomEvents: [String?] = []

    init() throws {
        let config = NWParameters.tcp
        config.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: config)
    }

    var roomEncryptionEvents: [String?] { queue.sync { roomEvents } }

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
        let notFound: (String, [String: Any]) = ("404 Not Found", ["errcode": "M_NOT_FOUND"])
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
            for kind in ["master_key", "self_signing_key", "user_signing_key"] {
                identity[kind + "s"] = payload[kind] as? [String: Any]
            }
            return (ok, [:])
        }
        if path.hasSuffix("/keys/signatures/upload") { return (ok, ["failures": [:]]) }
        if let eventType = path.components(separatedBy: "/account_data/").last,
           path.contains("/account_data/") {
            let key = eventType.removingPercentEncoding ?? eventType
            if method == "PUT" { accountData[key] = payload; return (ok, [:]) }
            return accountData[key].map { (ok, $0) } ?? notFound
        }
        if path.hasSuffix("/room_keys/version") || path.hasSuffix("/room_keys/version/1") {
            if method == "POST" {
                backup = payload.merging(["version": "1", "count": 0, "etag": "fixture"]) { _, new in new }
                return (ok, ["version": "1"])
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
