import Foundation
import AtumNativeAPI

/// These placeholders are for conformance; never use them for real sign-in.
public struct NativeAuthFixtures {
    public let manifest: NativeTurnFixtures.Manifest
    public init() throws {
        manifest = try JSONDecoder().decode(NativeTurnFixtures.Manifest.self, from: Self.resource("manifest.json"))
    }
    public func data(_ name: String) throws -> Data {
        guard manifest.fixtures.contains(where: { $0.file == name }) else { throw ContractViolation.invalidValue }
        return try Self.resource(name)
    }
    private static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)?
            .appendingPathComponent("provider-auth-v1").appendingPathComponent(name) else { throw ContractViolation.invalidValue }
        return try Data(contentsOf: url)
    }
}
