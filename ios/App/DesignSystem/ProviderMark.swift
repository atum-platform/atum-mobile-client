import AtumNativeAPI
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

    /// A picker row's mark (desktop `PickerRouteMark`): Atum's logo tile for
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

/// Atum's real logo on its dark tile: the mark (`marks/eclipse.json`, the
/// same file as the desktop's `atum-mark.svg`) on the brand's own `#141311`
/// (`--atum-brand-tile`), which stays dark in light mode too. The one place
/// the phone draws the logo at mark and avatar sizes; there is no second copy.
///
/// - `.pickerMark`: the desktop's inset `BrandMark`
///   (`components/brand-mark.tsx`, `PickerRouteMark` in
///   `model-picker-list.tsx`): the mark at 64%, a 0.5 pt inset hairline of
///   `line-2` (the desktop's `--atum-line-strong`), and the picker's 0.25rem
///   corner on a 16 px mark, kept in proportion as it grows.
/// - `.avatar` / `.avatarInset`: the main assistant's face, the desktop's
///   `AtumAssistantAvatar` with `brand` (`app/atum/assistant-avatar.tsx`): a
///   circle (`.atum-avatar`, `--atum-r-avatar: 9999px`) with no hairline
///   (`.atum-avatar` sets `box-shadow: none`), the mark at 70%, or 64% when
///   `inset` (only the chat list's rows, `roster-conversations.tsx`). The owner
///   chose the real logo there on 2026-10-31: "a redrawn crescent read as a
///   moon".
struct AtumBrandTile: View {
    enum Cut: Equatable {
        case pickerMark
        case avatar
        case avatarInset
    }

    let design: LiveDesign
    let side: CGFloat
    var cut: Cut = .pickerMark

    @Environment(\.colorScheme) private var scheme

    static let tile = Color(.sRGB, red: 0x14 / 255, green: 0x13 / 255, blue: 0x11 / 255, opacity: 1)
    /// The picker mark's (and the inset avatar's) mark over the side.
    static let markScale: CGFloat = 0.64
    static let cornerScale: CGFloat = 4.0 / 16

    /// The mark's side over the tile's for each cut (desktop `size-[64%]` /
    /// `size-[70%]`).
    static func markScale(for cut: Cut) -> CGFloat {
        cut == .avatar ? 0.70 : markScale
    }

    /// The tile's corner: the picker's 4 pt on 16, or a full circle for a face.
    static func cornerRadius(for cut: Cut, side: CGFloat) -> CGFloat {
        cut == .pickerMark ? side * cornerScale : side / 2
    }

    /// Only the picker mark draws the hairline; a face has none on desktop.
    static func hasHairline(_ cut: Cut) -> Bool { cut == .pickerMark }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius(for: cut, side: side))
        let mark = side * Self.markScale(for: cut)
        ZStack {
            shape.fill(Self.tile)
            LiveEclipseMark(design: design)
                .frame(width: mark, height: mark)
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay {
            if Self.hasHairline(cut) {
                shape.strokeBorder(design.kit.color(.line2, scheme: scheme), lineWidth: 0.5)
            }
        }
    }
}
