import AtumDesign
import XCTest
@testable import AtumMobile
@testable import AtumNativeAPI

/// W4-E6: what the app draws from the account registry. The registry's own
/// mapping is the package's (`AccountConnectionsTests`); these hold the app's
/// use of it: the picker offers Connect only after the read answered, the
/// words come from the pin, and the sheet's timings are the desktop's.
@MainActor
final class AccountConnectionsStateTests: XCTestCase {
    private func registry(_ plans: [AccountPlan: Bool]) -> AccountConnections {
        AccountConnections(connections: plans.map { plan, connected in
            AccountConnection(id: plan.rawValue, kind: .plan, status: connected ? .connected : .notConnected,
                              devices: connected ? [AccountConnectionDevice(
                                  deviceServiceID: "11111111-1111-4111-8111-11111111abcd",
                                  displayName: "MacBook Pro", stale: false, observedAt: 1)] : [])
        })
    }

    private func reads(registry: @escaping @MainActor () async -> AccountConnections?,
                       openCodeGo: ProviderConnectionsStatus? = nil) -> PhoneSubscriptionAccountReads {
        PhoneSubscriptionAccountReads(chatGPT: { nil }, openCodeGo: { openCodeGo }, accountConnections: registry)
    }

    private func actions(scope: UInt64 = 0, isCurrent: @escaping @MainActor () -> Bool = { true },
                         readiness: @escaping @MainActor () async -> WorkPlanReadinessRead = { .unavailable },
                         registry: @escaping @MainActor () async -> AccountConnections?) -> AccountConnectionsActions {
        AccountConnectionsActions(scope: .init(generation: scope, client: nil),
                                  isCurrent: isCurrent, read: registry, readReadiness: readiness,
                                  makePoll: {
                                      AccountPlanPoll(isCurrent: isCurrent, readReadiness: readiness,
                                                      readRegistry: registry)
                                  })
    }

    private func readiness(_ state: String = "ready",
                           checkedAt now: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) throws -> WorkPlanReadiness {
        let validity = state == "ready" ? ",\"validUntil\":\(now + 60_000)" : ""
        return try NativeAPI.decode(WorkPlanReadiness.self, from: Data("""
            {"profile":"atum.work-plan-readiness/1","checkedAt":\(now),"plans":{
                "codex":{"state":"not_connected"},"claude":{"state":"not_connected"},
                "antigravity":{"state":"\(state)"\(validity)}}}
            """.utf8))
    }

    func testThePickerOffersConnectOnlyOnceTheRegistryHasAnswered() {
        XCTAssertEqual(PhoneModelPickerList.planConnects(nil), [])
        XCTAssertEqual(PhoneModelPickerList.planConnects(PhoneSubscriptionAccount(chatGPT: nil, openCodeGo: nil)), [],
                       "an unread registry is not 'connected nowhere'")
        let account = PhoneSubscriptionAccount(chatGPT: nil, openCodeGo: nil,
                                               accountConnections: registry([.codex: true, .claude: false]))
        XCTAssertEqual(PhoneModelPickerList.planConnects(account), [.claude, .antigravity])
    }

    /// A plan the sheet saw land leaves the picker: the picker takes the
    /// sheet's registry, keeping the subscription statuses it already read.
    func testThePickerDropsConnectOnceThePlanLands() async {
        let state = PhoneModelPickerAccount()
        let before = registry([.codex: true, .claude: false])
        await state.reload(reads { before })
        XCTAssertEqual(PhoneModelPickerList.planConnects(state.value), [.claude, .antigravity])
        state.landed(registry([.codex: true, .claude: true]))
        XCTAssertEqual(PhoneModelPickerList.planConnects(state.value), [.antigravity])
    }

    func testARefusedPickRefreshCannotOfferConnectOverANewerAnswer() async {
        let state = PhoneModelPickerAccount()
        let connected = registry([.codex: true, .claude: true, .antigravity: true])
        let old = registry([.codex: true, .claude: false, .antigravity: true])
        await state.reload(reads {
            state.landed(connected)
            return old
        })
        XCTAssertEqual(PhoneModelPickerList.planConnects(state.value), [])
        await state.reload(reads { old })
        XCTAssertEqual(PhoneModelPickerList.planConnects(state.value), [.claude])
        // A landing during the read keeps the sheet's registry but still takes
        // the read's fresh subscription status (OpenCode Go disconnected elsewhere).
        let disconnected = try! NativeAPI.decode(ProviderConnectionsStatus.self, from: Data("""
            {"profile":"atum.provider-connections/1","revision":3,"connections":[{"provider":"opencode_go","state":"disconnected","revision":3,"models":[],"modelPolicy":"none"}]}
            """.utf8))
        await state.reload(reads(registry: {
            state.landed(connected)
            return old
        }, openCodeGo: disconnected))
        XCTAssertEqual(state.value?.openCodeGo, disconnected, "a landing must not drop the fresh OpenCode Go status")
        XCTAssertEqual(state.value?.accountConnections, connected)
        await state.reload(reads {
            await state.reload(self.reads { connected })
            return old
        })
        XCTAssertEqual(PhoneModelPickerList.planConnects(state.value), [])
    }

    /// Settings: a foreground refresh that read "Not connected" and finishes
    /// after the sheet saw the plan land must not undo the landing.
    func testALateRefreshNeverUndoesALanding() async throws {
        let model = AccountConnectionsModel()
        let old = registry([.antigravity: false])
        let newer = registry([.antigravity: true])
        let ready = try readiness()
        let currentActions = actions(readiness: { .available(ready) }) { newer }
        let landing = AccountPlanLanding(readiness: ready, registry: newer)
        // The sheet lands while the refresh is still reading.
        await model.reload(actions {
            model.applyReadiness(ready, actions: currentActions)
            XCTAssertTrue(model.landed(landing, actions: currentActions))
            return old
        })
        XCTAssertEqual(model.load, .loaded(newer))
        XCTAssertEqual(model.readiness, ready)
        // Nor does a failed refresh that was in flight.
        await model.reload(actions {
            XCTAssertTrue(model.landed(landing, actions: currentActions))
            return nil
        })
        XCTAssertEqual(model.load, .loaded(newer))
        XCTAssertEqual(model.readiness, ready)
        // Of two overlapping refreshes, the one that started last wins.
        await model.reload(actions {
            await model.reload(currentActions)
            return old
        })
        XCTAssertEqual(model.load, .loaded(newer))
        XCTAssertEqual(model.readiness, ready)
        // A refresh that starts after the landing applies as usual.
        await model.reload(actions { old })
        XCTAssertEqual(model.load, .loaded(old))
        XCTAssertNil(model.readiness)
    }

    func testLateReadinessAndLandingFromAnOldAccountAreDropped() async throws {
        let model = AccountConnectionsModel()
        let ready = try readiness()
        let oldRegistry = registry([.antigravity: true])
        let newRegistry = registry([.antigravity: false])
        let newActions = actions(scope: 2) { newRegistry }
        var oldAccountIsCurrent = true
        let oldActions = actions(scope: 1, isCurrent: { oldAccountIsCurrent }, readiness: {
            oldAccountIsCurrent = false
            await model.reload(newActions)
            return .available(ready)
        }) { oldRegistry }

        await model.reload(oldActions)
        XCTAssertEqual(model.scope, newActions.scope)
        XCTAssertEqual(model.load, .loaded(newRegistry))
        XCTAssertNil(model.readiness)
        model.applyReadiness(ready, actions: oldActions)
        XCTAssertFalse(model.landed(AccountPlanLanding(readiness: ready, registry: oldRegistry), actions: oldActions))
        XCTAssertEqual(model.load, .loaded(newRegistry))
        XCTAssertNil(model.readiness)
    }

    func testPollingFencesBothRepliesAndRequiresReadyWhenAvailable() async throws {
        let ready = try readiness()
        let missing = try readiness("grant_missing")
        var current = true
        var registryReads = 0
        var published: [WorkPlanReadiness] = []
        var landings: [AccountPlanLanding] = []
        let signIn = registry([.antigravity: true])
        let readRegistry: @MainActor () async -> AccountConnections? = { registryReads += 1; return signIn }
        let publish: @MainActor (WorkPlanReadiness) -> Void = { published.append($0) }
        let land: @MainActor (AccountPlanLanding) -> Bool = { landings.append($0); return true }

        let poll = AccountPlanPoll(isCurrent: { current }, readReadiness: { .available(missing) },
                                   readRegistry: readRegistry)
        let grantMissing = await poll.follow(.antigravity, onReadiness: publish, onLanded: land)
        XCTAssertFalse(grantMissing)
        XCTAssertEqual(registryReads, 0)
        XCTAssertEqual(published, [missing])
        let lateReadiness = AccountPlanPoll(isCurrent: { current }, readReadiness: {
            current = false
            return .available(ready)
        }, readRegistry: readRegistry)
        let retired = await lateReadiness.follow(.antigravity, onReadiness: publish, onLanded: land)
        XCTAssertFalse(retired)
        XCTAssertEqual(registryReads, 0)
        XCTAssertEqual(published, [missing])

        current = true
        let lateRegistry = AccountPlanPoll(isCurrent: { current }, readReadiness: { .available(ready) }, readRegistry: {
            current = false
            return await readRegistry()
        })
        let retiredDuringRegistry = await lateRegistry.follow(.antigravity, onReadiness: publish, onLanded: land)
        XCTAssertFalse(retiredDuringRegistry)
        XCTAssertEqual(registryReads, 1)
        XCTAssertEqual(published, [missing, ready])
        XCTAssertTrue(landings.isEmpty)

        current = true
        let registryUnavailable = AccountPlanPoll(isCurrent: { current }, readReadiness: { .available(ready) },
                                                  readRegistry: { nil })
        let landed = await registryUnavailable.follow(.antigravity, onReadiness: publish, onLanded: land)
        XCTAssertTrue(landed)
        XCTAssertEqual(landings.count, 1)
        XCTAssertEqual(landings.first?.readiness, ready)
        XCTAssertNil(landings.first?.registry)
    }

    func testUnsupportedReadinessStillFollowsMacSignInAndUpdatesThePicker() async throws {
        let client = NativeDomainClient(testAuthorization: { _ in
            XCTFail("A sheet read must use the stored bearer")
            return "fixture-legacy"
        }, protocolClasses: [ConnectionsStateProtocol.self], testStoredAuthorization: { "fixture-legacy" })
        let before = registry([.antigravity: false])
        let model = AccountConnectionsModel()
        let picker = PhoneModelPickerAccount()
        let currentActions = actions { before }
        await model.reload(currentActions)
        await picker.reload(reads { before })
        XCTAssertTrue(PhoneModelPickerList.planConnects(picker.value).contains(.antigravity))

        let poll = AccountPlanPoll(isCurrent: { true }, readReadiness: { await client.workPlanReadiness() },
                                   readRegistry: { try? await client.accountConnections(.poll) })
        let landed = await poll.follow(.antigravity, onReadiness: { _ in XCTFail("HTTP 400 has no readiness") },
                                       onLanded: { landing in
            XCTAssertNil(landing.readiness)
            if let registry = landing.registry { picker.landed(registry) }
            return model.landed(landing, actions: currentActions)
        })
        XCTAssertTrue(landed)
        XCTAssertFalse(PhoneModelPickerList.planConnects(picker.value).contains(.antigravity))
        let signedIn = try XCTUnwrap(picker.value?.accountConnections)
        XCTAssertEqual(model.load, .loaded(signedIn))
        XCTAssertNil(model.readiness)
        let row = AccountConnectionsView.planRow(signedIn, .antigravity, readiness: model.readiness)
        XCTAssertEqual(row.state, .signedIn)
        XCTAssertTrue(row.readinessUnknown)
    }

    func testForegroundReadinessUsesTheBearerAfterRegistryAuthorizationSettles() async throws {
        let rotating = expectation(description: "Registry is waiting for the replacement bearer")
        let gate = ConnectionsReadGate()
        var stored: String?
        var storedReads = 0
        let client = NativeDomainClient(testAuthorization: { forceRefresh in
            XCTAssertFalse(forceRefresh)
            rotating.fulfill()
            await gate.wait()
            stored = "fixture-renewed"
            return "fixture-renewed"
        }, protocolClasses: [ConnectionsStateProtocol.self], testStoredAuthorization: {
            storedReads += 1
            return stored
        })
        let model = AccountConnectionsModel()
        let currentActions = actions(readiness: { await client.workPlanReadiness() }) {
            try? await client.accountConnections()
        }
        let refresh = Task { await model.reload(currentActions) }
        await fulfillment(of: [rotating], timeout: 5)
        XCTAssertEqual(storedReads, 0)
        await gate.release()
        await refresh.value

        guard case .loaded = model.load else { return XCTFail("Registry failed after authorization") }
        XCTAssertEqual(storedReads, 1)
        XCTAssertTrue(AccountConnectionsView.connectLanded(model.readiness, plan: .antigravity))
    }

    func testNewerReadinessWhilePollRegistryIsHeldPreventsStaleLanding() async throws {
        let model = AccountConnectionsModel()
        let olderRegistry = registry([.antigravity: true])
        let newerRegistry = registry([.antigravity: false])
        let older = try readiness()
        let newer = try readiness("not_connected", checkedAt: older.checkedAt + 1)
        let currentActions = actions { newerRegistry }
        await model.reload(currentActions)

        let registryStarted = expectation(description: "Poll registry is in flight")
        let gate = ConnectionsReadGate()
        let poll = AccountPlanPoll(isCurrent: { true }, readReadiness: { .available(older) }, readRegistry: {
            registryStarted.fulfill()
            await gate.wait()
            return olderRegistry
        })
        let follow = Task {
            await poll.follow(.antigravity, onReadiness: { model.applyReadiness($0, actions: currentActions) },
                              onLanded: { model.landed($0, actions: currentActions) })
        }
        await fulfillment(of: [registryStarted], timeout: 5)
        XCTAssertEqual(model.readiness, older, "Readiness publishes while the registry is held")
        await model.reload(actions(readiness: { .available(newer) }) { newerRegistry })
        await gate.release()
        let landed = await follow.value
        XCTAssertFalse(landed, "The sheet must not announce a superseded confirmation")
        model.applyReadiness(older, actions: currentActions)
        XCTAssertEqual(model.readiness, newer)
        XCTAssertEqual(model.load, .loaded(newerRegistry))
    }

    func testReadinessLeavesTheRegistryRetryAndToolRowsAvailable() async throws {
        let model = AccountConnectionsModel()
        let ready = try readiness()
        let failedRegistry = actions(readiness: { .available(ready) }) { nil }
        await model.reload(failedRegistry)
        let firstFailure = AccountConnectionsContent(load: model.load, readiness: model.readiness)
        XCTAssertTrue(firstFailure.showsRetry)
        XCTAssertTrue(firstFailure.showsPlans)
        XCTAssertEqual(firstFailure.openCodeGoLine, AccountConnectionsCopy.readFailed)
        XCTAssertEqual(firstFailure.toolRows, [.ownerChats])

        let connections = AccountConnections(connections: [
            AccountConnection(id: "opencode_go", kind: .apiKey, status: .connected),
            AccountConnection(id: "home_hub:strap", kind: .tools, status: .connected),
        ])
        await model.reload(actions(readiness: { .available(ready) }) { connections })
        await model.reload(failedRegistry)
        let laterFailure = AccountConnectionsContent(load: model.load, readiness: model.readiness)
        XCTAssertFalse(laterFailure.showsRetry)
        XCTAssertTrue(laterFailure.showsPlans)
        XCTAssertEqual(laterFailure.openCodeGoLine, AccountConnectionsCopy.inCloud)
        XCTAssertEqual(laterFailure.toolRows, [.ownerChats, .homeHub(id: "home_hub:strap", name: "Strap", connected: true)])
    }

    func testTheConnectSheetFollowsAtTheDesktopsPace() {
        XCTAssertEqual(AccountPlanConnectSheet.pollInterval, .seconds(3))
        XCTAssertEqual(AccountPlanConnectSheet.waitLimit, .seconds(600))
        XCTAssertEqual(AccountPlanConnectSheet.doneBeat, .milliseconds(2_500))
    }

    func testEveryWordTheSectionsDrawComesFromThePin() throws {
        let design = try LiveDesign()
        let rows = AccountConnectionsView.planRows(registry([.codex: true]))
        for row in rows {
            let line = AccountConnectionsWords.text(AccountConnectionsCopy.line(AccountConnectionsView.line(row)),
                                                    design: design)
            XCTAssertFalse(line.isEmpty)
            XCTAssertFalse(line.contains("%"))
            XCTAssertFalse(AccountConnectionsWords.text(AccountConnectionsCopy.sheetTitle(row.plan), design: design).isEmpty)
        }
        XCTAssertEqual(rows.first.map(AccountConnectionsView.line), .onMacs("MacBook Pro"))
    }
}

private actor ConnectionsReadGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class ConnectionsStateProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let status: Int
        let response: String
        switch (request.value(forHTTPHeaderField: "Authorization"), body()) {
        case ("Bearer fixture-legacy", WorkPlanReadinessContract.requestBody):
            status = 400
            response = #"{"error":"matrix_400"}"#
        case ("Bearer fixture-renewed", WorkPlanReadinessContract.requestBody):
            status = 200
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            response = """
            {"profile":"atum.work-plan-readiness/1","checkedAt":\(now),"plans":{
                "codex":{"state":"not_connected"},"claude":{"state":"not_connected"},
                "antigravity":{"state":"ready","validUntil":\(now + 60_000)}}}
            """
        case ("Bearer fixture-legacy", AccountConnectionsContract.requestBody),
             ("Bearer fixture-renewed", AccountConnectionsContract.requestBody):
            status = 200
            response = """
            {"profile":"atum.account-connections/1","connections":[
                {"id":"antigravity","kind":"plan","provider":"antigravity","custody":"device","status":"connected",
                 "devices":[{"deviceServiceId":"11111111-1111-4111-8111-11111111abcd","displayName":"MacBook Pro",
                             "status":"connected","observedAt":1}],
                 "models":[],"reach":{"chat":"relay","work":"native","agents":"all"}}]}
            """
        default:
            XCTFail("Unexpected device-services request")
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                             headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func body() -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: 4_096)
            if count <= 0 { break }
            body.append(contentsOf: bytes.prefix(count))
        }
        return body
    }
}
