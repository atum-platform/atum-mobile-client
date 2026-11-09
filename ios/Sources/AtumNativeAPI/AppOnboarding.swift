import Foundation
import Security

/// Typed consumer of the frozen `atum.mobile-native-api/1.3`,
/// `atum.app-bots/1.1`, and `atum.claims/2.1` phone surface.
public enum AppOnboardingPolicy {
    public static let callbackOrigin = "https://api.atumplatform.com"
    public static let callbackPathPrefix = "/atum/app-link/"

    /// The disclosure version the phone's one generic consent text covers. A
    /// catalog app on any other version keeps the continue-on-computer handoff
    /// until the phone ships a reader for it.
    public static let genericDisclosureVersion: Int64 = 1

    /// Moon and Andy ship a contained first-contact reader at their own
    /// version (atum.app-bots/1.1); every other catalog app is read at the
    /// generic version. An old or newer version is deliberately unsupported
    /// here so it keeps the P0 handoff.
    public static func supports(disclosureVersion: Int64, for slug: String) -> Bool {
        switch slug {
        case "moon": disclosureVersion == 3
        case "andy": disclosureVersion == 2
        default: disclosureVersion == genericDisclosureVersion
        }
    }

    public static func allowsLaunch(slug: String, routeID: String) -> Bool {
        switch slug {
        case "moon": routeID == "readings" || routeID == "chat"
        case "andy": routeID == "chat"
        default: false
        }
    }

    public static func allowsComposerRoute(slug: String, routeID: String) -> Bool {
        slug == "moon" && routeID == "readings"
    }

    /// Whether the intake the provider reports may be shown or accepted. Moon
    /// and Andy pin the exact schema their copy was written for; any other app
    /// takes the schema the provider declares, which `AppIntakeStatus` has
    /// already validated field by field.
    public static func acceptsIntake(_ intake: AppIntakeStatus, for slug: String) -> Bool {
        switch slug {
        case "moon":
            let required: [String: AppIntakeStatus.FieldSpec.Kind] = [
                "preferred_name": .text, "dob": .date, "birth_time": .time,
                "birth_city": .text, "gender": .select,
            ]
            guard intake.fields.count == required.count,
                  intake.fields.allSatisfy({ required[$0.name] == $0.kind }),
                  Set(intake.fields.map(\.name)) == Set(required.keys),
                  let gender = intake.fields.first(where: { $0.name == "gender" }) else { return false }
            return Set(gender.options?.map(\.value) ?? []) == Set(["male", "female"])
        case "andy":
            return intake.complete && intake.fields.isEmpty && intake.missing.isEmpty
        default:
            return true
        }
    }
}

public enum AppBotConsentLocale: String, Codable, CaseIterable, Sendable {
    case vietnamese = "vi"
    case english = "en"
    case japanese = "ja"
    case chineseSimplified = "zh"
    case chineseTraditional = "zh-hant"

    public init?(designLocale: String) {
        switch designLocale.lowercased() {
        case "vi": self = .vietnamese
        case "en": self = .english
        case "ja": self = .japanese
        case "zh", "zh-hans": self = .chineseSimplified
        case "zh-hant": self = .chineseTraditional
        default: return nil
        }
    }
}

public struct AppBotConsentRequest: Encodable, Equatable, Sendable {
    public let disclosureVersion: Int64
    public let locale: AppBotConsentLocale

    public init(disclosureVersion: Int64, locale: AppBotConsentLocale) throws {
        guard (1...2_147_483_647).contains(disclosureVersion) else {
            throw ContractViolation.invalidValue
        }
        self.disclosureVersion = disclosureVersion
        self.locale = locale
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(disclosureVersion, forKey: Field("disclosure_version"))
        try c.encode(locale, forKey: Field("locale"))
    }
}

public struct AppBotSetupStatus: Decodable, Equatable, Sendable {
    public static let profile = "atum.app-bot-status/1"

    public struct Consent: Decodable, Equatable, Sendable {
        public enum State: String, Decodable, Sendable { case required, revoked, accepted }
        public let state: State
        public let disclosureVersion: Int64
        public let locale: AppBotConsentLocale?
        public let acceptedAt: NativeTimestamp?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["state", "disclosure_version", "locale", "accepted_at"])
            state = try c.value("state")
            disclosureVersion = try c.integer("disclosure_version", minimum: 1)
            locale = try c.nullable("locale")
            acceptedAt = try c.nullable("accepted_at")
            guard disclosureVersion <= 2_147_483_647,
                  (state == .accepted) == (locale != nil && acceptedAt != nil) else {
                throw ContractViolation.invariant
            }
        }
    }

    public struct Link: Decodable, Equatable, Sendable {
        public enum State: String, Decodable, Sendable { case neverLinked = "never_linked", linked, unlinked }
        public let state: State
        public let ready: Bool
        public let available: Bool

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["state", "ready", "available"])
            state = try c.value("state")
            ready = try c.value("ready")
            available = try c.value("available")
            guard !ready || (state == .linked && available) else { throw ContractViolation.invariant }
        }
    }

    /// The additive guest projection (atum.app-bots guest contract). Absent
    /// on an older platform and for a linked-only bot.
    public struct Guest: Decodable, Equatable, Sendable {
        public enum State: String, Decodable, Sendable {
            case unsupported
            case startRequired = "start_required"
            case ready, linked, unavailable
        }
        public let enabled: Bool
        public let state: State

        public init(from decoder: Decoder) throws {
            // Additive fields are ignored; the two this phone acts on are exact.
            let c = try decoder.container(keyedBy: Field.self)
            enabled = try c.value("enabled")
            state = try c.value("state")
            // A guest-disabled bot is exactly the unsupported state.
            guard enabled != (state == .unsupported) else { throw ContractViolation.invariant }
        }
    }

    public let bot: AppBotDescriptor?
    public let consent: Consent
    public let link: Link
    public let roomID: MatrixRoomID?
    public let guest: Guest?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        // A newer platform may add fields to this status. The recognized
        // authority-bearing fields below stay exact; unknown ones are ignored.
        guard try c.value("profile", as: String.self) == Self.profile else {
            throw ContractViolation.invalidValue
        }
        bot = try c.nullable("bot")
        consent = try c.value("consent")
        link = try c.value("link")
        roomID = try c.nullable("room_id")
        guest = try c.optional("guest")
        if let guest {
            // A linked guest state needs a ready linked account; a guest-enabled
            // bot with a linked account is only linked or unavailable.
            guard guest.state != .linked || (link.state == .linked && link.ready && link.available),
                  !(guest.enabled && link.state == .linked
                    && guest.state != .linked && guest.state != .unavailable) else {
                throw ContractViolation.invariant
            }
        }
    }
}

public struct AppLinkNonce: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let rawValue: String
    public var description: String { "AppLinkNonce([redacted])" }
    public var debugDescription: String { description }

    public init(_ value: String) throws {
        rawValue = try checkedString(value, minimum: 43, maximum: 43, pattern: "[A-Za-z0-9_-]{43}")
    }

    public init(bytes: Data) throws {
        guard bytes.count == 32 else { throw ContractViolation.invalidValue }
        try self.init(bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: ""))
    }

    public static func random() throws -> AppLinkNonce {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ContractViolation.invalidValue
        }
        return try AppLinkNonce(bytes: Data(bytes))
    }

    public var redirectURL: URL {
        // The validated alphabet cannot introduce a delimiter or escaping.
        URL(string: AppOnboardingPolicy.callbackOrigin + AppOnboardingPolicy.callbackPathPrefix + rawValue)!
    }
}

public struct AppLinkConnectRequest: Encodable, Equatable, Sendable {
    public let nonce: AppLinkNonce
    public init(nonce: AppLinkNonce) { self.nonce = nonce }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(nonce.redirectURL.absoluteString, forKey: Field("redirect_uri"))
    }
}

public struct AppLinkConnectResponse: Decodable, Equatable, Sendable {
    public let authorizationURL: URL
    public let initiationID: NativeID

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["authorize_url", "initiation_id"])
        let raw = try c.string("authorize_url", minimum: 1, maximum: 2_048)
        guard let url = URL(string: raw), url.absoluteString == raw,
              url.scheme == "https", url.host != nil, url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw ContractViolation.invalidValue
        }
        authorizationURL = url
        initiationID = try c.value("initiation_id")
    }
}

public struct AppLinkReturnProof: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let initiationID: NativeID
    public let returnCode: String
    public var description: String { "AppLinkReturnProof([redacted])" }
    public var debugDescription: String { description }

    public static func parse(_ url: URL, nonce: AppLinkNonce,
                             initiationID expected: NativeID) throws -> AppLinkReturnProof {
        let raw = url.absoluteString
        let prefix = nonce.redirectURL.absoluteString + "?code="
        guard raw.hasPrefix(prefix), url.scheme == "https", url.host == "api.atumplatform.com",
              url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.percentEncodedPath == AppOnboardingPolicy.callbackPathPrefix + nonce.rawValue,
              let query = components.percentEncodedQuery,
              !query.contains("%"),
              query.hasPrefix("code=") else { throw ContractViolation.invalidValue }
        let parts = query.split(separator: "&", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              parts[0].hasPrefix("code="), parts[1].hasPrefix("initiation_id="),
              !parts[0].dropFirst(5).isEmpty, !parts[1].dropFirst(14).isEmpty else {
            throw ContractViolation.invalidValue
        }
        let code = String(parts[0].dropFirst(5))
        _ = try checkedString(code, minimum: 43, maximum: 43, pattern: "[A-Za-z0-9_-]{43}")
        let returned = try NativeID(String(parts[1].dropFirst(14)))
        guard returned.rawValue == returned.rawValue.lowercased(), returned == expected,
              raw == nonce.redirectURL.absoluteString + "?code=" + code
                + "&initiation_id=" + returned.rawValue else {
            throw ContractViolation.invalidValue
        }
        return AppLinkReturnProof(initiationID: returned, returnCode: code)
    }
}

public struct AppLinkConfirmRequest: Encodable, Equatable, Sendable {
    public let initiationID: NativeID
    public let returnCode: String
    public let disclosureVersion: Int64

    public init(proof: AppLinkReturnProof, disclosureVersion: Int64) throws {
        guard (1...2_147_483_647).contains(disclosureVersion) else {
            throw ContractViolation.invalidValue
        }
        initiationID = proof.initiationID
        returnCode = proof.returnCode
        self.disclosureVersion = disclosureVersion
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(initiationID, forKey: Field("initiation_id"))
        try c.encode(returnCode, forKey: Field("return_code"))
        try c.encode(true, forKey: Field("confirmation"))
        try c.encode(ConsentProvenance(disclosureVersion: disclosureVersion),
                     forKey: Field("consent_provenance"))
    }

    private struct ConsentProvenance: Encodable {
        let disclosureVersion: Int64
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Field.self)
            try c.encode(Chat(disclosureVersion: disclosureVersion), forKey: Field("chat"))
            try c.encode(ExactPair(), forKey: Field("exact_pair"))
        }
    }
    private struct Chat: Encodable {
        let disclosureVersion: Int64
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Field.self)
            try c.encode("accepted", forKey: Field("state"))
            try c.encode(disclosureVersion, forKey: Field("disclosure_version"))
        }
    }
    private struct ExactPair: Encodable {
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Field.self)
            try c.encode("accepted", forKey: Field("state"))
            try c.encode("provider_page", forKey: Field("source"))
        }
    }
}

public struct AppLinkConfirmResponse: Decodable, Equatable, Sendable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["status"])
        guard try c.value("status", as: String.self) == "confirmed" else {
            throw ContractViolation.invalidValue
        }
    }
}

public struct AppConnectionSnapshot: Decodable, Equatable, Sendable {
    public struct Connection: Decodable, Equatable, Sendable {
        public enum State: String, Decodable, Sendable { case neverLinked = "never_linked", linked, unlinked }
        public enum Readiness: String, Decodable, Sendable { case notLinked = "not_linked", pending, ready, unavailable }
        public enum Cleanup: String, Decodable, Sendable { case pending, complete, unconfirmed }
        public let state: State
        public let connectionRequired: Bool
        public let cleanup: Cleanup?
        public let available: Bool
        public let readiness: Readiness

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["state", "connectionRequired", "cleanup", "available", "readiness"])
            state = try c.value("state")
            connectionRequired = try c.value("connectionRequired")
            cleanup = try c.optional("cleanup")
            available = try c.value("available")
            readiness = try c.value("readiness")
            guard (state == .linked) != (readiness == .notLinked) else {
                throw ContractViolation.invariant
            }
        }
    }

    public struct Initiation: Decodable, Equatable, Sendable {
        public enum Step: String, Decodable, Sendable { case idle, inProgress = "in_progress", awaitingConfirmation = "awaiting_confirmation", consumed, incomplete }
        public let step: Step
        public let initiationID: NativeID?

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["step", "initiation_id"])
            step = try c.value("step")
            initiationID = try c.optional("initiation_id")
            guard (step == .idle) == (initiationID == nil) else { throw ContractViolation.invariant }
        }
    }

    public let connection: Connection
    public let initiation: Initiation
    public let app: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["connection", "initiation", "app"])
        connection = try c.value("connection")
        initiation = try c.value("initiation")
        let appObject: AppSlugEnvelope = try c.value("app")
        app = appObject.slug
    }

    private struct AppSlugEnvelope: Decodable {
        let slug: String
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["slug"])
            slug = try c.string("slug", minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_-]{0,63}")
        }
    }
}

public struct AppIntakeStatus: Decodable, Equatable, Sendable {
    public struct FieldSpec: Decodable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Decodable, Sendable { case text, date, time, select }
        public struct Option: Decodable, Equatable, Sendable {
            public let value: String
            public let label: String
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Field.self)
                try c.closed(["value", "label"])
                value = try c.string("value", minimum: 1, maximum: 512)
                label = try c.string("label", minimum: 1, maximum: 1_000)
            }
        }
        public let name: String
        public let kind: Kind
        public let options: [Option]?
        public var id: String { name }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["name", "type", "options"])
            name = try c.string("name", minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_]*")
            kind = try c.value("type")
            options = try c.optional("options")
            guard (kind == .select) == (options != nil),
                  (options?.isEmpty == false || options == nil),
                  (options?.count ?? 0) <= 64,
                  Set(options?.map(\.value) ?? []).count == (options?.count ?? 0) else {
                throw ContractViolation.invariant
            }
        }
    }

    public let complete: Bool
    public let missing: [String]
    public let fields: [FieldSpec]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["complete", "missing", "fields"])
        complete = try c.value("complete")
        missing = try c.value("missing")
        fields = try c.value("fields")
        guard missing.count <= 32, fields.count <= 32,
              Set(missing).count == missing.count,
              Set(fields.map(\.name)).count == fields.count,
              missing.allSatisfy({ name in
                  (try? checkedString(name, minimum: 1, maximum: 64,
                                      pattern: "[a-z][a-z0-9_]*")) != nil
                      && fields.contains(where: { $0.name == name })
              }), !complete || missing.isEmpty else { throw ContractViolation.invariant }
    }

    /// Only missing fields are submitted. Provider-held known values are not
    /// blanked or collected again when the current provider response cannot
    /// safely return them.
    public var missingFields: [FieldSpec] {
        let names = Set(missing)
        return fields.filter { names.contains($0.name) }
    }
}

public struct AppIntakeSubmission: Encodable, Equatable, Sendable {
    public let values: [String: String]
    public init(values: [String: String], fields: [AppIntakeStatus.FieldSpec]) throws {
        guard !fields.isEmpty, fields.count <= 32,
              Set(fields.map(\.name)) == Set(values.keys) else { throw ContractViolation.invalidValue }
        var normalized = [String: String]()
        for field in fields {
            let value = values[field.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty, value.unicodeScalars.count <= 512 else {
                throw ContractViolation.invalidValue
            }
            normalized[field.name] = value
        }
        self.values = normalized
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        for (key, value) in values { try c.encode(value, forKey: Field(key)) }
    }
}

public enum AppIntakeSubmissionFailure: Error, Equatable, Sendable {
    case invalid(field: String?)
}

struct AppIntakeErrorResponse: Decodable {
    let field: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["error", "field"])
        guard try c.value("error", as: String.self) == "invalid_request" else {
            throw ContractViolation.invalidValue
        }
        field = try c.optional("field")
        if let field {
            _ = try checkedString(field, minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_]*")
        }
    }
}

public struct AppWorkspaceSnapshot: Decodable, Equatable, Sendable {
    public struct Route: Decodable, Equatable, Sendable, Identifiable {
        public enum Placement: String, Decodable, Sendable { case menu, composer }
        public enum Session: String, Decodable, Sendable { case required, none }
        public let id: String
        public let placements: [Placement]
        public let session: Session

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["id", "label", "icon", "path", "placements", "session"])
            id = try c.string("id", minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_-]{0,63}")
            _ = try c.value("label", as: LocalizedRouteLabel.self)
            _ = try c.string("icon", minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9-]{0,63}")
            _ = try c.string("path", minimum: 1, maximum: 512)
            placements = try c.value("placements")
            session = try c.value("session")
            guard !placements.isEmpty, placements.count <= 2,
                  Set(placements.map(\.rawValue)).count == placements.count else {
                throw ContractViolation.invariant
            }
        }
    }

    public let slug: String
    public let appVersionID: AppCatalogID
    public let routes: [Route]
    public let supportsLaunch: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["profile", "descriptor", "manifest", "web_origin", "network_origins"])
        guard try c.value("profile", as: String.self) == "atum.app-workspace/1" else {
            throw ContractViolation.invalidValue
        }
        let descriptor: WorkspaceDescriptor = try c.value("descriptor")
        let manifest: WorkspaceManifest = try c.value("manifest")
        guard descriptor.slug == manifest.slug,
              descriptor.appVersionID == manifest.appVersionID else { throw ContractViolation.invariant }
        slug = descriptor.slug
        appVersionID = descriptor.appVersionID
        routes = manifest.routes
        supportsLaunch = manifest.supportsLaunch
        guard routes.count <= 32, Set(routes.map(\.id)).count == routes.count,
              supportsLaunch || routes.allSatisfy({ $0.session == .none }) else {
            throw ContractViolation.invariant
        }
    }

    private struct WorkspaceDescriptor: Decodable {
        let slug: String
        let appVersionID: AppCatalogID
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            slug = try c.string("app", minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_-]{0,63}")
            appVersionID = try c.value("app_version_id")
        }
    }

    private struct WorkspaceManifest: Decodable {
        let slug: String
        let appVersionID: AppCatalogID
        let routes: [Route]
        let supportsLaunch: Bool
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            guard try c.value("profile", as: String.self) == "atum.remote-app-manifest/1" else {
                throw ContractViolation.invalidValue
            }
            let app: ManifestApp = try c.value("app")
            slug = app.slug
            appVersionID = app.appVersionID
            routes = try c.value("routes")
            supportsLaunch = !(try c.decodeNil(forKey: Field("launch")))
        }
    }

    private struct ManifestApp: Decodable {
        let slug: String
        let appVersionID: AppCatalogID
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            slug = try c.string("slug", minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_-]{0,63}")
            appVersionID = try c.value("app_version_id")
        }
    }

    private struct LocalizedRouteLabel: Decodable {
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["vi", "en"])
            _ = try c.string("vi", minimum: 1, maximum: 120)
            _ = try c.string("en", minimum: 1, maximum: 120)
        }
    }
}

public struct AppLaunchRequest: Encodable, Equatable, Sendable {
    public let appVersionID: AppCatalogID
    public let routeID: String

    public init(appVersionID: AppCatalogID, routeID: String) throws {
        _ = try checkedString(routeID, minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_-]{0,63}")
        self.appVersionID = appVersionID
        self.routeID = routeID
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        try c.encode(appVersionID.rawValue, forKey: Field("app_version_id"))
        try c.encode(routeID, forKey: Field("route_id"))
    }
}

public struct AppLaunchResponse: Decodable, Equatable, Sendable {
    public let launchURL: URL
    public let expiresAt: NativeTimestamp

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["launch_url", "expires_at"])
        let raw = try c.string("launch_url", minimum: 1, maximum: 2_048)
        guard let url = URL(string: raw), url.absoluteString == raw,
              url.scheme == "https", url.host != nil, url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.count == 1,
              items[0].name == "code", let code = items[0].value,
              (try? checkedString(code, minimum: 43, maximum: 43,
                                  pattern: "[A-Za-z0-9_-]{43}")) != nil else {
            throw ContractViolation.invalidValue
        }
        launchURL = url
        expiresAt = try c.value("expires_at")
    }
}
