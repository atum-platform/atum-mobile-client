/// S6's read-only Store section order. Purchase authority deliberately does
/// not enter this projection.
public enum StoreSectionKind: Int, CaseIterable, Equatable, Sendable {
    case featured
    case apps
    case assistants
    case skills
    case pets
}

public struct StoreProjection: Equatable, Sendable {
    public enum EntryKind: Equatable, Sendable {
        case app
        case assistant
        case skill
        case pet
    }

    public struct Entry: Equatable, Sendable {
        public let id: String
        public let kind: EntryKind
        public let featured: Bool

        public init(id: String, kind: EntryKind, featured: Bool = false) {
            self.id = id
            self.kind = kind
            self.featured = featured
        }
    }

    public struct Section: Equatable, Sendable {
        public let kind: StoreSectionKind
        public let entryIDs: [String]
    }

    /// A featured catalog item appears once, in Featured. Applications keep
    /// their server order and are never inferred to be purchasable.
    public static func sections(_ entries: [Entry]) -> [Section] {
        StoreSectionKind.allCases.compactMap { section in
            let ids = entries.compactMap { entry -> String? in
                switch section {
                case .featured:
                    return entry.featured && entry.kind != .app ? entry.id : nil
                case .apps:
                    return entry.kind == .app ? entry.id : nil
                case .assistants:
                    return !entry.featured && entry.kind == .assistant ? entry.id : nil
                case .skills:
                    return !entry.featured && entry.kind == .skill ? entry.id : nil
                case .pets:
                    return !entry.featured && entry.kind == .pet ? entry.id : nil
                }
            }
            return ids.isEmpty ? nil : Section(kind: section, entryIDs: ids)
        }
    }
}

