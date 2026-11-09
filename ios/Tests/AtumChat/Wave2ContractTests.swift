import XCTest
@testable import AtumChat

final class Wave2ContractTests: XCTestCase {
    @MainActor
    private final class RouterSpy: RouterOpening {
        var rooms = [String]()
        var apps = [String]()
        func open(roomId: String) { rooms.append(roomId) }
        func open(app: String) { apps.append(app) }
    }

    @MainActor
    func testRouterOpeningFreezesRoomAndAppEntryPoints() {
        let router = RouterSpy()
        router.open(roomId: "!room")
        router.open(app: "moon")
        XCTAssertEqual(router.rooms, ["!room"])
        XCTAssertEqual(router.apps, ["moon"])
    }

    func testMediaContractKeepsOpaqueSourcesAndInternalSize() {
        let media = ChatMedia(sourceHandle: "source-1", thumbnailSourceHandle: "thumb-1",
                              mimetype: "image/jpeg", filename: "photo.jpg",
                              isAnimated: false, byteSize: 42)
        let item = ChatItem(id: "photo", kind: .image(width: 4, height: 3), media: media)
        XCTAssertEqual(item.media, media)
        XCTAssertEqual(item.media?.byteSize, 42)
    }

    func testSendingProgressDistinguishesUnknownAndMeasuredUploads() {
        XCTAssertEqual(ChatDelivery.sending(), .sending(progress: nil))
        XCTAssertNotEqual(ChatDelivery.sending(), .sending(progress: 0.5))
        XCTAssertEqual(ChatDelivery.sending(progress: 0.5).uploadProgress, 0.5)
        XCTAssertEqual(ChatDelivery.sending(progress: 0).uploadProgress, 0)
        XCTAssertEqual(ChatDelivery.sending(progress: 1).uploadProgress, 1)
        XCTAssertNil(ChatDelivery.sending(progress: -.infinity).uploadProgress)
        XCTAssertNil(ChatDelivery.sending(progress: -.leastNonzeroMagnitude).uploadProgress)
        XCTAssertNil(ChatDelivery.sending(progress: 1.01).uploadProgress)
        XCTAssertNil(ChatDelivery.sending(progress: .nan).uploadProgress)

        let sending = ChatItem(id: "upload", kind: .file(name: "a.pdf"), isOwn: true,
                               delivery: .sending(progress: 0.5))
        XCTAssertEqual(Delivery.mark(for: sending), .sending)
    }
}
