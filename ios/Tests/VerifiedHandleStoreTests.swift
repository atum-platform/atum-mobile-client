import Foundation
import XCTest
@testable import AtumNativeAPI

@MainActor final class VerifiedHandleStoreTests: XCTestCase {
    private let owner = "@owner:example.test"
    private let person = "@person:example.test"
    private let other = "@other:example.test"

    private func response(_ users: [String], handles: [String: String] = [:],
                          revision: Int = 1, legacy: Bool = false) throws -> AliasContactsResponse {
        let contacts: [[String: Any]] = users.map { user in
            var entry: [String: Any] = ["matrixUser": user, "handle": handles[user] as Any? ?? NSNull()]
            if !legacy {
                entry["status"] = handles[user] == nil ? "unknown" : "resolved"
                entry["generation"] = handles[user] == nil ? NSNull() : 1
            }
            return entry
        }
        var object: [String: Any] = ["contacts": contacts]
        if !legacy { object["schemaVersion"] = 2; object["revision"] = revision }
        return try NativeAPI.decode(AliasContactsResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testOwnSuccessIsCachedAndNotifies() async throws {
        let store = VerifiedHandleStore(defaults: nil)
        store.bind(owner: owner)
        var calls = 0
        var changes: [[String: String]] = []
        store.onChange = { changes.append($0) }
        store.setDirectory(current: {
            calls += 1
            return .assigned(handle: try NativeHandle("owner_handle"), generation: 1)
        }, contacts: nil)
        await store.loadOwnHandle()
        await store.loadOwnHandle()
        XCTAssertEqual(store.ownHandle, "owner_handle")
        XCTAssertEqual(store.handle(for: owner), "owner_handle")
        XCTAssertEqual(changes, [[owner: "owner_handle"]])
        XCTAssertEqual(calls, 1)
    }

    func testOwnFailureKeepsEvidenceAndCanRetry() async throws {
        let store = VerifiedHandleStore(defaults: nil)
        store.bind(owner: owner)
        store.remember(userID: owner, handle: "before")
        var calls = 0
        store.setDirectory(current: {
            calls += 1
            if calls == 1 { throw NativeDomainClientFailure.transportUnavailable }
            return .assigned(handle: try NativeHandle("after"), generation: 2)
        }, contacts: nil)
        await store.loadOwnHandle()
        XCTAssertEqual(store.ownHandle, "before")
        await store.loadOwnHandle()
        XCTAssertEqual(store.ownHandle, "after")
        XCTAssertEqual(calls, 2)
    }

    func testOwnNullForgetsCachedValueAndIsCached() async {
        let store = VerifiedHandleStore(defaults: nil)
        store.bind(owner: owner)
        store.remember(userID: owner, handle: "before")
        var calls = 0
        store.setDirectory(current: { calls += 1; return .none }, contacts: nil)
        await store.loadOwnHandle()
        await store.loadOwnHandle()
        XCTAssertNil(store.ownHandle)
        XCTAssertEqual(calls, 1)
    }

    func testConcurrentOwnReadsJoinOneFlight() async throws {
        let store = VerifiedHandleStore(defaults: nil)
        store.bind(owner: owner)
        var resume: CheckedContinuation<AliasCurrentResponse, Never>?
        var calls = 0
        store.setDirectory(current: {
            calls += 1
            return await withCheckedContinuation { resume = $0 }
        }, contacts: nil)
        let first = Task { await store.loadOwnHandle() }
        for _ in 0..<20 where resume == nil { await Task.yield() }
        let second = Task { await store.loadOwnHandle() }
        await Task.yield()
        XCTAssertEqual(calls, 1)
        try XCTUnwrap(resume).resume(returning: .assigned(handle: NativeHandle("owner_handle"), generation: 1))
        await first.value; await second.value
        XCTAssertEqual(store.ownHandle, "owner_handle")
    }

    func testOldOwnReadCannotPublishAfterSignOutAndSameAccountRebind() async throws {
        let store = VerifiedHandleStore(defaults: nil)
        store.bind(owner: owner)
        var resume: CheckedContinuation<AliasCurrentResponse, Never>?
        store.setDirectory(current: { await withCheckedContinuation { resume = $0 } }, contacts: nil)
        let task = Task { await store.loadOwnHandle() }
        for _ in 0..<20 where resume == nil { await Task.yield() }
        store.bind(owner: nil)
        store.bind(owner: owner)
        try XCTUnwrap(resume).resume(returning: .assigned(handle: NativeHandle("stale"), generation: 1))
        await task.value
        XCTAssertNil(store.ownHandle)
    }

    func testPersistenceIsAccountScopedAndExpiresAfterSevenDays() throws {
        let suite = "VerifiedHandleStoreTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var date = Date(timeIntervalSince1970: 10_000)
        let store = VerifiedHandleStore(defaults: defaults, now: { date })
        store.bind(owner: owner)
        store.remember(userID: person, handle: "remembered")
        let restored = VerifiedHandleStore(defaults: defaults, now: { date })
        restored.bind(owner: other)
        XCTAssertNil(restored.handle(for: person))
        restored.bind(owner: owner)
        XCTAssertEqual(restored.handle(for: person), "remembered")
        restored.bind(owner: nil)
        date += 7 * 24 * 60 * 60
        restored.bind(owner: owner)
        XCTAssertNil(restored.handle(for: person))
    }

    func testCorruptPersistenceIsOnlyACacheMiss() throws {
        let suite = "VerifiedHandleStoreTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("broken".utf8), forKey: "atum.matrix.verified-handles.v1:" + owner)
        let store = VerifiedHandleStore(defaults: defaults)
        store.bind(owner: owner)
        XCTAssertTrue(store.knownHandles.isEmpty)
    }

    func testBackfillHitMissAndChangeNotification() async throws {
        let store = VerifiedHandleStore(defaults: nil)
        store.bind(owner: owner)
        var calls = 0
        var changes: [[String: String]] = []
        store.onChange = { changes.append($0) }
        store.setDirectory(current: nil, contacts: { input in
            calls += 1
            return try self.response(input.matrixUsers, handles: [self.person: "found"])
        })
        defer { store.setDirectory(current: nil, contacts: nil) }
        store.requestHandles(for: [person, other, person])
        await store.flush()
        XCTAssertEqual(store.handle(for: person), "found")
        XCTAssertNil(store.handle(for: other))
        XCTAssertEqual(changes, [[person: "found"]])
        store.requestHandles(for: [person, other])
        await store.flush()
        XCTAssertEqual(calls, 1)
    }

    func testBackfillUpdatesAndRemovesContactEvidenceOnRefresh() async throws {
        var date = Date()
        let store = VerifiedHandleStore(defaults: nil, now: { date })
        store.bind(owner: owner)
        var value: String? = "before"
        store.setDirectory(current: nil, contacts: { input in
            try self.response(input.matrixUsers, handles: value.map { [self.person: $0] } ?? [:])
        })
        defer { store.setDirectory(current: nil, contacts: nil) }
        store.requestHandles(for: [person]); await store.flush()
        value = "after"
        date += VerifiedHandleStore.refreshInterval
        store.requestHandles(for: [person]); await store.flush()
        XCTAssertEqual(store.handle(for: person), "after")
        value = nil
        date += VerifiedHandleStore.refreshInterval
        store.requestHandles(for: [person]); await store.flush()
        XCTAssertNil(store.handle(for: person))
    }

    func testExactEvidenceSurvivesContactMissAndRecentDisagreement() async throws {
        var date = Date()
        let store = VerifiedHandleStore(defaults: nil, now: { date })
        store.bind(owner: owner)
        var resume: CheckedContinuation<AliasContactsResponse, Never>?
        store.setDirectory(current: nil, contacts: { _ in await withCheckedContinuation { resume = $0 } })
        defer { store.setDirectory(current: nil, contacts: nil) }
        store.requestHandles(for: [person])
        let task = Task { await store.flush() }
        for _ in 0..<20 where resume == nil { await Task.yield() }
        store.remember(userID: person, handle: "exact")
        try XCTUnwrap(resume).resume(returning: response([person], handles: [person: "older"]))
        await task.value
        XCTAssertEqual(store.handle(for: person), "exact")
        date += VerifiedHandleStore.refreshInterval
        store.setDirectory(current: nil, contacts: { try self.response($0.matrixUsers) })
        store.requestHandles(for: [person]); await store.flush()
        XCTAssertEqual(store.handle(for: person), "exact")
    }

    func testMissExpiresAfterTwoHoursAndRevisionClearsMissesEarlier() async throws {
        var date = Date()
        let store = VerifiedHandleStore(defaults: nil, now: { date })
        store.bind(owner: owner)
        var revision = 1
        var found = false
        var batches: [[String]] = []
        store.setDirectory(current: nil, contacts: { input in
            batches.append(input.matrixUsers)
            return try self.response(input.matrixUsers, handles: found ? [self.person: "newly_found"] : [:],
                                     revision: revision)
        })
        defer { store.setDirectory(current: nil, contacts: nil) }
        store.requestHandles(for: [person]); await store.flush()
        date += 60 * 60
        store.requestHandles(for: [person]); await store.flush()
        XCTAssertEqual(batches.count, 1)
        revision = 2
        store.requestHandles(for: [other]); await store.flush()
        store.requestHandles(for: [person]); await store.flush()
        XCTAssertEqual(batches.count, 3)
        date += 2 * 60 * 60
        found = true
        store.requestHandles(for: [person]); await store.flush()
        XCTAssertEqual(batches.count, 4)
        XCTAssertEqual(store.handle(for: person), "newly_found")
    }

    func testBackfillFailureKeepsEvidenceAndRetriesWithoutCachingAMiss() async throws {
        var date = Date()
        let store = VerifiedHandleStore(defaults: nil, now: { date })
        store.bind(owner: owner)
        store.remember(userID: person, handle: "before")
        date += VerifiedHandleStore.refreshInterval
        var calls = 0
        store.setDirectory(current: nil, contacts: { input in
            calls += 1
            if calls == 1 { throw NativeDomainClientFailure.transportUnavailable }
            return try self.response(input.matrixUsers, handles: [self.person: "after"])
        })
        defer { store.setDirectory(current: nil, contacts: nil) }
        store.requestHandles(for: [person]); await store.flush()
        XCTAssertEqual(store.handle(for: person), "before")
        await store.flush()
        XCTAssertEqual(calls, 1)
        date += 30
        await store.flush()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.handle(for: person), "after")
    }

    func testBackfillSkipsOwnerForeignInvalidAndFreshExactIDs() async throws {
        let store = VerifiedHandleStore(defaults: nil)
        store.bind(owner: owner)
        store.remember(userID: other, handle: "known")
        var batches: [[String]] = []
        store.setDirectory(current: nil, contacts: { input in
            batches.append(input.matrixUsers)
            return try self.response(input.matrixUsers)
        })
        defer { store.setDirectory(current: nil, contacts: nil) }
        store.requestHandles(for: [owner, other, person, person, "@foreign:other.test", "@Upper:example.test", "bad", ""])
        await store.flush()
        XCTAssertEqual(batches, [[person]])
    }

    func testBackfillBatchesFiftyAndHonorsLocalReadBudget() async throws {
        var date = Date()
        let store = VerifiedHandleStore(defaults: nil, now: { date })
        store.bind(owner: owner)
        var batches: [[String]] = []
        store.setDirectory(current: nil, contacts: { input in
            batches.append(input.matrixUsers)
            return try self.response(input.matrixUsers)
        })
        defer { store.setDirectory(current: nil, contacts: nil) }
        store.requestHandles(for: (0..<651).map { "@person-\($0):example.test" })
        for _ in 0..<14 { await store.flush() }
        XCTAssertEqual(batches.count, 12)
        XCTAssertTrue(batches.allSatisfy { $0.count == 50 })
        date += 10 * 60
        await store.flush(); await store.flush()
        XCTAssertEqual(batches.map(\.count), Array(repeating: 50, count: 13) + [1])
    }

    func testBackfillDailyBudgetAndServerRetryAfter() async throws {
        let start = Date()
        var date = start
        let store = VerifiedHandleStore(defaults: nil, now: { date })
        store.bind(owner: owner)
        var calls = 0
        store.setDirectory(current: nil, contacts: { input in
            calls += 1
            return try self.response(input.matrixUsers)
        })
        defer { store.setDirectory(current: nil, contacts: nil) }
        for index in 0..<96 {
            if index > 0 && index % 12 == 0 { date += 600 }
            store.requestHandles(for: ["@person-\(index):example.test"])
            await store.flush()
        }
        XCTAssertEqual(calls, 96)
        date += 600
        store.requestHandles(for: [person]); await store.flush()
        XCTAssertEqual(calls, 96)
        date = start.addingTimeInterval(24 * 60 * 60)
        await store.flush()
        XCTAssertEqual(calls, 97)

        var attempts = 0
        store.setDirectory(current: nil, contacts: { input in
            attempts += 1
            if attempts == 1 {
                throw NativeDomainClientFailure.http(try NativeHTTPFailure(status: 429,
                    headers: ["Retry-After": "120"], body: Data(#"{"error":"matrix_429"}"#.utf8)))
            }
            return try self.response(input.matrixUsers, handles: [self.other: "found"])
        })
        store.requestHandles(for: [other]); await store.flush()
        date += 119
        await store.flush()
        XCTAssertEqual(attempts, 1)
        date += 1
        await store.flush()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(store.handle(for: other), "found")
    }

    func testBackfillNegotiatesLegacyOnlyOnBadRequest() async throws {
        let store = VerifiedHandleStore(defaults: nil)
        store.bind(owner: owner)
        var versions: [Int?] = []
        store.setDirectory(current: nil, contacts: { input in
            versions.append(input.schemaVersion)
            if input.schemaVersion != nil {
                throw NativeDomainClientFailure.http(try NativeHTTPFailure(status: 400, headers: [:],
                    body: Data(#"{"error":"matrix_400"}"#.utf8)))
            }
            return try self.response(input.matrixUsers, handles: [self.person: "found"], legacy: true)
        })
        defer { store.setDirectory(current: nil, contacts: nil) }
        store.requestHandles(for: [person]); await store.flush()
        store.requestHandles(for: [other]); await store.flush()
        XCTAssertEqual(versions, [2, nil, nil])
        XCTAssertEqual(store.handle(for: person), "found")
    }

    func testOldContactsCannotPublishAfterClientReplacement() async throws {
        let store = VerifiedHandleStore(defaults: nil)
        store.bind(owner: owner)
        var resume: CheckedContinuation<AliasContactsResponse, Never>?
        store.setDirectory(current: nil, contacts: { _ in await withCheckedContinuation { resume = $0 } })
        store.requestHandles(for: [person])
        let task = Task { await store.flush() }
        for _ in 0..<20 where resume == nil { await Task.yield() }
        store.setDirectory(current: nil, contacts: nil)
        try XCTUnwrap(resume).resume(returning: response([person], handles: [person: "stale"]))
        await task.value
        XCTAssertNil(store.handle(for: person))
    }

    func testNewExactProofMovesHandleAndNeverGuessesFromID() {
        let store = VerifiedHandleStore(defaults: nil)
        store.bind(owner: owner)
        XCTAssertNil(store.handle(for: person))
        store.remember(userID: person, handle: "shared")
        store.remember(userID: other, handle: "shared")
        XCTAssertNil(store.handle(for: person))
        XCTAssertEqual(store.handle(for: other), "shared")
        store.remember(userID: other, handle: "@invalid")
        XCTAssertEqual(store.handle(for: other), "shared")
    }
}
