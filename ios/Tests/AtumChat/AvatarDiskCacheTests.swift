import XCTest
@testable import AtumChat

final class AvatarDiskCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("avatar-disk-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStoreThenHitAndUnknownKeyMiss() async throws {
        let cache = AvatarDiskCache(directory: directory)
        let bytes = Data(repeating: 0x42, count: 512)
        let stored = await cache.store(bytes, for: "v1|mxc|mxc://atum.test/axe|156")
        XCTAssertTrue(stored)
        let hit = await cache.data(for: "v1|mxc|mxc://atum.test/axe|156")
        XCTAssertEqual(hit, bytes)
        let miss = await cache.data(for: "v1|mxc|mxc://atum.test/moon|156")
        XCTAssertNil(miss)
    }

    func testOversizeAndEmptyBytesAreRejected() async {
        let cache = AvatarDiskCache(directory: directory,
                                    limits: .init(maximumBytes: 2_048,
                                                  maximumEntryBytes: 1_024,
                                                  maximumEntries: 8))
        let tooBig = await cache.store(Data(repeating: 1, count: 1_025), for: "too-big")
        XCTAssertFalse(tooBig)
        let empty = await cache.store(Data(), for: "empty")
        XCTAssertFalse(empty)
        let tooBigData = await cache.data(for: "too-big")
        XCTAssertNil(tooBigData)
    }

    func testEntryLimitPrunesTheOldestBytes() async throws {
        let cache = AvatarDiskCache(directory: directory,
                                    limits: .init(maximumBytes: 4_096,
                                                  maximumEntryBytes: 1_024,
                                                  maximumEntries: 2))
        let firstStored = await cache.store(Data(repeating: 1, count: 32), for: "first")
        XCTAssertTrue(firstStored)
        try await Task.sleep(for: .milliseconds(20))
        let secondStored = await cache.store(Data(repeating: 2, count: 32), for: "second")
        XCTAssertTrue(secondStored)
        try await Task.sleep(for: .milliseconds(20))
        let thirdStored = await cache.store(Data(repeating: 3, count: 32), for: "third")
        XCTAssertTrue(thirdStored)

        let first = await cache.data(for: "first")
        let second = await cache.data(for: "second")
        let third = await cache.data(for: "third")
        XCTAssertNil(first, "the oldest entry is evicted first")
        XCTAssertNotNil(second)
        XCTAssertNotNil(third)
        let count = await cache.storedBytes()
        XCTAssertLessThanOrEqual(count, 4_096)
    }

    func testRemoveAllClearsEveryEntry() async {
        let cache = AvatarDiskCache(directory: directory)
        _ = await cache.store(Data(repeating: 1, count: 8), for: "one")
        _ = await cache.store(Data(repeating: 2, count: 8), for: "two")
        await cache.removeAll()
        let one = await cache.data(for: "one")
        XCTAssertNil(one)
        let bytes = await cache.storedBytes()
        XCTAssertEqual(bytes, 0)
    }
}
