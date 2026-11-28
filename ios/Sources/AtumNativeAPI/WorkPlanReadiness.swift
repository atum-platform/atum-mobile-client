import Foundation

/// Owner-scoped readiness for cloud assistants. The device-services request
/// relies on the session bearer and carries no account or device identifier.
public enum WorkPlanReadinessContract {
    public static let profile = "atum.work-plan-readiness/1"
    public static let requestBody = Data(#"{"operation":"work_plan_readiness_read"}"#.utf8)
}

public enum WorkPlanReadinessRead: Equatable, Sendable {
    case available(WorkPlanReadiness)
    case unavailable

    public var snapshot: WorkPlanReadiness? {
        guard case let .available(snapshot) = self else { return nil }
        return snapshot
    }
}

public struct WorkPlanReadiness: Equatable, Sendable, Decodable {
    public enum Entry: Equatable, Sendable, Decodable {
        case ready(validUntil: Int64)
        case grantMissing, grantExpired, notConnected

        public init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Field.self)
            let state: String = try fields.value("state")
            if state == "ready" {
                try fields.closed(["state", "validUntil"])
                self = .ready(validUntil: try WorkPlanReadiness.timestamp(fields, "validUntil"))
                return
            }
            try fields.closed(["state"])
            switch state {
            case "grant_missing": self = .grantMissing
            case "grant_expired": self = .grantExpired
            case "not_connected": self = .notConnected
            default: throw ContractViolation.invalidValue
            }
        }

        fileprivate var expiry: Date? {
            guard case let .ready(validUntil) = self else { return nil }
            return Date(timeIntervalSince1970: Double(validUntil) / 1_000)
        }
    }

    public let checkedAt: Int64
    private let plans: [AccountPlan: Entry]

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self)
        try fields.closed(["profile", "checkedAt", "plans"])
        guard try fields.value("profile", as: String.self) == WorkPlanReadinessContract.profile else {
            throw ContractViolation.invalidValue
        }
        let checkedAt = try Self.timestamp(fields, "checkedAt")
        let map = try fields.nestedContainer(keyedBy: Field.self, forKey: Field("plans"))
        try map.closed(Set(AccountPlan.allCases.map(\.rawValue)))
        plans = try Dictionary(uniqueKeysWithValues: AccountPlan.allCases.map { plan in
            let entry: Entry = try map.value(plan.rawValue)
            if case let .ready(validUntil) = entry, validUntil <= checkedAt {
                throw ContractViolation.invariant
            }
            return (plan, entry)
        })
        self.checkedAt = checkedAt
    }

    /// Cached ready entries turn into grant-expired entries at the deadline.
    public func entry(for plan: AccountPlan, at now: Date = .now) -> Entry {
        let entry = plans[plan]! // Decoding requires all three entries.
        if let expiry = entry.expiry, expiry <= now { return .grantExpired }
        return entry
    }

    public func nextExpiry(after now: Date) -> Date? {
        plans.values.compactMap(\.expiry).filter { $0 > now }.min()
    }

    private static func timestamp(_ fields: KeyedDecodingContainer<Field>, _ key: String) throws -> Int64 {
        // Match the wire schema's safe integers, including integral decimal numbers.
        let number = try fields.value(key, as: Double.self)
        guard let timestamp = Int64(exactly: number), (0...NativeAPI.maximumInteger).contains(timestamp) else {
            throw ContractViolation.invalidValue
        }
        return timestamp
    }
}
