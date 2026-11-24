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
