import Foundation

/// The assistant's Work catalogue from the owner-scoped eligibility RPC.
public struct WorkPlanEligibilitySnapshot: Equatable, Sendable, Decodable {
    public struct Plan: Equatable, Sendable, Decodable {
        public enum Status: String, Sendable, Decodable {
            case selectable, connect, unavailable
        }

        /// Shell owns the list of plan IDs and can add to it.
        public let plan: String
        public let status: Status
        public let models: [Model]

        public init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Field.self)
            plan = try fields.string("plan", minimum: 1, maximum: 200)
            status = try fields.value("status")
            models = try fields.value("models")
            guard (status == .selectable) == !models.isEmpty,
                  Set(models.map(\.id)).count == models.count else {
                throw ContractViolation.invalidValue
            }
        }
    }

    public struct Model: Equatable, Sendable, Decodable {
        public let id: String
        public let displayName: String

        public init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: Field.self)
            id = try fields.string("id", minimum: 1, maximum: 200, pattern: "[A-Za-z0-9][A-Za-z0-9._/-]{0,199}")
            displayName = try fields.string("displayName", minimum: 1, maximum: 120,
                                            pattern: "[A-Za-z0-9][A-Za-z0-9 ._()/+:-]{0,119}")
        }
    }

    public let plans: [Plan]

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self)
        plans = try fields.value("plans")
        guard Set(plans.map(\.plan)).count == plans.count else { throw ContractViolation.invalidValue }
    }
}

struct WorkPlanEligibilityReadRequest: Encodable {
    let operation = "work_plan_eligibility_read"
    let agentPrincipal: NativeID
}
