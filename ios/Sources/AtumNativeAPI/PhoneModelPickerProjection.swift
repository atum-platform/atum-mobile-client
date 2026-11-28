import Foundation

/// Pure phone presentation derived only from decoded model-choice contracts.
/// It creates no provider account or remote route identity.
public enum PhoneModelPickerProjection {
    public struct WorkPlanHandoff: Equatable, Sendable, Identifiable {
        public enum Reason: Equatable, Sendable { case openOnMac }

        public let plan: AccountPlan
        public let models: [AccountConnectionModel]
        public var id: AccountPlan { plan }
        public var reason: Reason { .openOnMac }

        public init(plan: AccountPlan, models: [AccountConnectionModel]) {
            self.plan = plan
            self.models = models
        }
    }

    public struct WorkRow: Equatable, Sendable, Identifiable {
        public let id: WorkModelSelection
        public let displayName: String
        public let selected: Bool
        public let selectable: Bool
    }

    /// The Work identity includes the plan even when two catalogs report the
    /// same model ID. A saved model stays visible if its catalog omits it.
    public static func workRows(state: PhoneModelPickerWorkSelectionState?) -> [WorkRow] {
        guard let state else { return [] }
        let current = state.readySnapshot?.selection
        var rows = state.selectableModels.map { model in
            let name = ModelDisplayName.name(model: model.choice.model, displayName: model.name)
            return WorkRow(id: model.choice, displayName: name, selected: model.choice == current, selectable: true)
        }
        if let saved = state.snapshot?.selection, !rows.contains(where: { $0.id == saved }) {
            let modelName = ModelDisplayName.destinationLabel(model: saved.model)
            rows.append(.init(id: saved, displayName: "\(saved.plan.productName) · \(modelName)",
                              selected: saved == current, selectable: false))
        }
        return rows
    }

    /// The Work model that answers, as the composer chip and the card's
    /// Model row name it (desktop #143 `relayCurrentName`): the eligible
    /// catalog's display name, the account catalog's label for a saved model
    /// outside eligibility, or readable words for the id.
    public struct WorkFace: Equatable, Sendable {
        public let selection: WorkModelSelection
        public let name: String
        public var plan: AccountPlan { selection.plan }
    }

    public static func workFace(_ selection: WorkModelSelection?, reported: [WorkPlanHandoff],
                                state: PhoneModelPickerWorkSelectionState? = nil) -> WorkFace? {
        guard let selection else { return nil }
        let eligible = state?.selectableModels.first { $0.choice == selection }
        let listed = reported.first { $0.plan == selection.plan }?.models
            .first { $0.id.utf8.elementsEqual(selection.model.utf8) }
        return WorkFace(selection: selection,
                        name: ModelDisplayName.name(model: selection.model,
                                                    displayName: eligible?.name ?? listed?.displayName))
    }

    /// The Work selection the phone last read for this assistant. A cached
    /// one still names the model during a refresh or after a failed read, as
    /// the W4-Y1 contract allows; only `readySnapshot` makes a row Current.
    public static func answeringWork(_ state: PhoneModelPickerWorkSelectionState?) -> WorkModelSelection? {
        if case let .saving(choice)? = state?.saveState { return choice }
        return state?.snapshot?.selection
    }

    /// While a Work model answers, no cloud row is Current (desktop
    /// `!relayCurrent`), so tapping Atum's or a subscription's row is a real,
    /// explicit switch. Nothing here writes: the server clears the Work choice
    /// only when the owner picks a cloud row (work-route v1.3 §151-153).
    public static func yieldingToWork(_ rows: [Row], answering work: WorkModelSelection?) -> [Row] {
        guard work != nil else { return rows }
        return rows.map { $0.selected ? $0.selecting(false) : $0 }
    }

    public struct Row: Equatable, Sendable {
        /// A small status word drawn beside a model's name. Only data a
        /// phone-visible contract carries is ever drawn: Atum names its default
        /// model. No contract carries a "legacy" flag, so there is no such badge;
        /// the day one does, it is one more case here and one more word in the view.
        public enum Badge: Equatable, Sendable {
            case `default`
        }

        /// Why a subscription's model is listed but cannot be chosen now.
        public enum Unavailable: Equatable, Sendable {
            case loading
            case failed
            case notReady
            case signedOut
        }

        public let favoriteID: String?
        public let source: ManagedModelDestinationSource
        public let model: String
        public let displayName: String
        public let selected: Bool
        public let selectable: Bool
        public let badges: [Badge]
        /// 2.4 uses the opaque connection ref so two same-kind connections do
        /// not collapse. Older model-choice rows keep deriving this from source.
        public let explicitConnectionID: String?
        /// A closed, sanitized provider label from the Mac catalog. It never
        /// contains an account name or credential-derived identifier.
        public let connectionLabel: String?
        /// Atum's own one-line description of the model, from its line-up row.
        /// Nil for a connection's model.
        public let tagline: ManagedModelLineup.Tagline?
        /// The announced third line-up row: always drawn, never selectable.
        public let announced: Bool
        /// A model that answers through an account subscription. It is drawn
        /// in the Subscriptions group, not in a connection's section.
        public let isSubscription: Bool
        /// The level a pick of this subscription model writes. Nil for every
        /// row the phone cannot write as a subscription.
        public let subscriptionEffort: ManagedModelEffort?
        /// Set when a subscription's model is drawn but cannot be chosen now.
        public let unavailable: Unavailable?

        public init(favoriteID: String?,
                    source: ManagedModelDestinationSource,
                    model: String,
                    displayName: String,
                    selected: Bool,
                    selectable: Bool,
                    badges: [Badge] = [],
                    connectionID: String? = nil,
                    connectionLabel: String? = nil,
                    tagline: ManagedModelLineup.Tagline? = nil,
                    announced: Bool = false,
                    isSubscription: Bool = false,
                    subscriptionEffort: ManagedModelEffort? = nil,
                    unavailable: Unavailable? = nil) {
            self.favoriteID = favoriteID
            self.source = source
            self.model = model
            self.displayName = displayName
            self.selected = selected
            self.selectable = selectable
            self.badges = badges
            explicitConnectionID = connectionID
            self.connectionLabel = connectionLabel
            self.tagline = tagline
            self.announced = announced
            self.isSubscription = isSubscription
            self.subscriptionEffort = subscriptionEffort
            self.unavailable = unavailable
        }

        /// The connection this row answers through. A section, the filter and a
        /// row's list identity all use it; it names no account, route or credential.
        public var connectionID: String {
            if let explicitConnectionID { return explicitConnectionID }
            return switch source {
            case .atum: "atum"
            case .chatGPTPlan: "chatgpt_plan"
            case .opencodeGo: "opencode_go"
            case let .ownKey(provider): "own_key:" + provider
            }
        }

        /// A list identity that two connections' same-named models never share.
        public var stableID: String { connectionID + "\u{0}" + model }

        /// Preserve the established model-only UI-test identifier for legacy
        /// rows. Catalog rows add their opaque connection ref, without a NUL.
        public var accessibilityID: String {
            guard explicitConnectionID != nil else { return model }
            return connectionID + "." + model.replacingOccurrences(of: "/", with: "_")
        }

        /// The same row drawn read-only: not current, not choosable and with no
        /// Default word, as while the destination readback is not ready (W4-X2).
        public func readOnly() -> Row {
            Row(favoriteID: favoriteID, source: source, model: model,
                displayName: displayName, selected: false, selectable: false,
                badges: [], connectionID: explicitConnectionID,
                connectionLabel: connectionLabel, tagline: tagline, announced: announced,
                isSubscription: isSubscription, subscriptionEffort: nil,
                unavailable: unavailable)
        }

        /// The same row with the current mark moved by a pick in flight.
        public func selecting(_ selected: Bool) -> Row {
            Row(favoriteID: favoriteID, source: source, model: model,
                displayName: displayName, selected: selected, selectable: selectable,
                badges: badges, connectionID: explicitConnectionID,
                connectionLabel: connectionLabel, tagline: tagline, announced: announced,
                isSubscription: isSubscription, subscriptionEffort: subscriptionEffort,
                unavailable: unavailable)
        }
    }

    /// Cloud is exactly the 1.1 Atum offer, but the picker always shows Atum's
    /// full three-row line-up, including the announced row: a person sees what
    /// is coming even when the server lists only the served aliases.
    public static func cloud(_ snapshot: ManagedModelSnapshot) -> [Row] {
        let offers = Dictionary(uniqueKeysWithValues: snapshot.models.map { ($0.alias, $0) })
        return lineupRows { alias in
            let ready = offers[alias]?.eligibility == .ready && offers[alias]?.selectionEffort != nil
            return (selected: snapshot.choice.model == alias, selectable: ready,
                    badges: ready && alias == ManagedModelLineup.defaultAlias ? [.default] : [])
        }
    }

    /// A Mac's 1.3 choice may name Atum, ChatGPT Plan, or one of that Mac's
    /// own-key providers. Only Atum aliases are selectable without a separate
    /// controller-backed catalog. A saved external choice remains visible by
    /// its actual source and model and is never relabelled as the recommendation.
    public static func mac(_ snapshot: ManagedModelDestinationSnapshot,
                           destination: ManagedModelDestinationID) -> [Row] {
        guard !destination.isCloud,
              let saved = snapshot.choice(for: destination) else { return [] }
        var rows: [Row] = []

        if saved.source != .atum {
            rows.append(Row(
                favoriteID: nil,
                source: saved.source,
                model: saved.model,
                // The desktop card's words for a saved external model
                // (`matrixModelDestinationsView` `external.modelLabel`).
                displayName: ModelDisplayName.destinationLabel(model: saved.model),
                selected: true,
                selectable: false,
                isSubscription: saved.source.isSubscription
            ))
        }

        let selectedAlias = saved.source == .atum ? saved.model : nil
        rows.append(contentsOf: lineupRows { alias in
            let canWrite = snapshot.atumWriteEffort(for: destination, model: alias) != nil
            return (selected: selectedAlias == alias, selectable: canWrite,
                    badges: canWrite && alias == snapshot.recommended.model ? [.default] : [])
        })
        return rows
    }

    /// One 1.3 destination. Cloud remains Atum-only and uses the separately
    /// decoded 1.1 eligibility set; Mac behavior retains truthful external
    /// readback while exposing only Atum aliases for selection.
    /// `destinationReady` false (a readback still loading or failed, so the
    /// snapshot may be stale) draws every row read-only and unchecked (W4-X2).
    public static func destination(_ snapshot: ManagedModelDestinationSnapshot,
                                   destination: ManagedModelDestinationID,
                                   cloudEligibleAliases: Set<String>,
                                   selectedAtumModel: String? = nil,
                                   destinationReady: Bool = true) -> [Row] {
        let rows = destination.isCloud
            ? cloudDestinationRows(snapshot, destination: destination, selectedAtumModel: selectedAtumModel) {
                cloudEligibleAliases.contains($0) && snapshot.atumWriteEffort(for: destination, model: $0) != nil
            }
            : mac(snapshot, destination: destination)
        return destinationReady ? rows : rows.map { $0.readOnly() }
    }

    private static func cloudDestinationRows(_ snapshot: ManagedModelDestinationSnapshot,
                                             destination: ManagedModelDestinationID,
                                             selectedAtumModel: String?,
                                             canSelect: (String) -> Bool) -> [Row] {
        let saved = snapshot.choice(for: destination)
        // A saved subscription is the current row in its own group; no Atum
        // row is checked for it. With no saved choice the recommendation is.
        let selected: String?
        if let selectedAtumModel {
            selected = selectedAtumModel
        } else if let saved {
            selected = saved.source == .atum ? saved.model : nil
        } else {
            selected = snapshot.recommended.model
        }
        return lineupRows { alias in
            let eligible = canSelect(alias)
            return (selected: selected == alias, selectable: eligible,
                    badges: eligible && alias == snapshot.recommended.model ? [.default] : [])
        }
    }

    /// The composer's conversation picker. The 1.3/1.4 snapshot is the
    /// authority for the cloud destination's saved choice and subscriptions;
    /// the 1.1 offer is only eligibility and thinking levels. Either one alone
    /// still yields the full Atum line-up, so a missing older read never
    /// removes the picker. With neither read there is nothing to draw.
    /// `destinationReady` false (the destination readback is loading or has
    /// failed) keeps the line-up visible but read-only and unchecked: neither
    /// the 1.1 offer nor a cached 1.3 snapshot may stand in for it (W4-X2).
    public static func conversation(offer: ManagedModelSnapshot?,
                                    destination: ManagedModelDestinationSnapshot?,
                                    destinationID: ManagedModelDestinationID,
                                    cloudEligibleAliases: Set<String>? = nil,
                                    selectedAtumModel: String? = nil,
                                    destinationReady: Bool = true) -> [Row] {
        let rows = conversationRows(offer: offer, destination: destination, destinationID: destinationID,
                                    cloudEligibleAliases: cloudEligibleAliases,
                                    selectedAtumModel: selectedAtumModel)
        return destinationReady ? rows : rows.map { $0.readOnly() }
    }

    private static func conversationRows(offer: ManagedModelSnapshot?,
                                         destination: ManagedModelDestinationSnapshot?,
                                         destinationID: ManagedModelDestinationID,
                                         cloudEligibleAliases: Set<String>?,
                                         selectedAtumModel: String?) -> [Row] {
        guard let destination else {
            guard let offer else { return [] }
            return cloud(offer).map { row in
                guard let selectedAtumModel else { return row }
                return row.selecting(row.model == selectedAtumModel)
            }
        }
        guard destinationID.isCloud else { return mac(destination, destination: destinationID) }
        var fallbackAliases = cloudEligibleAliases ?? []
        if offer == nil, fallbackAliases.isEmpty { fallbackAliases.insert(ManagedModelLineup.defaultAlias) }
        return cloudDestinationRows(destination, destination: destinationID, selectedAtumModel: selectedAtumModel) { alias in
            if let model = offer?.models.first(where: { $0.alias == alias }) {
                return model.eligibility == .ready && model.selectionEffort != nil
            }
            return fallbackAliases.contains(alias) && destination.atumWriteEffort(for: destinationID, model: alias) != nil
        }
    }

    /// Cloud subscription rows come from independent plan catalogs. A saved
    /// choice can still name a read-only row during a failed or incomplete read.
    /// Only current catalog membership and destination readback mark it current.
    public static func subscriptions(_ snapshot: ManagedModelDestinationSnapshot?,
                                     destination: ManagedModelDestinationID,
                                     account: PhoneSubscriptionAccount? = nil,
                                     destinationReady: Bool = true) -> [Row] {
        let saved = snapshot?.choices.first { $0.destination == destination && $0.source.isSubscription }
        guard destination.isCloud else {
            return saved.map { [savedRow($0, selected: destinationReady, unavailable: nil)] } ?? []
        }

        func planRows(_ source: ManagedModelDestinationSource,
                      models: [SubscriptionModelDescriptor], state: PhoneModelPickerReadState?,
                      unavailable: Row.Unavailable?) -> [Row] {
            let savedModel = saved?.source == source ? saved : nil
            let ready = state == .ready && snapshot != nil && destinationReady
            let reason: Row.Unavailable? = switch state {
            case .loading?: .loading
            case .failed?: .failed
            default: unavailable
            }
            var rows = models.map { model in
                let matchesSaved = savedModel?.model == model.id
                let effort = ready ? model.writeEffort : nil
                return Row(favoriteID: nil, source: source, model: model.id,
                           displayName: ModelDisplayName.name(model: model.id, displayName: model.displayName),
                           selected: ready && matchesSaved, selectable: !matchesSaved && effort != nil,
                           isSubscription: true, subscriptionEffort: effort,
                           unavailable: matchesSaved ? reason : nil)
            }
            if let savedModel, !rows.contains(where: { $0.model == savedModel.model }) {
                rows.append(savedRow(savedModel, selected: false, unavailable: reason))
            }
            return rows
        }

        let relay = account?.chatGPT
        let go = account?.openCodeGo
        return planRows(.chatGPTPlan, models: relay?.models ?? [], state: account?.chatGPTState,
                        unavailable: relay?.state == .disabled ? .notReady : nil)
            + planRows(.opencodeGo, models: go?.state == .connected ? go?.models ?? [] : [],
                       state: account?.openCodeGoState,
                       unavailable: go?.state == .disconnected ? .signedOut : nil)
    }

    private static func savedRow(_ choice: ManagedModelDestinationChoice, selected: Bool,
                                 unavailable: Row.Unavailable?) -> Row {
        Row(favoriteID: nil, source: choice.source, model: choice.model,
            displayName: ModelDisplayName.name(model: choice.model),
            selected: selected, selectable: false, isSubscription: true, unavailable: unavailable)
    }

    /// The write boundary for a subscription pick, as `canSelectAtumModel` is
    /// for Atum's: the latest snapshot and account status still list the
    /// model as choosable on the cloud.
    public static func canSelectSubscription(_ row: Row,
                                             snapshot: ManagedModelDestinationSnapshot,
                                             account: PhoneSubscriptionAccount?) -> ManagedModelEffort? {
        let destination = try! ManagedModelDestinationID("cloud")
        return subscriptions(snapshot, destination: destination, account: account).first {
            $0.source == row.source && $0.model == row.model && $0.selectable && !$0.selected
        }?.subscriptionEffort
    }

    /// Atum's line-up in the owner's order; `state` answers for the served
    /// aliases, and the announced row is always present and never selectable.
    private static func lineupRows(
        _ state: (String) -> (selected: Bool, selectable: Bool, badges: [Row.Badge])
    ) -> [Row] {
        ManagedModelLineup.lineup.map { row in
            guard let alias = row.alias else {
                return Row(favoriteID: nil, source: .atum, model: ManagedModelLineup.announcedAlias,
                           displayName: row.displayName, selected: false, selectable: false,
                           tagline: row.tagline, announced: true)
            }
            let value = state(alias)
            return Row(favoriteID: alias, source: .atum, model: alias,
                       displayName: row.displayName, selected: value.selected,
                       selectable: value.selectable, badges: value.badges,
                       tagline: row.tagline)
        }
    }

    /// The write boundary used by the phone UI. A Mac remains selectable only
    /// while the latest decoded 1.3 snapshot still contains that exact active
    /// destination; a conflict readback that removes it closes the boundary.
    public static func canSelectAtumModel(_ model: String,
                                          snapshot: ManagedModelDestinationSnapshot,
                                          destination: ManagedModelDestinationID,
                                          cloudEligibleAliases: Set<String>) -> Bool {
        PhoneModelPickerProjection.destination(
            snapshot,
            destination: destination,
            cloudEligibleAliases: cloudEligibleAliases
        ).contains {
            $0.source == .atum && $0.model == model && $0.selectable && !$0.selected
        }
    }

    // MARK: - The composer chip

    /// What the composer chip draws: its name, provider mark and any known
    /// reason the named plan cannot answer right now (desktop `chipDown`).
    public struct ChipFace: Equatable, Sendable {
        public enum PlanUnavailable: Equatable, Sendable {
            case noMac
            case reconnect
        }

        public let name: String
        public let source: ManagedModelDestinationSource
        public let connectionLabel: String?
        public let planUnavailable: PlanUnavailable?

        public init(name: String, source: ManagedModelDestinationSource, connectionLabel: String? = nil,
                    planUnavailable: PlanUnavailable? = nil) {
            self.name = name
            self.source = source
            self.connectionLabel = connectionLabel
            self.planUnavailable = planUnavailable
        }

        fileprivate init(subscription row: Row) {
            let reason: PlanUnavailable? = switch row.unavailable {
            case .notReady: .noMac
            case .signedOut: .reconnect
            default: nil
            }
            self.init(name: row.displayName, source: row.source, connectionLabel: row.connectionLabel,
                      planUnavailable: reason)
        }
    }

    /// A replay can return a snapshot ahead of the write receipt. Keep the
    /// tapped row's catalog metadata only if the returned cloud choice names it.
    public static func settledDestinationPick(_ row: Row, destination: ManagedModelDestinationSnapshot) -> Row? {
        guard let saved = destination.choice(for: cloudID),
              saved.source == row.source, saved.model == row.model else { return nil }
        return row.selecting(true)
    }

    /// A row a pick wrote, with the readbacks it was made over. The chip names
    /// it at once, before the server's next read, and only until a newer
    /// authoritative read says something else is saved.
    public struct ChipPick: Equatable, Sendable {
        public let row: Row
        /// The 1.3+ destination revision the composer held when the pick
        /// landed; nil when it held none.
        public let destinationRevision: Int64?
        /// The 1.1 offer revision the composer held when the pick landed.
        public let offerRevision: Int64?

        public init(row: Row, destinationRevision: Int64?, offerRevision: Int64?) {
            self.row = row
            self.destinationRevision = destinationRevision
            self.offerRevision = offerRevision
        }
    }

    /// The pick, unless a readback newer than it names another saved choice.
    /// The 1.3+ destination is the authority for the cloud's choice (a
    /// subscription or an Atum model); the 1.1 offer also answers for an Atum
    /// pick. A readback no newer than the pick (the same revision, or a 1.1
    /// write the destination read has not caught up with) never drops it.
    public static func reconciled(_ pick: ChipPick?,
                                  destination: ManagedModelDestinationSnapshot?,
                                  offer: ManagedModelSnapshot?) -> ChipPick? {
        guard let pick else { return nil }
        if let destination, destination.revision > pick.destinationRevision ?? .min {
            let saved = destination.choice(for: cloudID)
            let agrees = saved.map { $0.source == pick.row.source && $0.model == pick.row.model }
                ?? (pick.row.source == .atum && pick.row.model == destination.recommended.model)
            if !agrees { return nil }
        }
        if pick.row.source == .atum, let offer, offer.revision > pick.offerRevision ?? .min,
           offer.choice.model != pick.row.model {
            return nil
        }
        return pick
    }

    /// The chip's face for the cloud conversation (desktop `chipLabel` and
    /// `chipRoute`). A pick still current wins; Atum's line-up is named by its
    /// product name. A subscription model is named by the row the list draws
    /// for it (`subscriptions`): the account's catalog name when that status is
    /// loaded (desktop `relayCurrentName`), else the desktop's words for an
    /// id-only entry, never its raw id. Its mark is matched from that same row.
    /// Nil while nothing names the choice.
    public static func chip(pick: ChipPick?,
                            destination: ManagedModelDestinationSnapshot?,
                            offer: ManagedModelSnapshot?,
                            account: PhoneSubscriptionAccount? = nil) -> ChipFace? {
        if let row = reconciled(pick, destination: destination, offer: offer)?.row {
            if row.source == .atum, let name = ManagedModelLineup.productName(for: row.model) {
                return ChipFace(name: name, source: .atum, connectionLabel: row.connectionLabel)
            }
            if let listed = listedSubscription(row.source, model: row.model, destination: destination, account: account) {
                return ChipFace(subscription: listed)
            }
            return ChipFace(name: row.displayName, source: row.source, connectionLabel: row.connectionLabel)
        }
        if let saved = destination?.choice(for: cloudID) {
            if saved.source == .atum, let name = ManagedModelLineup.productName(for: saved.model) {
                return ChipFace(name: name, source: .atum)
            }
            if saved.source != .atum {
                if let listed = listedSubscription(saved.source, model: saved.model,
                                                   destination: destination, account: account) {
                    return ChipFace(subscription: listed)
                }
                return ChipFace(name: ModelDisplayName.name(model: saved.model), source: saved.source)
            }
        }
        for model in [offer?.choice.model, destination?.recommended.model].compactMap({ $0 }) {
            if let name = ManagedModelLineup.productName(for: model) { return ChipFace(name: name, source: .atum) }
        }
        return nil
    }

    /// The subscription row the conversation picker lists for this model once
    /// the account's status is loaded, so the chip and the list never name one
    /// model two ways. Nil before that read: a pick keeps its own row's name.
    private static func listedSubscription(_ source: ManagedModelDestinationSource, model: String,
                                           destination: ManagedModelDestinationSnapshot?,
                                           account: PhoneSubscriptionAccount?) -> Row? {
        guard source.isSubscription, let destination, let account else { return nil }
        return subscriptions(destination, destination: cloudID, account: account).first {
            $0.source == source && $0.model == model
        }
    }

    private static var cloudID: ManagedModelDestinationID { try! ManagedModelDestinationID("cloud") }

    // MARK: - Thinking level and the way back to Atum

    /// The thinking levels the server offers for the model that answers now, for
    /// the conversation picker: what the 1.1 offer lists that model accepts, in
    /// quick-to-thorough order, and the level it runs at (the saved one, else the
    /// offer's default).
    public struct Thinking: Equatable, Sendable {
        public let model: String
        public let levels: [ManagedModelEffort]
        public let current: ManagedModelEffort?

        public init(model: String, levels: [ManagedModelEffort], current: ManagedModelEffort?) {
            self.model = model
            self.levels = levels
            self.current = current
        }

        public func canChange(to level: ManagedModelEffort) -> Bool {
            levels.contains(level) && level != current
        }
    }

    /// Show recognized levels the model can accept. A single option remains
    /// actionable when a future effort is currently selected.
    public static func thinking(_ snapshot: ManagedModelSnapshot) -> Thinking? {
        guard let offer = snapshot.models.first(where: { $0.alias == snapshot.choice.model }),
              offer.eligibility == .ready else { return nil }
        let levels = offer.efforts
        guard !levels.isEmpty, levels.count > 1 || snapshot.currentEffort == nil else { return nil }
        return Thinking(model: offer.alias, levels: levels, current: snapshot.currentEffort)
    }

    /// The offer can drive thinking only when its choice agrees with the
    /// selected Atum row. The offer and destination have separate revisions.
    public static func conversationThinking(offer: ManagedModelSnapshot,
                                            rows: [Row], work: WorkModelSelectionSnapshot?) -> Thinking? {
        guard work?.permitsCloudEffortWrite(at: offer.revision) == true,
              rows.contains(where: { $0.selected && $0.source == .atum && $0.model == offer.choice.model })
        else { return nil }
        return thinking(offer)
    }

    /// The write boundary for a thinking change, as `canSelectAtumModel` is for a
    /// model: the same model, a level it offers, and not the level already saved.
    public static func canChangeThinking(to level: ManagedModelEffort,
                                         snapshot: ManagedModelSnapshot) -> Bool {
        thinking(snapshot)?.canChange(to: level) == true
    }

    /// The Atum model a Mac returns to when its saved choice is a connection's
    /// (a ChatGPT plan or its own key): the server's recommendation if the phone
    /// can pick it, else the line-up default. Nil when this Mac already answers
    /// with Atum's model, is not a Mac, or is not in the latest snapshot.
    public static func switchBackModel(_ snapshot: ManagedModelDestinationSnapshot,
                                       destination: ManagedModelDestinationID) -> String? {
        guard !destination.isCloud, let saved = snapshot.choice(for: destination),
              saved.source != .atum else { return nil }
        return [snapshot.recommended.model, ManagedModelLineup.defaultAlias].first {
            canSelectAtumModel($0, snapshot: snapshot, destination: destination, cloudEligibleAliases: [])
        }
    }
}
