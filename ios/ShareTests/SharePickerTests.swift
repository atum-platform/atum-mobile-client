import AtumChat
import AtumNativeAPI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import XCTest

/// The picker's bindings: sections, the Share Suggestion's preselection, selection
/// while files copy, the twenty-chat bound, the exported words and the preview strip.
@MainActor
final class SharePickerTests: XCTestCase {
    private let bundle = Bundle(for: SharePickerTests.self)
    private let account = ShareAccount(userID: "@owner:example.com", generation: UUID())

    private func chats(_ count: Int) -> [ShareChat] {
        (0..<count).map { ShareChat(id: "!c\($0):example.com", name: "Chat \($0)", isGroup: $0 % 3 == 0,
                                    recipients: ["@p\($0):example.com"]) }
    }

    private func queue(_ chats: [ShareChat]) throws -> ShareQueue {
        let q = ShareQueue(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try q.publish(ShareDirectory(account: account, chats: chats))
        addTeardownBlock { try? FileManager.default.removeItem(at: q.root) }
        return q
    }

    private var text: NSItemProvider { NSItemProvider(item: "body" as NSString, typeIdentifier: UTType.plainText.identifier) }

    // MARK: Sections

    func testRecentIsTheFiveNewestAndChatsAreTheRestOnce() {
        let all = chats(9)
        let sections = SharePickerSections.make(all: all, matches: all, search: "", suggested: nil)
        XCTAssertFalse(sections.isSearching)
        XCTAssertEqual(sections.recent.map(\.id), all.prefix(5).map(\.id))
        XCTAssertEqual(sections.chats.map(\.id), all.dropFirst(5).map(\.id))
    }

    func testSuggestionLeadsRecentEvenWhenOlder() {
        let all = chats(9)
        let sections = SharePickerSections.make(all: all, matches: all, search: "", suggested: all[7].id)
        XCTAssertEqual(sections.recent.map(\.id), [all[7].id] + all.prefix(4).map(\.id))
        XCTAssertFalse(sections.chats.contains(where: { $0.id == all[7].id }), "each chat is listed once")
        XCTAssertEqual(sections.recent.count + sections.chats.count, all.count)
    }

    func testStaleSuggestionIsIgnoredAndSearchShowsMatchesOnly() {
        let all = chats(3)
        XCTAssertEqual(SharePickerSections.make(all: all, matches: all, search: "", suggested: "!gone:example.com").recent,
                       all)
        let search = SharePickerSections.make(all: all, matches: [all[1]], search: "1", suggested: all[0].id)
        XCTAssertTrue(search.isSearching); XCTAssertTrue(search.recent.isEmpty); XCTAssertEqual(search.chats, [all[1]])
        XCTAssertTrue(SharePickerSections.make(all: all, matches: [], search: "zz", suggested: nil).isEmpty)
    }

    // MARK: Model binding

    func testSuggestionIsPreselectedAndExposedForRecent() async throws {
        let all = chats(8)
        let model = ShareComposerModel(queue: try queue(all), account: { self.account })
        await model.load(providers: [text], intent: ShareSuggestions.interaction(chat: all[6]).intent)
        XCTAssertEqual(model.suggestedChatID, all[6].id)
        XCTAssertEqual(model.selection, [all[6].id])
        let sections = SharePickerSections.make(all: model.recentChats, matches: model.chats, search: model.search,
                                                suggested: model.suggestedChatID)
        XCTAssertEqual(sections.recent.first?.id, all[6].id)
    }

    func testIneligibleSuggestionSelectsNothing() async throws {
        let model = ShareComposerModel(queue: try queue(chats(2)), account: { self.account })
        let hidden = ShareChat(id: "!hidden:example.com", name: "Hidden", isGroup: false, recipients: ["@h:example.com"])
        await model.load(providers: [text], intent: ShareSuggestions.interaction(chat: hidden).intent)
        XCTAssertNil(model.suggestedChatID); XCTAssertTrue(model.selection.isEmpty); XCTAssertFalse(model.canSend)
    }

    func testChatsCanBeChosenWhileFilesCopyButSendWaitsForReady() async throws {
        let all = chats(3)
        let q = try queue(all)
        let model = ShareComposerModel(queue: q, account: { self.account })
        let gate = AsyncStream<Void>.makeStream()
        let slow = NSItemProvider()
        slow.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            Task { for await _ in gate.stream { break }; completion(Data("late".utf8), nil) }
            return nil
        }
        let loading = Task { await model.load(providers: [slow], intent: nil) }
        for _ in 0..<200 where model.recentChats.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.phase, .loading)
        model.toggle(all[1]); model.caption = "while loading"
        XCTAssertEqual(model.selection, [all[1].id]); XCTAssertFalse(model.canSend, "send waits for the copy")
        model.toggle(ShareChat(id: "!other:example.com", name: "x", isGroup: false, recipients: []))
        XCTAssertEqual(model.selection, [all[1].id], "only chats in the snapshot can be chosen")
        gate.continuation.yield(); gate.continuation.finish()
        await loading.value
        XCTAssertEqual(model.phase, .ready); XCTAssertTrue(model.canSend)
        model.send()
        XCTAssertEqual(model.phase, .queued)
        XCTAssertEqual(try q.jobs(account: account).first?.caption, "while loading")
    }

    func testSelectionStopsAtTwentyAndReportsTheLimit() async throws {
        let all = chats(22)
        let model = ShareComposerModel(queue: try queue(all), account: { self.account })
        await model.load(providers: [text], intent: nil)
        for chat in all { model.toggle(chat) }
        XCTAssertEqual(model.selection.count, ShareComposerModel.maximumSelection)
        XCTAssertTrue(model.isAtSelectionLimit); XCTAssertTrue(model.canSend)
        model.toggle(all[0])
        XCTAssertFalse(model.isAtSelectionLimit)
        XCTAssertEqual(model.selection.count, 19)
    }

    func testSelectionSurvivesSearchAndToggleIsIgnoredAfterQueuing() async throws {
        let all = chats(4)
        let model = ShareComposerModel(queue: try queue(all), account: { self.account })
        await model.load(providers: [text], intent: nil)
        model.toggle(all[0]); model.search = "Chat 2"; model.toggle(all[2])
        XCTAssertEqual(model.chats.map(\.id), [all[2].id])
        model.search = ""
        XCTAssertEqual(model.selection, [all[0].id, all[2].id])
        model.send(); XCTAssertEqual(model.phase, .queued)
        model.toggle(all[3])
        XCTAssertEqual(model.selection, [all[0].id, all[2].id])
        XCTAssertNil(model.stagedFile(for: model.items[0]), "no previews after queueing")
    }

    // MARK: Copy

    func testExportedWordsResolveInTheBundledTable() {
        for key in SharePickerCopy.Key.allCases {
            let value = SharePickerCopy.text(key, bundle: bundle)
            XCTAssertNotEqual(value, key.rawValue, "\(key) is missing from ShareLocalizable")
            XCTAssertFalse(value.isEmpty)
        }
        let one = SharePickerCopy.selected(1, bundle: bundle), three = SharePickerCopy.selected(3, bundle: bundle)
        XCTAssertTrue(one.contains("1")); XCTAssertTrue(three.contains("3")); XCTAssertNotEqual(one, three)
        XCTAssertFalse(three.contains("%"), "the plural format resolved")
    }

    func testThePickerTableIsExactlyTheGeneratedKeys() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Share/ShareLocalizable.xcstrings")
        let table = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let keys = Set((table?["strings"] as? [String: Any] ?? [:]).keys)
        XCTAssertEqual(keys, Set(SharePickerCopy.Key.allCases.map(\.rawValue)))
    }

    func testPreviewLabelsNameEveryKind() {
        XCTAssertEqual(SharePreviewText.label(ShareItem(kind: .image, file: UUID().uuidString), bundle: bundle),
                       SharePickerCopy.text(.photo, bundle: bundle))
        XCTAssertEqual(SharePreviewText.label(ShareItem(kind: .video, file: UUID().uuidString), bundle: bundle),
                       SharePickerCopy.text(.video, bundle: bundle))
        XCTAssertTrue(SharePreviewText.label(ShareItem(kind: .file, file: "x", filename: "plan.pdf"), bundle: bundle)
            .hasSuffix(", plan.pdf"))
        XCTAssertEqual(SharePreviewText.detail(ShareItem(kind: .url, text: "https://atum.chat/a?b=c")), "atum.chat")
        XCTAssertEqual(SharePreviewText.detail(ShareItem(kind: .url, text: "not a url at all")), "not a url at all")
        let long = String(repeating: "word ", count: 40) + "\nsecond line"
        let detail = try? XCTUnwrap(SharePreviewText.detail(ShareItem(kind: .text, text: long)))
        XCTAssertEqual(detail?.count, 80); XCTAssertEqual(detail?.last, "…")
        XCTAssertNil(SharePreviewText.detail(ShareItem(kind: .text, text: "  \n ")))
    }

    // MARK: Host-style providers

    /// Files-style `NSItemProvider(contentsOf:)` and Safari-style object URLs, beside the
    /// registered representations ShareItemLoaderTests covers.
    private func hostInputs() throws -> (ShareQueue, UUID, ShareItemLoader, URL) {
        let q = try queue(chats(1)); let job = try q.begin()
        let folder = q.root.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (q, job, ShareItemLoader(queue: q), folder)
    }

    func testContentsOfImageProviderLoads() async throws {
        let (_, job, loader, folder) = try hostInputs()
        let png = folder.appendingPathComponent("photo.png")
        try UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).pngData { _ in }.write(to: png)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: png))
        let image = try await loader.load(provider, jobID: job)
        XCTAssertEqual(image.kind, .image, provider.registeredTypeIdentifiers.description)
    }

    func testContentsOfFileProviderLoads() async throws {
        let (_, job, loader, folder) = try hostInputs()
        let pdf = folder.appendingPathComponent("plan.pdf"); try Data("%PDF-1.4\n%%EOF\n".utf8).write(to: pdf)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: pdf))
        let file = try await loader.load(provider, jobID: job)
        XCTAssertEqual(file.kind, .file, provider.registeredTypeIdentifiers.description)
        XCTAssertEqual(file.filename, "plan.pdf")
    }

    func testObjectURLProviderLoads() async throws {
        let (_, job, loader, _) = try hostInputs()
        let provider = NSItemProvider(object: URL(string: "https://atum.chat/x")! as NSURL)
        let link = try await loader.load(provider, jobID: job)
        XCTAssertEqual(link.kind, .url, provider.registeredTypeIdentifiers.description)
        XCTAssertEqual(link.text, "https://atum.chat/x")
    }

    // MARK: Design inputs

    func testKitTokensAndFacesMatchHome() throws {
        XCTAssertNotNil(SharePickerDesign.kit(bundle: bundle), "atum-kit-tokens.json is bundled and decodes")
        let face: (ShareChat.Face?, Bool) -> AtumAvatarKind = { face, group in
            SharePickerDesign.avatarKind(ShareChat(id: "!x:e", name: "X", isGroup: group, recipients: [], face: face))
        }
        XCTAssertEqual(face(.app, false), .app); XCTAssertEqual(face(.atum, false), .atum)
        XCTAssertEqual(face(.assistant, false), .assistant)
        XCTAssertEqual(face(nil, true), .group); XCTAssertEqual(face(nil, false), .person)
        XCTAssertEqual(AvatarShapePolicy.frame(for: face(.app, false)), .squircle)
    }

    func testSnapshotWithoutFaceFieldsStillDecodes() throws {
        let old = #"{"id":"!a:e","name":"A","isGroup":false,"recipients":["@b:e"]}"#
        let chat = try JSONDecoder().decode(ShareChat.self, from: Data(old.utf8))
        XCTAssertNil(chat.face); XCTAssertNil(chat.mark)
        let marked = ShareChat(id: "!a:e", name: "A", isGroup: false, recipients: [], face: .assistant,
                               mark: AgentMark(shape: .spark, color: .mint))
        XCTAssertEqual(try JSONDecoder().decode(ShareChat.self, from: JSONEncoder().encode(marked)), marked)
    }

    func testStagedPhotoThumbnailIsSmall() async throws {
        let model = ShareComposerModel(queue: try queue(chats(1)), account: { self.account })
        let png = UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 1_200)).pngData { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 1_200))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try png.write(to: file); addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        await model.load(providers: [try XCTUnwrap(NSItemProvider(contentsOf: file))], intent: nil)
        let item = try XCTUnwrap(model.items.first); XCTAssertEqual(item.kind, .image)
        let staged = try XCTUnwrap(model.stagedFile(for: item))
        let image = await ShareThumbnail.image(url: staged, isVideo: false, typeIdentifier: item.typeIdentifier, pixelSide: 216)
        let size = try XCTUnwrap(image?.cgImage).width
        XCTAssertEqual(size, 216, "the longest side is the requested thumbnail, not the 1600 px original")
    }
}
