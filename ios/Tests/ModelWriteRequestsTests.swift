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

@MainActor
final class ManagedModelPickerStateTests: XCTestCase {
    private struct Snapshot: Equatable, Sendable {
        let revision: Int64
        let model: String
    }

    private let before = Snapshot(revision: 7, model: "nguyet-thuc")
    private let after = Snapshot(revision: 8, model: "nhat-thuc")
    private let requestID = ModelWriteRequests<NativeID>.freshID()

    func testReadStartedBeforeAWriteReturnsTheAdoptedSnapshot() async throws {
        let state = ManagedModelPickerState<Snapshot>(revision: \.revision)
        let (started, notice) = AsyncStream<Void>.makeStream()
        var finish: CheckedContinuation<Snapshot, Never>?
        let pending = Task {
            try await state.read(isCurrent: { true }) {
                await withCheckedContinuation { completion in
                    finish = completion
                    notice.yield(())
                    notice.finish()
                }
            }
        }
        _ = await started.first(where: { _ in true })

        let result = await state.save(from: before, choice: .offer(model: "nhat-thuc", effort: .high),
                                         requestID: requestID,
                                      refreshAfterSecondConflict: false, isCurrent: { true }, fetch: { before }) { _, _ in after }
        guard case .saved = result else { return XCTFail("Expected a save") }
        // A pre-write read can report the same revision and still hold old policy or choice.
        finish?.resume(returning: Snapshot(revision: 8, model: before.model))
        let late = try await pending.value
        XCTAssertEqual(late, after)
        let older = try await state.read(isCurrent: { true }) { before }
        XCTAssertEqual(older, after)
    }

    func testNewerReadDuringAWriteWinsOverTheReceipt() async throws {
        let state = ManagedModelPickerState<Snapshot>(revision: \.revision)
        let (writing, writeNotice) = AsyncStream<Void>.makeStream()
        let (reading, readNotice) = AsyncStream<Void>.makeStream()
        var writeReply: CheckedContinuation<Snapshot, Never>?
        var readReply: CheckedContinuation<Snapshot, Never>?
        let write = Task {
            await state.save(from: before, choice: .offer(model: after.model, effort: .high),
                             requestID: requestID, refreshAfterSecondConflict: false,
                             isCurrent: { true }, fetch: { before }) { _, _ in
                await withCheckedContinuation {
                    writeReply = $0
                    writeNotice.yield(())
                    writeNotice.finish()
                }
            }
        }
        _ = await writing.first(where: { _ in true })
        let read = Task {
            try await state.read(isCurrent: { true }) {
                await withCheckedContinuation {
                    readReply = $0
                    readNotice.yield(())
                    readNotice.finish()
                }
            }
        }
        _ = await reading.first(where: { _ in true })

        writeReply?.resume(returning: after)
        guard case .saved = await write.value else { return XCTFail("Expected the write receipt") }
        XCTAssertEqual(state.snapshot, after)
        let newer = Snapshot(revision: after.revision + 1, model: before.model)
        readReply?.resume(returning: newer)
        let latest = try await read.value
        XCTAssertEqual(latest, newer)
        XCTAssertEqual(state.snapshot, newer)
    }

    func testObsoleteIntentCannotRetryAfterAnotherPickDuringItsRead() async throws {
        let state = ManagedModelPickerState<Snapshot>(revision: \.revision)
        let (started, notice) = AsyncStream<Void>.makeStream()
        var finish: CheckedContinuation<Snapshot, Never>?
        var olderWrites = 0
        let pending = Task {
            await state.save(from: before, choice: .offer(model: "nhat-thuc", effort: .high),
                                         requestID: requestID,
                             refreshAfterSecondConflict: true, isCurrent: { true }, fetch: {
                await withCheckedContinuation { completion in
                    finish = completion
                    notice.yield(())
                    notice.finish()
                }
            }) { _, _ in
                olderWrites += 1
                throw ManagedModelFenceConflict.revision
            }
        }
        _ = await started.first(where: { _ in true })
        _ = await state.save(from: before, choice: .offer(model: "nhat-thuc", effort: .high),
                                         requestID: ModelWriteRequests<NativeID>.freshID(),
                             refreshAfterSecondConflict: true, isCurrent: { true }, fetch: { before }) { _, _ in after }
        finish?.resume(returning: before)
        guard case .failed = await pending.value else { return XCTFail("The older pick was superseded") }
        XCTAssertEqual(olderWrites, 1)
        let held = try await state.read(isCurrent: { true }) { before }
        XCTAssertEqual(held, after)
    }

    func testExplicitRetryReplaysTheRefencedWriteAfterTransportFailure() async throws {
        let state = ManagedModelPickerState<Snapshot>(revision: \.revision)
        let choice = ManagedModelPickerChoice.offer(model: "nhat-thuc", effort: .high)
        var writes: [(Snapshot, NativeID)] = []
        let failed = await state.save(from: before, choice: choice, requestID: requestID,
                                      refreshAfterSecondConflict: true, isCurrent: { true }, fetch: { after }) { fence, id in
            writes.append((fence, id))
            if writes.count == 1 { throw ManagedModelFenceConflict.policy }
            throw NativeDomainClientFailure.transportUnavailable
        }
        guard case .failed = failed else { return XCTFail("Expected the lost transport response") }
        XCTAssertEqual(writes.map { $0.0 }, [before, after])
        let actualID = try XCTUnwrap(writes.last?.1)
        XCTAssertNotEqual(actualID, requestID)

        let latest = Snapshot(revision: 9, model: "nhat-thuc")
        _ = try await state.read(isCurrent: { true }) { latest }
        let result = await state.save(from: latest, choice: choice, requestID: ModelWriteRequests<NativeID>.freshID(),
                                      refreshAfterSecondConflict: true, isCurrent: { true }, fetch: { latest }) { fence, id in
            XCTAssertEqual(fence, after)
            XCTAssertEqual(id, actualID)
            return latest
        }
        guard case let .saved(saved) = result else { return XCTFail("Expected the original write's receipt") }
        XCTAssertEqual(saved, latest)
    }

    func testOtherConflictsDoNotReadOrRetry() async throws {
        let state = ManagedModelPickerState<Snapshot>(revision: \.revision)
        let body = Data(#"{"error":"matrix_409","details":{"reason":"model_unavailable"}}"#.utf8)
        let refusal = try NativeHTTPFailure(status: 409, headers: [:], body: body)
        var writes = 0
        let result = await state.save(from: before, choice: .offer(model: "nhat-thuc", effort: .high),
                                         requestID: requestID,
                                      refreshAfterSecondConflict: true, isCurrent: { true }, fetch: {
            XCTFail("Only a fence conflict can re-read")
            return after
        }) { _, _ in
            writes += 1
            throw NativeDomainClientFailure.http(refusal)
        }
        guard case .refused(nil) = result else { return XCTFail("Expected the original refusal") }
        XCTAssertEqual(writes, 1)
    }
}
