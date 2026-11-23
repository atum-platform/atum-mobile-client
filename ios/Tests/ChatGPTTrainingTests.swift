import Foundation
import XCTest
@testable import AtumNativeAPI

/// The training-off projection is read as strictly as the desktop reads it
/// (`parseMatrixChatGptTraining`): only this build's wording is current, and
/// an answer outside the contract is unreadable, never a confirmation.
final class ChatGPTTrainingTests: XCTestCase {
    private let connection = "00000000-0000-4000-8000-0000000000c1"

    private func decode(_ object: [String: Any]) throws -> ChatGPTTrainingStatus {
        try ChatGPTTrainingStatus.decode(JSONSerialization.data(withJSONObject: object))
    }

    func testOnlyTheV1WordingIsCurrent() throws {
        let confirmed = try decode(["current": true, "wordingVersion": "chatgpt-google-v1",
                                    "connectionId": connection, "confirmedAt": "2026-11-20T08:00:00Z",
                                    "revision": 3])
        XCTAssertTrue(confirmed.current)
        XCTAssertEqual(confirmed.connectionID, connection)
        XCTAssertEqual(confirmed.confirmedAt, ISO8601DateFormatter().date(from: "2026-11-20T08:00:00Z"))

        let later = try decode(["current": true, "wordingVersion": "chatgpt-google-v2",
                                "connectionId": connection, "confirmedAt": "2026-11-20T08:00:00Z",
                                "revision": 4])
        XCTAssertFalse(later.current, "another wording is not what this build showed")
        XCTAssertNil(later.confirmedAt)

        let absent = try decode(["current": false, "wordingVersion": NSNull(), "connectionId": NSNull(),
                                 "confirmedAt": NSNull(), "revision": NSNull()])
        XCTAssertEqual(absent, ChatGPTTrainingStatus(current: false, connectionID: nil, confirmedAt: nil))
        XCTAssertEqual(confirmed.consent, ChatGPTTrainingConsent(connectionID: connection, revision: 3))
        XCTAssertNil(later.consent)
    }

    /// r1 finding 2: a malformed 200 never opens the gate. `current: true`
    /// counts only with its connection, time and revision all present.
    func testACurrentAnswerMissingAnyPartOfItsRecordIsNotConfirmed() throws {
        let complete: [String: Any] = ["current": true, "wordingVersion": "chatgpt-google-v1",
                                       "connectionId": connection, "confirmedAt": "2026-11-20T08:00:00Z",
                                       "revision": 3]
        for field in ["connectionId", "confirmedAt", "revision"] {
            var absent = complete
            absent.removeValue(forKey: field)
            var null = complete
            null[field] = NSNull()
            for object in [absent, null] {
                let status = try decode(object)
                XCTAssertFalse(status.current, "current without \(field)")
                XCTAssertNil(status.consent, "no decision without \(field)")
            }
        }
        // The type itself never holds an incomplete current record.
        XCTAssertFalse(ChatGPTTrainingStatus(current: true, connectionID: connection, confirmedAt: Date()).current)
        XCTAssertFalse(ChatGPTTrainingStatus(current: true, connectionID: "relay-1", confirmedAt: Date(),
                                             revision: 1).current)
    }

    func testAnAnswerOutsideTheContractIsUnreadable() {
        let bad: [[String: Any]] = [
            [:],
            ["current": "true"],
            ["current": 1],
            ["current": true, "wordingVersion": 1],
            ["current": false, "connectionId": "relay-1"],
            ["current": true, "wordingVersion": "chatgpt-google-v1", "confirmedAt": "yesterday"],
            ["current": true, "wordingVersion": "chatgpt-google-v1", "revision": -1],
            ["current": true, "wordingVersion": "chatgpt-google-v1", "revision": 1.5],
            ["current": true, "wordingVersion": "chatgpt-google-v1", "revision": true],
        ]
        for object in bad {
            XCTAssertThrowsError(try decode(object), "\(object)")
        }
        XCTAssertThrowsError(try ChatGPTTrainingStatus.decode(Data("[]".utf8)))
    }

    func testTheConfirmationBodyIsTheExactThreeFields() throws {
        let data = try JSONEncoder().encode(ChatGPTTrainingConfirmRequest(connectionID: connection))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object, ["wordingVersion": "chatgpt-google-v1", "connectionId": connection,
                                "transferWordingVersion": "chatgpt-google-transfer-v1"])
    }
}

/// r1 findings 1, 3 and 4: the consent decision a ChatGPT write carries, the
/// card's press, and the picker's selection and load lifetime.
@MainActor
final class ChatGPTTrainingConsentTests: XCTestCase {
    private let connection = "00000000-0000-4000-8000-0000000000c1"
    private let replaced = "00000000-0000-4000-8000-0000000000c2"
    private let at = Date(timeIntervalSince1970: 1_795_000_000)

    private func status(_ current: Bool, _ connection: String?, revision: Int64? = 3) -> ChatGPTTrainingStatus {
        ChatGPTTrainingStatus(current: current, connectionID: connection, confirmedAt: current ? at : nil,
                              revision: revision)
    }

    func testTheRecheckHoldsOnlyForTheSameConnectionAndRevision() async {
        let consent = ChatGPTTrainingConsent(connectionID: connection, revision: 3)
        var answer: ChatGPTTrainingStatus? = status(true, connection)
        let check = ChatGPTTrainingRecheck(consent: consent) { answer }
        let same = await check.stillCurrent()
        XCTAssertTrue(same)

        answer = status(false, connection, revision: nil)
        let revoked = await check.stillCurrent()
        XCTAssertFalse(revoked, "a revoked confirmation is never reused")
        XCTAssertEqual(check.latest, answer)

        answer = status(true, connection, revision: 4)
        let reconfirmed = await check.stillCurrent()
        XCTAssertFalse(reconfirmed, "another confirmation is another decision")

        answer = status(true, replaced)
        let relay = await check.stillCurrent()
        XCTAssertFalse(relay, "a replaced relay connection is another decision")

        answer = nil
        let unread = await check.stillCurrent()
        XCTAssertFalse(unread, "an unread status is never the old decision")
    }

    /// A revision conflict re-reads consent before the automatic retry; a
    /// revoked consent returns to the gate and is never written again.
    func testARevisionConflictWithRevokedConsentReturnsToTheGateWithoutRetrying() async {
        struct Snapshot: Equatable, Sendable { let revision: Int64 }
        let state = ManagedModelPickerState<Snapshot>(revision: \.revision)
        let check = ChatGPTTrainingRecheck(consent: ChatGPTTrainingConsent(connectionID: connection, revision: 3)) {
            self.status(false, self.connection, revision: nil)
        }
        var writes = 0
        let result = await state.save(
            from: Snapshot(revision: 7), choice: .subscription(.chatGPTPlan, model: "gpt-6.1", effort: .medium),
            requestID: ModelWriteRequests<NativeID>.freshID(), refreshAfterSecondConflict: true,
            isCurrent: { true }, fetch: { Snapshot(revision: 8) }, revalidate: { await check.stillCurrent() }
        ) { _, _ in
            writes += 1
            throw ManagedModelFenceConflict.revision
        }
        guard case let .preconditionChanged(latest) = result else { return XCTFail("expected the gate, got \(result)") }
        XCTAssertEqual(latest, Snapshot(revision: 8))
        XCTAssertEqual(writes, 1, "the old decision is never retried")
        XCTAssertEqual(check.latest?.current, false, "the picker asks again with the fresh status")
    }

    func testARevisionConflictWithTheSameConsentRetriesOnce() async {
        struct Snapshot: Equatable, Sendable { let revision: Int64 }
        let state = ManagedModelPickerState<Snapshot>(revision: \.revision)
        var checks = 0
        var fences: [Int64] = []
        let result = await state.save(
            from: Snapshot(revision: 7), choice: .subscription(.chatGPTPlan, model: "gpt-6.1", effort: .medium),
            requestID: ModelWriteRequests<NativeID>.freshID(), refreshAfterSecondConflict: true,
            isCurrent: { true }, fetch: { Snapshot(revision: 8) },
            revalidate: { checks += 1; return true }
        ) { fence, _ in
            fences.append(fence.revision)
            if fences.count == 1 { throw ManagedModelFenceConflict.revision }
            return Snapshot(revision: 9)
        }
        guard case .saved(Snapshot(revision: 9)) = result else { return XCTFail("expected the retry to land") }
        XCTAssertEqual(fences, [7, 8])
        XCTAssertEqual(checks, 1)
    }

    /// Any refusal of a ChatGPT write (the relay or its consent changing
    /// under it) re-reads consent; a changed one returns to the gate.
    func testARefusalRechecksConsent() async throws {
        struct Snapshot: Equatable, Sendable { let revision: Int64 }
        let body = Data(#"{"error":"matrix_409","details":{"reason":"not_connected"}}"#.utf8)
        let refusal = try NativeHTTPFailure(status: 409, headers: [:], body: body)
        for holds in [false, true] {
            let state = ManagedModelPickerState<Snapshot>(revision: \.revision)
            var checks = 0
            let result = await state.save(
                from: Snapshot(revision: 7), choice: .subscription(.chatGPTPlan, model: "gpt-6.1", effort: .medium),
                requestID: ModelWriteRequests<NativeID>.freshID(), refreshAfterSecondConflict: true,
                isCurrent: { true }, fetch: { Snapshot(revision: 7) },
                revalidate: { checks += 1; return holds }
            ) { _, _ in throw NativeDomainClientFailure.http(refusal) }
            XCTAssertEqual(checks, 1)
            switch (holds, result) {
            case (false, .preconditionChanged(nil)), (true, .refused(nil)): break
            default: XCTFail("holds \(holds): \(result)")
            }
        }
    }

    func testAPressConfirmsOnlyForTheConnectionItNamed() async {
        var posted: [String] = []
        let other = await ChatGPTTrainingPress.confirm(connectionID: connection, read: { nil }) { id in
            posted.append(id)
            return .confirmed(self.status(true, self.replaced))
        }
        XCTAssertEqual(other, .failed(connectionID: connection), "a confirmation for another relay is not this one")

        let landed = await ChatGPTTrainingPress.confirm(connectionID: connection, read: { nil }) { id in
            posted.append(id)
            return .confirmed(self.status(true, id))
        }
        XCTAssertEqual(landed, .confirmed(status(true, connection)))
        XCTAssertEqual(posted, [connection, connection])
    }

    /// After a 409 whose refresh failed the card holds no connection; the
    /// next press reads the status first and only then confirms.
    func testAPressWithoutAConnectionReadsBeforeItConfirms() async {
        var calls: [String] = []
        let fresh = await ChatGPTTrainingPress.confirm(connectionID: nil, read: {
            calls.append("GET")
            return self.status(false, self.replaced, revision: nil)
        }) { id in
            calls.append("POST " + id)
            return .confirmed(self.status(true, id))
        }
        XCTAssertEqual(fresh, .confirmed(status(true, replaced)))
        XCTAssertEqual(calls, ["GET", "POST " + replaced])

        calls = []
        let unread = await ChatGPTTrainingPress.confirm(connectionID: nil, read: {
            calls.append("GET")
            return nil
        }) { id in
            calls.append("POST " + id)
            return .unavailable
        }
        XCTAssertEqual(unread, .failed(connectionID: nil))
        XCTAssertEqual(calls, ["GET"], "nothing is confirmed without a connection")

        // A 409 reads again; an unreadable refresh asks again with no connection.
        let stale = await ChatGPTTrainingPress.confirm(connectionID: connection, read: { nil }) { _ in .stale }
        XCTAssertEqual(stale, .askAgain(connectionID: nil))
    }

    func testDismissalDuringTheRecoveryGetStopsTheConfirmationPost() async {
        var lifetime = ModelPickerLifetime()
        let selection = lifetime.beginSelection()
        var reads = 0
        var posts = 0
        let conflict = await ChatGPTTrainingPress.confirm(connectionID: connection, read: { nil }) { _ in
            .stale
        }
        guard case let .askAgain(connectionID) = conflict else { return XCTFail("expected an unread refresh") }
        XCTAssertNil(connectionID)

        let result = await ChatGPTTrainingPress.confirm(
            connectionID: connectionID, isCurrent: { lifetime.isCurrent(selection) },
            read: {
                reads += 1
                await Task.yield()
                lifetime.retire()
                return self.status(false, self.replaced, revision: nil)
            }
        ) { _ in
            posts += 1
            return .unavailable
        }
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(posts, 0)
    }

    func testDismissalDuringTheConflictReadbackStopsTheSecondPut() async {
        await assertDismissalStopsTheSecondPut(duringReadback: true)
    }

    func testDismissalDuringTheConsentRecheckStopsTheSecondPut() async {
        await assertDismissalStopsTheSecondPut(duringReadback: false)
    }

    private func assertDismissalStopsTheSecondPut(duringReadback: Bool) async {
        struct Snapshot: Equatable, Sendable { let revision: Int64 }
        var lifetime = ModelPickerLifetime()
        let selection = lifetime.beginSelection()
        let state = ManagedModelPickerState<Snapshot>(revision: \.revision)
        var writes = 0
        var reads = 0
        var checks = 0
        let check = ChatGPTTrainingRecheck(consent: ChatGPTTrainingConsent(connectionID: connection, revision: 3)) {
            checks += 1
            if !duringReadback {
                await Task.yield()
                lifetime.retire()
            }
            return self.status(true, self.connection)
        }
        let result = await state.save(
            from: Snapshot(revision: 7), choice: .subscription(.chatGPTPlan, model: "gpt-6.1", effort: .medium),
            requestID: ModelWriteRequests<NativeID>.freshID(), refreshAfterSecondConflict: true,
            isCurrent: { true }, fetch: {
                reads += 1
                if duringReadback {
                    await Task.yield()
                    lifetime.retire()
                }
                return Snapshot(revision: 8)
            },
            isSelectionCurrent: { lifetime.isCurrent(selection) }, revalidate: { await check.stillCurrent() }
        ) { _, _ in
            writes += 1
            throw ManagedModelFenceConflict.revision
        }
        guard case .cancelled = result else { return XCTFail("expected cancellation, got \(result)") }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(checks, duringReadback ? 0 : 1)
    }

    func testFenceRefusalsRecheckConsentWhenReadbackFailsOrTheRetryConflicts() async {
        struct Snapshot: Equatable, Sendable { let revision: Int64 }
        for readbackFails in [true, false] {
            let state = ManagedModelPickerState<Snapshot>(revision: \.revision)
            var writes = 0
            var checks = 0
            let result = await state.save(
                from: Snapshot(revision: 7), choice: .subscription(.chatGPTPlan, model: "gpt-6.1", effort: .medium),
                requestID: ModelWriteRequests<NativeID>.freshID(), refreshAfterSecondConflict: true,
                isCurrent: { true }, fetch: {
                    if readbackFails { throw NativeDomainClientFailure.transportUnavailable }
                    return Snapshot(revision: 7 + Int64(writes))
                },
                revalidate: {
                    checks += 1
                    return !readbackFails && checks == 1
                }
            ) { _, _ in
                writes += 1
                throw ManagedModelFenceConflict.revision
            }
            guard case let .preconditionChanged(latest) = result else {
                return XCTFail("expected the gate, got \(result)")
            }
            XCTAssertEqual(latest, readbackFails ? nil : Snapshot(revision: 9))
            XCTAssertEqual(writes, readbackFails ? 1 : 2)
            XCTAssertEqual(checks, writes)
        }
    }

    /// r1 finding 3: closing the picker retires the pending selection, so a
    /// late consent read can never start the write.
    func testDismissalAndANewerPickRetireAPendingSelection() {
        var lifetime = ModelPickerLifetime()
        let pick = lifetime.beginSelection()
        XCTAssertTrue(lifetime.isCurrent(pick))
        lifetime.retire()
        XCTAssertFalse(lifetime.isCurrent(pick), "a closed picker's pick is stale")

        let first = lifetime.beginSelection()
        let second = lifetime.beginSelection()
        XCTAssertFalse(lifetime.isCurrent(first))
        XCTAssertTrue(lifetime.isCurrent(second))
    }

    /// r1 finding 4: an interrupted load always ends, so the next is never refused.
    func testAnInterruptedLoadNeverStallsTheNext() {
        var lifetime = ModelPickerLifetime()
        let load = try! XCTUnwrap(lifetime.beginLoad())
        XCTAssertTrue(lifetime.loading)
        XCTAssertNil(lifetime.beginLoad(), "one load at a time")
        lifetime.endLoad(load)
        XCTAssertFalse(lifetime.loading)

        let interrupted = try! XCTUnwrap(lifetime.beginLoad())
        lifetime.retire()
        XCTAssertFalse(lifetime.loading, "closing ends every load")
        XCTAssertFalse(lifetime.isCurrentLoad(interrupted))
        let next = try! XCTUnwrap(lifetime.beginLoad())
        // The interrupted load ending late never clears the newer one.
        lifetime.endLoad(interrupted)
        XCTAssertTrue(lifetime.loading)
        XCTAssertTrue(lifetime.isCurrentLoad(next))
        lifetime.endLoad(next)
        XCTAssertNotNil(lifetime.beginLoad())
    }
}
