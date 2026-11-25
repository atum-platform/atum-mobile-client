import SwiftUI
import UIKit
import XCTest
@testable import AtumMobile

/// W4-R: the phone picks the same provider mark as the desktop
/// (`model-picker-provider-mark.tsx` `PROVIDER_ICONS`, first match over
/// "id label"), and every mark it names is bundled.
final class ProviderMarkTests: XCTestCase {
    func testProvidersMatchTheDesktopTable() {
        let expected: [(String, String, String)] = [
            ("codex", "ChatGPT", "provider.openai"),
            ("openai", "OpenAI", "provider.openai"),
            ("claude", "Claude", "provider.claude"),
            ("anthropic", "Anthropic", "provider.claude"),
            ("opencode", "OpenCode Go", "provider.opencode"),
            ("opencode-go", "OpenCode Go", "provider.opencode"),
            ("deepseek", "DeepSeek", "provider.deepseek"),
            ("gemini", "Gemini", "provider.gemini"),
            ("xai", "Grok", "provider.grok"),
            ("minimax", "MiniMax", "provider.minimax"),
            ("qwen", "Qwen", "provider.qwen"),
        ]
        for (provider, label, asset) in expected {
            guard case let .template(name, _) = ProviderMark.art(provider: provider, label: label) else {
                return XCTFail("\(provider) has no template mark")
            }
            XCTAssertEqual(name, asset, provider)
            XCTAssertNotNil(UIImage(named: name), "\(name) is not in the asset catalog")
        }
    }

    /// Copilot's mark isn't bundled (its catalog licence is MIT, not CC0), so it
    /// falls back to an initial like any provider without a bundled logo.
    func testCopilotFallsBackToItsInitial() {
        guard case .monogram = ProviderMark.art(provider: "copilot-acp", label: "GitHub Copilot") else {
            return XCTFail("copilot should use the initial fallback")
        }
    }

    func testAntigravityIsTheFullColourImageAndAtumIsTheEclipse() {
        XCTAssertEqual(ProviderMark.art(provider: "antigravity", label: "Antigravity"),
                       .image(asset: "provider.antigravity"))
        XCTAssertNotNil(UIImage(named: "provider.antigravity"))
        XCTAssertEqual(ProviderMark.art(provider: "atum", label: "Atum"), .atum)
    }

    /// Atum's row mark is the desktop's inset BrandMark (`PickerRouteMark`):
    /// the eclipse at 64% of the tile, a 0.25rem corner on a 16 px mark.
    @MainActor
    func testAtumWearsTheDesktopsInsetBrandMark() {
        XCTAssertEqual(AtumBrandTile.markScale, 0.64)
        XCTAssertEqual(AtumBrandTile.cornerScale * 16, 4)
        XCTAssertEqual(AtumBrandTile.markScale(for: .pickerMark), 0.64)
        XCTAssertEqual(AtumBrandTile.cornerRadius(for: .pickerMark, side: 20), 5)
        XCTAssertTrue(AtumBrandTile.hasHairline(.pickerMark))
    }

    /// Atum's assistant face is the desktop's `AtumAssistantAvatar` `brand`
    /// (`assistant-avatar.tsx`): the same logo on the same tile, a circle with
    /// no hairline, the mark at 70% (64% in the chat list's inset rows).
    @MainActor
    func testAtumAssistantFaceWearsTheDesktopsBrandAvatar() {
        XCTAssertEqual(AtumAvatar.treatment(kind: .atum, hasArt: false, mark: nil, name: "Atum"), .brand)
        XCTAssertEqual(AtumBrandTile.markScale(for: .avatar), 0.70)
        XCTAssertEqual(AtumBrandTile.markScale(for: .avatarInset), 0.64)
        XCTAssertEqual(AtumBrandTile.cornerRadius(for: .avatar, side: 52), 26)
        XCTAssertEqual(AtumBrandTile.cornerRadius(for: .avatarInset, side: 36), 18)
        XCTAssertFalse(AtumBrandTile.hasHairline(.avatar))
        XCTAssertFalse(AtumBrandTile.hasHairline(.avatarInset))
    }

    /// The rendered face, as pixels, in light mode (the crescent this replaced
    /// was an ink disc on the page): the dark `#141311` tile above the mark,
    /// and a circle, so a point in a rounded square's corner is clear.
    @MainActor
    func testRenderedAtumFaceIsTheDarkBrandCircle() throws {
        let design = try LiveDesign()
        let renderer = ImageRenderer(content: AtumAvatar(kind: .atum, name: "Atum", size: 52)
            .atumDesign(design)
            .environment(\.colorScheme, .light)
            .environment(\.dynamicTypeSize, .large))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.cgImage)
        let side = image.width
        // 8% down the middle: inside the circle, outside the 70% mark.
        let tile = try rgba(of: image, x: side / 2, y: Int(Double(side) * 0.08))
        XCTAssertEqual(Int(tile[0]), 0x14, accuracy: 3)
        XCTAssertEqual(Int(tile[1]), 0x13, accuracy: 3)
        XCTAssertEqual(Int(tile[2]), 0x11, accuracy: 3)
        XCTAssertGreaterThanOrEqual(tile[3], 250)
        // 12% in from two edges is outside a circle (0.54 of the side from its centre).
        let corner = try rgba(of: image, x: Int(Double(side) * 0.12), y: Int(Double(side) * 0.12))
        XCTAssertLessThanOrEqual(corner[3], 5, "the face is a circle, as the desktop's avatar")
    }

    /// One rendered pixel's premultiplied RGBA (`x`, `y` from the top left).
    private func rgba(of image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel
    }

    /// Monochrome marks follow the theme's ink; the brand-coloured ones keep their colour.
    func testOnlyTheDesktopsColouredMarksCarryAColour() {
        let coloured = ["claude", "deepseek", "gemini", "minimax", "qwen"]
        for provider in coloured + ["openai", "opencode", "grok"] {
            guard case let .template(_, color) = ProviderMark.art(provider: provider, label: provider) else {
                return XCTFail(provider)
            }
            XCTAssertEqual(color != nil, coloured.contains(provider), provider)
        }
    }

    /// A provider the phone has no mark for gets its initial, as the desktop's BrandTile does.
    func testAnUnknownProviderFallsBackToItsInitial() {
        XCTAssertEqual(ProviderMark.art(provider: "acme", label: "Acme AI"), .monogram("Acme AI"))
        XCTAssertEqual(ProviderMark.art(provider: "acme", label: ""), .monogram("acme"))
    }
}
