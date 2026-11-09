import Foundation

/// Registration is provider configuration, never permission to register a client.
public struct OIDCClientRegistration: Decodable, Sendable {
    public let clientID, name: String
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self); try c.closed(["client_id", "client_name", "client_auth_method", "redirect_uris"])
        clientID = try c.string("client_id", minimum: 26, maximum: 26, pattern: "[0-9A-HJKMNP-TV-Z]{26}")
        name = try c.string("client_name", minimum: 1, maximum: 64)
        guard try c.value("client_auth_method", as: String.self) == "none",
              try c.value("redirect_uris", as: [String].self) == [MASPublicClients.callback.absoluteString] else { throw ContractViolation.invariant }
    }
}

/// Display/lifecycle only. It holds no token and grants no transport authority.
/// Activation needs a verified three-way binding, not a decoded fixture fact.
public struct OIDCDomainLifecycle: Sendable {
    public enum State: String, Decodable, Sendable {
        case authorizing, active, refreshing, revoked
        case signedOut = "signed_out", reauthRequired = "reauth_required"
    }
    enum Event: String, Decodable {
        case start, refreshed
        case grantedAndBound = "granted_and_bound", cancelledOrDenied = "cancelled_or_denied", subjectMismatch = "subject_mismatch"
        case expiringOr401 = "expiring_or_401", refreshRefused = "refresh_refused", revokedElsewhere = "revoked_elsewhere"
        case personRetries = "person_retries", signOut = "sign_out"
    }
    public private(set) var state = State.signedOut
    public private(set) var binding: OIDCAccountBinding?
    public init() {}
    @discardableResult public mutating func start() -> Bool { advance(state == .reauthRequired ? .personRetries : .start) }
    @discardableResult public mutating func cancel() -> Bool { advance(.cancelledOrDenied) }
    @discardableResult public mutating func activate(_ verified: OIDCAccountBinding) -> Bool {
        guard advance(.grantedAndBound) else { return false }; binding = verified; return true
    }
    @discardableResult public mutating func rejectSubject() -> Bool { advance(.subjectMismatch) }
    @discardableResult public mutating func signOut() -> Bool { advance(.signOut) }
    @discardableResult public mutating func revokedElsewhere() -> Bool { advance(.revokedElsewhere) }
    // Native refresh coordinator will call these only after persistence proof.
    @discardableResult mutating func advance(_ event: Event) -> Bool {
        let next: State?
        switch (state, event) {
        case (.signedOut, .start), (.reauthRequired, .personRetries): next = .authorizing
        case (.authorizing, .grantedAndBound), (.refreshing, .refreshed): next = .active
        case (.authorizing, .cancelledOrDenied): next = .signedOut
        case (.authorizing, .subjectMismatch), (.active, .signOut), (.reauthRequired, .signOut): next = .revoked
        case (.active, .expiringOr401): next = .refreshing
        case (.refreshing, .refreshRefused), (.active, .revokedElsewhere): next = .reauthRequired
        default: next = nil
        }
        guard let next else { return false }
        state = next
        if next == .revoked || next == .signedOut { binding = nil }
        return true
    }
}
