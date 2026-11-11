import Foundation
import XCTest
@testable import AtumNativeAPI

/// AS-3/AS-5: the alias directory's answers and desktop's claim walk.
@MainActor final class AgentAliasesTests: XCTestCase {
    private let assistant = try! NativeID("00000000-0000-4000-8000-0000000000a1")

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try NativeAPI.decode(type, from: Data(json.utf8))
    }

    func testACheckIsAvailableExactlyWhenItHasNoCode() throws {
        XCTAssertTrue(try decode(AgentAliasCheck.self, #"{"handle":"lan_bot","available":true,"code":null}"#).available)
        XCTAssertEqual(try decode(AgentAliasCheck.self,
                                  #"{"handle":"lan_bot","available":false,"code":"alias_reserved"}"#).code, .reserved)
        XCTAssertThrowsError(try decode(AgentAliasCheck.self, #"{"handle":"lan_bot","available":true,"code":"alias_reserved"}"#))
        XCTAssertThrowsError(try decode(AgentAliasCheck.self, #"{"handle":"lan_bot","available":false,"code":"alias_new"}"#))
        XCTAssertThrowsError(try decode(AgentAliasCheck.self, #"{"handle":"lan_bot","available":true,"code":null,"x":1}"#))
    }

    func testAnAssignmentIsAssignedAndARenameNamesADifferentPrevious() throws {
        let claim = try decode(AgentAliasAssignment.self,
            #"{"handle":"lan_bot","state":"assigned","principal":"00000000-0000-4000-8000-0000000000a1","generation":1,"replayed":true}"#)
        XCTAssertTrue(claim.replayed)
        XCTAssertNil(claim.previous)
        XCTAssertThrowsError(try decode(AgentAliasAssignment.self,
            #"{"handle":"lan_bot","state":"pending","principal":"00000000-0000-4000-8000-0000000000a1","generation":1}"#))
        XCTAssertThrowsError(try decode(AgentAliasAssignment.self,
            #"{"handle":"lan_bot","state":"assigned","principal":"00000000-0000-4000-8000-0000000000a1","generation":2,"previous":"lan_bot"}"#))
        XCTAssertThrowsError(try decode(AgentAliasAssignment.self,
            #"{"handle":"lan_bot","state":"assigned","principal":"00000000-0000-4000-8000-0000000000a1","generation":1,"replayed":false}"#))
    }

    func testARetirementIsRetired() throws {
        let value = try decode(AgentRetirement.self,
            #"{"id":"00000000-0000-4000-8000-0000000000a1","status":"retired","sessionCleanup":"unconfirmed"}"#)
        XCTAssertEqual(value.sessionCleanup, .unconfirmed)
        XCTAssertThrowsError(try decode(AgentRetirement.self,
            #"{"id":"00000000-0000-4000-8000-0000000000a1","status":"active","sessionCleanup":"complete"}"#))
    }

    func testRefusalsReadAsDesktopsCodes() throws {
        func http(_ status: Int, _ body: String, retryAfter: String? = nil) throws -> NativeDomainClientFailure {
            .http(try NativeHTTPFailure(status: status, headers: retryAfter.map { ["Retry-After": $0] } ?? [:],
                                        body: Data(body.utf8)))
        }
        XCTAssertEqual(AgentAliasRefusal.from(try http(400, #"{"error":"matrix_400"}"#)), .invalid)
        XCTAssertEqual(AgentAliasRefusal.from(try http(403, #"{"error":"matrix_403"}"#)), .denied)
        XCTAssertEqual(AgentAliasRefusal.from(try http(404, #"{"error":"matrix_404"}"#)), .missing)
        XCTAssertEqual(AgentAliasRefusal.from(try http(409, #"{"error":"matrix_409"}"#)), .conflict)
        XCTAssertEqual(AgentAliasRefusal.from(try http(429, #"{"error":"matrix_429","details":{"reason":"alias_rename_too_soon"}}"#,
                                                      retryAfter: "86400")),
                       .limit(retryAfterSeconds: 86_400))
        XCTAssertEqual(AgentAliasRefusal.from(NativeDomainClientFailure.transportUnavailable), .unavailable)
        XCTAssertEqual(AgentAliasRefusal.from(NativeDomainClientFailure.authenticationRefused), .authentication)
    }

    // MARK: Claim walk

    private final class Directory {
        var current: AliasCurrentResponse = .none
        var unavailable: Set<String> = []
        var reserved: Set<String> = []
        var lostOnClaim: Set<String> = []
        var conflictOnClaim: Set<String> = []
        var checkFails = false
        var checks: [String] = []
        var claims: [AgentAliasClaimRequest] = []

        func calls(principal: NativeID) -> AgentAliasDirectoryCalls {
            AgentAliasDirectoryCalls(
                current: { _ in self.current },
                check: { handle, _ in
                    self.checks.append(handle.rawValue)
                    if self.checkFails { throw NativeDomainClientFailure.transportUnavailable }
                    if self.reserved.contains(handle.rawValue) {
                        return AgentAliasCheck(handle: handle, available: false, code: .reserved)
                    }
                    if self.unavailable.contains(handle.rawValue) {
                        return AgentAliasCheck(handle: handle, available: false, code: .unavailable)
                    }
                    return AgentAliasCheck(handle: handle, available: true, code: nil)
                },
                claim: { request in
                    self.claims.append(request)
                    if self.lostOnClaim.contains(request.handle.rawValue) {
                        self.lostOnClaim.remove(request.handle.rawValue)
                        throw NativeDomainClientFailure.transportUnavailable
                    }
                    if self.conflictOnClaim.contains(request.handle.rawValue) {
                        throw NativeDomainClientFailure.http(try NativeHTTPFailure(
                            status: 409, headers: [:], body: Data(#"{"error":"matrix_409"}"#.utf8)))
                    }
                    return AgentAliasAssignment(handle: request.handle, principal: principal, generation: 1)
                })
        }
    }

    private var counter = 0
    private func nextID() -> NativeID {
        counter += 1
        return try! NativeID(String(format: "00000000-0000-4000-8000-%012d", counter))
    }

    func testTheWalkKeepsAHandleTheAssistantAlreadyHas() async throws {
        let directory = Directory()
        directory.current = .assigned(handle: try NativeHandle("old_bot"), generation: 3)
        let outcome = await AgentHandleClaimWalk.run(assistantID: assistant, groups: [["lan_bot"]],
                                                     calls: directory.calls(principal: assistant),
                                                     requestID: nextID)
        XCTAssertEqual(outcome, .existing(try NativeHandle("old_bot")))
        XCTAssertTrue(directory.claims.isEmpty)
        XCTAssertFalse(outcome.isRetryable)
    }

    func testTheWalkSkipsTakenHandlesAndAReservedStemEndsItsGroup() async throws {
        let directory = Directory()
        directory.unavailable = ["lan_bot"]
        directory.reserved = ["moon_bot"]
        let outcome = await AgentHandleClaimWalk.run(
            assistantID: assistant,
            groups: [["moon_bot", "moon10_bot"], ["lan_bot", "lan10_bot"]],
            calls: directory.calls(principal: assistant), requestID: nextID)
        XCTAssertEqual(outcome, .claimed(try NativeHandle("lan10_bot")))
        XCTAssertEqual(directory.checks, ["moon_bot", "lan_bot", "lan10_bot"])
        XCTAssertEqual(directory.claims.map(\.handle.rawValue), ["lan10_bot"])
    }

    func testAHandleTakenBetweenCheckAndClaimMovesToTheNext() async throws {
        let directory = Directory()
        directory.conflictOnClaim = ["lan_bot"]
        let outcome = await AgentHandleClaimWalk.run(assistantID: assistant, groups: [["lan_bot", "lan10_bot"]],
                                                     calls: directory.calls(principal: assistant),
                                                     requestID: nextID)
        XCTAssertEqual(outcome, .claimed(try NativeHandle("lan10_bot")))
    }

    func testEveryHandleTakenIsExhaustedAndSettlesQuietly() async throws {
        let directory = Directory()
        directory.unavailable = ["lan_bot", "lan10_bot"]
        let outcome = await AgentHandleClaimWalk.run(assistantID: assistant, groups: [["lan_bot", "lan10_bot"]],
                                                     calls: directory.calls(principal: assistant),
                                                     requestID: nextID)
        XCTAssertEqual(outcome, .exhausted)
        XCTAssertFalse(outcome.isRetryable)
        XCTAssertFalse(AgentHandleClaimOutcome.refused(.closed).isRetryable)
        XCTAssertTrue(AgentHandleClaimOutcome.refused(.limit(retryAfterSeconds: 5)).isRetryable)
    }

    func testALostClaimIsResentWithTheSameRequestNeverAsASecondClaim() async throws {
        let directory = Directory()
        directory.lostOnClaim = ["lan_bot"]
        var pending: AgentAliasClaimRequest?
        let first = await AgentHandleClaimWalk.run(assistantID: assistant, groups: [["lan_bot", "lan10_bot"]],
                                                   calls: directory.calls(principal: assistant),
                                                   requestID: nextID, onAttempt: { pending = $0 })
        XCTAssertEqual(first, .refused(.unavailable))
        XCTAssertTrue(first.isRetryable)
        let lost = try XCTUnwrap(pending)
        let second = await AgentHandleClaimWalk.run(assistantID: assistant, groups: [["lan_bot", "lan10_bot"]],
                                                    pending: lost, calls: directory.calls(principal: assistant),
                                                    requestID: nextID)
        XCTAssertEqual(second, .claimed(try NativeHandle("lan_bot")))
        XCTAssertEqual(directory.claims.map(\.requestId), [lost.requestId, lost.requestId])
    }

    func testACheckThatCannotBeAnsweredIsRetryable() async throws {
        let directory = Directory()
        directory.checkFails = true
        let outcome = await AgentHandleClaimWalk.run(assistantID: assistant, groups: [["lan_bot"]],
                                                     calls: directory.calls(principal: assistant),
                                                     requestID: nextID)
        XCTAssertEqual(outcome, .refused(.unavailable))
        XCTAssertTrue(outcome.isRetryable)
    }
}
