import CryptoKit
import Foundation
import Observation

/// The last native /me answer for the active Matrix account.
@available(macOS 14.0, *)
@MainActor @Observable
public final class AccountBetaFeatures {
    public private(set) var isEnabled = false

    private let defaults: UserDefaults
    @ObservationIgnored private var accountKey: String?
    @ObservationIgnored private var scope = UUID()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func beginAccountScope(_ matrixUserID: String) {
        let digest = SHA256.hash(data: Data(matrixUserID.utf8))
        let key = "atum.live.betaFeatures.v1." + digest.map { String(format: "%02x", $0) }.joined()
        guard accountKey != key else { return }
        scope = UUID()
        accountKey = key
        isEnabled = defaults.bool(forKey: key)
    }

    public func endAccountScope() {
        scope = UUID()
        accountKey = nil
        isEnabled = false
    }

    public func record(_ answer: Bool) {
        guard let accountKey else { return }
        defaults.set(answer, forKey: accountKey)
        isEnabled = answer
    }

    public func refresh(read: @MainActor () async throws -> Bool) async {
        guard accountKey != nil, !Task.isCancelled else { return }
        let readingScope = scope
        guard let answer = try? await read(), readingScope == scope, !Task.isCancelled else { return }
        record(answer)
    }
}
