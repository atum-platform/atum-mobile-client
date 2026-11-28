import Foundation
import Observation
import XCTest
@testable import AtumNativeAPI

@available(macOS 14.0, *)
@MainActor final class PhoneWorkSelectionTests: XCTestCase {
    private let agent = try! NativeID("7ad4a8b3-58fa-40b9-9f68-d595bbff618e")
    private let otherAgent = try! NativeID("7ad4a8b3-58fa-40b9-9f68-d595bbff618f")
    private let pick = WorkModelSelection(plan: .codex, model: "gpt-5.4")!
    private let otherPick = WorkModelSelection(plan: .claude, model: "claude-opus-5-5")!

    func testReadDecoderKeepsNullAndAllowsAdditiveFields() throws {
        let empty = try decode(#"{"revision":0,"selection":null,"future":{}}"#)
        XCTAssertEqual(empty.revision, 0)
        XCTAssertNil(empty.selection)
        let cleared = try decode(#"{"revision":8,"selection":null}"#)
        XCTAssertEqual(cleared.revision, 8)
        XCTAssertNil(cleared.selection)
        let selected = try decode("""
            {"revision":9,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5",
            "future":{"nested":true}},"future":["other",3.14]}
            """)
        XCTAssertEqual(selected.selection, otherPick)
        XCTAssertEqual(selected.revision, 9)
    }

    func testDecoderRejectsMalformedRequiredFields() {
        for malformed in [
            #"{"selection":null}"#,
            #"{"revision":0}"#,
            #"{"revision":-1,"selection":null}"#,
            #"{"revision":true,"selection":null}"#,
            #"{"revision":1.5,"selection":null}"#,
            #"{"revision":9007199254740992,"selection":null}"#,
            #"{"revision":1,"selection":[]}"#,
            #"{"revision":1,"selection":{"plan":"claude","model":"agent"}}"#,
            #"{"revision":1,"selection":{"provider":"atum","plan":"claude","model":"agent"}}"#,
            #"{"revision":1,"selection":{"provider":"atum-work","plan":"claude-plan","model":"agent"}}"#,
            #"{"revision":1,"selection":{"provider":"atum-work","plan":"claude","model":""}}"#,
            #"{"revision":1,"selection":{"provider":"atum-work","plan":"claude","model":19}}"#
        ] {
            XCTAssertThrowsError(try decode(malformed), malformed)
        }
        XCTAssertNil(WorkModelSelection(plan: .codex, model: String(repeating: "🤖", count: 101)))
    }

    func testTransportUsesOwnerDeviceServicesAndAcceptsAnIdempotentWrite() async throws {
        let client = client([
            .init(200, #"{"revision":4,"selection":{"provider":"atum-work","plan":"codex","model":"gpt-5.4"}}"#),
            .init(200, #"{"revision":4,"provider":"atum-work","plan":"codex","model":"gpt-5.4","future":true}"#),
            .init(200, #"{"revision":0,"provider":"atum-work","plan":"codex","model":"gpt-5.4"}"#)
        ])
        let read = try await client.workSelection(agentPrincipal: agent)
        let result = try await client.setWorkSelection(
            agentPrincipal: agent, selection: pick, expectedRevision: read.revision, isCurrent: { true }
        )
        XCTAssertEqual(result, .saved(read))
        do {
            _ = try await client.setWorkSelection(
                agentPrincipal: agent, selection: pick, expectedRevision: 4, isCurrent: { true }
            )
            XCTFail("a malformed write acknowledgement was accepted")
        } catch {
            XCTAssertEqual(error as? NativeDomainClientFailure, .invalidResponse)
        }

        let requests = WorkSelectionFixture.requests
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertEqual(request.path, "/api/matrix/v1/device-services")
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.authorization, "Bearer owner-fixture")
            XCTAssertNil(request.deviceServicesVersion)
        }
        XCTAssertEqual(try XCTUnwrap(requests.first?.body) as NSDictionary, [
            "operation": "work_selection_read", "agentPrincipal": agent.rawValue
        ] as NSDictionary)
        XCTAssertEqual(try XCTUnwrap(requests.dropFirst().first?.body) as NSDictionary, [
            "operation": "work_selection_set", "agentPrincipal": agent.rawValue, "expectedRevision": 4,
            "selection": ["provider": "atum-work", "plan": "codex", "model": "gpt-5.4"]
        ] as NSDictionary)
    }

    func testEligibilityDecoderAndTransportMatchThePlatformFixture() async throws {
        let fixture = """
            {"plans":[
              {"plan":"codex","status":"unavailable","models":[]},
              {"plan":"claude","status":"selectable","models":[{"id":"claude-opus-5-5","displayName":"Claude Opus 5.5"}]},
              {"plan":"antigravity","status":"connect","models":[]}
            ]}
            """
        let client = client([], eligibility: [.init(200, fixture)])
        let value = try await client.workPlanEligibility(agentPrincipal: agent)
        XCTAssertEqual(value.plans.map(\.plan), ["codex", "claude", "antigravity"])
        XCTAssertEqual(value.plans.map(\.status), [.unavailable, .selectable, .connect])
        XCTAssertEqual(value.plans[1].models.map(\.displayName), ["Claude Opus 5.5"])
        let request = try XCTUnwrap(WorkSelectionFixture.requests.first)
        XCTAssertEqual(request.path, "/api/matrix/v1/device-services")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.authorization, "Bearer owner-fixture")
        XCTAssertNil(request.deviceServicesVersion)
        XCTAssertEqual(try XCTUnwrap(request.body) as NSDictionary, [
            "operation": "work_plan_eligibility_read", "agentPrincipal": agent.rawValue
        ] as NSDictionary)
    }

    func testEligibilityRejectsMalformedRowsAndAcceptsAdditionalPlanIDs() throws {
        func decode(_ body: String) throws -> WorkPlanEligibilitySnapshot {
            try NativeAPI.decode(WorkPlanEligibilitySnapshot.self, from: Data(body.utf8))
        }
        XCTAssertEqual(try decode(#"{"plans":[{"plan":"future-plan","status":"connect","models":[],"extra":1}]}"#)
            .plans.first?.plan, "future-plan")
        let model = #"{"id":"opus-v1","displayName":"Opus (v1)"}"#
        for bad in [
            #"{"plans":null}"#,
            #"{"plans":[{"plan":"codex","status":"selectable","models":[]}]}"#,
            #"{"plans":[{"plan":"codex","status":"unknown","models":[]}]}"#,
            #"{"plans":[{"plan":"codex","status":"connect"}]}"#,
            #"{"plans":[{"plan":"codex","status":"connect","models":[]},{"plan":"codex","status":"unavailable","models":[]}]}"#,
            """
            {"plans":[{"plan":"claude","status":"unavailable","models":[\(model)]}]}
            """,
            """
            {"plans":[{"plan":"claude","status":"selectable","models":[\(model),\(model)]}]}
            """,
            #"{"plans":[{"plan":"codex","status":"selectable","models":[{"id":"bad id","displayName":"Name"}]}]}"#,
            #"{"plans":[{"plan":"codex","status":"selectable","models":[{"id":"good-id","displayName":"<Name>"}]}]}"#
        ] {
            XCTAssertThrowsError(try decode(bad), bad)
        }
    }

    func testSaveReadsMissingRevisionAndRetriesAnAdvancedConflictOnce() async {
        let state = picker([
            .init(200, #"{"revision":0,"selection":null}"#), .conflict,
            .init(200, #"{"revision":2,"selection":null}"#),
            .init(200, #"{"revision":3,"provider":"atum-work","plan":"codex","model":"gpt-5.4"}"#)
        ], plans: [pick])
        await state.reload()
        await state.save(pick)
        XCTAssertEqual(operations, ["work_selection_read", "work_selection_set", "work_selection_read", "work_selection_set"])
        XCTAssertEqual(writeRevisions, [0, 2])
        XCTAssertEqual(state.value?.readState, .ready)
        XCTAssertEqual(state.value?.readySnapshot?.revision, 3)
        XCTAssertEqual(state.value?.readySnapshot?.selection, pick)
        XCTAssertEqual(state.value?.saveState, .idle)
    }

    func testUnchangedRevisionSettlesTheConflictWithoutRetry() async {
        let winner = WorkSelectionFixture.Reply(200, """
            {"revision":4,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}
            """)
        let state = picker([winner, .conflict, winner], plans: [pick])
        await state.reload()
        await state.save(pick)
        XCTAssertEqual(writeRevisions, [4])
        XCTAssertEqual(operations.last, "work_selection_read")
        XCTAssertEqual(state.value?.readySnapshot?.selection, otherPick)
        XCTAssertEqual(state.value?.saveState, .failed(.conflict))
    }

    func testSecondConflictInvalidatesTheRevisionUntilExplicitRefresh() async {
        let state = picker([
            .init(200, #"{"revision":1,"selection":null}"#), .conflict,
            .init(200, #"{"revision":2,"selection":null}"#), .conflict,
            .init(200, #"{"revision":3,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}"#)
        ], plans: [pick])
        await state.reload()
        await state.save(pick)
        XCTAssertEqual(operations, ["work_selection_read", "work_selection_set", "work_selection_read", "work_selection_set"])
        XCTAssertEqual(writeRevisions, [1, 2])
        XCTAssertNil(state.value?.readySnapshot)
        XCTAssertEqual(state.value?.readState, .failed)
        XCTAssertEqual(state.value?.saveState, .failed(.conflict))
        await state.reload()
        XCTAssertEqual(state.value?.readySnapshot?.revision, 3)
        XCTAssertEqual(state.value?.readySnapshot?.selection, otherPick)
    }

    func testNewPickDropsASupersededConflictRetry() async {
        let pending = HeldWorkReply(arrived: expectation(description: "old pick's conflict reread"))
        let state = picker([
            .init(200, #"{"revision":4,"selection":null}"#), .conflict,
            .init(200, #"{"revision":5,"selection":null}"#, held: pending),
            .init(200, #"{"revision":6,"selection":null}"#),
            .init(200, #"{"revision":7,"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}"#)
        ], plans: [pick, otherPick])
        await state.reload()
        let old = Task { await state.save(pick) }
        await fulfillment(of: [pending.arrived], timeout: 2)
        XCTAssertEqual(state.value?.readState, .loading)
        let latest = Task { await state.save(otherPick) }
        await waitForSave(otherPick, in: state)
        pending.deliver()
        await old.value
        await latest.value
        XCTAssertEqual(writeRevisions, [4, 6])
        XCTAssertEqual(state.value?.readySnapshot?.selection, otherPick)
        XCTAssertEqual(state.value?.readySnapshot?.revision, 7)
        XCTAssertEqual(state.value?.saveState, .idle)
    }

    func testWorkWritesSerializeAcrossClientReplacementAndOnlyLatestPendingPickSends() async {
        let held = HeldWorkReply(arrived: expectation(description: "first write is in flight"))
        let dropped = WorkModelSelection(plan: .codex, model: "dropped")!
        let initial = WorkSelectionFixture.Reply(200, #"{"revision":4,"selection":{"provider":"atum-work","plan":"codex","model":"gpt-5.4"}}"#)
        let client = client([
            initial, initial,
            .init(200, #"{"revision":5,"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}"#, held: held),
            .init(200, #"{"revision":5,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}"#),
            .init(200, #"{"revision":6,"provider":"atum-work","plan":"codex","model":"gpt-5.4"}"#)
        ], eligibility: [eligibility([pick, otherPick, dropped])])
        let first = PhoneModelPickerWorkSelection(agentPrincipal: agent, client: client, isCurrent: { true })
        let replacement = NativeDomainClient(
            testAuthorization: { _ in "owner-fixture" }, protocolClasses: [WorkSelectionFixture.self]
        )
        let reopened = PhoneModelPickerWorkSelection(agentPrincipal: agent, client: replacement, isCurrent: { true })
        await first.reload()
        await reopened.reload()
        let old = Task { await first.save(otherPick) }
        await fulfillment(of: [held.arrived], timeout: 2)
        first.retire()
        old.cancel()
        let intermediate = Task { await reopened.save(dropped) }
        await waitForSave(dropped, in: reopened)
        let final = Task { await reopened.save(pick) }
        await waitForSave(pick, in: reopened)
        await intermediate.value
        XCTAssertEqual(writeModels, [otherPick.model])
        XCTAssertEqual(reopened.value?.saveState, .saving(pick))

        held.deliver()
        await old.value
        await final.value
        XCTAssertEqual(writeRevisions, [4, 5])
        XCTAssertEqual(writeModels, [otherPick.model, pick.model])
        XCTAssertEqual(reopened.value?.readySnapshot?.revision, 6)
        XCTAssertEqual(reopened.value?.readySnapshot?.selection, pick)
        XCTAssertEqual(reopened.value?.saveState, .idle)
    }

    func testSupersededWorkWriteCannotReplayDuringAuthorization() async {
        let held = HeldWorkReply(arrived: expectation(description: "first write awaiting a 401"))
        let state = picker([
            .init(200, #"{"revision":4,"selection":null}"#),
            .init(401, #"{"error":"matrix_401"}"#, held: held),
            .init(200, #"{"revision":4,"selection":null}"#),
            .init(200, #"{"revision":5,"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}"#)
        ], plans: [pick, otherPick])
        await state.reload()
        let old = Task { await state.save(pick) }
        await fulfillment(of: [held.arrived], timeout: 2)
        let latest = Task { await state.save(otherPick) }
        await waitForSave(otherPick, in: state)
        held.deliver()
        await old.value
        await latest.value
        XCTAssertEqual(writeModels, [pick.model, otherPick.model])
        XCTAssertEqual(state.value?.readySnapshot?.selection, otherPick)
    }

    func testAccountSwitchDiscardsAnInFlightConflictReadAndPreventsRetry() async {
        let pending = HeldWorkReply(arrived: expectation(description: "old account's conflict reread"))
        var accountGeneration = 1
        let state = picker([
            .init(200, #"{"revision":2,"selection":null}"#), .conflict,
            .init(200, #"{"revision":3,"selection":null}"#, held: pending)
        ], plans: [pick], isCurrent: { accountGeneration == 1 })
        await state.reload()
        let save = Task { await state.save(pick) }
        await fulfillment(of: [pending.arrived], timeout: 2)
        let accountChanged = expectation(description: "account switch invalidates the observed value")
        withObservationTracking { _ = state.value } onChange: { accountChanged.fulfill() }
        accountGeneration += 1
        state.retire()
        await fulfillment(of: [accountChanged], timeout: 2)
        XCTAssertNil(state.value)
        pending.deliver()
        await save.value
        await state.save(pick)
        XCTAssertEqual(writeRevisions, [2])
        XCTAssertNil(state.value)
    }

    func testAssistantSwitchDiscardsAnInFlightRead() async {
        let pending = HeldWorkReply(arrived: expectation(description: "first assistant's read"))
        var activeAgent = agent
        let client = client([
            .init(200, #"{"revision":2,"selection":null}"#, held: pending),
            .init(200, #"{"revision":9,"selection":null}"#)
        ])
        let first = PhoneModelPickerWorkSelection(agentPrincipal: agent, client: client,
                                                   isCurrent: { activeAgent == self.agent })
        let read = Task { await first.reload() }
        await fulfillment(of: [pending.arrived], timeout: 2)
        activeAgent = otherAgent
        let second = PhoneModelPickerWorkSelection(agentPrincipal: otherAgent, client: client,
                                                    isCurrent: { activeAgent == self.otherAgent })
        await second.reload()
        pending.deliver()
        await read.value
        XCTAssertNil(first.value)
        XCTAssertEqual(second.value?.snapshot?.revision, 9)
        let selectionRequests = WorkSelectionFixture.requests.filter { $0.body?["operation"] as? String == "work_selection_read" }
        XCTAssertEqual(selectionRequests.compactMap { $0.body?["agentPrincipal"] as? String },
                       [agent.rawValue, otherAgent.rawValue])
    }

    func testPickerUsesAssistantEligibilityAndKeepsASavedIneligibleModelCurrent() async {
        let client = client([
            .init(200, #"{"revision":6,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}"#),
            .init(200, #"{"revision":7,"provider":"atum-work","plan":"codex","model":"gpt-5.4"}"#)
        ], eligibility: [.init(200, """
            {"plans":[{"plan":"codex","status":"selectable","models":[{"id":"gpt-5.4","displayName":"From Published Mac"}]},
            {"plan":"claude","status":"unavailable","models":[]},{"plan":"antigravity","status":"connect","models":[]}]}
            """)])
        let state = PhoneModelPickerWorkSelection(agentPrincipal: agent, client: client, isCurrent: { true })
        await state.save(pick)
        XCTAssertTrue(WorkSelectionFixture.requests.isEmpty)
        await state.reload()
        XCTAssertEqual(state.rows.filter(\.selectable).map(\.id), [pick])
        XCTAssertEqual(state.rows.first?.displayName, "From Published Mac")
        let saved = state.rows.filter(\.selected)
        XCTAssertEqual(saved.map(\.id), [otherPick])
        XCTAssertEqual(saved.first?.displayName,
                       "Claude · \(ModelDisplayName.destinationLabel(model: otherPick.model))")
        await state.save(otherPick)
        XCTAssertEqual(operations, ["work_selection_read"])
        await state.save(pick)
        XCTAssertEqual(writeRevisions, [6])
        XCTAssertEqual(state.rows.filter(\.selected).map(\.id), [pick])
    }

    func testUnavailableEligibilityFailsClosedWhileSavedChoiceRemainsCurrent() async {
        let selection = WorkSelectionFixture.Reply(200,
            #"{"revision":6,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}"#)
        for unavailable in [
            WorkSelectionFixture.Reply(400, #"{"error":"matrix_400","details":{"reason":"unknown_operation"}}"#),
            .init(503, #"{"error":"matrix_503"}"#),
            .init(200, #"{"plans":null}"#)
        ] {
            let client = client([selection, selection], eligibility: [eligibility([pick]), unavailable])
            let state = PhoneModelPickerWorkSelection(agentPrincipal: agent, client: client, isCurrent: { true })
            await state.reload()
            XCTAssertTrue(state.rows.contains(where: \.selectable))
            await state.reload()
            XCTAssertEqual(state.value?.eligibility, .unknown)
            XCTAssertEqual(state.rows.filter(\.selected).map(\.id), [otherPick])
            XCTAssertFalse(state.rows.contains(where: \.selectable))
            await state.save(pick)
            XCTAssertTrue(writeRevisions.isEmpty)
        }
    }

    func testSaveRechecksEligibilityWhenPublicationExpiredAfterReload() async {
        let denied = WorkSelectionFixture.Reply(200, #"{"plans":[{"plan":"codex","status":"unavailable","models":[]}]}"#)
        let client = client([.init(200, #"{"revision":1,"selection":null}"#)],
                            eligibility: [eligibility([pick]), denied])
        let state = PhoneModelPickerWorkSelection(agentPrincipal: agent, client: client, isCurrent: { true })
        await state.reload()
        XCTAssertTrue(state.rows.contains(where: \.selectable))
        await state.save(pick)
        XCTAssertEqual(state.value?.eligibility, .known([]))
        XCTAssertTrue(state.rows.isEmpty)
        XCTAssertTrue(writeRevisions.isEmpty)
    }

    func testAmbiguousWriteFailureKeepsTheNameAndRequiresAFreshRevision() async {
        let state = picker([
            .init(200, #"{"revision":6,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}"#),
            .init(503, "unavailable"),
            .init(200, #"{"revision":7,"selection":{"provider":"atum-work","plan":"codex","model":"gpt-5.4"}}"#),
            .init(200, #"{"revision":8,"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}"#)
        ], plans: [pick, otherPick])
        await state.reload()
        await state.save(pick)
        XCTAssertEqual(writeRevisions, [6])
        XCTAssertEqual(state.value?.saveState, .failed(.other))
        XCTAssertEqual(state.value?.readState, .failed)
        XCTAssertEqual(state.value?.snapshot?.selection, otherPick)
        XCTAssertTrue(state.rows.contains { $0.id == otherPick && !$0.selected })

        await state.save(otherPick)
        XCTAssertEqual(operations, ["work_selection_read", "work_selection_set", "work_selection_read", "work_selection_set"])
        XCTAssertEqual(writeRevisions, [6, 7])
        XCTAssertEqual(state.value?.readySnapshot?.revision, 8)
        XCTAssertEqual(state.value?.readySnapshot?.selection, otherPick)
    }

    func testFailedReloadKeepsTheNameButRequiresAFreshRevisionForSaving() async {
        let state = picker([
            .init(200, #"{"revision":6,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}"#),
            .init(503, #"{"error":"matrix_503"}"#),
            .init(200, #"{"revision":7,"selection":null}"#),
            .init(200, #"{"revision":8,"provider":"atum-work","plan":"codex","model":"gpt-5.4"}"#)
        ], plans: [pick])
        await state.reload()
        await state.reload()
        XCTAssertEqual(state.value?.readState, .failed)
        XCTAssertEqual(state.value?.snapshot?.revision, 6)
        let cached = state.rows.filter { !$0.selectable }
        XCTAssertEqual(cached.map(\.id), [otherPick])
        XCTAssertFalse(cached.contains(where: \.selected))
        await state.save(pick)
        XCTAssertEqual(writeRevisions, [7])
        XCTAssertEqual(state.value?.readySnapshot?.selection, pick)
    }

    private func decode(_ body: String) throws -> WorkModelSelectionSnapshot {
        try NativeAPI.decode(WorkModelSelectionSnapshot.self, from: Data(body.utf8))
    }

    private func client(_ replies: [WorkSelectionFixture.Reply],
                        eligibility: [WorkSelectionFixture.Reply] = [.init(200, #"{"plans":[]}"#)])
        -> NativeDomainClient {
        WorkSelectionFixture.reset(replies, eligibility: eligibility)
        return NativeDomainClient(testAuthorization: { _ in "owner-fixture" }, protocolClasses: [WorkSelectionFixture.self])
    }

    private func picker(_ replies: [WorkSelectionFixture.Reply], plans: [WorkModelSelection],
                        isCurrent: @escaping NativeDispatchGate = { true }) -> PhoneModelPickerWorkSelection {
        PhoneModelPickerWorkSelection(agentPrincipal: agent, client: client(replies, eligibility: [eligibility(plans)]),
                                      isCurrent: isCurrent)
    }

    private func eligibility(_ choices: [WorkModelSelection]) -> WorkSelectionFixture.Reply {
        let plans = Dictionary(grouping: choices, by: \.plan).map { plan, choices in
            ["plan": plan.rawValue, "status": "selectable", "models": choices.map {
                ["id": $0.model, "displayName": $0.model]
            }] as [String: Any]
        }
        let body = try! JSONSerialization.data(withJSONObject: ["plans": plans])
        return .init(200, String(decoding: body, as: UTF8.self))
    }

    private func waitForSave(_ pick: WorkModelSelection, in state: PhoneModelPickerWorkSelection) async {
        for _ in 0..<100 {
            if state.value?.saveState == .saving(pick) { return }
            await Task.yield()
        }
        XCTFail("pick did not queue")
    }

    private var operations: [String] {
        WorkSelectionFixture.requests.compactMap { $0.body?["operation"] as? String }
            .filter { $0 != "work_plan_eligibility_read" }
    }

    private var writeRevisions: [Int] {
        WorkSelectionFixture.requests.compactMap { $0.body?["expectedRevision"] as? Int }
    }

    private var writeModels: [String] {
        WorkSelectionFixture.requests.compactMap { ($0.body?["selection"] as? [String: String])?["model"] }
    }

}

private final class HeldWorkReply: @unchecked Sendable {
    let arrived: XCTestExpectation
    private let lock = NSLock()
    private var reply: (() -> Void)?

    init(arrived: XCTestExpectation) { self.arrived = arrived }

    func hold(_ reply: @escaping () -> Void) {
        lock.withLock { self.reply = reply }
        arrived.fulfill()
    }

    func deliver() {
        let deliver = lock.withLock {
            let deliver = reply
            reply = nil
            return deliver
        }
        deliver?()
    }
}

private final class WorkSelectionFixture: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let body: Data
        let held: HeldWorkReply?
        static let conflict = Self(409, #"{"error":"matrix_409","details":{"reason":"selection_revision"}}"#)

        init(_ status: Int, _ body: String, held: HeldWorkReply? = nil) {
            self.status = status
            self.body = Data(body.utf8)
            self.held = held
        }
    }

    struct Request {
        let path: String?
        let method: String?
        let authorization: String?
        let deviceServicesVersion: String?
        let body: [String: Any]?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var replies: [Reply] = []
    private nonisolated(unsafe) static var eligibility: [Reply] = []
    private nonisolated(unsafe) static var observed: [Request] = []
    static var requests: [Request] { lock.withLock { observed } }

    static func reset(_ replies: [Reply], eligibility: [Reply]) {
        lock.withLock {
            observed = []
            self.replies = replies
            self.eligibility = eligibility
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let seen = Request(path: request.url?.path, method: request.httpMethod,
                           authorization: request.value(forHTTPHeaderField: "Authorization"),
                           deviceServicesVersion: request.value(forHTTPHeaderField: "Atum-Device-Service-Version"),
                           body: requestBody())
        let reply: Reply? = Self.lock.withLock {
            Self.observed.append(seen)
            if seen.body?["operation"] as? String == "work_plan_eligibility_read" {
                return Self.eligibility.count > 1 ? Self.eligibility.removeFirst() : Self.eligibility.first
            }
            return Self.replies.isEmpty ? nil : Self.replies.removeFirst()
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let respond = {
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status,
                                           httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if let held = reply.held { held.hold(respond) }
        else { respond() }
    }
    override func stopLoading() {}

    private func requestBody() -> [String: Any]? {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                data.append(bytes, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
