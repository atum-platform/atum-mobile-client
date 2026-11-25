import SwiftUI

/// A provider's real mark, as the desktop picker draws it
/// (atum-desktop `src/matrix/model-picker-provider-mark.tsx`, #119): the same
/// bundled artwork (`Assets.xcassets/ProviderMarks`, attributed in
/// `Resources/ThirdPartyNotices/ProviderMarks-NOTICE.txt`), the same matching
/// on the provider's id and label, and the same colours. Monochrome marks
/// follow the theme's ink; Claude, Gemini, DeepSeek, MiniMax and Qwen keep
/// their identifying colour; Antigravity is a full-colour image. Atum wears
/// its real logo, the desktop's inset `BrandMark` (`PickerRouteMark`,
/// `model-picker-list.tsx`): the eclipse at 64% on the dark brand tile, in
/// light and dark alike. A provider with no bundled mark falls back to its
/// initial in the shared squircle, as the desktop's `BrandTile` does. A
/// signed-out connection keeps its full-strength mark (desktop round 2).
struct ProviderMark: View {
    enum Art: Equatable {
        case atum
        /// A template asset tinted with `color`, or with the theme's ink when nil.
        case template(asset: String, color: Color?)
        /// A full-colour image drawn as it is.
        case image(asset: String)
        case monogram(String)
    }

    let design: LiveDesign
    let art: Art
    var size: CGFloat = 16

    @ScaledMetric(relativeTo: .body) private var scale = 1.0
    @Environment(\.colorScheme) private var scheme

    init(design: LiveDesign, provider: String, label: String, size: CGFloat = 16) {
        self.design = design
        art = Self.art(provider: provider, label: label)
        self.size = size
    }

    init(design: LiveDesign, art: Art, size: CGFloat = 16) {
        self.design = design
        self.art = art
        self.size = size
    }

    /// Marks grow with the text so a row's mark keeps its place beside the
    /// name, to twice its size at the largest accessibility sizes.
    private var side: CGFloat { (size * min(scale, 2)).rounded() }

    var body: some View {
        Group {
            switch art {
            case .atum:
                AtumBrandTile(design: design, side: side)
            case let .template(asset, color):
                Image(asset)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(color ?? AtumVisualSystem(design: design).color(.ink, scheme: scheme))
                    .frame(width: side, height: side)
            case let .image(asset):
                Image(asset)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: side, height: side)
            case let .monogram(name):
                // AtumAvatar scales itself; give it the base size.
                AtumAvatar(kind: .app, name: name, size: size)
                    .atumDesign(design)
            }
        }
        // One lead column for every kind of mark, so names line up in a list
        // even where AtumAvatar caps its own growth below `side`.
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    /// Desktop `PROVIDER_ICONS`, first match wins, over "id label" in lower case.
    /// Only the marks the desktop bundles as files are shipped; its
    /// package-drawn marks (Google, OpenRouter, Mistral, Ollama, Hugging Face,
    /// NVIDIA, GitHub, Meta) are not in this app, so those fall back to the
    /// initial (see docs/ports/w4-r-picker-visuals.md).
    static func art(provider: String, label: String) -> Art {
        let identity = (provider + " " + label).lowercased()
        if provider == "atum" { return .atum }
        for (matches, art) in table where matches.contains(where: { identity.contains($0) }) {
            return art
        }
        return .monogram(label.isEmpty ? provider : label)
    }

    private static let table: [([String], Art)] = [
        (["openai-codex", "openai-api", "chatgpt", "codex", "openai"], .template(asset: "provider.openai", color: nil)),
        (["antigravity"], .image(asset: "provider.antigravity")),
        (["anthropic", "claude"], .template(asset: "provider.claude", color: hex(0xD97757))),
        (["deepseek"], .template(asset: "provider.deepseek", color: hex(0x5786FE))),
        (["opencode"], .template(asset: "provider.opencode", color: nil)),
        (["gemini"], .template(asset: "provider.gemini", color: hex(0x8E75B2))),
        (["xai", "grok"], .template(asset: "provider.grok", color: nil)),
        (["minimax"], .template(asset: "provider.minimax", color: hex(0xE73562))),
        (["qwen"], .template(asset: "provider.qwen", color: hex(0x6950EF))),
    ]

    private static func hex(_ value: UInt32) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255, opacity: 1)
    }
}

/// The desktop's inset `BrandMark` (`components/brand-mark.tsx`): Atum's mark
/// (`marks/eclipse.json`, the same file as the desktop's `atum-mark.svg`) at
/// 64% of a dark `#141311` tile, the tile's edge kept by a 0.5 pt inset
/// hairline of `line-2` (the desktop's `--atum-line-strong`). The tile is the
/// brand's own colour, so it stays dark in light mode too. Its corner is the
/// desktop picker's 0.25rem on a 16 px mark, kept in proportion as it grows.
struct AtumBrandTile: View {
    let design: LiveDesign
    let side: CGFloat

    @Environment(\.colorScheme) private var scheme

    static let tile = Color(.sRGB, red: 0x14 / 255, green: 0x13 / 255, blue: 0x11 / 255, opacity: 1)
    static let markScale: CGFloat = 0.64
    static let cornerScale: CGFloat = 4.0 / 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * Self.cornerScale)
        ZStack {
            shape.fill(Self.tile)
            LiveEclipseMark(design: design)
                .frame(width: side * Self.markScale, height: side * Self.markScale)
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(design.kit.color(.line2, scheme: scheme), lineWidth: 0.5)
        }
    }
}
