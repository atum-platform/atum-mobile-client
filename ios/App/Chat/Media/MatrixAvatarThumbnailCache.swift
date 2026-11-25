import Foundation

/// In-memory fast path for authenticated Matrix thumbnails. The SDK owns
/// persistent media in the Matrix installation's SQLite cache.
@MainActor
final class MatrixAvatarThumbnailCache {
    static let shared = MatrixAvatarThumbnailCache()

    struct Scope: Equatable {
        let sessionGeneration: UUID
        fileprivate let lifetime = UUID()
    }

    private var scope: Scope?
    private let memory: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()
    func beginAccountScope(sessionGeneration: UUID) -> Scope {
        if let scope, scope.sessionGeneration == sessionGeneration { return scope }
        let active = Scope(sessionGeneration: sessionGeneration)
        memory.removeAllObjects()
        scope = active
        return active
    }

    func endAccountScope() {
        scope = nil
        memory.removeAllObjects()
    }

    func thumbnail(uri: String, pixelSide: Int, scope loadScope: Scope,
                   fetch: () async -> Data?) async -> Data? {
        guard scope == loadScope, !uri.isEmpty, pixelSide > 0 else { return nil }
        let key = "\(pixelSide)|\(uri)" as NSString
        if let cached = memory.object(forKey: key) { return cached as Data }
        guard let data = await fetch(), scope == loadScope else { return nil }
        if !data.isEmpty {
            memory.setObject(data as NSData, forKey: key, cost: data.count)
        }
        return data
    }
}
