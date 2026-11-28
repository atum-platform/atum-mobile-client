import AtumChat
import Foundation
import MatrixRustSDK
import Network
import XCTest
@testable import AtumMobile

@MainActor
final class ChatActionsSDKTests: XCTestCase {
    func testPinnedSDKForwardAndReadbackAndPlainOnlyPreviews() async throws {
        let server = try ChatActionsHomeserver()
        let endpoint = try await server.start()
        defer { server.stop() }
        let client = try await fixtureClient(endpoint: endpoint)
        let room = try await client.joinRoomById(roomId: "!fixture:example.test")
        let original = #"{"type":"m.room.message","content":{"msgtype":"m.text","body":"Visible text","m.mentions":{"room":true}}}"#
        let projected = try ForwardContent(originalEvent: original, latestEvent: original)
        let sent = try await room.sendRaw(eventType: "m.room.message", content: projected.json)
        XCTAssertEqual(sent, "$forwarded")
        XCTAssertEqual(server.latestSend?["io.atum.forwarded"] as? Bool, true)
        XCTAssertEqual(server.latestSend?["m.mentions"] as? [String: Bool], [:])
        let readBack = try await room.loadOrFetchEvent(eventId: sent)
        guard case .messageLike(.roomMessage(.text(let content), _)) = try readBack.content() else {
            return XCTFail("The forwarded wire event should parse as an ordinary text message")
        }
        XCTAssertEqual(content.body, "Visible text")

        var item = ChatItem(id: sent, kind: .message, eventOrTransactionId: .event(sent))
        item.linkPreviewURL = URL(string: "https://example.test/story")
        let privateRoom = PreviewFixtureRoom(.encrypted)
        let blocked = RoomLinkPreviews(client: client, room: privateRoom, isCurrent: { true })
        let privateCard = await blocked.card(for: item)
        XCTAssertNil(privateCard)
        XCTAssertEqual(server.authenticatedPreviews, 0)
        XCTAssertEqual(privateRoom.encryptionReads, 0)

        let plain = RoomLinkPreviews(client: client, room: PreviewFixtureRoom(.notEncrypted), isCurrent: { true })
        let first = await plain.card(for: item)
        let second = await plain.card(for: item)
        XCTAssertEqual(first?.title, "Preview fixture")
        XCTAssertEqual(first, second)
        XCTAssertEqual(server.authenticatedPreviews, 1)
        plain.close()
        try await client.pause()
    }

    func testPinnedSDKQueuesTextAndUsesCurrentRoomMentionPower() async throws {
        let room = PreviewFixtureRoom(.notEncrypted)
        let explicit = OutgoingMentions(userIDs: [], formattedHTML: nil, room: true)
        let ordinary = try await RoomMentionMatrix.message("Ordinary text", mentions: .none, in: room)
        let typed = try await RoomMentionMatrix.message("Typed @room", mentions: .none, in: room)
        let selected = try await RoomMentionMatrix.message("Picked @channel", mentions: explicit, in: room)
        XCTAssertEqual(room.powerReads, 1)
        let server = try ChatActionsHomeserver()
        let endpoint = try await server.start()
        defer { server.stop() }
        let client = try await fixtureClient(endpoint: endpoint)
        let joined = try await client.joinRoomById(roomId: "!fixture:example.test")
        let timeline = try await joined.timeline()
        let demoted: RoomMessageEventContentWithoutRelation
        room.canNotify = false
        demoted = try await RoomMentionMatrix.message("Demoted @channel", mentions: explicit, in: room)
        XCTAssertEqual(room.powerReads, 2)
        // A request that misses the fixture timeout on a loaded host is a
        // recoverable send-queue error: the SDK disables the room's queue and
        // parks the rest until something re-enables it. Production wakes it on
        // the next send, retry, foreground or network regain; the test does the
        // same and records every error so a real failure stays visible.
        let errors = QueueErrorRecorder()
        let errorHandle = client.subscribeToSendQueueStatus(listener: errors)
        defer { errorHandle.cancel() }
        for content in [ordinary, typed, selected, demoted] {
            _ = try await timeline.send(msg: content)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var wakes = 0
        while server.sendCount < 4, ContinuousClock.now < deadline {
            if errors.count > wakes {
                wakes = errors.count
                joined.enableSendQueue(enable: true)
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let level = server.mentionFlags
        XCTAssertEqual(level, ["Ordinary text": "absent", "Typed @room": "empty",
                               "Picked @channel": "room", "Demoted @channel": "empty"],
                       "send-queue errors: \(errors.messages)")
        try await client.pause()
    }

    func testPinnedSDKReadsBothUpgradeLinksFromSync() async throws {
        let server = try ChatActionsHomeserver()
        let endpoint = try await server.start()
        defer { server.stop() }
        let client = try await fixtureClient(endpoint: endpoint)
        let sync = try await SessionLifecycle.makeSyncService(client: client)
        await sync.start()
        let until = ContinuousClock.now.advanced(by: .seconds(6))
        let oldID = "!old:example.test"
        let newID = "!new:example.test"
        var old: Room?
        var new: Room?
        while ContinuousClock.now < until {
            old = try client.getRoom(roomId: oldID)
            new = try client.getRoom(roomId: newID)
            if old?.successorRoom()?.roomId == newID, new?.predecessorRoom()?.roomId == oldID { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        await sync.stop()
        XCTAssertEqual(old?.successorRoom()?.roomId, newID)
        XCTAssertEqual(new?.predecessorRoom()?.roomId, oldID)
        try await client.pause()
    }

    private func fixtureClient(endpoint: String) async throws -> Client {
        let client = try await ClientBuilder().homeserverUrl(url: endpoint)
            .disableWellKnownLookup(disableWellKnownLookup: true)
            .autoEnableCrossSigning(autoEnableCrossSigning: false)
            .autoEnableBackups(autoEnableBackups: false)
            .requestConfig(config: RequestConfig(retryLimit: 0, timeout: 10_000,
                                                  maxConcurrentRequests: 2, maxRetryTime: 10_000))
            .build()
        try await client.restoreSession(session: Session(
            accessToken: "fixture", refreshToken: nil, userId: "@me:example.test", deviceId: "PHONE",
            homeserverUrl: endpoint, oauthData: nil, slidingSyncVersion: .native
        ))
        return client
    }
}

private final class QueueErrorRecorder: SendQueueRoomErrorListener, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [String]()

    var count: Int { lock.withLock { recorded.count } }
    var messages: [String] { lock.withLock { recorded } }

    func onError(roomId: String, error: ClientError) {
        lock.withLock { recorded.append("\(roomId): \(error)") }
    }
}

private final class PreviewFixtureRoom: Room, @unchecked Sendable {
    private let encryption: EncryptionState
    private(set) var encryptionReads = 0
    private(set) var powerReads = 0
    var canNotify = true

    init(_ encryption: EncryptionState) {
        self.encryption = encryption
        super.init(noHandle: Room.NoHandle())
    }

    required init(unsafeFromHandle handle: UInt64) { fatalError("Fixture has no Rust handle") }
    override func membership() -> Membership { .joined }
    override func successorRoom() -> SuccessorRoom? { nil }
    override func ownUserId() -> String { "@me:example.test" }
    override func encryptionState() -> EncryptionState { encryption }
    override func latestEncryptionState() async throws -> EncryptionState {
        encryptionReads += 1
        return encryption
    }
    override func getPowerLevels() async throws -> RoomPowerLevels {
        powerReads += 1
        return FixturePowers(canNotify: canNotify)
    }
}

private final class FixturePowers: RoomPowerLevels, @unchecked Sendable {
    let canNotify: Bool

    init(canNotify: Bool) {
        self.canNotify = canNotify
        super.init(noHandle: RoomPowerLevels.NoHandle())
    }

    required init(unsafeFromHandle handle: UInt64) { fatalError("Fixture has no Rust handle") }
    override func canUserTriggerRoomNotification(userId: String) throws -> Bool { canNotify }
    override func canUserSendMessage(userId: String, message: MessageLikeEventType) throws -> Bool { true }
}

private final class ChatActionsHomeserver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ChatActionsHomeserver")
    private var sends = [[String: Any]]()
    private var previews = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    var latestSend: [String: Any]? { queue.sync { sends.last } }
    var sendCount: Int { queue.sync { sends.count } }
    var authenticatedPreviews: Int { queue.sync { previews } }
    var mentionFlags: [String: String] {
        queue.sync {
            sends.reduce(into: [:]) { result, content in
                guard let body = content["body"] as? String else { return }
                let mentions = content["m.mentions"] as? [String: Any]
                result[body] = mentions == nil ? "absent" : (mentions?["room"] as? Bool == true ? "room" : "empty")
            }
        }
    }

    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: queue)
                receive(connection, bytes: Data())
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                        return
                    }
                    continuation.resume(returning: "http://127.0.0.1:\(port.rawValue)")
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = bytes
            if let data { request.append(data) }
            if let separator = request.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: request[..<separator.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let length = lines.first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if request.count - separator.upperBound >= length {
                    let body = request[separator.upperBound..<(separator.upperBound + length)]
                    respond(connection, headers: lines, body: Data(body))
                    return
                }
            }
            if done || request.count > 1_000_000 { connection.cancel() }
            else { receive(connection, bytes: request) }
        }
    }

    private func respond(_ connection: NWConnection, headers: [String], body: Data) {
        let request = headers.first?.split(separator: " ") ?? []
        let path = request.dropFirst().first.map(String.init) ?? ""
        let method = request.first
        var response = [String: Any]()
        var status = "200 OK"
        if path.hasSuffix("/versions") {
            response = ["versions": ["v1.11", "v1.12"], "unstable_features": ["org.matrix.simplified_msc3575": true]]
        } else if path.contains("/sync"), method == "POST" {
            response = Self.upgradeSync
        } else if path.contains("/join/") || path.hasSuffix("/join") {
            response = ["room_id": "!fixture:example.test"]
        } else if path.contains("/send/m.room.message/"), method == "PUT" {
            if let content = try? JSONSerialization.jsonObject(with: body) as? [String: Any] { sends.append(content) }
            response = ["event_id": sends.count == 1 ? "$forwarded" : "$message\(sends.count)"]
        } else if path.contains("/event/"), let content = sends.first {
            response = ["type": "m.room.message", "content": content, "sender": "@me:example.test",
                        "event_id": "$forwarded", "room_id": "!fixture:example.test", "origin_server_ts": 1]
        } else if path.contains("/preview_url?"),
                  headers.contains(where: { $0.lowercased() == "authorization: bearer fixture" }) {
            previews += 1
            response = ["og:title": "Preview fixture"]
        } else if path.hasSuffix("/members") {
            response = ["chunk": []]
        } else if path.contains("/keys/upload") {
            response = ["one_time_key_counts": ["signed_curve25519": 50]]
        } else if path.contains("/keys/query") {
            response = ["device_keys": [:], "failures": [:]]
        } else {
            status = "404 Not Found"
            response = ["errcode": "M_NOT_FOUND", "error": "Fixture endpoint unavailable"]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: response) else { connection.cancel(); return }
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + json, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static var upgradeSync: [String: Any] {
        let old = "!old:example.test"
        let new = "!new:example.test"
        let me = "@me:example.test"
        func state(_ id: String, _ type: String, _ content: [String: Any], key: String = "") -> [String: Any] {
            ["type": type, "event_id": id, "state_key": key, "sender": me, "origin_server_ts": 1, "content": content]
        }
        let member = state("$joined", "m.room.member", ["membership": "join"], key: me)
        return [
            "pos": "next", "lists": ["all_rooms": ["count": 2]],
            "rooms": [
                old: ["initial": true, "name": "Old room", "timeline": [], "required_state": [
                    member, state("$old", "m.room.create", ["creator": me, "room_version": "11"]),
                    state("$tombstone", "m.room.tombstone", ["body": "", "replacement_room": new])
                ]],
                new: ["initial": true, "name": "New room", "timeline": [], "required_state": [
                    member, state("$new", "m.room.create", ["creator": me, "room_version": "11",
                                                          "predecessor": ["room_id": old, "event_id": "$old"]])
                ]]
            ]
        ]
    }
}
