import AtumChat
import Foundation

/// Cached authenticated Matrix thumbnails. The SDK already keeps media in
/// memory and its own store; this adds the one thing it does not guarantee on
/// a cold launch: the exact avatar bytes the chat list painted last time.
///
/// Keys include the requested pixel side because a thumbnail is size-specific.
actor MatrixAvatarThumbnailCache {
    static let shared = MatrixAvatarThumbnailCache()

    private let memory: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()
    private let disk = AvatarDiskCache()

    func data(uri: String, pixelSide: Int) async -> Data? {
        guard !uri.isEmpty, pixelSide > 0 else { return nil }
        let key = Self.key(uri: uri, pixelSide: pixelSide)
        if let cached = memory.object(forKey: key as NSString) { return cached as Data }
        guard let data = await disk.data(for: key) else { return nil }
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        return data
    }

    func removeAll() async {
        memory.removeAllObjects()
        await disk.removeAll()
    }

    func store(_ data: Data, uri: String, pixelSide: Int) async {
        guard !uri.isEmpty, pixelSide > 0, !data.isEmpty else { return }
        let key = Self.key(uri: uri, pixelSide: pixelSide)
        memory.setObject(data as NSData, forKey: key as NSString, cost: data.count)
        _ = await disk.store(data, for: key)
    }

    private static func key(uri: String, pixelSide: Int) -> String {
        "v1|mxc|\(uri)|\(pixelSide)"
    }
}
