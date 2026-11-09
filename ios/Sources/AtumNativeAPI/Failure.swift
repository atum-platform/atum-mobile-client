import Foundation

public struct NativeErrorResponse: Decodable, Equatable, Sendable {
    public enum Code: String, Decodable, Sendable {
        case badRequest = "matrix_400", unauthenticated = "matrix_401", denied = "matrix_403", notFound = "matrix_404"
        case conflict = "matrix_409", rateLimited = "matrix_429", unavailable = "matrix_503"
        public var status: Int { Int(rawValue.dropFirst(7))! }
    }
    public struct Details: Decodable, Equatable, Sendable {
        public let reason, launchError: String?
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["reason", "launch_error"])
            reason = try c.optional("reason"); launchError = try c.optional("launch_error")
            for value in [reason, launchError].compactMap({ $0 }) {
                _ = try checkedString(value, minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_]*")
            }
        }
    }
    public let error: Code
    public let details: Details?
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["error", "details"])
        error = try c.value("error"); details = try c.optional("details")
    }
}

public struct NativeHTTPFailure: Equatable, Sendable {
    public let response: NativeErrorResponse
    public let retryAfterSeconds: Int64?
    public init(status: Int, headers: [String: String], body: Data) throws {
        response = try NativeAPI.decode(NativeErrorResponse.self, from: body)
        guard status == response.error.status else { throw ContractViolation.statusMismatch }
        if response.error == .rateLimited {
            let values = headers.filter { $0.key.lowercased() == "retry-after" }.map(\.value)
            guard values.count == 1, let raw = values.first,
                  !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let seconds = Int64(raw), seconds <= NativeAPI.maximumInteger else { throw ContractViolation.retryAfterRequired }
            retryAfterSeconds = seconds
        } else { retryAfterSeconds = nil }
    }
    /// Metadata for a future transport. Does not schedule retries, refresh a
    /// grant or mutate Matrix state. Missing 503 reason means unavailable.
    public var cloudUnavailable: Bool {
        response.error == .unavailable && (response.details?.reason == nil || response.details?.reason == "unavailable")
    }
}
