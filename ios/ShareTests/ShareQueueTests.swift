import XCTest
import AtumNativeAPI

@MainActor
final class ShareQueueTests: XCTestCase {
    private func fixture() throws -> (ShareQueue, ShareAccount, ShareJob) {
        let queue = ShareQueue(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let account = ShareAccount(userID: "@owner:example.com", generation: UUID())
        try queue.publish(ShareDirectory(account: account, chats: [
            ShareChat(id: "!one:example.com", name: "One", isGroup: false, recipients: ["@one:example.com"]),
            ShareChat(id: "!two:example.com", name: "Two", isGroup: true, recipients: ["@two:example.com"])
        ]))
        let id = try queue.begin()
        let job = ShareJob(id: id, account: account, items: [ShareItem(kind: .text, text: "Hello")],
                           caption: "Caption", rooms: ["!one:example.com", "!two:example.com"])
        addTeardownBlock { try? FileManager.default.removeItem(at: queue.root) }
        return (queue, account, job)
    }
    func testCommitRoundTripAndMultipleRecipients() throws {
        let (queue, account, job) = try fixture()
        try queue.commit(job) { account }
        XCTAssertEqual(try queue.jobs(account: account), [job])
        XCTAssertEqual(job.deliveries.count, 2)
    }
    func testUncommittedJobIsInvisible() throws {
        let (queue, account, _) = try fixture()
        XCTAssertEqual(try queue.jobs(account: account), [])
    }
    func testDifferentGenerationCannotDrain() throws {
        let (queue, account, job) = try fixture(); try queue.commit(job) { account }
        XCTAssertTrue(try queue.jobs(account: ShareAccount(userID: account.userID, generation: UUID())).isEmpty)
    }
    func testChangedAccountCannotCommit() throws {
        let (queue, _, job) = try fixture()
        XCTAssertThrowsError(try queue.commit(job) { ShareAccount(userID: "@other:example.com", generation: UUID()) })
    }
    func testRemovedRecipientCannotCommit() throws {
        let (queue, account, job) = try fixture()
        try queue.publish(ShareDirectory(account: account, chats: []))
        XCTAssertThrowsError(try queue.commit(job) { account })
    }
    func testCannotCommitTwice() throws {
        let (queue, account, job) = try fixture(); try queue.commit(job) { account }
        XCTAssertThrowsError(try queue.commit(job) { account })
    }
    func testClearRemovesDirectoryAndJobs() throws {
        let (queue, account, job) = try fixture(); try queue.commit(job) { account }; try queue.clear()
        XCTAssertNil(try queue.readDirectory()); XCTAssertTrue(try queue.jobs(account: account).isEmpty)
    }
    func testCopiedFileSurvivesProviderRemoval() throws {
        let (queue, account, job) = try fixture()
        let source = queue.root.appendingPathComponent("input.pdf"); try Data("bytes".utf8).write(to: source)
        let item = try queue.copyFile(source, jobID: job.id, kind: .file, type: "com.adobe.pdf", name: "report.pdf")
        try FileManager.default.removeItem(at: source)
        let file = try queue.fileURL(item, jobID: job.id)
        XCTAssertEqual(try Data(contentsOf: file), Data("bytes".utf8))
        let fileJob = ShareJob(id: job.id, account: account, items: [item], caption: "", rooms: ["!one:example.com"])
        try queue.commit(fileJob) { account }
        XCTAssertEqual(try queue.jobs(account: account).first?.items, [item])
    }
    func testOversizeAndDirectoryRefused() throws {
        let (queue, _, job) = try fixture()
        let source = queue.root.appendingPathComponent("large")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(ShareQueue.maximumItemBytes + 1)); try handle.close()
        XCTAssertThrowsError(try queue.copyFile(source, jobID: job.id, kind: .video, type: nil, name: nil))
        XCTAssertThrowsError(try queue.copyFile(queue.root, jobID: job.id, kind: .file, type: nil, name: nil))
    }
    func testPathTraversalRefused() throws {
        let (queue, account, job) = try fixture()
        let invalid = ShareJob(id: job.id, account: account, items: [ShareItem(kind: .file, file: "../secret")],
                               caption: "", rooms: ["!one:example.com"])
        XCTAssertThrowsError(try queue.commit(invalid) { account })
    }
    func testSuccessfulDrainRemovesOnlyAfterAllDestinations() async throws {
        let (queue, account, job) = try fixture(); try queue.commit(job) { account }
        var sent = [String]()
        let result = try await ShareQueueDrainer().drain(queue: queue, account: account, prepare: { _, _ in }, send: { _, delivery in
            XCTAssertEqual(try queue.jobs(account: account).first?.deliveries.filter { $0.state == .handingOff }.count, 1)
            sent.append(delivery.roomID)
        })
        XCTAssertEqual(result, .complete); XCTAssertEqual(sent.count, 2)
        XCTAssertTrue(try queue.jobs(account: account).isEmpty)
    }
    func testPreparationFailureRemainsPending() async throws {
        let (queue, account, job) = try fixture(); try queue.commit(job) { account }
        let result = try await ShareQueueDrainer().drain(queue: queue, account: account, prepare: { _, _ in
            throw ShareQueueFailure.unavailable
        }, send: { _, _ in XCTFail("Must not send") })
        XCTAssertEqual(result, .retryLater)
        XCTAssertTrue(try queue.jobs(account: account)[0].deliveries.allSatisfy { $0.state == .pending })
    }
    func testUncertainSendNeverAutomaticallyReplayed() async throws {
        let (queue, account, job) = try fixture(); try queue.commit(job) { account }
        let drainer = ShareQueueDrainer()
        let first = try await drainer.drain(queue: queue, account: account, prepare: { _, _ in }, send: { _, _ in throw ShareQueueFailure.unavailable })
        XCTAssertEqual(first, .needsReview)
        let second = try await drainer.drain(queue: queue, account: account, prepare: { _, _ in XCTFail() }, send: { _, _ in XCTFail() })
        XCTAssertEqual(second, .needsReview)
    }
    func testCrashHandoffResumesOtherItemsWithoutReplayingAccepted() async throws {
        let (queue, account, initial) = try fixture()
        var job = initial; job.deliveries[0].state = .accepted; job.deliveries[1].state = .handingOff
        try queue.commit(job) { account }
        let drainer = ShareQueueDrainer()
        try drainer.retryUncertain(queue: queue, account: account)
        var sent = [String]()
        let result = try await drainer.drain(queue: queue, account: account, prepare: { _, _ in }, send: { _, target in sent.append(target.roomID) })
        XCTAssertEqual(result, .complete); XCTAssertEqual(sent, ["!two:example.com"])
    }
    func testDiscardIsAccountScoped() throws {
        let (queue, account, job) = try fixture(); try queue.commit(job) { account }
        try ShareQueueDrainer().discard(queue: queue, account: ShareAccount(userID: account.userID, generation: UUID()))
        XCTAssertEqual(try queue.jobs(account: account).count, 1)
        try ShareQueueDrainer().discard(queue: queue, account: account)
        XCTAssertTrue(try queue.jobs(account: account).isEmpty)
    }
    func testMissingFileDoesNotPreventDiscard() throws {
        let (queue, account, initial) = try fixture()
        let source = queue.root.appendingPathComponent("input"); try Data("file".utf8).write(to: source)
        let item = try queue.copyFile(source, jobID: initial.id, kind: .file, type: nil, name: nil)
        let job = ShareJob(id: initial.id, account: account, items: [item], caption: "", rooms: ["!one:example.com"])
        try queue.commit(job) { account }
        try FileManager.default.removeItem(at: queue.fileURL(item, jobID: job.id))
        XCTAssertEqual(try queue.jobs(account: account).count, 1)
        try ShareQueueDrainer().discard(queue: queue, account: account)
        XCTAssertTrue(try queue.jobs(account: account).isEmpty)
    }
    func testTextAndCaptionBounds() throws {
        let (queue, account, job) = try fixture()
        let invalid = ShareJob(id: job.id, account: account, items: [ShareItem(kind: .text, text: String(repeating: "x", count: ShareQueue.maximumTextBytes + 1))], caption: "", rooms: ["!one:example.com"])
        XCTAssertThrowsError(try queue.commit(invalid) { account })
    }
}
