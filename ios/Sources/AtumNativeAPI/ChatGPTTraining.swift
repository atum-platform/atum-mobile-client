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

/// The GET/POST projection, read strictly as the desktop reads it
/// (`parseMatrixChatGptTraining`). `current` is true only for this build's
/// wording and the account's current relay connection.
public struct ChatGPTTrainingStatus: Equatable, Sendable {
    public let current: Bool
    /// The current relay connection a confirmation binds to; nil while no relay is enabled.
    public let connectionID: String?
    /// When the current confirmation was made; nil unless `current`.
    public let confirmedAt: Date?

    public init(current: Bool, connectionID: String?, confirmedAt: Date?) {
        self.current = current
        self.connectionID = connectionID
        self.confirmedAt = confirmedAt
    }

    /// A wording other than v1 is not current for this build. Any field
    /// outside the contract makes the whole answer unreadable: an unreadable
    /// answer is never a confirmation.
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

        let current = currentValue.boolValue && (wording as? String) == ChatGPTTraining.wordingVersion
        return ChatGPTTrainingStatus(
            current: current,
            connectionID: connection as? String,
            confirmedAt: current ? (confirmed as? String).flatMap(date) : nil
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
