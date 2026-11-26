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
    /// Pending export: desktop has no "hired, chat still being set up" line
    /// (its sheet shows Done at once). The nearest exported line stands in:
    /// launch-copy `gettingReady`, "%1$@ is getting ready…".
    static let settingUp = "src.matrix.launch-copy.copies.gettingReady"
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
                .font(.system(size: size * 0.42, weight: .light)) // design-lint: allow: monogram scales with the tile, not with text
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
    /// Whether the hired assistant's chat is open on this phone yet.
    var chatReady: (NativeID) -> Bool = { _ in true }
    let done: () -> Void

    @Environment(\.protonTopUp) private var topUp
    @Environment(\.atumBetaFeatures) private var betaFeatures
    @Environment(\.colorScheme) private var scheme
    @State private var checkout: StorePurchaseGate.Checkout = .closed

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var kit: AtumKit { design.kit }
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

    /// A priced seat needs a real price and open checkout, as every Proton
    /// spend on the phone. The confirm step only ever shows a priced seat.
    private var hireAllowed: Bool {
        ListingHireGate.allowsPaidHire(priceProtons: price ?? 0, checkoutOpen: checkout == .open)
    }

    private var comingSoon: Bool {
        guard !betaFeatures else { return false }
        switch hire.phase {
        case .confirm, .short, .failed(nil): return true
        default: return false
        }
    }

    /// The setting-up phase's assistant, while its chat isn't open yet.
    private var waitingFor: NativeID? {
        if case let .settingUp(assistantID) = hire.phase { return assistantID }
        return nil
    }

    private var waitedChatReady: Bool {
        waitingFor.map(chatReady) ?? false
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: kit.space(.s3)) {
                    ListingFace(design: design, glyph: hire.listing.glyph)
                    VStack(alignment: .leading, spacing: kit.space(.s1)) {
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
                .padding(.vertical, kit.space(.s1))
            }
            if !comingSoon { Section { line } }
        }
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme))
        .navigationTitle(copy(ListingHireCopy.newAssistant))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .onReceive(StorePurchaseGate.checkoutUpdates(topUp)) { checkout = $0 }
        .onChange(of: hire.phase) { _, phase in
            guard !comingSoon else { return }
            if let spoken = announcement(phase) { AccessibilityNotification.Announcement(spoken).post() }
        }
        .onChange(of: waitedChatReady, initial: true) { _, ready in
            if ready { flow.chatAvailable() }
        }
    }

    // MARK: The one line

    @ViewBuilder private var line: some View {
        switch hire.phase {
        case let .confirm(price):
            if price > 0 {
                Text(verbatim: copy(ListingHireCopy.price,
                                    [.text(ProtonAmountFormat.price(price * 1_000_000, design: design))]))
                    .font(.body.weight(.medium))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .accessibilityIdentifier("home.newAssistant.hire.price")
            }
            // No real price yet reads as not available, whatever checkout says.
            if !hireAllowed && (checkout == .closed || price <= 0) {
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
        case .settingUp:
            HStack(spacing: kit.space(.s2)) {
                ProgressView().accessibilityHidden(true)
                Text(verbatim: copy(ListingHireCopy.settingUp, [.text(hire.name)]))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("home.newAssistant.hire.status")
            }
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
        case .settingUp: copy(ListingHireCopy.settingUp, [.text(hire.name)])
        case .short: copy(ListingHireCopy.short)
        case let .failed(refusal): failureText(refusal)
        case .confirm, .hiring: nil
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        VStack(spacing: kit.space(.s2)) {
            switch hire.phase {
            case .confirm where comingSoon, .short where comingSoon, .failed(nil) where comingSoon:
                revokedActions
            case .done, .settingUp:
                Button(action: done) { primaryLabel(copy(ListingHireCopy.done)) }
                    .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
                    .accessibilityIdentifier("home.newAssistant.hire.done")
            case .short:
                if checkout == .open {
                    ProtonTopUpButton(design: design, style: .atumPrimary, fullWidth: true,
                                      onFinished: { flow.toppedUp() })
                        .environment(\.protonTopUpRequiresBeta, true)
                }
                backButton
            case .failed(nil):
                Button { flow.retry(betaFeatures: betaFeatures) } label: { primaryLabel(copy(ListingHireCopy.retry)) }
                    .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
                    .accessibilityIdentifier("home.newAssistant.hire.retry")
                backButton
            case .failed:
                backButton
            case .confirm, .hiring:
                if betaFeatures && (hireAllowed || hire.phase == .hiring) {
                    Button { flow.confirm(betaFeatures: betaFeatures) } label: {
                        HStack(spacing: kit.space(.s2)) {
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
        .padding(.horizontal, kit.space(.s4))
        .padding(.vertical, kit.space(.s3))
        .background(atum.color(.ground, scheme: scheme))
        // One haptic per hire: success once it is hired, error on a failure line.
        .sensoryFeedback(trigger: hire.phase) { old, new in
            switch (old, new) {
            case (.hiring, .settingUp), (.hiring, .done): .success
            case (_, .failed): .error
            default: nil
            }
        }
        .overlay(alignment: .top) {
            Rectangle().fill(atum.color(.frame, scheme: scheme)).frame(height: 0.5)
        }
    }

    private var revokedActions: some View {
        Group {
            Button {} label: { primaryLabel(copy(StoreCopyKey.comingSoon)) }
                .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
                .disabled(true)
                .accessibilityIdentifier("home.newAssistant.listing.soon")
            backButton
        }
    }

    /// Full width, as the sheet's own primary action.
    private func primaryLabel(_ text: String) -> some View {
        Text(verbatim: text).frame(maxWidth: .infinity, minHeight: 44)
    }

    private var backButton: some View {
        Button(copy(ListingHireCopy.back)) { flow.reset() }
            .buttonStyle(AtumQuietButtonStyle(atum: atum, scheme: scheme))
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(hire.phase == .hiring)
            .accessibilityIdentifier("home.newAssistant.hire.back")
    }
}
