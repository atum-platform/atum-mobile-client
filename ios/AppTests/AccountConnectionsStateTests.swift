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
        let before = PhoneSubscriptionAccount(chatGPT: nil, openCodeGo: nil,
                                              accountConnections: registry([.codex: true, .claude: false]))
        await state.reload { before }
        XCTAssertEqual(PhoneModelPickerList.planConnects(state.value), [.claude, .antigravity])
        state.landed(registry([.codex: true, .claude: true]))
        XCTAssertEqual(PhoneModelPickerList.planConnects(state.value), [.antigravity])
    }

    func testARefusedPickRefreshCannotOfferConnectOverANewerAnswer() async {
        let state = PhoneModelPickerAccount()
        let connected = registry([.codex: true, .claude: true, .antigravity: true])
        let newer = PhoneSubscriptionAccount(chatGPT: nil, openCodeGo: nil, accountConnections: connected)
        let old = PhoneSubscriptionAccount(chatGPT: nil, openCodeGo: nil,
                                           accountConnections: registry([.codex: true, .claude: false, .antigravity: true]))
        await state.reload {
            state.landed(connected)
            return old
        }
        XCTAssertEqual(PhoneModelPickerList.planConnects(state.value), [])
        await state.reload { old }
        XCTAssertEqual(PhoneModelPickerList.planConnects(state.value), [.claude])
        // A landing during the read keeps the sheet's registry but still takes
        // the read's fresh subscription status (OpenCode Go disconnected elsewhere).
        let disconnected = try! NativeAPI.decode(ProviderConnectionsStatus.self, from: Data("""
            {"profile":"atum.provider-connections/1","revision":3,"connections":[{"provider":"opencode_go","state":"disconnected","revision":3,"models":[],"modelPolicy":"none"}]}
            """.utf8))
        await state.reload {
            state.landed(connected)
            return PhoneSubscriptionAccount(chatGPT: nil, openCodeGo: disconnected, accountConnections: old.accountConnections)
        }
        XCTAssertEqual(state.value?.openCodeGo, disconnected, "a landing must not drop the fresh OpenCode Go status")
        XCTAssertEqual(state.value?.accountConnections, connected)
        await state.reload {
            await state.reload { newer }
            return old
        }
        XCTAssertEqual(PhoneModelPickerList.planConnects(state.value), [])
    }

    /// Settings: a foreground refresh that read "Not connected" and finishes
    /// after the sheet saw the plan land must not undo the landing.
    func testALateRefreshNeverUndoesALanding() async {
        let model = AccountConnectionsModel()
        let old = registry([.antigravity: false])
        let newer = registry([.antigravity: true])
        // The sheet lands while the refresh is still reading.
        await model.reload { model.landed(newer); return old }
        XCTAssertEqual(model.load, .loaded(newer))
        // Nor does a failed refresh that was in flight.
        await model.reload { model.landed(newer); return nil }
        XCTAssertEqual(model.load, .loaded(newer))
        // Of two overlapping refreshes, the one that started last wins.
        await model.reload {
            await model.reload { newer }
            return old
        }
        XCTAssertEqual(model.load, .loaded(newer))
        // A refresh that starts after the landing applies as usual.
        await model.reload { old }
        XCTAssertEqual(model.load, .loaded(old))
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
