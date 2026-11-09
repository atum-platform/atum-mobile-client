import AtumChat
import AtumDesign
import CoreGraphics
import ImageIO
import SwiftUI
import UIKit

struct AppBotAvatar: View {
    let app: AppBotPresentation
    let size: CGFloat
    @State private var art: AtumAvatarArt?

    var body: some View {
        AtumAvatar(kind: .app, name: app.name, art: art, size: size)
            .task(id: Request(url: app.avatarURL, sha256: app.avatarSHA256, size: size)) {
                art = nil
                guard let data = await AtumRemoteAvatarLoader.shared.data(
                    for: app.avatarURL,
                    expectedSHA256: app.avatarSHA256
                ), !Task.isCancelled else { return }
                let loaded = await AtumAvatarArt.load(data: data, pixelSide: AtumAvatar.thumbnailPixelSide(for: size))
                guard !Task.isCancelled else { return }
                art = loaded
            }
    }

    private struct Request: Hashable {
        let url: URL
        let sha256: String
        let size: CGFloat
    }
}

struct AppBotHero: View {
    let app: AppBotPresentation
    let design: LiveDesign
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 8) {
            AppBotAvatar(app: app, size: 72)
            AppNameWithSeal(tier: app.verification) {
                Text(verbatim: app.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(design.color("ink", scheme: scheme))
            }
            if let subtitle = app.subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.subheadline)
                    .foregroundStyle(design.color("soft", scheme: scheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
        }
        .padding(.horizontal, 32)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.appBotHero)
    }
}

struct AppBotRoomOpeningView: View {
    let opening: AppBotRoomOpening
    let design: LiveDesign
    let retry: () -> Void
    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            AppBotHero(app: opening.app, design: design)
            switch opening.phase {
            case .joining:
                AtomWait()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(design.color("muted", scheme: scheme))
                    .padding(.top, 8)
                    .accessibilityHidden(true)
            case .failed:
                Text(ChatCopy.text(design, .appBotRoomFailed, [.text(opening.app.name)]))
                    .font(.footnote)
                    .foregroundStyle(design.color("soft", scheme: scheme))
                    .multilineTextAlignment(.center)
                if let atum {
                    Button(action: retry) {
                        Text(ChatCopy.text(design, .retry))
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .tint(atum.color(.ink, scheme: scheme))
                        .foregroundStyle(atum.color(.onInk, scheme: scheme))
                        .frame(maxWidth: 360)
                        .accessibilityIdentifier(AccessibilityID.appBotRoomRetry)
                }
            }
            Spacer()
        }
        .padding(24)
        .background(design.color("ground", scheme: scheme).ignoresSafeArea())
    }
}

struct ContinueOnMacSheet: View {
    let request: AppBotContinueRequest
    let design: LiveDesign
    let dismiss: () -> Void
    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                AppBotAvatar(app: request.app, size: 56)
                Text(copy(.appBotContinueTitle))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(bodyCopy)
                    .font(.subheadline)
                    .foregroundStyle(design.color("soft", scheme: scheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer().frame(height: 4)
                if let atum {
                    Button(copy(.appBotGotIt), action: dismiss)
                        .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 16)
        }
        .presentationDragIndicator(.visible)
        .presentationSizing(.fitted)
        .accessibilityIdentifier(AccessibilityID.appBotContinueSheet)
    }

    private var bodyCopy: String {
        switch request.kind {
        case .setup: copy(.appBotContinueSetupBody, [.text(request.app.name)])
        case .route: copy(.appBotContinueRouteBody, [.text(request.app.name)])
        }
    }

    private func copy(_ key: ChatCopyKey, _ arguments: [AtumCopy.Argument] = []) -> String {
        ChatCopy.text(design, key, arguments)
    }
}

struct AppAccentButtonStyle: PrimitiveButtonStyle {
    enum Size: Sendable { case compact, large }

    let app: AppBotPresentation
    let atum: AtumVisualSystem
    let scheme: ColorScheme
    let size: Size

    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) {
            configuration.label
                .font(size == .large ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, size == .large ? 20 : 16)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(size == .large ? .large : .regular)
        .tint(app.brandAccentColor ?? atum.color(.ink, scheme: scheme))
        .foregroundStyle(app.brandAccentColor == nil
                         ? atum.color(.onInk, scheme: scheme)
                         : atum.color(.onAccent, scheme: scheme))
        .frame(maxWidth: size == .large ? 360 : nil)
        .frame(maxWidth: size == .large ? .infinity : nil,
               minHeight: size == .large ? 50 : 44)
    }
}

extension AppBotPresentation {
    var brandAccentColor: Color? {
        guard let hex = AppBrand.resolve(accentHex: accentHex).avatarRingHex else { return nil }
        return Color(appHex: hex)
    }
}

private extension Color {
    init?(appHex: String) {
        guard let normalized = AppBrand.normalizedHex(appHex),
              let value = UInt64(normalized.dropFirst(), radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xff) / 255,
                  green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255,
                  opacity: 1)
    }
}
