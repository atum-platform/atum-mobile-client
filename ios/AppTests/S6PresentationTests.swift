@testable import AtumMobile
import AtumChat
import AtumNativeAPI
import Foundation
import XCTest

final class S6PresentationTests: XCTestCase {
    @MainActor
    func testSignInFailureIsVisibleUnlessThePersonCancels() {
        XCTAssertEqual(LiveAppModel.initialNotice(OIDCFailure.authorizationDenied), .cancelled)
        XCTAssertEqual(LiveAppModel.initialNotice(OIDCFailure.browserUnavailable), .cancelled)
        XCTAssertEqual(LiveAppModel.initialNotice(URLError(.notConnectedToInternet)), .failed)
        XCTAssertEqual(LiveAppModel.initialNotice(OIDCFailure.invalidToken), .failed)
        XCTAssertEqual(LiveSignInNotice.failed.welcomePresentation, .failed)
        XCTAssertEqual(LiveSignInNotice.cancelled.welcomePresentation, .cancelled)
    }

    @MainActor
    func testMessageActionsOverlayCoversTheChat() {
        let presenter = MessageActionsPresenter()
        XCTAssertFalse(presenter.covers)

        let row = ChatRow(item: ChatItem(id: "m1", kind: .message, sender: "@ann:atum.test", body: "Hi"))
        presenter.actionsOverlay = MessageOverlayRequest(row: row, kind: .person, roomTitle: "Ann",
                                                         ownUserID: nil, parsedBody: nil,
                                                         items: [.react, .reply, .copy], sourceFrame: .zero)
        XCTAssertTrue(presenter.covers)

        presenter.actionsOverlay = nil
        XCTAssertFalse(presenter.covers)
    }

    func testRecoveryKeyGroupsOnlyWhileActiveAndRedactsEveryCharacterOtherwise() {
        let key = "SYNTH ETIC RECO VERY KEY1"
        XCTAssertEqual(RecoveryKeyDisplay.value(key, sceneIsActive: true),
                       "SYNT HETI CREC OVER YKEY 1")
        let hidden = RecoveryKeyDisplay.value(key, sceneIsActive: false)
        XCTAssertEqual(hidden, "•••• •••• •••• •••• •••• •")
        XCTAssertFalse(hidden.contains("S"))
        XCTAssertFalse(hidden.contains("1"))
    }

    func testAccountHandleNeverExposesTheServerPart() {
        let value = AccountPresentation(
            matrixUserID: "@an:atum.invalid", displayName: "An",
            offersHistoryRecovery: false, holdsRecoveryKey: false,
            recoveryKeySavedOnThisPhone: false, signOutInProgress: false,
            signOutFailureToken: 0, version: "1.0"
        )
        XCTAssertEqual(value.localHandle, "@an")
        XCTAssertFalse(value.localHandle.contains(":"))
    }

    func testContextlessStatusEscapeCannotOrphanAnUnsavedRecoveryKey() {
        XCTAssertTrue(StatusRecoverySignOutPolicy.requiresSave(hasRecoveryKey: true,
                                                               saved: false))
        XCTAssertFalse(StatusRecoverySignOutPolicy.authorizesArchive(
            hasRecoveryKey: true, saved: false, confirmedSaved: false
        ))
        XCTAssertTrue(StatusRecoverySignOutPolicy.authorizesArchive(
            hasRecoveryKey: true, saved: false, confirmedSaved: true
        ))
        XCTAssertTrue(StatusRecoverySignOutPolicy.authorizesArchive(
            hasRecoveryKey: true, saved: true, confirmedSaved: false
        ))
        XCTAssertTrue(StatusRecoverySignOutPolicy.authorizesArchive(
            hasRecoveryKey: false, saved: false, confirmedSaved: false
        ))
    }
}
