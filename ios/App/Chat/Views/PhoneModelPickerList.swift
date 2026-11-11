import AtumChat
import AtumDesign
import AtumNativeAPI
import SwiftUI

/// The phone model picker's list, laid out like T3 Code mobile's picker (owner,
/// 2026-10-24): "Defaults & favorites" at the top, then one collapsible section
/// per connection with the rest, a star on every model that has a stable
/// identity, and the filter button and search field pinned at the foot, where a
/// thumb reaches them. The rules (what is in which section, what search and the
/// filter keep, which sections open) are `PhoneModelPickerSections`; this view
/// draws them. Rows come only from decoded model-choice contracts: it owns no
/// provider discovery, account identity, credential or remote Mac route.
struct PhoneModelPickerList: View {
    enum Context: Equatable { case conversation, cloudAssistant, mac }

    typealias Row = PhoneModelPickerProjection.Row

    let design: LiveDesign
    let matrixAccountID: String
    let destinationID: String
    let rows: [Row]
    let context: Context
    let savingRowID: String?
    let saveFailed: Bool
    /// The levels the current Atum model accepts (the composer's picker only:
    /// a destination's default has no level of its own to write).
    let thinking: PhoneModelPickerProjection.Thinking?
    let savingEffort: ManagedModelEffort?
    let selectEffort: (ManagedModelEffort) -> Void
    /// Returns a Mac to Atum's model; given only when its saved choice is a connection's.
    let switchBack: (() -> Void)?
    let select: (Row) -> Void

    @State private var query = ""
    @State private var filter = PhoneModelPickerFilter.none
    @State private var disclosure = PhoneModelPickerDisclosure()
    @State private var preferences: ModelPickerPreferences
    /// The bar's controls grow with the text, to a cap, so a large type size
    /// never squeezes the filter symbol out of its circle.
    @ScaledMetric(relativeTo: .body) private var barControl = 44.0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let preferenceStore: ModelPickerPreferencesStore

    /// `initialQuery` and `initialFilter` start the list in a searched or filtered
    /// state, for previews, the simulator slice and UI tests; the app passes neither.
    init(design: LiveDesign, matrixAccountID: String, destinationID: String, rows: [Row],
         context: Context, savingRowID: String?, saveFailed: Bool,
         preferenceStore: ModelPickerPreferencesStore = ModelPickerPreferencesStore(),
         initialQuery: String = "", initialFilter: PhoneModelPickerFilter = .none,
         thinking: PhoneModelPickerProjection.Thinking? = nil,
         savingEffort: ManagedModelEffort? = nil,
         selectEffort: @escaping (ManagedModelEffort) -> Void = { _ in },
         switchBack: (() -> Void)? = nil,
         select: @escaping (Row) -> Void) {
        self.design = design
        self.matrixAccountID = matrixAccountID
        self.destinationID = destinationID
        self.rows = rows
        self.context = context
        self.savingRowID = savingRowID
        self.saveFailed = saveFailed
        self.thinking = thinking
        self.savingEffort = savingEffort
        self.selectEffort = selectEffort
        self.switchBack = switchBack
        self.select = select
        self.preferenceStore = preferenceStore
        _query = State(initialValue: initialQuery)
        _filter = State(initialValue: initialFilter)
        // Read before the first frame so a starred model never flashes unstarred.
        _preferences = State(initialValue: preferenceStore.read(matrixAccountID: matrixAccountID,
                                                                destinationID: destinationID))
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var copy: PhoneModelPickerCopy { PhoneModelPickerCopy(design: design) }
    private var scope: String { matrixAccountID + "\u{0}" + destinationID }

    var body: some View {
        let layout = sections
        List {
            ForEach(layout) { section in
                Section {
                    if disclosure.isOpen(section, browsing: browsing) {
                        ForEach(section.rows, id: \.stableID) { row in
                            modelRow(row, in: section)
                        }
                    }
                } header: {
                    sectionHeader(section)
                }
            }
            if layout.isEmpty {
                Section {
                    Text(verbatim: emptyCopy)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("phone.model.empty")
                }
            }
            if let switchBack {
                backToAtumSection(switchBack)
            }
            if let thinking {
                thinkingSection(thinking)
            }
            Section {
                Text(verbatim: contextCopy)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("phone.model.context")
            }
        }
        .listSectionSpacing(.compact)
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme))
        .scrollDismissesKeyboard(.interactively)
        // The foot is a bar, not an overlay: the list scrolls to its edge and
        // blurs softly under it, so a row never reads through the search field
        // and a failed-save note stays legible.
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .safeAreaBar(edge: .bottom, spacing: 0) { bottomBar }
        .accessibilityLabel(copy.text(.modelList))
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: preferences)
        .task(id: scope) {
            preferences = preferenceStore.read(matrixAccountID: matrixAccountID,
                                               destinationID: destinationID)
        }
        .onAppear {
            disclosure.show(view: viewKey)
            disclosure.settle(sections)
        }
        .onChange(of: viewKey) { _, next in disclosure.show(view: next) }
        .onChange(of: rows) { _, _ in disclosure.settle(sections) }
    }

    // MARK: Layout

    private var sections: [PhoneModelPickerSection] {
        PhoneModelPickerSections.make(rows: rows, favorites: preferences.favorites, query: query,
                                      filter: filter, locale: Locale(identifier: design.locale),
                                      searchText: searchWords)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A search or a filter is looking at the list, so a match is never hidden in a closed section.
    private var browsing: Bool { !trimmedQuery.isEmpty || filter.isActive }

    /// What is on screen: a person's open and close choices last until it changes.
    private var viewKey: String {
        trimmedQuery + "|" + (filter.favoritesOnly ? "favorites" : "") + "|" + (filter.connection ?? "")
    }

    @ViewBuilder
    private func sectionHeader(_ section: PhoneModelPickerSection) -> some View {
        switch section.kind {
        case .defaults:
            HStack(spacing: 8) {
                Image(atum.symbol(.star)).accessibilityHidden(true)
                Text(verbatim: copy.text(.defaultsAndFavorites))
            }
            .font(.body)
            .foregroundStyle(atum.color(.muted, scheme: scheme))
            .textCase(nil)
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("phone.model.section.defaults")
        case .subscriptions:
            Text(verbatim: copy.text(.subscriptions))
                .font(.body)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .textCase(nil)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("phone.model.section.subscriptions")
        case let .connection(id):
            let open = disclosure.isOpen(section, browsing: browsing)
            let name = label(forConnection: id)
            Button {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) {
                    disclosure.toggle(section, browsing: browsing)
                }
            } label: {
                HStack(spacing: 10) {
                    PhoneModelConnectionMark(design: design, connectionID: id, name: markName(forConnection: id))
                    Text(verbatim: name)
                    Spacer(minLength: 8)
                    Image(atum.symbol(.chevronDown))
                        .rotationEffect(.degrees(open ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .font(.body)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textCase(nil)
            .accessibilityLabel(name)
            .accessibilityHint(design.text(open ? "desktop.common.collapse" : "desktop.common.expand"))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("phone.model.section.\(id)")
        }
    }

    // MARK: Rows

    private func modelRow(_ row: Row, in section: PhoneModelPickerSection) -> some View {
        HStack(spacing: 4) {
            Button { choose(row) } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        nameLine(row)
                        if let detail = detail(row, withConnection: !section.isCollapsible) {
                            Text(verbatim: detail)
                                .font(.footnote)
                                .foregroundStyle(atum.color(.soft, scheme: scheme))
                        }
                    }
                    Spacer(minLength: 8)
                    trailing(row)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The current row is the one that should read strongest, so it is not
            // disabled (SwiftUI would grey its whole label); a tap on it, or on a
            // row that is busy saving, does nothing (`choose`). Only a row that
            // cannot be chosen at all is dimmed.
            .disabled(!row.selectable && !row.selected)
            .accessibilityValue(row.selected ? copy.text(.current) : "")
            .accessibilityAddTraits(row.selected ? .isSelected : [])
            .accessibilityIdentifier("phone.model.row.\(row.accessibilityID)")

            if let favoriteID = row.favoriteID {
                starButton(row, favoriteID: favoriteID)
            }
        }
        .frame(minHeight: 52)
        .listRowBackground(atum.color(.cell, scheme: scheme))
    }

    @ViewBuilder
    private func nameLine(_ row: Row) -> some View {
        let words = row.badges.map(badgeWord)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                name(row)
                badges(words)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                name(row)
                badges(words)
            }
        }
    }

    private func name(_ row: Row) -> some View {
        Text(verbatim: row.displayName).foregroundStyle(atum.color(.ink, scheme: scheme))
    }

    private func badges(_ words: [String]) -> some View {
        ForEach(words, id: \.self) { word in
            Text(verbatim: word)
                .font(.caption.weight(.medium))
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(atum.color(.bubble, scheme: scheme),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize()
        }
    }

    @ViewBuilder
    private func trailing(_ row: Row) -> some View {
        if savingRowID == row.stableID {
            ProgressView().controlSize(.small)
        } else if row.selected {
            Image(atum.symbol(.check))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .accessibilityHidden(true)
        } else if row.announced {
            Text(verbatim: design.text("desktop.atum.discover.comingSoon"))
                .font(.caption)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
        } else if !row.selectable {
            Text(verbatim: design.text("src.matrix.workbench-copy.copy.viewOnly"))
                .font(.caption)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
        }
    }

    private func starButton(_ row: Row, favoriteID: String) -> some View {
        let favorite = preferences.favorites.contains(favoriteID)
        return Button { toggleFavorite(favoriteID) } label: {
            Image(atum.symbol(favorite ? .starFilled : .star))
                .foregroundStyle(favorite ? atum.color(.ink, scheme: scheme)
                                          : atum.color(.soft, scheme: scheme))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copy.text(favorite ? .unfavorite : .favorite) + ": " + row.displayName)
        .accessibilityAddTraits(favorite ? .isSelected : [])
        .accessibilityIdentifier("phone.model.favorite.\(favoriteID)")
    }

    private func badgeWord(_ badge: Row.Badge) -> String {
        switch badge {
        case .default: copy.text(.badgeDefault)
        }
    }

    // MARK: Thinking level and the way back to Atum

    /// "Thinking": the levels the current Atum model accepts, as the desktop's
    /// Quick / Balanced / Thorough. Changing it writes the same model with the
    /// new level, through the same fenced save a model pick uses.
    private func thinkingSection(_ thinking: PhoneModelPickerProjection.Thinking) -> some View {
        let shown = savingEffort ?? thinking.current
        let level = Binding<ManagedModelEffort>(get: { shown }, set: { selectEffort($0) })
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                Picker(copy.text(.effort), selection: level) {
                    ForEach(thinking.levels, id: \.self) { each in
                        Text(verbatim: copy.effortName(each)).tag(each)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(savingRowID != nil || savingEffort != nil)
                .accessibilityIdentifier("phone.model.thinking")
                Text(verbatim: copy.effortHelp(shown))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                if shown == .high {
                    Text(verbatim: copy.text(.effortProtons))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(atum.color(.cell, scheme: scheme))
        } header: {
            Text(verbatim: copy.text(.effort))
                .font(.body)
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .textCase(nil)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// "Switch back to Atum's AI": the way home for a Mac that runs a connection's
    /// model. Atum's rows above do the same for a chosen model; this one needs no choosing.
    private func backToAtumSection(_ action: @escaping () -> Void) -> some View {
        Section {
            Button(action: action) {
                HStack(spacing: 10) {
                    PhoneModelConnectionMark(design: design, connectionID: "atum", name: "Atum")
                    Text(verbatim: copy.text(.backToAtum))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                    Spacer(minLength: 8)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(savingRowID != nil)
            .listRowBackground(atum.color(.cell, scheme: scheme))
            .accessibilityIdentifier("phone.model.back-to-atum")
        }
    }

    // MARK: The bar at the foot

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if saveFailed {
                // Glass behind it: the list scrolls under this bar, and a note drawn
                // straight on a faded row is not legible.
                Text(verbatim: copy.state(.saveFailed))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.danger, scheme: scheme))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(LiveGlass(design: design, radius: 14))
                    .accessibilityIdentifier("phone.model.save-failed")
            }
            HStack(spacing: 8) {
                filterMenu
                searchField
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(atum.symbol(.search))
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .accessibilityHidden(true)
            TextField(copy.text(.searchPlaceholder), text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("phone.model.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(atum.symbol(.close))
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .frame(width: controlSide, height: controlSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copy.text(.clearSearch))
                .accessibilityIdentifier("phone.model.search.clear")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, query.isEmpty ? 14 : 0)
        .frame(minHeight: controlSide)
        .modifier(LiveGlass(design: design, radius: controlSide / 2))
    }

    /// The bar's control height: 44 pt at the default size, growing to 64 pt.
    private var controlSide: CGFloat { min(barControl, 64) }

    /// The filter: favorites only, and one connection at a time. A person who
    /// never opens it never has one; the dot says one is set.
    private var filterMenu: some View {
        Menu {
            Toggle(isOn: $filter.favoritesOnly) {
                Label(copy.text(.favoritesOnly), image: atum.symbol(.star))
            }
            .accessibilityIdentifier("phone.model.filter.favorites")
            Section(copy.text(.accountFilter)) {
                Picker(copy.text(.accountFilter), selection: $filter.connection) {
                    Text(verbatim: copy.text(.allConnections)).tag(String?.none)
                    ForEach(PhoneModelPickerSections.connections(in: rows), id: \.self) { id in
                        Text(verbatim: label(forConnection: id)).tag(String?.some(id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            Image(atum.symbol(.slidersHorizontal))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .frame(width: controlSide, height: controlSide)
                .overlay(alignment: .topTrailing) {
                    if filter.isActive {
                        Circle()
                            .fill(atum.color(.ink, scheme: scheme))
                            .frame(width: 9, height: 9)
                            .padding(8)
                    }
                }
                .modifier(LiveGlass(design: design, radius: controlSide / 2))
        }
        .accessibilityLabel(filterLabel)
        .accessibilityIdentifier("phone.model.filter")
    }

    private var filterLabel: String {
        guard filter.isActive else { return copy.text(.filter) }
        let summary = [filter.favoritesOnly ? copy.text(.favoritesOnly) : nil,
                       filter.connection.map(label(forConnection:))]
            .compactMap { $0 }
            .joined(separator: ", ")
        return copy.text(.filterWith, [.text(summary)])
    }

    // MARK: Words

    private var emptyCopy: String {
        if !trimmedQuery.isEmpty || filter.connection != nil { return copy.text(.noMatches) }
        if filter.favoritesOnly { return copy.text(.favoritesEmpty) }
        return copy.text(.noModels)
    }

    private var contextCopy: String { copy.text(Self.contextKey(context)) }

    /// The list's last line: what a pick changes. A cloud assistant's line names
    /// the assistant only; plans work in the cloud too, so it sets no Atum-only limit.
    nonisolated static func contextKey(_ context: Context) -> PhonePickerCopyKey {
        switch context {
        case .conversation: .changesConversation
        case .cloudAssistant: .changesCloudAssistant
        case .mac: .thisMac
        }
    }

    private func label(for source: ManagedModelDestinationSource) -> String {
        switch source {
        case .atum: copy.text(.atumProvider)
        case .chatGPTPlan: copy.text(.planAccount, [.text("ChatGPT")])
        case .opencodeGo: copy.text(.planAccount, [.text("OpenCode Go")])
        case let .ownKey(provider): provider
        }
    }

    private func label(forConnection id: String) -> String {
        rows.first(where: { $0.connectionID == id }).map {
            $0.connectionLabel ?? label(for: $0.source)
        } ?? id
    }

    /// The word a connection's monogram is drawn from; OpenAI's own mark is not
    /// available, so a ChatGPT plan reads as an "O" like it does on desktop.
    private func markName(forConnection id: String) -> String {
        if rows.contains(where: { $0.connectionID == id && $0.source == .chatGPTPlan }) {
            return "OpenAI"
        }
        if rows.contains(where: { $0.connectionID == id && $0.source == .opencodeGo }) {
            return "OpenCode Go"
        }
        return label(forConnection: id)
    }

    /// The line under a model's name: whose it is. Only a connected model drawn
    /// among the defaults needs one, because nothing else there names its
    /// connection; inside a connection's own section the header does, and Atum's
    /// models are named by the line-up. Where a pick lands is said once, by the
    /// list's last line.
    private func detail(_ row: Row, withConnection: Bool) -> String? {
        guard withConnection else { return nil }
        if let tagline = row.tagline { return copy.tagline(tagline) }
        if let connectionLabel = row.connectionLabel, row.source != .atum { return connectionLabel }
        switch row.source {
        case .atum: return nil
        case .chatGPTPlan, .opencodeGo: return label(for: row.source)
        case let .ownKey(provider): return provider + " · " + copy.text(.keyAccount)
        }
    }

    /// What a row also answers to in search besides its name: its connection and account words.
    private func searchWords(_ row: Row) -> String {
        if let connectionLabel = row.connectionLabel { return connectionLabel }
        switch row.source {
        case .atum, .chatGPTPlan, .opencodeGo: return label(for: row.source)
        case let .ownKey(provider): return provider + " " + copy.text(.keyAccount)
        }
    }

    // MARK: Actions

    private func choose(_ row: Row) {
        guard row.selectable, !row.selected, savingRowID == nil else { return }
        select(row)
    }

    private func toggleFavorite(_ favoriteID: String) {
        preferences = preferences.toggling(favoriteID)
        preferenceStore.write(preferences, matrixAccountID: matrixAccountID, destinationID: destinationID)
    }
}

/// A connection's mark in its section header: Atum's own mark for Atum, else a
/// monogram in the shared squircle (no third-party brand art is shipped).
private struct PhoneModelConnectionMark: View {
    let design: LiveDesign
    let connectionID: String
    let name: String

    var body: some View {
        if connectionID == "atum" {
            LiveEclipseMark(design: design).frame(width: 24, height: 24)
        } else {
            AtumAvatar(kind: .app, name: name, size: 24)
                .atumDesign(design)
        }
    }
}
