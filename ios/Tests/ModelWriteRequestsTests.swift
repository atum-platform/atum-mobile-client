import XCTest
@testable import AtumNativeAPI

final class ModelWriteRequestsTests: XCTestCase {
    private struct Write: Hashable, Sendable {
        let model: String
        let effort: ManagedModelEffort
    }

    func testAnIdenticalRetryAfterAFailedWriteReusesTheKey() {
        var requests = ModelWriteRequests<Write>()
        let first = requests.begin(Write(model: "nhat-thuc", effort: .high))
        // The write failed in transit: nothing settles it.
        let retry = requests.begin(Write(model: "nhat-thuc", effort: .high))
        XCTAssertEqual(first, retry, "the provider may have it, so the replay is idempotent")
        XCTAssertEqual(requests.pendingPayload, Write(model: "nhat-thuc", effort: .high))
    }

    func testADifferentSelectionGetsANewKeyAndDropsTheStalePendingOne() {
        var requests = ModelWriteRequests<Write>()
        let first = requests.begin(Write(model: "nhat-thuc", effort: .high))
        let otherModel = requests.begin(Write(model: "nguyet-thuc", effort: .high))
        XCTAssertNotEqual(first, otherModel)
        XCTAssertEqual(requests.pendingPayload?.model, "nguyet-thuc", "the stale one is gone")
        // Going back to the first selection is a new operation, not the old key.
        let back = requests.begin(Write(model: "nhat-thuc", effort: .high))
        XCTAssertNotEqual(back, first)
        XCTAssertNotEqual(back, otherModel)
        // A different thinking level for the same model is also different.
        XCTAssertNotEqual(requests.begin(Write(model: "nhat-thuc", effort: .low)), back)
    }

    func testASettledWriteNeverLendsItsKeyToTheNextOne() {
        var requests = ModelWriteRequests<Write>()
        let first = requests.begin(Write(model: "nhat-thuc", effort: .high))
        requests.settled()
        XCTAssertNil(requests.pendingPayload)
        XCTAssertNotEqual(requests.begin(Write(model: "nhat-thuc", effort: .high)), first)
    }

    func testKeysAreValidNativeIDs() {
        XCTAssertNoThrow(try NativeID(ModelWriteRequests<Write>.freshID().rawValue))
    }
}
