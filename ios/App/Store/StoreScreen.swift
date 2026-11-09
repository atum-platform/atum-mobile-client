import AtumChat
import AtumDesign
import SwiftUI

/// S6's read-only Store. Catalog rows are data, never purchase or navigation
/// authority; an app with an already joined canonical room gets “Open”, and a
/// live app with a published bot but no room yet gets “Start a chat”, which
/// runs that app's own disclosure flow (`AppStartPolicy`).
struct StoreScreen: View {
    let design: LiveDesign
    let store: LiveProductStoreRead
    let onRefresh: @MainActor () async -> Void
    let onOpenRoom: (String) -> Void
    /// Starts the chat with a catalog app that has no room yet, by slug.
    var onStartApp: ((String) -> Void)? = nil
    var setAppShortcutVisibility: (@MainActor (String, Bool) async -> Bool)? = nil
    var loadingRevealAfter: Date? = nil

    @State private var showsDelayedLoadingMark = false
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
            // FlowPhone › Store: the balance once, as a glass capsule in the
            // top bar. Display-only until the phone top-up board exists
            // (owner, 11-01).
            if let value = store.walletValue {
                ToolbarItem(placement: .topBarTrailing) { balanceChip(value) }
            }
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

    private var catalog: some View {
        List {
            if !featured.isEmpty { itemSection(.featured, items: featured) }
            if !store.apps.isEmpty { appSection }
            if !assistants.isEmpty { itemSection(.assistants, items: assistants) }
            if !skills.isEmpty { itemSection(.skills, items: skills) }
            if !pets.isEmpty { itemSection(.pets, items: pets) }
            if store.items.isEmpty && store.apps.isEmpty { emptySection }
            if store.staleAvailability != nil { staleSection }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await onRefresh() }
        .accessibilityIdentifier("store.catalog")
    }

    private func balanceChip(_ value: String) -> some View {
        Text(verbatim: copy("desktop.atum.discover.protons", [.text(value)]))
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
            .lineLimit(1)
            .padding(.horizontal, 6)
            .accessibilityLabel([
                copy("desktop.atum.discover.protons", [.text(value)]),
                copy("src.matrix.mobile-device-copy.mobileDeviceCopy.accountRowsWalletLabel"),
            ].joined(separator: ", "))
            .accessibilityIdentifier("store.balance")
    }

    private func itemSection(_ kind: StoreSectionKind,
                             items: [LiveProductStoreItem]) -> some View {
        Section {
            ForEach(items) { item in StoreItemRow(design: design, item: item) }
        } header: {
            sectionHeader(copy(sectionKey(kind)))
        }
    }

    private var appSection: some View {
        Section {
            ForEach(store.apps) { app in
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
            sectionHeader(copy("desktop.atum.discover.appsSection"))
        }
    }

    private var emptySection: some View {
        Section {
            Text(copy("desktop.atum.workspace.empty"))
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

    private var featured: [LiveProductStoreItem] { store.items.filter(\.featured) }
    private var assistants: [LiveProductStoreItem] {
        store.items.filter { !$0.featured && $0.kind == .agent }
    }
    private var skills: [LiveProductStoreItem] {
        store.items.filter { !$0.featured && $0.kind == .skill }
    }
    private var pets: [LiveProductStoreItem] {
        store.items.filter { !$0.featured && $0.kind == .pet }
    }

    private func sectionKey(_ kind: StoreSectionKind) -> String {
        switch kind {
        case .featured: "desktop.atum.discover.featuredSection"
        case .apps: "desktop.atum.discover.appsSection"
        case .assistants: "desktop.atum.discover.agentsSection"
        case .skills: "desktop.atum.discover.skillsSection"
        case .pets: "desktop.atum.discover.petsSection"
        }
    }

    private func copy(_ key: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key, arguments: arguments)
    }
}

private struct StoreItemRow: View {
    let design: LiveDesign
    let item: LiveProductStoreItem
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StoreItemArt(item: item)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                Text(verbatim: item.summary)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .accessibilityIdentifier("store.item.\(item.id).summary")
                if dynamicTypeSize.isAccessibilitySize { price }
            }
            Spacer(minLength: 8)
            if !dynamicTypeSize.isAccessibilitySize { price }
        }
        .frame(minHeight: 60)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder private var price: some View {
        if let value = item.price {
            // A price, not a purchase button: no purchase call to action
            // until the server-validated StoreKit path exists (AGENTS.md;
            // owner, 11-01). The board's capsules arrive with the item sheet.
            if value == "0" {
                Text(design.text("desktop.atum.discover.free"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
            } else {
                HStack(spacing: 3) {
                    ProtonMark(.small)
                    Text(verbatim: value).monospacedDigit()
                }
                .font(.subheadline.weight(.semibold))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(design.text("desktop.atum.discover.protons",
                                                arguments: [.text(value)]))
            }
        }
    }

    private var accessibilityLabel: String {
        var parts = [item.title, item.summary]
        if let value = item.price {
            parts.append(value == "0" ? design.text("desktop.atum.discover.free")
                         : design.text("desktop.atum.discover.protons", arguments: [.text(value)]))
        }
        return parts.joined(separator: ", ")
    }
}

private struct StoreItemArt: View {
    let item: LiveProductStoreItem
    @ScaledMetric(relativeTo: .body) private var scaledSize = 52.0
    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    private var size: CGFloat { AtumAvatar.cappedPointSize(base: 52, scaled: scaledSize) }

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
                        Image(atum.symbol(glyph))
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

    private var glyph: AtumGlyph {
        switch item.kind {
        case .skill: .sparkles
        case .agent: .userCircle
        case .pet: .pawPrint
        }
    }
}

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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var verification: AppVerificationTier? {
        switch app.verification {
        case .official?: .official
        case .verified?: .verified
        case nil: nil
        }
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // The action goes under the text: beside it, a long label
                // squeezes the name out or wraps the capsule into a circle.
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        AtumAvatar(kind: .app, name: app.title, art: art, size: 52)
                        details
                    }
                    action
                }
            } else {
                HStack(spacing: 12) {
                    AtumAvatar(kind: .app, name: app.title, art: art, size: 52)
                    details
                    Spacer(minLength: 8)
                    action
                }
            }
        }
        .frame(minHeight: 60)
        .opacity(app.isAvailable ? 1 : 0.6)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            AppNameWithSeal(tier: verification) {
                Text(verbatim: app.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            if let subtitle = app.subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .accessibilityIdentifier("store.app.\(app.id).summary")
            }
            if shortcutSaveFailed {
                Text(design.text("src.matrix.chat-copy.copies.errorGeneric"))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.danger, scheme: scheme))
                    .accessibilityIdentifier("store.shortcut.\(app.id).failure")
            }
        }
    }

    @ViewBuilder private var action: some View {
        if app.roomID != nil {
            Button(design.text("desktop.atum.discover.open"), action: open)
                .buttonStyle(AtumCompactButtonStyle(atum: atum, scheme: scheme))
                .accessibilityIdentifier("store.open.\(app.id)")
        } else if app.canStartChat, let start {
            Button(action: start) {
                Text(design.text("desktop.atum.roster.startChat")).lineLimit(1)
            }
            .buttonStyle(AtumCompactButtonStyle(atum: atum, scheme: scheme))
                .accessibilityIdentifier("store.start.\(app.id)")
        } else if app.canManageShortcut, let visible = app.shortcutVisible,
                  let setShortcutVisibility {
            Button {
                guard !shortcutSaving else { return }
                shortcutSaving = true
                shortcutSaveFailed = false
                Task { @MainActor in
                    let saved = await setShortcutVisibility(!visible)
                    guard !Task.isCancelled else { return }
                    shortcutSaving = false
                    shortcutSaveFailed = !saved
                }
            } label: {
                if shortcutSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(design.text(
                            "src.matrix.app-copy.matrixAppCopy.savePending"
                        ))
                } else {
                    Text(design.text(visible
                        ? "src.matrix.app-copy.matrixAppCopy.hideShortcut"
                        : "src.matrix.app-copy.matrixAppCopy.addShortcut"))
                }
            }
            .buttonStyle(AtumCompactButtonStyle(atum: atum, scheme: scheme))
            .disabled(shortcutSaving)
            .accessibilityIdentifier("store.shortcut.\(app.id).\(visible ? "hide" : "show")")
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
        return parts.joined(separator: ", ")
    }
}

