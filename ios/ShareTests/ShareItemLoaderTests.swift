import AtumNativeAPI
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ShareItemLoaderTests: XCTestCase {
    private func fixture() throws -> (ShareQueue, UUID, ShareItemLoader) {
        let queue = ShareQueue(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let id = try queue.begin()
        addTeardownBlock { try? FileManager.default.removeItem(at: queue.root) }
        return (queue, id, ShareItemLoader(queue: queue))
    }
    private func fileProvider(queue: ShareQueue, type: UTType, name: String) throws -> NSItemProvider {
        let file = queue.root.appendingPathComponent(name); try Data("file payload".utf8).write(to: file)
        let provider = NSItemProvider(); provider.suggestedName = name
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(file, false, nil); return nil
        }
        return provider
    }
    func testImageCopiedWithoutDecode() async throws {
        let (q, id, loader) = try fixture()
        let item = try await loader.load(fileProvider(queue: q, type: .png, name: "photo.png"), jobID: id)
        XCTAssertEqual(item.kind, .image); XCTAssertEqual(item.typeIdentifier, UTType.png.identifier)
        XCTAssertEqual(try Data(contentsOf: q.fileURL(item, jobID: id)), Data("file payload".utf8))
    }
    func testVideoCopiedToGroup() async throws {
        let (q, id, loader) = try fixture()
        let item = try await loader.load(fileProvider(queue: q, type: .mpeg4Movie, name: "clip.mp4"), jobID: id)
        XCTAssertEqual(item.kind, .video); XCTAssertEqual(item.filename, "clip.mp4")
    }
    func testGenericFileCopiedToGroup() async throws {
        let (q, id, loader) = try fixture()
        let item = try await loader.load(fileProvider(queue: q, type: .pdf, name: "document.pdf"), jobID: id)
        XCTAssertEqual(item.kind, .file); XCTAssertEqual(item.filename, "document.pdf")
    }
    func testFileURLIsAttachmentNotLink() async throws {
        let (q, id, loader) = try fixture()
        let file = q.root.appendingPathComponent("file.txt"); try Data("hello".utf8).write(to: file)
        let provider = NSItemProvider(item: file as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let item = try await loader.load(provider, jobID: id)
        XCTAssertEqual(item.kind, .file); XCTAssertNotNil(item.file); XCTAssertNil(item.text)
    }
    func testURL() async throws {
        let (_, id, loader) = try fixture()
        let provider = NSItemProvider(item: URL(string: "https://example.com/page")! as NSURL, typeIdentifier: UTType.url.identifier)
        let item = try await loader.load(provider, jobID: id)
        XCTAssertEqual(item.kind, .url); XCTAssertEqual(item.text, "https://example.com/page")
    }
    func testText() async throws {
        let (_, id, loader) = try fixture()
        let item = try await loader.load(NSItemProvider(item: "hello" as NSString, typeIdentifier: UTType.plainText.identifier), jobID: id)
        XCTAssertEqual(item.kind, .text); XCTAssertEqual(item.text, "hello")
    }
    func testMixedItemsAndProgress() async throws {
        let (q, id, loader) = try fixture()
        var progress = [Double]()
        let values = try await loader.load([
            try fileProvider(queue: q, type: .png, name: "photo.png"),
            NSItemProvider(item: "hello" as NSString, typeIdentifier: UTType.plainText.identifier)
        ], jobID: id) { progress.append($0) }
        XCTAssertEqual(values.map(\.kind), [.image, .text]); XCTAssertEqual(progress, [0.5, 1])
    }
    func testUnsupportedProviderFailsWholeIntake() async throws {
        let (_, id, loader) = try fixture()
        do { _ = try await loader.load(NSItemProvider(), jobID: id); XCTFail() } catch {}
    }
    func testAttributedTextWithoutProvider() async throws {
        let (_, id, loader) = try fixture()
        let input = NSExtensionItem(); input.attributedContentText = NSAttributedString(string: "selected text")
        let providers = ShareItemLoader.providers(from: [input])
        let item = try await loader.load(providers[0], jobID: id)
        XCTAssertEqual(item.text, "selected text"); XCTAssertEqual(item.kind, .text)
    }
    func testAttributedTitleDoesNotDuplicateAttachment() throws {
        let input = NSExtensionItem(); input.attributedContentText = NSAttributedString(string: "title")
        input.attachments = [NSItemProvider(item: "body" as NSString, typeIdentifier: UTType.plainText.identifier)]
        XCTAssertEqual(ShareItemLoader.providers(from: [input]).count, 1)
    }
    func testTooManyItemsRefused() async throws {
        let (_, id, loader) = try fixture()
        do { _ = try await loader.load(Array(repeating: NSItemProvider(), count: 11), jobID: id) { _ in }; XCTFail() } catch {}
    }
}
