import AtumDesign
import AtumNativeAPI
import SwiftUI

// MARK: - The one top-up entry

/// What every "Top up" on the phone opens (lane 4 §2.5a): the Proton pack
/// sheet over the app's single `ApplePurchaseCoordinator`. Installed once at
/// the app root with `.environment(\.protonTopUp, …)`; a view without it (a
/// scripted host, a preview) shows no top-up entry at all.
@MainActor final class ProtonTopUpContext {
    let purchases: ApplePurchaseCoordinator
    /// The account's fresh spendable balance in micro-Protons, or nil when no
    /// fresh read exists. Read inside `body`, so Observation tracks it.
    let balance: @MainActor () -> Int64?

    init(purchases: ApplePurchaseCoordinator, balance: @escaping @MainActor () -> Int64?) {
        self.purchases = purchases
        self.balance = balance
    }
}

extension EnvironmentValues {
    @Entry var protonTopUp: ProtonTopUpContext? = nil
}

/// Hosts the pack sheet on a view that outlives the entry that opened it.
/// Use it where the entry itself goes away once Protons arrive (the item
/// sheet's short-of-Protons action, the chat's out-of-Protons notice):
/// otherwise the credit would dismiss the sheet before Done/Continue shows.
struct ProtonTopUpSheetHost: ViewModifier {
    let design: LiveDesign
    @Binding var isPresented: Bool
    var finish: ProtonTopUpSheet.Finish = .done
    var onFinished: (() -> Void)? = nil
    @Environment(\.protonTopUp) private var context

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            if let context {
                ProtonTopUpSheet(design: design, context: context, finish: finish, onFinished: onFinished)
            }
        }
    }
}

extension View {
    func protonTopUpSheet(design: LiveDesign, isPresented: Binding<Bool>,
                          finish: ProtonTopUpSheet.Finish = .done,
                          onFinished: (() -> Void)? = nil) -> some View {
        modifier(ProtonTopUpSheetHost(design: design, isPresented: isPresented, finish: finish,
                                      onFinished: onFinished))
    }
}

/// The reusable "present top-up" entry. Its content receives `present`; the
/// entry owns the sheet, so it works from any presentation layer (the Store
/// tab, Settings). Where the entry disappears once the balance changes, host
/// the sheet with `protonTopUpSheet` instead. Without a context it draws nothing.
struct ProtonTopUpEntry<Content: View>: View {
    let design: LiveDesign
    var finish: ProtonTopUpSheet.Finish = .done
    /// After a credited purchase, when the person presses Done or Continue.
    var onFinished: (() -> Void)? = nil
    @ViewBuilder let content: (_ present: @escaping () -> Void) -> Content

    @Environment(\.protonTopUp) private var context
    @State private var presented = false

    var body: some View {
        if let context {
            content { presented = true }
                .sheet(isPresented: $presented) {
                    ProtonTopUpSheet(design: design, context: context, finish: finish,
                                     onFinished: onFinished)
                }
        }
    }
}

/// The standard "Top up Protons" button. With `present`, it only asks a host
/// (`protonTopUpSheet`) to show the sheet; without, it owns the sheet.
struct ProtonTopUpButton: View {
    let design: LiveDesign
    var style: AtumKitButtonStyle = .atumSecondary
    var fullWidth = false
    var finish: ProtonTopUpSheet.Finish = .done
    var onFinished: (() -> Void)? = nil
    var present: (() -> Void)? = nil
    @Environment(\.protonTopUp) private var context

    var body: some View {
        if let present {
            if context != nil { button(present) }
        } else {
            ProtonTopUpEntry(design: design, finish: finish, onFinished: onFinished) { present in
                button(present)
            }
        }
    }

    private func button(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(design.text(ProtonTopUpCopyKey.topUp))
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(style)
        .accessibilityIdentifier("topup.entry")
    }
}

/// Chat (lane 4 W7): an assistant chat on an empty wallet says so above the
/// composer and offers the same top-up. The phone has no turn-level
/// out-of-Protons signal yet, so this reads the account's fresh balance:
/// shown only below one whole Proton, never on a stale or missing read.
struct ProtonTopUpChatNotice: View {
    let design: LiveDesign
    @Environment(\.protonTopUp) private var context
    @State private var presented = false

    var body: some View {
        // The container stays when the notice goes (Protons arrived), so the
        // sheet it hosts can still show its Done.
        VStack(spacing: 0) {
            if let context, let balance = context.balance(), ProtonTopUpPresentation.isOut(balance) {
                AtumNotice(glyph: .info, title: design.text(ProtonTopUpCopyKey.outOfProtons)) {
                    ProtonTopUpButton(design: design, present: { presented = true })
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .accessibilityIdentifier("chat.protons.out")
            }
        }
        .protonTopUpSheet(design: design, isPresented: $presented)
    }
}

// MARK: - Copy and states

/// Every word on the pack sheet and its entries: existing exports only.
enum ProtonTopUpCopyKey {
    private static let phone = "src.matrix.mobile-copy.mobilePhoneCopy."
    private static let device = "src.matrix.mobile-device-copy.mobileDeviceCopy."

    static let title = phone + "purchaseTitle"
    static let balanceLabel = "src.matrix.mobile-copy.mobileScreensCopy.store.balanceLabel"
    static let packLabel = phone + "productPrice"
    static let buy = "desktop.atum.protons.checkout.buy"
    static let pending = phone + "purchasePending"
    static let cancelled = phone + "purchaseCancelled"
    static let creditPending = phone + "purchaseCreditPending"
    static let complete = phone + "purchaseComplete"
    static let help = phone + "purchaseHelp"
    static let restore = phone + "restorePurchases"
    static let restoreBody = device + "recoverBalanceBody"
    static let closedTitle = phone + "noPurchasesTitle"
    static let closedHelp = phone + "noPurchasesHelp"
    static let otherAccount = device + "walletStatesOtherAccountText"
    static let refunded = device + "walletStatesRefundedText"
    static let outOfProtons = phone + "outOfProtons"
    static let topUp = "desktop.atum.discover.topUp"
    static let protons = "desktop.atum.discover.protons"
    static let failed = "src.matrix.chat-copy.copies.errorGeneric"
    static let retry = "src.matrix.chat-copy.copies.retry"
    static let loading = "desktop.common.loading"
    static let close = "desktop.common.close"
    static let done = "desktop.common.done"
    static let continueToItem = "desktop.common.continue"

    static let all: [String] = [
        title, balanceLabel, packLabel, buy, pending, cancelled, creditPending, complete, help,
        restore, restoreBody, closedTitle, closedHelp, otherAccount, refunded, outOfProtons, topUp,
        protons, failed, retry, loading, close, done, continueToItem,
    ]
}

/// The pack sheet's meaning, apart from SwiftUI so each state is tested.
enum ProtonTopUpPresentation {
    enum Body: Equatable { case loading, packs, closed, unavailable }

    /// Pack rows whenever StoreKit priced any; otherwise the catalogue state.
    static func body(state: ApplePurchaseCoordinator.State, hasRows: Bool) -> Body {
        if hasRows { return .packs }
        switch state {
        case .idle, .loading: return .loading
        case .closed, .sandboxCapExceeded: return .closed
        default: return .unavailable
        }
    }

    /// A paused or closed checkout above rows that stay visible but can't be bought.
    static func showsClosedBanner(checkoutOpen: Bool, hasRows: Bool) -> Bool { hasRows && !checkoutOpen }

    /// One pack's latest outcome, worded from the export.
    static func notice(for state: ApplePurchaseCoordinator.State) -> StoreNotice? {
        switch state {
        case .idle, .loading, .ready, .purchasing: nil
        case .pending: .init(key: ProtonTopUpCopyKey.pending, tone: .neutral)
        case .cancelled: .init(key: ProtonTopUpCopyKey.cancelled, tone: .neutral)
        case .retrying: .init(key: ProtonTopUpCopyKey.creditPending, tone: .neutral)
        case .succeeded: .init(key: ProtonTopUpCopyKey.complete, tone: .done)
        // PENDING-COPY:src.matrix.mobile-device-copy.mobileDeviceCopy.walletStatesNeedsSupportText
        // Until the export has the needs-support line, the payment-received
        // wording stands in and the sheet shows the transaction ID beside it.
        case .needsSupport: .init(key: ProtonTopUpCopyKey.creditPending, tone: .warning)
        case .otherAccount: .init(key: ProtonTopUpCopyKey.otherAccount, tone: .warning)
        case .revoked: .init(key: ProtonTopUpCopyKey.refunded, tone: .neutral)
        case .unavailable: .init(key: ProtonTopUpCopyKey.failed, tone: .danger)
        // PENDING-COPY: a dedicated "checkout paused" line (lane 4 D-3).
        case .closed, .sandboxCapExceeded: .init(key: ProtonTopUpCopyKey.closedTitle, tone: .warning)
        }
    }

    /// Done (or Continue) appears once a pack was credited in this sheet.
    static func finished(_ states: [String: ApplePurchaseCoordinator.State]) -> Bool {
        states.values.contains(.succeeded)
    }

    /// Below one whole Proton: the wallet floors to zero, as desktop shows it.
    static func isOut(_ balance: Int64) -> Bool { balance < 1_000_000 }
}

// MARK: - The pack sheet

/// Buy Protons (lane 4 §2.5a, App Store Connect review screenshot): the
/// balance once, then each pack's total Protons and StoreKit's price with a
/// Buy button. Never a paid/bonus split, a saving or a rate (owner ruling 1);
/// never another way to pay (ruling 5). Crediting stays on the server.
struct ProtonTopUpSheet: View {
    enum Finish: Sendable { case done, continueToItem }

    let design: LiveDesign
    let context: ProtonTopUpContext
    var finish: Finish = .done
    var onFinished: (() -> Void)? = nil

    @ObservedObject private var purchases: ApplePurchaseCoordinator
    @State private var restoring = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    init(design: LiveDesign, context: ProtonTopUpContext, finish: Finish = .done,
         onFinished: (() -> Void)? = nil) {
        self.design = design
        self.context = context
        self.finish = finish
        self.onFinished = onFinished
        _purchases = ObservedObject(wrappedValue: context.purchases)
    }

    private var kit: AtumKit { design.kit }
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var rows: [AppleProtonPackRow] { purchases.packRows }
    private var purchasing: Bool { purchases.purchaseStates.values.contains(.purchasing) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: kit.space(.s5)) {
                    if let balance = context.balance() { balanceRow(balance) }
                    content
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.top, kit.space(.s2))
                .padding(.bottom, kit.space(.s6))
            }
            .accessibilityIdentifier("topup.sheet")
            .scrollBounceBehavior(.basedOnSize)
            .background(kit.color(.ground, scheme: scheme).ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { finishBar }
            .navigationTitle(copy(ProtonTopUpCopyKey.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { atum.barIcon(.close) }
                        .accessibilityLabel(copy(ProtonTopUpCopyKey.close))
                        .disabled(purchasing)
                        .accessibilityIdentifier("topup.close")
                }
            }
        }
        .atumDesign(design)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(purchasing)
        .task {
            purchases.clearSettledOutcomes()
            if purchases.state == .unavailable { await purchases.load() }
        }
        .onDisappear { purchases.clearSettledOutcomes() }
    }

    // MARK: Balance

    private func balanceRow(_ balance: Int64) -> some View {
        let value = MicroProtonFormat.balance(balance, locale: Locale.current.identifier)
        return StoreValueRow(design: design, label: copy(ProtonTopUpCopyKey.balanceLabel)) {
            HStack(spacing: 3) {
                ProtonMark(.small)
                Text(verbatim: value).monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(copy(ProtonTopUpCopyKey.protons, [.text(value)]))
        }
        .background(kit.color(.surface, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: kit.radius(.xl), style: .continuous))
        .accessibilityIdentifier("topup.balance")
    }

    // MARK: Packs and states

    @ViewBuilder private var content: some View {
        switch ProtonTopUpPresentation.body(state: purchases.state, hasRows: !rows.isEmpty) {
        case .packs:
            if ProtonTopUpPresentation.showsClosedBanner(checkoutOpen: purchases.checkoutOpen,
                                                        hasRows: !rows.isEmpty) {
                closedNotice
            }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider().overlay(kit.color(.line, scheme: scheme)).padding(.leading, 14)
                    }
                    packRow(row)
                }
            }
            .background(kit.color(.surface, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: kit.radius(.xl), style: .continuous))
        case .loading:
            AtomWait()
                .frame(width: 24, height: 24)
                .foregroundStyle(kit.color(.ink3, scheme: scheme))
                .frame(maxWidth: .infinity, minHeight: 96)
                .accessibilityElement()
                .accessibilityLabel(copy(ProtonTopUpCopyKey.loading))
                .accessibilityIdentifier("topup.loading")
        case .closed:
            closedNotice
        case .unavailable:
            AtumNotice(glyph: .alertCircle, title: copy(ProtonTopUpCopyKey.closedTitle), tone: .warning) {
                Button(copy(ProtonTopUpCopyKey.retry)) { Task { await purchases.load() } }
                    .buttonStyle(.atumSecondary)
                    .accessibilityIdentifier("topup.retry")
            }
            .accessibilityIdentifier("topup.unavailable")
        }
    }

    private var closedNotice: some View {
        AtumNotice(glyph: .info, title: copy(ProtonTopUpCopyKey.closedTitle),
                   message: copy(ProtonTopUpCopyKey.closedHelp))
            .accessibilityIdentifier("topup.closed")
    }

    private func packRow(_ row: AppleProtonPackRow) -> some View {
        let total = MicroProtonFormat.balance(row.totalMicroProtons, locale: Locale.current.identifier)
        let label = copy(ProtonTopUpCopyKey.packLabel, [.text(total), .text(row.displayPrice)])
        let state = purchases.purchaseState(for: row.id)
        let working = state == .purchasing
        return VStack(alignment: .leading, spacing: kit.space(.s2)) {
            HStack(alignment: .center, spacing: kit.space(.s3)) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        ProtonMark(.regular)
                        Text(verbatim: total)
                            .font(kit.font(.title))
                            .monospacedDigit()
                    }
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                    Text(verbatim: row.displayPrice)
                        .font(kit.font(.callout))
                        .foregroundStyle(kit.color(.ink2, scheme: scheme))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                // On the info element only: on the row it would replace Buy's.
                .accessibilityIdentifier("topup.pack.\(row.id)")
                Spacer(minLength: kit.space(.s3))
                Button {
                    Task { await purchases.purchase(row.id) }
                } label: {
                    ZStack {
                        Text(copy(ProtonTopUpCopyKey.buy)).opacity(working ? 0 : 1)
                        if working { AtomWait().frame(width: 18, height: 18) }
                    }
                }
                .buttonStyle(AtumKitButtonStyle(kind: .primary, height: .regular))
                .disabled(!purchases.canPurchase || working)
                .accessibilityLabel([copy(ProtonTopUpCopyKey.buy), label].joined(separator: ", "))
                .accessibilityValue(working ? copy(ProtonTopUpCopyKey.loading) : "")
                .accessibilityIdentifier("topup.buy.\(row.id)")
            }
            if let notice = ProtonTopUpPresentation.notice(for: state) {
                VStack(alignment: .leading, spacing: 2) {
                    AtumNotice(glyph: notice.tone.glyph, title: copy(notice.key), tone: notice.tone.kitTone)
                    if case let .needsSupport(transactionID) = state {
                        Text(verbatim: transactionID)
                            .font(kit.font(.caption))
                            .monospacedDigit()
                            .foregroundStyle(kit.color(.ink3, scheme: scheme))
                            .textSelection(.enabled)
                            .padding(.leading, 14)
                    }
                }
                .accessibilityIdentifier("topup.state.\(row.id)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .onChange(of: state, initial: false) { _, value in
            guard let notice = ProtonTopUpPresentation.notice(for: value) else { return }
            AccessibilityNotification.Announcement(copy(notice.key)).post()
        }
    }

    // MARK: Footer and finish

    private var footer: some View {
        VStack(alignment: .leading, spacing: kit.space(.s2)) {
            Text(copy(ProtonTopUpCopyKey.help))
                .font(kit.font(.caption))
                .foregroundStyle(kit.color(.ink3, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                guard !restoring else { return }
                restoring = true
                Task {
                    await purchases.restore()
                    restoring = false
                }
            } label: {
                ZStack(alignment: .leading) {
                    Text(copy(ProtonTopUpCopyKey.restore)).opacity(restoring ? 0 : 1)
                    if restoring { AtomWait().frame(width: 16, height: 16) }
                }
            }
            .buttonStyle(.plain)
            .font(kit.font(.callout).weight(.semibold))
            .foregroundStyle(kit.color(.ink, scheme: scheme))
            .disabled(restoring || purchasing)
            .accessibilityLabel(copy(ProtonTopUpCopyKey.restore))
            .accessibilityHint(copy(ProtonTopUpCopyKey.restoreBody))
            .accessibilityValue(restoring ? copy(ProtonTopUpCopyKey.loading) : "")
            .accessibilityIdentifier("topup.restore")
        }
    }

    @ViewBuilder private var finishBar: some View {
        if ProtonTopUpPresentation.finished(purchases.purchaseStates) {
            Button {
                dismiss()
                onFinished?()
            } label: {
                Text(copy(finish == .done ? ProtonTopUpCopyKey.done : ProtonTopUpCopyKey.continueToItem))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.atumPrimary)
            .accessibilityIdentifier("topup.finish")
            .padding(.horizontal, 20)
            .padding(.top, kit.space(.s3))
            .padding(.bottom, kit.space(.s2))
            .frame(maxWidth: .infinity)
            .background(kit.color(.ground, scheme: scheme).ignoresSafeArea())
        }
    }

    private func copy(_ key: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key, arguments: arguments)
    }
}
