import AtumChat
import AtumNativeAPI
import CryptoKit
import Foundation

// The app's avatar byte sources: catalog/Matrix candidate traversal and the
// public remote loader. Split from AtumAvatar.swift so the share extension can
// compile the renderer alone (it has no network loader and no product models).

/// The one candidate traversal used by Store, Home and chat. Matrix media is
/// attempted first when a room has it, then every public catalog candidate is
/// tried in declared order. Fetch, integrity or native-decode failure advances
/// to the next candidate; cancellation stops the traversal immediately.
/// Main-actor isolated like every caller (views' `.task`), so the Matrix thumbnail loader they pass
/// is never sent across isolation (Swift 6 region isolation) and the negative cache has one owner.
@MainActor
enum AtumAvatarCandidateLoader {
    static func candidates(avatar: LiveProductAvatar?, sha256: String?,
                           declared: [LiveProductRemoteArt]) -> [LiveProductRemoteArt] {
        if !declared.isEmpty { return declared }
        guard case let .photo(url, _) = avatar else { return [] }
        return [LiveProductRemoteArt(url: url, sha256: sha256)]
    }

    static func load(matrixURI: String?, pixelSide: Int,
                     loadMatrixThumbnail: ((String, Int) async -> Data?)?,
                     remoteCandidates: [LiveProductRemoteArt], prefersRemote: Bool = false) async -> AtumAvatarArt? {
        guard !Task.isCancelled else { return nil }
        if prefersRemote, let art = await load(remoteCandidates: remoteCandidates, pixelSide: pixelSide) {
            return Task.isCancelled ? nil : art
        }
        guard !Task.isCancelled else { return nil }
        if let matrixURI, let loadMatrixThumbnail,
           let data = await loadMatrixThumbnail(matrixURI, pixelSide) {
            guard !Task.isCancelled else { return nil }
            if let art = await AtumAvatarArt.load(data: data, pixelSide: pixelSide) {
                return Task.isCancelled ? nil : art
            }
        }
        guard !Task.isCancelled else { return nil }
        if prefersRemote { return nil }
        return await load(remoteCandidates: remoteCandidates, pixelSide: pixelSide)
    }

    static func load(remoteCandidates: [LiveProductRemoteArt],
                     pixelSide: Int) async -> AtumAvatarArt? {
        await load(
            remoteCandidates: remoteCandidates,
            pixelSide: pixelSide,
            fetch: { candidate in
                await AtumRemoteAvatarLoader.shared.data(for: candidate.url,
                                                          expectedSHA256: candidate.sha256)
            },
            rememberDecodeFailure: { candidate in
                await AtumRemoteAvatarLoader.shared.rememberDecodeFailure(for: candidate)
            }
        )
    }

    static func load(remoteCandidates: [LiveProductRemoteArt], pixelSide: Int,
                     fetch: (LiveProductRemoteArt) async -> Data?,
                     rememberDecodeFailure: ((LiveProductRemoteArt) async -> Void)? = nil)
        async -> AtumAvatarArt? {
        for candidate in remoteCandidates {
            guard !Task.isCancelled else { return nil }
            let url = candidate.url
            guard url.scheme?.lowercased() == "https", url.host != nil,
                  url.user == nil, url.password == nil, url.fragment == nil,
                  let data = await fetch(candidate) else { continue }
            guard !Task.isCancelled else { return nil }
            guard let loaded = await AtumAvatarArt.load(data: data, pixelSide: pixelSide) else {
                if let rememberDecodeFailure { await rememberDecodeFailure(candidate) }
                continue
            }
            return Task.isCancelled ? nil : loaded
        }
        return nil
    }
}

/// Public avatar bytes use an ephemeral, credential-free session, a bounded
/// memory/disk cache and an integrity key. A short negative cache prevents a
/// row recreated by scrolling from immediately repeating a known-bad fetch.
actor AtumRemoteAvatarLoader {
    static let shared = AtumRemoteAvatarLoader()

    private let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()
    private let maximumBytes = 5 * 1_024 * 1_024
    private let negativeCacheSeconds: TimeInterval = 20
    private var retryAfter = [String: TimeInterval]()
    /// Public catalog art survives a cold launch here. The key carries the
    /// URL and declared digest, so a changed photo is a new entry.
    private let diskCache = AvatarDiskCache()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    func data(for url: URL, expectedSHA256: String?) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let key = url.absoluteString + "#" + (expectedSHA256 ?? "")
        let objectKey = key as NSString
        let now = ProcessInfo.processInfo.systemUptime
        if let deadline = retryAfter[key], deadline > now { return nil }
        retryAfter.removeValue(forKey: key)
        if let cached = cache.object(forKey: objectKey) { return cached as Data }

        if let data = await diskCache.data(for: key),
           data.count <= maximumBytes, Self.matches(data, expectedSHA256: expectedSHA256) {
            cache.setObject(data as NSData, forKey: objectKey, cost: data.count)
            return data
        }
        guard !Task.isCancelled else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard !Task.isCancelled else { return nil }
            guard data.count <= maximumBytes,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  response.mimeType?.hasPrefix("image/") == true,
                  Self.matches(data, expectedSHA256: expectedSHA256) else {
                rememberFailure(key, now: ProcessInfo.processInfo.systemUptime)
                return nil
            }
            cache.setObject(data as NSData, forKey: objectKey, cost: data.count)
            retryAfter.removeValue(forKey: key)
            _ = await diskCache.store(data, for: key)
            return data
        } catch {
            guard !Task.isCancelled else { return nil }
            rememberFailure(key, now: ProcessInfo.processInfo.systemUptime)
            return nil
        }
    }

    func rememberDecodeFailure(for candidate: LiveProductRemoteArt) {
        let key = candidate.url.absoluteString + "#" + (candidate.sha256 ?? "")
        cache.removeObject(forKey: key as NSString)
        rememberFailure(key, now: ProcessInfo.processInfo.systemUptime)
    }

    private func rememberFailure(_ key: String, now: TimeInterval) {
        retryAfter[key] = now + negativeCacheSeconds
        if retryAfter.count > 256 {
            retryAfter = retryAfter.filter { $0.value > now }
        }
    }

    private static func matches(_ data: Data, expectedSHA256: String?) -> Bool {
        guard let expectedSHA256 else { return true }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest.caseInsensitiveCompare(expectedSHA256) == .orderedSame
    }
}
