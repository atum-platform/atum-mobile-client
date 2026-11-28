import XCTest
@testable import AtumChat

final class GroupTranscriptTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var threadedGroup: RoomContext {
        var context = RoomContext(kind: .group, ownUserID: F.me)
        context.showsGroupThreads = true
        return context
    }

    private func reply(_ id: String, from sender: String = F.other) -> ChatItem {
        var reply = F.text(id, from: sender)
        reply.threadRoot = "$root"
        return reply
    }

    func testGroupHidesStandardRepliesWithoutChangingSDKIndices() throws {
        var root = F.text("root", from: F.me)
        root.threadSummary = .init(replyCount: 1, latest: nil)
        let threaded = reply("threaded")
        var legacy = reply("answer", from: F.agent)
        legacy.isLegacyThreadResult = true
        let plain = F.text("plain", from: F.other, replyTo: "$root")
        var projector = TimelineProjector(generation: 1, context: threadedGroup)
        let first = try projector.apply([.reset([root, threaded, legacy, plain])], now: now)
        XCTAssertEqual(first.snapshot.rows.map(\.item), [root, legacy, plain])
        XCTAssertEqual(projector.buffer.items, [root, threaded, legacy, plain])
        XCTAssertTrue(first.snapshot.rows.last?.showsQuote == true)

        root.threadSummary = .init(replyCount: 2, latest: nil)
        let incoming = F.text("received", from: F.other)
        let second = try projector.apply([.set(index: 0, item: root), .pushBack(reply("second")), .pushBack(incoming)],
                                         now: now)
        XCTAssertEqual(second.snapshot.rows.map(\.item), [root, legacy, plain, incoming])
        XCTAssertTrue(second.snapshot.rows.last?.isLatest == true)
        XCTAssertEqual(second.snapshot.change, .appendedAtEnd(count: 1, localEcho: false))
        let threadOnly = try projector.apply([.pushBack(reply("third"))], now: now)
        XCTAssertEqual(threadOnly.snapshot.change, .inPlace)
    }

    func testFlatRoomsAndFocusedThreadsRetainRepliesAndSendNormally() throws {
        var teamSpace = RoomContext(kind: .group, ownUserID: F.me)
        teamSpace.companyTurnScope = .channel(threadRoot: nil, binding: nil)
        let contexts = [RoomContext(kind: .group, ownUserID: F.me), // flat or focused group
                        RoomContext(kind: .person, ownUserID: F.me), // human DM or Notes
                        F.assistantRoom(), F.botRoom(), teamSpace]
        for context in contexts {
            var legacy = reply("answer", from: F.agent)
            legacy.isLegacyThreadResult = true
            let messages = [F.text("root", from: F.me), reply("threaded"), legacy]
            var projector = TimelineProjector(generation: 1, context: context)
            let projection = try projector.apply([.reset(messages)], now: now)
            XCTAssertEqual(projection.snapshot.rows.map(\.item), messages)

            var core = ConversationCore(context: context, history: .onScroll)
            _ = core.attached(now: now)
            _ = core.receive(projection, now: now)
            core.draft = "plain message"
            XCTAssertEqual(core.send(), [.send(text: "plain message", replyToEventID: nil)])
            let incoming = F.text("received", from: F.other)
            _ = core.receive(try projector.apply([.pushBack(incoming)], now: now), now: now)
            XCTAssertEqual(core.snapshot.rows.last?.item, incoming)
        }
    }

    func testGroupMainReceiptTargetsOnlyAVisibleMainEvent() throws {
        var legacy = reply("answer", from: F.agent)
        legacy.isLegacyThreadResult = true
        let root = F.text("root", from: F.other)
        var projector = TimelineProjector(generation: 1, context: threadedGroup)
        var core = ConversationCore(context: threadedGroup, history: .onScroll)
        _ = core.attached(now: now)
        let projection = try projector.apply([.reset([root, reply("threaded"), legacy])], now: now)
        _ = core.receive(projection, now: now)
        _ = core.setBottomVisible(true, now: now)
        XCTAssertEqual(core.readWakeDue(now: now.addingTimeInterval(1)), [.markMainRead(eventID: "$root")])
        core.draft = "main message"
        XCTAssertEqual(core.send(), [.send(text: "main message", replyToEventID: nil)])
    }
}
