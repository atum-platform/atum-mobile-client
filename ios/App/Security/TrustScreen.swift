import SwiftUI

/// The M4 trust page: a glyph in a quiet circle, one title, one line, the
/// screen's own content, then at most one primary and one quiet action pinned
/// to the bottom. Airy by construction: nothing else fits.
struct TrustScreen<Content: View, Actions: View>: View {
    let design: LiveDesign
    let glyph: AtumGlyph?
    let title: String
    let message: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var kit: AtumKit { design.kit }

    var body: some View {
        ScrollView {
            VStack(spacing: kit.space(.s3)) {
                if let glyph {
                    Image(atum.symbol(glyph))
                        .font(.title)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .frame(width: 64, height: 64)
                        .background(atum.kitColor(.surface, scheme: scheme), in: Circle())
                        .padding(.bottom, kit.space(.s2))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .font(.body)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content()
                    .padding(.top, kit.space(.s4))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, kit.space(.s5))
            .padding(.top, kit.space(.s8))
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: kit.space(.s1)) { actions() }
                .padding(.horizontal, kit.space(.s4))
                .padding(.bottom, kit.space(.s2))
        }
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
    }
}

/// A short confirmation capsule ("iPhone confirmed"). It never blocks: it
/// sits above the tab bar, reads once to VoiceOver and leaves by itself.
struct TrustToast: View {
    let design: LiveDesign
    let text: String

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var kit: AtumKit { design.kit }

    var body: some View {
        Label {
            Text(text).font(.subheadline.weight(.semibold))
        } icon: {
            Image(atum.symbol(.checkCircle))
        }
        .foregroundStyle(atum.color(.ink, scheme: scheme))
        .padding(.horizontal, kit.space(.s4))
        .padding(.vertical, kit.space(.s3))
        .background(atum.color(.cell, scheme: scheme), in: Capsule())
        .atumKitElevation(.two, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
