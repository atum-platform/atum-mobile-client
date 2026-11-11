import XCTest
@testable import AtumChat

final class PushDeliveryTests: XCTestCase {
    func testSuccessWinsOverLateExpiryAndDuplicateResult() {
        var values: [String] = []
        let delivery = PushDelivery(fallback: "generic") { values.append($0) }
        delivery.finish("rich"); delivery.expire(); delivery.finish("late")
        XCTAssertEqual(values, ["rich"])
    }
    func testOSExpiryWinsOverLateResult() {
        var values: [String] = []
        let delivery = PushDelivery(fallback: "generic") { values.append($0) }
        delivery.expire(); delivery.finish("rich"); delivery.expire()
        XCTAssertEqual(values, ["generic"])
    }
    func testConcurrentExpiryAndResultsCallHandlerOnce() {
        let values = Values()
        let delivery = PushDelivery(fallback: "generic") { values.append($0) }
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            if i.isMultiple(of: 2) { delivery.expire() } else { delivery.finish("rich") }
        }
        XCTAssertEqual(values.count, 1)
    }
    func testHandlerCanReenterCompletion() {
        var count = 0
        var delivery: PushDelivery<String>!
        delivery = PushDelivery(fallback: "generic") { _ in count += 1; delivery.expire() }
        delivery.finish("rich")
        XCTAssertEqual(count, 1)
    }
    func testFakeDeadlineCompletesWhileFetchIgnoresCancellation() async {
        let fetch = SuspendedFetch()
        let delivered = expectation(description: "generic before fetch returns")
        let values = Values()
        let delivery = PushDelivery(fallback: "generic") { values.append($0); delivered.fulfill() }
        delivery.start(waitForDeadline: { await fetch.waitUntilStarted() }, fetch: { await fetch.run() })
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(values.snapshot, ["generic"])
        await fetch.release()
        await fetch.waitUntilReturned()
        delivery.finish("late")
        XCTAssertEqual(values.snapshot, ["generic"])
    }
    func testFetchFailureFallsBack() async {
        let delivered = expectation(description: "failure fallback")
        let delivery = PushDelivery(fallback: "generic") { XCTAssertEqual($0, "generic"); delivered.fulfill() }
        delivery.start(waitForDeadline: { try await Task.sleep(nanoseconds: 60_000_000_000) }, fetch: { throw Failure.fake })
        await fulfillment(of: [delivered], timeout: 2)
    }
    func testAsyncSuccessCancelsDeadline() async {
        let delivered = expectation(description: "rich result")
        let cancelled = expectation(description: "deadline cancelled")
        let delivery = PushDelivery(fallback: "generic") { XCTAssertEqual($0, "rich"); delivered.fulfill() }
        delivery.start(waitForDeadline: {
            do { try await Task.sleep(nanoseconds: 60_000_000_000) }
            catch { cancelled.fulfill(); throw error }
        }, fetch: { "rich" })
        await fulfillment(of: [delivered, cancelled], timeout: 2)
    }
    private enum Failure: Error { case fake }
    private final class Values: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func append(_ value: String) { lock.withLock { values.append(value) } }
        var snapshot: [String] { lock.withLock { values } }
        var count: Int { snapshot.count }
    }
    private actor SuspendedFetch {
        private var continuation: CheckedContinuation<String, Never>?
        private var started = false
        private var returned = false
        func run() async -> String {
            let value = await withCheckedContinuation { continuation in self.continuation = continuation; started = true }
            returned = true
            return value
        }
        func waitUntilStarted() async { while !started { await Task.yield() } }
        func waitUntilReturned() async { while !returned { await Task.yield() } }
        func release() { continuation?.resume(returning: "rich"); continuation = nil }
    }
}
