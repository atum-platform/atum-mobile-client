import XCTest
@testable import AtumChat

/// The hotfix's per-room send-queue rules above the source seam (B8, B9):
/// a disabled queue is woken before a send, after a parked retry and after
/// "Xóa"; "Thử lại" follows the failure kind. A recording source stands in
/// for the SDK's room queue.
final class SendQueueRulesTests: XCTestCase {
    /// Records the SDK calls in order and models one room queue's enabled
    /// flag the way the SDK does: only `enableSendQueue` turns it on.
    final class RecordingSource: ChatTimelineSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = [String]()
        private var _queueEnabled: Bool
        let outputs: AsyncStream<ChatTimelineOutput>

        init(queueEnabled: Bool) {
            _queueEnabled = queueEnabled
            outputs = AsyncStream { $0.finish() }
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var calls: [String] { locked { _calls } }
        var queueEnabled: Bool { locked { _queueEnabled } }

        private func record(_ call: String) { locked { _calls.append(call) } }

        func start() async {}
        func stop() async {}
        func send(text: String, replyTo eventID: String?) async throws {
            record(eventID.map { "sendReply(\(text),\($0))" } ?? "send(\(text))")
        }
        func send(attachment: OutgoingChatAttachment, caption: String?, replyTo eventID: String?) async throws {
            record("sendAttachment(\(attachment.filename),\(caption ?? "nil"),\(eventID ?? "nil"))")
        }
        func edit(_ item: ChatEventRef, text: String) async throws { record("edit") }
        func redact(_ item: ChatEventRef) async throws { record("redact") }
        func toggleReaction(_ item: ChatEventRef, key: String) async throws { record("react") }
        func isSendQueueEnabled() async -> Bool { queueEnabled }
        func enableSendQueue() async {
            record("enableSendQueue")
            locked { _queueEnabled = true }
        }
        func retrySend(_ item: ChatEventRef) async throws { record("retrySend(\(item))") }
        func abortSend(_ item: ChatEventRef) async throws { record("abortSend(\(item))") }
        func paginateBackwards(numEvents: UInt16) async throws -> Bool { false }
        func sendReceipt(_ receipt: ChatReceipt) async throws {}
        func fetchReplyDetails(eventID: String) async {}
    }

    /// Collects the wake-ups the rules report for the log line.
    final class Wakes: @unchecked Sendable {
        private let lock = NSLock()
        private var values = [SendQueueRules.Wake]()
        var all: [SendQueueRules.Wake] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
        func add(_ wake: SendQueueRules.Wake) {
            lock.lock()
            defer { lock.unlock() }
            values.append(wake)
        }
    }

    func testASendWakesADisabledQueueFirstSoTheEarlierMessageGoesOutBeforeIt() async throws {
        let source = RecordingSource(queueEnabled: false)
        let wakes = Wakes()
        try await SendQueueRules.send(text: "hai", replyTo: nil, on: source, woke: { wakes.add($0) })
        XCTAssertEqual(source.calls, ["enableSendQueue", "send(hai)"])
        XCTAssertEqual(wakes.all, [.beforeSend])
    }

    func testASendOnAnEnabledQueueTouchesNothingElse() async throws {
        let source = RecordingSource(queueEnabled: true)
        let wakes = Wakes()
        try await SendQueueRules.send(text: "hai", replyTo: "$q", on: source, woke: { wakes.add($0) })
        XCTAssertEqual(source.calls, ["sendReply(hai,$q)"])
        XCTAssertEqual(wakes.all, [])
    }

    func testAttachmentSendUsesTheSameOrderedQueueWakeBoundary() async throws {
        let source = RecordingSource(queueEnabled: false)
        let attachment = OutgoingChatAttachment(id: "a", kind: .file,
                                                filePath: "/tmp/a.pdf", filename: "a.pdf",
                                                mimetype: "application/pdf", byteSize: 4)
        try await SendQueueRules.send(attachment: attachment, caption: "ghi chú",
                                      replyTo: "$q", on: source)
        XCTAssertEqual(source.calls,
                       ["enableSendQueue", "sendAttachment(a.pdf,ghi chú,$q)"])
    }

    func testRetryFollowsTheFailureKind() async throws {
        let recoverable = RecordingSource(queueEnabled: false)
        try await SendQueueRules.repair(.enableRoomQueue, on: recoverable)
        XCTAssertEqual(recoverable.calls, ["enableSendQueue"], "the queue resends in order, this message first")

        let parkedEnabled = RecordingSource(queueEnabled: true)
        try await SendQueueRules.repair(.retryParkedRequest(.transaction("t1")), on: parkedEnabled)
        XCTAssertEqual(parkedEnabled.calls, ["retrySend(transaction(\"t1\"))"])

        let parkedDisabled = RecordingSource(queueEnabled: false)
        let wakes = Wakes()
        try await SendQueueRules.repair(.retryParkedRequest(.transaction("t1")), on: parkedDisabled,
                                        woke: { wakes.add($0) })
        XCTAssertEqual(parkedDisabled.calls, ["retrySend(transaction(\"t1\"))", "enableSendQueue"],
                       "unparking does not wake a queue the SDK disabled")
        XCTAssertEqual(wakes.all, [.retry])
    }

    func testDeleteWakesADisabledQueueSoWhatWaitedBehindItGoesOut() async throws {
        let disabled = RecordingSource(queueEnabled: false)
        let wakes = Wakes()
        try await SendQueueRules.abort(.transaction("t1"), on: disabled, woke: { wakes.add($0) })
        XCTAssertEqual(disabled.calls, ["abortSend(transaction(\"t1\"))", "enableSendQueue"])
        XCTAssertEqual(wakes.all, [.afterAbort])

        let enabled = RecordingSource(queueEnabled: true)
        try await SendQueueRules.abort(.transaction("t2"), on: enabled)
        XCTAssertEqual(enabled.calls, ["abortSend(transaction(\"t2\"))"])
    }

    func testDeliveryRetryFollowsTheFailureKind() {
        // Recoverable → wake the room queue; else retry the parked request by
        // its own ID. The hotfix's `MobileSendRecoveryPolicy.retryAction`
        // (AtumNativeAPI) states the same rule; no test target links both
        // modules, so the two are not cross-checked here (assembly note).
        let recoverable = ChatItem(id: "a", kind: .message, isOwn: true, delivery: .failed(isRecoverable: true),
                                   eventOrTransactionId: .transaction("ta"))
        let parked = ChatItem(id: "b", kind: .message, isOwn: true, delivery: .failed(isRecoverable: false),
                              eventOrTransactionId: .transaction("tb"))
        XCTAssertEqual(Delivery.retry(for: recoverable), .enableRoomQueue)
        XCTAssertEqual(Delivery.retry(for: parked), .retryParkedRequest(.transaction("tb")))
    }
}
