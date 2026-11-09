import Foundation

/// Installed Store artwork exported by the desktop producer. The live Store
/// catalog still decides which rows exist; this inventory only answers whether
/// this build has local art for a server-authored item ID.
public struct AtumStoreArtCatalog: Decodable, Equatable, Sendable {
    public struct Item: Decodable, Equatable, Sendable {
        public let resource: String
        public let sha256: String
    }

    public let schemaVersion: Int
    public let items: [String: Item]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        items = try container.decode([String: Item].self, forKey: .items)
        guard schemaVersion == 1, !items.isEmpty, items.count <= 1_000 else {
            throw CatalogError.invalid
        }

        var resources = Set<String>()
        for (itemID, item) in items {
            guard Self.validItemID(itemID),
                  Self.safePath(item.resource, prefix: "store/", suffix: ".png"),
                  Self.digest(item.sha256),
                  resources.insert(item.resource).inserted else {
                throw CatalogError.invalid
            }
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    public static func load() throws -> Self {
        try decode(AtumDesign.data(for: "store-art.json"))
    }

    public func resource(for itemID: String) -> String? {
        items[itemID]?.resource
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, items }
    private enum CatalogError: Error { case invalid }

    private static func digest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static func validItemID(_ value: String) -> Bool {
        guard value.count <= 128, let slash = value.firstIndex(of: "/"),
              slash != value.startIndex, slash != value.index(before: value.endIndex) else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...122).contains($0.value)
                || $0 == "/" || $0 == "_" || $0 == "-"
        }
    }

    private static func safePath(_ value: String, prefix: String, suffix: String) -> Bool {
        value.count <= 512 && value.hasPrefix(prefix) && value.hasSuffix(suffix)
            && !value.contains("\\") && !value.split(separator: "/").contains("..")
    }
}
