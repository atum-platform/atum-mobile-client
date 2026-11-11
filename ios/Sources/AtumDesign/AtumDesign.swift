import Foundation

/// Generated resources consumed without a producer checkout or network.
public enum AtumDesign {
    public static let supportedSchemaVersion = 1

    public struct Manifest: Decodable {
        public let schemaVersion: Int
        public let developmentLanguage: String
        public let locales: [String]
        public let files: [String: String]
    }

    public enum ResourceError: Error {
        case missingResource(String)
        case unsupportedSchema(Int)
        case unlistedResource(String)
    }

    public static func manifest() throws -> Manifest {
        let source = try decodeManifest(Data(contentsOf: resourceURL("manifest.json")))
        // The retained producer manifest also inventories test fixtures. Those
        // files are not members of this production resource bundle.
        return Manifest(schemaVersion: source.schemaVersion,
                        developmentLanguage: source.developmentLanguage,
                        locales: source.locales,
                        files: source.files.filter { !$0.key.hasPrefix("fixtures/") })
    }

    public static func decodeManifest(_ data: Data) throws -> Manifest {
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw ResourceError.unsupportedSchema(manifest.schemaVersion)
        }
        return manifest
    }

    public static func data(for path: String) throws -> Data {
        try Data(contentsOf: url(for: path))
    }

    /// URL for native font registration; the manifest remains the allowlist.
    public static func url(for path: String) throws -> URL {
        guard try manifest().files[path] != nil else {
            throw ResourceError.unlistedResource(path)
        }
        return try resourceURL(path)
    }

    private static func resourceURL(_ path: String) throws -> URL {
        guard let root = Bundle.module.resourceURL else {
            throw ResourceError.missingResource(path)
        }
        let url = root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ResourceError.missingResource(path)
        }
        return url
    }
}
