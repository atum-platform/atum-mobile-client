import Foundation

/// The account's one-time "training is off" confirmation for using a ChatGPT
/// plan with Google data: Shell `/api/connections/openai-codex/training-confirmation`
/// (contract r3), the route the desktop calls from `chatgpt-training-confirmation.ts`.
///
/// The phone only forwards the person's explicit checkbox and transfer
/// acceptance, with the same native domain bearer the platform admits for this
/// path (`hostOwnerBearer`, iOS domain client). Owner, timestamps, wording
/// hashes and revisions are server-owned; nothing here is authority, and
/// nothing is ever confirmed without the person's press.
public enum ChatGPTTraining {
    /// Same host as the domain API, outside its `/api/matrix/v1` prefix.
    public static let url = URL(string: "https://api.atumplatform.com/api/connections/openai-codex/training-confirmation")!
    /// The checkbox sentence version this build shows (`MATRIX_CHATGPT_TRAINING_WORDING`).
    public static let wordingVersion = "chatgpt-google-v1"
    /// The transfer disclosure version this build shows (`MATRIX_CHATGPT_TRANSFER_WORDING`).
    public static let transferWordingVersion = "chatgpt-google-transfer-v1"
    /// The host-bridge contract header the Shell route checks (`owner-consent.ts`).
    public static let contractHeader = "X-Atum-Host-Bridge-Contract"
    public static let contract = "atum.s2.host-bridge/1.0.0"
    /// The desktop's response bound for this projection.
    public static let maximumResponseBytes = 16 * 1024
}

/// The consent decision a ChatGPT write is made under: the relay connection
/// the confirmation binds to and the platform revision of that confirmation.
/// A write carries it so a later re-read can tell whether the decision the
/// person made (or the platform reported) still stands.
public struct ChatGPTTrainingConsent: Equatable, Hashable, Sendable {
    public let connectionID: String
    public let revision: Int64

    public init(connectionID: String, revision: Int64) {
        self.connectionID = connectionID
        self.revision = revision
    }
}

/// The GET/POST projection, read strictly as the desktop reads it
/// (`parseMatrixChatGptTraining`). `current` is true only for this build's
/// wording, the account's current relay connection, and a complete record:
/// a current answer without its connection, time or revision is not a
/// confirmation.
public struct ChatGPTTrainingStatus: Equatable, Sendable {
    public let current: Bool
    /// The current relay connection a confirmation binds to; nil while no relay is enabled.
    public let connectionID: String?
    /// When the current confirmation was made; nil unless `current`.
    public let confirmedAt: Date?
    /// The confirmation's platform revision; nil unless `current`.
    public let revision: Int64?

    /// `current` holds only with every field of the record present.
    public init(current: Bool, connectionID: String?, confirmedAt: Date?, revision: Int64? = nil) {
        let complete = current && connectionID.map(Self.isUUID) == true && confirmedAt != nil && revision != nil
        self.current = complete
        self.connectionID = connectionID
        self.confirmedAt = complete ? confirmedAt : nil
        self.revision = complete ? revision : nil
    }

    /// The decision a write may carry; nil unless the confirmation is current.
    public var consent: ChatGPTTrainingConsent? {
        guard current, let connectionID, let revision else { return nil }
        return ChatGPTTrainingConsent(connectionID: connectionID, revision: revision)
    }

    /// A wording other than v1 is not current for this build. Any field
    /// outside the contract makes the whole answer unreadable: an unreadable
    /// answer is never a confirmation. A `current: true` that omits its
    /// connection, time or revision reads as not confirmed.
    public static func decode(_ data: Data) throws -> ChatGPTTrainingStatus {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let currentValue = object["current"] as? NSNumber, isBoolean(currentValue)
        else { throw NativeDomainClientFailure.invalidResponse }
        let wording = object["wordingVersion"]
        let connection = object["connectionId"]
        let confirmed = object["confirmedAt"]
        let revision = object["revision"]

        guard isNullOrAbsent(wording) || wording is String,
              isNullOrAbsent(connection) || (connection as? String).map(isUUID) == true,
              isNullOrAbsent(confirmed) || (confirmed as? String).flatMap(date) != nil,
              isNullOrAbsent(revision) || isRevision(revision)
        else { throw NativeDomainClientFailure.invalidResponse }

        return ChatGPTTrainingStatus(
            current: currentValue.boolValue && (wording as? String) == ChatGPTTraining.wordingVersion,
            connectionID: connection as? String,
            confirmedAt: (confirmed as? String).flatMap(date),
            revision: (revision as? NSNumber).map { $0.int64Value }
        )
    }

    private static func isNullOrAbsent(_ value: Any?) -> Bool { value == nil || value is NSNull }

    private static func isBoolean(_ value: NSNumber) -> Bool {
        CFGetTypeID(value) == CFBooleanGetTypeID()
    }

    private static func isRevision(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, !isBoolean(number) else { return false }
        let double = number.doubleValue
        return double >= 0 && double <= 9_007_199_254_740_991 && double.rounded() == double
    }

    static func isUUID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value) != nil
    }

    private static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

/// What a confirmation press came to (`MatrixChatGptTrainingConfirmResult`).
public enum ChatGPTTrainingConfirmResult: Equatable, Sendable {
    /// The platform recorded it for the current connection.
    case confirmed(ChatGPTTrainingStatus)
    /// The relay connection changed under the card (409): read again, ask again.
    case stale
    /// Nothing was recorded, or the outcome is unknown. The model is unchanged.
    case unavailable
}

/// The exact POST body the Shell route accepts: three fields, no more.
struct ChatGPTTrainingConfirmRequest: Encodable, Equatable {
    let wordingVersion: String
    let connectionId: String
    let transferWordingVersion: String

    init(connectionID: String) {
        wordingVersion = ChatGPTTraining.wordingVersion
        connectionId = connectionID
        transferWordingVersion = ChatGPTTraining.transferWordingVersion
    }
}

/// The re-check a ChatGPT write makes before an automatic retry and after a
/// refusal: the consent status is read again (with the client and scope the
/// write was bound to) and must still name the same connection and revision.
/// Anything else, including a failed read, means the old decision is not
/// reused; `latest` keeps what the re-read saw so the picker can ask again.
@MainActor public final class ChatGPTTrainingRecheck {
    public let consent: ChatGPTTrainingConsent
    public private(set) var latest: ChatGPTTrainingStatus?
    private let read: () async -> ChatGPTTrainingStatus?

    public init(consent: ChatGPTTrainingConsent, read: @escaping () async -> ChatGPTTrainingStatus?) {
        self.consent = consent
        self.read = read
    }

    public func stillCurrent() async -> Bool {
        let status = await read()
        latest = status
        return status?.consent == consent
    }
}

/// One press of the card's Confirm (desktop `chatgpt-training-confirm.tsx`).
/// The POST goes only for a connection the card read; when the card holds
/// none (a refresh after a 409 failed), the press reads the status first and
/// confirms for the connection it names. A 409 reads again and asks again.
public enum ChatGPTTrainingPress {
    public enum Outcome: Equatable, Sendable {
        /// The confirmation is current: carry `status.consent` to the write.
        case confirmed(ChatGPTTrainingStatus)
        /// The relay changed: untick and ask again for this connection (nil if unread).
        case askAgain(connectionID: String?)
        /// Nothing was recorded; the card keeps this connection (nil if unread).
        case failed(connectionID: String?)
    }

    @MainActor
    public static func confirm(connectionID: String?,
                               read: () async -> ChatGPTTrainingStatus?,
                               confirm: (String) async -> ChatGPTTrainingConfirmResult) async -> Outcome {
        var connection = connectionID
        if connection == nil {
            let fresh = await read()
            if let fresh, fresh.current { return .confirmed(fresh) }
            connection = fresh?.connectionID
        }
        guard let connection else { return .failed(connectionID: nil) }
        switch await confirm(connection) {
        case let .confirmed(status):
            guard status.current, status.connectionID == connection else { return .failed(connectionID: connection) }
            return .confirmed(status)
        case .stale:
            let fresh = await read()
            if let fresh, fresh.current { return .confirmed(fresh) }
            return .askAgain(connectionID: fresh?.connectionID)
        case .unavailable:
            return .failed(connectionID: connection)
        }
    }
}

/// The picker's selection lifetime, ported from the desktop picker's
/// `beginSelection` (`model-picker.tsx`): every pick takes a token, a newer
/// pick or the picker's dismissal retires it, and a continuation whose token
/// is stale does nothing (no consent read result, no POST follow-up, no
/// write). Loads take their own token so an interrupted read never leaves the
/// picker stuck "loading".
public struct ModelPickerLifetime: Equatable, Sendable {
    public struct Token: Equatable, Hashable, Sendable {
        fileprivate let generation: UInt64
    }

    private var selection: UInt64 = 0
    private var load: UInt64 = 0
    private var loadingToken: UInt64?

    public init() {}

    public var loading: Bool { loadingToken != nil }

    public mutating func beginSelection() -> Token {
        selection &+= 1
        return Token(generation: selection)
    }

    public func isCurrent(_ token: Token) -> Bool { token.generation == selection }

    /// nil while another load is in flight.
    public mutating func beginLoad() -> Token? {
        guard loadingToken == nil else { return nil }
        load &+= 1
        loadingToken = load
        return Token(generation: load)
    }

    /// Whether a load's result may still be applied.
    public func isCurrentLoad(_ token: Token) -> Bool { loadingToken == token.generation }

    /// Always called (`defer`), also when the load was cancelled. An older
    /// load ending never clears a newer one.
    public mutating func endLoad(_ token: Token) {
        if loadingToken == token.generation { loadingToken = nil }
    }

    /// The picker closed: every pending selection and load is stale.
    public mutating func retire() {
        selection &+= 1
        load &+= 1
        loadingToken = nil
    }
}
