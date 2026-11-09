import Foundation

/// The retry identity of one logical agent-home owner write
/// (`atum.agent-home/2.5`): the bearer `meta.requestId` and the operation
/// `idempotencyKey`.
///
/// A retry of the same preflight, move, cancel or model write reuses BOTH. The
/// platform records the bearer request ID (and refuses to rebind it to another
/// message) apart from the idempotency key that fences the effect itself, and
/// authentication metadata is not part of the effect: a retry that repeats only
/// one of the two is not the same request twice. Neither is made again until the
/// owner starts another logical operation.
public struct AgentHomeOwnerWriteIdentity: Hashable, Sendable {
    public let requestID: NativeID
    public let idempotencyKey: NativeID

    /// Whether a failed attempt carries the platform's final word, after which
    /// its identity must not be reused. A refusal the platform made (400, 403,
    /// 404, 409) is final: repeating it under the same identity can only repeat
    /// the refusal. Everything else leaves the outcome unknown (a dropped
    /// connection, a timeout, a 503, a rate limit or a reply that could not be
    /// read may all follow a write that DID land), so the retry repeats it.
    public static func isFinalAnswer(_ error: Error) -> Bool {
        guard case let .http(failure)? = error as? NativeDomainClientFailure else { return false }
        switch failure.response.error {
        case .badRequest, .denied, .notFound, .conflict: return true
        case .unauthenticated, .rateLimited, .unavailable: return false
        }
    }
}

/// The identity of the one owner write whose outcome may be unknown, kept with
/// the payload it was made for.
///
/// - `begin(_:)` returns the pending identity only for an identical payload; any
///   other payload is another logical operation and gets a fresh pair, dropping
///   the stale one. The payload must therefore name every effect field that can
///   change between attempts: a changed effect under a reused identity is a
///   conflict, not a retry.
/// - `settled()` ends the operation. Call it on a definitive answer (applied, or
///   a refusal), never on a transport failure, which may have reached the
///   platform.
public struct AgentHomeOwnerWrites<Payload: Hashable & Sendable>: Sendable {
    // The two halves move in lockstep: both begin and settle together.
    private var requestIDs = ModelWriteRequests<Payload>()
    private var idempotencyKeys = ModelWriteRequests<Payload>()

    public init() {}

    /// The payload whose outcome is unknown, if any.
    public var pendingPayload: Payload? { idempotencyKeys.pendingPayload }

    public mutating func begin(_ payload: Payload,
                               makeID: () -> NativeID = ModelWriteRequests<Payload>.freshID)
        -> AgentHomeOwnerWriteIdentity {
        AgentHomeOwnerWriteIdentity(requestID: requestIDs.begin(payload, makeID: makeID),
                                    idempotencyKey: idempotencyKeys.begin(payload, makeID: makeID))
    }

    public mutating func settled() {
        requestIDs.settled()
        idempotencyKeys.settled()
    }
}
