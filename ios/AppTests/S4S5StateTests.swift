@testable import AtumMobile
import AtumChat
import Foundation
import XCTest

final class S4S5StateTests: XCTestCase {
    @MainActor
    func testMediaComposerRestoresAndTakesPreparedItemsInOrder() {
        let state = ChatMediaComposerState()
        let photo = OutgoingChatAttachment(
            id: "photo", kind: .image(width: 4, height: 3, isAnimated: false),
            filePath: "/tmp/photo.jpg", filename: "photo.jpg",
            mimetype: "image/jpeg", byteSize: 10
        )
        let file = OutgoingChatAttachment(
            id: "file", kind: .file, filePath: "/tmp/file.pdf",
            filename: "file.pdf", mimetype: "application/pdf", byteSize: 20
        )
        state.restore([photo, file])
        XCTAssertEqual(state.items.map(\.id), ["photo", "file"])
        XCTAssertTrue(state.canSend)
        XCTAssertEqual(state.takeReadyAttachments(), [photo, file])
        XCTAssertTrue(state.items.isEmpty)
    }

    func testAuthenticatedNoticeProjectionUsesCatalogAndHidesSelfTarget() {
        let app = AppBotPresentation(
            appID: "00000000-0000-4000-8000-893af8437b12",
            slug: "moon", botUserID: "@app-moon:atum.test", name: "Moon",
            subtitle: "subtitle", avatarURL: URL(string: "https://example.test/moon.png")!,
            avatarSHA256: String(repeating: "0", count: 64), accentHex: "#D8612F",
            verification: .official, purchaseRouteID: "purchase", setupComplete: false
        )
        let metadata = #"{"action":{"app":"moon","kind":"open_setup"},"app_id":"00000000-0000-4000-8000-893af8437b12","code":"needs_setup","kind":"notice","turn_id":null,"v":1}"#
        let envelope = #"{"content":{"io.atum.app_bot":\#(metadata)},"sender":"@app-moon:atum.test"}"#
        let item = ChatItem(id: "notice", kind: .notice, sender: app.botUserID,
                            body: "fallback", appBotMeta: envelope)
        let row = ChatRow(item: item)
        let catalog = AppBotCatalogPresentation(appsByBotUserID: [app.botUserID: app],
                                                roomIDBySlug: [app.slug: "!moon:atum.test"])
        let displays = AppBotNoticeProjection.displays(
            .init(rows: [row], catalog: catalog, roomID: "!current:atum.test",
                  roomIsEncrypted: false)
        )
        XCTAssertEqual(displays["notice"]?.message.code, .needsSetup)
        XCTAssertEqual(displays["notice"]?.action, .openSetup(app: "moon"))

        XCTAssertTrue(AppBotNoticeProjection.displays(
            .init(rows: [row], catalog: catalog, roomID: "!current:atum.test",
                  roomIsEncrypted: true)
        ).isEmpty)

        var oldItem = item
        oldItem.id = "old"
        oldItem.timestamp = Date(timeIntervalSince1970: 1)
        var newItem = item
        newItem.id = "new"
        newItem.timestamp = Date(timeIntervalSince1970: 2)
        let reversed = AppBotNoticeProjection.displays(
            .init(rows: [ChatRow(item: newItem), ChatRow(item: oldItem)],
                  catalog: catalog, roomID: "!current:atum.test", roomIsEncrypted: false)
        )
        XCTAssertNil(reversed["old"]?.action)
        XCTAssertEqual(reversed["new"]?.action, .openSetup(app: "moon"))
    }

    @MainActor
    func testMediaComposerKeepsBatchRefusalPriority() {
        let state = ChatMediaComposerState()
        let existing = (0..<8).map { index in
            OutgoingChatAttachment(
                id: "existing-\(index)", kind: .file,
                filePath: "/tmp/existing-\(index)", filename: "existing-\(index).pdf",
                mimetype: "application/pdf", byteSize: 1
            )
        }
        state.restore(existing)

        state.beginSelection()
        state.showTooMany()
        XCTAssertNotNil(state.reserve(.photo, name: "one.jpg"))
        XCTAssertNotNil(state.reserve(.file, name: "two.pdf"))
        XCTAssertEqual(state.refusal, .tooMany(limit: MediaAttachmentPolicy.maximumItems))

        state.beginSelection()
        state.showScriptedRefusal(.tooLargePhoto)
        state.showScriptedRefusal(.unreadable)
        XCTAssertEqual(state.refusal, .tooLargePhoto)

        state.showScriptedRefusal(.tooMany(limit: MediaAttachmentPolicy.maximumItems))
        state.showScriptedRefusal(.tooLargeFile)
        XCTAssertEqual(state.refusal, .tooMany(limit: MediaAttachmentPolicy.maximumItems))
    }

    @MainActor
    func testLocalMediaDraftMatchesOutOfOrderEchoesAndSurvivesAStoreReplacement() {
        let first = OutgoingChatAttachment(
            id: "first", kind: .image(width: 4, height: 3, isAnimated: false),
            filePath: "/tmp/first.jpg", filename: "first.jpg",
            mimetype: "image/jpeg", byteSize: 11
        )
        let second = OutgoingChatAttachment(
            id: "second", kind: .image(width: 4, height: 3, isAnimated: false),
            filePath: "/tmp/second.jpg", filename: "second.jpg",
            mimetype: "image/jpeg", byteSize: 22
        )
        let draft = ConversationLocalMediaDraft()
        draft.append([first, second])

        let secondRow = localEcho(id: "local.second", attachment: second)
        let firstRow = localEcho(id: "local.first", attachment: first)
        let matched = draft.match(rows: [secondRow, firstRow])
        XCTAssertEqual(matched[secondRow.id]?.path, second.filePath)
        XCTAssertEqual(matched[firstRow.id]?.path, first.filePath)

        let info = ConversationRoomInfo(
            roomID: "!room:atum.test", title: "Lan",
            context: RoomContext(kind: .person, ownUserID: "@me:atum.test"),
            knownNames: [:], catalogBotUserIDs: [], languageCode: "vi",
            roomIsEncrypted: true
        )
        let replacement = LiveConversationStore(info: info, localMediaDraft: draft)
        XCTAssertEqual(replacement.localMediaFiles, matched)
        XCTAssertEqual(draft.match(rows: [secondRow, firstRow]), matched)
    }

    private func localEcho(id: String, attachment: OutgoingChatAttachment) -> ChatRow {
        let kind: ChatItem.Kind = switch attachment.kind {
        case let .image(width, height, _): .image(width: Double(width), height: Double(height))
        case .file: .file(name: attachment.filename)
        }
        let media = ChatMedia(sourceHandle: "source:" + id,
                              mimetype: attachment.mimetype,
                              filename: attachment.filename,
                              byteSize: attachment.byteSize)
        return ChatRow(item: ChatItem(id: id, kind: kind, sender: "@me:atum.test",
                                     isOwn: true, isLocalEcho: true,
                                     eventOrTransactionId: .transaction("txn-" + id),
                                     media: media))
    }

    func testMediaMemoryCacheEvictsByBytes() async {
        let cache = ChatMediaMemoryCache(maximumEntries: 10, maximumBytes: 4)
        await cache.insert(Data([1, 2, 3]), for: "first")
        await cache.insert(Data([4, 5, 6]), for: "second")
        let first = await cache.value(for: "first")
        let second = await cache.value(for: "second")
        XCTAssertNil(first)
        XCTAssertEqual(second, Data([4, 5, 6]))
    }

    @MainActor
    func testViewerShareCopyOutlivesTheUploadStagingFile() async throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-viewer-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("photo.jpg")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        let retainedValue = await MediaViewer.retainedShareFile(data: bytes, sourceURL: source)
        let retained = try XCTUnwrap(retainedValue)
        defer { try? FileManager.default.removeItem(at: retained.directory) }
        try FileManager.default.removeItem(at: source)

        XCTAssertEqual(try Data(contentsOf: retained.file), bytes)
    }
}
