import AtumChat
import AtumDesign
import AtumNativeAPI
import SwiftUI

/// The cloud's subscription models: the account status the desktop reads for a
/// cloud assistant (relay and provider connections) and the 1.4 / 1.5 write
/// it sends (`chooseRoute`, `model-picker.tsx`). No credential, device name or
/// sign-in crosses: connecting a plan stays where the desktop does it.
struct AssistantSubscriptionActions {
    let read: () async -> PhoneSubscriptionAccount
    let save: (ManagedModelDestinationSnapshot, ManagedModelDestinationSource, String, ManagedModelEffort,
               NativeID) async -> AssistantModelDestinationSaveResult
}

/// One subscription pick, for an idempotent retry of the same write.
private struct SubscriptionWrite: Hashable, Sendable {
    let connection: String
    let model: String
    let revision: Int64
}

/// The composer's model picker and the assistant card's destination picker.
/// Each loads its decoded model-choice snapshot, projects it to rows
/// and saves a pick; `PhoneModelPickerList` draws the rows (T3-style layout).
/// Rows come only from decoded model-choice contracts; these views own no
/// provider discovery, account identity, credential, or remote Mac route.
struct PhoneConversationModelPicker: View {
    let design: LiveDesign
    /// The 1.1 offer: eligibility and thinking levels. Optional so the picker
    /// survives an unavailable legacy read.
    let actions: AssistantModelActions?
    /// The 1.3/1.4 destination defaults and the connected subscription choice.
    let destinations: AssistantModelDestinationActions?
    var initialSnapshot: ManagedModelSnapshot?
    var initialDestination: ManagedModelDestinationSnapshot?
    var onSnapshot: (ManagedModelSnapshot) -> Void = { _ in }
    var onDestination: (ManagedModelDestinationSnapshot) -> Void = { _ in }
    var onPick: (String) -> Void = { _ in }

    @State private var snapshot: ManagedModelSnapshot?
    @State private var destination: ManagedModelDestinationSnapshot?
    /// The cloud aliases the 1.1 offer says are usable now, when it answered.
    @State private var cloudEligibleAliases: Set<String>?
    @State private var loading = false
    @State private var unavailable = false
    @State private var loadFailed = false
    @State private var savingRowID: String?
    /// The Atum row a successful 1.1 pick wrote, so the check follows the
    /// write even before a new 1.3 read returns.
    @State private var pickedAtumModel: String?
    @State private var savingEffort: ManagedModelEffort?
    @State private var saveFailed = false
    /// The idempotency key of the write whose outcome may be unknown, kept with
    /// the payload it belongs to.
    @State private var writes = ModelWriteRequests<ConversationModelWrite>()
    @State private var destinationWrites = ModelWriteRequests<ConversationDestinationWrite>()
    /// What the account's subscriptions can run in the cloud now; nil until read.
    @State private var account: PhoneSubscriptionAccount?
    @State private var subscriptionWrites = ModelWriteRequests<SubscriptionWrite>()

    private struct ConversationModelWrite: Hashable, Sendable {
        let model: String
        let effort: ManagedModelEffort
        /// The fence the write was made against.
        let revision: Int64
    }

    /// A pick made when only the 1.3/1.4 destination read is available.
    private struct ConversationDestinationWrite: Hashable, Sendable {
        let model: String
        let revision: Int64
    }

    init(design: LiveDesign,
         actions: AssistantModelActions?,
         destinations: AssistantModelDestinationActions?,
         initialSnapshot: ManagedModelSnapshot? = nil,
         initialDestination: ManagedModelDestinationSnapshot? = nil,
         onSnapshot: @escaping (ManagedModelSnapshot) -> Void = { _ in },
         onDestination: @escaping (ManagedModelDestinationSnapshot) -> Void = { _ in },
         onPick: @escaping (String) -> Void = { _ in }) {
        self.design = design
        self.actions = actions
        self.destinations = destinations
        self.initialSnapshot = initialSnapshot
        self.initialDestination = initialDestination
        self.onSnapshot = onSnapshot
        self.onDestination = onDestination
        self.onPick = onPick
        _snapshot = State(initialValue: initialSnapshot)
        _destination = State(initialValue: initialDestination)
    }

    private var rows: [PhoneModelPickerProjection.Row] {
        let atum = PhoneModelPickerProjection.conversation(
            offer: snapshot, destination: destination, destinationID: cloudDestination,
            cloudEligibleAliases: cloudEligibleAliases,
            selectedAtumModel: pickedAtumModel
        )
        let subscriptions = destination.map {
            PhoneModelPickerProjection.subscriptions($0, destination: cloudDestination, account: account)
        }?.map { pickedAtumModel == nil ? $0 : $0.selecting(false) } ?? []
        return atum + subscriptions
    }

    var body: some View {
        Group {
            if !rows.isEmpty {
                PhoneModelPickerList(
                    design: design,
                    matrixAccountID: actions?.matrixAccountID ?? destinations?.matrixAccountID ?? "",
                    destinationID: cloudDestination.rawValue,
                    rows: rows,
                    context: .conversation,
                    savingRowID: savingRowID,
                    saveFailed: saveFailed,
                    // Atum's levels only while Atum answers: changing one writes an Atum model.
                    thinking: subscriptionAnswers ? nil
                        : snapshot.flatMap(PhoneModelPickerProjection.thinking),
                    savingEffort: savingEffort,
                    selectEffort: chooseEffort,
                    select: choose
                )
            } else if unavailable {
                ContentUnavailableView(copy(.modelsUnavailable), image: symbol(.globe))
            } else if loadFailed {
                ContentUnavailableView {
                    Label(copy(.modelsFailed), image: symbol(.alertCircle))
                } actions: {
                    Button(copy(.modelsRetry)) { Task { await load(force: true) } }
                }
            } else {
                ProgressView().accessibilityIdentifier("assistant.model.loading")
            }
        }
        .navigationTitle(phoneCopy(.title))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(force: false) }
    }

    @MainActor private func load(force: Bool) async {
        guard !loading, force || snapshot == nil || destination == nil else { return }
        loading = true
        unavailable = false
        loadFailed = false
        let offer: AssistantModelLoadResult? = if let actions { await actions.read() } else { nil }
        let defaults: AssistantModelDestinationLoadResult? =
            if let destinations { await destinations.read() } else { nil }
        let subscriptionAccount: PhoneSubscriptionAccount? =
            if let read = destinations?.subscriptions?.read { await read() } else { nil }
        guard !Task.isCancelled else { return }
        if let subscriptionAccount { account = subscriptionAccount }
        loading = false

        var anyValue = false
        if let offer {
            switch offer {
            case let .value(value):
                apply(value)
                anyValue = true
            case .unavailable, .failed: break
            }
        }
        if let defaults {
            switch defaults {
            case let .value(value):
                applyDestination(value.snapshot)
                cloudEligibleAliases = value.cloudEligibleAliases
                anyValue = true
            case .unavailable, .failed: break
            }
        }
        if !anyValue {
            unavailable = offer?.isUnavailable == true || defaults?.isUnavailable == true
            loadFailed = !unavailable
        }
    }

    private func choose(_ row: PhoneModelPickerProjection.Row) {
        if row.isSubscription { return chooseSubscription(row) }
        let model = row.model
        guard savingRowID == nil, savingEffort == nil, row.source == .atum,
              row.selectable, !row.selected else { return }
        if let snapshot, let offer = snapshot.models.first(where: { $0.alias == model }) {
            guard offer.eligibility == .ready else { return }
            savingRowID = row.stableID
            save(snapshot, model: model, effort: offer.defaultEffort)
            return
        }
        guard destinations != nil, let destination else { return }
        savingRowID = row.stableID
        saveDestination(destination, model: model)
    }

    /// A thinking-level change writes the model that answers now with the new
    /// level: the same fenced save a model pick makes.
    private func chooseEffort(_ level: ManagedModelEffort) {
        guard savingRowID == nil, savingEffort == nil, let snapshot,
              PhoneModelPickerProjection.canChangeThinking(to: level, snapshot: snapshot) else { return }
        savingEffort = level
        save(snapshot, model: snapshot.choice.model, effort: level)
    }

    private func save(_ snapshot: ManagedModelSnapshot, model: String, effort: ManagedModelEffort) {
        guard let actions else { return }
        saveFailed = false
        // The same ID only for an identical retry; a different pick gets its own.
        let operation = writes.begin(ConversationModelWrite(model: model, effort: effort,
                                                            revision: snapshot.revision))
        Task { @MainActor in
            let result = await actions.save(snapshot, model, effort, operation)
            guard !Task.isCancelled else { return }
            savingRowID = nil
            savingEffort = nil
            switch result {
            case let .saved(value):
                pickedAtumModel = model
                onPick(model)
                apply(value)
                writes.settled()
            case let .conflict(latest):
                if let latest { apply(latest) }
                saveFailed = true
                writes.settled()
            case .failed:
                // The provider may have received it. Keep the key with its
                // payload so an identical explicit retry is an idempotent replay.
                saveFailed = true
            }
        }
    }

    /// The 1.3/1.4 fallback write, used only when no 1.1 offer could be read.
    /// The destination write keeps the server's recommendation effort.
    private func saveDestination(_ snapshot: ManagedModelDestinationSnapshot, model: String) {
        guard let destinations else { return }
        saveFailed = false
        let operation = destinationWrites.begin(ConversationDestinationWrite(
            model: model, revision: snapshot.revision
        ))
        Task { @MainActor in
            let result = await destinations.save(snapshot, cloudDestination, model, operation)
            guard !Task.isCancelled else { return }
            savingRowID = nil
            switch result {
            case let .saved(value):
                pickedAtumModel = model
                onPick(model)
                applyDestination(value)
                destinationWrites.settled()
            case let .refused(latest):
                if let latest { applyDestination(latest) }
                saveFailed = true
                destinationWrites.settled()
            }
        }
    }

    /// A subscription pick writes the cloud destination (1.4 / 1.5), as the
    /// desktop's cloud picker does. Only the server's answer moves the check.
    private func chooseSubscription(_ row: PhoneModelPickerProjection.Row) {
        guard savingRowID == nil, savingEffort == nil, let destination,
              let save = destinations?.subscriptions?.save,
              let effort = PhoneModelPickerProjection.canSelectSubscription(
                  row, snapshot: destination, account: account) else { return }
        savingRowID = row.stableID
        saveFailed = false
        let operation = subscriptionWrites.begin(SubscriptionWrite(
            connection: row.connectionID, model: row.model, revision: destination.revision))
        Task { @MainActor in
            let result = await save(destination, row.source, row.model, effort, operation)
            guard !Task.isCancelled else { return }
            savingRowID = nil
            switch result {
            case let .saved(value):
                pickedAtumModel = nil
                // The chip names the subscription model as it names a saved one.
                onPick(row.model)
                applyDestination(value)
                subscriptionWrites.settled()
            case let .refused(latest):
                if let latest {
                    applyDestination(latest)
                    subscriptionWrites.settled()
                }
                saveFailed = true
                // A relay that went down or a disconnected plan shows as such now.
                if let read = destinations?.subscriptions?.read { account = await read() }
            }
        }
    }

    /// The cloud answers with a subscription's model, so no Atum level applies.
    private var subscriptionAnswers: Bool {
        pickedAtumModel == nil && destination?.choice(for: cloudDestination)?.source.isSubscription == true
    }

    private func apply(_ value: ManagedModelSnapshot) {
        snapshot = value
        unavailable = false
        loadFailed = false
        saveFailed = false
        onSnapshot(value)
    }

    private func applyDestination(_ value: ManagedModelDestinationSnapshot) {
        destination = value
        unavailable = false
        loadFailed = false
        saveFailed = false
        onDestination(value)
    }

    private var cloudDestination: ManagedModelDestinationID {
        try! ManagedModelDestinationID("cloud")
    }

    private func copy(_ key: PhonePickerCopyKey) -> String { design.text(key.rawValue) }
    private func phoneCopy(_ key: PhoneModelPickerStateCopyKey) -> String { design.text(key.rawValue) }
    private func symbol(_ glyph: AtumGlyph) -> String { AtumVisualSystem(design: design).symbol(glyph) }
}

private extension AssistantModelLoadResult {
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

private extension AssistantModelDestinationLoadResult {
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

extension ManagedModelDestinationSnapshot {
    /// Cloud-only, as on desktop (`cardModelChoice`): the card edits the model
    /// of the place that answers now, and that is the cloud. The snapshot keeps
    /// its Mac entries for older desktops; the phone does not draw them. A
    /// not-yet-moved Mac home changes its model from the Lives on sheet.
    var cardDestination: ManagedModelDestinationID { try! ManagedModelDestinationID("cloud") }
}

/// The card's Model page when only the 1.3/1.4 destination read is available:
/// the one picker for the destination that answers now.
struct PhoneModelDestinationsPicker: View {
    let design: LiveDesign
    let actions: AssistantModelDestinationActions

    @State private var value: AssistantModelDestinationValue?
    @State private var loading = false
    @State private var unavailable = false
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let value {
                PhoneDestinationModelPicker(design: design, actions: actions, value: value,
                                            destination: value.snapshot.cardDestination,
                                            onValue: { self.value = $0 })
            } else if unavailable {
                ContentUnavailableView(copy(.modelsUnavailable), image: symbol(.globe))
            } else if loadFailed {
                ContentUnavailableView {
                    Label(copy(.modelsFailed), image: symbol(.alertCircle))
                } actions: {
                    Button(copy(.modelsRetry)) { Task { await load() } }
                }
            } else {
                ProgressView().accessibilityIdentifier("assistant.model.destinations.loading")
            }
        }
        .navigationTitle(design.text("desktop.atum.settings.model"))
        .navigationBarTitleDisplayMode(.inline)
        .task { if value == nil, !loading { await load() } }
    }

    @MainActor private func load() async {
        loading = true
        unavailable = false
        loadFailed = false
        let result = await actions.read()
        guard !Task.isCancelled else { return }
        loading = false
        switch result {
        case let .value(next): value = next
        case .unavailable: unavailable = true
        case .failed: loadFailed = true
        }
    }

    private func copy(_ key: PhonePickerCopyKey) -> String { design.text(key.rawValue) }
    private func symbol(_ glyph: AtumGlyph) -> String { AtumVisualSystem(design: design).symbol(glyph) }
}

private struct PhoneDestinationModelPicker: View {
    let design: LiveDesign
    let actions: AssistantModelDestinationActions
    @State var value: AssistantModelDestinationValue
    let destination: ManagedModelDestinationID
    let onValue: (AssistantModelDestinationValue) -> Void

    @State private var savingRowID: String?
    @State private var saveFailed = false
    @State private var writes = ModelWriteRequests<DestinationModelWrite>()
    @State private var account: PhoneSubscriptionAccount?
    @State private var subscriptionWrites = ModelWriteRequests<SubscriptionWrite>()

    private struct DestinationModelWrite: Hashable, Sendable {
        let destination: String
        let model: String
    }

    var body: some View {
        PhoneModelPickerList(
            design: design,
            matrixAccountID: actions.matrixAccountID,
            destinationID: destination.rawValue,
            rows: rows,
            context: destination.isCloud ? .cloudAssistant : .mac,
            savingRowID: savingRowID,
            saveFailed: saveFailed,
            select: choose
        )
        .task {
            if let read = actions.subscriptions?.read { account = await read() }
        }
    }

    private var rows: [PhoneModelPickerProjection.Row] {
        let atum = PhoneModelPickerProjection.destination(
            value.snapshot,
            destination: destination,
            cloudEligibleAliases: value.cloudEligibleAliases
        )
        guard destination.isCloud else { return atum }
        return atum + PhoneModelPickerProjection.subscriptions(value.snapshot, destination: destination,
                                                               account: account)
    }

    private func choose(_ row: PhoneModelPickerProjection.Row) {
        if row.isSubscription { return chooseSubscription(row) }
        guard savingRowID == nil,
              PhoneModelPickerProjection.canSelectAtumModel(
                  row.model,
                  snapshot: value.snapshot,
                  destination: destination,
                  cloudEligibleAliases: value.cloudEligibleAliases
              ) else { return }
        savingRowID = row.stableID
        saveFailed = false
        let operation = writes.begin(DestinationModelWrite(destination: destination.rawValue,
                                                           model: row.model))
        Task { @MainActor in
            let result = await actions.save(value.snapshot, destination, row.model, operation)
            guard !Task.isCancelled else { return }
            savingRowID = nil
            switch result {
            case let .saved(snapshot):
                value.snapshot = snapshot
                saveFailed = false
                writes.settled()
                onValue(value)
            case let .refused(latest):
                if let latest {
                    // A conflict carries the authoritative snapshot: settled.
                    value.snapshot = latest
                    writes.settled()
                    onValue(value)
                }
                // Without it the outcome is unknown; an identical retry replays.
                saveFailed = true
            }
        }
    }

    /// The same 1.4 / 1.5 cloud write as the composer's picker.
    private func chooseSubscription(_ row: PhoneModelPickerProjection.Row) {
        guard savingRowID == nil, destination.isCloud, let save = actions.subscriptions?.save,
              let effort = PhoneModelPickerProjection.canSelectSubscription(
                  row, snapshot: value.snapshot, account: account) else { return }
        savingRowID = row.stableID
        saveFailed = false
        let operation = subscriptionWrites.begin(SubscriptionWrite(
            connection: row.connectionID, model: row.model, revision: value.snapshot.revision))
        Task { @MainActor in
            let result = await save(value.snapshot, row.source, row.model, effort, operation)
            guard !Task.isCancelled else { return }
            savingRowID = nil
            switch result {
            case let .saved(snapshot):
                value.snapshot = snapshot
                saveFailed = false
                subscriptionWrites.settled()
                onValue(value)
            case let .refused(latest):
                if let latest {
                    value.snapshot = latest
                    subscriptionWrites.settled()
                    onValue(value)
                }
                saveFailed = true
                if let read = actions.subscriptions?.read { account = await read() }
            }
        }
    }
}
