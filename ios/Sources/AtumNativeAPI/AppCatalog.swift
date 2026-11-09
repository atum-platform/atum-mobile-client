import Foundation

/// Server-authored display data for eligible remote applications. A catalog is
/// not a launch grant, Matrix-room membership, or a provider connection.
public struct AppCatalogResponse: Decodable, Equatable, Sendable {
    public static let profile = "atum.app-catalog/1"

    public let apps: [AppDescriptor]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard try c.value("profile", as: String.self) == Self.profile else {
            throw ContractViolation.invalidValue
        }
        apps = try c.value("apps")
        guard apps.count <= 100 else { throw ContractViolation.invalidValue }

        var ids = Set<String>()
        var slugs = Set<String>()
        for app in apps {
            guard ids.insert(app.appID.rawValue).inserted,
                  slugs.insert(app.app).inserted else {
                throw ContractViolation.invariant
            }
        }
    }
}

/// A deliberately data-only app projection. URLs and routes in a later
/// workspace/launch contract remain main-process authority, never UI input.
public struct AppDescriptor: Decodable, Equatable, Identifiable, Sendable {
    public enum Availability: String, Decodable, Sendable { case available, unavailable }
    public enum SupportedMode: String, Decodable, Sendable { case direct, privateGroup = "private_group", sharedGroup = "shared_group" }
    public enum MatrixRoomContext: String, Sendable { case addressedOnly = "addressed_only" }
    public enum Verification: String, Sendable { case official, verified }
    /// Closed optional roster presentation state. Absence is legacy/available;
    /// this never changes `availability` or grants a launch surface.
    public enum RosterState: String, Decodable, Sendable {
        case available
        case comingSoon = "coming_soon"
    }

    public let app: String
    public let appID: AppCatalogID
    public let appVersionID: AppCatalogID
    public let name: AppLocalizedCopy
    public let subtitle: AppLocalizedCopy?
    public let description: AppLocalizedCopy?
    public let icon: AppCatalogIcon?
    public let accent: String?
    /// Unknown future affiliations stay present as data and must not be
    /// interpreted as a platform endorsement.
    public let affiliation: String?
    public let verified: Bool
    /// An optional additive desktop presentation field. Only the two known
    /// values carry display meaning; unknown values deliberately render none.
    public let verification: Verification?
    public let availability: Availability
    public let rosterDefault: Bool
    public let rosterOrder: Int64
    /// Nil when an older producer omitted the additive field. Consumers must
    /// use `effectiveRosterState`, never infer a state from availability or
    /// names.
    public let rosterState: RosterState?
    public let supportedModes: [SupportedMode]
    /// Unknown/older context does not imply Matrix support or a key grant.
    public let matrixRoomContext: MatrixRoomContext?
    public let hasSurface: Bool
    public let link: AppLink
    /// Older catalog providers may omit this; a supplied value is fully
    /// validated before an app can be represented as a chat identity.
    public let bot: AppBotDescriptor?

    public var id: AppCatalogID { appID }

    /// Absent legacy presentation is available. A coming-soon entry is never
    /// promoted to available here.
    public var effectiveRosterState: RosterState { rosterState ?? .available }

    /// The same ordered, server-declared art sources Desktop presents: the
    /// official Matrix bot identity first, then the app icon. Each URL stays
    /// paired with its own digest, and consumers may try the next candidate
    /// when the preferred format cannot be rendered natively. No app name or
    /// slug participates in selection.
    public var displayAvatarCandidates: [AppCatalogIcon] {
        AppAvatarCandidates.candidates(for: self)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        // Catalog v1 explicitly permits added presentation fields. Do not make
        // one into authority just because a newer server supplied it.
        app = try c.string("app", minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_-]{0,63}")
        appID = try c.value("app_id")
        appVersionID = try c.value("app_version_id")
        name = try c.value("name")
        subtitle = try c.nullable("subtitle")
        description = try c.nullable("description")
        icon = try c.nullable("icon")
        accent = try c.nullable("accent")
        affiliation = try c.nullable("affiliation")
        verified = try c.value("verified")
        availability = try c.value("availability")
        rosterDefault = try c.value("roster_default")
        rosterOrder = try c.integer("roster_order")
        guard rosterOrder <= 2_147_483_647 else { throw ContractViolation.invalidValue }
        supportedModes = try c.value("supported_modes")
        hasSurface = try c.value("has_surface")
        link = try c.value("link")

        if let accent {
            _ = try checkedString(accent, minimum: 7, maximum: 7, pattern: "#[0-9a-fA-F]{6}")
        }
        if let affiliation {
            guard !affiliation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ContractViolation.invalidValue
            }
            _ = try checkedString(affiliation, minimum: 1, maximum: 64)
        }
        guard supportedModes.count <= 3,
              Set(supportedModes.map(\.rawValue)).count == supportedModes.count else {
            throw ContractViolation.invalidValue
        }

        if c.contains(Field("verification")) {
            let raw = try c.decodeIfPresent(String.self, forKey: Field("verification"))
            verification = raw.flatMap(Verification.init(rawValue:))
        } else {
            verification = nil
        }
        if c.contains(Field("matrix_room_context")) {
            let raw = try c.decodeIfPresent(String.self, forKey: Field("matrix_room_context"))
            matrixRoomContext = raw.flatMap(MatrixRoomContext.init(rawValue:))
        } else {
            matrixRoomContext = nil
        }
        if c.contains(Field("bot")) {
            bot = try c.decodeIfPresent(AppBotDescriptor.self, forKey: Field("bot"))
        } else {
            bot = nil
        }

        // The additive field is a closed enum, not a free-form hint. An
        // unknown value, including a future one, must fail the read instead of
        // silently choosing a default placement.
        let parsedRosterState: RosterState?
        if c.contains(Field("roster_state")) {
            let raw = try c.decode(String.self, forKey: Field("roster_state"))
            guard let state = RosterState(rawValue: raw) else {
                throw ContractViolation.invalidValue
            }
            parsedRosterState = state
        } else {
            parsedRosterState = nil
        }

        // A presentation-only entry can never carry executable availability,
        // a bot identity, a surface or a link mode. Refuse an incoherent
        // producer instead of presenting a launchable "coming soon" row.
        if parsedRosterState == .comingSoon {
            guard availability == .unavailable, bot == nil, !hasSurface,
                  link.mode == .none else {
                throw ContractViolation.invariant
            }
        }
        rosterState = parsedRosterState
    }
}

/// Pure presentation projection for every app-catalog consumer. Candidate
/// order never depends on a known app slug: the declared bot identity is
/// preferred, the declared app icon is its fallback, and exact duplicate
/// URL/digest pairs collapse without separating either digest from its URL.
public enum AppAvatarCandidates {
    public static func candidates(for app: AppDescriptor) -> [AppCatalogIcon] {
        var result = [AppCatalogIcon]()
        for candidate in [app.bot?.avatar, app.icon].compactMap({ $0 })
            where !result.contains(candidate) {
            result.append(candidate)
        }
        return result
    }
}

public struct AppCatalogID: Decodable, Hashable, Sendable {
    public let rawValue: String

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        _ = try checkedString(raw, minimum: 36, maximum: 36,
            pattern: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}")
        rawValue = raw.lowercased()
    }
}

public struct AppLocalizedCopy: Decodable, Equatable, Sendable {
    public let values: [String: String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard c.allKeys.count <= 16 else { throw ContractViolation.invalidValue }
        var copy: [String: String] = [:]
        for key in c.allKeys {
            let locale = try checkedString(key.stringValue, minimum: 2, maximum: 35,
                pattern: "[a-z]{2,3}(-[A-Za-z0-9]{2,8})*")
            let phrase = try c.decode(String.self, forKey: key)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, phrase.utf16.count <= 1_000 else {
                throw ContractViolation.invalidValue
            }
            copy[locale] = phrase
        }
        values = copy
    }

    public func localized(locale: String, fallback: String = "") -> String {
        values[locale] ?? values["en"] ?? fallback
    }
}

public struct AppCatalogIcon: Decodable, Equatable, Sendable {
    public let url: URL
    public let sha256: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        // The platform and desktop parser both strip additive presentation
        // fields here. Only these two fields receive any native meaning.
        let value = try c.string("url", minimum: 1, maximum: 2_048)
        guard let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil,
              url.password == nil, url.fragment == nil else {
            throw ContractViolation.invalidValue
        }
        self.url = url
        sha256 = try c.string("sha256", minimum: 64, maximum: 64, pattern: "[0-9a-f]{64}")
    }
}

public struct AppLink: Decodable, Equatable, Sendable {
    public enum Mode: String, Decodable, Sendable { case none, externalAccount = "external_account" }
    public enum State: String, Decodable, Sendable { case neverLinked = "never_linked", linked, unlinked }

    public let mode: Mode
    public let state: State

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        // Additive fields are presentation-only and deliberately ignored.
        mode = try c.value("mode")
        state = try c.value("state")
        guard mode != .none || state == .neverLinked else { throw ContractViolation.invariant }
    }
}

/// An optional, official app-owned Matrix bot from the desktop catalog. It is
/// presentational identity only; it never creates a room or trusts a device.
public struct AppBotDescriptor: Decodable, Equatable, Sendable {
    public enum State: String, Decodable, Sendable { case starting, active, paused, unavailable }
    public enum Consent: String, Decodable, Sendable { case accepted, required }
    public enum TransportMode: String, Equatable, Sendable {
        case legacyTurn = "legacy_turn"
        case botAPI = "bot_api"
    }

    public struct Device: Decodable, Equatable, Sendable {
        public let deviceID: String
        public let ed25519: String
        public let curve25519: String

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            // Desktop safely ignores additive bot presentation fields.
            deviceID = try c.string("device_id", minimum: 1, maximum: 255, pattern: "[A-Za-z0-9._=-]+")
            ed25519 = try c.string("ed25519", minimum: 43, maximum: 43, pattern: "[A-Za-z0-9+/]{43}")
            curve25519 = try c.string("curve25519", minimum: 43, maximum: 43, pattern: "[A-Za-z0-9+/]{43}")
        }
    }

    public let userID: NativeMatrixUser
    public let handle: String
    public let displayName: String
    public let avatar: AppCatalogIcon
    public let deviceGeneration: Int64
    public let device: Device?
    public let state: State
    public let groups: Bool
    public let consent: Consent
    public let disclosureVersion: Int64
    public let openRouteID: String
    public let openSharedMemory: Bool
    public let purchaseRouteID: String
    /// The signed catalog chooses only the transport/setup path. Older,
    /// malformed and future values stay on the compatibility transport; they
    /// never fail the containing catalog or opt an app into Bot API.
    public let transportMode: TransportMode
    /// The reviewed guest capability. Absent on an older catalog means
    /// linked-only; an unreadable value is treated as absent, never as a grant.
    public let guestEnabled: Bool
    /// `atum.turn-memory/2` is the direct-turn authority a guest chat needs.
    public let directProfile: String?

    /// A guest chat is a direct-chat capability that stands only on the
    /// explicit guest flag together with the v2 turn profile.
    public var supportsGuestChat: Bool {
        guestEnabled && directProfile == Self.guestDirectProfile
    }

    /// The bot can take a chat now: published, running, with a device.
    public var isStartable: Bool { state == .active && device != nil }

    public static let guestDirectProfile = "atum.turn-memory/2"

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        guard try c.integer("v", minimum: 1) == 1 else { throw ContractViolation.invalidValue }
        let rawUserID = try c.string("user_id", minimum: 1, maximum: 1_024,
            pattern: "@app-[a-z][a-z0-9_-]*:atumplatform[.]com")
        userID = try NativeAPI.decode(NativeMatrixUser.self, from: JSONEncoder().encode(rawUserID))
        handle = try c.string("handle", minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_]*_bot")
        displayName = try c.string("display_name", minimum: 1, maximum: 120)
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContractViolation.invalidValue
        }
        avatar = try c.value("avatar")
        deviceGeneration = try c.integer("device_generation", minimum: 1)
        device = try c.nullable("device")
        state = try c.value("state")
        groups = try c.value("groups")
        consent = try c.value("consent")
        disclosureVersion = try c.integer("disclosure_version", minimum: 1)
        openRouteID = try c.string("open_route_id", minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_-]{0,63}")
        openSharedMemory = try c.value("open_shared_memory")
        purchaseRouteID = try c.string("purchase_route_id", minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_-]{0,63}")
        let rawTransportMode = ((try? c.decodeIfPresent(
            String.self, forKey: Field("transport_mode")
        )) ?? nil)
        transportMode = rawTransportMode.flatMap(TransportMode.init(rawValue:)) ?? .legacyTurn
        guestEnabled = ((try? c.decodeIfPresent(Bool.self, forKey: Field("guest_enabled"))) ?? nil) ?? false
        let profile = ((try? c.decodeIfPresent(String.self, forKey: Field("direct_profile"))) ?? nil)
        directProfile = profile.flatMap { ["atum.turn-memory/1", Self.guestDirectProfile].contains($0) ? $0 : nil }
        guard device != nil || state != .active else { throw ContractViolation.invariant }
    }
}
