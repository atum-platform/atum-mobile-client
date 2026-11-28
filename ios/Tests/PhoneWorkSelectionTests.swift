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

    func testSaveReadsMissingRevisionAndRetriesAnAdvancedConflictOnce() async {
        let state = await picker([
            .init(200, #"{"revision":0,"selection":null}"#), .conflict,
            .init(200, #"{"revision":2,"selection":null}"#),
            .init(200, #"{"revision":3,"provider":"atum-work","plan":"codex","model":"gpt-5.4"}"#)
        ], plans: [pick])
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
        let state = await picker([winner, .conflict, winner], plans: [pick])
        await state.reload()
        await state.save(pick)
        XCTAssertEqual(writeRevisions, [4])
        XCTAssertEqual(operations.last, "work_selection_read")
        XCTAssertEqual(state.value?.readySnapshot?.selection, otherPick)
        XCTAssertEqual(state.value?.saveState, .failed(.conflict))
    }

    func testSecondConflictReadsTheWinnerWithoutAThirdWrite() async {
        let state = await picker([
            .init(200, #"{"revision":1,"selection":null}"#), .conflict,
            .init(200, #"{"revision":2,"selection":null}"#), .conflict,
            .init(200, #"{"revision":3,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}"#)
        ], plans: [pick])
        await state.save(pick)
        XCTAssertEqual(writeRevisions, [1, 2])
        XCTAssertEqual(operations.last, "work_selection_read")
        XCTAssertEqual(state.value?.readySnapshot?.revision, 3)
        XCTAssertEqual(state.value?.readySnapshot?.selection, otherPick)
        XCTAssertEqual(state.value?.saveState, .failed(.conflict))
    }

    func testNewPickDropsAStaleConflictReadAndRetry() async {
        let pending = HeldWorkReply(arrived: expectation(description: "old pick's conflict reread"))
        let state = await picker([
            .init(200, #"{"revision":4,"selection":null}"#), .conflict,
            .init(200, #"{"revision":5,"selection":null}"#, held: pending),
            .init(200, #"{"revision":6,"selection":null}"#),
            .init(200, #"{"revision":7,"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}"#)
        ], plans: [pick, otherPick])
        let old = Task { await state.save(pick) }
        await fulfillment(of: [pending.arrived], timeout: 2)
        XCTAssertEqual(state.value?.readState, .loading)
        XCTAssertEqual(state.value?.saveState, .saving(pick))
        await state.save(otherPick)
        pending.deliver()
        await old.value
        XCTAssertEqual(writeRevisions, [4, 6])
        XCTAssertEqual(state.value?.readySnapshot?.selection, otherPick)
        XCTAssertEqual(state.value?.readySnapshot?.revision, 7)
        XCTAssertEqual(state.value?.saveState, .idle)
    }

    func testAccountSwitchDiscardsAnInFlightConflictReadAndPreventsRetry() async {
        let pending = HeldWorkReply(arrived: expectation(description: "old account's conflict reread"))
        var accountGeneration = 1
        let state = await picker([
            .init(200, #"{"revision":2,"selection":null}"#), .conflict,
            .init(200, #"{"revision":3,"selection":null}"#, held: pending)
        ], plans: [pick], isCurrent: { accountGeneration == 1 })
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
        let account = PhoneModelPickerAccount()
        let first = PhoneModelPickerWorkSelection(agentPrincipal: agent, client: client,
                                                   account: account,
                                                   isCurrent: { activeAgent == self.agent })
        let read = Task { await first.reload() }
        await fulfillment(of: [pending.arrived], timeout: 2)
        activeAgent = otherAgent
        let second = PhoneModelPickerWorkSelection(agentPrincipal: otherAgent, client: client,
                                                    account: account,
                                                    isCurrent: { activeAgent == self.otherAgent })
        await second.reload()
        pending.deliver()
        await read.value
        XCTAssertNil(first.value)
        XCTAssertEqual(second.value?.snapshot?.revision, 9)
        XCTAssertEqual(WorkSelectionFixture.requests.compactMap { $0.body?["agentPrincipal"] as? String },
                       [agent.rawValue, otherAgent.rawValue])
    }

    func testPickerUsesTheSharedCatalogAndAllowsTheLastConnectedMacPlan() async {
        let account = PhoneModelPickerAccount()
        let client = client([
            .init(200, #"{"revision":6,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}"#),
            .init(200, #"{"revision":7,"provider":"atum-work","plan":"codex","model":"gpt-5.4"}"#)
        ])
        let state = PhoneModelPickerWorkSelection(agentPrincipal: agent, client: client,
                                                  account: account, isCurrent: { true })
        await state.save(pick) // No preread either.
        XCTAssertTrue(operations.isEmpty)
        await state.reload()

        let registry = catalog([pick], stale: true)
        await account.reload(.init(chatGPT: { nil }, openCodeGo: { nil }, accountConnections: { registry }))
        XCTAssertEqual(state.rows.filter(\.selectable).map(\.id), [pick])
        let saved = state.rows.filter(\.selected)
        XCTAssertEqual(saved.map(\.id), [otherPick])
        XCTAssertEqual(saved.first?.displayName,
                       "Claude · \(ModelDisplayName.destinationLabel(model: otherPick.model))")
        await state.save(otherPick)
        XCTAssertEqual(operations, ["work_selection_read"])
        await state.save(pick)
        XCTAssertEqual(writeRevisions, [6])
        XCTAssertEqual(state.rows.filter(\.selected).map(\.id), [pick])

        let sameModelOtherPlan = WorkModelSelection(plan: .claude, model: pick.model)!
        account.landed(catalog([pick, sameModelOtherPlan]))
        XCTAssertEqual(state.rows.filter(\.selectable).map(\.id), [pick, sameModelOtherPlan])
        XCTAssertEqual(state.rows.filter(\.selected).map(\.id), [pick])

        account.landed(AccountConnections(connections: []))
        XCTAssertTrue(state.rows.filter(\.selectable).isEmpty)
        await state.save(pick)
        XCTAssertEqual(writeRevisions, [6])
    }

    func testEligibilityIsRecheckedBeforeAnAuthorizationReplay() async {
        var onRefresh: (() -> Void)?
        let client = client([
            .init(200, #"{"revision":0,"selection":null}"#),
            .init(401, #"{"error":"matrix_401"}"#)
        ], authorization: { refresh in
            if refresh { onRefresh?() }
            return "owner-fixture"
        })
        let account = await pickerAccount(plans: [pick])
        let state = PhoneModelPickerWorkSelection(agentPrincipal: agent, client: client,
                                                  account: account, isCurrent: { true })
        onRefresh = { account.landed(AccountConnections(connections: [])) }
        await state.save(pick)
        XCTAssertEqual(operations, ["work_selection_read", "work_selection_set"])
        XCTAssertEqual(state.value?.eligibility, .known([]))
        XCTAssertEqual(state.value?.saveState, .idle)
    }

    func testAmbiguousWriteFailureKeepsTheNameAndRequiresAFreshRevision() async {
        let state = await picker([
            .init(200, #"{"revision":6,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}"#),
            .init(503, "unavailable"),
            .init(200, #"{"revision":7,"selection":{"provider":"atum-work","plan":"codex","model":"gpt-5.4"}}"#),
            .init(200, #"{"revision":8,"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}"#)
        ], plans: [pick, otherPick])
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
        let state = await picker([
            .init(200, #"{"revision":6,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}"#),
            .init(503, #"{"error":"matrix_503"}"#),
            .init(200, #"{"revision":7,"selection":null}"#),
            .init(200, #"{"revision":8,"provider":"atum-work","plan":"codex","model":"gpt-5.4"}"#)
        ], plans: [pick])
        await state.reload()
        await state.reload()
        XCTAssertEqual(state.value?.readState, .failed)
        XCTAssertEqual(state.value?.snapshot?.revision, 6)
        let cached = PhoneModelPickerProjection.workRows(reported: [], state: state.value)
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
                        authorization: @escaping @MainActor (Bool) -> String = { _ in "owner-fixture" })
        -> NativeDomainClient {
        WorkSelectionFixture.reset(replies)
        return NativeDomainClient(testAuthorization: { authorization($0) }, protocolClasses: [WorkSelectionFixture.self])
    }

    private func picker(_ replies: [WorkSelectionFixture.Reply], plans: [WorkModelSelection],
                        isCurrent: @escaping NativeDispatchGate = { true }) async -> PhoneModelPickerWorkSelection {
        let account = await pickerAccount(plans: plans)
        return PhoneModelPickerWorkSelection(agentPrincipal: agent, client: client(replies),
                                             account: account, isCurrent: isCurrent)
    }

    private func pickerAccount(plans: [WorkModelSelection]) async -> PhoneModelPickerAccount {
        let account = PhoneModelPickerAccount()
        let registry = catalog(plans)
        await account.reload(.init(chatGPT: { nil }, openCodeGo: { nil }, accountConnections: { registry }))
        return account
    }

    private func catalog(_ choices: [WorkModelSelection], stale: Bool = false) -> AccountConnections {
        let mac = AccountConnectionDevice(deviceServiceID: "mac", displayName: "Mac", stale: stale, observedAt: 1)
        return AccountConnections(connections: Dictionary(grouping: choices, by: \.plan).map { plan, choices in
            AccountConnection(id: plan.rawValue, kind: .plan, status: .connected, devices: [mac],
                              models: choices.map { .init(id: $0.model, displayName: $0.model) })
        })
    }

    private var operations: [String] {
        WorkSelectionFixture.requests.compactMap { $0.body?["operation"] as? String }
    }

    private var writeRevisions: [Int] {
        WorkSelectionFixture.requests.compactMap { $0.body?["expectedRevision"] as? Int }
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
    private nonisolated(unsafe) static var observed: [Request] = []
    static var requests: [Request] { lock.withLock { observed } }

    static func reset(_ replies: [Reply]) {
        lock.withLock {
            observed = []
            self.replies = replies
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
