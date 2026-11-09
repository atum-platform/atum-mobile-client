import Foundation
import AtumNativeAPI

/// P2-only synthetic provider material. No network calls or deployment claims.
public struct NativeAPIFixtures {
    public struct Manifest: Decodable {
        public struct Fixture: Decodable {
            public let file, message, expect, sha256: String
        }
        public let contractId, providerCommit, packSHA256: String
        public let version: Int
        public let fixtures: [Fixture]
    }
    public let manifest: Manifest
    public init() throws {
        manifest = try JSONDecoder().decode(Manifest.self, from: Self.resource("manifest.json"))
    }
    public func data(_ name: String) throws -> Data {
        guard manifest.fixtures.contains(where: { $0.file == name }) else { throw ContractViolation.invalidValue }
        return try Self.resource(name)
    }
    public func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try NativeAPI.decode(type, from: data(name))
    }
    private static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)?
            .appendingPathComponent("provider-native-v1").appendingPathComponent(name) else { throw ContractViolation.invalidValue }
        return try Data(contentsOf: url)
    }
}
