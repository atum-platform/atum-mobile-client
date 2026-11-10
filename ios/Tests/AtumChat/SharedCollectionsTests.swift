import Foundation
import XCTest
@testable import AtumChat

final class SharedCollectionsPolicyTests: XCTestCase {
    func testDesktopLinkCases() {
        let cases: [(String, [String])] = [
            ("See https://example.test/a?b=1, and (https://example.test/x_(y)). Again https://example.test/a?b=1!",
             ["https://example.test/a?b=1", "https://example.test/x_(y)"]),
            ("[docs](https://docs.test/p) <http://old.test> ftp://no.test javascript:alert(1)",
             ["https://docs.test/p", "http://old.test"]),
            ("run `curl https://api.test/v1` then https://docs.test, or ``x ` https://tick.test``", ["https://docs.test"]),
            ("Before https://before.test\n```bash\nhttps://in.test\n```\nhttps://between.test\n~~~~\n~~~ https://inside.test\n~~~~\n  ```\nhttps://unclosed.test",
             ["https://before.test", "https://between.test"]),
            ("it's 5` past https://a.test", ["https://a.test"]),
            ("> <@reader:example.test> https://quoted.test\n> https://quoted2.test\n\nmine https://mine.test", ["https://mine.test"]),
            ("https://a.test/path). https://a.test/path).", ["https://a.test/path"]),
            ("HTTPS://Example.test/Path", ["HTTPS://Example.test/Path"]),
            ("文https://a.test prefixhttps://hidden.test", ["https://a.test"]),
            ("https://a.test/caf\u{e9} https://a.test/cafe\u{301}",
             ["https://a.test/caf\u{e9}", "https://a.test/cafe\u{301}"])
        ]
        for (body, expected) in cases { XCTAssertEqual(SharedCollectionsPolicy.links(in: body), expected) }
    }

    func testLinkLimitsDeduplicationAndSafety() {
        XCTAssertEqual(SharedCollectionsPolicy.links(in: (0..<8).map { "https://s\($0).test" }.joined(separator: " ")).count, 5)
        XCTAssertEqual(SharedCollectionsPolicy.links(in: "https://a.test https://a.test https://b.test"), ["https://a.test", "https://b.test"])
        XCTAssertEqual(SharedCollectionsPolicy.links(in: "https://a.test/" + String(repeating: "x", count: 2048)), [])
        XCTAssertEqual(SharedCollectionsPolicy.links(in: "https:// https:/// file:///tmp/a javascript:alert(1)"), [])
        XCTAssertEqual(SharedCollectionsPolicy.links(in: "https://a.test\\@b.test"), [])
        let held = rows("m.text", body: "https://pay.payos.vn/order", section: .links)
        XCTAssertEqual(held.first?.linkDecision, .hold)
        XCTAssertEqual(held.first?.url, "https://pay.payos.vn/order")
        XCTAssertNotEqual(rows("m.text", body: "https://a.test/caf\u{e9}", section: .links),
                          rows("m.text", body: "https://a.test/cafe\u{301}", section: .links))
    }

    func testNativeTypeClassificationIgnoresMisleadingMIME() {
        for (type, section, kind) in [("m.image", SharedCollectionSection.media, SharedCollectionItem.Kind.image),
                                       ("m.video", .media, .video), ("m.file", .files, .file), ("m.audio", .files, .audio)] {
            let result = rows(type, section: section)
            XCTAssertEqual(result.first?.kind, kind)
            XCTAssertEqual(rows(type, section: section == .media ? .files : .media), [])
            XCTAssertEqual(rows(type, body: "https://caption.test", section: .links), [])
        }
        for type in ["m.text", "m.notice", "m.emote"] {
            XCTAssertEqual(rows(type, body: "https://a.test", section: .links).count, 1)
        }
        for type in ["m.location", "m.sticker", "io.test.unknown-kind", "m.poll.start"] {
            XCTAssertEqual(rows(type, body: "https://a.test", section: .links), [])
        }
    }

    func testEncryptedSourcesNoPlaintextDowngradeAndThumbnailRules() {
        let image = testItem(kind: .image(width: nil, height: nil))
        XCTAssertEqual(project(image, content: ["msgtype": "m.image", "url": "mxc://s/a"], encrypted: true), [])
        let encrypted: [String: Any] = ["msgtype": "m.image", "file": ["url": "mxc://s/a", "v": "v2"]]
        let result = project(image, content: encrypted, encrypted: true)
        XCTAssertEqual(result.first?.media?.sourceHandle, "opaque-encrypted-source")
        XCTAssertEqual(result.first?.thumbnail, .content(source: "opaque-encrypted-source"))
        var noSize = image
        noSize.media?.byteSize = nil
        XCTAssertNil(project(noSize, content: encrypted, encrypted: true).first?.thumbnail)
        var big = image
        big.media?.byteSize = UInt64(SharedCollectionsPolicy.thumbnailMaximumBytes + 1)
        XCTAssertNil(project(big, content: encrypted, encrypted: true).first?.thumbnail)
        XCTAssertNil(rows("m.video", section: .media).first?.thumbnail)
        XCTAssertEqual(rows("m.image", section: .media).first?.thumbnail, .scaled(source: "opaque-encrypted-source"))
        let withThumbnail: [String: Any] = ["msgtype": "m.video", "file": ["url": "mxc://s/a"],
                                           "info": ["thumbnail_file": ["url": "mxc://s/t"]]]
        var video = testItem()
        video.media?.thumbnailSourceHandle = "encrypted-thumbnail"
        XCTAssertEqual(project(video, content: withThumbnail, encrypted: true).first?.thumbnail, .content(source: "encrypted-thumbnail"))
    }

    func testInvalidMediaAndMetadataBounds() {
        let item = testItem()
        for value in ["https://example.test/a", "mxc://s/a?x", "mxc://s/a/b", "mxc://s/", "mxc://s/a\n"] {
            XCTAssertEqual(project(item, content: ["msgtype": "m.image", "url": value]), [])
        }
        let result = project(item, content: ["msgtype": "m.image", "url": "mxc://s/a", "filename": String(repeating: "x", count: 513)])
        XCTAssertNil(result.first?.name)
        for mime in ["", String(repeating: "x", count: 256)] {
            var invalidMIME = item
            invalidMIME.media?.mimetype = mime
            XCTAssertNil(project(invalidMIME, content: ["msgtype": "m.image", "url": "mxc://s/a"]).first?.media?.mimetype)
        }
    }

    func testRedactedHiddenInternalPendingAndStandaloneEditsAreExcluded() {
        let content: [String: Any] = ["msgtype": "m.text", "body": "https://a.test"]
        for kind: ChatItem.Kind in [.roomState, .placeholder(.redacted), .placeholder(.undecryptable),
                                     .placeholder(.undecryptableOldHistory), .placeholder(.unsupported), .timelineStart] {
            XCTAssertEqual(project(testItem(kind: kind), content: content, section: .links), [])
        }
        var pending = testItem()
        pending.isLocalEcho = true
        XCTAssertEqual(project(pending, content: content, section: .links), [])
        pending.isLocalEcho = false
        pending.delivery = .failed(isRecoverable: true)
        XCTAssertEqual(project(pending, content: content, section: .links), [])
        var internalContent = content
        internalContent["io.atum.progress"] = ["phase": "working"]
        XCTAssertEqual(project(testItem(), content: internalContent, section: .links), [])
        var edit = content
        edit["m.relates_to"] = ["rel_type": "m.replace", "event_id": "$original"]
        XCTAssertEqual(project(testItem(), content: edit, section: .links), [])
    }

    func testProjectionUpdatesEditsRedactionsLateDecryptionAndRemovals() throws {
        var projection = SharedCollectionsProjection()
        var original = testItem(id: "$original", kind: .message)
        let old = json(["msgtype": "m.text", "body": "https://old.test"])
        let new = json(["msgtype": "m.text", "body": "https://new.test"])
        var result = try projection.apply([.reset([original])], contentJSON: [original.id: old], section: .links, encrypted: true)
        XCTAssertEqual(result.first?.url, "https://old.test")
        original.isEdited = true
        result = try projection.apply([.set(index: 0, item: original)], contentJSON: [original.id: new], section: .links, encrypted: true)
        XCTAssertEqual(result.first?.url, "https://new.test")
        original.kind = .placeholder(.redacted)
        XCTAssertEqual(try projection.apply([.set(index: 0, item: original)], contentJSON: [:], section: .links, encrypted: true), [])
        original.kind = .placeholder(.undecryptableOldHistory)
        XCTAssertEqual(try projection.apply([.reset([original])], contentJSON: [:], section: .links, encrypted: true), [])
        original.kind = .message
        XCTAssertEqual(try projection.apply([.set(index: 0, item: original)], contentJSON: [original.id: new], section: .links, encrypted: true).count, 1)
        XCTAssertEqual(try projection.apply([.remove(index: 0)], contentJSON: [:], section: .links, encrypted: true), [])
    }

    func testProjectionEncryptedMediaAndAtomicInvalidDiff() throws {
        var projection = SharedCollectionsProjection()
        let item = testItem(kind: .image(width: nil, height: nil))
        let content = json(["msgtype": "m.image", "file": ["url": "mxc://s/a"]])
        let result = try projection.apply([.reset([item])], contentJSON: [item.id: content], section: .media, encrypted: true)
        XCTAssertEqual(result.count, 1)
        XCTAssertThrowsError(try projection.apply([.remove(index: 4)], contentJSON: [:], section: .media, encrypted: true))
        XCTAssertEqual(try projection.apply([], contentJSON: [:], section: .media, encrypted: true), result)
        XCTAssertEqual(try projection.apply([.clear], contentJSON: [:], section: .media, encrypted: true), [])
    }

    func testProjectionCapsWithoutBreakingIndexAlignment() throws {
        var projection = SharedCollectionsProjection()
        let values = (0...SharedCollectionsPolicy.maximumTimelineEntries).map { testItem(id: "$\($0)", kind: .roomState) }
        XCTAssertThrowsError(try projection.apply([.reset(values)], contentJSON: [:], section: .links, encrypted: false))
        XCTAssertTrue(projection.capacityReached)
        XCTAssertEqual(try projection.apply([.reset([])], contentJSON: [:], section: .links, encrypted: false), [])
    }

    func testProjectionRetainsBoundedNewestWindowInTimelineOrder() throws {
        var projection = SharedCollectionsProjection()
        let values = (0..<650).map { testItem(id: "$e\($0)", at: Double(650 - $0)) }
        let bodies = Dictionary(uniqueKeysWithValues: values.map {
            ($0.id, json(["msgtype": "m.text", "body": "https://a.test"]))
        })
        let rows = try projection.apply([.reset(values)], contentJSON: bodies, section: .links, encrypted: false)
        XCTAssertEqual(rows.count, 600)
        XCTAssertEqual(rows.first?.eventID, "$e649")
        XCTAssertEqual(rows.last?.eventID, "$e50")
        XCTAssertTrue(projection.capacityReached)
    }

    func testNewestFirstDedupAndStableLinkOrder() {
        let old = rows("m.text", body: "https://old.test", section: .links, id: "$old", at: 1)
        let newer = rows("m.text", body: "https://a.test https://b.test", section: .links, id: "$new", at: 2)
        XCTAssertEqual(SharedCollectionsPolicy.newestFirst([old, newer, newer]).map(\.id), ["$new", "$new#1", "$old"])
    }

    private func rows(_ type: String, body: String = "photo.jpg", section: SharedCollectionSection,
                      id: String = "$event", at: TimeInterval = 1) -> [SharedCollectionItem] {
        project(testItem(id: id, at: at), content: ["msgtype": type, "body": body, "url": "mxc://s/a"], section: section)
    }
    private func project(_ item: ChatItem, content: [String: Any], section: SharedCollectionSection = .media,
                         encrypted: Bool = false) -> [SharedCollectionItem] {
        SharedCollectionsPolicy.items(section: section, item: item, latestContentJSON: json(content), encrypted: encrypted)
    }
}

private func testItem(id: String = "$event", kind: ChatItem.Kind = .message, at: TimeInterval = 1) -> ChatItem {
    ChatItem(id: id, kind: kind, sender: "@reader:example.test", timestamp: Date(timeIntervalSince1970: at),
             eventOrTransactionId: .event(id), media: ChatMedia(sourceHandle: "opaque-encrypted-source", byteSize: 12))
}
private func json(_ value: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!
}

@MainActor private final class SharedTestSource: SharedCollectionSource {
    let updates: AsyncStream<SharedCollectionSnapshot>
    let continuation: AsyncStream<SharedCollectionSnapshot>.Continuation
    var initial = SharedCollectionSnapshot()
    var pages: [SharedCollectionSnapshot] = []
    var requests: [UInt16] = []
    var fails = false
    var closed = false
    init() { (updates, continuation) = AsyncStream.makeStream() }
    func start() async throws -> SharedCollectionSnapshot { initial }
    func paginate(events: UInt16) async throws -> SharedCollectionSnapshot {
        requests.append(events)
        if fails { throw SharedCollectionFailure.unavailable }
        if !pages.isEmpty { initial = pages.removeFirst() }
        return initial
    }
    func close() { closed = true; continuation.finish() }
}

@available(macOS 14.0, *)
@MainActor final class SharedCollectionsPagingTests: XCTestCase {
    func testSparseReadStopsAtFourAndContinuesEvenAfterEmptyPages() async {
        let source = SharedTestSource()
        let model = SharedCollectionsModel(section: .links, source: source)
        await model.loadPreview()
        XCTAssertEqual(source.requests, [50, 50, 50, 50])
        XCTAssertEqual(model.state, .partial)
        XCTAssertTrue(model.canLoadMore)
        source.pages = [SharedCollectionSnapshot(reachedStart: true)]
        await model.loadMore()
        XCTAssertEqual(source.requests.count, 5)
        XCTAssertEqual(model.state, .empty)
        XCTAssertFalse(model.canLoadMore)
    }

    func testSeeAllAndLoadMoreUseCachedItemsWithoutSkipping() async {
        let source = SharedTestSource()
        source.initial = SharedCollectionSnapshot(items: makeRows(65), reachedStart: true)
        let model = SharedCollectionsModel(section: .links, source: source)
        await model.loadPreview()
        XCTAssertEqual(model.items.count, 3)
        XCTAssertTrue(model.contains(source.initial.items[50]))
        await model.seeAll()
        XCTAssertEqual(model.items.count, 30)
        await model.loadMore()
        XCTAssertEqual(model.items.count, 60)
        await model.loadMore()
        XCTAssertEqual(model.items.count, 65)
        XCTAssertEqual(Set(model.items.map(\.id)).count, 65)
        XCTAssertEqual(source.requests, [])
    }

    func testStopsOnEnoughItemsAndAtRoomStart() async {
        let source = SharedTestSource()
        source.pages = [SharedCollectionSnapshot(items: makeRows(10)), SharedCollectionSnapshot(items: makeRows(20), reachedStart: true)]
        let model = SharedCollectionsModel(section: .links, source: source)
        await model.loadPreview()
        XCTAssertEqual(source.requests.count, 1)
        XCTAssertEqual(model.state, .partial)
        await model.seeAll()
        XCTAssertEqual(source.requests.count, 2)
        XCTAssertEqual(model.state, .ready)
        XCTAssertFalse(model.canLoadMore)
    }

    func testFailurePreservesSubsetAndRetryResumes() async {
        let source = SharedTestSource()
        source.initial = SharedCollectionSnapshot(items: makeRows(1))
        source.fails = true
        let model = SharedCollectionsModel(section: .links, source: source)
        await model.loadPreview()
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(model.items.count, 1)
        source.fails = false
        source.pages = [SharedCollectionSnapshot(items: makeRows(4), reachedStart: true)]
        await model.retry()
        XCTAssertEqual(model.state, .ready)
        XCTAssertNil(model.failure)
    }

    func testTerminalSourceFailureStaysFailedUntilReopen() async {
        let source = SharedTestSource()
        source.initial = SharedCollectionSnapshot(items: makeRows(1), failure: .unavailable)
        let model = SharedCollectionsModel(section: .links, source: source)
        await model.loadPreview()
        XCTAssertTrue(model.requiresReopen)
        XCTAssertFalse(model.canLoadMore)
        XCTAssertEqual(model.state, .failed)
        await model.retry()
        XCTAssertEqual(model.state, .failed)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertTrue(source.requests.isEmpty)
    }

    func testOfflineCachedSubsetNeverTriggersPaginationAndCloseClears() async {
        let source = SharedTestSource()
        source.initial = SharedCollectionSnapshot(items: makeRows(2))
        let model = SharedCollectionsModel(section: .links, source: source)
        model.setOffline(true)
        await model.loadPreview()
        XCTAssertEqual(model.state, .offline)
        XCTAssertEqual(model.items.count, 2)
        XCTAssertTrue(source.requests.isEmpty)
        XCTAssertNil(model.unreadableCount)
        model.close()
        XCTAssertEqual(model.items, [])
        XCTAssertTrue(source.closed)
        await model.retry()
        XCTAssertTrue(source.requests.isEmpty)
    }

    func testStaleReadCannotRestoreRemovedRowsOrClaimCompleteHistory() async {
        let source = SharedTestSource()
        source.initial = SharedCollectionSnapshot(sequence: 5)
        source.pages = [SharedCollectionSnapshot(items: makeRows(1), reachedStart: true, sequence: 4)]
        let model = SharedCollectionsModel(section: .links, source: source)
        await model.loadPreview()
        XCTAssertEqual(model.items, [])
        XCTAssertFalse(model.reachedStart)
        XCTAssertEqual(model.state, .partial)
    }

    func testSectionCursorsAreIndependent() async {
        let links = SharedTestSource(), media = SharedTestSource()
        let linkModel = SharedCollectionsModel(section: .links, source: links)
        let mediaModel = SharedCollectionsModel(section: .media, source: media)
        await linkModel.loadPreview()
        XCTAssertEqual(links.requests.count, 4)
        XCTAssertEqual(media.requests.count, 0)
        await mediaModel.loadPreview()
        XCTAssertEqual(media.requests.count, 4)
    }

    private func makeRows(_ count: Int) -> [SharedCollectionItem] {
        (0..<count).map { index in
            SharedCollectionsPolicy.items(section: .links, item: testItem(id: "$e\(index)", at: Double(count - index)),
                                           latestContentJSON: json(["msgtype": "m.text", "body": "https://s\(index).test"]), encrypted: false)[0]
        }
    }
}
