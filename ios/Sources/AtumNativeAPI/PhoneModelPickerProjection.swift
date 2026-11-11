import Foundation

/// Pure phone presentation derived only from decoded model-choice contracts.
/// It creates no provider account or remote route identity.
public enum PhoneModelPickerProjection {
    public struct Row: Equatable, Sendable {
        /// A small status word drawn beside a model's name. Only data a
        /// phone-visible contract carries is ever drawn: Atum names its default
        /// model. No contract carries a "legacy" flag, so there is no such badge;
        /// the day one does, it is one more case here and one more word in the view.
        public enum Badge: Equatable, Sendable {
            case `default`
        }

        /// Why a subscription's model is listed but cannot be chosen now, in
        /// the desktop's two states for a cloud assistant (`model-picker.tsx`):
        /// a ChatGPT plan no owner Mac relays to the cloud yet
        /// (`chatgptCloudNotReady`), and an OpenCode Go connection that was
        /// disconnected (`modelsSignedOut`).
        public enum Unavailable: Equatable, Sendable {
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
            let ready = offers[alias]?.eligibility == .ready
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
                displayName: saved.model,
                selected: true,
                selectable: false,
                isSubscription: saved.source.isSubscription
            ))
        }

        let selectedAlias = saved.source == .atum ? saved.model : nil
        rows.append(contentsOf: lineupRows { alias in
            (selected: selectedAlias == alias, selectable: true,
             badges: alias == snapshot.recommended.model ? [.default] : [])
        })
        return rows
    }

    /// One 1.3 destination. Cloud remains Atum-only and uses the separately
    /// decoded 1.1 eligibility set; Mac behavior retains truthful external
    /// readback while exposing only Atum aliases for selection.
    public static func destination(_ snapshot: ManagedModelDestinationSnapshot,
                                   destination: ManagedModelDestinationID,
                                   cloudEligibleAliases: Set<String>,
                                   selectedAtumModel: String? = nil) -> [Row] {
        guard destination.isCloud else { return mac(snapshot, destination: destination) }
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
            let eligible = cloudEligibleAliases.contains(alias)
            return (selected: selected == alias, selectable: eligible,
                    badges: eligible && alias == snapshot.recommended.model ? [.default] : [])
        }
    }

    /// The composer's conversation picker. The 1.3/1.4 snapshot is the
    /// authority for the cloud destination's saved choice and subscriptions;
    /// the 1.1 offer is only eligibility and thinking levels. Either one alone
    /// still yields the full Atum line-up, so a missing older read never
    /// removes the picker. With neither read there is nothing to draw.
    public static func conversation(offer: ManagedModelSnapshot?,
                                    destination: ManagedModelDestinationSnapshot?,
                                    destinationID: ManagedModelDestinationID,
                                    cloudEligibleAliases: Set<String>? = nil,
                                    selectedAtumModel: String? = nil) -> [Row] {
        guard let destination else {
            guard let offer else { return [] }
            return cloud(offer).map { row in
                guard let selectedAtumModel else { return row }
                return row.selecting(row.model == selectedAtumModel)
            }
        }
        let fromOffer = Set((offer?.models ?? []).compactMap { model in
            model.eligibility == .ready
                && ManagedModelLineup.servedAliases.contains(model.alias) ? model.alias : nil
        })
        let eligible = fromOffer.union(cloudEligibleAliases ?? [])
        let fallback: Set<String> = eligible.isEmpty && offer == nil
            ? [ManagedModelLineup.defaultAlias] : []
        return self.destination(destination, destination: destinationID,
                                cloudEligibleAliases: eligible.union(fallback),
                                selectedAtumModel: selectedAtumModel)
    }

    /// The cloud's subscription rows, as the desktop lists them for a cloud
    /// assistant (`cloudSubscriptionRoutes`, `model-picker.tsx`): ChatGPT first,
    /// then OpenCode Go, each from the account's own status.
    ///
    /// - A relayed ChatGPT plan lists every model the relay serves, and a
    ///   connected OpenCode Go every model it serves. Each is choosable; the
    ///   saved one is current.
    /// - A saved ChatGPT model with no relay up stays listed, not choosable,
    ///   as not ready (the desktop keeps a plan the cloud cannot reach yet).
    /// - A saved OpenCode Go model whose connection was disconnected stays
    ///   listed, not choosable, as signed out (the desktop's Reconnect note).
    /// - A status the phone could not read (`account` nil, or that provider
    ///   nil) keeps the saved model read-only and current, never a guess.
    ///
    /// A Mac destination has no subscription write on the phone: its saved
    /// choice stays read-only.
    public static func subscriptions(_ snapshot: ManagedModelDestinationSnapshot,
                                     destination: ManagedModelDestinationID,
                                     account: PhoneSubscriptionAccount? = nil) -> [Row] {
        let saved = snapshot.choices.first { $0.destination == destination && $0.source.isSubscription }
        guard destination.isCloud else { return saved.map { [savedRow($0, unavailable: nil)] } ?? [] }

        func served(_ source: ManagedModelDestinationSource,
                    _ models: [SubscriptionModelDescriptor]) -> [Row] {
            models.map { model in
                let current = saved?.source == source && saved?.model == model.id
                return Row(favoriteID: nil, source: source, model: model.id,
                           displayName: model.displayName, selected: current, selectable: !current,
                           isSubscription: true, subscriptionEffort: model.writeEffort)
            }
        }

        var rows: [Row] = []
        let savedPlan = saved?.source == .chatGPTPlan ? saved : nil
        switch account?.chatGPT?.state {
        case .enabled?: rows += served(.chatGPTPlan, account?.chatGPT?.models ?? [])
        case .disabled?: rows += savedPlan.map { [savedRow($0, unavailable: .notReady)] } ?? []
        case nil: rows += savedPlan.map { [savedRow($0, unavailable: nil)] } ?? []
        }
        let savedGo = saved?.source == .opencodeGo ? saved : nil
        switch account?.openCodeGo?.state {
        case .connected?: rows += served(.opencodeGo, account?.openCodeGo?.models ?? [])
        case .disconnected?: rows += savedGo.map { [savedRow($0, unavailable: .signedOut)] } ?? []
        case nil: rows += savedGo.map { [savedRow($0, unavailable: nil)] } ?? []
        }
        return rows
    }

    /// The saved subscription model when the phone cannot offer it: current
    /// only while nothing says it stopped working, and never choosable.
    private static func savedRow(_ choice: ManagedModelDestinationChoice, unavailable: Row.Unavailable?) -> Row {
        Row(favoriteID: nil, source: choice.source, model: choice.model, displayName: choice.model,
            selected: unavailable == nil, selectable: false, isSubscription: true,
            unavailable: unavailable)
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

    // MARK: - Thinking level and the way back to Atum

    /// The thinking levels the server offers for the model that answers now, for
    /// the conversation picker: what the 1.1 offer lists that model accepts, in
    /// quick-to-thorough order, and the level it runs at (the saved one, else the
    /// offer's default).
    public struct Thinking: Equatable, Sendable {
        public let model: String
        public let levels: [ManagedModelEffort]
        public let current: ManagedModelEffort

        public init(model: String, levels: [ManagedModelEffort], current: ManagedModelEffort) {
            self.model = model
            self.levels = levels
            self.current = current
        }
    }

    /// Nothing is offered for a model that cannot be written now (not eligible)
    /// or that accepts one level only: a control with one choice is not a control.
    public static func thinking(_ snapshot: ManagedModelSnapshot) -> Thinking? {
        guard let offer = snapshot.models.first(where: { $0.alias == snapshot.choice.model }),
              offer.eligibility == .ready else { return nil }
        let levels = ManagedModelEffort.allCases.filter { offer.efforts.contains($0) }
        guard levels.count > 1 else { return nil }
        return Thinking(model: offer.alias, levels: levels,
                        current: snapshot.choice.effort ?? offer.defaultEffort)
    }

    /// The write boundary for a thinking change, as `canSelectAtumModel` is for a
    /// model: the same model, a level it offers, and not the level already saved.
    public static func canChangeThinking(to level: ManagedModelEffort,
                                         snapshot: ManagedModelSnapshot) -> Bool {
        guard let thinking = thinking(snapshot) else { return false }
        return thinking.levels.contains(level) && level != thinking.current
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
