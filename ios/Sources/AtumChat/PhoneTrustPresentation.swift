import Foundation

// Phone trust presentation (chat parity S7–S9, mockup M4). Pure rules the
// Security screens draw from: which screen a native verification or recovery
// state shows, which actions it offers, and when the Private choice appears.
// No SDK, no SwiftUI. The app maps its Matrix engine states onto these inputs.

// MARK: - S7 · Emoji verification

/// The native self-verification stage, as `MatrixSASVerification.State`
/// reports it, without the attempt IDs or emoji payload.
public enum PhoneTrustSASStage: Equatable, Sendable {
    case idle
    case incoming(deviceName: String?)
    case requested
    case accepted
    case comparing
    case waitingForPeer
    case finished(PhoneTrustSASOutcome)
}

public enum PhoneTrustSASOutcome: Equatable, Sendable {
    case matched, mismatch, cancelled, peerCancelled, timedOut, unavailable
}

/// Why a verification ended without confirming this phone. Each reason is the
/// same calm screen with a different line (M4 notes: mismatch, peer cancel and
/// timeout share one screen).
public enum PhoneTrustEndReason: Equatable, Sendable {
    case mismatch, peerCancelled, timedOut, unavailable
}

/// What the verification screen draws.
public enum PhoneTrustSASScreen: Equatable, Sendable {
    /// Before the person asked to start: one action, Start.
    case start
    /// "Confirm this iPhone": the request is out, the other device answers.
    case waiting
    /// Another of the account's own devices asked to confirm this phone.
    case incoming(deviceName: String?)
    /// The seven emoji with They match / They don't match.
    case compare
    /// This phone approved. The other device still has to finish.
    case confirming
    /// Native completion: the screen closes and a short toast confirms.
    case confirmed
    case ended(PhoneTrustEndReason)
    /// The person cancelled: the screen closes with nothing more to say.
    case dismissed

    public init(stage: PhoneTrustSASStage) {
        switch stage {
        case .idle: self = .start
        case .requested, .accepted: self = .waiting
        case let .incoming(name): self = .incoming(deviceName: name)
        case .comparing: self = .compare
        case .waitingForPeer: self = .confirming
        case let .finished(outcome):
            switch outcome {
            case .matched: self = .confirmed
            case .cancelled: self = .dismissed
            case .mismatch: self = .ended(.mismatch)
            case .peerCancelled: self = .ended(.peerCancelled)
            case .timedOut: self = .ended(.timedOut)
            case .unavailable: self = .ended(.unavailable)
            }
        }
    }

    /// A Cancel control is shown only while cancelling still means something.
    /// After They match, the native approval is committed and a concurrent
    /// peer completion may already have landed, so cancel is not offered;
    /// the engine's own deadline still ends a stalled attempt.
    public var allowsCancel: Bool {
        switch self {
        case .waiting, .incoming, .compare: true
        case .start, .confirming, .confirmed, .ended, .dismissed: false
        }
    }

    /// Try again starts a fresh attempt from this phone.
    public var offersRetry: Bool {
        if case .ended = self { return true }
        return false
    }

    /// The recovery key is the only alternative to a second device (M4 §1).
    public var offersRecoveryKey: Bool {
        switch self {
        case .start, .waiting, .ended: true
        case .incoming, .compare, .confirming, .confirmed, .dismissed: false
        }
    }

    /// The screen is finished and the presenter should close it.
    public var closes: Bool { self == .confirmed || self == .dismissed }
}

// MARK: - S8 · Recovery setup

/// The runtime's closed `MatrixSecurityFailure` codes, plus `other` for an
/// error the runtime does not classify. Raw SDK errors never reach a screen.
public enum PhoneTrustFailure: Error, Equatable, Sendable {
    case sessionUnavailable
    case busy
    case crossSigningBootstrapUnavailable
    case verificationRequired
    case existingRecovery
    case recoveryNotReady
    case recoveryKeyUnavailable
    case secureStorageUnavailable
    case saveCancelled
    case platformSaveUnavailable
    case notHuman
    case invalidParticipants
    case roomUnavailable
    case other
}

/// Why a setup step can be retried in place.
public enum PhoneTrustRetryReason: Equatable, Sendable {
    /// Another trust operation is still finishing (`.busy`).
    case busy
    /// The SDK state is still settling (`.recoveryNotReady`, unclassified).
    case notReady
    /// This iPhone's protected storage refused the key (`.secureStorageUnavailable`).
    case storage
}

/// The result of the explicit "Set up" action on the Security sheet. Fewer
/// screens: every outcome except a fresh key renders as one quiet line under
/// the Security rows, never as a modal or a separate screen.
public enum PhoneTrustSetupOutcome: Equatable, Sendable {
    /// One key to save (Save to Passwords first, Copy second).
    case key(UUID)
    /// This phone is not cross-signed yet: compare emoji or use the key.
    case verifyFirst
    /// The account already has recovery: use that key; never replace it.
    case useExistingKey
    /// No account identity exists yet and this build has no safe phone-first
    /// setup (pinned SDK; automatic setup tested and kept off, 28 Nov 2026).
    /// One honest line: set up from another signed-in device, or later. No
    /// action. Isolated so a future decided route replaces only this case.
    case setUpOnAnotherDevice
    case retry(PhoneTrustRetryReason)
    /// The session changed or ended; the sheet closes.
    case closed

    public init(setupFailure failure: PhoneTrustFailure) {
        switch failure {
        case .verificationRequired: self = .verifyFirst
        case .existingRecovery: self = .useExistingKey
        case .crossSigningBootstrapUnavailable: self = .setUpOnAnotherDevice
        case .sessionUnavailable: self = .closed
        case .busy: self = .retry(.busy)
        case .secureStorageUnavailable: self = .retry(.storage)
        case .recoveryNotReady, .recoveryKeyUnavailable, .saveCancelled, .platformSaveUnavailable,
             .notHuman, .invalidParticipants, .roomUnavailable, .other:
            self = .retry(.notReady)
        }
    }
}

/// The recovery key row on the Security sheet, from the SDK projection.
public enum PhoneTrustKeyStatus: Equatable, Sendable {
    /// Saved and confirmed on this phone: nothing to do.
    case on
    /// A key was generated here and its save is not confirmed yet. The row
    /// resumes the save; it is an offer, never a blocker.
    case notSaved(UUID)
    /// Recovery exists for the account but this phone has not used the key:
    /// the row opens the existing restore sheet.
    case onElsewhere
    /// No recovery yet: the row runs explicit setup.
    case notSetUp

    public init(recoveryEnabled: Bool, backupEnabled: Bool, recoveryKeyConfirmed: Bool,
                pendingSaveID: UUID?) {
        if let pendingSaveID { self = .notSaved(pendingSaveID) }
        else if recoveryEnabled, backupEnabled, recoveryKeyConfirmed { self = .on }
        else if recoveryEnabled || backupEnabled { self = .onElsewhere }
        else { self = .notSetUp }
    }
}

/// The key screen's actions. Save to Passwords leads when the platform save is
/// confirmed for this build; otherwise Copy leads and an explicit "I've saved
/// it" confirmation follows. A Copy tap alone never confirms the save.
public struct PhoneTrustKeyActions: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case saveToPasswords, copy, confirmSaved
    }

    public let primary: Action
    public let secondary: Action?

    public init(platformSaveAvailable: Bool, copied: Bool) {
        if platformSaveAvailable {
            primary = .saveToPasswords
            secondary = copied ? .confirmSaved : .copy
        } else {
            primary = copied ? .confirmSaved : .copy
            secondary = copied ? .copy : nil
        }
    }

    /// The platform save runs only on iOS 26.2+ and only once a dedicated
    /// recovery credential scope is confirmed for the signed build
    /// (docs/implementation/chat-parity-ml5-trust.md, integration contract).
    public static func platformSaveAvailable(systemSupportsSave: Bool, scopeConfirmed: Bool,
                                             failedThisSession: Bool) -> Bool {
        systemSupportsSave && scopeConfirmed && !failedThisSession
    }
}

// MARK: - S9 · Private at creation

public enum PhoneTrustPrivateOption {
    /// The Private row exists only once this device passed S7 and S8 (M4 §5).
    /// Until then it is not drawn at all: never a disabled teaser.
    public static func isShown(canCreatePrivateChat: Bool?) -> Bool {
        canCreatePrivateChat == true
    }
}

/// One private group creation intent. The same name and people keep the same
/// request UUID across retries, so the runtime dispatches at most once; a
/// changed name or member set is a new intent with a new UUID.
public struct PhoneTrustPrivateGroupIntent: Equatable, Sendable {
    public private(set) var requestID: UUID
    private var name: String
    private var memberIDs: Set<String>

    public init(name: String, memberIDs: Set<String>, requestID: UUID = UUID()) {
        self.name = name
        self.memberIDs = memberIDs
        self.requestID = requestID
    }

    public mutating func requestID(name: String, memberIDs: Set<String>,
                                   makeID: () -> UUID = UUID.init) -> UUID {
        if name != self.name || memberIDs != self.memberIDs {
            self.name = name
            self.memberIDs = memberIDs
            requestID = makeID()
        }
        return requestID
    }
}
