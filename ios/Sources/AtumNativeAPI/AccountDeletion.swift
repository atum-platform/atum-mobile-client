import Foundation

/// Frozen contract-e wire consumers only. No requests, reauthentication,
/// replay coordinator, deletion fence or grant revocation are performed here.
public enum AccountDeletion {
    private static let ownerForbidden: Set<String> = ["accessToken", "refreshToken", "password", "recoveryKey", "email", "subject"]
    public static func status(_ data: Data) throws -> DeletionStatus {
        try NativeAPI.decode(DeletionStatus.self, from: data, forbidden: ownerForbidden)
    }
    public static func request(_ data: Data) throws -> DeletionRequest {
        try NativeAPI.decode(DeletionRequest.self, from: data, forbidden: ownerForbidden.union(["owner", "principal", "issuer", "handle"]))
    }
    public static func accepted(_ data: Data) throws -> DeletionAccepted {
        try NativeAPI.decode(DeletionAccepted.self, from: data, forbidden: ownerForbidden)
    }
    public static func progress(_ data: Data) throws -> DeletionProgress {
        try NativeAPI.decode(DeletionProgress.self, from: data,
            forbidden: ["principal", "subject", "issuer", "email", "handle", "statusToken", "matrixUser"])
    }
    public static func failure(_ data: Data) throws -> DeletionFailure {
        try NativeAPI.decode(DeletionFailure.self, from: data, forbidden: ownerForbidden)
    }
}

/// Opaque proof/token routing bytes, never a description or authorization claim.
public struct DeletionProof: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let wireValue: String
    fileprivate init(_ value: String, minimum: Int, maximum: Int, pattern: String) throws {
        wireValue = try checkedString(value, minimum: minimum, maximum: maximum, pattern: pattern)
    }
    fileprivate static func token(_ value: String) throws -> Self {
        try Self(value, minimum: 43, maximum: 43, pattern: "[A-Za-z0-9_-]{43}")
    }
    public var description: String { "Deletion proof (withheld)" }
    public var debugDescription: String { description }
}

public enum DeletionState: String, Decodable, Sendable { case none, blocked, inProgress = "in_progress", completed }
public enum DeletionBlockerCode: String, Decodable, Hashable, Sendable {
    case companyOwnerWithMembers = "company_owner_with_members"
    case sellerPayoutPending = "seller_payout_pending"
    case purchaseReconciliationPending = "purchase_reconciliation_pending"
}
public struct DeletionBlocker: Decodable, Hashable, Sendable {
    public let code: DeletionBlockerCode
    public let actionURL: String?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self); try c.closed(["code", "actionUrl"])
        code = try c.value("code")
        actionURL = try c.optional("actionUrl", as: String.self).map {
            try checkedString($0, minimum: 9, maximum: 2048, pattern: "https://[!-~]+")
        }
    }
}
public struct DeletionStatus: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let state: DeletionState, disclosure: DeletionDisclosure, blockers: [DeletionBlocker]
    public let reauthNonce: DeletionProof, reauthNonceExpiresAt: Int64, appleRevocationState: DeletionProof?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["state", "disclosure", "blockers", "reauthNonce", "reauthNonceExpiresAt", "appleRevocationState"])
        state = try c.value("state"); disclosure = try c.value("disclosure"); blockers = try c.value("blockers")
        guard blockers.count <= 3, Set(blockers).count == blockers.count else { throw ContractViolation.invalidValue }
        reauthNonce = try .token(c.value("reauthNonce")); reauthNonceExpiresAt = try c.integer("reauthNonceExpiresAt")
        appleRevocationState = try c.optional("appleRevocationState", as: String.self).map(DeletionProof.token)
    }
    public var description: String { "Deletion status: \(state.rawValue) (proofs withheld)" }
    public var debugDescription: String { description }
}

public struct DeletionDisclosure: Decodable, Sendable {
    public enum Deleted: String, Decodable, Hashable, Sendable {
        case accountProfile = "account_profile", identities, encryptedChatsAndKeyBackup = "encrypted_chats_and_key_backup"
        case syncedAssistantContent = "synced_assistant_content", agents, appLinks = "app_links", driveFiles = "drive_files"
        case knowledge, storageObjects = "storage_objects", cloudEnrollments = "cloud_enrollments"
        case linkedUsageData = "linked_usage_data", pushersAndDevices = "pushers_and_devices"
    }
    public struct Retained: Decodable, Sendable {
        public enum Category: String, Decodable, Sendable {
            case protonLedgerRecords = "proton_ledger_records", aiUsageRecords = "ai_usage_records", appMessageRecords = "app_message_records"
            case errorReports = "error_reports", serverLogs = "server_logs", backups, appMemberCopies = "app_member_copies"
            case updatesChannelComments = "updates_channel_comments", websiteWaitlistAndContact = "website_waitlist_and_contact"
            case deletionReceipts = "deletion_receipts", abuseReports = "abuse_reports"
        }
        public enum Basis: String, Decodable, Sendable { case law, privacyPolicy = "privacy_policy", safety, proofOfDeletion = "proof_of_deletion" }
        public let category: Category, basis: Basis, maxRetention: String?
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self); try c.closed(["category", "basis", "maxRetention"])
            category = try c.value("category"); basis = try c.value("basis")
            maxRetention = try c.nullable("maxRetention", as: String.self).map {
                try checkedString($0, minimum: 3, maximum: 6, pattern: "P[0-9]{1,3}[DMY]")
            }
        }
    }
    public struct Protons: Decodable, Sendable {
        public let availableMicroProtons: Int64, refundEligible: Bool
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self); try c.closed(["availableMicroProtons", "refundEligible"])
            availableMicroProtons = try c.integer("availableMicroProtons"); refundEligible = try c.value("refundEligible")
        }
    }
    public let deleted: [Deleted], retained: [Retained], protons: Protons
    public let timelineDays: Int64, cannotRecall: String, localOnMac: [String]
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["deleted", "retained", "timelineDays", "cannotRecall", "localOnMac", "protons"])
        deleted = try c.value("deleted"); retained = try c.value("retained"); protons = try c.value("protons")
        timelineDays = try c.integer("timelineDays"); cannotRecall = try c.value("cannotRecall"); localOnMac = try c.value("localOnMac")
        guard (1...20).contains(deleted.count), Set(deleted).count == deleted.count, (1...20).contains(retained.count),
              timelineDays == 30, cannotRecall == "copies_others_received", localOnMac == ["assistant_memory", "google_credentials"] else {
            throw ContractViolation.invalidValue
        }
    }
}

public struct DeletionRequest: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let reauthIDToken: DeletionProof, idempotencyKey: String, appleAuthorizationCode: DeletionProof?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["confirmation", "reauthIdToken", "idempotencyKey", "appleAuthorizationCode"])
        guard try c.value("confirmation", as: String.self) == "delete_account" else { throw ContractViolation.invalidValue }
        reauthIDToken = try DeletionProof(c.value("reauthIdToken"), minimum: 5, maximum: 16384,
            pattern: "[A-Za-z0-9_-]+[.][A-Za-z0-9_-]+[.][A-Za-z0-9_-]+")
        idempotencyKey = try c.string("idempotencyKey", minimum: 1, maximum: 100, pattern: "[A-Za-z0-9_-]+")
        appleAuthorizationCode = try c.optional("appleAuthorizationCode", as: String.self).map {
            try DeletionProof($0, minimum: 1, maximum: 2048, pattern: "[!-~]+")
        }
    }
    public var description: String { "Deletion request (proofs withheld)" }
    public var debugDescription: String { description }
}
public struct DeletionAccepted: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let requestID: NativeID, completesBy: Int64, statusToken: DeletionProof
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self); try c.closed(["requestId", "state", "completesBy", "statusToken"])
        guard try c.value("state", as: String.self) == "in_progress" else { throw ContractViolation.invalidValue }
        requestID = try c.value("requestId"); completesBy = try c.integer("completesBy"); statusToken = try .token(c.value("statusToken"))
    }
    public var description: String { "Deletion accepted (status token withheld)" }
    public var debugDescription: String { description }
}
public struct DeletionProgress: Decodable, Sendable {
    public enum State: String, Decodable, Sendable { case inProgress = "in_progress", completed }
    public enum System: String, Decodable, CaseIterable, Hashable, Sendable {
        case turnsAndCloud = "turns_and_cloud", appsAndAgents = "apps_and_agents", drive, knowledge, storage, commerce
        case appleAndGoogle = "apple_and_google", matrix, telemetry, principal
    }
    public enum StepState: String, Decodable, Sendable { case pending, running, done, failed, blocked }
    public struct Step: Decodable, Sendable {
        public let system: System, state: StepState
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self); try c.closed(["system", "state"])
            system = try c.value("system"); state = try c.value("state")
        }
    }
    public let state: State, completesBy: Int64, steps: [Step]
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self); try c.closed(["state", "completesBy", "steps"])
        state = try c.value("state"); completesBy = try c.integer("completesBy"); steps = try c.value("steps")
        guard steps.count == 10, Set(steps.map(\.system)) == Set(System.allCases),
              state != .completed || steps.allSatisfy({ $0.state == .done }) else { throw ContractViolation.invariant }
    }
}
public struct DeletionFailure: Decodable, Sendable {
    public enum Code: String, Decodable, Sendable { case badRequest = "matrix_400", unauthenticated = "matrix_401", forbidden = "matrix_403", conflict = "matrix_409", rateLimited = "matrix_429", unavailable = "matrix_503" }
    public struct Details: Decodable, Sendable {
        public enum Reason: String, Decodable, Sendable {
            case invalid, reauthRequired = "reauth_required", reauthSubjectMismatch = "reauth_subject_mismatch"
            case deletionBlocked = "deletion_blocked", alreadyRequested = "already_requested", requestConflict = "request_conflict", deletionUnavailable = "deletion_unavailable"
        }
        public let reason: Reason, blockers: [DeletionBlockerCode]?, requestID: NativeID?
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self); try c.closed(["reason", "blockers", "requestId"])
            reason = try c.value("reason"); blockers = try c.optional("blockers"); requestID = try c.optional("requestId")
            if let blockers {
                guard (1...3).contains(blockers.count), Set(blockers).count == blockers.count else { throw ContractViolation.invalidValue }
            }
        }
    }
    public let code: Code, details: Details?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self); try c.closed(["error", "details"])
        code = try c.value("error"); details = try c.optional("details")
    }
}
