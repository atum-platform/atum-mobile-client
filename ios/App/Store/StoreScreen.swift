import AtumChat
import AtumDesign
import AtumNativeAPI
import SwiftUI

/// S6's Store. Every row is one button with one trailing value: an item opens
/// its sheet (`StoreItemSheet`); an app with an already joined canonical room
/// opens it, and a live app with a published bot but no room yet starts a chat
/// through that app's own disclosure flow (`AppStartPolicy`). Catalog rows are
/// display data; only `LiveStoreCommerce` reviews and confirms an acquisition.
struct StoreScreen: View {
    let design: LiveDesign
    let store: LiveProductStoreRead
    let onRefresh: @MainActor () async -> Void
    let onOpenRoom: (String) -> Void
    /// Starts the chat with a catalog app that has no room yet, by slug.
    var onStartApp: ((String) -> Void)? = nil
    var setAppShortcutVisibility: (@MainActor (String, Bool) async -> Bool)? = nil
    var loadingRevealAfter: Date? = nil
    /// Acquisition, ownership and recovery. Without it the sheet shows the
    /// item only and offers no action.
    var commerce: LiveStoreCommerce? = nil
    /// A shelf to scroll to once (an assistant card's Pet or Skills row);
    /// `onShelfShown` clears the request.
    var shelfRequest: StoreSectionKind? = nil
    var onShelfShown: (() -> Void)? = nil

    @Environment(\.protonTopUp) private var topUp
    @State private var showsDelayedLoadingMark = false
    @State private var selectedItem: LiveProductStoreItem?
    @State private var showsPurchased = false
    @State private var query = ""
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        Group {
            switch store.availability {
            case .ready:
                catalog
            case .loading:
                firstLoad
            case .empty:
                catalog
            case .offline, .unavailable:
                unavailable
            }
        }
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .navigationTitle(copy("src.matrix.mobile-device-copy.mobileDeviceCopy.uiStore"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { ConnectionGlyph(design: design) }
            // FlowPhone › Store: the balance once, in the top bar, as the
            // Proton mark and whole Protons. Pressing it opens the top-up
            // (desktop `discover-view.tsx:563-581`, lane 4 W14).
            if let value = store.walletValue {
                ToolbarItem(placement: .topBarTrailing) { balanceChip(value) }
            }
        }
        .sheet(item: $selectedItem) { item in
            StoreItemSheet(design: design, item: item, commerce: commerce,
                           openRoom: onOpenRoom)
        }
        .navigationDestination(isPresented: $showsPurchased) {
            if let commerce {
                StorePurchasedScreen(design: design, commerce: commerce, title: itemTitle)
            }
        }
        .task(id: commerce?.journalReady) {
            // Ownership and unfinished purchases for the rows and Purchased.
            guard let commerce, commerce.journalReady, !commerce.busy, !commerce.ready else { return }
            await commerce.refresh()
        }
        .task(id: store.availability) {
            showsDelayedLoadingMark = false
            guard store.availability == .loading else { return }
            let deadline = loadingRevealAfter?.addingTimeInterval(0.4)
                ?? Date().addingTimeInterval(0.4)
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled, store.availability == .loading else { return }
            showsDelayedLoadingMark = true
        }
    }

    /// Desktop shelf order: Featured, Skills, Assistants, Apps, Pets, then
    /// Purchased. Featured items also sit in their kind's shelf.
    private var catalog: some View {
        ScrollViewReader { proxy in
            catalogList
                .task(id: ShelfScroll(shelf: shelfRequest, itemCount: store.items.count)) {
                    guard let shelf = shelfRequest else { return }
                    // A card opening a shelf lands on the unfiltered Store:
                    // drop a leftover search, then let the full list draw
                    // before scrolling to it.
                    if !query.isEmpty {
                        query = ""
                        try? await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled else { return }
                    }
                    if let first = firstItemID(on: shelf) {
                        withAnimation { proxy.scrollTo(first, anchor: .top) }
                    }
                    onShelfShown?()
                }
        }
    }

    private struct ShelfScroll: Equatable {
        let shelf: StoreSectionKind?
        let itemCount: Int
    }

    /// The first row of a shelf as `catalogList` draws it (no search query:
    /// a card opening a shelf lands on the unfiltered Store).
    private func firstItemID(on shelf: StoreSectionKind) -> String? {
        let plan = StoreShelfPlan(items: store.items, apps: store.apps, query: "")
        switch shelf {
        case .featured: return plan.featured.first?.id
        case .apps: return plan.apps.first?.id
        case .assistants: return plan.assistants.first?.id
        case .skills: return plan.skills.first?.id
        case .pets: return plan.pets.first?.id
        }
    }

    private var catalogList: some View {
        let plan = StoreShelfPlan(items: store.items, apps: store.apps, query: query)
        return List {
            if !plan.featured.isEmpty { itemSection(.featured, items: plan.featured) }
            if !plan.skills.isEmpty { itemSection(.skills, items: plan.skills) }
            if !plan.assistants.isEmpty {
                itemSection(.assistants, items: plan.assistants)
            } else if !plan.searching && !(store.items.isEmpty && store.apps.isEmpty) {
                assistantsSoonSection
            }
            if !plan.apps.isEmpty { appSection(plan.apps) }
            if !plan.pets.isEmpty { itemSection(.pets, items: plan.pets) }
            if showsPurchasedEntry && !plan.searching { purchasedSection }
            if plan.searching && plan.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("store.search.empty")
            } else if store.items.isEmpty && store.apps.isEmpty {
                emptySection
            }
            if store.staleAvailability != nil { staleSection }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: Text(copy(StoreShelfCopyKey.search)))
        .refreshable {
            await onRefresh()
            await commerce?.refresh()
        }
        .accessibilityIdentifier("store.catalog")
    }

    /// Desktop's Assistants shelf while nothing is for hire: "Coming soon".
    private var assistantsSoonSection: some View {
        Section {
            Text(copy(StoreCopyKey.comingSoon))
                .font(.subheadline)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .accessibilityIdentifier("store.assistants.soon")
        } header: {
            sectionHeader(copy(sectionKey(.assistants)))
        }
    }

    /// Purchased, once the account's purchase journal can be read: the way
    /// back to anything owned and to any purchase still being checked.
    private var showsPurchasedEntry: Bool {
        guard let commerce else { return false }
        return commerce.journalReady || commerce.readState != .unavailable
    }

    private var purchasedSection: some View {
        Section {
            Button { showsPurchased = true } label: {
                StorePurchasedEntry(design: design,
                                    checking: !(commerce?.unresolvedAttempts.isEmpty ?? true))
            }
            .buttonStyle(StoreRowButtonStyle(design: design))
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .accessibilityIdentifier("store.purchased.entry")
        }
    }

    private func itemTitle(_ itemID: String) -> String {
        if let item = store.items.first(where: { $0.id == itemID }) { return item.title }
        // An offer may disappear from the shop while the item remains owned.
        if let item = commerce?.catalog.first(where: { $0.itemID == itemID }) {
            return item.title.localized(locale: design.locale, fallback: itemID)
        }
        let kind = itemID.split(separator: "/").first.map(String.init)
        return copy(kind == "skill" ? "desktop.atum.discover.skillsSection"
            : kind == "pet" ? "desktop.atum.discover.petsSection" : "desktop.atum.discover.agentsSection")
    }

    /// The mark stands for the word, as a currency sign does; VoiceOver
    /// reads "N Protons". With a top-up context it is the top-up button.
    @ViewBuilder private func balanceChip(_ value: String) -> some View {
        let label = HStack(spacing: 3) {
            ProtonMark(.small)
            Text(verbatim: value).monospacedDigit()
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 6)
        if topUp != nil {
            ProtonTopUpEntry(design: design) { present in
                Button(action: present) { label }
                    .accessibilityLabel(copy(StoreCopyKey.protons, [.text(value)]))
                    .accessibilityHint(copy(ProtonTopUpCopyKey.topUp))
                    .accessibilityIdentifier("store.balance")
            }
        } else {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(copy(StoreCopyKey.protons, [.text(value)]))
                .accessibilityIdentifier("store.balance")
        }
    }

    private func itemSection(_ kind: StoreSectionKind,
                             items: [StoreListing]) -> some View {
        Section {
            ForEach(items) { listing in
                let item = listing.item
                Button { selectedItem = item } label: {
                    StoreItemRow(design: design, item: item, status: status(for: item),
                                 regularOffer: listing.regularOffer)
                }
                .buttonStyle(StoreRowButtonStyle(design: design))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                // A featured item is listed again in its kind's shelf.
                .accessibilityIdentifier(kind == .featured ? "store.featured.\(item.id)" : "store.item.\(item.id)")
            }
        } header: {
            sectionHeader(copy(sectionKey(kind)))
        }
    }

    private func appSection(_ apps: [LiveProductStoreApp]) -> some View {
        Section {
            ForEach(apps) { app in
                StoreAppRow(
                    design: design,
                    app: app,
                    open: {
                        guard let roomID = app.roomID else { return }
                        onOpenRoom(roomID)
                    },
                    start: onStartApp.map { start in { start(app.slug) } },
                    setShortcutVisibility: shortcutSetter(for: app.id)
                )
            }
        } header: {
            sectionHeader(copy(sectionKey(.apps)))
        }
    }

    private var emptySection: some View {
        Section {
            Text(copy(StoreShelfCopyKey.empty))
                .font(.subheadline)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
                .listRowBackground(Color.clear)
        }
    }

    private var staleSection: some View {
        Section {
            EmptyView()
        } footer: {
            Text(copy("desktop.atum.discover.catalogStale"))
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .textCase(nil)
        }
    }

    private func shortcutSetter(
        for appID: String
    ) -> (@MainActor (Bool) async -> Bool)? {
        guard let setAppShortcutVisibility else { return nil }
        return { shown in await setAppShortcutVisibility(appID, shown) }
    }

    private var firstLoad: some View {
        ZStack {
            Color.clear
                .accessibilityHidden(true)
            if showsDelayedLoadingMark {
                AtomWait()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityRepresentation {
                        Text(copy("desktop.atum.discover.catalogLoading"))
                            .accessibilityIdentifier("store.loading")
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unavailable: some View {
        ContentUnavailableView {
            VStack(spacing: 12) {
                Image(atum.symbol(.compass))
                    .font(.largeTitle)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityHidden(true)
                Text(copy("desktop.atum.discover.storeUnavailable"))
                    .font(.headline)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        } actions: {
            Button(copy("src.matrix.chat-copy.copies.retry")) {
                Task { await onRefresh() }
            }
            .buttonStyle(AtumCompactButtonStyle(atum: atum, scheme: scheme, size: .regular))
        }
        .accessibilityIdentifier("store.unavailable")
    }

    private func sectionHeader(_ value: String) -> some View {
        Text(value)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(atum.color(.muted, scheme: scheme))
            .textCase(nil)
    }

    /// The row's one trailing value: owned or getting ready instead of a price.
    private func status(for item: LiveProductStoreItem) -> StoreItemRow.Status {
        guard let commerce else {
            return item.kind != .skill && item.ownership?.state == .owned ? .owned : .price
        }
        let ids = StoreShelfPlan.itemIDs(for: item.id)
        if commerce.purchases.contains(where: { ids.contains($0.itemID) && $0.state == .deliveryPending }) {
            return .pending
        }
        // A skill is owned per assistant: its row keeps the price.
        guard item.kind != .skill else { return .price }
        // The folded Hatch card carries the regular card's ownership.
        if item.ownership?.state == .owned { return .owned }
        let catalogItems = commerce.catalog.filter { ids.contains($0.itemID) }
        return catalogItems.contains { commerce.owned($0, assistant: nil) } ? .owned : .price
    }

    private func sectionKey(_ kind: StoreSectionKind) -> String {
        switch kind {
        case .featured: StoreShelfCopyKey.featured
        case .apps: StoreShelfCopyKey.apps
        case .assistants: StoreShelfCopyKey.assistants
        case .skills: StoreShelfCopyKey.skills
        case .pets: StoreShelfCopyKey.pets
        }
    }

    private func copy(_ key: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key, arguments: arguments)
    }
}

/// One Store row, item or app: the 52 pt tile, name and summary, and one
/// trailing value in a single text style (a price, Owned, Open). At
/// accessibility sizes the value moves under the text.
private struct StoreRowLayout<Tile: View, Trailing: View>: View {
    let design: LiveDesign
    let title: String
    let summary: String?
    let summaryID: String
    var failure: String? = nil
    /// An app's verification seal, beside its name as in every app row.
    var seal: AppVerificationTier? = nil
    @ViewBuilder let tile: () -> Tile
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let kit = design.kit
        HStack(alignment: .center, spacing: 12) {
            tile()
            VStack(alignment: .leading, spacing: 2) {
                AppNameWithSeal(tier: seal) {
                    Text(verbatim: title)
                        .font(kit.font(.bodyStrong))
                        .foregroundStyle(kit.color(.ink, scheme: scheme))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }
                if let summary, !summary.isEmpty {
                    Text(verbatim: summary)
                        .font(.footnote)
                        .foregroundStyle(kit.color(.ink3, scheme: scheme))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                        .accessibilityIdentifier(summaryID)
                }
                if let failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(kit.color(.danger, scheme: scheme))
                }
                if dynamicTypeSize.isAccessibilitySize { trailing().padding(.top, 4) }
            }
            Spacer(minLength: 8)
            if !dynamicTypeSize.isAccessibilitySize { trailing() }
        }
        .frame(minHeight: 60)
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}

/// A full-width row press: the quiet fill, no system blue, no scale.
private struct StoreRowButtonStyle: ButtonStyle {
    let design: LiveDesign
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed
                ? design.kit.color(.fillPress, scheme: scheme) : Color.clear)
    }
}

/// The trailing value's one style, shared by every row in the Store.
/// The row's price button (desktop `ak-btn--sm`): a quiet capsule. The
/// whole row is the tap target and opens the item sheet, as on desktop.
private struct StoreRowPill<Label: View>: View {
    let design: LiveDesign
    @ViewBuilder let label: Label
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        label
            .font(design.kit.font(.callout).weight(.semibold))
            .foregroundStyle(design.kit.color(.ink, scheme: scheme))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(design.kit.color(.fillQuiet, scheme: scheme), in: Capsule())
    }
}

private struct StoreTrailingText: View {
    let design: LiveDesign
    let text: String
    var quiet = false
    var lineLimit: Int? = 1
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(text)
            .font(design.kit.font(.callout).weight(.semibold))
            .foregroundStyle(design.kit.color(quiet ? .ink3 : .ink, scheme: scheme))
            .lineLimit(lineLimit)
    }
}

private struct StorePurchasedEntry: View {
    let design: LiveDesign
    let checking: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let kit = design.kit
        let atum = AtumVisualSystem(design: design)
        StoreRowLayout(
            design: design,
            title: design.text(StoreCopyKey.purchasedTitle),
            summary: checking ? design.text(StoreCopyKey.deliveryUncertain) : nil,
            summaryID: "store.purchased.entry.summary"
        ) {
            ZStack {
                kit.color(.surface, scheme: scheme)
                Image(atum.symbol(.history))
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            .accessibilityHidden(true)
        } trailing: {
            Image(atum.symbol(.chevronRight))
                .font(kit.font(.callout))
                .foregroundStyle(kit.color(.ink3, scheme: scheme))
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(checking
            ? [design.text(StoreCopyKey.purchasedTitle), design.text(StoreCopyKey.deliveryUncertain)]
                .joined(separator: ", ")
            : design.text(StoreCopyKey.purchasedTitle))
    }
}

struct StoreItemRow: View {
    enum Status: Equatable { case price, owned, pending }
    @Environment(\.colorScheme) private var scheme

    let design: LiveDesign
    let item: LiveProductStoreItem
    var status: Status = .price
    /// The Hatch card's regular price, struck through beside the first-hatch one.
    var regularOffer: StoreCatalogOffer? = nil

    var body: some View {
        StoreRowLayout(design: design, title: item.title, summary: item.summary,
                       summaryID: "store.item.\(item.id).summary") {
            StoreItemArt(item: item)
        } trailing: {
            trailing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Desktop `store-card.tsx`: one small button per row, the Proton mark
    /// and the first price ("Open" once owned, "Free" when it costs
    /// nothing). A monthly hire's "first month · then …/mo" terms belong to
    /// the item sheet, not the row; VoiceOver still reads them here.
    @ViewBuilder private var trailing: some View {
        switch status {
        case .owned:
            StoreRowPill(design: design) { Text(design.text(StoreCopyKey.open)) }
        case .pending:
            Image(AtumVisualSystem(design: design).symbol(.clock))
                .font(design.kit.font(.callout))
                .accessibilityHidden(true)
        case .price:
            if let amount = firstPrice {
                VStack(alignment: .trailing, spacing: 2) {
                    StoreRowPill(design: design) {
                        HStack(spacing: 3) {
                            ProtonMark(.small)
                            Text(verbatim: amount).monospacedDigit()
                        }
                    }
                    if let regularOffer {
                        // PENDING-COPY:store-copy.ts firstHatch / regularPrice labels.
                        Text(verbatim: StoreOutcomePresentation.protons(regularOffer.priceMicroProtons))
                            .font(design.kit.font(.caption))
                            .monospacedDigit()
                            .strikethrough()
                            .foregroundStyle(design.kit.color(.ink3, scheme: scheme))
                    }
                }
            } else if item.offer != nil || item.price == "0" {
                // PENDING-COPY: desktop says "Get" (store-copy.ts `get`), not yet exported.
                StoreRowPill(design: design) { Text(design.text(StoreCopyKey.free)) }
            }
        }
    }

    /// The first price, formatted the same way as every other amount on the
    /// screen; nil when the item is free or has no price.
    private var firstPrice: String? {
        if let offer = item.offer {
            return offer.priceMicroProtons > 0 ? StoreOutcomePresentation.protons(offer.priceMicroProtons) : nil
        }
        guard let value = item.price, value != "0" else { return nil }
        return value
    }

    private var accessibilityLabel: String {
        var parts = [item.title, item.summary].filter { !$0.isEmpty }
        switch status {
        case .owned: parts.append(design.text(StoreCopyKey.owned))
        case .pending: parts.append(design.text(StoreCopyKey.detailPending))
        case .price:
            if let offer = item.offer, offer.billingInterval == .month {
                parts.append(StorePricePresentation.text(offer, design: design))
            } else if let value = item.price {
                parts.append(value == "0" ? design.text(StoreCopyKey.free)
                             : design.text(StoreCopyKey.protons, arguments: [.text(value)]))
            }
        }
        return parts.joined(separator: ", ")
    }
}

struct StoreItemArt: View {
    let item: LiveProductStoreItem
    var base: CGFloat = 52
    @ScaledMetric(relativeTo: .body) private var scale = 1.0
    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    private var size: CGFloat { AtumAvatar.cappedPointSize(base: base, scaled: base * scale) }

    var body: some View {
        Group {
            if let atum {
                // FlowPhone › Store: a neutral `surface` tile with a light
                // glyph (the Kit allows no emoji tiles or accent fills); a pet
                // keeps its portrait.
                ZStack {
                    atum.kitColor(.surface, scheme: scheme)
                    if let art = item.art?.value {
                        art.image
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(atum.design.symbol(glyphAlias))
                            .font(.system(size: size * 0.42, weight: .light))
                            .foregroundStyle(atum.color(.ink, scheme: scheme))
                    }
                }
                .frame(width: size, height: size)
                // Store items are apps: the squircle tile (Kit STYLE §5).
                .clipShape(AtumAvatar.shape(for: .app, size: size))
                .overlay(AtumAvatar.shape(for: .app, size: size)
                    .strokeBorder(atum.color(.avatarEdge, scheme: scheme), lineWidth: 0.5))
            }
        }
        .accessibilityHidden(true)
    }

    /// The item's own Phosphor glyph from its catalog emoji, else its kind's
    /// (desktop `storeGlyphIcon`, `store-card.tsx:92-97`).
    private var glyphAlias: String {
        let kind: StoreCatalogItem.Kind = switch item.kind {
        case .skill: .skill
        case .agent: .agent
        case .pet: .pet
        }
        return StoreGlyphs.alias(glyph: item.glyph, kind: kind)
    }
}

/// An app row is the same row as an item: one button (Open, or Start a chat)
/// with one trailing text value, not a capsule beside a price elsewhere in the
/// list (design review S1). A coming-soon app's sidebar shortcut is a context
/// menu and VoiceOver action; its row says Coming soon.
private struct StoreAppRow: View {
    let design: LiveDesign
    let app: LiveProductStoreApp
    let open: () -> Void
    let start: (() -> Void)?
    let setShortcutVisibility: (@MainActor (Bool) async -> Bool)?
    @State private var art: AtumAvatarArt?
    @State private var shortcutSaving = false
    @State private var shortcutSaveFailed = false
    @Environment(\.colorScheme) private var scheme

    private var verification: AppVerificationTier? {
        switch app.verification {
        case .official?: .official
        case .verified?: .verified
        case nil: nil
        }
    }

    private enum Action { case open, start }

    private var action: Action? {
        if app.roomID != nil { return .open }
        if app.canStartChat, start != nil { return .start }
        return nil
    }

    private var shortcut: (visible: Bool, set: @MainActor (Bool) async -> Bool)? {
        guard app.canManageShortcut, let visible = app.shortcutVisible,
              let setShortcutVisibility else { return nil }
        return (visible, setShortcutVisibility)
    }

    var body: some View {
        Group {
            switch action {
            case .open?:
                Button(action: open) { row(trailing: design.text("desktop.atum.discover.open")) }
                    .buttonStyle(StoreRowButtonStyle(design: design))
                    .accessibilityIdentifier("store.open.\(app.id)")
            case .start?:
                Button { start?() } label: { row(trailing: design.text("desktop.atum.roster.startChat")) }
                    .buttonStyle(StoreRowButtonStyle(design: design))
                    .accessibilityIdentifier("store.start.\(app.id)")
            case nil:
                row(trailing: app.canManageShortcut ? design.text(StoreCopyKey.comingSoon) : nil, quiet: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("store.app.\(app.id)")
            }
        }
        .opacity(app.isAvailable ? 1 : 0.6)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .contextMenu {
            if let shortcut {
                Button(design.text(shortcutKey(shortcut.visible))) { toggle(shortcut) }
                    .disabled(shortcutSaving)
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityActions {
            if let shortcut, !shortcutSaving {
                Button(design.text(shortcutKey(shortcut.visible))) { toggle(shortcut) }
            }
        }
        .task(id: app.avatarCandidates) {
            art = nil
            art = await AtumAvatarCandidateLoader.load(
                remoteCandidates: app.avatarCandidates,
                pixelSide: AtumAvatar.thumbnailPixelSide(for: 44)
            )
        }
        .onChange(of: app.shortcutVisible) { _, _ in
            shortcutSaveFailed = false
        }
    }

    private func row(trailing: String?, quiet: Bool = false) -> some View {
        StoreRowLayout(
            design: design, title: app.title, summary: app.subtitle,
            summaryID: "store.app.\(app.id).summary",
            failure: shortcutSaveFailed ? design.text("src.matrix.chat-copy.copies.errorGeneric") : nil,
            seal: verification
        ) {
            AtumAvatar(kind: .app, name: app.title, art: art, size: 52)
        } trailing: {
            if shortcutSaving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(design.text("src.matrix.app-copy.matrixAppCopy.savePending"))
            } else if let trailing {
                StoreTrailingText(design: design, text: trailing, quiet: quiet)
            }
        }
    }

    private func shortcutKey(_ visible: Bool) -> String {
        visible ? "src.matrix.app-copy.matrixAppCopy.hideShortcut"
            : "src.matrix.app-copy.matrixAppCopy.addShortcut"
    }

    private func toggle(_ shortcut: (visible: Bool, set: @MainActor (Bool) async -> Bool)) {
        guard !shortcutSaving else { return }
        shortcutSaving = true
        shortcutSaveFailed = false
        Task { @MainActor in
            let saved = await shortcut.set(!shortcut.visible)
            guard !Task.isCancelled else { return }
            shortcutSaving = false
            shortcutSaveFailed = !saved
        }
    }

    private var accessibilityLabel: String {
        var parts = [app.title]
        if let subtitle = app.subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        if let verification {
            parts.append(design.text(verification == .official
                ? "src.matrix.founder.founder-copy.FOUNDER_COPY.officialApp"
                : "desktop.atum.roster.verified"))
        }
        switch action {
        case .open?: parts.append(design.text("desktop.atum.discover.open"))
        case .start?: parts.append(design.text("desktop.atum.roster.startChat"))
        case nil: if app.canManageShortcut { parts.append(design.text(StoreCopyKey.comingSoon)) }
        }
        if shortcutSaveFailed { parts.append(design.text("src.matrix.chat-copy.copies.errorGeneric")) }
        return parts.joined(separator: ", ")
    }
}
