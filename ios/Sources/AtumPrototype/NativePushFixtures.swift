import Foundation
import AtumNativeAPI

/// Immutable, synthetic contract-b samples; no push registration or APNs proof.
public struct NativePushFixtures {
    public let manifest: NativeAPIFixtures.Manifest
    public init() throws {
        manifest = try JSONDecoder().decode(NativeAPIFixtures.Manifest.self, from: Self.resource("manifest.json"))
    }
    public func data(_ name: String) throws -> Data {
        guard manifest.fixtures.contains(where: { $0.file == name }) else { throw ContractViolation.invalidValue }
        return try Self.resource(name)
    }
    private static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)?
            .appendingPathComponent("provider-push-v1").appendingPathComponent(name) else { throw ContractViolation.invalidValue }
        return try Data(contentsOf: url)
    }
}
