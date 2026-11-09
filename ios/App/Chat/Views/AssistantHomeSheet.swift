import AtumDesign
import AtumNativeAPI
import SwiftUI

struct AssistantHomeValue: Equatable {
    let snapshot: AgentHomeSnapshot
    let destinations: ManagedModelDestinationSnapshot
    let cloudModels: ManagedModelSnapshot
    let application: AgentHomeModelApplication?
    let choiceOverride: AgentHomeModelChoice?
    let pendingNextTurn: Bool

    var choiceRevision: Int64 { application?.choiceRevision ?? destinations.revision }

    var currentChoice: AgentHomeModelChoice? {
        if let choiceOverride { return choiceOverride }
        if let application { return application.choice }
        guard let choice = try? legacyChoice(for: snapshot.placement.location) else { return nil }
        return choice
    }

    func legacyChoice(for home: AgentHomeLocation) throws -> AgentHomeModelChoice? {
        let destination = try ManagedModelDestinationID(home.destinationID)
        guard let choice = destinations.choice(for: destination) else { return nil }
        guard home == .cloud, choice.source == .atum,
              let effort = AgentHomeModelEffort(rawValue: choice.effort) else { return nil }
        return try AgentHomeModelChoice(home: .cloud, source: .atum,
                                        connectionRef: AgentHomeContract.managedConnectionRef,
                                        model: choice.model, effort: effort)
    }
}
enum AssistantHomeLoadResult {
    case value(AssistantHomeValue)
    case unavailable
    case failed
}

enum AssistantHomeCatalogResult { case value(AgentHomeMacCatalog), unavailable, failed }

struct AssistantHomeActions {
    let matrixAccountID: String
    // The authenticated phone channel authorizes owner writes in agent-home/2.5.
    // Each owner write also takes the request ID of its logical operation: a
    // retry passes the same one, with the same idempotency key in its input.
    let read: () async -> AssistantHomeLoadResult
    let catalog: (NativeID) async -> AssistantHomeCatalogResult
    let preflight: (AgentHomePreflightInput, NativeID) async -> Result<AgentHomeMovePreflight, Error>
    let move: (AgentHomeMoveInput, NativeID) async -> Result<AgentHomeMoveCommandResult, Error>
    let cancel: (AgentHomeCancelInput, NativeID) async -> Result<AgentHomeMoveCommandResult, Error>
    let progress: (NativeID) async -> Result<AgentHomeMoveProgress, Error>
    let writeModel: (AgentHomeModelChoiceInput, NativeID) async -> Result<AgentHomeModelChoiceResult, Error>
    let application: () async -> AgentHomeModelApplication?
}

/// The one assistant-card "where it lives" row. It loads the authoritative
/// summary and presents one sheet for destination, model, disclosures and
/// progress. The card's model row is separate: this row is only the place.
struct AssistantHomeCardControl: View {
    let design: LiveDesign
    let assistantName: String
    let actions: AssistantHomeActions

    @State private var value: AssistantHomeValue?
    @State private var condition: Condition = .loading
    @State private var showsSheet = false
    @Environment(\.colorScheme) private var scheme

    private enum Condition: Equatable { case loading, ready, unavailable, failed }
    private var copy: AgentHomeCopy { AgentHomeCopy(design: design) }
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        // The task and the sheet hang off the container, not off one row, so a
        // row that swaps for the other never cancels the read or the sheet.
        row
            .task { await load() }
            .sheet(isPresented: $showsSheet) {
                NavigationStack {
                    AssistantHomeMoveSheet(design: design, assistantName: assistantName,
                                           actions: actions, initialValue: value) { next in
                        value = next
                        condition = .ready
                    }
                }
            }
    }

    private var row: some View {
        Button { showsSheet = true } label: {
            HStack(spacing: 8) {
                Text(copy.text(.livesOn))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                Spacer(minLength: 8)
                Text(verbatim: valueText)
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
                if canOpen {
                    Image(atum.symbol(.chevronRight))
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .accessibilityHidden(true)
                } else if condition == .loading {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canOpen)
        .accessibilityLabel(copy.text(.livesOn) + ", " + valueText)
        .accessibilityIdentifier("assistant.card.home")
    }

    private var valueText: String {
        switch condition {
        case .loading: return copy.text(.loading)
        case .unavailable: return copy.text(.movesUnavailable)
        case .failed: return copy.text(.loadFailed)
        case .ready:
            guard let value else { return copy.text(.loadFailed) }
            return copy.placeName(value.snapshot.placement.location, snapshot: value.snapshot)
        }
    }

    /// Reachable when the platform advertises placement, and also while the assistant's
    /// Mac is not answering: the owner can still wait, move to the cloud knowingly, or cancel.
    private var canOpen: Bool {
        guard let snapshot = value?.snapshot else { return false }
        return snapshot.moveCapability == .available || snapshot.waitsForHomeMac
    }

    @MainActor private func load() async {
        // `condition` starts as `.loading`. A later read keeps the row that is
        // showing until its answer arrives, so coming back from the sheet does
        // not flash the row.
        switch await actions.read() {
        case let .value(next):
            value = next; condition = .ready
        case .unavailable: condition = .unavailable
        case .failed: if value == nil { condition = .failed }
        }
    }
}

private struct AssistantHomeMoveSheet: View {
    let design: LiveDesign
    let assistantName: String
    let actions: AssistantHomeActions
    let initialValue: AssistantHomeValue?
    let onValue: (AssistantHomeValue) -> Void

    @State private var value: AssistantHomeValue?
    @State private var loadFailed = false
    @State private var selectedHome: AgentHomeLocation?
    @State private var selectedChoice: AgentHomeModelChoice?
    @State private var catalog: AgentHomeMacCatalog?
    @State private var catalogFailed = false
    @State private var preflight: AgentHomeMovePreflight?
    @State private var progress = AgentHomeProgressTracker()
    @State private var busy = false
    @State private var commandFailed = false
    @State private var acceptsCheckpointLoss = false
    @State private var modelSaveFailed = false
    @State private var modelSavingRowID: String?
    // One logical owner write each. A retry reuses BOTH the request ID and the
    // idempotency key until a definitive answer; a changed effect (the payload)
    // is another operation with a fresh pair.
    @State private var modelWrites = AgentHomeOwnerWrites<ModelPayload>()
    @State private var preflightWrites = AgentHomeOwnerWrites<PreflightPayload>()
    @State private var moveWrites = AgentHomeOwnerWrites<MovePayload>()
    @State private var cancelWrites = AgentHomeOwnerWrites<CancelPayload>()
    @State private var moveID: NativeID?
    @State private var cancelID: NativeID?
    @State private var pollTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    /// Every field of each request that can differ between two attempts.
    private struct ModelPayload: Hashable, Sendable {
        let choice: AgentHomeModelChoice
        let revision: Int64
        let home: AgentHomeLocation
        let homeID: NativeID
        let epoch: Int64
        let activeMoveID: NativeID?
    }
    private struct PreflightPayload: Hashable, Sendable {
        let target: AgentHomeLocation
        let choice: AgentHomeModelChoice
        let epoch: Int64
        let activeMoveID: NativeID?
        let catalogRevision: Int64
    }
    private struct MovePayload: Hashable, Sendable {
        let target: AgentHomeLocation
        let epoch: Int64
        let activeMoveID: NativeID?
        let accepted: AgentHomeAcceptedPreflight
        let acceptsCheckpointLoss: Bool
    }
    private struct CancelPayload: Hashable, Sendable {
        let moveID: NativeID
        let epoch: Int64
    }

    init(design: LiveDesign, assistantName: String, actions: AssistantHomeActions,
         initialValue: AssistantHomeValue?, onValue: @escaping (AssistantHomeValue) -> Void) {
        self.design = design; self.assistantName = assistantName; self.actions = actions
        self.initialValue = initialValue; self.onValue = onValue
        _value = State(initialValue: initialValue)
        _selectedHome = State(initialValue: initialValue?.snapshot.placement.location)
        _selectedChoice = State(initialValue: initialValue?.currentChoice)
    }

    private var copy: AgentHomeCopy { AgentHomeCopy(design: design) }
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        Group {
            if let value { content(value) }
            else if loadFailed {
                ContentUnavailableView {
                    Label(copy.text(.loadFailed), image: atum.symbol(.alertCircle))
                } actions: {
                    Button(copy.text(.retry)) { Task { await load() } }
                }
            } else { ProgressView().accessibilityIdentifier("assistant.home.loading") }
        }
        .navigationTitle(copy.text(.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { atum.barIcon(.close) }
                    .accessibilityLabel(copy.text(.close))
            }
        }
        .task { if value == nil { await load() } else { await loadCatalogForSelection() } }
        .onDisappear { pollTask?.cancel() }
    }

    private func content(_ value: AssistantHomeValue) -> some View {
        List {
            currentSummary(value)
            if value.snapshot.waitsForHomeMac { waitingSection(value) }
            destinationSection(value)
            modelSection(value)
            if let preflight { disclosureSection(preflight) }
            if let current = progress.progress { progressSection(current, value: value) }
            if commandFailed || modelSaveFailed { errorSection }
            actionSection(value)
        }
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme))
    }

    private func currentSummary(_ value: AssistantHomeValue) -> some View {
        Section {
            LabeledContent(copy.text(.livesOn),
                           value: copy.homeName(value.snapshot.placement.location,
                                                snapshot: value.snapshot))
            if let choice = value.currentChoice {
                LabeledContent(copy.text(.model),
                               value: copy.provider(choice.source) + " · "
                                   + copy.modelName(choice, cloudModels: value.cloudModels,
                                                    catalog: catalog))
            }
            LabeledContent(copy.text(.status),
                           value: copy.reachability(value.snapshot.currentHomeReachability))
            if let application = value.application {
                Text(verbatim: copy.application(
                    application,
                    home: copy.homeName(value.snapshot.placement.location,
                                        snapshot: value.snapshot)
                ))
                    .font(.footnote)
                    .foregroundStyle(application.status == .unavailable
                        ? atum.color(.danger, scheme: scheme) : atum.color(.muted, scheme: scheme))
            }
        } header: { Text(verbatim: assistantName) }
    }

    /// The assistant's Mac is not answering: Atum waits for it, and the one other way
    /// out (the cloud, losing the work since the last checkpoint) stays the owner's to take.
    private func waitingSection(_ value: AssistantHomeValue) -> some View {
        Section {
            Text(verbatim: copy.waitingForHome(homeName: copy.homeName(value.snapshot.placement.location,
                                                                       snapshot: value.snapshot)))
                .font(.footnote).foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityIdentifier("assistant.home.waiting")
        }
    }

    private func destinationSection(_ value: AssistantHomeValue) -> some View {
        Section(copy.text(.chooseHome)) {
            ForEach(destinations(value), id: \.location) { destination in
                Button {
                    selectHome(destination.location, value: value)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: destination.name)
                            if let status = destination.status {
                                Text(verbatim: status).font(.footnote)
                                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                            }
                        }
                        Spacer()
                        if selectedHome == destination.location {
                            Image(atum.symbol(.check)).accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!destination.enabled || busy || progress.progress?.isTerminal == false)
                .accessibilityValue(selectedHome == destination.location ? copy.text(.selected) : "")
                .accessibilityIdentifier("assistant.home.destination." + destination.location.destinationID)
            }
        }
    }

    @ViewBuilder private func modelSection(_ value: AssistantHomeValue) -> some View {
        Section(copy.text(.model)) {
            if let selectedHome {
                NavigationLink {
                    modelPicker(value, home: selectedHome)
                } label: {
                    HStack {
                        Text(copy.text(.chooseModel))
                        Spacer()
                        Text(verbatim: selectedChoice.map {
                            copy.provider($0.source) + " · "
                                + copy.modelName($0, cloudModels: value.cloudModels, catalog: catalog)
                        } ?? copy.text(.notSelected))
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .multilineTextAlignment(.trailing)
                    }
                }
                .disabled(selectedHome.deviceID != nil && catalog == nil)
                .accessibilityIdentifier("assistant.home.model")
                if value.snapshot.waitsForHomeMac, selectedHome == value.snapshot.placement.location {
                    // The waiting note above says why; a stale catalog here is that same wait.
                    EmptyView()
                } else if catalogFailed {
                    Text(verbatim: copy.text(.catalogUnavailable))
                        .font(.footnote).foregroundStyle(atum.color(.danger, scheme: scheme))
                } else if let catalog, catalog.freshness == .unavailable {
                    Text(verbatim: copy.text(.catalogUnavailable))
                        .font(.footnote).foregroundStyle(atum.color(.danger, scheme: scheme))
                } else if let catalog, catalog.freshness == .stale {
                    Text(verbatim: copy.text(.catalogStale))
                        .font(.footnote).foregroundStyle(atum.color(.danger, scheme: scheme))
                } else if let catalog,
                          let connection = catalog.connections.first(where: { $0.state == .needsAttention }) {
                    Text(verbatim: copy.connectionNeedsAttention(
                        provider: connection.providerLabel.rawValue,
                        home: copy.homeName(selectedHome, snapshot: value.snapshot)
                    ))
                    .font(.footnote).foregroundStyle(atum.color(.danger, scheme: scheme))
                }
            }
        }
    }

    private func modelPicker(_ value: AssistantHomeValue, home: AgentHomeLocation) -> some View {
        let rows = home == .cloud
            ? AgentHomeModelRows.cloud(value.cloudModels, selected: selectedChoice)
            : catalog.map { AgentHomeModelRows.mac($0, selected: selectedChoice) } ?? []
        return PhoneModelPickerList(
            design: design, matrixAccountID: actions.matrixAccountID,
            destinationID: home.destinationID, rows: rows,
            context: home == .cloud ? .cloudAssistant : .mac,
            savingRowID: modelSavingRowID, saveFailed: modelSaveFailed
        ) { row in choose(row, home: home, value: value) }
        .navigationTitle(copy.text(.chooseModel))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func disclosureSection(_ preflight: AgentHomeMovePreflight) -> some View {
        Section(copy.text(.actualLosses)) {
            if preflight.common.featureLosses.isEmpty {
                Text(verbatim: copy.text(.noLosses))
            } else {
                ForEach(preflight.common.featureLosses, id: \.self) { loss in
                    Label(copy.loss(loss), image: atum.symbol(.alertCircle))
                }
            }
            if case let .disclosed(timestamp) = preflight.common.checkpointLoss {
                Text(verbatim: copy.checkpoint(timestamp))
                    .font(.footnote).foregroundStyle(atum.color(.danger, scheme: scheme))
                Toggle(copy.text(.acceptCheckpointLoss), isOn: $acceptsCheckpointLoss)
                    .accessibilityIdentifier("assistant.home.accept-checkpoint-loss")
            }
            if preflight.outcome == .blocked {
                Text(verbatim: copy.blocked(preflight.reason, target: selectedHome))
                    .foregroundStyle(atum.color(.danger, scheme: scheme))
            }
        }
    }

    private func progressSection(_ current: AgentHomeMoveProgress,
                                 value: AssistantHomeValue) -> some View {
        Section(copy.text(.status)) {
            Text(verbatim: copy.progress(current, snapshot: value.snapshot))
                .font(.headline)
            if current.state == .failed {
                Text(verbatim: copy.failure(current, snapshot: value.snapshot))
                    .font(.footnote).foregroundStyle(atum.color(.danger, scheme: scheme))
            }
            if current.state == .ready, current.modelApplication == .pendingNextTurn {
                Text(verbatim: copy.text(.modelNextTurn))
                    .font(.footnote).foregroundStyle(atum.color(.muted, scheme: scheme))
            }
        }
    }

    private var errorSection: some View {
        Section {
            Text(verbatim: copy.text(modelSaveFailed ? .modelSaveFailed : .commandFailed))
                .foregroundStyle(atum.color(.danger, scheme: scheme))
        }
    }

    @ViewBuilder private func actionSection(_ value: AssistantHomeValue) -> some View {
        Section {
            if let current = progress.progress, !current.isTerminal {
                Button(copy.text(.cancelMove), role: .destructive) { Task { await cancel(value) } }
                    .disabled(busy)
                    .accessibilityIdentifier("assistant.home.cancel")
            } else if progress.progress?.state == .failed {
                Button(copy.text(.retry)) { resetMove() }
                    .disabled(busy)
                    .accessibilityIdentifier("assistant.home.retry")
            } else if selectedHome != value.snapshot.placement.location {
                Button(moveButtonTitle) { Task { await advanceMove(value) } }
                    .disabled(!canAdvanceMove(value))
                    .accessibilityIdentifier("assistant.home.move")
            // No owner-signer availability branch remains: the phone's MAS
            // bearer and authenticated channel authorize the four owner writes.
            // Platform capability and operation state still gate each action.
            }
        }
    }

    private var moveButtonTitle: String {
        if busy { return copy.text(.working) }
        if preflight?.outcome == .ready { return copy.move(assistantName) }
        return copy.text(.reviewMove)
    }

    private func canAdvanceMove(_ value: AssistantHomeValue) -> Bool {
        guard !busy, selectedChoice != nil,
              progress.progress?.isTerminal != false else { return false }
        if let preflight {
            guard preflight.outcome == .ready else { return false }
            if case .disclosed = preflight.common.checkpointLoss { return acceptsCheckpointLoss }
        }
        return selectedHome != value.snapshot.placement.location
    }

    private struct Destination {
        let location: AgentHomeLocation
        let name: String
        let status: String?
        let enabled: Bool
    }

    private func destinations(_ value: AssistantHomeValue) -> [Destination] {
        var result = [Destination(location: .cloud, name: copy.text(.cloud), status: nil, enabled: true)]
        let waiting = value.snapshot.waitsForHomeMac
        let home = value.snapshot.placement.location
        result += value.snapshot.eligibleDevices.compactMap { device -> Destination? in
            let location = AgentHomeLocation.mac(device.deviceServiceID)
            // While the assistant's Mac is not answering the owner waits for it (or moves to the
            // cloud): no other Mac is offered, and that Mac itself is the one being waited for.
            if waiting, location != home { return nil }
            let status: String
            let enabled: Bool
            switch device.eligibility {
            case _ where waiting: status = copy.waitingForMac(device.displayName); enabled = true
            case .ready: status = copy.text(.available); enabled = true
            case let .unavailable(reason): status = copy.deviceUnavailable(reason); enabled = false
            }
            return Destination(location: location, name: device.displayName, status: status, enabled: enabled)
        }
        return result
    }

    private func selectHome(_ home: AgentHomeLocation, value: AssistantHomeValue) {
        guard selectedHome != home else { return }
        selectedHome = home
        selectedChoice = (try? value.legacyChoice(for: home)) ?? nil
        catalog = nil; catalogFailed = false
        resetMove()
        Task { await loadCatalogForSelection() }
    }

    private func choose(_ row: PhoneModelPickerProjection.Row, home: AgentHomeLocation,
                        value: AssistantHomeValue) {
        let choice: AgentHomeModelChoice?
        if home == .cloud {
            guard let offer = value.cloudModels.models.first(where: { $0.alias == row.model }) else { return }
            choice = try? AgentHomeModelChoice(home: .cloud, source: .atum,
                                               connectionRef: AgentHomeContract.managedConnectionRef,
                                               model: offer.alias,
                                               effort: AgentHomeModelEffort(rawValue: offer.defaultEffort.rawValue)!)
        } else {
            choice = try? catalog?.choice(connectionRef: row.connectionID, model: row.model)
        }
        guard let choice else { return }
        selectedChoice = choice
        resetMove()
        guard AgentHomeModelRoute.select(currentHome: value.snapshot.placement.location,
                                         selectedHome: home) == .currentHomeWrite else { return }
        saveCurrentModel(choice, value: value, rowID: row.stableID)
    }

    private func saveCurrentModel(_ choice: AgentHomeModelChoice,
                                  value: AssistantHomeValue, rowID: String) {
        guard modelSavingRowID == nil else { return }
        modelSavingRowID = rowID
        modelSaveFailed = false
        let identity = modelWrites.begin(ModelPayload(
            choice: choice, revision: value.choiceRevision, home: value.snapshot.placement.location,
            homeID: value.snapshot.placement.homeID, epoch: value.snapshot.placement.homeEpoch,
            activeMoveID: value.snapshot.placement.activeMove?.moveID
        ))
        Task { @MainActor in
            do {
                let input = try AgentHomeModelChoiceInput(
                    idempotencyKey: identity.idempotencyKey, agentPrincipal: value.snapshot.agentPrincipal,
                    currentHome: value.snapshot.placement.location,
                    expectedHomeID: value.snapshot.placement.homeID,
                    expectedHomeEpoch: value.snapshot.placement.homeEpoch,
                    expectedActiveMoveID: value.snapshot.placement.activeMove?.moveID,
                    expectedChoiceRevision: value.choiceRevision, choice: choice
                )
                switch await actions.writeModel(input, identity.requestID) {
                case let .success(.receipt(receipt)):
                    let application = await actions.application()
                    let applicationMatches = application?.choiceRevision == receipt.choiceRevision
                        && application?.choice == receipt.choice
                    let next = AssistantHomeValue(
                        snapshot: value.snapshot, destinations: value.destinations,
                        cloudModels: value.cloudModels, application: applicationMatches ? application : nil,
                        choiceOverride: receipt.choice,
                        pendingNextTurn: applicationMatches ? false : true
                    )
                    self.value = next
                    selectedChoice = receipt.choice
                    onValue(next)
                    modelWrites.settled()
                case .success(.refused):
                    modelSaveFailed = true; modelWrites.settled()
                    if case let .value(latest) = await actions.read() {
                        self.value = latest; selectedChoice = latest.currentChoice; onValue(latest)
                    }
                case let .failure(error):
                    modelSaveFailed = true
                    if AgentHomeOwnerWriteIdentity.isFinalAnswer(error) { modelWrites.settled() }
                }
            } catch { modelSaveFailed = true; modelWrites.settled() }
            modelSavingRowID = nil
        }
    }

    @MainActor private func load() async {
        loadFailed = false
        switch await actions.read() {
        case let .value(next):
            value = next; selectedHome = next.snapshot.placement.location
            selectedChoice = next.currentChoice; onValue(next)
            await loadCatalogForSelection()
        case .unavailable, .failed: loadFailed = true
        }
    }

    @MainActor private func loadCatalogForSelection() async {
        guard let deviceID = selectedHome?.deviceID else { catalog = nil; catalogFailed = false; return }
        catalogFailed = false
        switch await actions.catalog(deviceID) {
        case let .value(value):
            catalog = value
            if selectedChoice == nil,
               let destination = try? ManagedModelDestinationID("mac:" + deviceID.rawValue),
               let legacy = self.value?.destinations.choice(for: destination) {
                let matches = value.connections.flatMap { connection in
                    connection.models.compactMap { model -> (AgentHomeConnection, AgentHomeCatalogModel)? in
                        guard connection.source.managedDestinationSource == legacy.source,
                              model.model == legacy.model else { return nil }
                        return (connection, model)
                    }
                }
                if matches.count == 1 {
                    selectedChoice = try? value.choice(connectionRef: matches[0].0.connectionRef,
                                                       model: matches[0].1.model,
                                                       effort: AgentHomeModelEffort(rawValue: legacy.effort))
                }
            }
        case .unavailable, .failed: catalog = nil; catalogFailed = true
        }
    }

    @MainActor private func advanceMove(_ value: AssistantHomeValue) async {
        guard let target = selectedHome, let choice = selectedChoice else { return }
        if let preflight, preflight.outcome == .ready { await commit(value, preflight: preflight); return }
        busy = true; commandFailed = false
        do {
            let catalogRevision: Int64 = target == .cloud ? 0 : (catalog?.catalogRevision ?? -1)
            let identity = preflightWrites.begin(PreflightPayload(
                target: target, choice: choice, epoch: value.snapshot.placement.homeEpoch,
                activeMoveID: value.snapshot.placement.activeMove?.moveID,
                catalogRevision: catalogRevision
            ))
            let input = try AgentHomePreflightInput(
                idempotencyKey: identity.idempotencyKey, agentPrincipal: value.snapshot.agentPrincipal,
                target: target, chosenModel: choice,
                catalogRevision: catalogRevision,
                expectedHomeEpoch: value.snapshot.placement.homeEpoch,
                expectedActiveMoveID: value.snapshot.placement.activeMove?.moveID
            )
            switch await actions.preflight(input, identity.requestID) {
            case let .success(result): preflight = result; preflightWrites.settled()
            case let .failure(error):
                commandFailed = true
                if AgentHomeOwnerWriteIdentity.isFinalAnswer(error) { preflightWrites.settled() }
            }
        } catch { commandFailed = true; preflightWrites.settled() }
        busy = false
    }

    @MainActor private func commit(_ value: AssistantHomeValue,
                                   preflight: AgentHomeMovePreflight) async {
        guard let target = selectedHome, selectedChoice != nil else { return }
        busy = true; commandFailed = false
        do {
            let id = moveID ?? ModelWriteRequests<MovePayload>.freshID()
            moveID = id
            let acceptsLoss: Bool
            if case .disclosed = preflight.common.checkpointLoss { acceptsLoss = acceptsCheckpointLoss }
            else { acceptsLoss = false }
            let accepted = preflight.common.accepted
            let identity = moveWrites.begin(MovePayload(
                target: target, epoch: value.snapshot.placement.homeEpoch,
                activeMoveID: value.snapshot.placement.activeMove?.moveID,
                accepted: accepted, acceptsCheckpointLoss: acceptsLoss
            ))
            let input = try AgentHomeMoveInput(
                moveID: id, idempotencyKey: identity.idempotencyKey, agentPrincipal: value.snapshot.agentPrincipal,
                target: target, expectedHomeEpoch: value.snapshot.placement.homeEpoch,
                expectedActiveMoveID: value.snapshot.placement.activeMove?.moveID,
                acceptedPreflight: accepted,
                acceptCheckpointLoss: acceptsLoss
            )
            switch await actions.move(input, identity.requestID) {
            case let .success(.progress(next)):
                _ = progress.receive(next); moveWrites.settled()
                if !next.isTerminal {
                    pollTask?.cancel()
                    pollTask = Task { @MainActor in await poll(value, moveID: id) }
                }
                else { await finishIfReady(next) }
            case .success(.refused):
                commandFailed = true; moveWrites.settled(); self.preflight = nil
                acceptsCheckpointLoss = false; moveID = nil
            case let .failure(error):
                commandFailed = true
                if AgentHomeOwnerWriteIdentity.isFinalAnswer(error) { moveWrites.settled(); moveID = nil }
            }
        } catch { commandFailed = true; moveWrites.settled() }
        busy = false
    }

    /// Reads the move's progress on a backing-off cadence. A rate limit or a
    /// dropped connection says nothing about the move, so it only waits longer;
    /// the last record stays on screen and the move is never reported failed
    /// for it. Only an answer the platform means as final ends the loop.
    @MainActor private func poll(_ value: AssistantHomeValue, moveID: NativeID) async {
        var polling = AgentHomeProgressPolling()
        var delay = polling.delay(after: .started)
        while !Task.isCancelled, progress.progress?.isTerminal != true {
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            // A cancel or another read may have ended the move while this slept.
            guard progress.progress?.isTerminal != true else { return }
            switch await actions.progress(moveID) {
            case let .success(next):
                let changed = progress.receive(next)
                if changed, next.isTerminal { await finishIfReady(next); return }
                delay = polling.delay(after: changed ? .changed : .unchanged)
            case let .failure(error):
                switch AgentHomeProgressPolling.classify(error) {
                case .cancelled: return
                case .definitive: commandFailed = true; return
                case .transient: delay = polling.delay(after: .transientFailure)
                case let .rateLimited(retryAfter): delay = polling.delay(after: .rateLimited(retryAfter: retryAfter))
                }
            }
        }
    }

    @MainActor private func cancel(_ value: AssistantHomeValue) async {
        guard let moveID = progress.progress?.moveID ?? moveID else { return }
        busy = true; commandFailed = false
        do {
            let cancelID = self.cancelID ?? ModelWriteRequests<CancelPayload>.freshID()
            self.cancelID = cancelID
            let identity = cancelWrites.begin(CancelPayload(
                moveID: moveID, epoch: value.snapshot.placement.homeEpoch
            ))
            let input = try AgentHomeCancelInput(cancelID: cancelID, idempotencyKey: identity.idempotencyKey,
                                                 agentPrincipal: value.snapshot.agentPrincipal,
                                                 moveID: moveID,
                                                 expectedHomeEpoch: value.snapshot.placement.homeEpoch,
                                                 expectedActiveMoveID: moveID)
            switch await actions.cancel(input, identity.requestID) {
            case let .success(.progress(next)):
                _ = progress.receive(next); self.cancelID = nil; cancelWrites.settled()
                if next.isTerminal { pollTask?.cancel(); pollTask = nil }
            case let .success(.refused(refusal)):
                self.cancelID = nil; cancelWrites.settled()
                if refusal.reason == .committedEpochPreserved {
                    pollTask?.cancel()
                    pollTask = Task { @MainActor in await poll(value, moveID: moveID) }
                } else { commandFailed = true }
            case let .failure(error):
                commandFailed = true
                if AgentHomeOwnerWriteIdentity.isFinalAnswer(error) { self.cancelID = nil; cancelWrites.settled() }
            }
        } catch { commandFailed = true; self.cancelID = nil; cancelWrites.settled() }
        busy = false
    }

    @MainActor private func finishIfReady(_ final: AgentHomeMoveProgress) async {
        guard final.state == .ready else { return }
        switch await actions.read() {
        case let .value(next): value = next; selectedHome = next.snapshot.placement.location
            selectedChoice = next.currentChoice; onValue(next)
        case .unavailable, .failed: break
        }
    }

    private func resetMove() {
        pollTask?.cancel(); pollTask = nil
        preflight = nil; progress = AgentHomeProgressTracker(); acceptsCheckpointLoss = false
        commandFailed = false; preflightWrites.settled(); moveWrites.settled(); moveID = nil
        cancelWrites.settled(); cancelID = nil
    }
}

// MARK: - Phone-owned fallbacks pending atum-app export

@MainActor
private struct AgentHomeCopy {
    enum Key: String, CaseIterable {
        case title = "agentHome.title", livesOn = "agentHome.livesOn", livesOnLoading = "agentHome.livesOnLoading"
        case move = "agentHome.move", model = "agentHome.model", loading = "agentHome.loading"
        case movesUnavailable = "agentHome.movesUnavailable", loadFailed = "agentHome.loadFailed"
        case retry = "agentHome.retry", close = "agentHome.close", chooseHome = "agentHome.chooseHome"
        case chooseModel = "agentHome.chooseModel", cloud = "agentHome.cloud", available = "agentHome.available"
        case cloudPlace = "agentHome.cloudPlace"
        case selected = "agentHome.selected", notSelected = "agentHome.notSelected"
        case catalogUnavailable = "agentHome.catalogUnavailable", catalogStale = "agentHome.catalogStale"
        case actualLosses = "agentHome.actualLosses", noLosses = "agentHome.noLosses"
        case acceptCheckpointLoss = "agentHome.acceptCheckpointLoss", status = "agentHome.status"
        case modelNextTurn = "agentHome.modelNextTurn", commandFailed = "agentHome.commandFailed"
        case modelSaveFailed = "agentHome.modelSaveFailed", cancelMove = "agentHome.cancelMove"
        case working = "agentHome.working"
        case reviewMove = "agentHome.reviewMove"
    }

    let design: LiveDesign
    private var locale: String { design.locale }
    private var vi: Bool { locale == "vi" }

    func text(_ key: Key) -> String {
        if let export = exportKey(key), design.copy.contains(export) { return design.text(export) }
        return switch (vi, key) {
        case (false, .title): "Where it lives"; case (true, .title): "Trợ lý đang ở đâu"
        case (false, .livesOn): "Lives on"; case (true, .livesOn): "Đang ở trên"
        case (false, .livesOnLoading): "Lives on: Loading…"; case (true, .livesOnLoading): "Đang ở trên: Đang tải…"
        case (false, .move): "Move"; case (true, .move): "Chuyển"
        case (false, .model): "Model"; case (true, .model): "Mô hình"
        case (false, .loading): "Loading…"; case (true, .loading): "Đang tải…"
        case (false, .movesUnavailable): "Move is not available yet"; case (true, .movesUnavailable): "Chưa thể chuyển"
        case (false, .loadFailed): "Couldn’t load the current home"; case (true, .loadFailed): "Không tải được nhà hiện tại"
        case (false, .retry): "Try again"; case (true, .retry): "Thử lại"
        case (false, .close): "Close"; case (true, .close): "Đóng"
        case (false, .chooseHome): "Home"; case (true, .chooseHome): "Nhà"
        case (false, .chooseModel): "Choose model"; case (true, .chooseModel): "Chọn mô hình"
        case (false, .cloud): "the cloud"; case (true, .cloud): "đám mây"
        case (false, .cloudPlace): "The cloud"; case (true, .cloudPlace): "Đám mây"
        case (false, .available): "Available"; case (true, .available): "Sẵn sàng"
        case (false, .selected): "Selected"; case (true, .selected): "Đã chọn"
        case (false, .notSelected): "Not selected"; case (true, .notSelected): "Chưa chọn"
        case (false, .catalogUnavailable): "This Mac’s models aren’t available"; case (true, .catalogUnavailable): "Mô hình trên máy Mac này chưa sẵn sàng"
        case (false, .catalogStale): "Reconnect this Mac before moving"; case (true, .catalogStale): "Kết nối lại máy Mac này trước khi chuyển"
        case (false, .actualLosses): "What will not move"; case (true, .actualLosses): "Những gì sẽ không được chuyển"
        case (false, .noLosses): "Everything supported moves with this assistant."
        case (true, .noLosses): "Mọi nội dung được hỗ trợ sẽ đi cùng trợ lý này."
        case (false, .acceptCheckpointLoss): "I accept losing changes since this checkpoint"
        case (true, .acceptCheckpointLoss): "Tôi chấp nhận mất thay đổi kể từ điểm lưu này"
        case (false, .status): "Status"; case (true, .status): "Trạng thái"
        case (false, .modelNextTurn): "The model applies on the next turn"; case (true, .modelNextTurn): "Mô hình áp dụng từ lượt tiếp theo"
        case (false, .commandFailed): "The move didn’t complete. The current home is unchanged."
        case (true, .commandFailed): "Chưa chuyển xong. Nhà hiện tại không đổi."
        case (false, .modelSaveFailed): "The model wasn’t saved"; case (true, .modelSaveFailed): "Chưa lưu mô hình"
        case (false, .cancelMove): "Cancel move"; case (true, .cancelMove): "Hủy chuyển"
        // agent-home/2.5 removed the phone signer-unavailable state.
        // Write failures continue through the ordinary command error copy.
        case (false, .working): "Moving…"; case (true, .working): "Đang chuyển…"
        case (false, .reviewMove): "Review move"; case (true, .reviewMove): "Xem trước khi chuyển"
        }
    }

    private func exportKey(_ key: Key) -> String? {
        let name: String? = switch key {
        case .title: "title"
        case .livesOn: "livesOn"
        case .move: "move"
        case .model: "model"
        case .cloud: "cloud"
        case .cloudPlace: "cloudPlace"
        case .actualLosses: "actualLosses"
        case .noLosses: "noLosses"
        case .reviewMove: "reviewMove"
        case .cancelMove: "cancel"
        case .working: "moving"
        default: nil
        }
        return name.map { "src.matrix.agent-home-copy.words." + $0 }
    }

    func summary(home: String, provider: String?, model: String?) -> String {
        if let provider, let model {
            let key = "src.matrix.agent-home-copy.words.summary"
            if design.copy.contains(key) {
                return design.text(key, arguments: [.text(home), .text(provider), .text(model)])
            }
        }
        var parts = [(vi ? "Đang ở trên: " : "Lives on: ") + home]
        if let provider { parts.append((vi ? "Mô hình: " : "Model: ") + provider) }
        if let model { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    func move(_ name: String) -> String { vi ? "Chuyển \(name)" : "Move \(name)" }

    func provider(_ source: AgentHomeModelSource) -> String {
        switch source { case .atum: "Atum"; case .chatGPTPlan: "ChatGPT"; case let .ownKey(name): name }
    }

    func homeName(_ home: AgentHomeLocation, snapshot: AgentHomeSnapshot) -> String {
        switch home {
        case .cloud: text(.cloud)
        case let .mac(id): snapshot.device(id)?.displayName ?? (vi ? "Máy Mac" : "Mac")
        }
    }

    /// The card row's value: a place standing alone, never mid-sentence.
    func placeName(_ home: AgentHomeLocation, snapshot: AgentHomeSnapshot) -> String {
        switch home {
        case .cloud: text(.cloudPlace)
        case let .mac(id): snapshot.device(id)?.displayName ?? (vi ? "Máy Mac" : "Mac")
        }
    }

    func modelName(_ choice: AgentHomeModelChoice, cloudModels: ManagedModelSnapshot,
                   catalog: AgentHomeMacCatalog?) -> String {
        if choice.source == .atum,
           let offer = cloudModels.models.first(where: { $0.alias == choice.model }) { return offer.displayName }
        return catalog?.connections.first(where: { $0.connectionRef == choice.connectionRef })?
            .models.first(where: { $0.model == choice.model })?.label ?? choice.model
    }

    func application(_ value: AgentHomeModelApplication, home: String) -> String {
        switch value.status {
        case .applied: return vi ? "Đã áp dụng" : "Applied"
        case .pending:
            let key = "src.matrix.agent-home-copy.words.waitingForMac"
            if design.copy.contains(key) { return design.text(key, arguments: [.text(home)]) }
            return vi ? "Đang chờ \(home)" : "Waiting for \(home)"
        case .unavailable: return vi ? "Đang chờ kết nối trên máy Mac" : "Waiting for the Mac connection"
        }
    }

    func connectionNeedsAttention(provider: String, home: String) -> String {
        vi ? "Kết nối \(provider) trên \(home)" : "Connect \(provider) on \(home)"
    }

    func reachability(_ value: AgentHomeReachability) -> String {
        switch (vi, value.state) {
        case (false, "reachable"): "Available"; case (true, "reachable"): "Sẵn sàng"
        case (false, "asleep"): "Asleep"; case (true, "asleep"): "Đang ngủ"
        default: vi ? "Ngoại tuyến" : "Offline"
        }
    }

    func deviceUnavailable(_ reason: AgentHomeNamedDevice.Eligibility.Reason) -> String {
        switch (vi, reason) {
        case (false, .offline): "Offline"; case (true, .offline): "Ngoại tuyến"
        case (false, .versionUnsupported): "Update required"; case (true, .versionUnsupported): "Cần cập nhật"
        case (false, .homeConflict): "Home conflict"; case (true, .homeConflict): "Xung đột nhà"
        // A Mac the platform does not list as ready has no active set-up for this assistant (or it lapsed), and
        // only that Mac can fix it: say what to do, in the owner's language, not just that models are missing.
        case (_, .notEnrolled), (_, .catalogUnavailable):
            AgentHomePlacementCopy.text(.openAtumOnMac, locale: locale)
        }
    }

    /// The short row status for the Mac the assistant is waiting on.
    func waitingForMac(_ name: String) -> String {
        AgentHomePlacementCopy.text(.waitingForMac, locale: locale, name: name)
    }

    /// The note under "Lives on" while that Mac is not answering.
    func waitingForHome(homeName: String) -> String {
        AgentHomePlacementCopy.text(.waitingForHome, locale: locale, name: homeName)
    }

    func loss(_ loss: AgentHomeFeatureLoss) -> String {
        let export = "src.matrix.agent-home-copy.words.losses." + loss.rawValue
        if design.copy.contains(export) { return design.text(export) }
        let en: [AgentHomeFeatureLoss: String] = [
            .googleProtectedRoute: "Protected Google access on the current home",
            .protectedPrivateSkill: "A private skill that cannot be exported",
            .cloudBrowserSession: "Cloud browser sessions", .cloudComputer: "Cloud computer access",
            .drivePublication: "Drive publication from the current home",
            .routineExecution: "Routines that only run on the current home",
            .pushDelivery: "Push delivery from the current home",
            .changesSinceLastCheckpointLost: "Changes since the last checkpoint",
            .modelSourceChangesToAtum: "The current Mac connection; cloud uses an Atum model",
            .localToolsUnavailable: "Tools installed only on this Mac",
            .localFilesUnavailable: "Files stored only on this Mac",
            .localBrowserSessionsUnavailable: "Browser sessions stored only on this Mac",
            .conversationOverridesCleared: "Conversation-specific model choices",
        ]
        let viText: [AgentHomeFeatureLoss: String] = [
            .googleProtectedRoute: "Quyền truy cập Google được bảo vệ ở nơi hiện tại",
            .protectedPrivateSkill: "Một kỹ năng riêng tư không thể xuất",
            .cloudBrowserSession: "Các phiên trình duyệt trên đám mây",
            .cloudComputer: "Quyền dùng máy tính đám mây",
            .drivePublication: "Đăng lên Drive từ nơi hiện tại",
            .routineExecution: "Các lịch việc chỉ chạy ở nơi hiện tại",
            .pushDelivery: "Thông báo đẩy từ nơi hiện tại",
            .changesSinceLastCheckpointLost: "Các thay đổi kể từ điểm lưu gần nhất",
            .modelSourceChangesToAtum: "Kết nối trên Mac hiện tại; đám mây dùng mô hình Atum",
            .localToolsUnavailable: "Công cụ chỉ được cài trên máy Mac này",
            .localFilesUnavailable: "Tệp chỉ được lưu trên máy Mac này",
            .localBrowserSessionsUnavailable: "Phiên trình duyệt chỉ được lưu trên máy Mac này",
            .conversationOverridesCleared: "Lựa chọn mô hình riêng của từng cuộc trò chuyện",
        ]
        return (vi ? viText : en)[loss]!
    }

    func checkpoint(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
        return (vi ? "Điểm lưu gần nhất: " : "Last checkpoint: ") + date.formatted(date: .abbreviated, time: .shortened)
    }

    func blocked(_ reason: AgentHomeMovePreflight.BlockReason?, target: AgentHomeLocation? = nil) -> String {
        guard let reason else { return text(.commandFailed) }
        // The platform says `target_unavailable` for a Mac that has no active set-up for the assistant (never for
        // the cloud); its closed reasons have no word for that, so this client says it plainly.
        if reason == .targetUnavailable, target?.deviceID != nil {
            return AgentHomePlacementCopy.text(.macNotSetUp, locale: locale)
        }
        return switch (vi, reason) {
        case (false, .targetUnavailable): "The destination is unavailable"
        case (true, .targetUnavailable): "Đích đến chưa sẵn sàng"
        case (false, .connectionUnavailable): "The selected connection is unavailable"
        case (true, .connectionUnavailable): "Kết nối đã chọn chưa sẵn sàng"
        case (false, .catalogStale): "Reconnect the Mac and try again"
        case (true, .catalogStale): "Kết nối lại máy Mac rồi thử lại"
        case (false, .notEligible): "This agent can’t move there"
        case (true, .notEligible): "Trợ lý này không thể chuyển đến đó"
        case (false, .unknownExportClass): "Some home data can’t be moved safely"
        case (true, .unknownExportClass): "Một số dữ liệu nhà chưa thể chuyển an toàn"
        case (false, .cloudControllerVersionUnsupported): "The cloud home needs an update"
        case (true, .cloudControllerVersionUnsupported): "Nhà đám mây cần được cập nhật"
        }
    }

    func progress(_ value: AgentHomeMoveProgress, snapshot: AgentHomeSnapshot) -> String {
        let target = homeName(value.target, snapshot: snapshot)
        let export = "src.matrix.agent-home-copy.words.progress." + value.state.rawValue
        if design.copy.contains(export) {
            let arguments: [AtumCopy.Argument] = [.waitingForDestination, .ready].contains(value.state)
                ? [.text(target)] : []
            return design.text(export, arguments: arguments)
        }
        switch value.state {
        case .finishingCurrentWork: return vi ? "Đang hoàn thành công việc hiện tại" : "Finishing current work"
        case .moving: return vi ? "Đang chuyển" : "Moving"
        case .waitingForDestination: return vi ? "Đang chờ \(target)" : "Waiting for \(target)"
        case .reconciling: return vi ? "Đang kiểm tra việc chuyển" : "Checking the move"
        case .ready: return vi ? "Sẵn sàng trên \(target)" : "Ready on \(target)"
        case .failed: return vi ? "Việc chuyển chưa hoàn tất" : "Move did not finish"
        }
    }

    func failure(_ value: AgentHomeMoveProgress, snapshot: AgentHomeSnapshot) -> String {
        let current = homeName(value.authoritativeHome, snapshot: snapshot)
        let reason: String
        switch value.failureReason {
        case .targetUnavailable: reason = vi ? "Đích đến chưa sẵn sàng" : "Destination unavailable"
        case .destinationUnreachable: reason = vi ? "Đã chuyển nhưng chưa kết nối được đích đến" : "Moved, but the destination is unreachable"
        case .sourceUnreachable: reason = vi ? "Không liên lạc được nhà cũ" : "The current home is unreachable"
        case .modelUnavailable: reason = vi ? "Mô hình đã chọn chưa sẵn sàng" : "The selected model is unavailable"
        case .ownerCancelled: reason = vi ? "Đã hủy" : "Cancelled"
        default: reason = vi ? "Không thể hoàn tất việc chuyển" : "The move could not finish"
        }
        return reason + " · " + (vi ? "Nhà hiện tại: " : "Current home: ") + current
    }
}
