import XCTest
import UserNotifications
import AtumChat
import MatrixRustSDK

final class NotificationServiceTests: XCTestCase {
    private let payload: [AnyHashable: Any] = ["room_id": "!room:example.test", "event_id": "$event",
        "unread_count": 3, "aps": ["alert": ["loc-key": "ATUM_NEW_MESSAGE"], "mutable-content": 1, "badge": 4]]

    func testGenericContentKeepsOnlyValidatedRoutingBadgeAndSound() {
        let content = NotificationService.genericContent(userInfo: payload, bundle: .init(for: Self.self))
        XCTAssertFalse(content.body.isEmpty)
        XCTAssertEqual(content.title, ""); XCTAssertEqual(content.subtitle, "")
        XCTAssertEqual(content.userInfo as NSDictionary, ["room_id": "!room:example.test", "event_id": "$event"] as NSDictionary)
        XCTAssertEqual(content.threadIdentifier, "!room:example.test")
        XCTAssertEqual(content.badge, 4); XCTAssertNotNil(content.sound); XCTAssertTrue(content.attachments.isEmpty)
    }
    func testUntrustedPayloadCannotSupplyDisplayOrRouting() {
        var bad = payload; bad["sender"] = "Injected"
        let content = NotificationService.genericContent(userInfo: bad, bundle: .init(for: Self.self))
        XCTAssertEqual(content.title, ""); XCTAssertTrue(content.userInfo.isEmpty)
        XCTAssertNil(content.badge); XCTAssertNil(content.sound); XCTAssertEqual(content.threadIdentifier, "")
    }
    func testRichContentKeepsGenericMetadata() {
        let generic = NotificationService.genericContent(userInfo: payload, bundle: .init(for: Self.self))
        let result = RichPushPresentation.map(.init(senderID: "@mai:example.test", senderName: "Mai",
            roomName: "Book club", isDirect: false, kind: .text("Hello")), ownUserID: "me", copy: .init(generic: "New message"))
        let rich = NotificationService.content(result, generic: generic)
        XCTAssertEqual(rich.title, "Book club"); XCTAssertEqual(rich.subtitle, "Mai"); XCTAssertEqual(rich.body, "Hello")
        XCTAssertEqual(rich.userInfo as NSDictionary, generic.userInfo as NSDictionary)
        XCTAssertEqual(rich.threadIdentifier, generic.threadIdentifier); XCTAssertEqual(rich.badge, generic.badge)
        XCTAssertNotNil(rich.sound)
    }
    func testFilteredAndRedactedNotificationsAreSilentBadgeOnly() throws {
        for status in [NotificationStatus.eventFilteredOut, .eventRedacted] {
            let result = try MatrixNotificationFetcher.presentation(status, eventID: "$event", ownUserID: "me", copy: .init(generic: "New message"))
            XCTAssertEqual(result, .suppress)
            let content = NotificationService.content(result, generic: NotificationService.genericContent(userInfo: payload, bundle: .init(for: Self.self)))
            XCTAssertEqual(content.body, ""); XCTAssertEqual(content.title, ""); XCTAssertNil(content.sound)
            XCTAssertTrue(content.userInfo.isEmpty); XCTAssertEqual(content.badge, 4)
        }
    }
    func testNotFoundKeepsGeneric() throws {
        XCTAssertEqual(try MatrixNotificationFetcher.presentation(.eventNotFound, eventID: "$event", ownUserID: "me", copy: .init(generic: "New message")), .generic)
    }
    func testSDKTimelineTextNoticeAndEmoteProjection() throws {
        let types: [(MessageType, String)] = [
            (.text(content: .init(body: "Hello", formatted: nil)), "Hello"),
            (.notice(content: .init(body: "Notice", formatted: nil)), "Notice"),
            (.emote(content: .init(body: "waves", formatted: nil)), "Mai waves")]
        for (type, expected) in types {
            let event = FakeTimelineEvent(.messageLike(content: .roomMessage(messageType: type, inReplyToEventId: nil)))
            guard case let .content(content) = try project(event) else { return XCTFail("Missing message content") }
            XCTAssertEqual(content.title, "Mai"); XCTAssertEqual(content.body, expected)
        }
    }
    func testSDKUTDAndWrongEventIDKeepGeneric() throws {
        XCTAssertEqual(try project(FakeTimelineEvent(.messageLike(content: .roomEncrypted))), .generic)
        let event = FakeTimelineEvent(.messageLike(content: .roomMessage(messageType: .text(content: .init(body: "wrong", formatted: nil)), inReplyToEventId: nil)))
        XCTAssertEqual(try project(event, eventID: "$different"), .generic)
    }
    func testOSExpiryBeforeReceiveStillDeliversGenericOnce() {
        let service = NotificationService()
        service.serviceExtensionTimeWillExpire()
        let content = UNMutableNotificationContent(); content.userInfo = payload
        var calls = 0
        service.didReceive(.init(identifier: "test", content: content, trigger: nil)) { result in
            calls += 1
            XCTAssertEqual(result.title, ""); XCTAssertFalse(result.body.isEmpty)
        }
        service.serviceExtensionTimeWillExpire()
        XCTAssertEqual(calls, 1)
    }
    private func project(_ event: TimelineEvent, eventID: String = "$event") throws -> RichPushPresentation.Result {
        let item = NotificationItem(event: .timeline(event: event), rawEvent: "untrusted raw display text",
            senderInfo: .init(displayName: "Mai", avatarUrl: nil, isNameAmbiguous: false),
            roomInfo: .init(displayName: "Book club", avatarUrl: nil, canonicalAlias: nil, topic: nil, joinRule: nil,
                joinedMembersCount: 2, activeServiceMembersCount: 0, serviceMembers: [], isEncrypted: true,
                isDirect: true, isSpace: false, isDm: true), isNoisy: true, hasMention: false, threadId: nil, actions: nil)
        return try MatrixNotificationFetcher.presentation(.event(item: item), eventID: eventID, ownUserID: "me", copy: .init(generic: "New message"))
    }
    private final class FakeTimelineEvent: TimelineEvent, @unchecked Sendable {
        private let value: TimelineEventContent
        init(_ value: TimelineEventContent) { self.value = value; super.init(noHandle: .init()) }
        required init(unsafeFromHandle handle: UInt64) { fatalError("Not a Rust-backed fixture") }
        override func content() throws -> TimelineEventContent { value }
        override func eventId() -> String { "$event" }
        override func senderId() -> String { "@mai:example.test" }
    }
    func testSDKInviteMapsThroughExportedLocalizedCopy() throws {
        let item = NotificationItem(event: .invite(sender: "@mai:example.test"), rawEvent: "not display input",
            senderInfo: .init(displayName: "Mai", avatarUrl: nil, isNameAmbiguous: false),
            roomInfo: .init(displayName: "Book club", avatarUrl: nil, canonicalAlias: nil, topic: nil, joinRule: nil,
                joinedMembersCount: 3, activeServiceMembersCount: 0, serviceMembers: [], isEncrypted: true,
                isDirect: false, isSpace: false, isDm: false), isNoisy: true, hasMention: false, threadId: nil, actions: nil)
        let copy = NotificationService.copy(bundle: .init(for: Self.self))
        guard case let .content(content) = try MatrixNotificationFetcher.presentation(.event(item: item), eventID: "$event", ownUserID: "me", copy: copy)
        else { return XCTFail("Missing invite content") }
        XCTAssertEqual(content.title, "Book club"); XCTAssertEqual(content.subtitle, "Mai")
        XCTAssertEqual(content.body, copy.invite)
        XCTAssertNotNil(copy.invite); XCTAssertNotNil(copy.unnamed); XCTAssertNotNil(copy.image)
    }
}
