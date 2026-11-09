import Foundation

/// The active Cloud disclosure from `GET /cloud/disclosure`, the route the
/// desktop reads as `cloud-disclosure`. `kind` must be `cloud`; a version
/// outside the contract is not a version this build may send as consent.
public struct CloudDisclosureResponse: Decodable, Equatable, Sendable {
    public let kind: String
    public let version: Int64

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["kind", "version"])
        kind = try c.value("kind")
        version = try c.integer("version", minimum: 1)
        guard kind == "cloud", version <= Int64(Int32.max) else { throw ContractViolation.invalidValue }
    }
}

/// `POST /assistant` (`atum.cloud-first-use/1` `bootstrap.response`): the
/// account's default assistant and starter allocation, created on first
/// sign-in under any retry. The caller keeps no identity from it beyond this
/// reply; the ignored `starter` object is the allocation the platform records.
public struct AssistantProvisionResponse: Decodable, Equatable, Sendable {
    public let agentPrincipal: NativeID
    public let matrixUser: NativeMatrixUser

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        agentPrincipal = try c.value("agentPrincipal")
        matrixUser = try c.value("matrixUser")
    }
}
