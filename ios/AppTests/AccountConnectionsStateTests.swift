import AtumDesign
import AtumNativeAPI
import XCTest
@testable import AtumMobile

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

    private func readiness(_ state: String = "ready") throws -> WorkPlanReadiness {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
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
            model.landed(landing, actions: currentActions)
            return old
        })
        XCTAssertEqual(model.load, .loaded(newer))
        XCTAssertEqual(model.readiness, ready)
        // Nor does a failed refresh that was in flight.
        await model.reload(actions {
            model.landed(landing, actions: currentActions)
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
        model.landed(AccountPlanLanding(readiness: ready, registry: oldRegistry), actions: oldActions)
        XCTAssertEqual(model.load, .loaded(newRegistry))
        XCTAssertNil(model.readiness)
    }

    func testPollingRequiresReadyAndFencesBothReplies() async throws {
        let ready = try readiness()
        let missing = try readiness("grant_missing")
        var current = true
        var registryReads = 0
        let signIn = registry([.antigravity: true])
        let readRegistry: @MainActor () async -> AccountConnections? = { registryReads += 1; return signIn }

        for result: WorkPlanReadinessRead in [.unavailable, .available(missing)] {
            let poll = AccountPlanPoll(isCurrent: { current }, readReadiness: { result }, readRegistry: readRegistry)
            let landing = await poll.landing(for: .antigravity)
            XCTAssertNil(landing)
        }
        XCTAssertEqual(registryReads, 0)
        let lateReadiness = AccountPlanPoll(isCurrent: { current }, readReadiness: {
            current = false
            return .available(ready)
        }, readRegistry: readRegistry)
        let retired = await lateReadiness.landing(for: .antigravity)
        XCTAssertNil(retired)
        XCTAssertEqual(registryReads, 0)

        current = true
        let lateRegistry = AccountPlanPoll(isCurrent: { current }, readReadiness: { .available(ready) }, readRegistry: {
            current = false
            return await readRegistry()
        })
        let retiredDuringRegistry = await lateRegistry.landing(for: .antigravity)
        XCTAssertNil(retiredDuringRegistry)
        XCTAssertEqual(registryReads, 1)

        current = true
        let registryUnavailable = AccountPlanPoll(isCurrent: { current }, readReadiness: { .available(ready) },
                                                  readRegistry: { nil })
        let landing = await registryUnavailable.landing(for: .antigravity)
        XCTAssertEqual(landing?.readiness, ready)
        XCTAssertNil(landing?.registry)
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
