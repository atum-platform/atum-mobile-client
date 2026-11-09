/// S6 shows at most one recovery row in Account. Locked old history wins over
/// a locally held key so the person always sees the action that restores use.
public enum AccountRecoverySlot: Equatable, Sendable {
    case restoreMessages
    case recoveryKey

    public static func decide(offersHistoryRecovery: Bool,
                              holdsRecoveryKey: Bool) -> AccountRecoverySlot? {
        if offersHistoryRecovery { return .restoreMessages }
        if holdsRecoveryKey { return .recoveryKey }
        return nil
    }
}

public enum SignOutPrompt: Equatable, Sendable {
    case confirmation
    case saveRecoveryKey

    /// A held key that has not been confirmed saved must be shown before any
    /// local sign-out mutation. Every other state uses the ordinary dialog.
    public static func decide(holdsRecoveryKey: Bool,
                              confirmedSavedOnThisPhone: Bool) -> SignOutPrompt {
        holdsRecoveryKey && !confirmedSavedOnThisPhone ? .saveRecoveryKey : .confirmation
    }
}

public enum RestoreMessagesState: Equatable, Sendable {
    case idle
    case working
    case rejected
    case failed
    case done

    public var keepsEnteredKey: Bool {
        switch self {
        case .rejected, .failed: true
        case .idle, .working, .done: false
        }
    }

    public var dismissIsDisabled: Bool { self == .working }
}

public enum WelcomePresentation: Equatable, Sendable {
    case idle
    case busy
    case cancelled
    case registrationClosed
    case failed
    case expired

    public var acceptsSignInTap: Bool { self != .busy }
}

/// Synchronous UI gate around the asynchronous Matrix → device preparation →
/// domain sign-in chain. The tap changes presentation before a Task can be
/// scheduled, so a second tap can never start a parallel browser flow.
public struct SignInAttemptGate: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case succeeded
        case cancelled
        case failed
    }

    public private(set) var presentation = WelcomePresentation.idle

    public init() {}

    @discardableResult public mutating func begin() -> Bool {
        guard presentation != .busy else { return false }
        presentation = .busy
        return true
    }

    public mutating func finish(_ outcome: Outcome) {
        presentation = switch outcome {
        case .succeeded: .idle
        case .cancelled: .cancelled
        case .failed: .failed
        }
    }

    public var isInProgress: Bool { presentation == .busy }
}

