import AtumDesign
import SwiftUI

// The app's half of Atum Kit: loading the vendored tokens, the legacy palette
// mapping, the `.atumDesign` installers and the composites that also read the
// legacy projection (`\.atum`). AtumKit.swift holds the token reader and the
// primitives the share extension compiles too.

extension AtumKit {
    /// The tokens in the committed design bundle. Throws until the pinned export lists them.
    static func vendored() throws -> AtumKit {
        try AtumKit(data: AtumDesign.data(for: resource))
    }
}

/// The pre-Kit palette (`phone-design.json`) mapped onto Kit roles (gap spec §1).
/// `LiveDesign.color` consults it first, so a legacy call site draws Kit colours.
/// Roles absent here (media viewer, scrims, `eclipseTile`) keep their exported value.
enum AtumKitLegacyRoles {
    static let table: [String: AtumKit.ColorRole] = [
        "ground": .ground,
        "cell": .surface,
        "roster": .surface,
        // Quiet tiles and peer fills. Your own bubble asks for `.bubbleOwn` explicitly.
        "bubble": .sunk,
        "frame": .line,
        "avatarEdge": .line,
        "ink": .ink,
        "soft": .ink2,
        "muted": .ink3,
        "actionStrong": .ink,
        "actionQuiet": .ink4,
        "danger": .danger,
        "onInk": .onInk,
        "glass": .glass,
        "glassOpaque": .raised,
    ]

    static func kitRole(for legacy: String) -> AtumKit.ColorRole? { table[legacy] }
}

extension View {
    /// Installs both design environments a screen reads: the typed legacy projection
    /// (`\.atum`) and the Kit tokens (`\.atumKit`).
    @MainActor
    func atumDesign(_ design: LiveDesign) -> some View {
        environment(\.atum, AtumVisualSystem(design: design))
            .environment(\.atumKit, design.kit)
    }

    /// The same, from an already-built projection (sheets re-installing their parent's).
    @MainActor
    func atumDesign(visual atum: AtumVisualSystem?) -> some View {
        environment(\.atum, atum)
            .environment(\.atumKit, atum?.kit)
    }
}

// MARK: - Notice

/// A notice's tone. Only the icon takes it; the panel stays neutral.
enum AtumNoticeTone: Sendable {
    case neutral, warning, danger

    var iconRole: AtumKit.ColorRole {
        switch self {
        case .neutral: .ink2
        case .warning: .warn
        case .danger: .danger
        }
    }
}

/// An inline notice: a quiet neutral panel (never tinted). Only the icon takes the tone.
struct AtumNotice<Actions: View>: View {
    typealias Tone = AtumNoticeTone

    let glyph: AtumGlyph
    let title: String
    let message: String?
    let tone: Tone
    let actions: Actions

    @Environment(\.atumKit) private var kit
    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    init(glyph: AtumGlyph, title: String, message: String? = nil, tone: Tone = .neutral,
         @ViewBuilder actions: () -> Actions) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.tone = tone
        self.actions = actions()
    }

    var body: some View {
        if let kit {
            HStack(alignment: .top, spacing: kit.space(.s3)) {
                if let atum {
                    Image(atum.symbol(glyph))
                        .font(kit.font(.headline))
                        .foregroundStyle(kit.color(tone.iconRole, scheme: scheme))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(kit.font(.bodyStrong))
                        .foregroundStyle(kit.color(.ink, scheme: scheme))
                    if let message {
                        Text(message)
                            .font(kit.font(.body))
                            .foregroundStyle(kit.color(.ink2, scheme: scheme))
                    }
                    if Actions.self != EmptyView.self {
                        actions
                            .padding(.top, kit.space(.s2))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, kit.space(.s3))
            .padding(.leading, 14)
            .padding(.trailing, kit.space(.s3))
            .background(kit.color(.fillQuiet, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: kit.radius(.lg), style: .continuous))
            .accessibilityElement(children: .contain)
        }
    }
}

extension AtumNotice where Actions == EmptyView {
    init(glyph: AtumGlyph, title: String, message: String? = nil, tone: Tone = .neutral) {
        self.init(glyph: glyph, title: title, message: message, tone: tone) { EmptyView() }
    }
}

// MARK: - Atum asks

/// Atum asking the person for something: a mark, a title and body, optional detail rows,
/// and a primary action beside "Not now".
struct AtumAskCard: View {
    struct Detail: Identifiable, Sendable {
        let id: String
        let glyph: AtumGlyph
        let text: String

        init(id: String? = nil, glyph: AtumGlyph, text: String) {
            self.id = id ?? text
            self.glyph = glyph
            self.text = text
        }
    }

    let glyph: AtumGlyph
    let title: String
    let message: String
    let details: [Detail]
    let primaryTitle: String
    let primary: () -> Void
    let notNow: () -> Void

    @Environment(\.atumKit) private var kit
    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    /// Detail rows and actions align with the text column: the 32 pt mark plus a 12 pt gap.
    static let textInset: CGFloat = 44

    init(glyph: AtumGlyph, title: String, message: String, details: [Detail] = [],
         primaryTitle: String, primary: @escaping () -> Void, notNow: @escaping () -> Void) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.details = details
        self.primaryTitle = primaryTitle
        self.primary = primary
        self.notNow = notNow
    }

    var body: some View {
        if let kit, let atum {
            let shape = RoundedRectangle(cornerRadius: kit.radius(.xl), style: .continuous)
            VStack(alignment: .leading, spacing: kit.space(.s3)) {
                HStack(alignment: .top, spacing: kit.space(.s3)) {
                    Image(atum.symbol(glyph))
                        .font(kit.font(.body))
                        .foregroundStyle(kit.color(.ink, scheme: scheme))
                        .frame(width: 32, height: 32)
                        .background(kit.color(.fillQuiet, scheme: scheme), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(kit.font(.headline))
                            .foregroundStyle(kit.color(.ink, scheme: scheme))
                            .accessibilityAddTraits(.isHeader)
                        Text(message)
                            .font(kit.font(.body))
                            .foregroundStyle(kit.color(.ink2, scheme: scheme))
                    }
                }
                if !details.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(details) { detail in
                            HStack(spacing: kit.space(.s2)) {
                                Image(atum.symbol(detail.glyph))
                                    .font(kit.font(.callout))
                                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
                                    .accessibilityHidden(true)
                                Text(detail.text)
                                    .font(kit.font(.body))
                                    .foregroundStyle(kit.color(.ink2, scheme: scheme))
                            }
                        }
                    }
                    .padding(.leading, Self.textInset)
                }
                HStack(spacing: kit.space(.s2)) {
                    Button(primaryTitle, action: primary)
                        .buttonStyle(AtumKitButtonStyle(kind: .primary, height: .regular))
                    Button(atum.text(.notNow), action: notNow)
                        .buttonStyle(.atumPlain)
                }
                .padding(.leading, Self.textInset)
            }
            .padding(kit.space(.s4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kit.color(.surface, scheme: scheme), in: shape)
            .atumKitElevation(.one, in: shape)
        }
    }
}
