import AtumChat
import AtumNativeAPI
import AuthenticationServices
import Foundation
import Observation
import UIKit

// The trust UI's whole view of the runtime (ML5 UI, chat parity S7–S9). Screens
// receive these closures and never hold `MatrixLiveRuntime`. The coordinator
// builds them once per live runtime (`SecurityActions.live`) and passes nil
// while no session is live, which hides every trust entry.

/// The SAS engine as the verification screen drives it. `MatrixSASVerification`
/// conforms; DEBUG scripted hosts supply a scripted driver.
@MainActor
protocol DeviceVerificationDriver: AnyObject, Observable {
    var state: MatrixSASVerification.State { get }
    func listen() async
    func request() async
    func accept(_ id: UUID) async
    func compare(_ id: UUID, matches: Bool) async
    func cancel(_ id: UUID) async
}

extension MatrixSASVerification: DeviceVerificationDriver {}

extension MatrixSASVerification.State {
    /// The attempt the current presentation acts on, if any.
    var attemptID: UUID? {
        switch self {
        case let .incoming(invitation): invitation.id
        case let .requested(id), let .accepted(id), let .comparing(id, _), let .waitingForPeer(id): id
        case .idle, .finished: nil
        }
    }

    var emoji: [MatrixSASVerification.Emoji] {
        if case let .comparing(_, emoji) = self { return emoji }
        return []
    }

    var stage: PhoneTrustSASStage {
        switch self {
        case .idle: .idle
        case let .incoming(invitation): .incoming(deviceName: invitation.deviceName)
        case .requested: .requested
        case .accepted: .accepted
        case .comparing: .comparing
        case .waitingForPeer: .waitingForPeer
        case let .finished(outcome):
            switch outcome {
            case .matched: .finished(.matched)
            case .mismatch: .finished(.mismatch)
            case .cancelled: .finished(.cancelled)
            case .peerCancelled: .finished(.peerCancelled)
            case .timedOut: .finished(.timedOut)
            case .unavailable: .finished(.unavailable)
            }
        }
    }
}

extension PhoneTrustFailure {
    init(_ error: Error) {
        guard let failure = error as? MatrixSecurityFailure else { self = .other; return }
        switch failure {
        case .sessionUnavailable: self = .sessionUnavailable
        case .busy: self = .busy
        case .crossSigningBootstrapUnavailable: self = .crossSigningBootstrapUnavailable
        case .verificationRequired: self = .verificationRequired
        case .existingRecovery: self = .existingRecovery
        case .recoveryNotReady: self = .recoveryNotReady
        case .recoveryKeyUnavailable: self = .recoveryKeyUnavailable
        case .secureStorageUnavailable: self = .secureStorageUnavailable
        case .saveCancelled: self = .saveCancelled
        case .platformSaveUnavailable: self = .platformSaveUnavailable
        case .notHuman: self = .notHuman
        case .invalidParticipants: self = .invalidParticipants
        case .roomUnavailable: self = .roomUnavailable
        }
    }
}

struct SecurityActions {
    /// The live runtime's SAS engine (one per runtime).
    let verification: @MainActor () -> (any DeviceVerificationDriver)?
    /// Nil when the runtime could not answer; screens then show nothing new.
    let snapshot: @MainActor () async -> MatrixSecuritySnapshot?
    let setup: @MainActor () async -> Result<UUID, PhoneTrustFailure>
    /// The pending key, only for the explicit reveal and Copy. Never stored in
    /// observable state beyond the visible key view.
    let revealKey: @MainActor (UUID) -> String?
    /// Nil hides Save to Passwords (iOS < 26.2 or no confirmed scope).
    let saveToPasswords: (@MainActor (UUID, ASPresentationAnchor) async -> Result<Void, PhoneTrustFailure>)?
    let confirmSaved: @MainActor (UUID) async -> Result<Void, PhoneTrustFailure>
    /// The existing restore path (`LiveAppModel.restoreMessages`), unchanged.
    let restore: @MainActor @Sendable (String) async -> RecoveryRestoreResult
}

extension SecurityActions {
    /// One live runtime's actions. `restore` stays the app's existing restore
    /// path so recovery behaves exactly as today.
    @MainActor
    static func live(runtime: MatrixLiveRuntime,
                     restore: @escaping @MainActor @Sendable (String) async -> RecoveryRestoreResult) -> SecurityActions {
        var saveToPasswords: (@MainActor (UUID, ASPresentationAnchor) async -> Result<Void, PhoneTrustFailure>)?
        if let scope = RecoveryPasswordSave.configuredScope(userID: runtime.ticket.session.userID) {
            saveToPasswords = { [weak runtime] id, anchor in
                guard let runtime else { return .failure(.sessionUnavailable) }
                do {
                    try await runtime.saveRecoveryKey(id) { key in
                        try await RecoveryPasswordSave.save(key, scope: scope, anchor: anchor)
                    }
                    return .success(())
                } catch { return .failure(PhoneTrustFailure(error)) }
            }
        }
        return SecurityActions(
            verification: { [weak runtime] in runtime?.deviceVerification },
            snapshot: { [weak runtime] in try? await runtime?.securitySnapshot() },
            setup: { [weak runtime] in
                guard let runtime else { return .failure(.sessionUnavailable) }
                do { return .success(try await runtime.setupRecovery()) }
                catch { return .failure(PhoneTrustFailure(error)) }
            },
            revealKey: { [weak runtime] id in
                try? runtime?.withRecoveryKey(id) { $0 }
            },
            saveToPasswords: saveToPasswords,
            confirmSaved: { [weak runtime] id in
                guard let runtime else { return .failure(.sessionUnavailable) }
                do { try await runtime.confirmRecoveryKeySaved(id); return .success(()) }
                catch { return .failure(PhoneTrustFailure(error)) }
            },
            restore: restore
        )
    }
}

/// Save to Passwords (owner decision: Passwords first). The system credential's
/// password is the key; the URL scope and username carry no secret. The scope
/// must be a dedicated recovery-only HTTPS origin covered by the signed app's
/// `webcredentials` entitlement, so a login AutoFill never offers the key.
/// Until the coordinator confirms that origin it is absent from Info.plist and
/// the key screen shows manual Copy plus explicit confirmation instead.
enum RecoveryPasswordSave {
    /// Info.plist key holding the confirmed recovery credential host.
    static let scopeInfoKey = "AtumRecoveryCredentialHost"

    struct Scope: Sendable {
        let host: String
        let username: String
    }

    @MainActor
    static func configuredScope(userID: String, bundle: Bundle = .main) -> Scope? {
        guard #available(iOS 26.2, *),
              let host = bundle.object(forInfoDictionaryKey: scopeInfoKey) as? String,
              !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else { return nil }
        // A distinct, account-scoped synthetic username: never a login name.
        return Scope(host: host, username: "recovery-key " + userID)
    }

    @MainActor
    static func save(_ key: String, scope: Scope, anchor: ASPresentationAnchor) async throws {
        guard #available(iOS 26.2, *) else { throw MatrixSecurityFailure.platformSaveUnavailable }
        let credential = ASPasswordCredential(user: scope.username, password: key)
        do {
            try await ASCredentialDataManager().save(
                password: credential, for: ASAutoFillURLScope(scheme: .https, host: scope.host),
                title: nil, anchor: anchor
            )
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // The person dismissed the system sheet: keep Save offered.
            throw CancellationError()
        }
    }
}

/// Private people chats at creation (S9). The coordinator passes nil until the
/// release proof; the views also hide Private until the runtime is ready.
struct PrivateChatActions {
    let readiness: @MainActor () async -> Bool
    let createDirect: @MainActor (String) async -> PrivateChatCreateResult
    /// Name, selected people, and the request UUID kept for this exact intent.
    let createGroup: @MainActor (String, [HomeGroupCandidate], UUID) async -> PrivateChatCreateResult
}

enum PrivateChatCreateResult: Equatable, Sendable {
    case openRoom(String)
    case notFound(String)
    /// A selected participant is not positively confirmed as a person.
    case peopleOnly
    /// Trust or recovery changed since the toggle was shown.
    case notReady
    case rateLimited(Int?)
    case failed
}

/// One directory lookup on the private path: the evidence, or the refusal.
enum PrivateLookup {
    case found(AliasLookupResponse)
    case refused(PrivateChatCreateResult)
}

/// The trust screens' words: the export first, then the pending table.
@MainActor
struct SecurityCopy {
    let design: LiveDesign

    func text(_ key: PhoneTrustCopyKey) -> String {
        if design.copy.contains(key.rawValue) { return design.text(key.rawValue) }
        return PhoneTrustPendingCopy.text(key, locale: design.locale)
    }

    func text(_ key: PhoneTrustCopyKey, _ argument: String) -> String {
        if design.copy.contains(key.rawValue) { return design.text(key.rawValue, words: [argument]) }
        return PhoneTrustPendingCopy.text(key, locale: design.locale)
            .replacingOccurrences(of: "{0}", with: argument)
    }

    /// An exported key the trust screens reuse.
    func exported(_ key: String) -> String { design.text(key) }
}

extension UIApplication {
    /// The key window of the foreground scene, for system credential sheets.
    @MainActor var trustPresentationAnchor: ASPresentationAnchor? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
    }
}
