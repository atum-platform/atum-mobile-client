import Foundation

/// One open listing (platform 0535 `matrix_open_agent_catalog`): an assistant
/// anyone can hire, read from `GET /agents?catalog=open` (desktop
/// `listMatrixOpenAgents`, `electron/matrix/agent-definition.ts`). Titles and
/// summaries are keyed by locale; the seat price is the ordinary hire, in
/// whole Protons. The catalog's accent colour is ignored (the Kit allows no
/// raw colour) and its emoji is only a key for a Phosphor glyph.
public struct OpenAgentListing: Decodable, Equatable, Identifiable, Sendable {
    public let listingID: String
    public let displayName: String
    public let title: [String: String]
    public let summary: [String: String]
    public let glyph: String?
    public let skills: [String]
    /// Whole Protons for one seat month. Shown only when `hireRequired`.
    public let seatPriceProtons: Int64
    /// True when this hire is the owner's third or later assistant: the price
    /// is confirmed before it is made.
    public let hireRequired: Bool

    public var id: String { listingID }

    public init(listingID: String, displayName: String, title: [String: String] = [:],
                summary: [String: String] = [:], glyph: String? = nil, skills: [String] = [],
                seatPriceProtons: Int64, hireRequired: Bool) throws {
        guard Self.validListingID(listingID) else { throw ContractViolation.invalidValue }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count), seatPriceProtons >= 0 else { throw ContractViolation.invalidValue }
        self.listingID = listingID
        self.displayName = name
        self.title = title
        self.summary = summary
        self.glyph = glyph
        self.skills = skills
        self.seatPriceProtons = seatPriceProtons
        self.hireRequired = hireRequired
    }

    public init(from decoder: Decoder) throws {
        // The row may carry merchandising fields the phone does not draw
        // (accent, visibility, revision): an open row, as desktop reads it.
        let c = try decoder.container(keyedBy: Field.self)
        try self.init(
            listingID: c.value("listingId"),
            displayName: c.value("displayName"),
            title: Self.localized(c, "title"),
            summary: Self.localized(c, "summary"),
            glyph: c.lossyNullable("glyph", as: String.self).flatMap { $0.unicodeScalars.count <= 16 ? $0 : nil },
            skills: c.lossyNullable("skills", as: [String].self) ?? [],
            seatPriceProtons: c.integer("seatPriceProtons"),
            hireRequired: c.value("hireRequired")
        )
    }

    /// A listing id the platform accepts (`open/agents/researcher`): 1–128 characters.
    static func validListingID(_ value: String) -> Bool {
        (1...128).contains(value.count)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    /// A localized catalog string: `{ vi, en, ... }` or one plain string.
    /// Unusable values drop rather than failing the row.
    private static func localized(_ c: KeyedDecodingContainer<Field>, _ key: String) -> [String: String] {
        if let plain = c.lossyNullable(key, as: String.self) {
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [:] : ["en": plain]
        }
        guard let map = c.lossyNullable(key, as: [String: LossyString].self) else { return [:] }
        return map.compactMapValues { value in
            guard let text = value.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
    }

    /// The text this listing shows in a locale: its own, then the language's,
    /// then English, then the fallback (desktop `listingText`).
    public static func text(_ values: [String: String], locale: String, fallback: String = "") -> String {
        let lowered = locale.lowercased()
        let language = lowered.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? lowered
        return values[locale] ?? values[lowered] ?? values[language] ?? values["en"] ?? fallback
    }

    public func title(locale: String) -> String {
        Self.text(title, locale: locale, fallback: displayName)
    }

    public func summary(locale: String) -> String {
        Self.text(summary, locale: locale)
    }
}

private struct LossyString: Decodable {
    let text: String?
    init(from decoder: Decoder) throws {
        text = try? decoder.singleValueContainer().decode(String.self)
    }
}

/// The open catalog. A row the phone cannot show is left out rather than
/// failing the shelf; anything but a list is an empty shelf.
public struct OpenAgentCatalog: Decodable, Equatable, Sendable {
    public let listings: [OpenAgentListing]

    public init(listings: [OpenAgentListing]) { self.listings = listings }

    public init(from decoder: Decoder) throws {
        guard let decoded = try? LossyDecodableArray<OpenAgentListing>(from: decoder) else {
            listings = []
            return
        }
        // Twelve rows is already more than the sheet could show well; the
        // platform's slice 1 has one.
        listings = Array(decoded.elements.prefix(12))
    }
}

/// How the platform answered a listing hire (desktop `MatrixAgentRefusal`,
/// `electron/matrix/main.ts` `createLifecycle().refusal`). `.hireRequired`,
/// `.short` and `.retry` lead to another try under the same request; the
/// others are shown as final answers.
///
/// The platform charges the seat in `matrix_agent_create_finish` (0314),
/// after the reservation and the MAS identity, and keeps provisioning after
/// that (definition seed, Hermes, owner snapshot). Any of those later steps
/// can still answer 400, 403, 404, 409 or 503, so only the name rules' own
/// refusal (422 with an `assistant_name_*` code, raised by
/// `matrix_agent_create_begin` before anything is reserved or charged) ends
/// the request. Every other answer keeps its UUID, and the next try resumes
/// it: the charge is keyed by the request, so it is never made twice.
public enum OpenAgentHireRefusal: Equatable, Sendable {
    /// Third or later assistant: confirm this price (whole Protons) first.
    case hireRequired(priceProtons: Int64?)
    /// The wallet can't cover the seat.
    case short
    /// The platform's name rules refused the name, before any charge.
    case name
    case limit
    case account
    /// Nothing final: a lost answer, an outage, or a refusal that can follow
    /// the charge (a bare 400). The same request resumes.
    case retry

    public static func from(_ failure: Error) -> OpenAgentHireRefusal {
        guard let failure = failure as? NativeDomainClientFailure else { return .retry }
        switch failure {
        case .assistantName: return .name
        case let .http(http):
            let reason = http.response.details?.reason
            switch http.response.error {
            case .conflict where reason == "hire_required":
                return .hireRequired(priceProtons: http.response.details?.hirePriceProtons)
            case .conflict where reason == "hire_insufficient_protons": return .short
            case .conflict: return .limit
            // Desktop reads a 400 as a name refusal. Names are refused with
            // 422 and their own code; a bare 400 (`matrix_invalid`) can come
            // from a provisioning step after the seat was charged, so it is
            // retried under the same request instead.
            case .denied, .notFound: return .account
            default: return .retry
            }
        default: return .retry
        }
    }

    /// Whether the request stays pending, so the next Hire, Retry or relaunch
    /// resumes it under the same request ID. Only a refusal the platform makes
    /// before it reserves or charges anything (the name rules) lets it go.
    public var keepsRequest: Bool {
        switch self {
        case .name: return false
        case .hireRequired, .short, .limit, .account, .retry: return true
        }
    }
}

/// Where the platform placed a newly created assistant (`cloud_placement`,
/// `apps/shell/src/lib/cloud-agent-create.ts`). Absent when the cloud did
/// not apply. Only `placed` means it answers now; the others mean its chat
/// is still being set up (`pending_trust`, `capacity`) or it was made
/// Mac-run (`no_access`, `consent_mismatch`).
public enum AgentCloudPlacement: String, Decodable, Equatable, Sendable {
    case placed
    case pendingTrust = "pending_trust"
    case capacity
    case noAccess = "no_access"
    case consentMismatch = "consent_mismatch"
}

/// `POST /agents`'s answer: the agent, and where it was placed. An unknown
/// or malformed placement is absent rather than failing the create, whose
/// charge has already happened.
public struct AgentCreateResponse: Decodable, Equatable, Sendable {
    public let agent: AgentsResponse.Agent
    public let placement: AgentCloudPlacement?

    public init(agent: AgentsResponse.Agent, placement: AgentCloudPlacement?) {
        self.agent = agent
        self.placement = placement
    }

    private enum Key: String, CodingKey { case placement = "cloud_placement" }

    public init(from decoder: Decoder) throws {
        agent = try AgentsResponse.Agent(from: decoder)
        let c = try decoder.container(keyedBy: Key.self)
        placement = (try? c.decodeIfPresent(AgentCloudPlacement.self, forKey: .placement)) ?? nil
    }
}
