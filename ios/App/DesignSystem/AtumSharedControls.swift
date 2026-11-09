import SwiftUI

/// Catalog verification is semantic data, not a name-based visual heuristic.
enum AppVerificationTier: Equatable, Sendable {
    case official
    case verified
}

/// The verification seal displayed after a catalog app's name.
struct AppSeal: View {
    enum Placement: Sendable {
        case row
        case chatTitle

        fileprivate var textStyle: Font {
            switch self {
            case .row: .footnote
            case .chatTitle: .caption
            }
        }
    }

    let tier: AppVerificationTier?
    let placement: Placement
    /// The semantic label for the filled mark: an app by default, the
    /// platform-named Founder account where supplied.
    let label: AtumCopyKey

    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    init(tier: AppVerificationTier?, placement: Placement = .row,
         label: AtumCopyKey = .officialApp) {
        self.tier = tier
        self.placement = placement
        self.label = label
    }

    @ViewBuilder var body: some View {
        if let atum, let tier {
            switch tier {
            case .official:
                Image(atum.symbol(.rosetteCheckFilled))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .accessibilityLabel(atum.text(label))
                    .font(placement.textStyle)
            case .verified:
                Image(atum.symbol(.rosetteCheck))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityLabel(atum.text(.verifiedApp))
                    .font(placement.textStyle)
            }
        }
    }
}

/// Places a semantic app seal after a supplied name with the prescribed gap.
/// Omit this component in combined accessibility rows, where the row reads the
/// app kind instead and the decorative seal must remain hidden.
struct AppNameWithSeal<Label: View>: View {
    let tier: AppVerificationTier?
    let placement: AppSeal.Placement
    let label: Label

    init(tier: AppVerificationTier?, placement: AppSeal.Placement = .row,
         @ViewBuilder label: @escaping () -> Label) {
        self.tier = tier
        self.placement = placement
        self.label = label()
    }

    var body: some View {
        HStack(spacing: 4) {
            label
            if tier != nil {
                AppSeal(tier: tier, placement: placement)
            }
        }
    }
}

/// The shared solid primary treatment. Busy labels are supplied by callers as
/// a 20 pt `AtomWait`, keeping the button's frame fixed and its action disabled.
struct AtumPrimaryButtonStyle: PrimitiveButtonStyle {
    let atum: AtumVisualSystem
    let scheme: ColorScheme

    init(atum: AtumVisualSystem, scheme: ColorScheme) {
        self.atum = atum
        self.scheme = scheme
    }

    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) {
            configuration.label
                .font(.body.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(atum.color(.ink, scheme: scheme))
        .foregroundStyle(atum.color(.onInk, scheme: scheme))
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, minHeight: 50)
    }
}

/// The shared quiet treatment for a secondary action.
struct AtumQuietButtonStyle: ButtonStyle {
    let atum: AtumVisualSystem
    let scheme: ColorScheme

    init(atum: AtumVisualSystem, scheme: ColorScheme) {
        self.atum = atum
        self.scheme = scheme
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .foregroundStyle(atum.color(.soft, scheme: scheme))
            .opacity(configuration.isPressed ? 0.65 : 1)
            .frame(minHeight: 44)
    }
}

/// The capsule action used for small row controls and empty-state actions.
struct AtumCompactButtonStyle: PrimitiveButtonStyle {
    enum Size: Sendable {
        case small
        case regular

        fileprivate var controlSize: ControlSize {
            switch self {
            case .small: .small
            case .regular: .regular
            }
        }
    }

    let atum: AtumVisualSystem
    let scheme: ColorScheme
    let size: Size

    init(atum: AtumVisualSystem, scheme: ColorScheme, size: Size = .small) {
        self.atum = atum
        self.scheme = scheme
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        Button(action: configuration.trigger) {
            configuration.label
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(size.controlSize)
        .tint(atum.color(.ink, scheme: scheme))
    }
}
