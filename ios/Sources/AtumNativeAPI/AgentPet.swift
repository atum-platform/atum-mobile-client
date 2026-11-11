import Foundation

/// The pet one assistant has, as the platform's `GET /agents/{id}/pet` returns
/// it (desktop `MatrixPetSnapshot`, `apps/desktop/shared/matrix-pet.ts`). The
/// phone only reads it, for the card's Pet row; choosing a pet is a later
/// slice. Only the fields the row needs are decoded.
public struct AgentPetSelection: Decodable, Equatable, Sendable {
    public enum Reference: Equatable, Sendable {
        case bundled(slug: String)
        case personal(petID: String)
        /// A catalog or petdex pet, or a kind this build does not know. Desktop
        /// draws no sprite for these, so the row says "Choose".
        case other
    }

    public struct Binding: Decodable, Equatable, Sendable {
        public let ref: Reference?
        public let enabled: Bool

        public init(ref: Reference?, enabled: Bool) {
            self.ref = ref
            self.enabled = enabled
        }

        private enum CodingKeys: String, CodingKey { case ref, enabled }
        private enum RefKeys: String, CodingKey { case kind, slug, pet_id }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decode(Bool.self, forKey: .enabled)
            guard container.contains(.ref), try !container.decodeNil(forKey: .ref) else {
                ref = nil
                return
            }
            let value = try container.nestedContainer(keyedBy: RefKeys.self, forKey: .ref)
            switch try value.decode(String.self, forKey: .kind) {
            case "bundled": ref = .bundled(slug: try value.decode(String.self, forKey: .slug))
            case "personal": ref = .personal(petID: try value.decode(String.self, forKey: .pet_id))
            default: ref = .other
            }
        }
    }

    public let agent: String
    public let revision: Int64
    /// Nil when nothing is saved (never chosen, or the chosen pet is no
    /// longer accessible). An explicit "no companion" is a binding.
    public let pet: Binding?

    public init(agent: String, revision: Int64, pet: Binding?) {
        self.agent = agent
        self.revision = revision
        self.pet = pet
    }
}

/// The part of `GET /agents/{id}/pets` (desktop `MatrixPetCatalog`) that names
/// pets: the shelf's items and the account's own hatched pets.
public struct AgentPetCatalog: Decodable, Equatable, Sendable {
    public enum Access: String, Decodable, Sendable { case owned, visiting, available }

    public struct Item: Decodable, Equatable, Sendable {
        public let ref: AgentPetSelection.Reference
        public let name: String
        public let access: Access?

        public init(ref: AgentPetSelection.Reference, name: String, access: Access?) {
            self.ref = ref
            self.name = name
            self.access = access
        }

        private enum CodingKeys: String, CodingKey { case ref, name, access }
        private enum RefKeys: String, CodingKey { case kind, slug, pet_id }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            access = try? container.decode(Access.self, forKey: .access)
            let value = try container.nestedContainer(keyedBy: RefKeys.self, forKey: .ref)
            switch try value.decode(String.self, forKey: .kind) {
            case "bundled": ref = .bundled(slug: try value.decode(String.self, forKey: .slug))
            case "personal": ref = .personal(petID: try value.decode(String.self, forKey: .pet_id))
            default: ref = .other
            }
        }
    }

    public struct PersonalPet: Decodable, Equatable, Sendable {
        public let petID: String
        public let displayName: String
        public let deletedAt: String?

        public init(petID: String, displayName: String, deletedAt: String? = nil) {
            self.petID = petID
            self.displayName = displayName
            self.deletedAt = deletedAt
        }

        private enum CodingKeys: String, CodingKey {
            case petID = "pet_id", displayName = "display_name", deletedAt = "deleted_at"
        }
    }

    public let agent: String
    public let items: [Item]
    public let personal: [PersonalPet]

    public init(agent: String, items: [Item], personal: [PersonalPet]) {
        self.agent = agent
        self.items = items
        self.personal = personal
    }
}

/// The name the card's Pet row shows, decided the way desktop's
/// `useAgentPetName` + `MatrixPets.read` decide whether a sprite is drawn.
public enum AgentPetName {
    /// Desktop's bundled pets, with the `displayName` of each
    /// `apps/desktop/assets/pets/<slug>/pet.json`. These are proper names, the
    /// same in every language, and desktop reads them from the asset, not the
    /// catalog.
    public static let bundled: [String: String] = [
        "gigi": "Gigi", "cookie": "Cookie", "bailey": "Bailey", "mochi": "Mochi",
    ]

    /// Whether the catalog is needed to name this selection: a personal pet
    /// is named by the account's library, and the primary's unsaved stand-in
    /// (Gigi) only shows while the catalog grants her.
    public static func needsCatalog(_ selection: AgentPetSelection, isPrimary: Bool) -> Bool {
        guard let pet = selection.pet else { return isPrimary }
        guard pet.enabled, case .personal? = pet.ref else { return false }
        return true
    }

    /// The pet's name, or nil for "Choose".
    public static func resolve(_ selection: AgentPetSelection, catalog: AgentPetCatalog?,
                               isPrimary: Bool) -> String? {
        guard let pet = selection.pet else {
            // Nothing saved: the primary shows Gigi while the platform says the
            // account owns her or is visiting her. Display only.
            guard isPrimary, let catalog,
                  catalog.items.contains(where: {
                      $0.ref == .bundled(slug: "gigi") && ($0.access == .owned || $0.access == .visiting)
                  }) else { return nil }
            return bundled["gigi"]
        }
        guard pet.enabled, let ref = pet.ref else { return nil }
        switch ref {
        case let .bundled(slug):
            return bundled[slug]
        case let .personal(petID):
            // A personal pet is shown only while the fresh library still has it.
            guard let record = catalog?.personal.first(where: { $0.petID == petID && $0.deletedAt == nil })
            else { return nil }
            let name = record.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        case .other:
            return nil
        }
    }
}
