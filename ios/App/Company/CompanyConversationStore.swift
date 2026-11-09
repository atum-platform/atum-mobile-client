import AtumChat
import AtumNativeAPI
import Foundation
import Observation

// The phone's company DMs and group DMs (wire 1.5): the probe, each company's
// conversation directory, the conversation room claims, and the open / add
// people / hide actions. It holds no authority: the platform's directory is the
// only thing that says a Matrix room is a conversation, and every action
// re-reads it. The section exists only while the probe says wire 1.5, the
// feature and the tenant's activation are all on.

/// One row of the Direct messages section.
struct ConversationListRow: Identifiable, Equatable {
    let row: ConversationRow
    /// Unread and mention mark from the Matrix room, by Home's `Badge` rule.
    var badge: Badge = .none

    var id: String { row.id }
    var isBold: Bool { TeamSpaceBadges.isBold(badge) }
}

/// What the Workplace list shows for a company's conversations. Absent when
/// the family is off: no section, no placeholder, no request.
struct ConversationSectionPresentation: Equatable {
    let rows: [ConversationListRow]
    /// Folded away under "Hidden".
    let hidden: [ConversationListRow]
    let isLoading: Bool
    /// The list could not be read and there is nothing older to show.
    let failed: Bool
    /// The last read failed transiently: the rows are the last good ones, shown as stale, and
    /// New message, Add people and Hide are closed until a read succeeds.
    let isStale: Bool
    /// The last hide or open that did not happen, worded.
    let notice: String?
}

/// How one New message / Add people ended.
enum ConversationStartOutcome: Equatable {
    /// The conversation's room is joined: open it.
    case opened(roomID: String)
    /// Made, and listed, but its room is not ready yet (bounded wait spent).
    /// Never an error: the row says "Setting up…".
    case settingUp
    case failed(ConversationRefusal)
}

/// A person the picker can offer.
struct ConversationPerson: Identifiable, Equatable {
    let id: String
    let name: String
    let handle: String?
}

/// Who is already in a conversation, for an expansion's explanation.
struct ConversationKept: Equatable {
    let refs: [String]
    let title: String
}

@MainActor
@Observable
final class CompanyConversationStore {
    enum Availability: Equatable {
        /// Not probed yet, or only transient failures so far.
        case unknown
        case unavailable
        case available
    }

    private(set) var availability = Availability.unknown
    /// Whether the last probe authorizes 1.5 requests and writes right now. Separate from whether the
    /// rows are visible: a failed probe keeps the last rows on screen (stale) but sends nothing.
    private(set) var discoveryAuthorizes = false
    private(set) var directories = [String: CompanyConversationDirectory]()
    private(set) var loading = Set<String>()
    private(set) var readFailed = Set<String>()
    private(set) var roomDirectory = ConversationRoomDirectory()
    /// Bumped when the claims change, so room classification is re-run.
    private(set) var revision: UInt64 = 0
    private(set) var failureToken: UInt64 = 0
    private(set) var notices = [String: ConversationRefusal]()
    /// Companies whose last read failed transiently: their rows stay visible but are stale, and
    /// nothing is sent and no composer is open until a read succeeds.
    private(set) var stale = Set<String>()

    /// Set by the workspace model.
    @ObservationIgnored var clientProvider: () -> CompanyConversationsAPI? = { nil }
    @ObservationIgnored var selfRef: (String) -> String? = { _ in nil }
    @ObservationIgnored var presence: (String) -> CompanyRoomPresence = { _ in .unknown }
    @ObservationIgnored var join: (String) async -> Bool = { _ in false }
    @ObservationIgnored var fallbackName: () -> String = { "…" }
    /// Told when conversation rooms lose their directory record (denied, missing or invalid
    /// answer, the family switched off, a company gone): the open chat must close.
    @ObservationIgnored var onAuthorityLost: (Set<String>) -> Void = { _ in }
    /// How long an opened conversation's room is waited for (a test shortens it).
    @ObservationIgnored var convergence = (attempts: CompanyConvergence.attempts,
                                           delayMilliseconds: CompanyConvergence.delayMilliseconds)

    @ObservationIgnored private var tracker = ConversationRequestTracker()
    @ObservationIgnored private var epoch: UInt64 = 0

    private func client() -> CompanyConversationsAPI? { clientProvider() }

    var isAvailable: Bool { availability == .available }

    // MARK: Probe and reads

    /// One probe per refresh. Anything but "yes" hides the section and drops
    /// what was listed; a transient failure keeps what the last good answer
    /// said (and an unprobed store stays unknown, which shows nothing).
    func probe() async {
        guard let client = client() else { return }
        let started = epoch
        let before = discoveryAuthorizes
        do {
            let capabilities = try await client.companyCapabilities()
            guard started == epoch else { return }
            availability = capabilities.offersConversations ? .available : .unavailable
            discoveryAuthorizes = capabilities.offersConversations
        } catch let error as CompanyAPIError {
            guard started == epoch else { return }
            discoveryAuthorizes = false
            switch error {
            case .transport, .unavailable: break   // rows stay, stale; nothing is sent
            case .refused, .invalid: availability = .unavailable
            }
        } catch {
            guard started == epoch else { return }
            discoveryAuthorizes = false
            availability = .unavailable
        }
        if availability != .available { dropLists() }
        if before != discoveryAuthorizes { revision &+= 1 }
    }

    /// Reads one company's conversations. True when the answer is the current
    /// truth (or the family is off and there is nothing to read).
    @discardableResult
    func read(companyID: String) async -> Bool {
        guard isAvailable else { return true }
        // A failed probe closes 1.5 requests, reads included, until the next probe succeeds.
        guard discoveryAuthorizes else { return false }
        guard let client = client(), let id = try? NativeID(companyID) else { return false }
        let started = epoch
        loading.insert(companyID)
        defer { if started == epoch { loading.remove(companyID) } }
        do {
            let directory = try await client.companyConversations(companyID: id)
            guard started == epoch, isAvailable else { return true }
            return apply(directory, companyID: companyID)
        } catch {
            guard started == epoch else { return false }
            ingest(error, companyID: companyID)
            return false
        }
    }

    /// A refused list read. `denied`, `missing` and `invalid` (and an answer that is not the closed
    /// shape) end the authority: the rows, the claims and the open chat go, and nothing is sent.
    /// Anything else (a lost answer, a 503, a rate limit, a sign-in refresh) may be transient: the
    /// rows stay, marked stale, with every write and every composer closed until a read succeeds.
    private func ingest(_ error: Error, companyID: String) {
        if Self.endsAuthority(error) {
            clearAuthority(companyID: companyID)
        } else {
            if directories[companyID] == nil { readFailed.insert(companyID) } else { stale.insert(companyID) }
            revision &+= 1
        }
    }

    static func endsAuthority(_ error: Error) -> Bool {
        guard let error = error as? CompanyAPIError else { return true }
        switch error {
        case .invalid: return true
        // A refusal to authenticate that reaches here already survived the one token refresh: final.
        case let .refused(refusal, _, _): return [.denied, .missing, .invalid, .authentication].contains(refusal)
        case .unavailable, .transport: return false
        }
    }

    private func clearAuthority(companyID: String) {
        let rooms = roomDirectory.roomIDs(companyID: companyID)
        directories.removeValue(forKey: companyID)
        stale.remove(companyID)
        readFailed.insert(companyID)
        notices.removeValue(forKey: companyID)
        roomDirectory.remove(companyID: companyID)
        tracker.clear(company: companyID)
        revision &+= 1
        if !rooms.isEmpty { onAuthorityLost(rooms) }
    }

    /// Writes (New message, Add people, Hide) need the family on and this company's list fresh.
    func canMutate(companyID: String) -> Bool {
        isAvailable && discoveryAuthorizes && directories[companyID] != nil && !stale.contains(companyID)
    }

    /// A list holding a conversation of another company is not this company's answer: it ends the
    /// authority like any other invalid one (the client checks this too; the store does not trust it).
    @discardableResult
    private func apply(_ directory: CompanyConversationDirectory, companyID: String) -> Bool {
        guard directory.conversations.allSatisfy({ $0.companyId.rawValue == companyID }) else {
            clearAuthority(companyID: companyID)
            return false
        }
        let before = roomDirectory.roomIDs(companyID: companyID)
        directories[companyID] = directory
        readFailed.remove(companyID)
        stale.remove(companyID)
        roomDirectory.replace(directory, companyID: companyID, selfRef: selfRef(companyID),
                              fallbackName: fallbackName())
        revision &+= 1
        // A room the platform no longer lists has no authority: its open chat closes.
        let removed = before.subtracting(roomDirectory.roomIDs(companyID: companyID))
        if !removed.isEmpty { onAuthorityLost(removed) }
        return true
    }

    /// A company that left the account's list loses its conversations.
    func retain(companies: Set<String>) {
        for company in Array(directories.keys) where !companies.contains(company) {
            directories.removeValue(forKey: company)
            notices.removeValue(forKey: company)
        }
        for operation in Array(tracker.pending.keys) where !companies.contains(operation.company) {
            tracker.clear(company: operation.company)
        }
        readFailed.formIntersection(companies)
        stale.formIntersection(companies)
        roomDirectory.retain(companies: companies)
        revision &+= 1
    }

    func remove(companyID: String) {
        directories.removeValue(forKey: companyID)
        readFailed.remove(companyID)
        stale.remove(companyID)
        notices.removeValue(forKey: companyID)
        roomDirectory.remove(companyID: companyID)
        tracker.clear(company: companyID)
        revision &+= 1
    }

    /// The family is off (or the account ended): every list and claim goes. Unresolved request ids
    /// stay (they end with a terminal outcome, their company's clearing or the account), so a Retry
    /// after the gate reopens replays the same operation.
    private func dropLists(notify: Bool = true) {
        guard !directories.isEmpty || !roomDirectory.isEmpty || !readFailed.isEmpty || !stale.isEmpty else { return }
        var rooms = Set<String>()
        for company in roomDirectory.companyIDs { rooms.formUnion(roomDirectory.roomIDs(companyID: company)) }
        directories.removeAll()
        readFailed.removeAll()
        stale.removeAll()
        loading.removeAll()
        notices.removeAll()
        roomDirectory.clear()
        revision &+= 1
        if notify, !rooms.isEmpty { onAuthorityLost(rooms) }
    }

    /// The account ended or changed.
    func reset(notify: Bool = false) {
        epoch &+= 1
        availability = .unknown
        discoveryAuthorizes = false
        dropLists(notify: notify)
        tracker.clear()
        revision &+= 1
    }

    // MARK: Presentation

    func section(companyID: String, signals: CompanyRoomSignals, activity: [String: Date],
                 locale: Locale) -> ConversationSectionPresentation? {
        guard isAvailable else { return nil }
        let rows: [ConversationListRow]
        if let directory = directories[companyID] {
            rows = ConversationRows.rows(directory, selfRef: selfRef(companyID),
                                         fallbackName: fallbackName(), activity: activity, locale: locale)
                .map { row in
                    ConversationListRow(
                        row: row,
                        badge: row.roomID.flatMap { signals[$0] }.map(Badge.mark(for:)) ?? .none)
                }
        } else {
            rows = []
        }
        return ConversationSectionPresentation(
            rows: rows.filter { !$0.row.isHidden },
            hidden: rows.filter { $0.row.isHidden },
            isLoading: loading.contains(companyID) && directories[companyID] == nil,
            failed: readFailed.contains(companyID) && directories[companyID] == nil,
            isStale: stale.contains(companyID) || !discoveryAuthorizes,
            notice: nil)
    }

    func refusal(companyID: String) -> ConversationRefusal? { notices[companyID] }

    func clearNotice(companyID: String) { notices.removeValue(forKey: companyID) }

    /// The conversation a Matrix room belongs to. Believed only when the directory has a record that
    /// matches all three of company, conversation and room: a room that merely claims the type, or
    /// whose record names another room, has no authority and nothing of it is shown.
    func claim(roomID: String) -> ConversationRoomClaim? {
        guard let claim = roomDirectory.claim(roomID: roomID),
              let record = record(for: claim), record.room.roomId == roomID else { return nil }
        return claim
    }

    private func record(for claim: ConversationRoomClaim) -> CompanyConversation? {
        directories[claim.companyID]?.conversations.first {
            $0.id.rawValue == claim.conversationID && $0.companyId.rawValue == claim.companyID
        }
    }

    func conversation(roomID: String) -> CompanyConversation? {
        guard let claim = claim(roomID: roomID) else { return nil }
        return record(for: claim)
    }

    /// Whether the record behind a room is from a successful read (not a stale one).
    func isFresh(roomID: String) -> Bool {
        guard let claim = claim(roomID: roomID) else { return false }
        return isAvailable && discoveryAuthorizes && !stale.contains(claim.companyID)
    }

    func kept(roomID: String) -> ConversationKept? {
        guard let conversation = conversation(roomID: roomID), let me = selfRef(conversation.companyId.rawValue)
        else { return nil }
        return ConversationKept(refs: conversation.participants.map(\.memberRef).filter { $0 != me },
                                title: ConversationRows.title(of: conversation, selfRef: me,
                                                              fallbackName: fallbackName()))
    }

    // MARK: Actions

    /// New message: one other person is a DM, several a group. The set is
    /// opened atomically on the platform; the same people always open the same
    /// conversation, in any order. A lost answer is retried with the same
    /// request id.
    func start(companyID: String, others: [String],
               isCurrent: @MainActor () -> Bool = { true }) async -> ConversationStartOutcome {
        guard let me = selfRef(companyID), let refs = ConversationPeople.refs(selfRef: me, others: others)
        else { return .failed(.plain(.invalid)) }
        return await perform(companyID: companyID, operation: .open(company: companyID, people: refs),
                             isCurrent: isCurrent) { client, company, request in
            try await client.openCompanyConversation(companyID: company, requestID: request,
                                                     participantMemberRefs: refs)
        }
    }

    /// Add people: a new conversation with the whole larger set. The source is
    /// not changed and no history is carried over.
    func addPeople(companyID: String, sourceConversationID: String, others: [String],
                   isCurrent: @MainActor () -> Bool = { true }) async -> ConversationStartOutcome {
        guard let me = selfRef(companyID), let refs = ConversationPeople.refs(selfRef: me, others: others),
              refs.count >= 3, let source = try? NativeID(sourceConversationID)
        else { return .failed(.plain(.invalid)) }
        return await perform(companyID: companyID,
                             operation: .expand(company: companyID, source: sourceConversationID, people: refs),
                             isCurrent: isCurrent) { client, company, request in
            try await client.expandCompanyConversation(companyID: company, sourceConversationID: source,
                                                       requestID: request, participantMemberRefs: refs)
        }
    }

    private func perform(
        companyID: String, operation: ConversationRequestTracker.Operation,
        isCurrent: @MainActor () -> Bool,
        call: (CompanyConversationsAPI, NativeID, NativeID) async throws -> CompanyConversationAnswer
    ) async -> ConversationStartOutcome {
        // The family can be switched off under an open picker.
        // Every try, a Retry included, passes the 1.5 gate again; a stale or cleared company sends nothing.
        guard canMutate(companyID: companyID), let client = client(), let company = try? NativeID(companyID)
        else { return .failed(.plain(.unavailable)) }
        let started = epoch
        let requestID = tracker.requestID(for: operation) { UUID().uuidString.lowercased() }
        guard let request = try? NativeID(requestID) else { return .failed(.lost) }
        do {
            let answer = try await call(client, company, request)
            guard started == epoch else { return .failed(.lost) }
            tracker.succeeded(operation)
            // The conversation is made and will be listed; if the person has moved on, nothing joins or opens.
            guard isCurrent() else { return .settingUp }
            return await converge(answer.conversation, companyID: companyID, client: client, isCurrent: isCurrent)
        } catch let error as CompanyAPIError {
            guard started == epoch else { return .failed(.lost) }
            let refusal = ConversationRefusal(error)
            tracker.failed(operation, refusal)
            failureToken &+= 1
            return .failed(refusal)
        } catch {
            guard started == epoch else { return .failed(.lost) }
            failureToken &+= 1
            return .failed(.lost)
        }
    }

    /// The made conversation is listed at once, shown again if it was hidden,
    /// and its room is waited for, bounded. Never a substitute room.
    private func converge(_ made: CompanyConversation, companyID: String,
                          client: CompanyConversationsAPI,
                          isCurrent: @MainActor () -> Bool) async -> ConversationStartOutcome {
        let started = epoch
        var current = made
        // Opening a set that was hidden shows it again (the re-read below lists it).
        if made.hidden {
            _ = await setHiddenQuietly(companyID: companyID, conversationID: made.id, hidden: false, client: client)
        }
        guard let company = try? NativeID(companyID) else { return .settingUp }
        for attempt in 0..<convergence.attempts {
            if Task.isCancelled || started != epoch { return .settingUp }
            // The family can be switched off, or the list denied, while the room is awaited.
            guard isAvailable, discoveryAuthorizes else { return .failed(.plain(.unavailable)) }
            guard isCurrent() else { return .settingUp }
            do {
                let directory = try await client.companyConversations(companyID: company)
                guard started == epoch, isCurrent() else { return .settingUp }
                guard isAvailable, discoveryAuthorizes else { return .failed(.plain(.unavailable)) }
                guard apply(directory, companyID: companyID) else { return .failed(.plain(.unavailable)) }
                if let listed = directory.conversations.first(where: { $0.id == made.id }) { current = listed }
            } catch {
                guard started == epoch else { return .settingUp }
                ingest(error, companyID: companyID)
                if Self.endsAuthority(error) { return .failed(.plain(.unavailable)) }
            }
            let roomID = current.room.roomId
            let step = ConversationConvergence.step(
                attempt: attempt, conversation: current,
                presence: roomID.map(presence) ?? .unknown)
            guard isCurrent() else { return .settingUp }
            switch step {
            case let .open(room): return .opened(roomID: room)
            case let .join(room):
                // The one join a conversation room may have: directory-confirmed, company still current.
                let joined = await join(room)
                guard started == epoch, isCurrent() else { return .settingUp }
                if joined { continue }
            case .wait: break
            case .giveUp: return .settingUp
            }
            if attempt + 1 < convergence.attempts {
                do { try await Task.sleep(for: .milliseconds(convergence.delayMilliseconds)) }
                catch { return .settingUp }
            }
        }
        return .settingUp
    }

    /// Opening a row: a hidden conversation is shown again first.
    func prepareToOpen(companyID: String, conversationID: String) async {
        guard canMutate(companyID: companyID), let client = client(), let id = try? NativeID(conversationID),
              directories[companyID]?.conversations.first(where: { $0.id == id })?.hidden == true else { return }
        _ = await setHiddenQuietly(companyID: companyID, conversationID: id, hidden: false, client: client)
        await read(companyID: companyID)
    }

    /// Hide / unhide: the person's own view only. True when the platform
    /// confirmed it (the list is re-read either way).
    @discardableResult
    func setHidden(companyID: String, conversationID: String, hidden: Bool) async -> Bool {
        guard canMutate(companyID: companyID), let client = client(), let id = try? NativeID(conversationID)
        else { return false }
        let ok = await setHiddenQuietly(companyID: companyID, conversationID: id, hidden: hidden, client: client)
        if !ok { failureToken &+= 1 }
        await read(companyID: companyID)
        return ok
    }

    private func setHiddenQuietly(companyID: String, conversationID: NativeID, hidden: Bool,
                                  client: CompanyConversationsAPI) async -> Bool {
        guard let company = try? NativeID(companyID) else { return false }
        let operation = ConversationRequestTracker.Operation.hidden(company: companyID,
                                                                    conversation: conversationID.rawValue,
                                                                    hidden: hidden)
        let requestID = tracker.requestID(for: operation) { UUID().uuidString.lowercased() }
        guard let request = try? NativeID(requestID) else { return false }
        do {
            _ = try await client.setCompanyConversationHidden(companyID: company, conversationID: conversationID,
                                                              requestID: request, hidden: hidden)
            tracker.succeeded(operation)
            notices.removeValue(forKey: companyID)
            return true
        } catch let error as CompanyAPIError {
            let refusal = ConversationRefusal(error)
            tracker.failed(operation, refusal)
            notices[companyID] = refusal
            return false
        } catch {
            notices[companyID] = .lost
            return false
        }
    }

    // MARK: People

    /// The people the picker offers for a company: its active members except
    /// the caller (and, for an expansion, except those already in).
    func candidates(members: [CompanyMember], companyID: String, excluding kept: Set<String>) -> [ConversationPerson] {
        ConversationPeople.candidates(members: members, selfRef: selfRef(companyID), excluding: kept)
            .map { member in
                ConversationPerson(id: member.memberRef,
                                   name: member.displayName ?? member.handle.map { "@" + $0 } ?? fallbackName(),
                                   handle: member.handle)
            }
    }
}
