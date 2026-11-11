import CryptoKit
import Foundation
import AtumNativeAPI
import MatrixRustSDK
import os

/// Debug-device evidence only. The record contains a fixed phase and enum
/// classification; it never serializes an Error, URL, browser callback,
/// identity or credential.
@MainActor
enum LiveAuthDiagnostics {
    private static var file: URL {
        URL.documentsDirectory
            .appending(path: "LiveDiagnostics", directoryHint: .isDirectory)
            .appending(path: "latest.json")
    }

    static func clear() {
        #if DEBUG
        try? FileManager.default.removeItem(at: file)
        #endif
    }

    static func record(phase: String, error: any Error) {
        #if DEBUG
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "phase": phase,
            "code": code(error)
        ]
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: payload,
                                                  options: [.sortedKeys])
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: file.path)
        } catch {
            // Diagnostics cannot affect sign-in or become a second state store.
        }
        #endif
    }

    static func recordSuccess() {
        #if DEBUG
        let payload: [String: Any] = [
            "schemaVersion": 1,
            "phase": "signed_in",
            "code": "success"
        ]
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: payload,
                                                  options: [.sortedKeys])
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: file.path)
        } catch { }
        #endif
    }

    /// Closed classification of an error. It never includes the error's
    /// message, URL, identity or any credential.
    static func code(_ error: any Error) -> String {
        if let value = error as? MASWebAuthFailure {
            return switch value {
            case .cancelled: "browser_cancelled"
            case .presentationContextNotProvided: "browser_presentation_context_missing"
            case .presentationContextInvalid: "browser_presentation_context_invalid"
            case .systemFailure: "browser_system_failure"
            case .callbackMalformed: "callback_malformed"
            case .callbackSchemeMismatch: "callback_scheme_mismatch"
            case .callbackHostMismatch: "callback_host_mismatch"
            case .callbackExplicitPort: "callback_explicit_port"
            case .callbackUserInfo: "callback_user_info"
            case .callbackFragment: "callback_fragment_present"
            case .callbackPathMismatch: "callback_path_mismatch"
            case .callbackCodeMissing: "callback_code_missing"
            case .callbackCodeInvalid: "callback_code_invalid"
            case .callbackInvalidUnclassified: "callback_invalid_unclassified"
            }
        }
        if let value = error as? OIDCFailure {
            return switch value {
            case .invalidConfiguration: "oidc_invalid_configuration"
            case .randomUnavailable: "oidc_random_unavailable"
            case .invalidCallback: "oidc_invalid_callback"
            case .unknownOrUsedState: "oidc_unknown_or_used_state"
            case .authorizationDenied: "oidc_authorization_denied"
            case .invalidToken: "oidc_invalid_token"
            case .unsupportedAlgorithm: "oidc_unsupported_algorithm"
            case .invalidSignature: "oidc_invalid_signature"
            case .invalidClaims: "oidc_invalid_claims"
            case .subjectMismatch: "oidc_subject_mismatch"
            case .deviceMismatch: "oidc_device_mismatch"
            case .browserBusy: "oidc_browser_busy"
            case .browserUnavailable: "oidc_browser_unavailable"
            }
        }
        if let value = error as? MASHTTPFailure {
            return switch value {
            case .invalidRequest: "http_invalid_request"
            case .invalidResponse: "http_invalid_response"
            case .responseTooLarge: "http_response_too_large"
            case .redirectRefused: "http_redirect_refused"
            case .bodyReplayRefused: "http_body_replay_refused"
            case .authenticationRefused: "http_authentication_refused"
            case .transportUnavailable: "http_transport_unavailable"
            case .cancelled: "http_cancelled"
            case let .httpStatus(status): "http_status_\(status)"
            }
        }
        if let value = error as? OIDCGrantFailure {
            return switch value {
            case .storageUnavailable: "grant_storage_unavailable"
            case .reauthenticationRequired: "grant_reauthentication_required"
            case .refreshInterrupted: "grant_refresh_interrupted"
            case .invalidResponse: "grant_invalid_response"
            case .invalidIdentity: "grant_invalid_identity"
            }
        }
        if let value = error as? MatrixRefreshFailure {
            return switch value {
            case .busy: "matrix_refresh_busy"
            case .unavailable: "matrix_refresh_lock_unavailable"
            case .recordChanged: "matrix_refresh_record_changed"
            case .timedOut: "matrix_refresh_timeout"
            case .keychainLocked: "matrix_keychain_locked"
            }
        }
        if let value = error as? MatrixCustodyFailure {
            return switch value {
            case .storageUnavailable: "matrix_storage_unavailable"
            case .recoveryRequired: "matrix_recovery_required"
            case .invalidIdentity: "matrix_invalid_identity"
            case .interruptedPreparation: "matrix_interrupted_preparation"
            case .refreshRequired: "matrix_refresh_required"
            case .expired: "matrix_expired"
            }
        }
        if let value = error as? MatrixRecoveryFailure {
            return switch value {
            case .storageUnavailable: "recovery_storage_unavailable"
            case .survivorRequiresRecovery: "recovery_survivor_present"
            case .invalidInput: "recovery_invalid_input"
            case .identityChanged: "recovery_identity_changed"
            }
        }
        if let value = error as? MatrixLiveRuntimeFailure {
            return switch value {
            case .identityMismatch: "sdk_identity_mismatch"
            case .unexpectedSessionMutation: "sdk_session_mutation"
            case .invalidRecoveryKey: MobileRecoveryKeyFailureCode.keyFormatInvalid.rawValue
            case .recoveryNotReady: MobileRecoveryKeyFailureCode.acceptedStillRestoring.rawValue
            case .founderUnavailable: "sdk_founder_unavailable"
            }
        }
        if let value = error as? RecoveryError {
            // Pattern checks instead of an exhaustive switch: the candidate SDK
            // may add cases, which then classify as "other".
            if case .SecretStorage = value { return MobileRecoveryKeyFailureCode.keyRejected.rawValue }
            if case .Import = value { return "sdk_recovery_import" }
            if case .Client = value { return "sdk_recovery_client" }
            return "sdk_recovery_other"
        }
        if error is CancellationError { return "cancelled" }
        // The type name is a closed, compile-time set (for example an SDK
        // error enum); it carries no message text or identifiers.
        return "unclassified_" + String(describing: type(of: error))
    }
}

/// Structured, content-free flow log lines for the 0.19.4 quality lane. Every
/// stage logs one line with closed codes. Read on a Mac with Console.app (pick
/// the iPhone, filter subsystem `com.atum.mobile`) or
/// `log stream --predicate 'subsystem == "com.atum.mobile"'`.
/// Never log message text, keys, tokens, user IDs or full room IDs.
enum LiveFlowLog {
    private static let recoveryLog = Logger(subsystem: "com.atum.mobile", category: "recovery")
    private static let botRoomLog = Logger(subsystem: "com.atum.mobile", category: "bot-room")
    private static let sessionLog = Logger(subsystem: "com.atum.mobile", category: "session")
    private static let rosterLog = Logger(subsystem: "com.atum.mobile", category: "roster")
    private static let sendLog = Logger(subsystem: "com.atum.mobile", category: "send")
    private static let pushLog = Logger(subsystem: "com.atum.mobile", category: "push")
    private static let timelineLog = Logger(subsystem: "com.atum.mobile", category: "timeline")
    private static let creationLog = Logger(subsystem: "com.atum.mobile", category: "creation")

    enum PrivateCosReadOutcome: String { case bound, unbound, unclassified }
    static func privateCosRead(_ outcome: PrivateCosReadOutcome) {
        rosterLog.info("private_cos_read outcome=\(outcome.rawValue, privacy: .public)")
    }

    /// 0.20 sign-in and resume stages that used to involve recovery.
    enum SessionStage: String {
        case signInRecovery = "sign_in_recovery"
        case resumeKeys = "resume_keys"
        case recoveryJournal = "recovery_journal"
        case blockedRetry = "blocked_retry"
        /// Foreground renewal of the 300 s Matrix access token.
        case keepAlive = "keep_alive"
        /// W4 E3: a session or custody failure that kept the app and its
        /// chats on screen instead of a lock screen.
        case continuity
        /// Owner decision 2026-10-19: the once-per-sign-in `POST /assistant`
        /// that reports the disclosure version shown on the sign-in screen.
        case cloudPlacement = "cloud_placement"
    }

    /// Send-queue health. Outcomes are closed failure classes or reasons.
    enum SendQueueEvent: String {
        case allEnabled = "all_enabled"
        case roomEnabled = "room_enabled"
        case roomDisabled = "room_disabled"
        case sendFailed = "send_failed"
        case autoRetry = "auto_retry"
    }

    /// 0.20 roster stages: one row per agent and invite handling.
    enum RosterStage: String {
        case agentRooms = "agent_rooms"
        case invite = "invite"
    }

    enum PushStage: String {
        case permission
        case apnsRegister = "apns_register"
        case pusher
    }

    enum RecoveryStage: String {
        case trustState = "trust_state"
        case verificationStart = "verification_start"
        case verificationFinished = "verification_finished"
        case flowCheck = "flow_check"
        case grantSend = "grant_send"
        case grantReceived = "grant_received"
        case grantRequest = "grant_request"
        case keyImport = "key_import"
        case readiness = "readiness"
        case finish = "finish"
        case manualKey = "manual_key"
    }

    enum BotRoomAction: String {
        case hide
        case unhide
        case open
        case pointer
        case hideRefused = "hide_refused"
    }

    enum CreationStage: String { case assistant, founder }

    static func creation(_ stage: CreationStage, outcome: String, code: String? = nil) {
        let codeText = code ?? "none"
        creationLog.notice(
            "atum.creation stage=\(stage.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) code=\(codeText, privacy: .public)"
        )
    }

    /// `outcome` and `code` must come from closed sets in code.
    static func recovery(_ stage: RecoveryStage, outcome: String, code: String? = nil) {
        let codeText = code ?? "none"
        recoveryLog.notice(
            "atum.recovery stage=\(stage.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) code=\(codeText, privacy: .public)"
        )
    }

    static func botRoom(_ action: BotRoomAction, outcome: String, roomID: String?) {
        let room = roomID.map(fingerprint) ?? "none"
        botRoomLog.notice(
            "atum.bot_room action=\(action.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) room=\(room, privacy: .public)"
        )
    }

    static func session(_ stage: SessionStage, outcome: String) {
        sessionLog.notice(
            "atum.session stage=\(stage.rawValue, privacy: .public) outcome=\(outcome, privacy: .public)"
        )
    }

    /// With a closed failure class (`LiveAuthDiagnostics.code`), so a device
    /// round can tell a custody refusal from a network drop (W4 E3).
    static func session(_ stage: SessionStage, outcome: String, code: String) {
        sessionLog.notice(
            "atum.session stage=\(stage.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) code=\(code, privacy: .public)"
        )
    }

    /// `count` is clamped so a log line never reveals the size of an account.
    static func roster(_ stage: RosterStage, outcome: String, roomID: String?, count: Int = 0) {
        let room = roomID.map(fingerprint) ?? "none"
        let bounded = min(max(count, 0), 9)
        rosterLog.notice(
            "atum.roster stage=\(stage.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) room=\(room, privacy: .public) count=\(bounded, privacy: .public)"
        )
    }

    /// `roomKind` is `plain`, `encrypted` or `unknown`; never message text.
    static func send(outcome: String, roomKind: String, roomID: String?) {
        let room = roomID.map(fingerprint) ?? "none"
        sendLog.notice(
            "atum.send outcome=\(outcome, privacy: .public) room_kind=\(roomKind, privacy: .public) room=\(room, privacy: .public)"
        )
    }

    /// Never message text, error text or a full room ID.
    static func sendQueue(_ event: SendQueueEvent, outcome: String, roomID: String?) {
        let room = roomID.map(fingerprint) ?? "none"
        sendLog.notice(
            "atum.send_queue event=\(event.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) room=\(room, privacy: .public)"
        )
    }

    /// `outcome` is `plaintext_hidden` or `plaintext_none`; logged only when
    /// the number of hidden messages in the open room changes.
    static func timeline(outcome: String, roomID: String?, count: Int) {
        let room = roomID.map(fingerprint) ?? "none"
        let bounded = min(max(count, 0), 9)
        timelineLog.notice(
            "atum.timeline outcome=\(outcome, privacy: .public) room=\(room, privacy: .public) count=\(bounded, privacy: .public)"
        )
    }

    static func push(_ stage: PushStage, outcome: String, code: String? = nil) {
        let codeText = code ?? "none"
        pushLog.notice(
            "atum.push stage=\(stage.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) code=\(codeText, privacy: .public)"
        )
    }

    /// Eight hex characters of SHA-256: enough to tell whether two log lines
    /// name the same room, without writing the room ID.
    static func fingerprint(_ roomID: String) -> String {
        SHA256.hash(data: Data(roomID.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
    }
}
