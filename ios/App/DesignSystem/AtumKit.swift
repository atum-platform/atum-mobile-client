import SwiftUI
import AtumDesign

/// Atum Kit 0.1 on the phone: a typed reader for `atum-kit-tokens.json`, generated in
/// atum-app from `packages/atum-kit/tokens.json` (the same source as the desktop's
/// `--ak-*` tokens) and pinned here through `atum-design.lock`.
///
/// Rules carried over from the kit: actions are capsules, inputs and containers are
/// rounded rectangles, colour is rare (ink carries everything; red is danger), glass is
/// for floating chrome only, people and agents are circles, apps are squircles.
///
/// `LiveDesign` loads it once; every screen root installs it with `.atumDesign(design)`,
/// and legacy palette roles resolve to these tokens (`AtumKitLegacyRoles`). A primitive
/// without an installed kit renders its content unstyled rather than inventing a palette.
struct AtumKit: Sendable {
    static let resource = "atum-kit-tokens.json"
    static let supportedSchemaVersion = 1

    enum LoadError: Error, Equatable {
        case unsupportedSchema(Int)
        case missingToken(String)
    }

    // MARK: Roles

    /// Semantic colour roles. Raw values are the token names in `tokens.json`.
    enum ColorRole: String, CaseIterable, Sendable {
        case ground, chrome, surface, raised, sunk
        case ink
        case ink2 = "ink-2"
        case ink3 = "ink-3"
        /// Icons and strokes only, never text.
        case ink4 = "ink-4"
        case onInk = "on-ink"
        case line
        case line2 = "line-2"
        case fillQuiet = "fill-quiet"
        case fillHover = "fill-hover"
        case fillPress = "fill-press"
        case fillSelected = "fill-selected"
        case inkHover = "ink-hover"
        case inkPress = "ink-press"
        case danger
        case dangerFill = "danger-fill"
        case dangerHover = "danger-hover"
        case warn
        case warnFill = "warn-fill"
        case ok
        case okFill = "ok-fill"
        case glass
        case glassRim = "glass-rim"
        case glassEdge = "glass-edge"
        case scrim, focus, knob
        case frame, panel
        case panelRim = "panel-rim"
        /// Your own chat bubble: ink in light, a lifted grey in dark (STYLE §10).
        case bubbleOwn = "bubble-own"
        case onBubbleOwn = "on-bubble-own"
    }

    enum ShadowLevel: String, CaseIterable, Sendable {
        case one = "shadow-1"
        case two = "shadow-2"
        case three = "shadow-3"
    }

    enum Radius: String, CaseIterable, Sendable {
        case xs, sm, md, lg, xl
        case xxl = "2xl"
        case full
    }

    /// The 4-point spacing grid (`--ak-s1` … `--ak-s12`).
    enum Space: String, CaseIterable, Sendable {
        case s1 = "1", s2 = "2", s3 = "3", s4 = "4", s5 = "5", s6 = "6", s8 = "8", s12 = "12"
    }

    /// Desktop control heights (26/32/40). Phone buttons use `phoneControlHeight`.
    enum ControlHeight: String, CaseIterable, Sendable {
        case sm, md, lg
    }

    /// Phone control heights: 50 pt for a primary action, 44 pt for every other control.
    enum PhoneControlHeight: String, CaseIterable, Sendable {
        case primary, regular
    }

    /// The kit's type roles. On the phone they follow Dynamic Type through a text style;
    /// the desktop's point sizes stay in `tokens` for reference.
    enum TypeRole: String, CaseIterable, Sendable {
        case display, title, headline, chat, body
        case bodyStrong = "body-strong"
        case callout, caption

        var textStyle: Font.TextStyle {
            switch self {
            case .display: .largeTitle
            case .title: .title2
            case .headline: .headline
            case .chat, .body, .bodyStrong: .body
            case .callout: .subheadline
            case .caption: .caption
            }
        }
    }

    // MARK: Decoded tokens

    struct RGBA: Decodable, Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
        var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    }

    struct ShadowLayer: Decodable, Equatable, Sendable {
        let x: Double
        let y: Double
        let blur: Double
        let spread: Double
        let color: RGBA
    }

    struct LinearGradientToken: Decodable, Equatable, Sendable {
        struct Stop: Decodable, Equatable, Sendable {
            let color: RGBA
            let location: Double
        }
        let angleDegrees: Double
        let stops: [Stop]
    }

    struct TypeToken: Decodable, Equatable, Sendable {
        let size: Double
        let lineHeight: Double
        let weight: Int
        let family: String
    }

    struct Schemes<Value: Decodable & Sendable>: Decodable, Sendable {
        let light: Value
        let dark: Value
        func value(_ scheme: ColorScheme) -> Value { scheme == .dark ? dark : light }
    }

    struct Phone: Decodable, Sendable {
        let controlHeight: [String: Double]
        let appIconCornerRatio: Double
    }

    struct Tokens: Decodable, Sendable {
        let schemaVersion: Int
        let kitVersion: String
        let light: [String: RGBA]
        let dark: [String: RGBA]
        let gradients: Schemes<[String: LinearGradientToken]>
        let shadows: Schemes<[String: [ShadowLayer]]>
        let type: [String: TypeToken]
        let space: [String: Double]
        let radius: [String: Double]
        let controlHeight: [String: Double]
        let icon: [String: Double]
        let phone: Phone
    }

    let tokens: Tokens

    /// Decodes and validates the export: every role this file names must be present in
    /// both schemes, so a missing token fails at load, never at a call site.
    init(data: Data) throws {
        let tokens = try JSONDecoder().decode(Tokens.self, from: data)
        guard tokens.schemaVersion == Self.supportedSchemaVersion else {
            throw LoadError.unsupportedSchema(tokens.schemaVersion)
        }
        func require<Key: RawRepresentable & CaseIterable, Value>(_: Key.Type, in table: [String: Value],
                                                                  _ context: String) throws where Key.RawValue == String {
            for key in Key.allCases where table[key.rawValue] == nil {
                throw LoadError.missingToken("\(context).\(key.rawValue)")
            }
        }
        try require(ColorRole.self, in: tokens.light, "light")
        try require(ColorRole.self, in: tokens.dark, "dark")
        try require(ShadowLevel.self, in: tokens.shadows.light, "shadows.light")
        try require(ShadowLevel.self, in: tokens.shadows.dark, "shadows.dark")
        try require(TypeRole.self, in: tokens.type, "type")
        try require(Space.self, in: tokens.space, "space")
        try require(Radius.self, in: tokens.radius, "radius")
        try require(ControlHeight.self, in: tokens.controlHeight, "controlHeight")
        try require(PhoneControlHeight.self, in: tokens.phone.controlHeight, "phone.controlHeight")
        for scheme in ["light", "dark"] {
            let table = scheme == "dark" ? tokens.gradients.dark : tokens.gradients.light
            guard let stops = table["monogram"]?.stops, stops.count >= 2 else {
                throw LoadError.missingToken("gradients.\(scheme).monogram")
            }
        }
        self.tokens = tokens
    }

    /// The tokens in the committed design bundle. Throws until the pinned export lists them.
    static func vendored() throws -> AtumKit {
        try AtumKit(data: AtumDesign.data(for: resource))
    }

    // MARK: Accessors

    func rgba(_ role: ColorRole, scheme: ColorScheme) -> RGBA {
        (scheme == .dark ? tokens.dark : tokens.light)[role.rawValue]!
    }

    func color(_ role: ColorRole, scheme: ColorScheme) -> Color {
        rgba(role, scheme: scheme).color
    }

    func radius(_ radius: Radius) -> CGFloat { CGFloat(tokens.radius[radius.rawValue]!) }

    func space(_ space: Space) -> CGFloat { CGFloat(tokens.space[space.rawValue]!) }

    func controlHeight(_ height: ControlHeight) -> CGFloat { CGFloat(tokens.controlHeight[height.rawValue]!) }

    func phoneControlHeight(_ height: PhoneControlHeight) -> CGFloat {
        CGFloat(tokens.phone.controlHeight[height.rawValue]!)
    }

    func shadow(_ level: ShadowLevel, scheme: ColorScheme) -> [ShadowLayer] {
        tokens.shadows.value(scheme)[level.rawValue]!
    }

    /// The grey monogram fill for avatars (a top-to-bottom gradient in the kit).
    func monogram(scheme: ColorScheme) -> LinearGradient {
        let token = tokens.gradients.value(scheme)["monogram"]!
        return LinearGradient(stops: token.stops.map { .init(color: $0.color.color, location: $0.location) },
                              startPoint: .top, endPoint: .bottom)
    }

    /// The role's Dynamic Type font, with the kit's weight for that role.
    func font(_ role: TypeRole) -> Font {
        .system(role.textStyle, weight: Self.weight(tokens.type[role.rawValue]!.weight))
    }

    static func weight(_ value: Int) -> Font.Weight {
        switch value {
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        default: .bold
        }
    }
}

extension EnvironmentValues {
    /// Installed at a root with `.atumDesign(design)` (or, without a `LiveDesign`,
    /// `.environment(\.atumKit, try AtumKit.vendored())`).
    @Entry var atumKit: AtumKit?
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

// MARK: - Elevation

/// Applies a kit shadow. Zero-blur spread layers (the kit's hairline ring) become a
/// stroke on the shape; blurred layers become SwiftUI shadows (CSS blur ≈ 2 × radius).
struct AtumKitElevation<S: InsettableShape>: ViewModifier {
    let level: AtumKit.ShadowLevel
    let shape: S
    @Environment(\.atumKit) private var kit
    @Environment(\.colorScheme) private var scheme

    init(level: AtumKit.ShadowLevel, shape: S) {
        self.level = level
        self.shape = shape
    }

    func body(content: Content) -> some View {
        if let kit {
            elevated(content, layers: kit.shadow(level, scheme: scheme))
        } else {
            content
        }
    }

    private func elevated(_ content: Content, layers: [AtumKit.ShadowLayer]) -> AnyView {
        var view = AnyView(content)
        for layer in layers {
            if layer.blur == 0, layer.spread > 0 {
                view = AnyView(view.overlay(shape.strokeBorder(layer.color.color, lineWidth: layer.spread)))
            } else {
                view = AnyView(view.shadow(color: layer.color.color, radius: layer.blur / 2, x: layer.x, y: layer.y))
            }
        }
        return view
    }
}

extension View {
    func atumKitElevation(_ level: AtumKit.ShadowLevel, in shape: some InsettableShape) -> some View {
        modifier(AtumKitElevation(level: level, shape: shape))
    }
}

// MARK: - Buttons (capsules)

/// The kit's capsule buttons. Primary is ink on ink-inverse at 50 pt; every other kind is
/// 44 pt. Danger keeps a neutral fill with red text; destructive is solid red.
struct AtumKitButtonStyle: ButtonStyle {
    enum Kind: CaseIterable, Sendable {
        case primary, secondary, plain, danger, destructive
        /// Frosted glass, for floating chrome only.
        case glass
    }

    let kind: Kind
    /// Overrides the kind's default height (50 pt primary, 44 pt otherwise).
    var height: AtumKit.PhoneControlHeight?

    func makeBody(configuration: Configuration) -> some View {
        AtumKitButtonBody(configuration: configuration, kind: kind,
                          height: height ?? (kind == .primary ? .primary : .regular))
    }
}

private struct AtumKitButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: AtumKitButtonStyle.Kind
    let height: AtumKit.PhoneControlHeight
    @Environment(\.atumKit) private var kit
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceTransparency) private var opaque

    var body: some View {
        if let kit {
            styled(kit)
        } else {
            configuration.label
        }
    }

    private func styled(_ kit: AtumKit) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(kit.font(.bodyStrong))
            .lineLimit(1)
            .foregroundStyle(foreground(kit, pressed: pressed))
            .padding(.horizontal, kit.space(.s5))
            .frame(minHeight: kit.phoneControlHeight(height))
            .background { background(kit, pressed: pressed) }
            .contentShape(Capsule())
            .scaleEffect(pressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.38)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }

    private func foreground(_ kit: AtumKit, pressed: Bool) -> Color {
        switch kind {
        case .primary: kit.color(.onInk, scheme: scheme)
        case .secondary, .plain, .glass: kit.color(.ink, scheme: scheme)
        case .danger: kit.color(pressed ? .dangerHover : .danger, scheme: scheme)
        case .destructive: .white
        }
    }

    @ViewBuilder private func background(_ kit: AtumKit, pressed: Bool) -> some View {
        switch kind {
        case .primary:
            Capsule().fill(kit.color(pressed ? .inkPress : .ink, scheme: scheme))
        case .secondary, .danger:
            Capsule().fill(kit.color(pressed ? .fillPress : .fillQuiet, scheme: scheme))
        case .plain:
            Capsule().fill(pressed ? kit.color(.fillPress, scheme: scheme) : .clear)
        case .destructive:
            Capsule().fill(kit.color(.danger, scheme: scheme))
        case .glass:
            if opaque {
                Capsule().fill(kit.color(.raised, scheme: scheme))
            } else {
                Capsule().fill(.clear).glassEffect(.regular.interactive(), in: Capsule())
            }
        }
    }
}

extension ButtonStyle where Self == AtumKitButtonStyle {
    static var atumPrimary: AtumKitButtonStyle { .init(kind: .primary) }
    static var atumSecondary: AtumKitButtonStyle { .init(kind: .secondary) }
    static var atumPlain: AtumKitButtonStyle { .init(kind: .plain) }
    static var atumDanger: AtumKitButtonStyle { .init(kind: .danger) }
    static var atumDestructive: AtumKitButtonStyle { .init(kind: .destructive) }
    static var atumGlass: AtumKitButtonStyle { .init(kind: .glass) }
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

// MARK: - Identity shapes

/// People, agents and groups are circles: a grey monogram gradient with white initials.
struct AtumMonogramAvatar: View {
    let name: String
    let size: CGFloat

    @Environment(\.atumKit) private var kit
    @Environment(\.colorScheme) private var scheme

    init(name: String, size: CGFloat = 40) {
        self.name = name
        self.size = size
    }

    var body: some View {
        if let kit {
            Text(Self.initials(name))
                .font(.system(size: size * 0.43, weight: .semibold))
                .tracking(size * 0.02)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: size, height: size)
                .background(kit.monogram(scheme: scheme), in: Circle())
                .accessibilityHidden(true)
        }
    }

    /// Up to two initials: the first letters of the first and last words.
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        guard let first = words.first?.first else { return "" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }
}

/// Apps and services are squircles: Apple's continuous-corner app-icon tile.
struct AtumAppIconShape: InsettableShape {
    /// Corner radius as a fraction of the tile's side (matches `phone.appIconCornerRatio`).
    static let cornerRatio: CGFloat = 0.2237
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let tile = rect.insetBy(dx: inset, dy: inset)
        let side = min(tile.width, tile.height)
        return RoundedRectangle(cornerRadius: side * Self.cornerRatio, style: .continuous).path(in: tile)
    }

    func inset(by amount: CGFloat) -> AtumAppIconShape {
        AtumAppIconShape(inset: inset + amount)
    }
}
