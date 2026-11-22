import AtumChat
import CryptoKit
import Foundation

/// Platform #909's authenticated Shell Stop for one exact Hermes execution.
public enum CloudScheduleStop {
    static let path = "/api/host/stop"
    static let bridgeHeader = "X-Atum-Host-Bridge-Contract"
    static let bridgeVersion = "atum.s2.host-bridge/1.0.0"

    public struct Request: Encodable, Equatable, Sendable {
        public struct Source: Encodable, Equatable, Sendable {
            public let kind = "schedule"
            public let job: String
            public let execution: String
        }

        public let agent: NativeID
        public let requestId: NativeID
        public let source: Source

        public init(agent: NativeID, execution: ChatScheduleExecution) throws {
            self.agent = agent
            self.source = Source(job: execution.job, execution: execution.execution)
            // The same stable UUIDv8 desktop uses, including across retries
            // after the chat is reopened. Shell scopes the receipt by owner.
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            let identity = try encoder.encode(["atum.schedule-stop", agent.rawValue, execution.job, execution.execution])
            var bytes = Array(SHA256.hash(data: identity).prefix(16))
            bytes[6] = (bytes[6] & 0x0f) | 0x80
            bytes[8] = (bytes[8] & 0x3f) | 0x80
            let hex = bytes.map { String(format: "%02x", Int($0)) }
            let id = [hex[0..<4], hex[4..<6], hex[6..<8], hex[8..<10], hex[10..<16]]
                .map { $0.joined() }.joined(separator: "-")
            requestId = try NativeID(id)
        }

        public func body() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self)
        }
    }

    private struct Receipt: Decodable {
        enum State: String, Decodable { case interrupted, finished, pending, unknown }
        let ok: Bool
        let requestId: NativeID
        let state: State
        let cancelled: Bool
        let interrupted: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["ok", "requestId", "state", "cancelled", "interrupted"])
            ok = try c.value("ok")
            requestId = try c.value("requestId")
            state = try c.value("state")
            cancelled = try c.value("cancelled")
            interrupted = try c.value("interrupted")
        }
    }

    public static func result(status: Int, data: Data, for request: Request) throws -> AssistantTurnStopResult {
        guard status == 200 else { return .failed }
        let receipt = try NativeAPI.decode(Receipt.self, from: data)
        let didInterrupt = receipt.state == .interrupted
        guard receipt.ok, receipt.requestId == request.requestId, receipt.cancelled == didInterrupt,
              receipt.interrupted == didInterrupt else { throw ContractViolation.invariant }
        switch receipt.state {
        case .interrupted: return .stopped
        case .finished: return .completed
        case .pending, .unknown: return .stopRequested
        }
    }
}
