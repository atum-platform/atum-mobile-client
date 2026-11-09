import XCTest
@testable import AtumChat

final class S6SystemPolicyTests: XCTestCase {
    func testAccountShowsOnlyTheHighestPriorityRecoveryRow() {
        XCTAssertEqual(AccountRecoverySlot.decide(offersHistoryRecovery: true,
                                                  holdsRecoveryKey: true), .restoreMessages)
        XCTAssertEqual(AccountRecoverySlot.decide(offersHistoryRecovery: false,
                                                  holdsRecoveryKey: true), .recoveryKey)
        XCTAssertNil(AccountRecoverySlot.decide(offersHistoryRecovery: false,
                                                holdsRecoveryKey: false))
    }

    func testSignOutRequiresTheSaveSheetOnlyForAnUnconfirmedHeldKey() {
        XCTAssertEqual(SignOutPrompt.decide(holdsRecoveryKey: true,
                                            confirmedSavedOnThisPhone: false), .saveRecoveryKey)
        XCTAssertEqual(SignOutPrompt.decide(holdsRecoveryKey: true,
                                            confirmedSavedOnThisPhone: true), .confirmation)
        XCTAssertEqual(SignOutPrompt.decide(holdsRecoveryKey: false,
                                            confirmedSavedOnThisPhone: false), .confirmation)
    }

    func testRestoreFailureKeepsTheEnteredKeyAndOnlyWorkingBlocksDismissal() {
        XCTAssertTrue(RestoreMessagesState.rejected.keepsEnteredKey)
        XCTAssertTrue(RestoreMessagesState.failed.keepsEnteredKey)
        XCTAssertFalse(RestoreMessagesState.done.keepsEnteredKey)
        XCTAssertTrue(RestoreMessagesState.working.dismissIsDisabled)
        XCTAssertFalse(RestoreMessagesState.idle.dismissIsDisabled)
    }

    func testBusyWelcomeIsTheOnlyStateThatRejectsAnotherTap() {
        XCTAssertFalse(WelcomePresentation.busy.acceptsSignInTap)
        for state in [WelcomePresentation.idle, .cancelled, .registrationClosed, .failed, .expired] {
            XCTAssertTrue(state.acceptsSignInTap)
        }
    }

    func testSignInAttemptIsSingleFlightAndFailureReturnsToContinue() {
        var gate = SignInAttemptGate()
        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isInProgress)
        XCTAssertEqual(gate.presentation, .busy)
        XCTAssertFalse(gate.begin(), "a second tap never starts another browser flow")

        gate.finish(.failed)
        XCTAssertFalse(gate.isInProgress)
        XCTAssertEqual(gate.presentation, .failed)
        XCTAssertTrue(gate.presentation.acceptsSignInTap)
        XCTAssertTrue(gate.begin(), "the one Continue action is available again after failure")

        gate.finish(.cancelled)
        XCTAssertEqual(gate.presentation, .cancelled)
        XCTAssertTrue(gate.presentation.acceptsSignInTap)
    }
}

