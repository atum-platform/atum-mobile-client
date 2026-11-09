import Foundation

/// The platform's closed official-accounts answer
/// (`atum.official-accounts/1`, atum-platform
/// `spec/official-accounts/v1/README.md`). Only the named Founder and the
/// listed tiers draw marks or start a Founder chat. The optional roster fields
/// are presentation only; `user_id`, `tier` and `role` remain the whole trust
/// authority.
public struct OfficialAccountsResponse: Decodable, Equatable, Sendable {
    public static let profile = "atum.official-accounts/1"
    public static let maximumAccounts = 64

    public struct Founder: Decodable, Equatable, Sendable {
        public let userID: String

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            userID = try Self.userID(c, key: "user_id")
            // `updates_room_id` and any later optional field are additive and
            // are deliberately not copied into the phone's state.
        }

        fileprivate static func userID(_ c: KeyedDecodingContainer<Field>,
                                       key: String) throws -> String {
            try c.string(key, minimum: 4, maximum: 1024,
                         pattern: "@[a-z0-9._=/-]{1,255}:[A-Za-z0-9.-]{1,253}(?::[0-9]{1,5})?")
        }
    }

    public enum Tier: String, Decodable, Sendable {
        case official
        case verified
    }

    public enum Role: String, Decodable, Sendable {
        case founder
    }

    public struct Account: Decodable, Equatable, Sendable {
        public let userID: String
        public let tier: Tier
        public let role: Role?
        public let handle: String?
        /// Effective owner-scoped presentation, absent on an older producer.
        public let rosterDefault: Bool?
        public let rosterOrder: Int64?
        public let rosterState: AppDescriptor.RosterState?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            userID = try Founder.userID(c, key: "user_id")
            tier = try c.value("tier")

            if c.contains(Field("role")) {
                role = try c.decodeIfPresent(Role.self, forKey: Field("role"))
            } else {
                role = nil
            }

            if c.contains(Field("handle")) {
                handle = try c.decodeIfPresent(NativeHandle.self, forKey: Field("handle"))?.rawValue
            } else {
                handle = nil
            }

            if c.contains(Field("roster_default")) {
                rosterDefault = try c.decode(Bool.self, forKey: Field("roster_default"))
            } else {
                rosterDefault = nil
            }

            if c.contains(Field("roster_order")) {
                let value = try c.value("roster_order", as: WireInteger.self).value
                guard (0...2_147_483_647).contains(value) else {
                    throw ContractViolation.invalidValue
                }
                rosterOrder = value
            } else {
                rosterOrder = nil
            }

            if c.contains(Field("roster_state")) {
                rosterState = try c.value("roster_state", as: AppDescriptor.RosterState.self)
            } else {
                rosterState = nil
            }
        }
    }

    public let founder: Founder?
    public let accounts: [Account]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard try c.value("profile", as: String.self) == Self.profile else {
            throw ContractViolation.invalidValue
        }

        founder = try c.nullable("founder", as: Founder.self)
        accounts = try c.value("accounts")
        guard accounts.count <= Self.maximumAccounts,
              Set(accounts.map(\.userID)).count == accounts.count else {
            throw ContractViolation.invariant
        }

        let roles = accounts.compactMap { account in
            account.role == .founder ? account : nil
        }
        if let founder {
            guard roles.count == 1, roles[0].userID == founder.userID,
                  roles[0].tier == .official else {
                throw ContractViolation.invariant
            }
        } else {
            guard roles.isEmpty else { throw ContractViolation.invariant }
        }
    }

    /// The effective Founder row presentation, or nil while the platform names
    /// no Founder. Absent optional fields keep the legacy default/available
    /// behavior; `coming_soon` suppresses automatic creation but grants
    /// nothing and never removes an existing chat.
    public var founderRoster: OfficialFounderRoster? {
        guard let founder else { return nil }
        let row = accounts.first { $0.userID == founder.userID }
        return OfficialFounderRoster(defaultVisible: row?.rosterDefault ?? true,
                                     order: row?.rosterOrder ?? 0,
                                     state: row?.rosterState ?? .available)
    }

    public var founderHandle: String? {
        guard let founder else { return nil }
        return accounts.first { $0.userID == founder.userID }?.handle
    }
}

/// The Founder's effective roster presentation. It moves no identity and is
/// never a permission, a room grant or an invitation.
public struct OfficialFounderRoster: Equatable, Sendable {
    public let defaultVisible: Bool
    public let order: Int64
    public let state: AppDescriptor.RosterState

    public init(defaultVisible: Bool, order: Int64, state: AppDescriptor.RosterState) {
        self.defaultVisible = defaultVisible
        self.order = order
        self.state = state
    }
}

/// The retry gate for the native official-accounts read. Product refreshes,
/// foreground returns and account-service recovery are the phone's bounded
/// triggers; this gate makes those triggers a single flight and prevents a
/// refused/unavailable endpoint from becoming a hot retry loop. A successful
/// answer is still refreshed on the next explicit trigger, matching the
/// platform contract. The last-good answer lives in the caller's `NativeRead`
/// and is intentionally not persisted here.
public struct OfficialAccountsRetryCadence: Equatable, Sendable {
    public struct Scope: Equatable, Sendable {
        public let accountID: String
        public let generation: UInt64

        public init(accountID: String, generation: UInt64) {
            self.accountID = accountID
            self.generation = generation
        }
    }

    public static let firstFailureDelay: TimeInterval = 5 * 60
    public static let maximumFailureDelay: TimeInterval = 6 * 60 * 60

    public private(set) var scope: Scope?
    public private(set) var failures = 0
    public private(set) var nextAllowedAt: Date?
    public private(set) var isReading = false

    public init() {}

    /// Changes account/session ownership atomically. A late completion from
    /// the previous generation is ignored by `succeed`/`fail`.
    public mutating func activate(_ scope: Scope?) {
        guard scope != self.scope else { return }
        self.scope = scope
        failures = 0
        nextAllowedAt = nil
        isReading = false
    }

    /// Begins at most one read, and only after the current failure delay.
    public mutating func begin(scope: Scope, now: Date) -> Bool {
        activate(scope)
        guard !isReading else { return false }
        if let nextAllowedAt, now < nextAllowedAt { return false }
        isReading = true
        return true
    }

    /// A good answer clears the failure delay. It does not impose a success
    /// TTL: start/refresh/foreground remain the contract's explicit triggers.
    @discardableResult
    public mutating func succeed(scope: Scope) -> Bool {
        guard self.scope == scope, isReading else { return false }
        isReading = false
        failures = 0
        nextAllowedAt = nil
        return true
    }

    /// The transport or owner changed while a read was running. Release the
    /// single-flight slot without turning a deliberate discard/cancellation
    /// into a service failure or extending the retry delay.
    @discardableResult
    public mutating func abandon(scope: Scope) -> Bool {
        guard self.scope == scope, isReading else { return false }
        isReading = false
        return true
    }

    /// Failures back off 5m, 10m, 20m… up to 6h. A valid 429 Retry-After can
    /// only lengthen that delay; it can never shorten the bounded backoff.
    @discardableResult
    public mutating func fail(scope: Scope, now: Date,
                              retryAfterSeconds: Int64? = nil) -> Bool {
        guard self.scope == scope, isReading else { return false }
        isReading = false
        failures = min(failures + 1, 63)
        let exponent = min(failures - 1, 16)
        let multiplier = pow(2.0, Double(exponent))
        let backoff = min(Self.maximumFailureDelay,
                          Self.firstFailureDelay * multiplier)
        let asked = retryAfterSeconds.map { TimeInterval(max(0, $0)) } ?? 0
        nextAllowedAt = now.addingTimeInterval(max(backoff, asked))
        return true
    }
}
