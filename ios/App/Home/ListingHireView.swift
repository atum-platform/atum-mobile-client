import AtumDesign
import AtumNativeAPI
import SwiftUI

/// Every word the listing hire shows, from the pinned export. Only "Make
/// your own" is not exported yet (see `docs/ports/w4-e1-researcher-hire.md`).
enum ListingHireCopy {
    private static let roster = "src.matrix.roster-create-copy.copies."
    private static let shell = "src.matrix.mobile-copy.mobileScreensCopy.shell."

    static let readyToHire = roster + "readyToHire"
    static let price = roster + "hirePrice"
    static let hiring = roster + "hiring"
    static let hired = roster + "hired"
    static let failed = roster + "hireFailed"
    static let newAssistant = roster + "newAssistant"
    static let hire = shell + "agentHireConfirm"
    static let short = shell + "agentHireShort"
    static let nameRefused = shell + "agentNameRefused"
    static let limitRefused = shell + "agentLimitRefused"
    static let accountRefused = shell + "agentAccountRefused"
    static let back = "desktop.common.back"
    static let retry = "desktop.common.retry"
    static let done = "desktop.common.done"
    static let purchasesClosed = StoreCopyKey.purchasesClosed
}

/// A listing's face: its catalog glyph, drawn as its Phosphor Light
/// counterpart (never the emoji) on the neutral surface, round because
/// assistants are round (Kit STYLE §5; desktop `StoreArt face`).
struct ListingFace: View {
    let design: LiveDesign
    let glyph: String?
    var base: CGFloat = 48
    @ScaledMetric(relativeTo: .body) private var scale = 1.0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let atum = AtumVisualSystem(design: design)
        let size = AtumAvatar.cappedPointSize(base: base, scaled: base * scale)
        ZStack {
            atum.kitColor(.surface, scheme: scheme)
            Image(design.symbol(StoreGlyphs.alias(glyph: glyph ?? "", kind: .agent)))
                .font(.system(size: size * 0.42, weight: .light))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
        }
        .frame(width: size, height: size)
        .clipShape(AtumAvatar.shape(for: .assistant, size: size))
        .overlay(AtumAvatar.shape(for: .assistant, size: size)
            .strokeBorder(atum.color(.avatarEdge, scheme: scheme), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// The sheet while one listing has its focus: its face and name, one line,
/// its one action (desktop `ListingHireView`). The price shows once, in
/// Protons, and only for a third+ assistant; no balance appears anywhere.
struct ListingHireView: View {
    let design: LiveDesign
    let hire: ListingHireState
    let flow: ListingHireFlow
    let done: () -> Void

    @Environment(\.protonTopUp) private var topUp
    @Environment(\.colorScheme) private var scheme
    @State private var checkout: StorePurchaseGate.Checkout = .closed

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private func copy(_ key: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key, arguments: arguments)
    }

    private var summary: String {
        let value = hire.listing.summary(locale: design.locale)
        return value.isEmpty ? hire.listing.displayName : value
    }

    private var price: Int64? {
        if case let .confirm(price) = hire.phase { return price }
        return nil
    }

    /// A priced seat needs open checkout, as every Proton spend on the phone.
    private var hireAllowed: Bool {
        ListingHireGate.allowsHire(priceProtons: price ?? 0, checkoutOpen: checkout == .open)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ListingFace(design: design, glyph: hire.listing.glyph)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: hire.name)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(atum.color(.ink, scheme: scheme))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("home.newAssistant.hire.name")
                        Text(verbatim: summary)
                            .font(.subheadline)
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 4)
            }
            Section { line }
        }
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme))
        .navigationTitle(copy(ListingHireCopy.newAssistant))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .onReceive(StorePurchaseGate.checkoutUpdates(topUp)) { checkout = $0 }
        .onChange(of: hire.phase) { _, phase in
            if let spoken = announcement(phase) { AccessibilityNotification.Announcement(spoken).post() }
        }
    }

    // MARK: The one line

    @ViewBuilder private var line: some View {
        switch hire.phase {
        case let .confirm(price):
            Text(verbatim: copy(ListingHireCopy.price,
                                [.text(ProtonAmountFormat.price(price * 1_000_000, design: design))]))
                .font(.body.weight(.medium))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .accessibilityIdentifier("home.newAssistant.hire.price")
            if checkout == .closed && !hireAllowed {
                Text(copy(ListingHireCopy.purchasesClosed))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.newAssistant.hire.closed")
            }
        case .hiring:
            Text(verbatim: copy(ListingHireCopy.hiring, [.text(hire.name)]))
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityIdentifier("home.newAssistant.hire.status")
        case .done:
            Text(verbatim: copy(ListingHireCopy.hired, [.text(hire.name)]))
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("home.newAssistant.hire.status")
        case .short:
            notice(copy(ListingHireCopy.short))
        case let .failed(refusal):
            notice(failureText(refusal))
        }
    }

    private func notice(_ text: String) -> some View {
        Text(verbatim: text)
            .foregroundStyle(atum.color(.danger, scheme: scheme))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("home.newAssistant.hire.notice")
    }

    private func failureText(_ refusal: ListingHirePhase.Refusal?) -> String {
        switch refusal {
        case .name?: copy(ListingHireCopy.nameRefused)
        case .limit?: copy(ListingHireCopy.limitRefused)
        case .account?: copy(ListingHireCopy.accountRefused)
        case nil: copy(ListingHireCopy.failed, [.text(hire.name)])
        }
    }

    private func announcement(_ phase: ListingHirePhase) -> String? {
        switch phase {
        case .done: copy(ListingHireCopy.hired, [.text(hire.name)])
        case .short: copy(ListingHireCopy.short)
        case let .failed(refusal): failureText(refusal)
        case .confirm, .hiring: nil
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        VStack(spacing: 6) {
            switch hire.phase {
            case .done:
                Button(copy(ListingHireCopy.done), action: done)
                    .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
                    .accessibilityIdentifier("home.newAssistant.hire.done")
            case .short:
                if checkout == .open {
                    ProtonTopUpButton(design: design, style: .atumPrimary, fullWidth: true,
                                      onFinished: { flow.toppedUp() })
                }
                backButton
            case .failed(nil):
                Button(copy(ListingHireCopy.retry)) { flow.retry() }
                    .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
                    .accessibilityIdentifier("home.newAssistant.hire.retry")
                backButton
            case .failed:
                backButton
            case .confirm, .hiring:
                if hireAllowed || hire.phase == .hiring {
                    Button { flow.confirm() } label: {
                        HStack(spacing: 8) {
                            if hire.phase == .hiring {
                                ProgressView().tint(atum.color(.onInk, scheme: scheme))
                            }
                            Text(copy(ListingHireCopy.hire))
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
                    .disabled(hire.phase == .hiring)
                    .accessibilityIdentifier("home.newAssistant.hire.confirm")
                }
                backButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(atum.color(.ground, scheme: scheme))
        .overlay(alignment: .top) {
            Rectangle().fill(atum.color(.frame, scheme: scheme)).frame(height: 0.5)
        }
    }

    private var backButton: some View {
        Button(copy(ListingHireCopy.back)) { flow.reset() }
            .buttonStyle(AtumQuietButtonStyle(atum: atum, scheme: scheme))
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(hire.phase == .hiring)
            .accessibilityIdentifier("home.newAssistant.hire.back")
    }
}
