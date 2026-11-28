import AtumChat
import AtumNativeAPI
import MatrixRustSDK
import XCTest
@testable import AtumMobile

@MainActor
final class GroupTranscriptSDKTests: XCTestCase {
    private let own = "@me:example.test"
    private let replier = "@guest:example.test"

    func testMappedRootSuppliesCapsuleWithoutThreadList() async throws {
        let latest = EmbeddedEventDetails.ready(content: content(), sender: replier,
                                                senderProfile: .unavailable, timestamp: 2_000,
                                                eventOrTransactionId: .eventId(eventId: "$latest"))
        let mapped = mapper().map(event(content: content(summary: Summary(count: 7, latest: latest))))
        let live = GroupRoomLive(key: .init(roomID: "!group:example.test",
                                           session: ObjectIdentifier(GroupRoomLive.self), scope: .peopleGroup),
                                 list: nil, pins: nil)
        await live.updateTranscriptRoots(GroupRoomLive.transcriptRoots(in: [ChatRow(item: mapped.item)],
                                                                        roomID: live.roomID, ownUserID: own))
        let thread = try XCTUnwrap(live.summaries["$root"])
        XCTAssertNil(live.threads)
        XCTAssertEqual(thread.replyCount, 7)
        XCTAssertEqual(thread.latest?.eventID, "$latest")
        XCTAssertEqual(thread.latest?.senderID, replier)
        XCTAssertEqual(thread.lastActivityAt, 2_000)
    }

    func testCountSurvivesPendingLatestEventAndSummaryMappingIsGroupOnly() {
        let root = event(content: content(summary: Summary(count: 2, latest: .pending)))
        XCTAssertEqual(mapper().map(root).item.threadSummary, .init(replyCount: 2, latest: nil))
        for kind in RoomKind.allCases {
            XCTAssertNil(mapper(kind: kind, showsGroupThreads: false).map(root).item.threadSummary)
        }
    }

    func testLegacyResultMarkerComesFromOriginalEventEvenAfterAnEdit() {
        let original = #"{"content":{"msgtype":"m.text","io.atum.result":{"transaction":"legacy"}}}"#
        let replacement = #"{"content":{"m.new_content":{"msgtype":"m.text","body":"Updated"}}}"#
        let legacy = event(id: "$legacy", content: content(threadRoot: "$root", edited: true),
                           json: JSONProvider(latest: replacement, original: original))
        let ordinary = event(id: "$reply", content: content(threadRoot: "$root"),
                             json: JSONProvider(latest: #"{"content":{"io.atum.result":false}}"#))
        let mapper = mapper()
        XCTAssertTrue(mapper.map(legacy).item.isLegacyThreadResult)
        XCTAssertFalse(mapper.map(ordinary).item.isLegacyThreadResult)
    }

    func testThreadUnreadUsesLatestReplyAndScopedOrLegacyReceipts() {
        let latest = CompanyThreadMessage(eventID: "$latest", senderID: replier, senderName: nil,
                                          isOwn: false, body: "", sentAt: 2_000)
        let seenLatest = UserReceipt(eventId: "$latest", receipt: Receipt(timestamp: nil))
        let seenRoot = UserReceipt(eventId: "$root", receipt: Receipt(timestamp: 2_100))
        let laterLegacyReceipt = UserReceipt(eventId: "$later", receipt: Receipt(timestamp: 2_500))
        XCTAssertTrue(RoomThreadList.isUnread(latest: latest, scoped: [], unthreaded: []))
        XCTAssertTrue(RoomThreadList.isUnread(latest: latest, scoped: [seenRoot], unthreaded: []))
        XCTAssertFalse(RoomThreadList.isUnread(latest: latest, scoped: [seenLatest], unthreaded: []))
        XCTAssertFalse(RoomThreadList.isUnread(latest: latest, scoped: [], unthreaded: [laterLegacyReceipt]))
        let mine = CompanyThreadMessage(eventID: "$mine", senderID: own, senderName: nil,
                                        isOwn: true, body: "", sentAt: 2_000)
        XCTAssertFalse(RoomThreadList.isUnread(latest: mine, scoped: [], unthreaded: []))
    }

    private func mapper(kind: RoomKind = .group, showsGroupThreads: Bool = true) -> ItemMapper {
        var context = RoomContext(kind: kind, ownUserID: own)
        context.showsGroupThreads = showsGroupThreads
        return ItemMapper(room: .init(roomID: "!group:example.test", context: context, isEncrypted: false,
                                      knownNames: [:], catalogBotUserIDs: [], languageCode: "en"))
    }

    private func content(summary: ThreadSummary? = nil, threadRoot: String? = nil,
                         edited: Bool = false) -> TimelineItemContent {
        .msgLike(content: MsgLikeContent(
            kind: .message(content: MessageContent(msgType: .text(content: .init(body: "Text", formatted: nil)),
                                                   body: "Text", isEdited: edited, mentions: nil)),
            inReplyTo: nil, threadRoot: threadRoot, threadSummary: summary))
    }

    private func event(id: String = "$root", content: TimelineItemContent,
                       json: JSONProvider = JSONProvider()) -> TimelineItem {
        FixtureTimelineItem(id: id, item: EventTimelineItem(
            isRemote: true, eventOrTransactionId: .eventId(eventId: id), sender: own, senderProfile: .unavailable,
            forwarder: nil, forwarderProfile: nil, isOwn: true, isEditable: true, content: content,
            reactions: [], eventTypeRaw: "m.room.message", timestamp: 1_000, localSendState: nil, editSendState: nil,
            redactionSendState: nil, localCreatedAt: nil, readReceipts: [:], origin: nil, canBeRepliedTo: true,
            lazyProvider: json))
    }
}

private final class FixtureTimelineItem: TimelineItem, @unchecked Sendable {
    let id: String
    let item: EventTimelineItem

    init(id: String, item: EventTimelineItem) {
        self.id = id
        self.item = item
        super.init(noHandle: .init())
    }

    required init(unsafeFromHandle handle: UInt64) { fatalError("Test fixture") }

    override func asEvent() -> EventTimelineItem? { item }
    override func asVirtual() -> VirtualTimelineItem? { nil }
    override func uniqueId() -> TimelineUniqueId { .init(id: id) }
}

private final class Summary: ThreadSummary, @unchecked Sendable {
    let count: UInt64
    let latest: EmbeddedEventDetails

    init(count: UInt64, latest: EmbeddedEventDetails) {
        self.count = count
        self.latest = latest
        super.init(noHandle: .init())
    }

    required init(unsafeFromHandle handle: UInt64) { fatalError("Test fixture") }

    override func numReplies() -> UInt64 { count }
    override func latestEvent() -> EmbeddedEventDetails { latest }
}

private final class JSONProvider: LazyTimelineItemProvider, @unchecked Sendable {
    let latest: String?
    let original: String?

    init(latest: String? = nil, original: String? = nil) {
        self.latest = latest
        self.original = original
        super.init(noHandle: .init())
    }

    required init(unsafeFromHandle handle: UInt64) { fatalError("Test fixture") }

    override func latestJson() -> String? { latest }
    override func debugInfo() -> EventTimelineItemDebugInfo {
        .init(model: "", originalJson: original, latestEditJson: latest)
    }
}
