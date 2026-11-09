import Foundation
import AtumNativeAPI

public struct NativeTurnFixtures {
    public struct Manifest: Decodable {
        public struct Fixture: Decodable {
            public let file, expect, sha256: String
            public let message, machine: String?
        }
        public let contractId, providerCommit, packSHA256: String
        public let fixtures: [Fixture]
    }
    public let manifest: Manifest
    public let answer: AgentAnswer
    public let notice: AgentStatusNotice
    public init() throws {
        manifest = try JSONDecoder().decode(Manifest.self, from: Self.resource("manifest.json"))
        answer = try AgentTurns.answer(Self.resource("answer.content.json"))
        notice = try AgentTurns.notice(Self.resource("status-notice.content.json"))
    }
    public func data(_ name: String) throws -> Data {
        guard manifest.fixtures.contains(where: { $0.file == name }) else { throw ContractViolation.invalidValue }
        return try Self.resource(name)
    }
    private static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: "Fixtures", withExtension: nil)?
            .appendingPathComponent("provider-turns-v1").appendingPathComponent(name) else { throw ContractViolation.invalidValue }
        return try Data(contentsOf: url)
    }
}
