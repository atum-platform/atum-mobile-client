import Foundation

/// The identity of one model in a native Work plan.
public struct WorkModelSelection: Hashable, Sendable, Codable {
    public let plan: AccountPlan
    public let model: String

    public init?(plan: AccountPlan, model: String) {
        // The Shell Work relay schema bounds the JavaScript string length.
        guard (1...200).contains(model.utf16.count) else { return nil }
        self.plan = plan
        self.model = model
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        // The platform compares opaque model identifiers literally.
        lhs.plan == rhs.plan && lhs.model.utf8.elementsEqual(rhs.model.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(plan)
        for byte in model.utf8 { hasher.combine(byte) }
    }

    private enum CodingKeys: String, CodingKey { case provider, plan, model }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        guard try fields.decode(String.self, forKey: .provider) == "atum-work",
              let plan = AccountPlan(rawValue: try fields.decode(String.self, forKey: .plan)),
              let selection = Self(plan: plan, model: try fields.decode(String.self, forKey: .model))
        else { throw ContractViolation.invalidValue }
        self = selection
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode("atum-work", forKey: .provider)
        try fields.encode(plan.rawValue, forKey: .plan)
        try fields.encode(model, forKey: .model)
    }
}

/// Readback of the revision used by work_selection_set, including when the
/// selection was cleared or the assistant has never had a selection.
public struct WorkModelSelectionSnapshot: Equatable, Sendable, Decodable {
    public let revision: Int64
    public let selection: WorkModelSelection?

    public init(revision: Int64, selection: WorkModelSelection?) {
        self.revision = revision
        self.selection = selection
    }

    public func permitsCloudEffortWrite(at managedRevision: Int64) -> Bool {
        // Revision zero has no row to lock. The two server writers use
        // different advisory locks, and the managed insert can upsert over Work.
        selection == nil && revision > 0 && revision == managedRevision
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Field.self)
        revision = try fields.integer("revision")
        selection = try fields.nullable("selection")
    }
}

public enum WorkModelSelectionWriteResult: Equatable, Sendable {
    case saved(WorkModelSelectionSnapshot)
    case conflict
}

struct WorkModelSelectionReadRequest: Encodable {
    let operation = "work_selection_read"
    let agentPrincipal: NativeID
}

struct WorkModelSelectionWriteRequest: Encodable {
    let operation = "work_selection_set"
    let agentPrincipal: NativeID
    let expectedRevision: Int64
    let selection: WorkModelSelection
}

struct WorkModelSelectionWriteReply: Decodable {
    let snapshot: WorkModelSelectionSnapshot

    init(from decoder: Decoder) throws {
        let revision = try decoder.container(keyedBy: Field.self).integer("revision", minimum: 1)
        snapshot = .init(revision: revision, selection: try WorkModelSelection(from: decoder))
    }
}
