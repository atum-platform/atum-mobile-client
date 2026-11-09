#if DEBUG
import SwiftUI

struct S6SystemGallery: View {
    let design: LiveDesign
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                tokenGrid
                typeRamp
                avatarGrid
                marks
                buttons
            }
            .padding(16)
        }
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .atumDesign(visual: atum)
        .accessibilityIdentifier("system.gallery")
    }

    private var tokenGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 108))], spacing: 8) {
            ForEach(AtumColorRole.allCases, id: \.rawValue) { role in
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(atum.color(role, scheme: scheme))
                        .frame(height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(atum.color(.avatarEdge, scheme: scheme), lineWidth: 0.5))
                    Text(verbatim: role.rawValue)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                }
            }
        }
    }

    private var typeRamp: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeTitle"))
                .font(.system(.largeTitle, weight: .semibold))
            Text(design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.uiStore"))
                .font(.title2.weight(.semibold))
            Text(design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeBody"))
                .font(.body)
            Text(design.text("desktop.atum.discover.catalogStale"))
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
        }
    }

    private var avatarGrid: some View {
        let kinds: [(AtumAvatarKind, String)] = [
            (.atum, "Atum"), (.assistant, "An"), (.app, "Moon"),
            (.person, "Mai"), (.group, "Anka"),
        ]
        let sizes: [CGFloat] = [20, 32, 44, 52, 72]
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { _, value in
                HStack(alignment: .center, spacing: 8) {
                    ForEach(sizes, id: \.self) { size in
                        AtumAvatar(kind: value.0, name: value.1, size: size)
                    }
                }
            }
            HStack(spacing: 12) {
                AppSeal(tier: .official)
                AppSeal(tier: .verified)
            }
        }
    }

    private var marks: some View {
        HStack(spacing: 20) {
            HStack(spacing: 3) { ProtonMark(.small); Text(verbatim: "12") }
            HStack(spacing: 5) { ProtonMark(.regular); Text(verbatim: "12.400") }
            AtomMark().frame(width: 28, height: 28)
            AtomWait().frame(width: 28, height: 28)
        }
        .foregroundStyle(atum.color(.ink, scheme: scheme))
    }

    private var buttons: some View {
        VStack(spacing: 8) {
            Button(design.text("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeActionsSignInLabel")) {}
                .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
            Button(design.text("desktop.dm.signOut")) {}
                .buttonStyle(AtumQuietButtonStyle(atum: atum, scheme: scheme))
            Button(design.text("desktop.atum.discover.open")) {}
                .buttonStyle(AtumCompactButtonStyle(atum: atum, scheme: scheme,
                                                     size: .regular))
            Button(design.text("src.matrix.mobile-copy.mobileChatCopy.appBot.fillIn")) {}
                .buttonStyle(AppAccentButtonStyle(app: moon, atum: atum,
                                                  scheme: scheme, size: .large))
        }
    }

    private var moon: AppBotPresentation {
        AppBotPresentation(
            appID: "00000000-0000-4000-8000-893af8437b12", slug: "moon",
            botUserID: "@app-moon:atum.invalid", name: "Moon", subtitle: nil,
            avatarURL: URL(string: "https://atum.invalid/moon.png")!,
            avatarSHA256: String(repeating: "0", count: 64), accentHex: "#F4D35E",
            verification: .official, purchaseRouteID: "purchase", setupComplete: false
        )
    }
}
#endif

