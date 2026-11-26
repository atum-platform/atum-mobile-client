import Foundation
import XCTest
@testable import AtumNativeAPI

@available(macOS 14.0, *)
@MainActor final class AccountBetaFeaturesTests: XCTestCase {
    private let first = "@beta:example.test"
    private let second = "@public:example.test"

    private func defaults() throws -> UserDefaults {
        let suite = "AccountBetaFeaturesTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testRestoredAccountKeepsLastAnswerWhenMeFailsAndStoresRevocation() async throws {
        let defaults = try defaults()
        let initial = AccountBetaFeatures(defaults: defaults)
        initial.beginAccountScope(first)
        XCTAssertFalse(initial.isEnabled)
        initial.record(true)

        let restored = AccountBetaFeatures(defaults: defaults)
        restored.beginAccountScope(first)
        XCTAssertTrue(restored.isEnabled)
        await restored.refresh { throw URLError(.notConnectedToInternet) }
        XCTAssertTrue(restored.isEnabled)

        await restored.refresh { false }
        XCTAssertFalse(restored.isEnabled)
        let relaunched = AccountBetaFeatures(defaults: defaults)
        relaunched.beginAccountScope(first)
        XCTAssertFalse(relaunched.isEnabled)
    }

    func testSignOutClearsActiveValueAndRejectsLateAnswerWhenSameAccountReturns() async throws {
        let state = AccountBetaFeatures(defaults: try defaults())
        state.beginAccountScope(first)
        state.record(true)

        await state.refresh {
            state.endAccountScope()
            XCTAssertFalse(state.isEnabled)
            state.beginAccountScope(first)
            return false
        }
        XCTAssertTrue(state.isEnabled)
    }

    func testSwitchingAccountsLoadsOnlyTheirOwnCachedAnswer() async throws {
        let state = AccountBetaFeatures(defaults: try defaults())
        state.beginAccountScope(first)
        state.record(true)

        await state.refresh {
            state.beginAccountScope(second)
            return true
        }
        XCTAssertFalse(state.isEnabled)
        await state.refresh { throw URLError(.notConnectedToInternet) }
        XCTAssertFalse(state.isEnabled)
        state.beginAccountScope(first)
        XCTAssertTrue(state.isEnabled)
    }
}
