import AtumChat
import AtumDesign
import AtumNativeAPI
import SwiftUI

/// The cloud's subscription models: the account status the desktop reads for a
/// cloud assistant (relay and provider connections) and the 1.4 / 1.5 write
/// it sends (`chooseRoute`, `model-picker.tsx`). No credential, device name or
/// sign-in crosses: connecting a plan stays where the desktop does it.
struct AssistantSubscriptionActions {
    let read: PhoneSubscriptionAccountReads
    /// The consent decision is what a ChatGPT write is made
    /// under (nil for any other plan); the save re-checks it before an
    /// automatic retry and after a refusal. The selection must remain live for each send.
    let save: @MainActor (ManagedModelDestinationSnapshot, ManagedModelDestinationSource, String, ManagedModelEffort,
                          NativeID, ChatGPTTrainingConsent?, @escaping @MainActor () -> Bool) async
        -> AssistantModelDestinationSaveResult
    /// The one-time training-off confirmation a ChatGPT pick needs first.
    /// Without it a ChatGPT pick is never written (`ChatGPTTrainingGate`).
    var training: ChatGPTTrainingActions?
    /// The connect sheet's registry poll, made when the sheet opens and bound
    /// to that account session; it never rotates the grant. Nil: the sheet
    /// does not follow the read.
    var makeConnectionsPoll: (@MainActor () -> @MainActor () async -> AccountConnections?)?
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
    /// The row a successful write made current. Nil clears the chip's
    /// cached pick so it follows the returned destination.
    var onPick: (PhoneModelPickerProjection.Row?) -> Void = { _ in }
    /// A Work pick the server saved (W4-Y2): the chip names it at once.
    var onWorkPick: (WorkModelSelection) -> Void = { _ in }

    @State private var snapshot: ManagedModelSnapshot?
    @State private var destinationRead: PhoneModelPickerDestinationRead
    private var destination: ManagedModelDestinationSnapshot? { destinationRead.snapshot }
    private var destinationReadState: PhoneModelPickerReadState { destinationRead.state }
    /// Selection and load lifetime (desktop `beginSelection`): closing the
    /// picker retires every pending pick and load.
    @State private var lifetime = ModelPickerLifetime()
    @State private var unavailable = false
    @State private var loadFailed = false
    @State private var savingRowID: String?
    /// The Atum row a successful 1.1 pick wrote, so the check follows the
    /// write even before a new 1.3 read returns.
    @State private var pickedAtum: PhoneModelPickerProjection.ChipPick?
    private var pickedAtumModel: String? { pickedAtum?.row.model }
    @State private var savingEffort: ManagedModelEffort?
    @State private var saveFailed = false
    /// The idempotency key of the write whose outcome may be unknown, kept with
    /// the payload it belongs to.
    @State private var writes = ModelWriteRequests<ConversationModelWrite>()
    @State private var destinationWrites = ModelWriteRequests<ConversationDestinationWrite>()
    /// What the account's subscriptions can run in the cloud now; nil until read.
    @State private var accountState: PhoneModelPickerAccount
    private var account: PhoneSubscriptionAccount? { accountState.value }
    /// Plans Work reports on a Mac, drawn read-only with their hand-off (W4-X2).
    private var handoffs: [PhoneModelPickerProjection.WorkPlanHandoff] { account?.workPlanHandoffs ?? [] }
    @State private var subscriptionWrites = ModelWriteRequests<SubscriptionWrite>()
    /// A ChatGPT pick held on the training-off card; nothing is written meanwhile.
    @State private var confirming: PendingChatGPTTraining?
    /// W4-Y2: this picker's Work selection, made when it opens and retired
    /// when it closes. Opening reads it; only a Work row's tap writes it.
    @State private var work: PhoneModelPickerWorkSelection?
    /// A cloud pick landed after the last Work read: the server cleared the
    /// Work choice, so the cloud rows stop yielding before the reread lands.
    @State private var cloudPickedSinceWorkRead = false

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
         accountState: PhoneModelPickerAccount? = nil,
         onPick: @escaping (PhoneModelPickerProjection.Row?) -> Void = { _ in },
         onWorkPick: @escaping (WorkModelSelection) -> Void = { _ in }) {
        self.design = design
        self.actions = actions
        self.destinations = destinations
        self.initialSnapshot = initialSnapshot
        self.initialDestination = initialDestination
        self.onSnapshot = onSnapshot
        self.onDestination = onDestination
        self.onPick = onPick
        self.onWorkPick = onWorkPick
        _snapshot = State(initialValue: initialSnapshot)
        _destinationRead = State(initialValue: PhoneModelPickerDestinationRead(
            cached: initialDestination, canRead: destinations != nil
        ))
        _accountState = State(initialValue: accountState ?? PhoneModelPickerAccount())
    }

    /// Whether an Atum row may be current and chosen (W4-X2 r2). With a
    /// destination read, only its readback says what the cloud runs: while it
    /// loads or after it fails, neither the 1.1 offer nor a cached 1.3
    /// snapshot stands in, so the line-up is drawn read-only and unchecked and
    /// `choose` writes nothing. A destination read the server does not offer
    /// (`unavailable`) leaves the 1.1 offer as the authority, as before W4-X2.
    private var atumWritable: Bool {
        guard destinations != nil else { return true }
        return destinationReadState == .ready || destinationReadState == .unavailable
    }

    private var rows: [PhoneModelPickerProjection.Row] {
        let atum = PhoneModelPickerProjection.conversation(
            offer: snapshot, destination: destination, destinationID: cloudDestination,
            selectedAtumModel: pickedAtumModel, destinationReady: atumWritable
        )
        let subscriptions = PhoneModelPickerProjection.subscriptions(
            destination, destination: cloudDestination, account: account,
            destinationReady: destinationReadState == .ready
        ).map { pickedAtumModel == nil ? $0 : $0.selecting(false) }
        return PhoneModelPickerProjection.yieldingToWork(atum + subscriptions, answering: answeringWork)
    }

    /// The Work model that answers now, unless a cloud pick replaced it.
    private var answeringWork: WorkModelSelection? {
        cloudPickedSinceWorkRead ? nil : PhoneModelPickerProjection.answeringWork(work?.value)
    }

    private var workSaving: WorkModelSelection? {
        if case let .saving(choice)? = work?.value?.saveState { return choice }
        return nil
    }

    private var workSaveFailed: Bool {
        if case .failed? = work?.value?.saveState { return true }
        return false
    }

    private var workRows: PhoneModelPickerList.WorkRows? {
        guard let work else { return nil }
        return .init(rows: work.rows, saving: workSaving, select: chooseWork)
    }

    private var workForThinking: WorkModelSelectionSnapshot? {
        guard !cloudPickedSinceWorkRead, let work, work.agentPrincipal == snapshot?.agentPrincipal,
              let state = work.value else { return nil }
        if case .saving = state.saveState { return nil }
        return state.readySnapshot
    }

    private func thinking(in rows: [PhoneModelPickerProjection.Row]) -> PhoneModelPickerProjection.Thinking? {
        snapshot.flatMap { PhoneModelPickerProjection.conversationThinking(offer: $0, rows: rows, work: workForThinking) }
    }

    var body: some View {
        // One stable container: its disappearance is the picker closing, not
        // the list giving way to the training card.
        ZStack { content }
            .task { await load() }
            .onDisappear(perform: retire)
    }

    private var content: some View {
        let rows = self.rows
        let thinking = self.thinking(in: rows)
        return Group {
            if let confirming, let training = destinations?.subscriptions?.training {
                ChatGPTTrainingConfirmView(design: design, actions: training, status: confirming.status,
                                           isSelectionCurrent: { lifetime.isCurrent(confirming.selection) },
                                           onConfirmed: { confirmed(confirming, status: $0) },
                                           onKeep: { self.confirming = nil })
            } else if !rows.isEmpty || !handoffs.isEmpty || work?.rows.isEmpty == false {
                PhoneModelPickerList(
                    design: design,
                    matrixAccountID: actions?.matrixAccountID ?? destinations?.matrixAccountID ?? "",
                    destinationID: cloudDestination.rawValue,
                    rows: rows,
                    context: .conversation,
                    savingRowID: savingRowID,
                    saveFailed: saveFailed || workSaveFailed,
                    thinking: thinking,
                    savingEffort: savingEffort,
                    selectEffort: { level in
                        if let model = thinking?.model { chooseEffort(level, shownModel: model) }
                    },
                    planConnects: PhoneModelPickerList.planConnects(account),
                    makeConnectionsPoll: destinations?.subscriptions?.makeConnectionsPoll,
                    onConnectionsChanged: { registry in
                        if destinations?.subscriptions?.read.isCurrent() == true { accountState.landed(registry) }
                    },
                    destinationStatus: PhoneModelPickerStatus.destination(destinationReadState),
                    providerStatuses: PhoneModelPickerStatus.providers(account),
                    handoffs: handoffs,
                    work: workRows,
                    // Every picker load refreshes the destination, offer and
                    // account sources together under one bounded budget.
                    retry: { _ in Task { await load() } },
                    select: choose
                )
            } else if unavailable {
                ContentUnavailableView(copy(.modelsUnavailable), image: symbol(.globe))
            } else if loadFailed {
                ContentUnavailableView {
                    Label(copy(.modelsFailed), image: symbol(.alertCircle))
                } actions: {
                    Button(copy(.modelsRetry)) { Task { await load() } }
                }
            } else {
                ProgressView().accessibilityIdentifier("assistant.model.loading")
            }
        }
        .navigationTitle(phoneCopy(.title))
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor private func load() async {
        // Composer snapshots keep the list visible while each picker session
        // refreshes its own destination, offer and account reads.
        // An interrupted read (the list giving way to the card, a closed
        // sheet) still ends its load, so the next one is never refused.
        guard let token = lifetime.beginLoad() else { return }
        defer { lifetime.endLoad(token) }
        let budget = PhoneModelPickerRead()
        unavailable = false
        loadFailed = false
        if work?.value == nil { work = destinations?.makeWorkSelection?() }
        async let accountLoad: Void = loadAccount(within: budget)
        async let workLoad: Void = loadWork(within: budget)
        async let offerRead = loadOffer(within: budget, isCurrent: { lifetime.isCurrentLoad(token) })
        async let defaultsRead = loadDestination(within: budget, token: token)
        let (offer, defaults, _, _) = await (offerRead, defaultsRead, accountLoad, workLoad)
        guard lifetime.isCurrentLoad(token) else { return }
        if case .value? = offer { return }
        if case .value? = defaults { return }
        unavailable = Task.isCancelled || offer?.state == .unavailable || defaults?.state == .unavailable
        loadFailed = !unavailable
    }

    private func loadAccount(within budget: PhoneModelPickerRead) async {
        if let read = destinations?.subscriptions?.read { await accountState.reload(read, within: budget) }
    }

    /// A read only: opening the picker never writes a Work or cloud choice.
    private func loadWork(within budget: PhoneModelPickerRead = PhoneModelPickerRead()) async {
        guard let work else { return }
        await work.reload(within: budget)
        if work.value?.readState == .ready { cloudPickedSinceWorkRead = false }
    }

    /// A Work row's tap: `work_selection_set` for that plan and model, and
    /// nothing else. The cloud choice is left as it is.
    private func chooseWork(_ choice: WorkModelSelection) {
        guard let work, savingRowID == nil, savingEffort == nil, workSaving == nil,
              let row = work.rows.first(where: { $0.id == choice }), row.selectable,
              !(row.selected && !cloudPickedSinceWorkRead) else { return }
        saveFailed = false
        Task { @MainActor in
            await work.save(choice)
            guard work.value?.readySnapshot?.selection == choice else { return }
            cloudPickedSinceWorkRead = false
            pickedAtum = nil
            onWorkPick(choice)
        }
    }

    private func loadOffer(within budget: PhoneModelPickerRead, isCurrent: @escaping @MainActor () -> Bool) async
        -> AssistantModelLoadResult? {
        guard let actions else { return nil }
        let result = await budget.scoped(isCurrent: { isCurrent() && destinations?.isCurrent() != false }) {
            await actions.read()
        }
        guard isCurrent() else { return nil }
        if case let .value(value) = result, value.revision >= snapshot?.revision ?? .min { apply(value) }
        return result
    }

    private func loadDestination(within budget: PhoneModelPickerRead, token: ModelPickerLifetime.Token) async
        -> AssistantModelDestinationLoadResult? {
        guard let destinations else { return nil }
        destinationRead.begin()
        let result = await budget.scoped(isCurrent: destinations.isCurrent) { await destinations.read() }
        guard lifetime.isCurrentLoad(token) else { return nil }
        guard destinations.isCurrent() else {
            destinationRead = PhoneModelPickerDestinationRead(canRead: false)
            snapshot = nil
            pickedAtum = nil
            unavailable = true
            return .unavailable
        }
        if case let .value(value) = result { applyDestination(value) }
        else { destinationRead.settle(result) }
        return result
    }

    private func choose(_ row: PhoneModelPickerProjection.Row) {
        guard workSaving == nil else { return }
        if row.isSubscription { return chooseSubscription(row) }
        let model = row.model
        guard savingRowID == nil, savingEffort == nil, atumWritable, row.source == .atum,
              row.selectable, !row.selected else { return }
        if let snapshot, let offer = snapshot.models.first(where: { $0.alias == model }) {
            guard offer.eligibility == .ready, let effort = offer.selectionEffort else { return }
            savingRowID = row.stableID
            save(snapshot, model: model, effort: effort)
            return
        }
        guard let destination = destinationRead.readySnapshot else { return }
        savingRowID = row.stableID
        saveDestination(destination, model: model)
    }

    /// A thinking-level change writes the model that answers now with the new
    /// level: the same fenced save a model pick makes.
    private func chooseEffort(_ level: ManagedModelEffort, shownModel: String) {
        guard savingRowID == nil, savingEffort == nil, atumWritable, let snapshot, let work = workForThinking,
              let thinking = thinking(in: rows), thinking.model == shownModel,
              thinking.canChange(to: level) else { return }
        savingEffort = level
        save(snapshot, model: thinking.model, effort: level, work: work)
    }

    private func save(_ snapshot: ManagedModelSnapshot, model: String, effort: ManagedModelEffort,
                      work workFence: WorkModelSelectionSnapshot? = nil) {
        guard let actions else { return }
        saveFailed = false
        // The same ID only for an identical retry; a different pick gets its own.
        let operation = writes.begin(ConversationModelWrite(model: model, effort: effort,
                                                            revision: snapshot.revision))
        Task { @MainActor in
            let result = await actions.save(snapshot, model, effort, operation, workFence) {
                workFence == nil || workFence == workForThinking
            }
            guard !Task.isCancelled, work?.value != nil || workFence == nil else { return }
            savingRowID = nil
            savingEffort = nil
            switch result {
            case let .saved(value):
                apply(value)
                reportAtumPick(value.choice.model)
                writes.settled()
                cloudPickedSinceWorkRead = true
                await loadWork()
                return
            case let .conflict(latest):
                if let latest { apply(latest) }
                saveFailed = true
                writes.settled()
            case .failed:
                // The provider may have received it. Keep the key with its
                // payload so an identical explicit retry is an idempotent replay.
                saveFailed = true
            }
            if workFence != nil { await loadWork() }
        }
    }

    /// The 1.3/1.4 fallback write, used only when no 1.1 offer could be read.
    /// The destination write uses a route-compatible effort from the snapshot.
    private func saveDestination(_ snapshot: ManagedModelDestinationSnapshot, model: String) {
        guard let destinations else { return }
        let selection = lifetime.beginSelection()
        saveFailed = false
        let operation = destinationWrites.begin(ConversationDestinationWrite(
            model: model, revision: snapshot.revision
        ))
        Task { @MainActor in
            let result = await destinations.save(snapshot, cloudDestination, model, operation)
            guard !Task.isCancelled, lifetime.isCurrent(selection) else { return }
            savingRowID = nil
            switch result {
            case let .saved(value):
                pickedAtum = nil
                applyDestination(value)
                onPick(nil)
                destinationWrites.settled()
                cloudPickedSinceWorkRead = true
                // The initial offer may have been read before this write.
                // Read again to recover thinking levels for the saved model.
                let budget = PhoneModelPickerRead()
                async let workLoad: Void = loadWork(within: budget)
                _ = await loadOffer(within: budget, isCurrent: { lifetime.isCurrent(selection) })
                await workLoad
            case .cancelled: break
            case let .refused(latest), let .consentRequired(_, latest):
                if let latest { applyDestination(latest) }
                saveFailed = true
                destinationWrites.settled()
            }
        }
    }

    /// A subscription pick writes the cloud destination (1.4 / 1.5), as the
    /// desktop's cloud picker does. Only the server's answer moves the check.
    /// A ChatGPT pick first passes the training-off gate.
    private func chooseSubscription(_ row: PhoneModelPickerProjection.Row) {
        guard savingRowID == nil, savingEffort == nil, let destination = destinationRead.readySnapshot,
              destinations?.subscriptions?.save != nil,
              PhoneModelPickerProjection.canSelectSubscription(
                  row, snapshot: destination, account: account) != nil else { return }
        let selection = lifetime.beginSelection()
        guard row.source == .chatGPTPlan else {
            return writeSubscription(row, consent: nil, selection: selection)
        }
        savingRowID = row.stableID
        saveFailed = false
        Task { @MainActor in
            let decision = await ChatGPTTrainingGate.decide(source: row.source,
                                                            training: destinations?.subscriptions?.training)
            // A closed picker or a newer pick: this read decides nothing.
            guard !Task.isCancelled, lifetime.isCurrent(selection) else { return }
            switch decision {
            case let .write(consent):
                writeSubscription(row, consent: consent, selection: selection)
            case let .ask(status):
                savingRowID = nil
                confirming = PendingChatGPTTraining(row: row, status: status, selection: selection)
            case .failed:
                savingRowID = nil
                saveFailed = true
            }
        }
    }

    /// The card's confirmation starts the held pick's write only while that
    /// pick is still the picker's current selection.
    private func confirmed(_ pending: PendingChatGPTTraining, status: ChatGPTTrainingStatus) {
        guard lifetime.isCurrent(pending.selection) else { return }
        confirming = nil
        guard let consent = status.consent else {
            saveFailed = true
            return
        }
        writeSubscription(pending.row, consent: consent, selection: pending.selection)
    }

    /// The picker closed: no pending pick may start a read result, a POST
    /// follow-up or a write after this.
    private func retire() {
        lifetime.retire()
        work?.retire()
        work = nil
        if destinationReadState == .loading { destinationRead.settle(.unavailable) }
        accountState.retire(keepingSettled: true)
        confirming = nil
        savingRowID = nil
        savingEffort = nil
    }

    /// The write itself, against the snapshot the picker holds now, under the
    /// consent decision the gate or card read (ChatGPT only).
    private func writeSubscription(_ row: PhoneModelPickerProjection.Row, consent: ChatGPTTrainingConsent?,
                                   selection: ModelPickerLifetime.Token) {
        guard lifetime.isCurrent(selection), let destination = destinationRead.readySnapshot,
              let save = destinations?.subscriptions?.save,
              row.source != .chatGPTPlan || consent != nil,
              let effort = PhoneModelPickerProjection.canSelectSubscription(
                  row, snapshot: destination, account: account) else {
            savingRowID = nil
            saveFailed = true
            return
        }
        savingRowID = row.stableID
        saveFailed = false
        let operation = subscriptionWrites.begin(SubscriptionWrite(
            connection: row.connectionID, model: row.model, revision: destination.revision))
        Task { @MainActor in
            let result = await save(destination, row.source, row.model, effort, operation, consent) {
                lifetime.isCurrent(selection)
            }
            guard !Task.isCancelled, lifetime.isCurrent(selection) else { return }
            savingRowID = nil
            switch result {
            case let .saved(value):
                pickedAtum = nil
                applyDestination(value)
                onPick(PhoneModelPickerProjection.settledDestinationPick(row, destination: value))
                subscriptionWrites.settled()
                cloudPickedSinceWorkRead = true
                await loadWork()
            case .cancelled: break
            case let .consentRequired(status, latest):
                // The consent changed under the write: nothing was retried.
                // Back to the card for the connection the platform names now.
                if let latest { applyDestination(latest) }
                subscriptionWrites.settled()
                confirming = PendingChatGPTTraining(row: row, status: status, selection: selection)
            case let .refused(latest):
                if let latest {
                    applyDestination(latest)
                    subscriptionWrites.settled()
                }
                saveFailed = true
                // A relay that went down or a disconnected plan shows as such now.
                if let read = destinations?.subscriptions?.read { await accountState.reload(read) }
            }
        }
    }

    /// The chip's row for an Atum write: the line-up row the list now checks.
    private func reportAtumPick(_ model: String) {
        guard let row = rows.first(where: { $0.source == .atum && $0.model == model }) else { return }
        let selected = row.selecting(true)
        pickedAtum = .init(row: selected, destinationRevision: destination?.revision,
                           offerRevision: snapshot?.revision)
        onPick(selected)
    }

    private func apply(_ value: ManagedModelSnapshot) {
        snapshot = value
        pickedAtum = PhoneModelPickerProjection.reconciled(pickedAtum, destination: destination, offer: value)
        unavailable = false
        loadFailed = false
        saveFailed = false
        onSnapshot(value)
    }

    private func applyDestination(_ value: ManagedModelDestinationSnapshot) {
        destinationRead.settle(.value(value))
        pickedAtum = PhoneModelPickerProjection.reconciled(pickedAtum, destination: value, offer: snapshot)
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

extension ManagedModelDestinationSnapshot {
    /// The card edits the cloud, as desktop's cardModelChoice does. A Mac
    /// home's model is edited from the Lives on sheet.
    var cardDestination: ManagedModelDestinationID { try! ManagedModelDestinationID("cloud") }
}

/// The card's Model page when only the 1.3/1.4 destination read is available:
/// the one picker for the destination that answers now.
struct PhoneModelDestinationsPicker: View {
    let design: LiveDesign
    let actions: AssistantModelDestinationActions
    @State private var snapshot: ManagedModelDestinationSnapshot?
    private var destination: ManagedModelDestinationID {
        snapshot?.cardDestination ?? (try! ManagedModelDestinationID("cloud"))
    }
    @State private var destinationReadState: PhoneModelPickerReadState = .loading
    @State private var offer: AssistantModelLoadResult?
    @State private var savingRowID: String?
    @State private var saveFailed = false
    @State private var writes = ModelWriteRequests<DestinationModelWrite>()
    @State private var accountState = PhoneModelPickerAccount()
    private var account: PhoneSubscriptionAccount? { accountState.value }
    /// Plans Work reports on a Mac, drawn read-only with their hand-off (W4-X2).
    private var handoffs: [PhoneModelPickerProjection.WorkPlanHandoff] { account?.workPlanHandoffs ?? [] }
    @State private var subscriptionWrites = ModelWriteRequests<SubscriptionWrite>()
    /// A ChatGPT pick held on the training-off card; nothing is written meanwhile.
    @State private var confirming: PendingChatGPTTraining?
    /// Selection lifetime (desktop `beginSelection`): closing retires every pending pick.
    @State private var lifetime = ModelPickerLifetime()
    /// W4-Y2: the same Work selection as the composer's picker.
    @State private var work: PhoneModelPickerWorkSelection?
    @State private var cloudPickedSinceWorkRead = false

    private struct DestinationModelWrite: Hashable, Sendable {
        let destination: String
        let model: String
    }

    var body: some View {
        // One stable container: its disappearance is the picker closing, not
        // the list giving way to the training card.
        ZStack { content }
            .onDisappear(perform: retire)
            .navigationTitle(design.text("desktop.atum.settings.model"))
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
    }

    private var content: some View {
        Group {
            if let confirming, let training = actions.subscriptions?.training {
                ChatGPTTrainingConfirmView(design: design, actions: training, status: confirming.status,
                                           isSelectionCurrent: { lifetime.isCurrent(confirming.selection) },
                                           onConfirmed: { confirmed(confirming, status: $0) },
                                           onKeep: { self.confirming = nil })
            } else if !rows.isEmpty || !handoffs.isEmpty || work?.rows.isEmpty == false {
                PhoneModelPickerList(
                    design: design,
                    matrixAccountID: actions.matrixAccountID,
                    destinationID: destination.rawValue,
                    rows: rows,
                    context: .cloudAssistant,
                    savingRowID: savingRowID,
                    saveFailed: saveFailed || workSaveFailed,
                    planConnects: PhoneModelPickerList.planConnects(account),
                    makeConnectionsPoll: actions.subscriptions?.makeConnectionsPoll,
                    onConnectionsChanged: { registry in
                        if actions.subscriptions?.read.isCurrent() == true { accountState.landed(registry) }
                    },
                    destinationStatus: PhoneModelPickerStatus.destination(destinationReadState),
                    providerStatuses: PhoneModelPickerStatus.providers(account),
                    handoffs: handoffs,
                    work: workRows,
                    retry: { _ in Task { await load() } },
                    select: choose
                )
            } else if destinationReadState == .unavailable {
                ContentUnavailableView(copy(.modelsUnavailable), image: symbol(.globe))
            } else if destinationReadState == .failed {
                ContentUnavailableView {
                    Label(copy(.modelsFailed), image: symbol(.alertCircle))
                } actions: {
                    Button(copy(.modelsRetry)) { Task { await load() } }
                }
            } else {
                ProgressView().accessibilityIdentifier("assistant.model.destinations.loading")
            }
        }
    }

    @MainActor private func load() async {
        guard let token = lifetime.beginLoad() else { return }
        defer { lifetime.endLoad(token) }
        destinationReadState = .loading
        offer = nil
        let budget = PhoneModelPickerRead()
        if work?.value == nil { work = actions.makeWorkSelection?() }
        async let accountLoad: Void = loadAccount(within: budget)
        async let workLoad: Void = loadWork(within: budget)
        async let offerLoad: Void = loadOffer(within: budget, token: token)
        let result = await budget.scoped(isCurrent: actions.isCurrent) { await actions.read() }
        if lifetime.isCurrentLoad(token) {
            if actions.isCurrent() {
                destinationReadState = result.state
                if case let .value(next) = result { snapshot = next }
            } else {
                destinationReadState = .unavailable
                snapshot = nil
            }
        }
        _ = await (accountLoad, offerLoad, workLoad)
    }

    private func loadWork(within budget: PhoneModelPickerRead = PhoneModelPickerRead()) async {
        guard let work else { return }
        await work.reload(within: budget)
        if work.value?.readState == .ready { cloudPickedSinceWorkRead = false }
    }

    private var answeringWork: WorkModelSelection? {
        cloudPickedSinceWorkRead ? nil : PhoneModelPickerProjection.answeringWork(work?.value)
    }

    private var workSaving: WorkModelSelection? {
        if case let .saving(choice)? = work?.value?.saveState { return choice }
        return nil
    }

    private var workSaveFailed: Bool {
        if case .failed? = work?.value?.saveState { return true }
        return false
    }

    private var workRows: PhoneModelPickerList.WorkRows? {
        guard let work else { return nil }
        return .init(rows: work.rows, saving: workSaving, select: chooseWork)
    }

    private func chooseWork(_ choice: WorkModelSelection) {
        guard let work, savingRowID == nil, workSaving == nil,
              let row = work.rows.first(where: { $0.id == choice }), row.selectable,
              !(row.selected && !cloudPickedSinceWorkRead) else { return }
        saveFailed = false
        Task { @MainActor in
            await work.save(choice)
            if work.value?.readySnapshot?.selection == choice { cloudPickedSinceWorkRead = false }
        }
    }

    private func cloudPickLanded() {
        cloudPickedSinceWorkRead = true
        Task { @MainActor in await loadWork() }
    }

    private func loadOffer(within budget: PhoneModelPickerRead, token: ModelPickerLifetime.Token) async {
        let result = await budget.scoped(isCurrent: actions.isCurrent) { await actions.readOffer() }
        if lifetime.isCurrentLoad(token) { offer = result }
    }

    private func loadAccount(within budget: PhoneModelPickerRead) async {
        if let read = actions.subscriptions?.read { await accountState.reload(read, within: budget) }
    }

    private var rows: [PhoneModelPickerProjection.Row] {
        // A snapshot kept from an earlier read is drawn read-only and
        // unchecked while a later read loads or after it fails (W4-X2 r2).
        let atum = snapshot.map {
            PhoneModelPickerProjection.destination($0, destination: destination,
                                                   cloudEligibleAliases: cloudEligibleAliases,
                                                   destinationReady: destinationReadState == .ready)
        } ?? []
        return PhoneModelPickerProjection.yieldingToWork(atum + PhoneModelPickerProjection.subscriptions(
            snapshot, destination: destination, account: account,
            destinationReady: destinationReadState == .ready
        ), answering: answeringWork)
    }

    private var cloudEligibleAliases: Set<String> {
        guard destinationReadState == .ready, case let .value(value)? = offer else { return [] }
        return Set(value.models.lazy.filter { $0.eligibility == .ready }.map(\.alias))
    }

    private func choose(_ row: PhoneModelPickerProjection.Row) {
        guard workSaving == nil else { return }
        if row.isSubscription { return chooseSubscription(row) }
        guard savingRowID == nil, destinationReadState == .ready, let snapshot,
              PhoneModelPickerProjection.canSelectAtumModel(
                  row.model,
                  snapshot: snapshot,
                  destination: destination,
                  cloudEligibleAliases: cloudEligibleAliases
              ) else { return }
        savingRowID = row.stableID
        saveFailed = false
        let operation = writes.begin(DestinationModelWrite(destination: destination.rawValue,
                                                           model: row.model))
        Task { @MainActor in
            let result = await actions.save(snapshot, destination, row.model, operation)
            guard !Task.isCancelled else { return }
            savingRowID = nil
            switch result {
            case let .saved(snapshot):
                self.snapshot = snapshot
                saveFailed = false
                writes.settled()
                cloudPickLanded()
            case .cancelled: break
            case let .refused(latest), let .consentRequired(_, latest):
                if let latest {
                    // A conflict carries the authoritative snapshot: settled.
                    self.snapshot = latest
                    writes.settled()
                }
                // Without it the outcome is unknown; an identical retry replays.
                saveFailed = true
            }
        }
    }

    /// The same 1.4 / 1.5 cloud write as the composer's picker, behind the
    /// same training-off gate for a ChatGPT pick.
    private func chooseSubscription(_ row: PhoneModelPickerProjection.Row) {
        guard savingRowID == nil, destinationReadState == .ready, let snapshot, actions.subscriptions?.save != nil,
              PhoneModelPickerProjection.canSelectSubscription(
                  row, snapshot: snapshot, account: account) != nil else { return }
        let selection = lifetime.beginSelection()
        guard row.source == .chatGPTPlan else {
            return writeSubscription(row, consent: nil, selection: selection)
        }
        savingRowID = row.stableID
        saveFailed = false
        Task { @MainActor in
            let decision = await ChatGPTTrainingGate.decide(source: row.source,
                                                            training: actions.subscriptions?.training)
            // A closed picker or a newer pick: this read decides nothing.
            guard !Task.isCancelled, lifetime.isCurrent(selection) else { return }
            switch decision {
            case let .write(consent):
                writeSubscription(row, consent: consent, selection: selection)
            case let .ask(status):
                savingRowID = nil
                confirming = PendingChatGPTTraining(row: row, status: status, selection: selection)
            case .failed:
                savingRowID = nil
                saveFailed = true
            }
        }
    }

    private func confirmed(_ pending: PendingChatGPTTraining, status: ChatGPTTrainingStatus) {
        guard lifetime.isCurrent(pending.selection) else { return }
        confirming = nil
        guard let consent = status.consent else {
            saveFailed = true
            return
        }
        writeSubscription(pending.row, consent: consent, selection: pending.selection)
    }

    private func retire() {
        lifetime.retire()
        work?.retire()
        work = nil
        if destinationReadState == .loading { destinationReadState = .unavailable }
        accountState.retire()
        confirming = nil
        savingRowID = nil
    }

    private func writeSubscription(_ row: PhoneModelPickerProjection.Row, consent: ChatGPTTrainingConsent?,
                                   selection: ModelPickerLifetime.Token) {
        guard lifetime.isCurrent(selection), destinationReadState == .ready,
              let snapshot, let save = actions.subscriptions?.save,
              row.source != .chatGPTPlan || consent != nil,
              let effort = PhoneModelPickerProjection.canSelectSubscription(
                  row, snapshot: snapshot, account: account) else {
            savingRowID = nil
            saveFailed = true
            return
        }
        savingRowID = row.stableID
        saveFailed = false
        let operation = subscriptionWrites.begin(SubscriptionWrite(
            connection: row.connectionID, model: row.model, revision: snapshot.revision))
        Task { @MainActor in
            let result = await save(snapshot, row.source, row.model, effort, operation, consent) {
                lifetime.isCurrent(selection)
            }
            guard !Task.isCancelled, lifetime.isCurrent(selection) else { return }
            savingRowID = nil
            switch result {
            case let .saved(snapshot):
                self.snapshot = snapshot
                saveFailed = false
                subscriptionWrites.settled()
                cloudPickLanded()
            case .cancelled: break
            case let .consentRequired(status, latest):
                // The consent changed under the write: nothing was retried.
                if let latest {
                    self.snapshot = latest
                }
                subscriptionWrites.settled()
                confirming = PendingChatGPTTraining(row: row, status: status, selection: selection)
            case let .refused(latest):
                if let latest {
                    self.snapshot = latest
                    subscriptionWrites.settled()
                }
                saveFailed = true
                if let read = actions.subscriptions?.read { await accountState.reload(read) }
            }
        }
    }

    private func copy(_ key: PhonePickerCopyKey) -> String { design.text(key.rawValue) }
    private func symbol(_ glyph: AtumGlyph) -> String { AtumVisualSystem(design: design).symbol(glyph) }
}
