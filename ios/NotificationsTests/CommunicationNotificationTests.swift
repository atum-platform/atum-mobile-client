import XCTest
import Intents
import UserNotifications
import AtumChat
import AtumNativeAPI
import MatrixRustSDK

/// The extension half of communication notifications: the intent's shape for
/// a person and a group, the monogram, image normalisation, the avatar cache's
/// caps, the fetch order and deadline, and that a failure only costs the image.
final class CommunicationNotificationTests: XCTestCase {
    private func face(_ style: CommunicationNotificationPolicy.Style, image: Data? = nil) -> CommunicationFace {
        CommunicationFace(plan: .init(style: style, images: [], monogramName: "Mai"), roomID: "!room:hs.test",
                          senderID: "@mai:hs.test", senderName: "Mai", ownUserID: "@me:hs.test", image: image)
    }

    func testPersonIntentPutsTheFaceOnTheSender() throws {
        let image = INImage(imageData: try XCTUnwrap(CommunicationNotification.monogram("Mai")))
        let intent = CommunicationNotification.intent(for: face(.person), image: image)
        XCTAssertNil(intent.speakableGroupName)
        XCTAssertNil(intent.recipients)
        XCTAssertEqual(intent.conversationIdentifier, "!room:hs.test")
        XCTAssertEqual(intent.sender?.displayName, "Mai")
        XCTAssertEqual(intent.sender?.personHandle?.value, "@mai:hs.test")
        XCTAssertNotNil(intent.sender?.image)
        XCTAssertNil(intent.image(forParameterNamed: \.speakableGroupName))
    }

    func testGroupIntentPutsTheImageOnTheGroupAndNamesTheSender() throws {
        let image = INImage(imageData: try XCTUnwrap(CommunicationNotification.monogram("Acme")))
        let intent = CommunicationNotification.intent(for: face(.group(name: "# general · Acme")), image: image)
        XCTAssertEqual(intent.speakableGroupName?.spokenPhrase, "# general · Acme")
        XCTAssertNotNil(intent.image(forParameterNamed: \.speakableGroupName))
        XCTAssertEqual(intent.sender?.displayName, "Mai")
        XCTAssertNil(intent.sender?.image, "in group style the group's image is the big one")
        XCTAssertEqual(intent.recipients?.count, 2)
        XCTAssertEqual(intent.recipients?.last?.isMe, true)
    }

    func testMonogramIsTheKitGradientAndInitialInACircle() throws {
        let data = try XCTUnwrap(CommunicationNotification.monogram("mai anh", side: 96))
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(image.width, 96); XCTAssertEqual(image.height, 96)
        XCTAssertEqual(try pixel(image, x: 1, y: 1).alpha, 0, "corners are outside the circle")
        let top = try pixel(image, x: 48, y: 6), bottom = try pixel(image, x: 48, y: 90)
        XCTAssertEqual(top.alpha, 255)
        XCTAssertGreaterThan(top.red, bottom.red, "the light gradient darkens downwards")
    }

    func testMonogramGradientMatchesTheVendoredKitTokens() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/AtumDesign/atum-kit-tokens.json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let gradients = try XCTUnwrap(json["gradients"] as? [String: Any])
        let light = try XCTUnwrap((gradients["light"] as? [String: Any])?["monogram"] as? [String: Any])
        let stops = try XCTUnwrap(light["stops"] as? [[String: Any]]).map { try XCTUnwrap($0["color"] as? [String: Double]) }
        XCTAssertEqual(stops.count, MonogramGradient.light.count)
        for (token, stop) in zip(stops, MonogramGradient.light) {
            XCTAssertEqual(token["red"]!, stop.red, accuracy: 0.002)
            XCTAssertEqual(token["green"]!, stop.green, accuracy: 0.002)
            XCTAssertEqual(token["blue"]!, stop.blue, accuracy: 0.002)
        }
    }

    func testNormalisationShrinksAndRefusesGarbage() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; return format
        }()).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        let small = try XCTUnwrap(CommunicationNotification.normalized(big))
        let image = try XCTUnwrap(UIImage(data: small)?.cgImage)
        XCTAssertLessThanOrEqual(max(image.width, image.height), CommunicationNotification.pixelSide)
        XCTAssertLessThan(small.count, big.count)
        XCTAssertNil(CommunicationNotification.normalized(Data("not an image".utf8)))
    }

    func testAvatarCacheIsCappedAndEvictsTheLeastRecentlyUsed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotificationSharedStore(root: root)
        let blob = Data(repeating: 7, count: 100 * 1_024)
        let folder = root.appendingPathComponent("avatars")
        // 40 x 100 KiB fits under the 4 MiB cap; the 41st does not.
        for index in 0..<40 { store.storeAvatar(blob, uri: "mxc://hs.test/\(index)", pixelSide: 192) }
        for index in 0..<40 {
            let file = folder.appendingPathComponent(NotificationSharedStore.avatarKey(uri: "mxc://hs.test/\(index)", pixelSide: 192))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(index - 100))],
                                                  ofItemAtPath: file.path)
        }
        XCTAssertNotNil(store.cachedAvatar(uri: "mxc://hs.test/0", pixelSide: 192), "a read makes 0 the most recent")
        store.storeAvatar(blob, uri: "mxc://hs.test/new", pixelSide: 192)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 40)
        XCTAssertLessThanOrEqual(files.count * blob.count, NotificationSharedStore.maximumAvatarBytes)
        XCTAssertNotNil(store.cachedAvatar(uri: "mxc://hs.test/0", pixelSide: 192), "recently used survives")
        XCTAssertNil(store.cachedAvatar(uri: "mxc://hs.test/1", pixelSide: 192), "the least recently used went first")
        XCTAssertNotNil(store.cachedAvatar(uri: "mxc://hs.test/new", pixelSide: 192))
        XCTAssertFalse(files.contains { $0.contains("hs.test") }, "no media URI appears in a path")
        store.storeAvatar(Data(count: NotificationSharedStore.maximumImageBytes + 1), uri: "mxc://hs.test/huge", pixelSide: 192)
        XCTAssertNil(store.cachedAvatar(uri: "mxc://hs.test/huge", pixelSide: 192))
    }

    func testDirectoryAndFacesRoundTripAndSignOutRemovesThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotificationSharedStore(root: root)
        let name = NotificationSharedStore.faceFileName(identity: "face")
        try store.writeFace(try XCTUnwrap(CommunicationNotification.monogram("A")), name: name)
        XCTAssertThrowsError(try store.writeFace(Data([1]), name: "../escape.png"))
        let directory = NotificationRoomDirectory(ownUserID: "@me:hs.test", rooms: [
            "!a:hs.test": .init(kind: .assistant, faceFile: name, faceName: "Atlas")])
        try store.writeDirectory(directory)
        XCTAssertEqual(store.readDirectory(), directory)
        XCTAssertNotNil(store.readFace(name))
        store.pruneFaces(keeping: [])
        XCTAssertNil(store.readFace(name))
        store.removeAll()
        XCTAssertNil(store.readDirectory())
    }

    func testImageOrderUsesTheCacheAndFetchesAtMostTwo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotificationSharedStore(root: root)
        let png = try XCTUnwrap(CommunicationNotification.monogram("Z"))
        let plan = CommunicationNotificationPolicy.Plan(style: .person, images: [
            .matrix("mxc://hs.test/a"), .matrix("mxc://hs.test/b"), .matrix("mxc://hs.test/c")], monogramName: "Z")
        let asked = Asked()
        let none = await CommunicationNotification.image(for: plan, store: store) { uri, _ in
            await asked.add(uri); throw CocoaError(.fileNoSuchFile)
        }
        XCTAssertNil(none)
        let first = await asked.values
        XCTAssertEqual(first, ["mxc://hs.test/a", "mxc://hs.test/b"], "the third candidate is never fetched")
        let fetched = await CommunicationNotification.image(for: plan, store: store) { uri, _ in
            guard uri == "mxc://hs.test/b" else { throw CocoaError(.fileNoSuchFile) }
            return png
        }
        XCTAssertNotNil(fetched)
        let cached = await CommunicationNotification.image(for: .init(style: .person, images: [.matrix("mxc://hs.test/b")],
                                                                      monogramName: "Z"), store: store) { _, _ in
            XCTFail("a cached avatar is not fetched again"); return Data()
        }
        XCTAssertEqual(cached, fetched)
    }

    func testASlowAvatarFetchIsAbandonedAtItsDeadline() async {
        let start = ContinuousClock.now
        let value: Int? = await CommunicationNotification.firstOf(seconds: 0.2) {
            try await Task.sleep(for: .seconds(30)); return 1
        }
        XCTAssertNil(value)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
        let quick: Int? = await CommunicationNotification.firstOf(seconds: 5) { 7 }
        XCTAssertEqual(quick, 7)
    }

    func testFaceIsBuiltFromSDKAvatarsNeverTheRawEvent() async throws {
        let item = NotificationItem(event: .invite(sender: "@mai:hs.test"), rawEvent: "{\"avatar\":\"mxc://evil.test/x\"}",
            senderInfo: .init(displayName: "Mai", avatarUrl: "mxc://hs.test/mai", isNameAmbiguous: false),
            roomInfo: .init(displayName: "Book club", avatarUrl: "mxc://hs.test/room", canonicalAlias: nil, topic: nil,
                joinRule: nil, joinedMembersCount: 3, activeServiceMembersCount: 0, serviceMembers: [],
                isEncrypted: true, isDirect: false, isSpace: false, isDm: false),
            isNoisy: true, hasMention: false, threadId: nil, actions: nil)
        let status = NotificationStatus.event(item: item)
        let result = try MatrixNotificationFetcher.presentation(status, eventID: "$e", ownUserID: "@me:hs.test",
                                                               copy: .init(generic: "New", invite: "invited you"))
        let asked = Asked()
        let face = await MatrixNotificationFetcher.face(status, result: result, roomID: "!room:hs.test",
                                                        ownUserID: "@me:hs.test", store: nil) { uri, _ in
            await asked.add(uri); throw CocoaError(.fileNoSuchFile)
        }
        let built = try XCTUnwrap(face)
        XCTAssertEqual(built.plan.style, .group(name: "Book club"))
        XCTAssertEqual(built.senderID, "@mai:hs.test")
        let requested = await asked.values
        XCTAssertEqual(requested, ["mxc://hs.test/room"])
        XCTAssertNil(built.image, "a failed fetch leaves the monogram")
    }

    func testFailuresOnlyCostTheImageNeverTheNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Mai"; content.body = "Hello"
        content.userInfo = ["room_id": "!room:hs.test", "event_id": "$e"]
        var reasons = [CommunicationFallback]()
        let result = await CommunicationNotification.apply(face(.person), to: content,
            donate: { _ in try await Task.sleep(for: .seconds(30)) }, log: { reasons.append($0) })
        XCTAssertTrue(reasons.contains(.donationFailed))
        // On a simulator test host without the entitlement `updating(from:)`
        // may refuse; either way the caller keeps a deliverable notification.
        let delivered = result ?? content
        XCTAssertEqual(delivered.body, "Hello")
        XCTAssertEqual(delivered.userInfo["room_id"] as? String, "!room:hs.test")
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (red: UInt8, alpha: UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (bytes[0], bytes[3])
    }
}

private actor Asked {
    var values = [String]()
    func add(_ value: String) { values.append(value) }
}
