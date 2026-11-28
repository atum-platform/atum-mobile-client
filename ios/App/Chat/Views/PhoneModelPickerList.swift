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

    /// W4-Y2: the assistant's Work models from connected plan catalogs, each
    /// one a real pick (`work_selection_set`). Nil keeps the W4-X2 read-only
    /// hand-off, for a host that cannot write a Work selection.
    struct WorkRows {
        let rows: [PhoneModelPickerProjection.WorkRow]
        /// The pick in flight; its row shows progress instead of the check.
        let saving: WorkModelSelection?
        let select: (WorkModelSelection) -> Void
    }

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
    /// The account's plans with nothing to pick yet (connected nowhere or
    /// signed out): each gets "Use your {Plan} plan" and one Connect, which
    /// opens the connect sheet (desktop `AccountPlanConnectState`).
    let planConnects: [AccountPlan]
    /// Makes the connect sheet's registry poll when it opens (bound to that
    /// account session; it never rotates the grant).
    let makeConnectionsPoll: (@MainActor () -> @MainActor () async -> AccountConnections?)?
    /// The sheet saw a plan land: the picker takes that registry, so the
    /// plan's Connect entry goes away.
    let onConnectionsChanged: @MainActor (AccountConnections) -> Void
    /// W4-X2: the destination readback's own line, drawn above the models
    /// (a failure leaves every loaded catalog visible and read-only).
    let destinationStatus: PhoneModelPickerStatus?
    /// One line per account source still loading or failed (desktop #126).
    let providerStatuses: [PhoneModelPickerStatus]
    /// Plans Work reports on a Mac: read-only models with a hand-off to the
    /// Mac, never a native consent the phone cannot host.
    let handoffs: [PhoneModelPickerProjection.WorkPlanHandoff]
    let work: WorkRows?
    let retry: (PhoneModelPickerStatus.Source) -> Void
    let select: (Row) -> Void

    @State private var query = ""
    @State private var filter = PhoneModelPickerFilter.none
    @State private var disclosure = PhoneModelPickerDisclosure()
    @State private var preferences: ModelPickerPreferences
    @State private var connecting: AccountPlanConnectRequest?
    /// The sources whose failed line VoiceOver has been told about, so each
    /// failure is announced once, when its line first appears (desktop
    /// `role="alert"`). A line that loads again and fails again is new.
    @State private var announcedFailures: Set<PhoneModelPickerStatus.Source> = []
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
         planConnects: [AccountPlan] = [],
         makeConnectionsPoll: (@MainActor () -> @MainActor () async -> AccountConnections?)? = nil,
         onConnectionsChanged: @escaping @MainActor (AccountConnections) -> Void = { _ in },
         destinationStatus: PhoneModelPickerStatus? = nil,
         providerStatuses: [PhoneModelPickerStatus] = [],
         handoffs: [PhoneModelPickerProjection.WorkPlanHandoff] = [],
         work: WorkRows? = nil,
         retry: @escaping (PhoneModelPickerStatus.Source) -> Void = { _ in },
         select: @escaping (Row) -> Void) {
        self.destinationStatus = destinationStatus
        self.providerStatuses = providerStatuses
        self.handoffs = handoffs
        self.work = work
        self.retry = retry
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
        self.planConnects = planConnects
        self.makeConnectionsPoll = makeConnectionsPoll
        self.onConnectionsChanged = onConnectionsChanged
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
            if let destinationStatus {
                Section { statusRow(destinationStatus) }
            }
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
            if !providerStatuses.isEmpty, !browsing {
                Section {
                    ForEach(providerStatuses) { statusRow($0) }
                }
            }
            if work != nil {
                ForEach(shownWorkPlans, id: \.self) { workSection($0) }
            } else if !browsing {
                ForEach(shownHandoffs) { handoffSection($0) }
            }
            if layout.isEmpty, (work == nil ? (shownHandoffs.isEmpty || browsing) : shownWorkPlans.isEmpty) {
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
            if !planConnects.isEmpty, !browsing {
                planConnectSection
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
        .onChange(of: failedStatuses, initial: true) { _, next in announceFailures(next) }
        .sheet(item: $connecting) { request in
            AccountPlanConnectSheet(design: design, plan: request.plan,
                                    makePoll: request.handoff ? nil : makeConnectionsPoll,
                                    onLanded: onConnectionsChanged)
        }
    }

    /// The plans a cloud assistant's picker offers to connect, once the
    /// account read has answered (an unread registry offers nothing).
    static func planConnects(_ account: PhoneSubscriptionAccount?) -> [AccountPlan] {
        account?.accountConnections.map(AccountConnectionsView.pickerConnectPlans) ?? []
    }

    /// Desktop's Connect state for a plan with nothing to pick: the plan's
    /// mark, one line, one Connect. The phone has no rail, so each such plan
    /// is one row under the models instead of a hollow rail mark.
    private var planConnectSection: some View {
        Section {
            ForEach(planConnects, id: \.self) { plan in
                let label = Text(verbatim: AccountConnectionsWords.text(AccountConnectionsCopy.pickerUse(plan),
                                                                        design: design))
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                let connect = Button(AccountConnectionsWords.text(AccountConnectionsCopy.connect, design: design)) {
                    connecting = AccountPlanConnectRequest(plan: plan)
                }
                .buttonStyle(.atumSecondary)
                .accessibilityLabel(AccountConnectionsWords.text(AccountConnectionsCopy.sheetTitle(plan),
                                                                 design: design))
                .accessibilityIdentifier("phone.model.plan." + plan.pickerID + ".connect")
                // At accessibility sizes Connect goes under the words, as in Settings.
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                AccountPlanMark(design: design, plan: plan, size: 20)
                                label
                            }
                            connect
                        }
                    } else {
                        HStack(spacing: 12) {
                            AccountPlanMark(design: design, plan: plan, size: 20)
                            label
                            connect
                        }
                    }
                }
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 6 : 0)
                .frame(minHeight: 52)
                .listRowBackground(atum.color(.cell, scheme: scheme))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("phone.model.plan." + plan.pickerID)
            }
        }
    }

    // MARK: Settled reads and the Mac hand-off (W4-X2)

    /// The hand-off groups drawn now. While the ChatGPT relay read is loading
    /// or has failed, its line stands for ChatGPT; desktop never offers a
    /// ChatGPT hand-off on a device that reaches the relay (`model-picker.tsx`
    /// `relayReadReason`), so the same models are not listed twice (W4-X2 r2).
    private var shownHandoffs: [PhoneModelPickerProjection.WorkPlanHandoff] {
        guard providerStatuses.contains(where: { $0.source == .chatGPT }) else { return handoffs }
        return handoffs.filter { $0.plan != .codex }
    }

    private var failedStatuses: [PhoneModelPickerStatus] {
        ([destinationStatus].compactMap { $0 } + providerStatuses).filter { $0.phase == .failed }
    }

    /// Speaks a line once, when it first reads failed: "{source}, {words}".
    private func announceFailures(_ failed: [PhoneModelPickerStatus]) {
        let sources = Set(failed.map(\.source))
        let fresh = failed.filter { !announcedFailures.contains($0.source) }
        announcedFailures = sources
        guard !fresh.isEmpty else { return }
        let words = fresh.map { status in
            [statusTitle(status.source), copy.status(status)].compactMap { $0 }.joined(separator: ", ")
        }.joined(separator: ". ")
        var announcement = AttributedString(words)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }

    /// One settled read line (desktop #126 `catalogState` and the subscription
    /// note): the source, its bounded loading or failed words and, for a
    /// failure, Try again. At accessibility sizes Try again goes under the words.
    private func statusRow(_ status: PhoneModelPickerStatus) -> some View {
        let title = statusTitle(status.source)
        // A saved plan row already says why under its name: desktop gives
        // the reason there only, so the line keeps its source and Try again.
        let message: String? = title != nil && status.isShownOnRow(in: rows) ? nil : copy.status(status)
        let words = VStack(alignment: .leading, spacing: design.kit.space(.s1)) {
            if let title {
                Text(verbatim: title)
                    .font(.body)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
            }
            if let message {
                Text(verbatim: message)
                    .font(title == nil ? .body : .footnote)
                    .foregroundStyle(atum.color(title == nil ? .muted : .soft, scheme: scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        let lead = HStack(alignment: .center, spacing: design.kit.space(.s3)) {
            statusMark(status)
            words
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, message].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(status.phase == .loading ? .updatesFrequently : [])
        .accessibilityIdentifier("phone.model.status." + status.source.rawValue)
        return Group {
            if status.offersRetry, dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: design.kit.space(.s2)) {
                    lead
                    retryButton(status, title: title ?? message ?? "")
                }
            } else if status.offersRetry {
                HStack(spacing: design.kit.space(.s3)) {
                    lead
                    retryButton(status, title: title ?? message ?? "")
                }
            } else {
                lead
            }
        }
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? design.kit.space(.s2) : 0)
        .frame(minHeight: design.kit.phoneControlHeight(.regular))
        .listRowBackground(atum.color(.cell, scheme: scheme))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func statusMark(_ status: PhoneModelPickerStatus) -> some View {
        if status.phase == .loading {
            // A spinner is motion: with Reduce Motion the line keeps a still clock.
            if reduceMotion {
                Image(atum.symbol(.clock))
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.small).accessibilityHidden(true)
            }
        } else {
            switch status.source {
            case .destination:
                Image(atum.symbol(.alertCircle))
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .accessibilityHidden(true)
            case .chatGPT:
                ProviderMark(design: design, art: ProviderMark.art(source: .chatGPTPlan, connectionLabel: nil), size: 20)
                    .accessibilityHidden(true)
            case .openCodeGo:
                ProviderMark(design: design, art: ProviderMark.art(source: .opencodeGo, connectionLabel: nil), size: 20)
                    .accessibilityHidden(true)
            case .accountConnections:
                Image(atum.symbol(.link))
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .accessibilityHidden(true)
            }
        }
    }

    private func retryButton(_ status: PhoneModelPickerStatus, title: String) -> some View {
        Button(copy.text(.modelsRetry)) { retry(status.source) }
            .buttonStyle(.atumSecondary)
            .disabled(savingRowID != nil)
            .accessibilityLabel(copy.text(.modelsRetry) + ": " + title)
            .accessibilityIdentifier("phone.model.status." + status.source.rawValue + ".retry")
    }

    /// Whose read the line is about. The destination's line needs no name: its
    /// words already say the assistant's choice cannot change right now.
    private func statusTitle(_ source: PhoneModelPickerStatus.Source) -> String? {
        switch source {
        case .destination: nil
        case .chatGPT: label(for: .chatGPTPlan)
        case .openCodeGo: label(for: .opencodeGo)
        case .accountConnections: AccountConnectionsWords.text(AccountConnectionsCopy.subscriptions, design: design)
        }
    }

    /// A plan Work reports on a Mac (W4-X1 `workPlanHandoffs`): its models,
    /// read-only, then one hand-off line. Desktop greys these rows with "Works
    /// in Work for now" and, when native consent is missing, opens its Allow
    /// sheet; on a device without Work that sheet says to open Atum on the Mac,
    /// which is all the phone can offer. It never grants consent itself.
    private func handoffSection(_ handoff: PhoneModelPickerProjection.WorkPlanHandoff) -> some View {
        let planName = copy.text(.planAccount, [.text(handoff.plan.productName)])
        let reason = AccountConnectionsWords.text(AccountConnectionsCopy.pickerInWork, design: design)
        let handoffID = "phone.model.handoff." + handoff.plan.pickerID
        return Section {
            ForEach(handoff.models, id: \.id) { model in
                let name = ModelDisplayName.name(model: model.id, displayName: model.displayName)
                HStack(spacing: design.kit.space(.s3)) {
                    AccountPlanMark(design: design, plan: handoff.plan, size: 20)
                    Text(verbatim: name)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 52)
                .listRowBackground(atum.color(.cell, scheme: scheme))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(name + ", " + reason)
                .accessibilityIdentifier(handoffID + ".model." + model.id)
            }
            Button {
                connecting = AccountPlanConnectRequest(plan: handoff.plan, handoff: true)
            } label: {
                HStack(spacing: design.kit.space(.s3)) {
                    Image(atum.symbol(.arrowUpRight))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .accessibilityHidden(true)
                    Text(verbatim: reason)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(atum.symbol(.chevronRight))
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .accessibilityHidden(true)
                }
                .frame(minHeight: design.kit.phoneControlHeight(.regular))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(atum.color(.cell, scheme: scheme))
            .accessibilityLabel(planName + ", " + reason)
            .accessibilityHint(AccountConnectionsWords.text(AccountConnectionsCopy.needsMac, design: design))
            .accessibilityIdentifier(handoffID + ".open")
        } header: {
            HStack(spacing: design.kit.space(.s3)) {
                AccountPlanMark(design: design, plan: handoff.plan, size: 20)
                Text(verbatim: planName)
            }
            .font(.body)
            .foregroundStyle(atum.color(.muted, scheme: scheme))
            .textCase(nil)
            .frame(minHeight: design.kit.phoneControlHeight(.regular), alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(handoffID)
        }
    }

    // MARK: Work models (W4-Y2)

    /// The Work rows drawn now. As for the hand-off, ChatGPT's Work models
    /// are not listed beside a ChatGPT relay line still loading or failed,
    /// unless one of them is the saved choice. A search or a filter keeps
    /// the rows it matches, as it does for every other connection.
    private var shownWorkRows: [PhoneModelPickerProjection.WorkRow] {
        guard let work else { return [] }
        let relayLine = providerStatuses.contains(where: { $0.source == .chatGPT })
        return work.rows.filter { row in
            if relayLine, row.id.plan == .codex, !row.selected { return false }
            if filter.favoritesOnly || filter.connection != nil { return false }
            guard !trimmedQuery.isEmpty else { return true }
            let words = row.displayName + " " + copy.text(.planAccount, [.text(row.id.plan.productName)])
            return words.range(of: trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive],
                               locale: Locale(identifier: design.locale)) != nil
        }
    }

    /// Plans in the order their first Work row appears.
    private var shownWorkPlans: [AccountPlan] {
        var seen = Set<AccountPlan>()
        return shownWorkRows.compactMap { seen.insert($0.id.plan).inserted ? $0.id.plan : nil }
    }

    /// One connected plan's Work models (desktop `relayRoutes`): the plan's
    /// mark and "{Plan} plan" over its models, the saved one checked and
    /// Current. A pick here writes the Work selection only; it never writes
    /// a cloud choice. A row the catalog cannot offer now is drawn dimmed.
    private func workSection(_ plan: AccountPlan) -> some View {
        let planName = copy.text(.planAccount, [.text(plan.productName)])
        return Section {
            ForEach(shownWorkRows.filter { $0.id.plan == plan }) { row in
                workRow(row)
            }
        } header: {
            HStack(spacing: design.kit.space(.s3)) {
                AccountPlanMark(design: design, plan: plan, size: 20)
                Text(verbatim: planName)
            }
            .font(.body)
            .foregroundStyle(atum.color(.muted, scheme: scheme))
            .textCase(nil)
            .frame(minHeight: design.kit.phoneControlHeight(.regular), alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("phone.model.work." + plan.pickerID)
        }
    }

    private func workRow(_ row: PhoneModelPickerProjection.WorkRow) -> some View {
        let saving = work?.saving == row.id
        let busy = work?.saving != nil || savingRowID != nil
        return Button {
            guard row.selectable, !row.selected, !busy else { return }
            work?.select(row.id)
        } label: {
            HStack(spacing: design.kit.space(.s3)) {
                AccountPlanMark(design: design, plan: row.id.plan, size: 20)
                HStack(alignment: .firstTextBaseline, spacing: 6) { // design-lint: allow: desktop #119 puts the check 6 pt after the name
                    Text(verbatim: row.displayName)
                        .foregroundStyle(atum.color(row.selectable || row.selected ? .ink : .soft, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                    if row.selected, !saving { check }
                }
                Spacer(minLength: design.kit.space(.s2))
                if saving {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(copy.state(.saving))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!row.selectable && !row.selected)
        .frame(minHeight: 52)
        .listRowBackground(rowBackground(selected: row.selected))
        .accessibilityValue(saving ? copy.state(.saving) : row.selected ? copy.text(.current) : "")
        .accessibilityAddTraits(row.selected ? .isSelected : [])
        .accessibilityIdentifier("phone.model.work." + row.id.plan.pickerID + ".model." + row.id.model)
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
                    ProviderMark(design: design, art: connectionArt(id), size: 20)
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

    /// Desktop's row (`model-picker-list.tsx`, spec `row`): the provider's
    /// mark, the name with the check beside it, Atum's muted line, the star.
    /// The phone keeps that line under the name (an iPhone row is too narrow
    /// to trail it) and a tap target of at least 44 pt.
    private func modelRow(_ row: Row, in section: PhoneModelPickerSection) -> some View {
        HStack(spacing: 4) {
            Button { choose(row) } label: {
                HStack(spacing: 12) {
                    ProviderMark(design: design, art: markArt(row), size: 20)
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
        // The current row is shaded as well as checked, as on the desktop
        // (`current && bg-(--atum-hover)`); the shade alone would read as a press.
        .listRowBackground(rowBackground(selected: row.selected))
    }

    private func rowBackground(selected: Bool) -> some View {
        atum.color(.cell, scheme: scheme)
            .overlay(selected ? atum.kitColor(.fillHover, scheme: scheme) : .clear)
    }

    @ViewBuilder
    private func nameLine(_ row: Row) -> some View {
        let words = row.badges.map(badgeWord)
        let named = HStack(alignment: .firstTextBaseline, spacing: 6) { // design-lint: allow: desktop #119 puts the check 6 pt after the name
            name(row)
            if row.selected, savingRowID != row.stableID { check }
        }
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                named
                badges(words)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                named
                badges(words)
            }
        }
    }

    /// The saved choice's check, beside its name (desktop STYLE.md §12).
    private var check: some View {
        Image(atum.symbol(.check))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(atum.color(.ink, scheme: scheme))
            .accessibilityHidden(true)
    }

    /// The row's mark: Atum's logo tile for Atum's line-up, else the
    /// connection's provider (desktop `PickerRouteMark`), the same one the
    /// composer chip draws for this row.
    private func markArt(_ row: Row) -> ProviderMark.Art { ProviderMark.art(for: row) }

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
            // The check is beside the name.
            EmptyView()
        } else if row.announced {
            Text(verbatim: design.text("desktop.atum.discover.comingSoon"))
                .font(.caption)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
        } else if row.unavailable != nil {
            // The line under the name says why; "view only" would say something else.
            EmptyView()
        } else if !row.selectable {
            Text(verbatim: design.text("src.matrix.workbench-copy.copy.viewOnly"))
                .font(.caption)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
        }
    }

    private func starButton(_ row: Row, favoriteID: String) -> some View {
        let favorite = preferences.favorites.contains(favoriteID)
        return Button { toggleFavorite(favoriteID) } label: {
            // Desktop: a starred model's star is the mark amber (`--atum-mark-amber`,
            // #ffa100); an unstarred one is faint. A phone has no hover, so the
            // unstarred star stays drawn rather than waiting for the pointer.
            Image(atum.symbol(favorite ? .starFilled : .star))
                .foregroundStyle(favorite ? AssistantMarkPalette.color(.amber, scheme: scheme)
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
        let level = Binding<ManagedModelEffort?>(get: { shown }, set: { if let value = $0 { selectEffort(value) } })
        return Section {
            VStack(alignment: .leading, spacing: 8) {
                Picker(copy.text(.effort), selection: level) {
                    ForEach(thinking.levels, id: \.self) { each in
                        Text(verbatim: copy.effortName(each)).tag(Optional(each))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(savingRowID != nil || savingEffort != nil)
                .accessibilityIdentifier("phone.model.thinking")
                if let shown, let help = copy.effortHelp(shown) {
                    Text(verbatim: help)
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                }
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
                    ProviderMark(design: design, art: .atum, size: 20)
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

    /// A connection's mark in its section header: its first row's provider,
    /// as the desktop rail draws it (a signed-out connection keeps its full mark).
    private func connectionArt(_ id: String) -> ProviderMark.Art {
        if id == "atum" { return .atum }
        guard let row = rows.first(where: { $0.connectionID == id }) else {
            return .monogram(label(forConnection: id))
        }
        return markArt(row)
    }

    /// The line under a model's name: whose it is. Only a connected model drawn
    /// among the defaults needs one, because nothing else there names its
    /// connection; inside a connection's own section the header does, and Atum's
    /// models are named by the line-up. Where a pick lands is said once, by the
    /// list's last line.
    private func detail(_ row: Row, withConnection: Bool) -> String? {
        if let unavailable = row.unavailable {
            return label(for: row.source) + " · " + copy.unavailable(unavailable)
        }
        // Atum's own line always follows its name, as on the desktop.
        if let tagline = row.tagline { return copy.tagline(tagline) }
        guard withConnection else { return nil }
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
