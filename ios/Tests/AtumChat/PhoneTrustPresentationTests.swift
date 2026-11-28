import AtumChat
import Foundation
import XCTest

final class PhoneTrustPresentationTests: XCTestCase {
    // MARK: S7

    func testEveryNativeStageMapsToOneScreen() {
        XCTAssertEqual(PhoneTrustSASScreen(stage: .idle), .start)
        XCTAssertEqual(PhoneTrustSASScreen(stage: .requested), .waiting)
        XCTAssertEqual(PhoneTrustSASScreen(stage: .accepted), .waiting)
        XCTAssertEqual(PhoneTrustSASScreen(stage: .incoming(deviceName: "Mac")), .incoming(deviceName: "Mac"))
        XCTAssertEqual(PhoneTrustSASScreen(stage: .comparing), .compare)
        XCTAssertEqual(PhoneTrustSASScreen(stage: .waitingForPeer), .confirming)
        XCTAssertEqual(PhoneTrustSASScreen(stage: .finished(.matched)), .confirmed)
        XCTAssertEqual(PhoneTrustSASScreen(stage: .finished(.cancelled)), .dismissed)
        XCTAssertEqual(PhoneTrustSASScreen(stage: .finished(.mismatch)), .ended(.mismatch))
        XCTAssertEqual(PhoneTrustSASScreen(stage: .finished(.peerCancelled)), .ended(.peerCancelled))
        XCTAssertEqual(PhoneTrustSASScreen(stage: .finished(.timedOut)), .ended(.timedOut))
        XCTAssertEqual(PhoneTrustSASScreen(stage: .finished(.unavailable)), .ended(.unavailable))
    }

    func testOnlyNativeCompletionConfirmsAndOnlyItOrCancelCloses() {
        let all: [PhoneTrustSASStage] = [
            .idle, .incoming(deviceName: nil), .requested, .accepted, .comparing, .waitingForPeer,
            .finished(.matched), .finished(.mismatch), .finished(.cancelled), .finished(.peerCancelled),
            .finished(.timedOut), .finished(.unavailable),
        ]
        let confirming = all.filter { PhoneTrustSASScreen(stage: $0) == .confirmed }
        XCTAssertEqual(confirming, [.finished(.matched)])
        let closing = all.filter { PhoneTrustSASScreen(stage: $0).closes }
        XCTAssertEqual(closing, [.finished(.matched), .finished(.cancelled)])
    }

    func testCancelIsNotOfferedAfterApproval() {
        XCTAssertTrue(PhoneTrustSASScreen.waiting.allowsCancel)
        XCTAssertTrue(PhoneTrustSASScreen.incoming(deviceName: nil).allowsCancel)
        XCTAssertTrue(PhoneTrustSASScreen.compare.allowsCancel)
        XCTAssertFalse(PhoneTrustSASScreen.confirming.allowsCancel)
        XCTAssertFalse(PhoneTrustSASScreen.confirmed.allowsCancel)
        XCTAssertFalse(PhoneTrustSASScreen.ended(.mismatch).allowsCancel)
    }

    func testEveryEndingOffersRetryAndTheRecoveryKey() {
        for reason in [PhoneTrustEndReason.mismatch, .peerCancelled, .timedOut, .unavailable] {
            XCTAssertTrue(PhoneTrustSASScreen.ended(reason).offersRetry)
            XCTAssertTrue(PhoneTrustSASScreen.ended(reason).offersRecoveryKey)
        }
        XCTAssertFalse(PhoneTrustSASScreen.compare.offersRetry)
        // The emoji decision is never crowded by an alternative.
        XCTAssertFalse(PhoneTrustSASScreen.compare.offersRecoveryKey)
        XCTAssertFalse(PhoneTrustSASScreen.incoming(deviceName: nil).offersRecoveryKey)
    }

    // MARK: S8

    func testSetupFailuresBecomeOneQuietOutcome() {
        XCTAssertEqual(PhoneTrustSetupOutcome(setupFailure: .verificationRequired), .verifyFirst)
        XCTAssertEqual(PhoneTrustSetupOutcome(setupFailure: .existingRecovery), .useExistingKey)
        XCTAssertEqual(PhoneTrustSetupOutcome(setupFailure: .crossSigningBootstrapUnavailable),
                       .setUpOnAnotherDevice)
        XCTAssertEqual(PhoneTrustSetupOutcome(setupFailure: .sessionUnavailable), .closed)
        XCTAssertEqual(PhoneTrustSetupOutcome(setupFailure: .busy), .retry(.busy))
        XCTAssertEqual(PhoneTrustSetupOutcome(setupFailure: .secureStorageUnavailable), .retry(.storage))
        XCTAssertEqual(PhoneTrustSetupOutcome(setupFailure: .recoveryNotReady), .retry(.notReady))
        XCTAssertEqual(PhoneTrustSetupOutcome(setupFailure: .other), .retry(.notReady))
    }

    func testExistingRecoveryIsNeverOfferedAsANewKey() {
        let outcome = PhoneTrustSetupOutcome(setupFailure: .existingRecovery)
        if case .key = outcome { XCTFail("an existing backup must be restored, not replaced") }
    }

    func testKeyRowResumesAPendingSaveBeforeAnythingElse() {
        let pending = UUID()
        XCTAssertEqual(PhoneTrustKeyStatus(recoveryEnabled: true, backupEnabled: true,
                                           recoveryKeyConfirmed: true, pendingSaveID: pending),
                       .notSaved(pending))
        XCTAssertEqual(PhoneTrustKeyStatus(recoveryEnabled: true, backupEnabled: true,
                                           recoveryKeyConfirmed: true, pendingSaveID: nil), .on)
        XCTAssertEqual(PhoneTrustKeyStatus(recoveryEnabled: true, backupEnabled: true,
                                           recoveryKeyConfirmed: false, pendingSaveID: nil), .onElsewhere)
        XCTAssertEqual(PhoneTrustKeyStatus(recoveryEnabled: false, backupEnabled: true,
                                           recoveryKeyConfirmed: false, pendingSaveID: nil), .onElsewhere)
        XCTAssertEqual(PhoneTrustKeyStatus(recoveryEnabled: false, backupEnabled: false,
                                           recoveryKeyConfirmed: false, pendingSaveID: nil), .notSetUp)
    }

    func testPasswordsLeadOnlyWhenTheConfirmedPlatformSaveIsAvailable() {
        let save = PhoneTrustKeyActions(platformSaveAvailable: true, copied: false)
        XCTAssertEqual(save.primary, .saveToPasswords)
        XCTAssertEqual(save.secondary, .copy)
        let saveAfterCopy = PhoneTrustKeyActions(platformSaveAvailable: true, copied: true)
        XCTAssertEqual(saveAfterCopy.primary, .saveToPasswords)
        XCTAssertEqual(saveAfterCopy.secondary, .confirmSaved)
    }

    func testManualFallbackNeedsAnExplicitConfirmationAfterCopy() {
        let fresh = PhoneTrustKeyActions(platformSaveAvailable: false, copied: false)
        XCTAssertEqual(fresh.primary, .copy)
        XCTAssertNil(fresh.secondary, "nothing can be confirmed before the key leaves the screen")
        let copied = PhoneTrustKeyActions(platformSaveAvailable: false, copied: true)
        XCTAssertEqual(copied.primary, .confirmSaved)
        XCTAssertEqual(copied.secondary, .copy)
    }

    func testPlatformSaveRequiresSystemSupportAndConfirmedScope() {
        XCTAssertTrue(PhoneTrustKeyActions.platformSaveAvailable(
            systemSupportsSave: true, scopeConfirmed: true, failedThisSession: false))
        XCTAssertFalse(PhoneTrustKeyActions.platformSaveAvailable(
            systemSupportsSave: false, scopeConfirmed: true, failedThisSession: false))
        XCTAssertFalse(PhoneTrustKeyActions.platformSaveAvailable(
            systemSupportsSave: true, scopeConfirmed: false, failedThisSession: false))
        XCTAssertFalse(PhoneTrustKeyActions.platformSaveAvailable(
            systemSupportsSave: true, scopeConfirmed: true, failedThisSession: true))
    }

    // MARK: S9

    func testPrivateIsHiddenUntilReadyAndNeverTeased() {
        XCTAssertFalse(PhoneTrustPrivateOption.isShown(canCreatePrivateChat: nil))
        XCTAssertFalse(PhoneTrustPrivateOption.isShown(canCreatePrivateChat: false))
        XCTAssertTrue(PhoneTrustPrivateOption.isShown(canCreatePrivateChat: true))
    }

    func testPrivateGroupRetryKeepsTheRequestIDForTheSameIntentOnly() {
        let first = UUID(), second = UUID(), third = UUID()
        var intent = PhoneTrustPrivateGroupIntent(name: "Trip", memberIDs: ["@a:x", "@b:x"], requestID: first)
        XCTAssertEqual(intent.requestID(name: "Trip", memberIDs: ["@b:x", "@a:x"], makeID: { second }), first)
        XCTAssertEqual(intent.requestID(name: "Trip!", memberIDs: ["@a:x", "@b:x"], makeID: { second }), second)
        XCTAssertEqual(intent.requestID(name: "Trip!", memberIDs: ["@a:x"], makeID: { third }), third)
        XCTAssertEqual(intent.requestID(name: "Trip!", memberIDs: ["@a:x"], makeID: { first }), third)
    }

    // MARK: Copy

    func testEveryPendingKeyHasEveryLocaleAndNoArgumentDrift() {
        XCTAssertEqual(Set(PhoneTrustPendingCopy.tables.keys), Set(PhoneTrustCopyKey.allCases.map(\.rawValue)))
        for key in PhoneTrustCopyKey.allCases {
            let english = PhoneTrustPendingCopy.text(key, locale: "en")
            for locale in PhoneTrustPendingCopy.locales {
                let value = PhoneTrustPendingCopy.tables[key.rawValue]?[locale] ?? ""
                XCTAssertFalse(value.isEmpty, "\(key) lacks \(locale)")
                XCTAssertEqual(value.contains("{0}"), english.contains("{0}"), "\(key) \(locale) argument")
            }
        }
    }

    func testCopyNeverMentionsDevicesTheAppCannotKnow() {
        // The requester cannot know which device answers (M4 drew "your Mac").
        for key in PhoneTrustCopyKey.allCases {
            let english = PhoneTrustPendingCopy.text(key, locale: "en")
            XCTAssertFalse(english.contains("Mac"), "\(key) names a device")
        }
        XCTAssertEqual(PhoneTrustPendingCopy.text(.privateLabel, locale: "fr"), "Private")
    }
}
