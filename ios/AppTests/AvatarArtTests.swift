@testable import AtumMobile
import AtumChat
import CoreGraphics
import SwiftUI
import UIKit
import XCTest

/// Atum Kit STYLE §5: apps are squircles, every other face is a circle. The
/// mask follows `AvatarShapePolicy` for every kind.
final class AvatarFrameTests: XCTestCase {

    @MainActor
    func testEveryAvatarKindIsDrawnInItsKitFrame() {
        for kind in AtumAvatarKind.allCases {
            let shape = AtumAvatar.shape(for: kind, size: 52)
            switch AvatarShapePolicy.frame(for: kind) {
            case .circle:
                XCTAssertEqual(shape.cornerSize.width, 26, accuracy: 0.001, "\(kind) is round")
                XCTAssertEqual(shape.style, .circular, "\(kind)")
            case .squircle:
                XCTAssertEqual(shape.cornerSize.width, 52 * 0.2237, accuracy: 0.001, "\(kind)")
                XCTAssertEqual(shape.style, .continuous, "\(kind)")
            }
        }
        XCTAssertEqual(AtumAvatar.shape(size: 52).cornerSize.width, 26, accuracy: 0.001,
                       "local artwork such as the Founder raven is a person's face, so round")
    }

    /// The app ratio is the Kit token, not a second copy of it.
    @MainActor
    func testTheAppTileRatioIsTheKitToken() throws {
        let kit = try AtumKit.vendored()
        XCTAssertEqual(AvatarShapePolicy.appCornerRadiusRatio, kit.tokens.phone.appIconCornerRatio, accuracy: 0.0001)
    }
}

/// The art behind the frame: a disc with transparent corners is filled with
/// its own colour, art that already fills its square is left alone.
final class AvatarArtTests: XCTestCase {
    private func image(_ side: Int = 128, height: Int? = nil,
                       draw: (CGContext, CGRect) -> Void) throws -> CGImage {
        let height = height ?? side
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context, CGRect(x: 0, y: 0, width: side, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func png(_ image: CGImage) throws -> Data {
        try XCTUnwrap(UIImage(cgImage: image).pngData())
    }

    private let green = CGColor(srgbRed: 0x5A / 255, green: 0x9B / 255, blue: 0x8A / 255, alpha: 1)

    private func disc() throws -> CGImage {
        try image { context, rect in
            context.setFillColor(green)
            context.fillEllipse(in: rect)
        }
    }

    private func fullBleed() throws -> CGImage {
        try image { context, rect in
            context.setFillColor(green)
            context.fill(rect)
        }
    }

    func testAFlatDiscIsSampledForItsOwnColour() throws {
        let fill = try XCTUnwrap(AvatarArtSampler.backplate(of: try disc()))
        XCTAssertEqual(Int(fill.red), 0x5A, accuracy: 2)
        XCTAssertEqual(Int(fill.green), 0x9B, accuracy: 2)
        XCTAssertEqual(Int(fill.blue), 0x8A, accuracy: 2)
        XCTAssertEqual(fill.alpha, 255)
    }

    func testArtThatFillsItsSquareAndGlyphsOnNothingAreLeftAlone() throws {
        XCTAssertNil(AvatarArtSampler.backplate(of: try fullBleed()))
        let glyph = try image { context, rect in
            context.setFillColor(green)
            context.fillEllipse(in: rect.insetBy(dx: 48, dy: 48))
        }
        XCTAssertNil(AvatarArtSampler.backplate(of: glyph), "no rim at the edges to match")
    }

    func testANonSquareThumbnailIsNotMistakenForADisc() throws {
        let wide = try image(128, height: 64) { context, rect in
            context.setFillColor(green)
            context.fillEllipse(in: rect)
        }
        XCTAssertNil(AvatarArtSampler.backplate(of: wide), "the fill crops it, so its corners are not the frame's")
    }

    /// The alpha of one rendered pixel (`x`, `y` from the top left).
    private func alpha(of image: CGImage, x: Int, y: Int) throws -> UInt8 {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel[3]
    }

    /// The owner's complaint, as pixels: a point inside the squircle's rounded
    /// corner but outside the disc is the page showing through without the
    /// backplate, and the disc's own colour with it.
    @MainActor
    func testARenderedDiscFillsTheSquircleCornerNotJustTheCircle() throws {
        let design = try LiveDesign()
        let art = try XCTUnwrap(AtumAvatarArt.decode(data: try png(try disc()), pixelSide: 156))
        XCTAssertNotNil(art.backplate)
        func render(_ art: AtumAvatarArt) throws -> CGImage {
            let renderer = ImageRenderer(content: AtumAvatar(kind: .app, name: "Andy", art: art, size: 52)
                .environment(\.atum, AtumVisualSystem(design: design)))
            renderer.scale = 3
            return try XCTUnwrap(renderer.cgImage)
        }
        // 0.12 of the side from two edges: inside the 0.2237 app corner, outside the disc.
        let probe = Int((52 * 3) * 0.12)
        let filled = try render(art)
        XCTAssertGreaterThanOrEqual(try alpha(of: filled, x: probe, y: probe), 250,
                                    "the corner reads as the squircle")
        XCTAssertGreaterThanOrEqual(try alpha(of: filled, x: filled.width / 2, y: filled.height / 2), 250)
        // The very corner pixel is outside the squircle itself: the frame still clips.
        XCTAssertLessThanOrEqual(try alpha(of: filled, x: 0, y: 0), 5,
                                 "the frame is still a squircle, not a square")

        let bare = try render(AtumAvatarArt(image: art.image, backplate: nil))
        XCTAssertLessThanOrEqual(try alpha(of: bare, x: probe, y: probe), 5,
                                 "without the backplate the corner is the page")
    }

    /// Kit text roles stay readable on the Kit grounds they sit on, in both schemes
    /// (`ink-4` is for icons and strokes only, never text).
    @MainActor
    func testKitTextRolesMeetTextContrastOnTheirGroundsInBothSchemes() throws {
        let kit = try LiveDesign().kit
        for scheme in [ColorScheme.light, .dark] {
            for text in [AtumKit.ColorRole.ink, .ink2, .ink3] {
                for ground in [AtumKit.ColorRole.ground, .surface] {
                    let a = kit.rgba(text, scheme: scheme), b = kit.rgba(ground, scheme: scheme)
                    let ratio = (max(luminance(a), luminance(b)) + 0.05) / (min(luminance(a), luminance(b)) + 0.05)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(scheme) \(text.rawValue) on \(ground.rawValue)")
                }
            }
            let own = kit.rgba(.onBubbleOwn, scheme: scheme), bubble = kit.rgba(.bubbleOwn, scheme: scheme)
            let ratio = (max(luminance(own), luminance(bubble)) + 0.05) / (min(luminance(own), luminance(bubble)) + 0.05)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(scheme) own bubble")
        }
    }

    private func luminance(_ value: AtumKit.RGBA) -> Double {
        func channel(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(value.red) + 0.7152 * channel(value.green)
            + 0.0722 * channel(value.blue)
    }

    func testARingKeepsItsHoleInsteadOfBeingFilled() throws {
        // Same flat rim and transparent corners as the disc, but hollow.
        let ring = try image { context, rect in
            context.setFillColor(green)
            context.fillEllipse(in: rect)
            context.setBlendMode(.clear)
            context.fillEllipse(in: rect.insetBy(dx: 40, dy: 40))
        }
        let samples = try XCTUnwrap(AvatarArtSampler.samples(of: ring))
        XCTAssertEqual(samples.interior.count, 5)
        XCTAssertTrue(samples.interior.contains { $0.alpha == 0 }, "the hole is sampled")
        XCTAssertNil(AvatarArtSampler.backplate(of: ring), "a donut is not filled")
        let art = try XCTUnwrap(AtumAvatarArt.decode(data: try png(ring), pixelSide: 128))
        XCTAssertNil(art.backplate)
        // A thin ring around a big hole: the inner points are all in the hole.
        let thin = try image { context, rect in
            context.setFillColor(green)
            context.fillEllipse(in: rect)
            context.setBlendMode(.clear)
            context.fillEllipse(in: rect.insetBy(dx: 12, dy: 12))
        }
        XCTAssertNil(AvatarArtSampler.backplate(of: thin))
        // The solid disc is still filled.
        XCTAssertNotNil(AvatarArtSampler.backplate(of: try disc()))
    }

    func testTheDecoderCachesByContentAndStaysBounded() async throws {
        let decoder = AtumAvatarArtDecoder(capacity: 3)
        func solid(_ shade: CGFloat) throws -> Data {
            try png(try image(64) { context, rect in
                context.setFillColor(CGColor(srgbRed: shade, green: 0.2, blue: 0.4, alpha: 1))
                context.fill(rect)
            })
        }
        let first = try solid(0.1)
        _ = await decoder.decoded(data: first, pixelSide: 64)
        _ = await decoder.decoded(data: first, pixelSide: 64)
        var hits = await decoder.hits
        var misses = await decoder.misses
        XCTAssertEqual(hits, 1, "the same bytes at the same size are decoded once")
        XCTAssertEqual(misses, 1)
        // Equal bytes from another source hit; another size is its own entry.
        _ = await decoder.decoded(data: Data(first), pixelSide: 64)
        _ = await decoder.decoded(data: first, pixelSide: 32)
        hits = await decoder.hits
        misses = await decoder.misses
        XCTAssertEqual(hits, 2)
        XCTAssertEqual(misses, 2)

        for index in 1...8 { _ = await decoder.decoded(data: try solid(0.1 + CGFloat(index) / 20), pixelSide: 64) }
        let count = await decoder.cachedCount
        XCTAssertEqual(count, 3, "never more than its capacity")
        // The oldest was evicted, so it decodes again.
        let before = await decoder.misses
        _ = await decoder.decoded(data: first, pixelSide: 64)
        let after = await decoder.misses
        XCTAssertEqual(after, before + 1)
        let bad = await decoder.decoded(data: Data("not an image".utf8), pixelSide: 64)
        XCTAssertNil(bad)
        let afterBad = await decoder.cachedCount
        XCTAssertEqual(afterBad, 3, "a failed decode is not cached")
    }

    func testLoadDecodesOffTheCallersActorAndMatchesTheSyncResult() async throws {
        let data = try png(try disc())
        let maybe = await AtumAvatarArt.load(data: data, pixelSide: 96)
        let loaded = try XCTUnwrap(maybe)
        XCTAssertNotNil(loaded.backplate)
        let none = await AtumAvatarArt.load(data: Data("nope".utf8), pixelSide: 96)
        XCTAssertNil(none)
    }

    func testCandidateLoaderAdvancesPastAnUndecodableFirstCandidate() async throws {
        let first = try XCTUnwrap(URL(string: "https://cdn.atum.test/first.svg"))
        let second = try XCTUnwrap(URL(string: "https://cdn.atum.test/second.png"))
        let valid = try png(try fullBleed())
        var attempted = [URL]()

        let art = await AtumAvatarCandidateLoader.load(
            remoteCandidates: [
                LiveProductRemoteArt(url: first, sha256: nil),
                LiveProductRemoteArt(url: second, sha256: nil),
            ],
            pixelSide: 96
        ) { candidate in
            attempted.append(candidate.url)
            return candidate.url == first ? Data("not a native image".utf8) : valid
        }

        XCTAssertNotNil(art)
        XCTAssertEqual(attempted, [first, second])
    }

    func testTheCacheEvictsTheLeastRecentlyUsedEntry() {
        var cache = AvatarArtLRU<String, Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1, "touching a makes b the oldest")
        cache.insert(3, for: "c")
        XCTAssertFalse(cache.contains("b"))
        XCTAssertTrue(cache.contains("a"))
        XCTAssertTrue(cache.contains("c"))
        cache.insert(4, for: "c")
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.value(for: "c"), 4)
    }

    func testTheSharedDecoderCarriesTheBackplateOnlyForACutOut() throws {
        let cutOut = try XCTUnwrap(AtumAvatarArt.decode(data: try png(try disc()), pixelSide: 96))
        XCTAssertNotNil(cutOut.backplate)
        let full = try XCTUnwrap(AtumAvatarArt.decode(data: try png(try fullBleed()), pixelSide: 96))
        XCTAssertNil(full.backplate)
        XCTAssertNil(AtumAvatarArt.decode(data: Data("not an image".utf8), pixelSide: 96))
    }
}

// MARK: Roster kinds (needs HomeScreen's `HomeRow`)

/// Which roster rows are an "app" (an official app account), and that a
/// roster row's frame follows its kind.
final class RosterAvatarKindTests: XCTestCase {
    @MainActor
    func testRosterKindsResolveToTheirKitFrame() {
        let kinds: [HomeRow.Kind] = [.atum, .assistant, .app, .person, .group, .invitation]
        for kind in kinds {
            let shape = AtumAvatar.shape(for: kind.avatarKind, size: 52)
            XCTAssertEqual(shape.style, kind.avatarKind == .app ? .continuous : .circular, "\(kind)")
        }
    }

    @MainActor
    func testAnOfficialAppRoomIsASquircleAndAPersonRoomIsACircle() {
        let app = HomeRow(product: LiveProductRoom(id: "!andy:atum.test", kind: .agent, title: "Andy",
                                                   isAppBotRoom: true), locale: Locale(identifier: "vi"))
        let appByID = HomeRow(product: LiveProductRoom(id: "app:demoza", kind: .agent, title: "Demoza"),
                              locale: Locale(identifier: "vi"))
        let person = HomeRow(product: LiveProductRoom(id: "!anh:atum.test", kind: .people, title: "Anh"),
                             locale: Locale(identifier: "vi"))
        XCTAssertEqual(app.kind, .app, "a catalog bot room is an app")
        XCTAssertEqual(appByID.kind, .app, "a coming-soon catalog entry (`app:` id) is an app")
        XCTAssertEqual(person.kind, .person)
        XCTAssertEqual(AvatarShapePolicy.frame(for: app.kind.avatarKind), .squircle)
        XCTAssertEqual(AvatarShapePolicy.frame(for: person.kind.avatarKind), .circle)
    }
}
