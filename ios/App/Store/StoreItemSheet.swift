import AtumChat
import AtumDesign
import AtumNativeAPI
import SwiftUI

/// One Store item (FlowStore-2 / FlowPhone3 › Store item): what it is, its
/// price in Protons, owned or pending state, the recipient for a skill, and a
/// separate review step before any Protons move. An action appears only when
/// `LiveStoreCommerce` reports it possible. Short of Protons, the action is the
/// in-app Proton top-up (Apple IAP only, App Review 3.1.1), which returns here
/// with Continue (desktop `store-detail.tsx:372-420, 611-614`).
struct StoreItemSheet: View {
    let design: LiveDesign
    let item: LiveProductStoreItem
    let commerce: LiveStoreCommerce?
    let openRoom: (String) -> Void

    @State private var chosenAssistant: NativeID?
    @State private var quote: StoreAcquireQuote?
    @State private var reviewing = false
    /// Check status from the sheet: its outcome is this sheet's to show.
    @State private var checking = false
    /// Hosted here, not on the short-of-Protons button: the credit turns that
    /// button into Get, which would otherwise dismiss the sheet mid-flow.
    @State private var showsTopUp = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    private var kit: AtumKit { design.kit }
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        NavigationStack {
            detail
                .navigationDestination(isPresented: $reviewing) {
                    if let commerce, let quote {
                        StoreReviewView(design: design, item: item, commerce: commerce,
                                        quote: quote, recipient: recipientName(quote.assistantID),
                                        roomID: roomID(quote.assistantID), openRoom: open,
                                        finish: { dismiss() })
                    }
                }
        }
        .atumDesign(design)
        .protonTopUpSheet(design: design, isPresented: $showsTopUp, finish: .continueToItem,
                          onFinished: { Task { await commerce?.refresh() } })
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(commerce?.busy == true)
        .task {
            // A quote needs this moment's catalog, inventory and wallet.
            guard let commerce, !commerce.busy else { return }
            await commerce.refresh()
        }
    }

    // MARK: Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if !item.detailDescription.isEmpty {
                    Text(verbatim: item.detailDescription)
                        .font(kit.font(.body))
                        .foregroundStyle(kit.color(.ink, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, kit.space(.s5))
                        .accessibilityIdentifier("store.detail.description")
                }
                if !requirementKeys.isEmpty {
                    requirements.padding(.top, kit.space(.s5))
                }
                if !item.tryPrompt.isEmpty {
                    Text(copy(StoreCopyKey.tryExample, [.text(item.tryPrompt)]))
                        .font(kit.font(.callout))
                        .foregroundStyle(kit.color(.ink2, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, kit.space(.s3))
                        .background(kit.color(.fillQuiet, scheme: scheme),
                                    in: RoundedRectangle(cornerRadius: kit.radius(.lg), style: .continuous))
                        .padding(.top, kit.space(.s5))
                }
                if showsRecipients { recipients.padding(.top, kit.space(.s6)) }
                if let offer = item.offer, phase.showsPrice { priceRows(offer).padding(.top, kit.space(.s6)) }
                if let notice = phaseNotice {
                    noticeView(notice).padding(.top, kit.space(.s5))
                        .accessibilityIdentifier("store.detail.status")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, kit.space(.s2))
            .padding(.bottom, kit.space(.s6))
        }
        // On the scroll view itself: an identifier after `safeAreaInset`
        // would also replace the action bar buttons' identifiers.
        .accessibilityIdentifier("store.sheet")
        .scrollBounceBehavior(.basedOnSize)
        .background(kit.color(.ground, scheme: scheme).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { actionBar }
        .navigationTitle(copy(StoreCopyKey.detailTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { atum.barIcon(.close) }
                    .accessibilityLabel(copy(StoreCopyKey.close))
                    .disabled(commerce?.busy == true)
                    .accessibilityIdentifier("store.sheet.close")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: kit.space(.s4)) {
            StoreItemArt(item: item, base: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .font(kit.font(.title))
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if !item.summary.isEmpty {
                    Text(verbatim: item.summary)
                        .font(kit.font(.callout))
                        .foregroundStyle(kit.color(.ink3, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, kit.space(.s2))
    }

    // MARK: What it uses

    private var requirementKeys: [String] { StoreRequirementPresentation.keys(for: item.needs) }

    /// Desktop "What it uses" (`store-detail.tsx:177-187`): one check row per
    /// requirement the export names.
    private var requirements: some View {
        // PENDING-COPY: the "What it uses" heading (store-copy.ts `whatItUses`)
        // is not exported; the rows stand alone until it is.
        VStack(alignment: .leading, spacing: kit.space(.s2)) {
            ForEach(requirementKeys, id: \.self) { key in
                HStack(spacing: 10) {
                    Image(atum.symbol(.check))
                        .font(kit.font(.callout))
                        .foregroundStyle(kit.color(.ink2, scheme: scheme))
                        .accessibilityHidden(true)
                    Text(copy(key))
                        .font(kit.font(.body))
                        .foregroundStyle(kit.color(.ink, scheme: scheme))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("store.detail.requirements")
    }

    // MARK: Recipient

    private var perAssistant: Bool { item.kind == .skill && item.offer?.scope == .agent }

    private var showsRecipients: Bool {
        guard perAssistant, let commerce, commerce.readState == .ready else { return false }
        return !eligible.isEmpty
    }

    private var eligible: [LiveStoreCommerce.Target] {
        guard let commerce else { return [] }
        return commerce.targets.filter { commerce.paidTargets.contains($0.id) }
    }

    /// The chosen assistant, else the first eligible one without the skill.
    /// Never silently swapped during a purchase: the review holds its own quote.
    private var assistant: NativeID? {
        guard perAssistant else { return nil }
        if let chosenAssistant, eligible.contains(where: { $0.id == chosenAssistant }) { return chosenAssistant }
        return (eligible.first { !ownedFor($0.id) } ?? eligible.first)?.id
    }

    private var recipients: some View {
        VStack(alignment: .leading, spacing: kit.space(.s2)) {
            Text(copy(StoreCopyKey.recipientTitle))
                .font(kit.font(.headline))
                .foregroundStyle(kit.color(.ink, scheme: scheme))
                .accessibilityAddTraits(.isHeader)
            Text(copy(StoreCopyKey.recipientBody))
                .font(kit.font(.callout))
                .foregroundStyle(kit.color(.ink3, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(eligible.enumerated()), id: \.element.id) { index, target in
                    if index > 0 { Divider().overlay(kit.color(.line, scheme: scheme)).padding(.leading, 52) }
                    recipientRow(target)
                }
            }
            .background(kit.color(.surface, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: kit.radius(.xl), style: .continuous))
            .padding(.top, kit.space(.s1))
        }
    }

    private func recipientRow(_ target: LiveStoreCommerce.Target) -> some View {
        let selected = assistant == target.id
        let owned = ownedFor(target.id)
        return Button {
            chosenAssistant = target.id
        } label: {
            HStack(spacing: kit.space(.s3)) {
                AtumAvatar(kind: .assistant, name: target.name, size: 28)
                Text(verbatim: target.name)
                    .font(kit.font(.body))
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if owned {
                    Text(copy(StoreCopyKey.owned))
                        .font(kit.font(.callout))
                        .foregroundStyle(kit.color(.ink3, scheme: scheme))
                }
                Image(atum.symbol(.check))
                    .font(kit.font(.bodyStrong))
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(commerce?.busy == true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(owned ? [target.name, copy(StoreCopyKey.owned)].joined(separator: ", ") : target.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("store.recipient.\(target.id.rawValue)")
    }

    // MARK: Price

    private func priceRows(_ offer: StoreCatalogOffer) -> some View {
        VStack(spacing: 0) {
            StoreValueRow(design: design, label: copy(StoreCopyKey.reviewPrice)) {
                if offer.billingInterval == .month {
                    Text(verbatim: StorePricePresentation.text(offer, design: design))
                        .monospacedDigit()
                } else {
                    StoreProtonsText(design: design, microProtons: offer.priceMicroProtons)
                }
            }
            if let balance = freshBalance, phase.showsBalance {
                Divider().overlay(kit.color(.line, scheme: scheme)).padding(.leading, 14)
                StoreValueRow(design: design, label: copy(StoreCopyKey.walletLabel)) {
                    StoreProtonsText(design: design, microProtons: balance, emphasis: false, isBalance: true)
                }
                .accessibilityIdentifier("store.detail.balance")
            }
        }
        .background(kit.color(.surface, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: kit.radius(.xl), style: .continuous))
    }

    /// Displayed only from this refresh: a saved balance never sits beside a price.
    private var freshBalance: Int64? {
        guard let commerce, commerce.ready else { return nil }
        return commerce.wallet?.balances.available
    }

    // MARK: Phase

    fileprivate enum Phase {
        /// Shown for what it is: no native action (no offer, a hire, a Hub skill).
        case info
        case loading
        case readFailed(LiveStoreCommerce.ReadState)
        case owned
        case pending
        case unresolved(StorePurchaseAttempt)
        case notForSale
        case blocked(LiveStoreCommerce.ReviewFailure)
        case ready(StoreAcquireQuote)

        var showsPrice: Bool {
            switch self {
            case .owned, .pending: false
            default: true
            }
        }

        var showsBalance: Bool {
            switch self {
            case .ready: true
            case .blocked(let failure): failure == .insufficientBalance
            default: false
            }
        }
    }

    private var catalogItem: StoreCatalogItem? {
        commerce?.catalog.first { $0.itemID == item.id }
    }

    private func ownedFor(_ assistant: NativeID?) -> Bool {
        // The folded Hatch card carries the regular card's ownership.
        if item.kind != .skill, item.ownership?.state == .owned { return true }
        guard let commerce, let catalogItem else { return false }
        if commerce.owned(catalogItem, assistant: assistant) { return true }
        // A held credit for the other Hatch item counts too.
        return commerce.catalog
            .filter { StoreShelfPlan.itemIDs(for: item.id).contains($0.itemID) && $0.itemID != catalogItem.itemID }
            .contains { commerce.owned($0, assistant: assistant) }
    }

    private var phase: Phase {
        guard let commerce else { return ownedFor(nil) ? .owned : .info }
        if ownedFor(assistant) && (!perAssistant || assistant != nil) { return .owned }
        if commerce.purchases.contains(where: {
            $0.itemID == item.id && $0.assistantID == assistant && $0.state == .deliveryPending
        }) { return .pending }
        if let attempt = commerce.unresolvedAttempts.first(where: {
            $0.itemID == item.id && $0.assistantID == assistant
        }) { return .unresolved(attempt) }
        guard let offer = item.offer, item.kind != .agent, item.install == nil,
              offer.billingInterval == .oneTime else { return .info }
        if item.deliverable == false { return .notForSale }
        switch commerce.readState {
        case .loading: return .loading
        case .offline, .forbidden: return .readFailed(commerce.readState)
        case .unavailable:
            // Not configured for this session: no client, so no action at all.
            guard commerce.journalReady else { return commerce.refreshing ? .loading : .info }
            return commerce.refreshing ? .loading : .readFailed(.unavailable)
        case .ready: break
        }
        if commerce.busy || commerce.refreshing || !commerce.ready { return .loading }
        if perAssistant && assistant == nil { return .blocked(.noEligibleAssistant) }
        do {
            return .ready(try commerce.review(itemID: item.id, assistant: assistant))
        } catch let failure as LiveStoreCommerce.ReviewFailure {
            return .blocked(failure)
        } catch {
            return .blocked(.unavailable)
        }
    }

    private var phaseNotice: StoreNotice? {
        if checking, let commerce, let notice = StoreOutcomePresentation.notice(for: commerce.state, kind: item.kind),
           commerce.operationItemID == item.id {
            return notice
        }
        switch phase {
        case .info:
            return item.offer == nil && item.install == nil && item.kind != .agent
                ? .init(key: StoreCopyKey.detailNoOffer, tone: .neutral) : nil
        case .loading, .ready: return nil
        case .readFailed(let state):
            switch state {
            case .offline: return .init(key: StoreCopyKey.offline, tone: .warning)
            case .forbidden: return .init(key: StoreCopyKey.denied, tone: .danger)
            default: return .init(key: StoreCopyKey.storeUnavailable, tone: .warning)
            }
        case .owned:
            return .init(key: perAssistant ? StoreCopyKey.recipientOwned : StoreCopyKey.owned, tone: .done)
        case .pending: return .init(key: StoreCopyKey.detailPending, tone: .neutral)
        case .unresolved: return .init(key: StoreCopyKey.deliveryUncertain, tone: .warning)
        case .notForSale: return .init(key: StoreCopyKey.notForSale, tone: .neutral)
        case .blocked(let failure):
            return StoreOutcomePresentation.notice(for: failure, kind: item.kind,
                                                   hasEligibleAssistant: !eligible.isEmpty)
        }
    }

    // MARK: Actions

    @ViewBuilder private var actionBar: some View {
        let content = actionContent
        if let content {
            VStack(spacing: kit.space(.s2)) { content }
                .padding(.horizontal, 20)
                .padding(.top, kit.space(.s3))
                .padding(.bottom, kit.space(.s2))
                .frame(maxWidth: .infinity)
                .background(kit.color(.ground, scheme: scheme).ignoresSafeArea())
        }
    }

    private var actionContent: AnyView? {
        switch phase {
        case .ready(let value):
            let amount = StoreOutcomePresentation.protons(value.price, locale: design.locale)
            return AnyView(
                Button {
                    quote = value
                    reviewing = true
                } label: {
                    StoreGetLabel(design: design, amount: value.price == 0 ? nil : amount)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.atumPrimary)
                .accessibilityLabel(value.price == 0 ? copy(StoreShelfCopyKey.get)
                    : copy(StoreShelfCopyKey.getWithPrice, [.text(copy(StoreCopyKey.protons, [.text(amount)]))]))
                .accessibilityIdentifier("store.detail.acquire")
            )
        case .blocked(.insufficientBalance):
            guard commerce != nil else { return nil }
            return AnyView(
                ProtonTopUpButton(design: design, style: .atumPrimary, fullWidth: true,
                                  present: { showsTopUp = true })
            )
        case .owned:
            guard let roomID = roomID(assistant) else { return nil }
            return AnyView(
                Button(copy(StoreCopyKey.open)) { open(roomID) }
                    .buttonStyle(.atumSecondary)
                    .accessibilityIdentifier("store.detail.open")
            )
        case .unresolved(let attempt):
            return AnyView(checkStatusButton(attempt))
        case .readFailed:
            guard let commerce else { return nil }
            return AnyView(
                Button(copy(StoreCopyKey.retry)) { Task { await commerce.refresh() } }
                    .buttonStyle(.atumSecondary)
                    .accessibilityIdentifier("store.detail.retry")
            )
        case .loading:
            return AnyView(
                AtomWait()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
                    .frame(minHeight: kit.phoneControlHeight(.primary))
                    .accessibilityElement()
                    .accessibilityLabel(copy(StoreCopyKey.loading))
                    .accessibilityIdentifier("store.detail.loading")
            )
        case .info, .pending, .notForSale, .blocked:
            return nil
        }
    }

    private func checkStatusButton(_ attempt: StorePurchaseAttempt) -> some View {
        let working = commerce?.busy == true
        return Button {
            guard let commerce, !commerce.busy else { return }
            checking = true
            Task { await commerce.retry(attempt) }
        } label: {
            ZStack {
                Text(copy(StoreCopyKey.checkStatus)).opacity(working ? 0 : 1)
                if working { AtomWait().frame(width: 20, height: 20) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.atumPrimary)
        .disabled(working)
        .accessibilityLabel(copy(StoreCopyKey.checkStatus))
        .accessibilityValue(working ? copy(StoreCopyKey.busy) : "")
        .accessibilityIdentifier("store.detail.check")
    }

    // MARK: Helpers

    private func noticeView(_ notice: StoreNotice) -> some View {
        AtumNotice(glyph: notice.tone.glyph, title: copy(notice.key), tone: notice.tone.kitTone)
    }

    private func recipientName(_ id: NativeID?) -> String? {
        guard let id else { return nil }
        return commerce?.targets.first { $0.id == id }?.name
    }

    private func roomID(_ id: NativeID?) -> String? {
        guard item.kind == .skill, let id else { return nil }
        return commerce?.targets.first { $0.id == id }?.roomID
    }

    private func open(_ roomID: String) {
        dismiss()
        openRoom(roomID)
    }

    private func copy(_ key: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key, arguments: arguments)
    }
}

// MARK: - Review and confirm

/// The explicit confirmation: the immutable quote's item, recipient, price and
/// balance before and after. Confirm is single-flight; while it works the page
/// cannot be left. An unanswered write offers only Check status (same key).
private struct StoreReviewView: View {
    let design: LiveDesign
    let item: LiveProductStoreItem
    let commerce: LiveStoreCommerce
    @State var quote: StoreAcquireQuote
    let recipient: String?
    let roomID: String?
    let openRoom: (String) -> Void
    let finish: () -> Void

    /// This page sent the current operation; `commerce.state` is its outcome.
    @State private var submitted = false
    @State private var requoted = false
    /// The changed offer could not be quoted again (for example, it now costs
    /// more than the balance): say why and offer only Close.
    @State private var requoteFailure: LiveStoreCommerce.ReviewFailure?
    @Environment(\.dismiss) private var pop
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kit: AtumKit { design.kit }
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    private var state: StoreAcquireState? {
        guard submitted, commerce.operationItemID == item.id,
              commerce.operationAssistantID == quote.assistantID else { return nil }
        return commerce.state
    }

    private var working: Bool { commerce.busy || state == .working }

    /// The write was refused for want of Protons (locally or by the server).
    private var short: Bool {
        if requoteFailure == .insufficientBalance { return true }
        switch state {
        case .insufficientBalance?, .result(.refused(.insufficientProtons))?: return true
        default: return false
        }
    }

    private var outcome: StoreOutcome? {
        guard let state, !commerce.busy else { return nil }
        return StoreOutcomePresentation.outcome(
            for: state,
            hasSavedAttempt: commerce.attempt(itemID: item.id, assistant: quote.assistantID) != nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: kit.space(.s5)) {
                Text(design.text(StoreCopyKey.reviewBody))
                    .font(kit.font(.callout))
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                rows
                if let notice {
                    AtumNotice(glyph: notice.tone.glyph, title: design.text(notice.key),
                               tone: notice.tone.kitTone)
                        .accessibilityIdentifier("store.review.outcome")
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, kit.space(.s2))
            .padding(.bottom, kit.space(.s6))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: notice)
        }
        .accessibilityIdentifier("store.review")
        .scrollBounceBehavior(.basedOnSize)
        .background(kit.color(.ground, scheme: scheme).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { actions }
        .navigationTitle(design.text(StoreCopyKey.reviewTitle))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(working || outcome != nil && outcome != .requote)
        .onChange(of: outcome) { _, value in
            guard value == .requote else { return }
            // The server's new offer is shown and must be confirmed again.
            do {
                quote = try commerce.review(itemID: item.id, assistant: quote.assistantID)
                requoted = true
                submitted = false
            } catch {
                requoteFailure = (error as? LiveStoreCommerce.ReviewFailure) ?? .unavailable
            }
        }
        .onChange(of: notice?.key) { _, key in
            guard let key else { return }
            AccessibilityNotification.Announcement(design.text(key)).post()
        }
    }

    private var notice: StoreNotice? {
        if let requoteFailure {
            return StoreOutcomePresentation.notice(for: requoteFailure, kind: item.kind,
                                                   hasEligibleAssistant: true)
        }
        if let state, !commerce.busy {
            return StoreOutcomePresentation.notice(for: state, kind: item.kind)
        }
        return requoted ? .init(key: StoreCopyKey.offerChanged, tone: .warning) : nil
    }

    private var rows: some View {
        VStack(spacing: 0) {
            StoreValueRow(design: design, label: design.text(StoreCopyKey.reviewItem)) {
                Text(verbatim: item.title)
            }
            if let recipient {
                divider
                StoreValueRow(design: design, label: design.text(StoreCopyKey.reviewRecipient)) {
                    Text(verbatim: recipient)
                }
                .accessibilityIdentifier("store.review.recipient")
            }
            divider
            StoreValueRow(design: design, label: design.text(StoreCopyKey.reviewPrice)) {
                StoreProtonsText(design: design, microProtons: quote.price)
            }
            .accessibilityIdentifier("store.review.price")
            divider
            // The export has no "balance after" label yet: the balance row shows
            // the current balance and, after the chevron, what remains.
            StoreValueRow(design: design, label: design.text(StoreCopyKey.walletLabel)) {
                HStack(spacing: 6) {
                    StoreProtonsText(design: design, microProtons: quote.balance, emphasis: false, isBalance: true)
                    Image(atum.symbol(.chevronRight))
                        .font(kit.font(.caption))
                        .foregroundStyle(kit.color(.ink3, scheme: scheme))
                        .accessibilityHidden(true)
                    StoreProtonsText(design: design, microProtons: quote.resultingBalance, isBalance: true)
                }
            }
            .accessibilityIdentifier("store.review.balance")
        }
        .background(kit.color(.surface, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: kit.radius(.xl), style: .continuous))
    }

    private var divider: some View {
        Divider().overlay(kit.color(.line, scheme: scheme)).padding(.leading, 14)
    }

    private var actions: some View {
        VStack(spacing: kit.space(.s2)) {
            switch requoteFailure == nil ? outcome : .stopped {
            case nil, .requote?:
                confirmButton
                Button(design.text(StoreCopyKey.cancel)) { pop() }
                    .buttonStyle(.atumPlain)
                    .disabled(working)
                    .accessibilityIdentifier("store.review.cancel")
            case .recover?:
                if let attempt = commerce.attempt(itemID: item.id, assistant: quote.assistantID) {
                    Button {
                        guard !commerce.busy else { return }
                        submitted = true
                        Task { await commerce.retry(attempt) }
                    } label: {
                        Text(design.text(StoreCopyKey.checkStatus)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.atumPrimary)
                    .accessibilityIdentifier("store.review.check")
                }
                closeButton(.atumPlain)
            case .settled?:
                Button { finish() } label: {
                    Text(design.text(StoreCopyKey.done)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.atumPrimary)
                .accessibilityIdentifier("store.review.done")
                if let roomID {
                    Button(design.text(StoreCopyKey.open)) { openRoom(roomID) }
                        .buttonStyle(.atumPlain)
                        .accessibilityIdentifier("store.review.open")
                }
            case .stopped? where short:
                // Refused short: top up, then back to the item to review again.
                ProtonTopUpButton(design: design, style: .atumPrimary, fullWidth: true,
                                  finish: .continueToItem,
                                  onFinished: {
                                      pop()
                                      Task { await commerce.refresh() }
                                  })
                closeButton(.atumPlain)
            case .recorded?, .stopped?:
                closeButton(.atumPrimary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, kit.space(.s3))
        .padding(.bottom, kit.space(.s2))
        .frame(maxWidth: .infinity)
        .background(kit.color(.ground, scheme: scheme).ignoresSafeArea())
    }

    private var confirmButton: some View {
        Button {
            // Single flight: the engine refuses a second write while busy, and
            // the page shows the first one's outcome.
            guard !commerce.busy, !submitted || outcome == .requote else { return }
            submitted = true
            requoted = false
            let confirmed = quote
            Task { await commerce.confirm(confirmed) }
        } label: {
            ZStack {
                Text(design.text(StoreCopyKey.confirm)).opacity(working ? 0 : 1)
                if working { AtomWait().frame(width: 20, height: 20) }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.atumPrimary)
        .disabled(working || !commerce.ready || commerce.refreshing)
        .accessibilityLabel(design.text(StoreCopyKey.confirm))
        .accessibilityValue(working ? design.text(StoreCopyKey.busy) : "")
        .accessibilityIdentifier("store.review.confirm")
    }

    private func closeButton(_ style: AtumKitButtonStyle) -> some View {
        Button { finish() } label: {
            Text(design.text(StoreCopyKey.close)).frame(maxWidth: .infinity)
        }
        .buttonStyle(style)
        .accessibilityIdentifier("store.review.close")
    }
}

// MARK: - Shared pieces

/// "Get · [mark] 8,000" (desktop `store-detail.tsx:327-333, 615-624`), or "Get"
/// when free: the exported phrase, with the Proton mark before the amount.
struct StoreGetLabel: View {
    let design: LiveDesign
    let amount: String?

    var body: some View {
        if let amount {
            let marker = "\u{1}"
            let parts = design.text(StoreShelfCopyKey.getWithPrice, arguments: [.text(marker)])
                .components(separatedBy: marker)
            HStack(spacing: 4) {
                if let lead = parts.first, !lead.isEmpty { Text(verbatim: lead) }
                ProtonMark(.small)
                Text(verbatim: amount).monospacedDigit()
                if parts.count > 1, !parts[1].isEmpty { Text(verbatim: parts[1]) }
            }
            .accessibilityElement(children: .combine)
        } else {
            Text(design.text(StoreShelfCopyKey.get))
        }
    }
}

/// A label and its value on one line; at accessibility sizes the value moves
/// under the label instead of squeezing it.
struct StoreValueRow<Value: View>: View {
    let design: LiveDesign
    let label: String
    @ViewBuilder let value: () -> Value
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let kit = design.kit
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(label)
                .font(kit.font(.body))
                .foregroundStyle(kit.color(.ink2, scheme: scheme))
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            value()
                .font(kit.font(.bodyStrong))
                .foregroundStyle(kit.color(.ink, scheme: scheme))
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }
}

/// An amount in Protons: the mark and the number, spoken as "24 Protons".
struct StoreProtonsText: View {
    let design: LiveDesign
    let microProtons: Int64
    var emphasis = true
    var isBalance = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let value = isBalance
            ? ProtonAmountFormat.balance(microProtons, design: design)
            : ProtonAmountFormat.price(microProtons, design: design)
        HStack(spacing: 3) {
            ProtonMark(.small)
            Text(verbatim: value).monospacedDigit()
        }
        .foregroundStyle(design.kit.color(emphasis ? .ink : .ink2, scheme: scheme))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(design.text(StoreCopyKey.protons, arguments: [.text(value)]))
    }
}

extension StoreNotice.Tone {
    var glyph: AtumGlyph {
        switch self {
        case .done: .checkCircle
        case .neutral: .info
        case .warning: .alertCircle
        case .danger: .alertCircle
        }
    }

    var kitTone: AtumNoticeTone {
        switch self {
        case .done, .neutral: .neutral
        case .warning: .warning
        case .danger: .danger
        }
    }
}
