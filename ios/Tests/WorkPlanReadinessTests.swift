import Foundation
import XCTest
@testable import AtumNativeAPI

final class WorkPlanReadinessTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_795_824_000)
    private let expiry = Date(timeIntervalSince1970: 1_795_824_600)

    static func fixture(_ name: String, trim: Bool = false) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "plan-readiness"))
        let data = try Data(contentsOf: url)
        if trim { return Data(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).utf8) }
        return data
    }

    private func decode(_ data: Data) throws -> WorkPlanReadiness {
        try NativeAPI.decode(WorkPlanReadiness.self, from: data)
    }

    private func replacing(_ from: String, with to: String) throws -> Data {
        let json = String(decoding: try Self.fixture("response"), as: UTF8.self)
        XCTAssertTrue(json.contains(from), from)
        return Data(json.replacingOccurrences(of: from, with: to).utf8)
    }

    func testDecodesTheWireFixtureAndExactRequest() throws {
        let snapshot = try decode(Self.fixture("response"))
        XCTAssertEqual(WorkPlanReadinessContract.requestBody, try Self.fixture("request", trim: true))
        XCTAssertEqual(snapshot.checkedAt, 1_795_824_000_000)
        XCTAssertEqual(snapshot.entry(for: .codex, at: checkedAt), .ready(validUntil: 1_795_824_600_000))
        XCTAssertEqual(snapshot.entry(for: .claude, at: checkedAt), .grantExpired)
        XCTAssertEqual(snapshot.entry(for: .antigravity, at: checkedAt), .grantMissing)
    }

    func testRejectsUnknownKeysMissingPlansAndUnknownStates() throws {
        let invalid = [
            (#""plans":"#, #""extra": null, "plans":"#),
            (#""codex":"#, #""extra": {}, "codex":"#),
            (#""claude":"#, #""claude-plan":"#),
            (#""state": "grant_missing""#, #""state": "grant_missing", "extra": false"#),
            (#""state": "grant_expired""#, #""state": "future_state""#),
            ("atum.work-plan-readiness/1", "atum.work-plan-readiness/2")
        ]
        for (from, to) in invalid {
            XCTAssertThrowsError(try decode(replacing(from, with: to)), to)
        }
        XCTAssertThrowsError(try decode(replacing(#""codex": { "state": "ready", "validUntil": 1795824600000 },"#, with: "")))
    }

    func testRequiresBoundedTimestampsAndExpiryOnlyOnReady() throws {
        for invalid in ["-1", "null", "true", "1.5", "9007199254740992", #""1795824600000""#] {
            XCTAssertThrowsError(try decode(replacing("1795824000000", with: invalid)), invalid)
            XCTAssertThrowsError(try decode(replacing("1795824600000", with: invalid)), invalid)
        }
        for invalid in ["1795823999999", "1795824000000"] {
            XCTAssertThrowsError(try decode(replacing("1795824600000", with: invalid)), invalid)
        }
        XCTAssertThrowsError(try decode(replacing(#", "validUntil": 1795824600000"#, with: "")))
        XCTAssertThrowsError(try decode(replacing(#""state": "grant_expired""#,
                                                  with: #""state": "grant_expired", "validUntil": null"#)))
        let snapshot = try decode(replacing("1795824600000", with: "9007199254740991.0"))
        XCTAssertEqual(snapshot.entry(for: .codex, at: checkedAt), .ready(validUntil: 9_007_199_254_740_991))
    }

    func testProjectionUsesReadinessForMixedPlansEvenWhenRegistryDisagrees() throws {
        let readiness = try decode(replacing("grant_missing", with: "not_connected"))
        let registry = try NativeAPI.decode(AccountConnections.self, from: AccountConnectionsTests.fixture)
        let rows = AccountConnectionsView.planRows(registry, readiness: readiness, now: checkedAt)
        XCTAssertEqual(rows.map(\.plan), [.codex, .claude, .antigravity])
        XCTAssertEqual(rows.map(\.state), [.connected, .needsRenew, .notConnected])
        XCTAssertEqual(rows.map(\.offersConnect), [false, true, true])
        XCTAssertTrue(rows.allSatisfy { !$0.readinessUnknown })
        XCTAssertEqual(AccountConnectionsView.line(rows[1]), .needsRenew)

        let missingGrant = try decode(Self.fixture("response"))
        XCTAssertEqual(AccountConnectionsView.planRow(registry, .antigravity, readiness: missingGrant,
                                                       now: checkedAt).state, .needsRenew)
        XCTAssertEqual(AccountConnectionsView.planRow(nil, .codex, readiness: readiness, now: checkedAt).state, .connected)
        let staleButReady = try decode(replacing(#""state": "grant_expired""#,
                                                 with: #""state": "ready", "validUntil": 1795824600000"#))
        let claude = AccountConnectionsView.planRow(registry, .claude, readiness: staleButReady, now: checkedAt)
        XCTAssertEqual(claude.state, .connected)
        XCTAssertEqual(AccountConnectionsView.line(claude), .lastSeen("Mac mini"))
    }

    func testExpiryDropsConnectionAndPreventsSheetCompletionAtTheDeadline() throws {
        let readiness = try decode(Self.fixture("response"))
        let before = expiry.addingTimeInterval(-0.001)
        XCTAssertEqual(readiness.nextExpiry(after: before), expiry)
        XCTAssertNil(readiness.nextExpiry(after: expiry))
        XCTAssertEqual(AccountConnectionsView.planRow(nil, .codex, readiness: readiness, now: before).state, .connected)
        let expired = AccountConnectionsView.planRow(nil, .codex, readiness: readiness, now: expiry)
        XCTAssertEqual(expired.state, .needsRenew)
        XCTAssertFalse(expired.readinessUnknown)
        XCTAssertTrue(AccountConnectionsView.connectLanded(readiness, plan: .codex, now: before))
        XCTAssertFalse(AccountConnectionsView.connectLanded(readiness, plan: .codex, now: expiry))
        XCTAssertFalse(AccountConnectionsView.connectLanded(readiness, plan: .claude, now: before))
        XCTAssertFalse(AccountConnectionsView.connectLanded(readiness, plan: .antigravity, now: before))
        XCTAssertFalse(AccountConnectionsView.connectLanded(nil, plan: .codex, now: before))
    }

    func testUnavailableReadinessFallsBackToSignInWithUnknownFlag() throws {
        let registry = try NativeAPI.decode(AccountConnections.self, from: AccountConnectionsTests.fixture)
        let rows = AccountConnectionsView.planRows(registry, readiness: WorkPlanReadinessRead.unavailable.snapshot)
        XCTAssertEqual(rows.map(\.state), [.signedIn, .stale, .notConnected])
        XCTAssertEqual(rows.map(\.offersConnect), [false, false, true])
        XCTAssertTrue(rows.allSatisfy(\.readinessUnknown))
        XCTAssertEqual(AccountConnectionsView.line(rows[0]), .onMacs("MacBook Pro"))
    }
}
