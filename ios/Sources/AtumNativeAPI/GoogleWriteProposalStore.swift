import Foundation
import Observation

public enum GoogleWriteProposalSurface: Hashable, Sendable {
    case assistant(roomID: String)
    case work
}

public enum GoogleWriteProposalState: Equatable, Sendable {
    case pending, deciding(GoogleWriteDecision), failedRetryable
    case approved, declined, superseded, expired, changed, closed, unsupported

    fileprivate var canDecide: Bool { self == .pending || self == .failedRetryable }

    fileprivate var isDeciding: Bool {
        if case .deciding = self { return true }
        return false
    }

    fileprivate var isOpen: Bool { canDecide || isDeciding }
}

public struct GoogleWriteProposalCard: Equatable, Identifiable, Sendable {
    /// Capture this value from the rendered card when sending a decision. A
    /// stale view cannot act on a proposal that belongs to a new session.
    public struct ID: Hashable, Sendable {
        fileprivate let session: UUID
        public let proposalID: NativeID
    }

    public let id: ID
    public let source: GoogleWriteProposalSource
    public let kind: GoogleWriteProposalKind
    public let previewLines: [GoogleWritePreviewLine]
    public let mailboxOperation: GoogleMailboxOperation?
    public let state: GoogleWriteProposalState
    public let canDecide: Bool

    fileprivate init(session: UUID, proposal: GoogleWriteProposal, state: GoogleWriteProposalState, canDecide: Bool) {
        id = ID(session: session, proposalID: proposal.id)
        source = proposal.source
        kind = proposal.kind
        previewLines = proposal.previewLines
        mailboxOperation = proposal.mailboxOperation
        self.state = state
        self.canDecide = canDecide
    }
}

/// One in-memory owner feed shared by the assistant and Work surfaces.
@available(macOS 14.0, *)
@MainActor @Observable public final class GoogleWriteProposalStore {
    public private(set) var accountID: String?
    public private(set) var session = UUID()
    public private(set) var cards: [GoogleWriteProposalCard] = []

    @ObservationIgnored private var api: (any GoogleWriteProposalAPI)?
    @ObservationIgnored private var entries: [Entry] = []
    @ObservationIgnored private var retired = Set<NativeID>()
    @ObservationIgnored private var inFlight = Set<DecisionKey>()
    @ObservationIgnored private var visible = Set<GoogleWriteProposalSurface>()
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var queuedRefresh: RefreshTrigger?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable () async throws -> Void

    public convenience init() {
        self.init(sleep: { try await Task.sleep(for: .seconds(5)) })
    }

    init(sleep: @escaping @Sendable () async throws -> Void) {
        self.sleep = sleep
    }

    /// Bind to the live owner and its domain client together. A new client,
    /// account or sign-out retires all previous projections synchronously.
    public func bind(accountID: String?, api: (any GoogleWriteProposalAPI)?) {
        let account = api == nil ? nil : accountID.flatMap { $0.isEmpty ? nil : $0 }
        let client = account == nil ? nil : api
        guard self.accountID != account || self.api !== client else { return }
        session = UUID()
        self.accountID = account
        self.api = client
        refreshTask?.cancel()
        refreshTask = nil
        queuedRefresh = nil
        pollTask?.cancel()
        pollTask = nil
        visible.removeAll()
        entries.removeAll()
        retired.removeAll()
        cards = []
    }

    public func cards(for surface: GoogleWriteProposalSurface) -> [GoogleWriteProposalCard] {
        cards.filter { card in
            switch (card.source, surface) {
            case (.work, .work): true
            case let (.assistant(_, room), .assistant(visibleRoom)): room == visibleRoom
            default: false
            }
        }
    }

    /// Supply the session captured when the surface was mounted. Late
    /// disappearance callbacks cannot remove a new account's registration.
    public func setVisible(_ isVisible: Bool, for surface: GoogleWriteProposalSurface, session: UUID) {
        guard self.session == session, api != nil else { return }
        let changed = isVisible ? visible.insert(surface).inserted : visible.remove(surface) != nil
        guard changed else { return }
        if isVisible && foreground { requestRefresh(.visible) }
        updatePolling()
    }

    /// Scene activation also covers focus regained. Reads run while a consumer
    /// is visible, and the shared poll stops as soon as the scene loses focus.
    public func setForeground(_ isForeground: Bool) {
        guard foreground != isForeground else { return }
        foreground = isForeground
        if isForeground && !visible.isEmpty { requestRefresh(.visible) }
        updatePolling()
    }

    /// Matrix is only a refresh hint. Call from an assistant-room subscription
    /// when a new message arrives, including before the first card exists.
    public func hintAssistantMessage(roomID: String, session: UUID) {
        guard self.session == session, foreground, visible.contains(.assistant(roomID: roomID)) else { return }
        requestRefresh(.visible)
    }

    /// An explicit read for the current session. A failed read keeps the last
    /// projection. Concurrent triggers share one request and at most one rerun.
    public func refresh() async {
        await requestRefresh()?.value
    }

    public func decide(_ decision: GoogleWriteDecision, cardID: GoogleWriteProposalCard.ID) async {
        guard cardID.session == session, let api, let accountID,
              let index = entries.firstIndex(where: { $0.proposal.id == cardID.proposalID }),
              entries[index].state.canDecide else { return }
        let proposal = entries[index].proposal
        let key = DecisionKey(accountID: accountID, proposalID: proposal.id)
        guard inFlight.insert(key).inserted else { return }
        entries[index].state = .deciding(decision)
        publish()

        let result = await api.decideGoogleWriteProposal(decision, proposal: proposal, isCurrent: { [weak self] in
            self?.session == cardID.session
        })
        inFlight.remove(key)
        if cardID.session != session {
            // The same owner can return while a previous dispatch is still
            // finishing. Use a fresh list for the new session's state.
            if self.accountID == accountID {
                publish()
                requestRefresh(.visible)
            }
            return
        }
        guard let current = entries.firstIndex(where: { $0.proposal.id == cardID.proposalID }) else { return }

        switch result {
        case .accepted: entries[current].state = decision == .approve ? .approved : .declined
        case .refused: entries[current].state = proposal.source == .work ? .expired : .closed
        case .changed: entries[current].state = .changed
        case .unavailable: entries[current].state = .failedRetryable
        }
        if result != .unavailable { retired.insert(proposal.id) }
        publish()
        await refresh()
    }

    private enum RefreshTrigger { case visible, explicit }

    private struct DecisionKey: Hashable {
        let accountID: String
        let proposalID: NativeID
    }

    private func canRefresh(_ trigger: RefreshTrigger, session: UUID) -> Bool {
        self.session == session && (trigger == .explicit || (foreground && !visible.isEmpty))
    }

    @discardableResult private func requestRefresh(_ trigger: RefreshTrigger = .explicit) -> Task<Void, Never>? {
        guard let api else { return nil }
        if queuedRefresh != .explicit { queuedRefresh = trigger }
        if let refreshTask { return refreshTask }
        let session = session
        let task = Task { [weak self] in
            while self?.session == session, let trigger = self?.queuedRefresh, !Task.isCancelled {
                self?.queuedRefresh = nil
                guard self?.canRefresh(trigger, session: session) == true else { break }
                let proposals = try? await api.googleWriteProposals(isCurrent: { [weak self] in
                    self?.canRefresh(trigger, session: session) == true
                })
                guard let self, self.session == session, !Task.isCancelled else { return }
                if let proposals { self.apply(proposals) }
            }
            if self?.session == session { self?.refreshTask = nil }
        }
        refreshTask = task
        return task
    }

    private func updatePolling() {
        guard foreground, !visible.isEmpty, api != nil else {
            pollTask?.cancel()
            pollTask = nil
            return
        }
        guard pollTask == nil else { return }
        let session = session
        pollTask = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do { try await sleep() }
                catch { return }
                guard let self, self.session == session, !Task.isCancelled else { return }
                self.requestRefresh(.visible)
            }
        }
    }

    private struct Entry {
        let proposal: GoogleWriteProposal
        var state: GoogleWriteProposalState
        var surface: GoogleWriteProposalSurface? {
            switch proposal.source {
            case let .assistant(_, room): .assistant(roomID: room)
            case .work: .work
            case .unsupported: nil
            }
        }
    }

    private func apply(_ proposals: [GoogleWriteProposal]) {
        let byID = Dictionary(proposals.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in entries.indices {
            let entry = entries[index]
            // An authenticated answer wins over a list refreshed during the POST.
            guard !entry.state.isDeciding, !retired.contains(entry.proposal.id) else { continue }
            if let latest = byID[entry.proposal.id] {
                if !entry.proposal.sameApproval(as: latest) {
                    entries[index].state = .changed
                    retired.insert(entry.proposal.id)
                }
            } else if entry.state.isOpen || entry.state == .unsupported || entry.state == .changed {
                let replaced = proposals.contains { $0.source == entry.proposal.source }
                entries[index].state = replaced ? .superseded : (entry.proposal.source == .work ? .expired : .closed)
                retired.insert(entry.proposal.id)
            }
        }

        var seen = Set(entries.map { $0.proposal.id })
        for proposal in proposals where !retired.contains(proposal.id) && seen.insert(proposal.id).inserted {
            let state: GoogleWriteProposalState
            if case .unsupported = proposal.kind { state = .unsupported }
            else { state = proposal.digestMatchesPreview ? .pending : .changed }
            entries.append(Entry(proposal: proposal, state: state))
        }

        // Keep only the recent settled projections per surface, like desktop.
        // Retired IDs keep stale lists from reopening any evicted decision.
        var settledCounts = [GoogleWriteProposalSurface: Int]()
        entries = entries.reversed().filter { entry in
            guard retired.contains(entry.proposal.id) else { return true }
            guard let surface = entry.surface else { return false }
            settledCounts[surface, default: 0] += 1
            return settledCounts[surface, default: 0] <= (surface == .work ? 1 : 3)
        }.reversed()
        publish()
    }

    private func publish() {
        guard let accountID else { return }
        let next = entries.map { entry in
            let key = DecisionKey(accountID: accountID, proposalID: entry.proposal.id)
            return GoogleWriteProposalCard(session: session, proposal: entry.proposal, state: entry.state,
                                           canDecide: entry.state.canDecide && !inFlight.contains(key))
        }
        if cards != next { cards = next }
    }
}

private extension GoogleWriteProposal {
    func sameApproval(as latest: Self) -> Bool {
        source == latest.source && kind == latest.kind && digest == latest.digest
            && digestMatchesPreview == latest.digestMatchesPreview
    }
}
