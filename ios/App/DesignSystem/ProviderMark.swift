import AtumNativeAPI
import SwiftUI

/// A provider's real mark, as the desktop picker draws it
/// (atum-desktop `src/matrix/model-picker-provider-mark.tsx`, #119): the same
/// bundled artwork (`Assets.xcassets/ProviderMarks`, attributed in
/// `Resources/ThirdPartyNotices/ProviderMarks-NOTICE.txt`), the same matching
/// on the provider's id and label, and the same colours. Monochrome marks
/// follow the theme's ink; Claude, Gemini, DeepSeek, MiniMax and Qwen keep
/// their identifying colour; Antigravity is a full-colour image. Atum is its
/// own crescent. A provider with no bundled mark falls back to its initial in
/// the shared squircle, as the desktop's `BrandTile` does. A signed-out
/// connection keeps its full-strength mark (desktop round 2).
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
                // Atum's small face, the crescent the chat title draws
                // (`AtumAvatar.swift:171`); the full eclipse reads as a solid
                // dot at row size in light mode. AtumAvatar scales itself.
                AtumAvatar(kind: .atum, name: "Atum", size: size)
                    .atumDesign(design)
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

    /// A picker row's mark (desktop `PickerRouteMark`): Atum's crescent for
    /// Atum's line-up, else the connection's provider, matched over its id and
    /// the row's connection label. The list and the composer chip both draw a
    /// row's mark through here, so the chip never names a connection by
    /// anything the row does not.
    static func art(source: ManagedModelDestinationSource, connectionLabel: String?) -> Art {
        switch source {
        case .atum: .atum
        case .chatGPTPlan: art(provider: "openai", label: connectionLabel ?? "ChatGPT")
        case .opencodeGo: art(provider: "opencode", label: connectionLabel ?? "OpenCode Go")
        case let .ownKey(provider): art(provider: provider, label: connectionLabel ?? provider)
        }
    }

    static func art(for row: PhoneModelPickerProjection.Row) -> Art {
        art(source: row.source, connectionLabel: row.connectionLabel)
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
