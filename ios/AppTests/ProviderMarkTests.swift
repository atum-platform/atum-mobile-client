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
            ("copilot-acp", "GitHub Copilot", "provider.github-copilot"),
        ]
        for (provider, label, asset) in expected {
            guard case let .template(name, _) = ProviderMark.art(provider: provider, label: label) else {
                return XCTFail("\(provider) has no template mark")
            }
            XCTAssertEqual(name, asset, provider)
            XCTAssertNotNil(UIImage(named: name), "\(name) is not in the asset catalog")
        }
    }

    func testAntigravityIsTheFullColourImageAndAtumIsTheEclipse() {
        XCTAssertEqual(ProviderMark.art(provider: "antigravity", label: "Antigravity"),
                       .image(asset: "provider.antigravity"))
        XCTAssertNotNil(UIImage(named: "provider.antigravity"))
        XCTAssertEqual(ProviderMark.art(provider: "atum", label: "Atum"), .atum)
    }

    /// Monochrome marks follow the theme's ink; the brand-coloured ones keep their colour.
    func testOnlyTheDesktopsColouredMarksCarryAColour() {
        let coloured = ["claude", "deepseek", "gemini", "minimax", "qwen"]
        for provider in coloured + ["openai", "opencode", "grok", "copilot"] {
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
