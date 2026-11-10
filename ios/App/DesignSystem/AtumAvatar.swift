import AtumChat
import AtumNativeAPI
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SwiftUI
import UIKit

/// The semantic identity of an avatar. The kind decides the frame
/// (`AvatarShapePolicy`, Atum Kit STYLE §5): apps are squircles, every other
/// face is a circle.
typealias AtumAvatarKind = AvatarKind

/// One face treatment for every app surface, drawn to the Kit.
///
/// `art` is an already-decoded thumbnail (`AtumAvatarArt.decode`). This view
/// intentionally has no URL or loader API: Matrix and catalog clients own
/// their fetch, caching and 3x thumbnail requests, then hand the result to the
/// renderer. The image fills the frame edge to edge. Without art:
/// - Atum is an ink circle with the eclipse crescent cut by a ground disc
///   (FlowPhone: a 41 pt disc at (15, 4) in the 52 pt face);
/// - everyone else is the Kit monogram: the grey `monogram` gradient with a
///   white semibold initial. A photo that has not loaded (or never loads) shows
///   the monogram too, so no face is ever left blank.
/// App tiles carry a 0.5 pt `line` edge so a white icon reads on the page.
struct AtumAvatar: View {
    /// What to draw when there is no decoded image yet. Both draw the Kit
    /// monogram (gap spec §1: a blank `.neutral` face left Andy empty forever
    /// when the photo failed); the case stays so call sites keep saying which
    /// rows expect a photo.
    enum Placeholder: Equatable {
        case monogram
        case neutral
    }

    let kind: AtumAvatarKind
    let name: String
    let art: AtumAvatarArt?
    /// A named assistant's coloured shape, drawn when it has no photo
    /// (desktop `at/assistant-avatar.tsx`: photo, brand, mark, initial).
    let mark: AgentMark?
    let placeholder: Placeholder
    private let baseSize: CGFloat
    @ScaledMetric private var scaledSize: CGFloat
    @Environment(\.atum) private var atum
    @Environment(\.atumKit) private var kit
    @Environment(\.colorScheme) private var scheme

    init(kind: AtumAvatarKind, name: String, art: AtumAvatarArt? = nil,
         mark: AgentMark? = nil, placeholder: Placeholder = .monogram, size: CGFloat) {
        self.kind = kind
        self.name = name
        self.art = art
        self.mark = mark
        self.placeholder = placeholder
        baseSize = size
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        Group {
            if let kit = kit ?? atum?.kit {
                face(kit: kit)
                    .frame(width: size, height: size)
                    .clipShape(shape)
                    .overlay {
                        if AvatarShapePolicy.frame(for: kind) == .squircle {
                            shape.strokeBorder(kit.color(.line, scheme: scheme), lineWidth: 0.5)
                        }
                    }
            }
        }
        .accessibilityHidden(true)
    }

    /// S6 caps every prescribed face at roughly 135% of its base size (the
    /// 52 pt Home face therefore never exceeds 72 pt). An environment limit
    /// around a `@ScaledMetric` does not cap its already-resolved value, so
    /// the bound is explicit.
    private var size: CGFloat { Self.cappedPointSize(base: baseSize, scaled: scaledSize) }

    private var shape: RoundedRectangle { Self.shape(for: kind, size: size) }

    /// The outer mask for a face of `kind` (`AvatarShapePolicy`): a true
    /// circle (circular corners at half the side) or the continuous app tile.
    static func shape(for kind: AtumAvatarKind, size: CGFloat) -> RoundedRectangle {
        RoundedRectangle(
            cornerRadius: CGFloat(AvatarShapePolicy.cornerRadius(for: kind, side: Double(size))),
            style: AvatarShapePolicy.frame(for: kind) == .circle ? .circular : .continuous)
    }

    /// The mask for approved local artwork rendered outside this view (the
    /// Founder raven is a person's face, so a circle).
    static func shape(size: CGFloat) -> RoundedRectangle { shape(for: .person, size: size) }

    static func cappedPointSize(base: CGFloat, scaled: CGFloat) -> CGFloat {
        min(scaled, base * 1.35)
    }

    /// Sources use this to request the required 3x face thumbnail before
    /// decoding it into `image`; the renderer never starts a network request.
    static func thumbnailPixelSide(for pointSize: CGFloat) -> Int {
        Int((pointSize * 3).rounded(.up))
    }

    /// What the face draws, in desktop's order: the photo, Atum's crescent,
    /// an assistant's mark, then the initial. An app never wears a mark.
    enum Treatment: Equatable {
        case image
        case crescent
        case mark(AgentMark)
        case monogram(String)
    }

    static func treatment(kind: AtumAvatarKind, hasArt: Bool, mark: AgentMark?,
                          name: String) -> Treatment {
        switch AvatarFacePolicy.face(hasImage: hasArt, name: name) {
        case .image: return .image
        case let .monogram(value):
            if kind == .atum { return .crescent }
            if let mark, kind != .app { return .mark(mark) }
            return .monogram(value)
        }
    }

    /// The mark's side over the face's (desktop: `size-[62%]` in a roster row).
    static let markScale: CGFloat = 0.62

    @ViewBuilder
    private func face(kit: AtumKit) -> some View {
        switch Self.treatment(kind: kind, hasArt: art != nil, mark: mark, name: name) {
        case .image:
            ZStack {
                // A cut-out disc leaves its corners transparent; its own
                // colour behind it keeps an app tile a squircle.
                if let backplate = art?.backplate { backplate }
                art?.image
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            }
        case .crescent:
            AtumCrescentFace(size: size)
        case let .mark(mark):
            ZStack {
                kit.color(.fillQuiet, scheme: scheme)
                AssistantMarkGlyphShape(shape: mark.shape)
                    .fill(AssistantMarkPalette.color(mark.color, scheme: scheme))
                    .frame(width: size * Self.markScale, height: size * Self.markScale)
            }
            .accessibilityIdentifier("avatar.mark")
        case let .monogram(value):
            ZStack {
                kit.monogram(scheme: scheme)
                Text(verbatim: value)
                    .font(.system(size: size * Self.monogramScale, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(.white)
                    .accessibilityIdentifier("avatar.monogram")
            }
        }
    }

    /// The initial over the side (FlowPhone: 19 px in a 52 px face, 13 in 34).
    /// The face itself already follows Dynamic Type through `size`.
    static let monogramScale: CGFloat = 0.37
}

/// Atum's face (FlowPhone): an ink circle with the eclipse crescent, cut by a
/// disc of the page colour. The disc is 41/52 of the side, set 15/52 in from
/// the left and 4/52 down, so the ink crescent shows on the left.
struct AtumCrescentFace: View {
    let size: CGFloat
    /// What the disc is cut from: the page by default, `surface` on a card.
    var cut: AtumKit.ColorRole = .ground

    @Environment(\.atumKit) private var environmentKit
    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let kit = environmentKit ?? atum?.kit {
            Circle()
                .fill(kit.color(.ink, scheme: scheme))
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(kit.color(cut, scheme: scheme))
                        .frame(width: size * 41 / 52, height: size * 41 / 52)
                        .offset(x: size * 15 / 52, y: size * 4 / 52)
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .accessibilityHidden(true)
        }
    }
}

/// A decoded avatar thumbnail and, when its artwork is a cut-out (a disc or
/// round logo on transparent corners), the colour that fills the squircle
/// behind it (`AvatarBackplatePolicy`). Every avatar surface loads through
/// `load`, so no view repeats ImageIO or decides a shape, and none decodes on
/// the main actor.
struct AtumAvatarArt {
    let image: Image
    let backplate: Color?

    init(image: Image, backplate: Color? = nil) {
        self.image = image
        self.backplate = backplate
    }

    init(_ decoded: DecodedAvatar) {
        image = Image(uiImage: UIImage(cgImage: decoded.cgImage))
        backplate = decoded.backplate.map {
            Color(.sRGB, red: Double($0.red) / 255, green: Double($0.green) / 255,
                  blue: Double($0.blue) / 255, opacity: 1)
        }
    }

    /// What a view calls: the decode and the pixel sampling run on the shared
    /// decoder's own executor, never the caller's, and a thumbnail already
    /// decoded for the same bytes and size comes from its cache.
    static func load(data: Data, pixelSide: Int) async -> AtumAvatarArt? {
        await AtumAvatarArtDecoder.shared.decoded(data: data, pixelSide: pixelSide)
            .map(AtumAvatarArt.init)
    }

    /// The synchronous worker behind `load`. It is cheap to call from a test or
    /// a background task; a view must go through `load`.
    static func decode(data: Data, pixelSide: Int) -> AtumAvatarArt? {
        DecodedAvatar.decode(data: data, pixelSide: pixelSide).map(AtumAvatarArt.init)
    }
}

/// A decoded thumbnail and its backplate decision, as plain immutable values
/// that can cross actors. `CGImage` is immutable once made.
struct DecodedAvatar: @unchecked Sendable {
    let cgImage: CGImage
    let backplate: AvatarPixel?

    static func decode(data: Data, pixelSide: Int) -> DecodedAvatar? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSide,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return DecodedAvatar(cgImage: cgImage, backplate: AvatarArtSampler.backplate(of: cgImage))
    }
}

/// A least-recently-used cache with a hard entry limit.
struct AvatarArtLRU<Key: Hashable, Value> {
    let capacity: Int
    private var values = [Key: Value]()
    /// Oldest first.
    private var order = [Key]()

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { values.count }

    mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        if let index = order.lastIndex(of: key) { order.remove(at: index) }
        order.append(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        if values.updateValue(value, forKey: key) != nil, let index = order.lastIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
        while order.count > capacity { values.removeValue(forKey: order.removeFirst()) }
    }

    func contains(_ key: Key) -> Bool { values[key] != nil }
}

/// Decodes avatar thumbnails and samples their pixels off the main actor, and
/// remembers the result by content hash, so a face that appears on several
/// surfaces (or scrolls back into view) is decoded once. The cache holds at
/// most `capacity` thumbnails (about 200 faces is a few tens of MB at 3x).
actor AtumAvatarArtDecoder {
    static let shared = AtumAvatarArtDecoder(capacity: 200)

    private struct Key: Hashable {
        let contentHash: String
        let pixelSide: Int
    }

    private var cache: AvatarArtLRU<Key, DecodedAvatar>
    private(set) var hits = 0
    private(set) var misses = 0

    init(capacity: Int) { cache = AvatarArtLRU(capacity: capacity) }

    var cachedCount: Int { cache.count }

    func decoded(data: Data, pixelSide: Int) -> DecodedAvatar? {
        let key = Key(contentHash: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                      pixelSide: pixelSide)
        if let hit = cache.value(for: key) {
            hits += 1
            return hit
        }
        misses += 1
        guard let decoded = DecodedAvatar.decode(data: data, pixelSide: pixelSide) else { return nil }
        cache.insert(decoded, for: key)
        return decoded
    }
}

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
                     remoteCandidates: [LiveProductRemoteArt]) async -> AtumAvatarArt? {
        guard !Task.isCancelled else { return nil }
        if let matrixURI, let loadMatrixThumbnail,
           let data = await loadMatrixThumbnail(matrixURI, pixelSide) {
            guard !Task.isCancelled else { return nil }
            if let art = await AtumAvatarArt.load(data: data, pixelSide: pixelSide) {
                return Task.isCancelled ? nil : art
            }
        }
        guard !Task.isCancelled else { return nil }
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

/// Reads the pixels `AvatarBackplatePolicy` decides from.
enum AvatarArtSampler {
    /// Thumbnails further from square than this are cropped by the fill, so
    /// their corners are not the squircle's corners; they are left alone.
    private static let squareTolerance = 0.05

    static func backplate(of image: CGImage) -> AvatarPixel? {
        guard let samples = samples(of: image) else { return nil }
        return AvatarBackplatePolicy.backplate(corners: samples.corners, edges: samples.edges,
                                               interior: samples.interior)
    }

    static func samples(of image: CGImage)
        -> (corners: [AvatarPixel], edges: [AvatarPixel], interior: [AvatarPixel])? {
        let width = image.width
        let height = image.height
        guard width >= 8, height >= 8,
              abs(Double(width) / Double(height) - 1) <= squareTolerance,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let inset = width >= 64 ? 2 : 1

        func pixel(_ x: Int, _ y: Int) -> AvatarPixel {
            let offset = (y * width + x) * 4
            let alpha = bytes[offset + 3]
            // The context stores premultiplied colour; the policy wants straight.
            func straight(_ value: UInt8) -> UInt8 {
                guard alpha > 0 else { return 0 }
                return UInt8(min(255, Int(value) * 255 / Int(alpha)))
            }
            return AvatarPixel(red: straight(bytes[offset]), green: straight(bytes[offset + 1]),
                               blue: straight(bytes[offset + 2]), alpha: alpha)
        }

        let right = width - 1 - inset
        let bottom = height - 1 - inset
        let near = width / 4
        let far = width - 1 - near
        let nearY = height / 4
        let farY = height - 1 - nearY
        return (corners: [pixel(inset, inset), pixel(right, inset), pixel(inset, bottom), pixel(right, bottom)],
                edges: [pixel(width / 2, inset), pixel(width / 2, bottom),
                        pixel(inset, height / 2), pixel(right, height / 2)],
                interior: [pixel(width / 2, height / 2),
                           pixel(near, nearY), pixel(far, nearY), pixel(near, farY), pixel(far, farY)])
    }
}

enum AssistantMarkPalette {
    static func color(_ value: AgentMarkColor, scheme: ColorScheme) -> Color {
        switch value {
        case .snow: return scheme == .dark ? Color(white: 0.92) : .white
        case .earth: return Color(red: 0.58, green: 0.38, blue: 0.22)
        case .coral: return Color(red: 1.00, green: 0.18, blue: 0.27)
        case .orange: return Color(red: 1.00, green: 0.39, blue: 0.00)
        case .amber: return Color(red: 1.00, green: 0.63, blue: 0.00)
        case .mint: return Color(red: 0.00, green: 0.78, blue: 0.48)
        case .teal: return Color(red: 0.00, green: 0.72, blue: 0.66)
        case .blue: return Color(red: 0.08, green: 0.49, blue: 0.96)
        case .violet: return Color(red: 0.52, green: 0.30, blue: 0.94)
        case .pink: return Color(red: 1.00, green: 0.16, blue: 0.55)
        case .stone: return Color(white: scheme == .dark ? 0.62 : 0.48)
        }
    }
    static func selection(_ scheme: ColorScheme) -> Color { scheme == .dark ? .white : .black }
}

struct AssistantMarkGlyphShape: Shape {
    let shape: AgentMarkShape

    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
        switch shape {
        case .circle: return Path(ellipseIn: inset)
        case .roundedSquare: return Path(roundedRect: inset, cornerRadius: rect.width * 0.24)
        case .diamond: return polygon(in: inset, sides: 4, rotation: -.pi / 2)
        case .spark: return radial(in: inset, points: 4, inner: 0.24, rotation: -.pi / 2)
        case .clover:
            var path = Path()
            let size = rect.width * 0.49
            for center in [CGPoint(x: rect.midX, y: rect.minY + size / 2),
                           CGPoint(x: rect.midX, y: rect.maxY - size / 2),
                           CGPoint(x: rect.minX + size / 2, y: rect.midY),
                           CGPoint(x: rect.maxX - size / 2, y: rect.midY)] {
                path.addEllipse(in: CGRect(x: center.x - size / 2, y: center.y - size / 2,
                                           width: size, height: size))
            }
            return path
        case .heart:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY * 0.92))
            path.addCurve(to: CGPoint(x: rect.minX + rect.width * 0.08, y: rect.midY * 0.82),
                          control1: CGPoint(x: rect.midX * 0.88, y: rect.maxY * 0.72),
                          control2: CGPoint(x: rect.minX, y: rect.midY * 1.25))
            path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.30),
                          control1: CGPoint(x: rect.minX + rect.width * 0.06, y: rect.minY),
                          control2: CGPoint(x: rect.midX * 0.82, y: rect.minY))
            path.addCurve(to: CGPoint(x: rect.maxX - rect.width * 0.08, y: rect.midY * 0.82),
                          control1: CGPoint(x: rect.midX * 1.18, y: rect.minY),
                          control2: CGPoint(x: rect.maxX - rect.width * 0.06, y: rect.minY))
            path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY * 0.92),
                          control1: CGPoint(x: rect.maxX, y: rect.midY * 1.25),
                          control2: CGPoint(x: rect.midX * 1.12, y: rect.maxY * 0.72))
            return path
        case .flower: return radial(in: inset, points: 8, inner: 0.62, rotation: -.pi / 2)
        case .drop:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addCurve(to: CGPoint(x: rect.midX, y: rect.maxY),
                          control1: CGPoint(x: rect.maxX * 1.04, y: rect.midY * 0.90),
                          control2: CGPoint(x: rect.maxX * 0.88, y: rect.maxY))
            path.addCurve(to: CGPoint(x: rect.midX, y: rect.minY),
                          control1: CGPoint(x: rect.minX * 1.12, y: rect.maxY),
                          control2: CGPoint(x: rect.minX * 0.96, y: rect.midY * 0.90))
            return path
        case .pebble: return Path(roundedRect: inset, cornerRadius: rect.width * 0.42)
        case .triangle: return polygon(in: inset, sides: 3, rotation: -.pi / 2)
        case .pentagon: return polygon(in: inset, sides: 5, rotation: -.pi / 2)
        case .star: return radial(in: inset, points: 5, inner: 0.45, rotation: -.pi / 2)
        case .hexagon: return polygon(in: inset, sides: 6, rotation: -.pi / 2)
        }
    }

    private func polygon(in rect: CGRect, sides: Int, rotation: CGFloat) -> Path {
        radial(in: rect, points: sides, inner: 1, rotation: rotation)
    }

    private func radial(in rect: CGRect, points: Int, inner: CGFloat, rotation: CGFloat) -> Path {
        var path = Path()
        let count = inner == 1 ? points : points * 2
        let radius = min(rect.width, rect.height) / 2
        for index in 0..<count {
            let angle = rotation + CGFloat(index) / CGFloat(count) * .pi * 2
            let length = inner == 1 || index.isMultiple(of: 2) ? radius : radius * inner
            let point = CGPoint(x: rect.midX + cos(angle) * length,
                                y: rect.midY + sin(angle) * length)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
