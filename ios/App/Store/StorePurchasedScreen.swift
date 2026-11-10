import AtumChat
import AtumDesign
import AtumNativeAPI
import SwiftUI

/// Purchased: unfinished writes first (each checked with its original key,
/// never a new purchase), then what the account owns, then the purchase
/// record. A failed inventory read is said plainly; it is never shown as an
/// empty list. Renewal cancellation stops renewal only: no uninstall, no refund.
struct StorePurchasedScreen: View {
    let design: LiveDesign
    let commerce: LiveStoreCommerce
    /// Title for an item ID from the current listing.
    let title: (String) -> String

    @State private var checkingKey: NativeID?
    @State private var confirmingCancel: StoreEntitlement?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var kit: AtumKit { design.kit }

    var body: some View {
        List {
            if let failure = readFailure {
                Section {
                    AtumNotice(glyph: .alertCircle, title: copy(failure), tone: .warning) {
                        Button(copy(StoreCopyKey.retry)) { Task { await commerce.refresh() } }
                            .buttonStyle(.atumSecondary)
                            .disabled(commerce.refreshing || commerce.busy)
                            .accessibilityIdentifier("store.purchased.retry")
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            if !commerce.unresolvedAttempts.isEmpty {
                Section {
                    ForEach(commerce.unresolvedAttempts, id: \.idempotencyKey) { attempt in
                        attemptRow(attempt)
                    }
                } header: { header(StoreCopyKey.deliveryTitle) }
            }
            if !commerce.entitlements.isEmpty {
                Section {
                    ForEach(entitlements) { entitlementRow($0) }
                } header: { header(StoreCopyKey.owned) }
            }
            if !commerce.purchases.isEmpty {
                Section {
                    ForEach(purchases) { purchaseRow($0) }
                } header: { header(StoreCopyKey.historyTitle) }
            }
            if isEmpty {
                Section {
                    Text(copy(StoreCopyKey.ownedEmpty))
                        .font(kit.font(.callout))
                        .foregroundStyle(kit.color(.ink3, scheme: scheme))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, kit.space(.s4))
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("store.purchased.empty")
                }
            }
            if commerce.readState == .loading && commerce.entitlements.isEmpty && commerce.purchases.isEmpty {
                Section {
                    AtomWait()
                        .frame(width: 24, height: 24)
                        .foregroundStyle(kit.color(.ink3, scheme: scheme))
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .accessibilityElement()
                        .accessibilityLabel(copy(StoreCopyKey.busy))
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(kit.color(.ground, scheme: scheme).ignoresSafeArea())
        .navigationTitle(copy(StoreCopyKey.purchasedTitle))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await commerce.refresh() }
        .task { if !commerce.busy { await commerce.refresh() } }
        .accessibilityIdentifier("store.purchased")
        .confirmationDialog(copy(StoreCopyKey.renewal), isPresented: cancelDialog,
                            titleVisibility: .visible, presenting: confirmingCancel) { entitlement in
            Button(copy(StoreCopyKey.confirm), role: .destructive) {
                Task { await commerce.cancel(entitlement) }
            }
            .accessibilityIdentifier("store.renewal.confirm")
            Button(copy(StoreCopyKey.back), role: .cancel) {}
        } message: { entitlement in
            Text(renewalMessage(entitlement))
        }
    }

    private var readFailure: String? {
        switch commerce.readState {
        case .offline: StoreCopyKey.offline
        case .forbidden: StoreCopyKey.denied
        case .unavailable where !commerce.refreshing: StoreCopyKey.storeUnavailable
        default: nil
        }
    }

    private var isEmpty: Bool {
        commerce.readState == .ready && commerce.unresolvedAttempts.isEmpty
            && commerce.entitlements.isEmpty && commerce.purchases.isEmpty
    }

    private var entitlements: [StoreEntitlement] {
        commerce.entitlements.sorted { $0.grantedAt.rawValue > $1.grantedAt.rawValue }
    }

    private var purchases: [StorePurchase] {
        commerce.purchases.sorted { $0.createdAt.rawValue > $1.createdAt.rawValue }
    }

    private var cancelDialog: Binding<Bool> {
        Binding(get: { confirmingCancel != nil }, set: { if !$0 { confirmingCancel = nil } })
    }

    // MARK: Rows

    private func attemptRow(_ attempt: StorePurchaseAttempt) -> some View {
        let mine = checkingKey == attempt.idempotencyKey
            && commerce.operationItemID == attempt.itemID
            && commerce.operationAssistantID == attempt.assistantID
        let working = mine && commerce.busy
        let pending = commerce.purchases.contains { attempt.matches($0) && $0.state == .deliveryPending }
        let notice = mine && !commerce.busy
            ? StoreOutcomePresentation.notice(for: commerce.state, kind: kind(attempt.itemID)) : nil
        return VStack(alignment: .leading, spacing: kit.space(.s2)) {
            rowTitle(attempt.itemID, assistant: attempt.assistantID)
            Text(copy(notice?.key ?? (pending ? StoreCopyKey.deliveryPending : StoreCopyKey.deliveryUncertain)))
                .font(kit.font(.callout))
                .foregroundStyle(kit.color(notice?.tone == .danger ? .danger : .ink2, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("store.purchased.attempt.status")
            Button {
                guard !commerce.busy else { return }
                checkingKey = attempt.idempotencyKey
                Task { await commerce.retry(attempt) }
            } label: {
                ZStack {
                    Text(copy(StoreCopyKey.checkStatus)).opacity(working ? 0 : 1)
                    if working { AtomWait().frame(width: 20, height: 20) }
                }
            }
            .buttonStyle(.atumSecondary)
            .disabled(commerce.busy || commerce.refreshing)
            .accessibilityLabel(copy(StoreCopyKey.checkStatus))
            .accessibilityValue(working ? copy(StoreCopyKey.busy) : "")
            .accessibilityIdentifier("store.purchased.check")
        }
        .padding(.vertical, kit.space(.s2))
        .listRowBackground(kit.color(.surface, scheme: scheme))
    }

    private func entitlementRow(_ entitlement: StoreEntitlement) -> some View {
        VStack(alignment: .leading, spacing: kit.space(.s2)) {
            rowTitle(entitlement.itemID, assistant: entitlement.assistantID)
            if let status = entitlementStatus(entitlement) {
                Text(status)
                    .font(kit.font(.callout))
                    .foregroundStyle(kit.color(.ink2, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let subscription = entitlement.subscription, subscription.state == .active,
               entitlement.isOwned {
                renewal(entitlement, subscription)
            }
        }
        .padding(.vertical, kit.space(.s2))
        .listRowBackground(kit.color(.surface, scheme: scheme))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("store.purchased.entitlement.\(entitlement.itemID)")
    }

    private func entitlementStatus(_ entitlement: StoreEntitlement) -> String? {
        if entitlement.state == .revoked || entitlement.subscription?.state == .lapsed {
            return copy(StoreCopyKey.purchasedRevoked)
        }
        if let subscription = entitlement.subscription, subscription.state == .cancelled {
            return [copy(StoreCopyKey.purchasedCancelledRenewal), day(subscription.renewAt)]
                .compactMap { $0 }.joined(separator: " ")
        }
        if commerce.purchases.contains(where: {
            $0.itemID == entitlement.itemID && $0.assistantID == entitlement.assistantID
                && $0.state == .deliveryPending
        }) {
            return copy(StoreCopyKey.deliveryPending)
        }
        return nil
    }

    @ViewBuilder
    private func renewal(_ entitlement: StoreEntitlement, _ subscription: StoreSubscription) -> some View {
        let state = cancellation(for: entitlement.id)
        HStack(alignment: .firstTextBaseline, spacing: kit.space(.s3)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(copy(StoreCopyKey.renewal))
                    .font(kit.font(.bodyStrong))
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                HStack(spacing: 4) {
                    if let day = day(subscription.renewAt) { Text(verbatim: day) }
                    StoreProtonsText(design: design, microProtons: subscription.priceMicroProtons,
                                     emphasis: false)
                }
                .font(kit.font(.callout))
                .foregroundStyle(kit.color(.ink3, scheme: scheme))
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
        }
        if let failure = state.failure {
            Text(copy(failure))
                .font(kit.font(.callout))
                .foregroundStyle(kit.color(.danger, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("store.renewal.failure")
        }
        if entitlement.canCancel {
            Button {
                confirmingCancel = entitlement
            } label: {
                ZStack {
                    // The export has no dedicated "Cancel renewal" label: the
                    // generic Cancel sits under the Renewal heading and the
                    // confirmation names Renewal again.
                    Text(copy(state.failure == nil ? StoreCopyKey.cancel : StoreCopyKey.retry))
                        .opacity(state.working ? 0 : 1)
                    if state.working { AtomWait().frame(width: 20, height: 20) }
                }
            }
            .buttonStyle(.atumDanger)
            .disabled(commerce.busy || commerce.refreshing || !commerce.ready)
            .accessibilityLabel([copy(StoreCopyKey.cancel), copy(StoreCopyKey.renewal)].joined(separator: ", "))
            .accessibilityValue(state.working ? copy(StoreCopyKey.busy) : "")
            .accessibilityIdentifier("store.renewal.cancel")
        }
    }

    private func purchaseRow(_ purchase: StorePurchase) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return VStack(alignment: .leading, spacing: kit.space(.s1)) {
            layout {
                rowTitle(purchase.itemID, assistant: purchase.assistantID)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                StoreProtonsText(design: design, microProtons: purchase.amountMicroProtons)
                    .font(kit.font(.bodyStrong))
            }
            HStack(spacing: 4) {
                if let day = day(purchase.createdAt) { Text(verbatim: day) }
                Text(copy(StoreOutcomePresentation.purchaseKey(purchase.state)))
            }
            .font(kit.font(.callout))
            .foregroundStyle(kit.color(.ink3, scheme: scheme))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, kit.space(.s1))
        .listRowBackground(kit.color(.surface, scheme: scheme))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("store.purchased.purchase.\(purchase.id.rawValue)")
    }

    private func rowTitle(_ itemID: String, assistant: NativeID?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: title(itemID))
                .font(kit.font(.bodyStrong))
                .foregroundStyle(kit.color(.ink, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
            if let assistant, let name = commerce.targets.first(where: { $0.id == assistant })?.name {
                Text(verbatim: name)
                    .font(kit.font(.callout))
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
            }
        }
    }

    private func header(_ key: String) -> some View {
        Text(copy(key))
            .font(kit.font(.caption).weight(.semibold))
            .foregroundStyle(kit.color(.ink3, scheme: scheme))
            .textCase(nil)
    }

    // MARK: Helpers

    private struct Cancellation {
        var working = false
        var failure: String?
    }

    private func cancellation(for id: NativeID) -> Cancellation {
        switch commerce.cancellationState {
        case .working(let value) where value == id: Cancellation(working: true)
        case .uncertain(let value) where value == id: Cancellation(failure: StoreCopyKey.genericError)
        case .forbidden(let value) where value == id: Cancellation(failure: StoreCopyKey.denied)
        default: Cancellation()
        }
    }

    private func renewalMessage(_ entitlement: StoreEntitlement) -> String {
        [copy(StoreCopyKey.purchasedCancelledRenewal), entitlement.subscription.flatMap { day($0.renewAt) }]
            .compactMap { $0 }.joined(separator: "\n")
    }

    private func kind(_ itemID: String) -> LiveProductStoreItemKind {
        itemID.hasPrefix("skill/") ? .skill : itemID.hasPrefix("pet/") ? .pet : .agent
    }

    private func day(_ timestamp: NativeTimestamp) -> String? {
        StoreOutcomePresentation.date(timestamp)?.formatted(date: .abbreviated, time: .omitted)
    }

    private func copy(_ key: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key, arguments: arguments)
    }
}
