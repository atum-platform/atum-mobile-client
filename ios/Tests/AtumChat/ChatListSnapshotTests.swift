import XCTest
@testable import AtumChat

final class ChatListSnapshotTests: XCTestCase {
    private var directory: URL!
    private var store: ChatListSnapshotStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-list-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ChatListSnapshotStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func row(_ id: String, kind: ChatListSnapshot.Kind = .person,
                     avatar: String? = nil, preview: String? = nil,
                     unread: Int = 0, founder: Bool = false) -> ChatListSnapshot.Room {
        ChatListSnapshot.Room(
            id: id, roomID: id, kind: kind, name: "Room \(id)",
            verification: kind == .app ? .official : nil,
            avatarURL: avatar,
            matrixAvatarURL: kind == .person ? "mxc://atum.test/\(id)" : nil,
            avatarSHA256: avatar == nil ? nil : String(repeating: "a", count: 64),
            avatarCandidates: avatar.map {
                [.init(url: $0, sha256: String(repeating: "b", count: 64))]
            } ?? [],
            preview: preview.map {
                RowPreview.Display(prefix: .none, value: .text($0), sendState: .sent)
            } ?? .init(prefix: .none, value: .empty, sendState: .sent),
            latestEventAt: Date(timeIntervalSince1970: 1_800),
            unreadCount: unread, notificationCount: unread,
            isPinned: false, isMuted: false, canOpen: true,
            isFounder: founder
        )
    }

    func testSnapshotRoundTripsEveryRenderedField() throws {
        let rows = [
            row("axe", kind: .assistant, avatar: "https://cdn.atum.test/axe.png", preview: "Building now"),
            row("founder", kind: .person, preview: "Atum founder", unread: 2, founder: true),
            row("app:demoza", kind: .app, avatar: "https://cdn.atum.test/demoza.png"),
        ]
        try store.save(accountID: "@owner:atum.test", rooms: rows,
                       savedAt: Date(timeIntervalSince1970: 1_000))

        let loaded = try XCTUnwrap(store.load(accountID: "@owner:atum.test",
                                              now: Date(timeIntervalSince1970: 2_000)))
        XCTAssertEqual(loaded.rooms, rows)
        XCTAssertEqual(loaded.schemaVersion, ChatListSnapshot.schemaVersion)
    }

    func testSnapshotIsAccountScoped() throws {
        try store.save(accountID: "@other:atum.test", rooms: [row("a")])
        XCTAssertNil(store.load(accountID: "@owner:atum.test"),
                     "another sign-in must never read a previous account's rows")
    }

    func testStaleAndCorruptSnapshotsAreAbsent() throws {
        try store.save(accountID: "@owner:atum.test", rooms: [row("a")],
                       savedAt: Date(timeIntervalSince1970: 1_000))
        XCTAssertNil(store.load(accountID: "@owner:atum.test",
                                now: Date(timeIntervalSince1970: 1_000 + 31 * 24 * 60 * 60)))
        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertNil(store.load(accountID: "@owner:atum.test"))
    }

    func testMergeKeepsCachedIdentityAndPreviewWhileLiveSourcesArePartial() {
        let cached = row("axe", kind: .assistant, avatar: "https://cdn.atum.test/axe.png",
                         preview: "Last real answer")
        // The room list synced before /agents: same room, no photo, no real
        // preview yet.
        var live = cached
        live.kind = .person
        live.avatarURL = nil
        live.avatarSHA256 = nil
        live.avatarCandidates = []
        live.preview = .init(prefix: .none, value: .empty, sendState: .sent)
        live.unreadCount = 4
        live.notificationCount = 4

        let merged = ChatListSnapshot.merged(cached: [cached], live: [live],
                                             liveIsAuthoritative: false)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].kind, .assistant, "a partial classification never demotes a cached row")
        XCTAssertEqual(merged[0].avatarURL, "https://cdn.atum.test/axe.png")
        XCTAssertEqual(merged[0].preview.value, .text("Last real answer"))
        XCTAssertEqual(merged[0].unreadCount, 4, "live counts still move")
    }

    func testMergeLetsRealLivePreviewReplaceTheCachedOne() {
        var cached = row("founder", preview: "Old line")
        var live = cached
        live.preview = .init(prefix: .none, value: .text("New line"), sendState: .sent)
        live.latestEventAt = cached.latestEventAt?.addingTimeInterval(10)

        let merged = ChatListSnapshot.merged(cached: [cached], live: [live],
                                             liveIsAuthoritative: false)
        XCTAssertEqual(merged[0].preview.value, .text("New line"))
        XCTAssertEqual(merged[0].latestEventAt, live.latestEventAt)
        cached.preview = .init(prefix: .none, value: .empty, sendState: .sent)
    }

    func testMergeAppendsLiveOnlyRowsAndDropsCacheWhenAuthoritative() {
        let cached = row("old")
        let fresh = row("new")
        let partial = ChatListSnapshot.merged(cached: [cached], live: [fresh],
                                              liveIsAuthoritative: false)
        XCTAssertEqual(partial.map(\.id), ["old", "new"])

        let authoritative = ChatListSnapshot.merged(cached: [cached], live: [fresh],
                                                    liveIsAuthoritative: true)
        XCTAssertEqual(authoritative.map(\.id), ["new"])
        XCTAssertEqual(ChatListSnapshot.merged(cached: [cached], live: [],
                                               liveIsAuthoritative: true), [])
    }

    func testAuthoritativeMergeKeepsTheLastRealPreviewForADeliveryNotice() {
        let cached = row("demoza", kind: .app, preview: "Here is your reading")
        var live = cached
        live.latestWasDeliveryNotice = true
        live.preview = .init(prefix: .none, value: .empty, sendState: .sent)
        let kept = ChatListSnapshot.merged(cached: [cached], live: [live],
                                           liveIsAuthoritative: true)
        XCTAssertEqual(kept[0].preview.value, .text("Here is your reading"))
        XCTAssertTrue(kept[0].latestWasDeliveryNotice)

        // A genuinely empty room gets no borrowed line.
        var empty = live
        empty.id = "empty"
        empty.roomID = "empty"
        let noBorrow = ChatListSnapshot.merged(cached: [cached], live: [empty],
                                               liveIsAuthoritative: true)
        XCTAssertEqual(noBorrow[0].preview.value, .empty)
    }

    func testFounderIdentitySurvivesAPartialLiveRow() {
        let cached = row("founder", founder: true)
        var live = cached
        live.isFounder = false
        let merged = ChatListSnapshot.merged(cached: [cached], live: [live],
                                             liveIsAuthoritative: false)
        XCTAssertTrue(merged[0].isFounder)
    }

    func testUncertainDeliveryNoticesAreNeverPreviews() {
        let vi = "Demoza có thể đã nhận tin này nhưng câu trả lời không về được đây. "
            + "Lượt nhắn có thể đã được tính và Atum đang kiểm tra lại. "
            + "Nếu bạn không nhận được câu trả lời, hãy báo support@atumplatform.com."
        let en = "Demoza may have received this message, but its answer didn't make it back here. "
            + "The message may have been counted, and Atum is checking. "
            + "If no answer reaches you, email support@atumplatform.com."
        XCTAssertTrue(RowPreview.suppressesPreview(body: vi + "\n" + en, isOwn: false))
        XCTAssertFalse(RowPreview.suppressesPreview(body: vi + "\n" + en, isOwn: true))
        XCTAssertFalse(RowPreview.suppressesPreview(body: "A normal answer", isOwn: false))
        XCTAssertFalse(RowPreview.suppressesPreview(body: "line one\nline two", isOwn: false))
        // A single-language notice is still a delivery warning.
        XCTAssertTrue(RowPreview.suppressesPreview(body: en, isOwn: false, isNotice: true))
        XCTAssertFalse(RowPreview.suppressesPreview(body: en, isOwn: false))
    }
}
