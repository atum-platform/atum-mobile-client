import Foundation

/// The public-handle directory as an assistant's owner uses it
/// (`spec/public-handles/v1`, platform `matrix-alias-directory.ts`): check a
/// handle, read the assistant's current one, claim a first one, rename it.
/// Every call names the assistant by its directory ID; the platform derives
/// the owner from the bearer and refuses anyone else's assistant.
public enum AgentAliasCheckCode: String, Sendable, Equatable, CaseIterable {
    case invalid = "alias_invalid"
    case botSuffixRequired = "alias_bot_suffix_required"
    case botSuffixReserved = "alias_bot_suffix_reserved"
    case reserved = "alias_reserved"
    case unavailable = "alias_unavailable"
}

/// `GET aliases/check`: `{handle, available, code}`, where `available` is
/// exactly `code == null`.
public struct AgentAliasCheck: Decodable, Equatable, Sendable {
    public let handle: NativeHandle?
    public let available: Bool
    public let code: AgentAliasCheckCode?

    public init(handle: NativeHandle?, available: Bool, code: AgentAliasCheckCode?) {
        self.handle = handle
        self.available = available
        self.code = code
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["handle", "available", "code"])
        handle = try c.nullable("handle")
        available = try c.value("available")
        let raw: String? = try c.nullable("code")
        if let raw {
            guard let value = AgentAliasCheckCode(rawValue: raw) else { throw ContractViolation.invalidValue }
            code = value
        } else {
            code = nil
        }
        guard available == (code == nil) else { throw ContractViolation.invariant }
    }
}

/// `POST aliases/claim` and `POST aliases/rename`: the new assignment. A
/// rename also names the handle it replaced (held for 30 days).
public struct AgentAliasAssignment: Decodable, Equatable, Sendable {
    public let handle: NativeHandle
    public let principal: NativeID
    public let generation: Int64
    public let previous: NativeHandle?
    public let replayed: Bool

    public init(handle: NativeHandle, principal: NativeID, generation: Int64,
                previous: NativeHandle? = nil, replayed: Bool = false) {
        self.handle = handle
        self.principal = principal
        self.generation = generation
        self.previous = previous
        self.replayed = replayed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["handle", "state", "principal", "generation", "previous", "replayed"])
        let state: String = try c.value("state")
        guard state == "assigned" else { throw ContractViolation.invalidValue }
        handle = try c.value("handle")
        principal = try c.value("principal")
        generation = try c.integer("generation", minimum: 1)
        previous = try c.optional("previous")
        let replay: Bool? = try c.optional("replayed")
        guard replay == nil || replay == true else { throw ContractViolation.invalidValue }
        replayed = replay == true
        if let previous, previous == handle { throw ContractViolation.invariant }
    }
}

public struct AgentAliasClaimRequest: Encodable, Equatable, Sendable {
    public let handle: NativeHandle
    public let requestId: NativeID
    public let assistantId: NativeID

    public init(handle: NativeHandle, requestId: NativeID, assistantId: NativeID) {
        self.handle = handle
        self.requestId = requestId
        self.assistantId = assistantId
    }

    private enum CodingKeys: String, CodingKey { case handle, requestId, assistantId }
}

public struct AgentAliasRenameRequest: Encodable, Equatable, Sendable {
    public let handle: NativeHandle
    public let from: NativeHandle
    public let requestId: NativeID
    public let assistantId: NativeID

    public init(handle: NativeHandle, from: NativeHandle, requestId: NativeID,
                assistantId: NativeID) throws {
        guard handle != from else { throw ContractViolation.invariant }
        self.handle = handle
        self.from = from
        self.requestId = requestId
        self.assistantId = assistantId
    }

    private enum CodingKeys: String, CodingKey { case handle, from, requestId, assistantId }
}

/// Why the directory refused, in desktop's terms (`MatrixAliasErrorCode`,
/// `electron/matrix/aliases.ts`): 400 invalid, 401 authentication, 403
/// denied (or `closed` when claims are not open yet), 404 missing, 409
/// conflict, 429 limit (with the wait, when the platform names one), and
/// anything else unavailable.
public enum AgentAliasRefusal: Equatable, Sendable {
    case invalid
    case authentication
    case denied
    case closed
    case missing
    case conflict
    case limit(retryAfterSeconds: Int64?)
    case unavailable

    public static func from(_ failure: Error) -> AgentAliasRefusal {
        guard let failure = failure as? NativeDomainClientFailure else { return .unavailable }
        switch failure {
        case .authenticationRefused: return .authentication
        case let .http(http):
            switch http.response.error {
            case .badRequest: return .invalid
            case .unauthenticated: return .authentication
            case .denied: return http.response.details?.reason == "alias_claims_closed" ? .closed : .denied
            case .notFound: return .missing
            case .conflict: return .conflict
            case .rateLimited: return .limit(retryAfterSeconds: http.retryAfterSeconds)
            case .unavailable: return .unavailable
            }
        default: return .unavailable
        }
    }
}

/// `DELETE agents/{id}`: retiring is final and done in one platform
/// transaction (`matrix_agent_retire`). `sessionCleanup` reports only the
/// best-effort revocation of the assistant's executor sessions afterwards.
public struct AgentRetirement: Decodable, Equatable, Sendable {
    public enum SessionCleanup: String, Decodable, Sendable { case complete, pending, unconfirmed }
    public let id: NativeID
    public let sessionCleanup: SessionCleanup

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["id", "status", "sessionCleanup"])
        let status: String = try c.value("status")
        guard status == "retired" else { throw ContractViolation.invalidValue }
        id = try c.value("id")
        sessionCleanup = try c.value("sessionCleanup")
    }
}

/// The directory calls a handle walk needs, so the walk can be tested
/// without a network (the app passes `NativeDomainClient`'s methods).
public struct AgentAliasDirectoryCalls {
    public var current: @MainActor (NativeID) async throws -> AliasCurrentResponse
    public var check: @MainActor (NativeHandle, NativeID) async throws -> AgentAliasCheck
    public var claim: @MainActor (AgentAliasClaimRequest) async throws -> AgentAliasAssignment

    public init(current: @escaping @MainActor (NativeID) async throws -> AliasCurrentResponse,
                check: @escaping @MainActor (NativeHandle, NativeID) async throws -> AgentAliasCheck,
                claim: @escaping @MainActor (AgentAliasClaimRequest) async throws -> AgentAliasAssignment) {
        self.current = current
        self.check = check
        self.claim = claim
    }
}

/// How giving a new assistant its handle ended (desktop
/// `MatrixAgentHandleOutcome`).
public enum AgentHandleClaimOutcome: Equatable, Sendable {
    case claimed(NativeHandle)
    /// It already had this handle; nothing was claimed.
    case existing(NativeHandle)
    case refused(AgentAliasRefusal)
    /// Every candidate was taken or reserved.
    case exhausted

    /// Desktop `matrixAgentHandleRetryable`: only a refusal a Retry can
    /// change keeps the create sheet open. Closed, denied, missing, invalid
    /// and exhausted settle quietly; the card offers a handle later.
    public var isRetryable: Bool {
        switch self {
        case .claimed, .existing, .exhausted: return false
        case let .refused(reason):
            switch reason {
            case .closed, .denied, .missing, .invalid: return false
            case .authentication, .conflict, .limit, .unavailable: return true
            }
        }
    }
}

/// Desktop `claimMatrixAgentHandle`: gives an assistant that exists the
/// first free handle among `groups`. An assistant that already has one keeps
/// it, a reserved stem ends its group, and a claim lost between check and
/// claim (409) moves to the next candidate. `pending` is a claim whose answer
/// was lost earlier in this sheet: it is resent first with the same request
/// ID, so the platform replays it instead of claiming a second handle.
@MainActor
public enum AgentHandleClaimWalk {
    public static func run(assistantID: NativeID, groups: [[String]],
                           pending: AgentAliasClaimRequest? = nil,
                           calls: AgentAliasDirectoryCalls,
                           requestID: () -> NativeID,
                           onAttempt: (AgentAliasClaimRequest) -> Void = { _ in }) async -> AgentHandleClaimOutcome {
        if let pending, pending.assistantId == assistantID {
            do {
                let assignment = try await calls.claim(pending)
                return .claimed(assignment.handle)
            } catch {
                let refusal = AgentAliasRefusal.from(error)
                // A conflict means the earlier claim lost; anything else
                // leaves it unanswered and worth the same Retry.
                if refusal != .conflict { return .refused(refusal) }
            }
        }
        do {
            if case let .assigned(handle, _) = try await calls.current(assistantID) {
                return .existing(handle)
            }
        } catch {
            return .refused(AgentAliasRefusal.from(error))
        }
        for group in groups {
            for raw in group {
                guard let handle = try? NativeHandle(raw) else { continue }
                let check: AgentAliasCheck
                do { check = try await calls.check(handle, assistantID) }
                catch { return .refused(AgentAliasRefusal.from(error)) }
                guard check.available else {
                    if check.code == .reserved { break }
                    continue
                }
                let request = AgentAliasClaimRequest(handle: handle, requestId: requestID(),
                                                     assistantId: assistantID)
                onAttempt(request)
                do {
                    let assignment = try await calls.claim(request)
                    return .claimed(assignment.handle)
                } catch {
                    let refusal = AgentAliasRefusal.from(error)
                    if refusal == .conflict { continue }
                    return .refused(refusal)
                }
            }
        }
        return .exhausted
    }
}
