import AtumChat
import AtumNativeAPI
import Foundation
import Observation

// The phone's Team Space state (B19 S4): one probe, the company list, each
// company's channel directory and member snapshot, the join/leave
// convergence, and the room classification. It holds no authority: every
// value comes from the 1.1 wire and every action re-reads the platform.

/// A company invitation waiting at the top of Workplace.
struct CompanyHomeRow: Identifiable, Equatable {
    let id: String
    let companyID: String
    /// The platform invitation ID.
    let invitationID: String
    let title: String
    let subtitle: String?
}

struct CompanyChannelRow: Identifiable, Equatable {
    let id: String
    let title: String
    let state: String
    let roomID: String?
    let memberCount: Int
    let canOpen: Bool
    /// Unread and mention mark from the Matrix room, by Home's `Badge` rule.
    var badge: Badge = .none
    var isMuted = false

    var isBold: Bool { TeamSpaceBadges.isBold(badge) }
}

/// How one create ended. `roomID` is the new company's default channel once
/// the phone could open it; nil while the channel is still being prepared (the
/// list says so).
enum CompanyCreateResult: Equatable {
    case created(roomID: String?)
    case failed(CompanyCreateFailure)
}

/// One company in the switcher sheet.
struct CompanySwitcherEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let badge: Badge
    let isActive: Bool
}

struct CompanyMemberRow: Identifiable, Equatable {
    let id: String
    let name: String
    let handle: String?
    let role: String
    let state: String?
    let isSelf: Bool
}

/// The active company's Workplace root: its channel list and header state.
struct CompanyWorkspacePresentation: Identifiable, Equatable {
    let id: String
    let title: String
    let channels: [CompanyChannelRow]
    let members: [CompanyMemberRow]
    let channelsLoading: Bool
    let membersLoading: Bool
    let leavePending: Bool
    let notice: String?
    let error: String?
    /// Direct messages; nil unless the server, the feature and the tenant all say yes.
    var conversations: ConversationSectionPresentation?
}

/// The Matrix unread state of every company channel room, by room ID. The app
/// derives it from the live room list; the model never reads Matrix itself.
typealias CompanyRoomSignals = [String: Badge.Input]

enum CompanyRoomClassification: Equatable {
    case company(CompanyRoomClaim)
    /// A company DM or group DM, believed because the conversation directory lists it.
    case conversation(ConversationRoomClaim)
    case privateCos(companyID: String)
    /// Claims to be a company conversation and is not listed: shown nowhere.
    case quarantined
    case personal
    case unknown
}

@MainActor
@Observable
final class CompanyWorkspaceModel {
    enum Phase: Equatable {
        case idle
        case probing
        /// The server speaks 1.1. `list` may still be empty.
        case ready
        /// A v1 server (or a rolled-back Shell): hide every 1.1 surface.
        case hidden
        case unavailable
    }

    private(set) var phase = Phase.idle
    private(set) var list: CompanyList?
    private(set) var channelsByCompany = [String: CompanyChannelDirectory]()
    private(set) var snapshotsByCompany = [String: CompanySnapshot]()
    private(set) var channelsLoading = Set<String>()
    private(set) var membersLoading = Set<String>()
    private(set) var leavePending = Set<String>()
    private(set) var actionFailureToken: UInt64 = 0
    private(set) var roomDirectory = CompanyRoomDirectory()
    private(set) var classificationComplete = false
    private(set) var classificationBase: UInt64 = 0
    /// Re-run room classification when this changes: the company directories, the type claims
    /// and the conversation claims all feed it.
    var classificationRevision: UInt64 { classificationBase &+ conversations.revision }
    /// Company DMs and group DMs (wire 1.5). The directory it keeps is the only authority for
    /// "this Matrix room is a conversation".
    let conversations = CompanyConversationStore()
    private(set) var privateCosBindings = CompanyPrivateCosBindings()

    /// Set by the root: the production client, the Matrix presence the
    /// convergence asks about, and the existing chat's join.
    @ObservationIgnored var clientProvider: () -> CompanyWorkspaceAPI? = { nil }
    /// Read-only private-CoS discovery and views, using the same account client.
    @ObservationIgnored var privateCosProvider: () -> CompanyPrivateCosAPI? = { nil }
    /// Existing Matrix room content, never a new untranslated label.
    @ObservationIgnored var privateCosRoomTitle: (String) -> String? = { _ in nil }
    /// The same client's 1.3 discovery and 1.5 conversation calls; nil keeps Direct messages off.
    @ObservationIgnored var conversationsProvider: () -> CompanyConversationsAPI? = { nil }
    @ObservationIgnored var presence: (String) -> CompanyRoomPresence = { _ in .unknown }
    @ObservationIgnored var join: (String) async -> Bool = { _ in false }
    /// The one join a company conversation's room may have: its invitation is accepted only by the
    /// directory-confirmed conversation convergence. `join` (channels) never joins such a room.
    @ObservationIgnored var conversationJoin: (String) async -> Bool = { _ in false }
    @ObservationIgnored var copy: CompanyCopy?
    /// Rooms that belonged to a company the person just left, so the open
    /// chat can close instead of reading a banned room.
    @ObservationIgnored var onLeft: (Set<String>) -> Void = { _ in }

    @ObservationIgnored private var leaveTracker = CompanyLeaveTracker()
    /// The create in flight, kept until its outcome is known so a retry after
    /// a lost answer replays the same request instead of making a second company.
    @ObservationIgnored private var createTracker = CompanyCreateTracker()
    @ObservationIgnored private var isCreating = false
    /// The create in flight, so sign-out can cancel it.
    @ObservationIgnored private var createTask: Task<CompanyCreateResult, Never>?
    /// Bumped whenever the account scope ends or changes. A create captures it
    /// when it starts and every completion path checks it, so a create that was
    /// started for one account can never write into the next one.
    @ObservationIgnored private var accountEpoch: UInt64 = 0
    @ObservationIgnored private var journal = CompanyLeaveJournal()
    /// "Not now" answers and the company last shown, kept per account.
    @ObservationIgnored private var prefs = CompanyLocalPrefs()
    @ObservationIgnored private var prefsJournal = CompanyLocalPrefsJournal()
    private(set) var prefsRevision: UInt64 = 0
    @ObservationIgnored private var noticeCompanies = Set<String>()
    @ObservationIgnored private var actionError: String?
    @ObservationIgnored private var actionErrorCompany: String?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var leaveTasks = [String: Task<Void, Never>]()
    @ObservationIgnored private var hasLoadedJournal = false
    @ObservationIgnored private var knownPersonalRoomIDs = Set<String>()
    @ObservationIgnored private var quarantinedCompanyRoomIDs = Set<String>()
    /// Rooms whose create event claims the company conversation type. A display hint
    /// only (anyone can create a room of any type): such a room shows nowhere unless the
    /// conversation directory lists it with that room id.
    @ObservationIgnored private var conversationTypeClaims = Set<String>()
    @ObservationIgnored private var accountScopeID: String?

    private func client() -> CompanyWorkspaceAPI? { clientProvider() }

    init() {
        conversations.clientProvider = { [weak self] in self?.conversationsProvider() }
        conversations.selfRef = { [weak self] companyID in
            self?.snapshotsByCompany[companyID]?.members.first(where: \.isSelf)?.memberRef
        }
        conversations.onAuthorityLost = { [weak self] rooms in self?.onLeft(rooms) }
        conversations.presence = { [weak self] in self?.presence($0) ?? .unknown }
        conversations.join = { [weak self] in await self?.conversationJoin($0) ?? false }
        conversations.fallbackName = { [weak self] in
            self?.copy?.text(CompanyCopyKey("someone")) ?? "…"
        }
    }

    // MARK: Reads

    func refresh() async {
        guard phase != .hidden, let client = client() else {
            if client() == nil { phase = .idle }
            return
        }
        generation &+= 1
        let scope = generation
        invalidateClassification()
        if phase == .idle || phase == .unavailable { phase = .probing }
        do {
            let read = try await client.companyList()
            guard scope == generation, self.client() === client else { return }
            switch read {
            case .v1:
                hideForDowngrade()
            case let .v1_1(value):
                await applyList(value, client: client, scope: scope)
            }
        } catch {
            guard scope == generation, self.client() === client else { return }
            if CompanyWireDegrade.shouldDegrade(error) {
                hideForDowngrade()
            } else if list == nil {
                phase = .unavailable
            }
            // A stale list stays; the next foreground retries.
        }
    }

    /// The channels sheet's refresh: one company, both reads.
    func refreshCompany(_ companyID: String) async {
        guard let client = client(), let id = try? NativeID(companyID) else { return }
        actionError = nil
        actionErrorCompany = nil
        generation &+= 1
        let scope = generation
        let wasComplete = classificationComplete
        invalidateClassification()
        async let channels = readChannels(id: id, companyID: companyID, client: client, scope: scope)
        async let snapshot = readSnapshot(id: id, companyID: companyID, client: client, scope: scope)
        let (directory, _) = await (channels, snapshot)
        guard scope == generation, self.client() === client else { return }
        // The members are read first: a conversation's title needs to know who "me" is.
        let conversationsRead = await conversations.read(companyID: companyID)
        guard scope == generation, self.client() === client else { return }
        await readPrivateCos(companies: [companyID], scope: scope)
        guard scope == generation, self.client() === client else { return }
        if wasComplete, directory != nil, conversationsRead { setClassificationComplete(true) }
    }

    private func applyList(_ value: CompanyList, client: CompanyWorkspaceAPI, scope: UInt64) async {
        list = value
        prunePrefs(value)
        if phase != .ready { phase = .probing }
        let companies = Set(value.companies.map(\.id.rawValue))
        let removedCompanies = roomDirectory.companyIDs.subtracting(companies)
        var removedRooms = Set<String>()
        for companyID in removedCompanies {
            let rooms = roomDirectory.roomIDs(companyID: companyID)
            removedRooms.formUnion(rooms)
            quarantinedCompanyRoomIDs.formUnion(rooms)
        }
        for (company, view) in privateCosBindings.views where !companies.contains(company) {
            if let room = view.binding?.roomId { removedRooms.insert(room) }
        }
        privateCosBindings.retain(companies: companies)
        classificationBase &+= 1
        roomDirectory.retain(companies: companies)
        for companyID in conversations.roomDirectory.companyIDs.subtracting(companies) {
            removedRooms.formUnion(conversations.roomDirectory.roomIDs(companyID: companyID))
        }
        quarantinedCompanyRoomIDs.formUnion(removedRooms)
        conversations.retain(companies: companies)
        if !removedRooms.isEmpty { onLeft(removedRooms) }
        channelsByCompany = channelsByCompany.filter { companies.contains($0.key) }
        snapshotsByCompany = snapshotsByCompany.filter { companies.contains($0.key) }
        leavePending.formIntersection(companies)
        noticeCompanies.formIntersection(companies)

        var directoriesComplete = true
        // One probe per refresh: Direct messages exist only while the server says so.
        await conversations.probe()
        guard scope == generation, self.client() === client else { return }
        for company in value.companies {
            let directory = await readChannels(id: company.id, companyID: company.id.rawValue,
                                               client: client, scope: scope)
            if directory == nil { directoriesComplete = false }
            _ = await readSnapshot(id: company.id, companyID: company.id.rawValue,
                                   client: client, scope: scope)
            // After the members: the picker and the titles need the caller's own ref.
            if !(await conversations.read(companyID: company.id.rawValue)) { directoriesComplete = false }
        }
        guard scope == generation, self.client() === client, phase != .hidden else { return }
        // Publish company access before any positive binding removes a Home row.
        phase = .ready
        await readPrivateCos(companies: value.companies.map { $0.id.rawValue }, scope: scope)
        guard scope == generation, self.client() === client, phase != .hidden else { return }
        setClassificationComplete(directoriesComplete)
        await resumePendingLeaveIfNeeded(client: client, scope: scope)
    }

    /// A positive GET binding is the only private-CoS classification input.
    /// Failures retain prior positive knowledge and retry on every refresh.
    private func readPrivateCos(companies: [String], scope: UInt64) async {
        guard !companies.isEmpty, let api = privateCosProvider(), let account = accountScopeID else { return }
        do {
            _ = try await api.companyPrivateCosCapability()
            guard scope == generation, privateCosProvider() === api, accountScopeID == account else { return }
            for company in companies {
                do {
                    let view = try await api.companyPrivateCosView(companyID: NativeID(company))
                    guard scope == generation, privateCosProvider() === api, accountScopeID == account else { return }
                    guard view.pair.companyPrincipal.rawValue == company,
                          list?.companies.contains(where: { $0.id.rawValue == company }) == true
                    else { throw CompanyAPIError.invalid }
                    let oldRooms = privateCosBindings.roomIDs
                    privateCosBindings.apply(view, companyID: company, accountID: account)
                    knownPersonalRoomIDs.subtract(privateCosBindings.roomIDs)
                    classificationBase &+= 1
                    let removed = oldRooms.subtracting(privateCosBindings.roomIDs)
                    if !removed.isEmpty { onLeft(removed) }
                    LiveFlowLog.privateCosRead(view.binding == nil ? .unbound : .bound)
                } catch {
                    guard scope == generation, privateCosProvider() === api, accountScopeID == account else { return }
                    LiveFlowLog.privateCosRead(.unclassified)
                }
            }
        } catch {
            guard scope == generation, privateCosProvider() === api, accountScopeID == account else { return }
            LiveFlowLog.privateCosRead(.unclassified)
        }
    }

    @discardableResult
    private func readChannels(id: NativeID, companyID: String, client: CompanyWorkspaceAPI,
                              scope: UInt64) async -> CompanyChannelDirectory? {
        channelsLoading.insert(companyID)
        defer { if scope == generation { channelsLoading.remove(companyID) } }
        do {
            let read = try await client.companyChannels(companyID: id)
            guard scope == generation, self.client() === client else { return nil }
            switch read {
            case .v1:
                hideForDowngrade()
                return nil
            case let .v1_1(value):
                channelsByCompany[companyID] = value
                roomDirectory.absorb(value, companyID: id)
                let rooms = Set(value.channels.compactMap { entry in
                    entry.room.state == "ready" ? entry.room.roomId : nil
                })
                knownPersonalRoomIDs.subtract(rooms)
                quarantinedCompanyRoomIDs.subtract(rooms)
                classificationBase &+= 1
                return value
            }
        } catch {
            guard scope == generation, self.client() === client else { return nil }
            if CompanyWireDegrade.shouldDegrade(error) { hideForDowngrade() }
            return nil
        }
    }

    @discardableResult
    private func readSnapshot(id: NativeID, companyID: String, client: CompanyWorkspaceAPI,
                              scope: UInt64) async -> CompanySnapshot? {
        membersLoading.insert(companyID)
        defer { if scope == generation { membersLoading.remove(companyID) } }
        do {
            let read = try await client.companySnapshot(companyID: id)
            guard scope == generation, self.client() === client else { return nil }
            switch read {
            case .v1:
                hideForDowngrade()
                return nil
            case let .v1_1(value):
                snapshotsByCompany[companyID] = value
                return value
            }
        } catch {
            guard scope == generation, self.client() === client else { return nil }
            if CompanyWireDegrade.shouldDegrade(error) { hideForDowngrade() }
            return nil
        }
    }

    private func hideForDowngrade() {
        generation &+= 1
        phase = .hidden
        privateCosBindings = CompanyPrivateCosBindings()
        privateCosBindings.beginAccount(accountScopeID)
        list = nil
        channelsByCompany.removeAll()
        snapshotsByCompany.removeAll()
        classificationComplete = false
        classificationBase &+= 1
        // A downgrade ends every conversation's authority: their open chats close.
        conversations.reset(notify: true)
        leavePending.removeAll()
        noticeCompanies.removeAll()
        channelsLoading.removeAll()
        membersLoading.removeAll()
        for task in leaveTasks.values { task.cancel() }
        leaveTasks.removeAll()
    }

    /// Starts one account scope. A reconnect to the same account keeps the
    /// directory and per-room cache; a different account gets a clean model
    /// and its own leave journal.
    func beginAccountScope(_ accountID: String) {
        guard accountScopeID != accountID else { return }
        resetAccountState()
        accountScopeID = accountID
        privateCosBindings.beginAccount(accountID)
        journal = CompanyLeaveJournal(
            key: "atum.company-leave.v1." + LiveFlowLog.fingerprint(accountID)
        )
        hasLoadedJournal = false
        prefsJournal = CompanyLocalPrefsJournal(key: CompanyLocalPrefsJournal.key(forAccount: accountID))
        prefs = prefsJournal.load()
        // A create whose answer was never seen, from before a relaunch.
        createTracker = CompanyCreateTracker(pending: prefs.pendingCreate)
        prefsRevision &+= 1
    }

    /// Sign-out, stranded-session archive and account replacement end the
    /// in-memory scope without deleting another account's pending journal.
    func clear() {
        resetAccountState()
        accountScopeID = nil
        journal = CompanyLeaveJournal()
        hasLoadedJournal = false
        prefsJournal = CompanyLocalPrefsJournal()
    }

    private func resetAccountState() {
        generation &+= 1
        accountEpoch &+= 1
        createTask?.cancel()
        createTask = nil
        phase = .idle
        list = nil
        channelsByCompany.removeAll()
        snapshotsByCompany.removeAll()
        roomDirectory.clear()
        privateCosBindings = CompanyPrivateCosBindings()
        conversations.reset()
        conversationTypeClaims.removeAll()
        classificationComplete = false
        knownPersonalRoomIDs.removeAll()
        quarantinedCompanyRoomIDs.removeAll()
        classificationBase &+= 1
        leavePending.removeAll()
        noticeCompanies.removeAll()
        channelsLoading.removeAll()
        membersLoading.removeAll()
        prefs = CompanyLocalPrefs()
        prefsRevision &+= 1
        actionError = nil
        actionErrorCompany = nil
        leaveTracker = CompanyLeaveTracker(pending: nil)
        createTracker = CompanyCreateTracker()
        isCreating = false
        for task in leaveTasks.values { task.cancel() }
        leaveTasks.removeAll()
    }

    // MARK: Room classification

    func reconcileMatrixRooms(_ roomIDs: Set<String>, conversationTypeClaims claims: Set<String> = []) {
        let before = knownPersonalRoomIDs
        let claimsBefore = conversationTypeClaims
        conversationTypeClaims = claims.intersection(roomIDs)
        quarantinedCompanyRoomIDs.formIntersection(roomIDs)
        knownPersonalRoomIDs.formIntersection(roomIDs)
        // A room that claims the conversation type is never Personal, listed or not.
        knownPersonalRoomIDs.subtract(conversationTypeClaims)
        defer {
            if knownPersonalRoomIDs != before || conversationTypeClaims != claimsBefore {
                classificationBase &+= 1
            }
        }
        guard classificationComplete else { return }
        var companyRooms = quarantinedCompanyRoomIDs.union(conversationTypeClaims)
            .union(privateCosBindings.roomIDs)
        for companyID in roomDirectory.companyIDs {
            companyRooms.formUnion(roomDirectory.roomIDs(companyID: companyID))
        }
        for companyID in conversations.roomDirectory.companyIDs {
            companyRooms.formUnion(conversations.roomDirectory.roomIDs(companyID: companyID))
        }
        knownPersonalRoomIDs.formUnion(roomIDs.subtracting(companyRooms))
    }

    func roomClassification(_ roomID: String) -> CompanyRoomClassification {
        if let company = privateCosBindings.companyID(owning: roomID) { return .privateCos(companyID: company) }
        if let claim = roomDirectory.claim(roomID: roomID) { return .company(claim) }
        // Only the platform's directory makes a room a conversation.
        if let claim = conversations.claim(roomID: roomID) { return .conversation(claim) }
        if conversationTypeClaims.contains(roomID) { return .quarantined }
        if knownPersonalRoomIDs.contains(roomID) { return .personal }
        return .unknown
    }

    private func invalidateClassification() {
        if classificationComplete {
            classificationComplete = false
            classificationBase &+= 1
        }
    }

    private func setClassificationComplete(_ value: Bool) {
        guard classificationComplete != value else { return }
        classificationComplete = value
        classificationBase &+= 1
    }

    // MARK: Home

    /// Workplace has something to show or do: a company, an invitation, or the
    /// platform's say-so that this person may create one. Without any of them
    /// the tab stays subdued.
    var isVisible: Bool {
        guard phase == .ready, let list else { return false }
        return !list.companies.isEmpty || !visibleInvitations(list).isEmpty || list.canCreate
    }

    /// Whether to offer "Create company". The platform decides who may create
    /// (`canCreate` is its advisory answer); a refused create still lands as
    /// `.closed`, so hiding the button is a courtesy, not the enforcement.
    var canCreate: Bool {
        phase == .ready && list?.canCreate == true
    }

    /// The invitations waiting at the top of Workplace.
    func invitationRows() -> [CompanyHomeRow] {
        guard phase == .ready, let list else { return [] }
        let copy = self.copy
        return visibleInvitations(list).map { invitation in
            let inviter = invitation.inviter.displayName ?? invitation.inviter.handle.map { "@" + $0 }
            return CompanyHomeRow(
                id: "invitation:" + invitation.id.rawValue,
                companyID: invitation.companyId.rawValue,
                invitationID: invitation.id.rawValue,
                title: invitation.displayName,
                subtitle: copy?.joinInvitation(inviter: inviter, company: invitation.displayName))
        }
    }

    private func visibleInvitations(_ list: CompanyList) -> [CompanyInvitation] {
        list.invitations.filter { !prefs.isLater($0.id.rawValue) }
    }

    /// Invitations still waiting for an answer: the Workplace tab's badge.
    var pendingInvitationCount: Int {
        guard phase == .ready, let list else { return 0 }
        return visibleInvitations(list).count
    }

    /// "Not now": the invitation leaves the list and the badge, and stays
    /// away across restarts (account-scoped). It is not a decline on the
    /// platform; the platform still lists it until it is answered or expires.
    func declineInvitation(_ invitationID: String) {
        prefs.later(invitationID)
        prefsJournal.save(prefs)
        prefsRevision &+= 1
    }

    /// Forgets "Not now" answers for invitations the platform no longer lists.
    private func prunePrefs(_ list: CompanyList) {
        var next = prefs
        next.prune(keeping: Set(list.invitations.map(\.id.rawValue)))
        guard next != prefs else { return }
        prefs = next
        prefsJournal.save(prefs)
        prefsRevision &+= 1
    }

    // MARK: Active company

    /// The company the Workplace root shows: the last one chosen while it is
    /// still in the list, else the most recently used one still in it, else
    /// the first by name whose default channel can be opened, else the first by
    /// name (see `CompanyLocalPrefs.resolvedCompanyID`). The platform list's own
    /// order is never the answer.
    var activeCompanyID: String? {
        guard phase == .ready, let list else { return nil }
        let candidates = list.companies.map { company in
            CompanyCandidate(id: company.id.rawValue, name: company.displayName,
                             hasReachableDefaultChannel: CompanyCandidate.reachable(
                                 channelsByCompany[company.id.rawValue]))
        }
        return prefs.resolvedCompanyID(candidates: candidates,
                                       locale: Locale(identifier: copy?.design.locale ?? "en"))
    }

    func selectCompany(_ companyID: String) {
        guard list?.companies.contains(where: { $0.id.rawValue == companyID }) == true,
              prefs.activeCompanyID != companyID || prefs.recentCompanyIDs.first != companyID else { return }
        prefs.use(company: companyID)
        prefsJournal.save(prefs)
        prefsRevision &+= 1
    }

    /// A route into a company room makes that room's company the Workplace
    /// root, so Back from the chat lands on the same company's list. A room
    /// that is not a company channel changes nothing.
    func activateCompany(owning roomID: String) {
        switch roomClassification(roomID) {
        case let .company(claim): selectCompany(claim.companyID)
        case let .conversation(claim): selectCompany(claim.companyID)
        case let .privateCos(companyID): selectCompany(companyID)
        case .quarantined, .personal, .unknown: break
        }
    }

    // MARK: Accept and converge

    /// Returns the room to open, or nil after showing the bounded-retry line.
    func accept(invitationID: String) async -> String? {
        guard phase == .ready, let client = client(), let list,
              let invitation = list.invitations.first(where: { $0.id.rawValue == invitationID })
        else { return nil }
        let requestID = UUID().uuidString.lowercased()
        guard let request = try? NativeID(requestID) else { return nil }
        do {
            let snapshot = try await client.acceptCompanyInvitation(
                companyID: invitation.companyId, requestID: request,
                invitationID: invitation.id)
            guard self.client() === client else { return nil }
            snapshotsByCompany[invitation.companyId.rawValue] = snapshot
            await refresh()
            selectCompany(invitation.companyId.rawValue)
            return await converge(companyID: invitation.companyId.rawValue,
                                  preferredChannelID: snapshot.defaultChannelId?.rawValue)
        } catch {
            if CompanyWireDegrade.shouldDegrade(error) { hideForDowngrade() }
            actionFailure()
            return nil
        }
    }

    /// Accept → directory ready → invitation synced → join → open, bounded.
    func converge(companyID: String, preferredChannelID: String?) async -> String? {
        guard let client = client(), let id = try? NativeID(companyID) else { return nil }
        noticeCompanies.remove(companyID)
        for attempt in 0..<CompanyConvergence.attempts {
            if Task.isCancelled { return nil }
            var directory = channelsByCompany[companyID]
            if let refreshed = await readChannels(id: id, companyID: companyID,
                                                  client: client, scope: generation) {
                directory = refreshed
            }
            guard self.client() === client else { return nil }
            let roomID = directory.flatMap {
                CompanyConvergence.targetRoomID(in: $0, preferredChannelID: preferredChannelID)
            }
            let step = CompanyConvergence.step(
                attempt: attempt, directory: directory, preferredChannelID: preferredChannelID,
                presence: roomID.map(presence) ?? .unknown)
            switch step {
            case let .open(room):
                return room
            case let .join(room):
                if await join(room) { continue }
            case .wait:
                break
            case .giveUp:
                noticeCompanies.insert(companyID)
                return nil
            }
            if attempt + 1 < CompanyConvergence.attempts {
                do { try await Task.sleep(for: .milliseconds(CompanyConvergence.delayMilliseconds)) }
                catch { return nil }
            }
        }
        noticeCompanies.insert(companyID)
        return nil
    }

    // MARK: Create

    /// Creates a company the way the desktop does (`POST /companies` under
    /// wire 1.1), then shows it: it becomes the active company and the phone
    /// waits, bounded, for its default channel the same way an accepted
    /// invitation does. A retry of the same name after a lost answer replays
    /// the same request, also after the app was relaunched (the attempt is
    /// kept in the account's prefs until the platform answers or refuses it,
    /// or the person edits the name).
    func createCompany(named typed: String) async -> CompanyCreateResult {
        guard phase == .ready, let client = client(), !isCreating else { return .failed(.unavailable) }
        guard let name = CompanyName.normalized(typed) else { return .failed(.invalidName) }
        // The platform's advisory answer is read again at submit: the right can
        // be lost after the form was opened (a list refresh took it away).
        guard list?.canCreate == true else { return .failed(.closed) }
        isCreating = true
        let epoch = accountEpoch
        // Only the scope that started the create may end it: a later account
        // may already be creating.
        defer {
            if epoch == accountEpoch {
                isCreating = false
                createTask = nil
            }
        }
        let task = Task { @MainActor in
            await self.runCreate(name: name, client: client, epoch: epoch)
        }
        createTask = task
        return await task.value
    }

    private func runCreate(name: String, client: CompanyWorkspaceAPI,
                           epoch: UInt64) async -> CompanyCreateResult {
        let attempt = createTracker.attempt(for: name) { UUID().uuidString.lowercased() }
        persistPendingCreate()
        guard let requestID = try? NativeID(attempt.requestID) else { return .failed(.unavailable) }
        do {
            let snapshot = try await client.createCompany(requestID: requestID, displayName: name)
            guard epoch == accountEpoch, self.client() === client else { return .failed(.unavailable) }
            createTracker.succeeded()
            persistPendingCreate()
            let companyID = snapshot.company.id.rawValue
            snapshotsByCompany[companyID] = snapshot
            await refresh()
            guard epoch == accountEpoch else { return .failed(.unavailable) }
            selectCompany(companyID)
            let room = await converge(companyID: companyID,
                                      preferredChannelID: snapshot.defaultChannelId?.rawValue)
            guard epoch == accountEpoch else { return .failed(.unavailable) }
            return .created(roomID: room)
        } catch is CompanyWireRefusal {
            guard epoch == accountEpoch else { return .failed(.unavailable) }
            // A v1 answer: this server has no 1.1 Workplace. Hide it rather
            // than blame the name. The attempt stays, because a v1 server
            // still creates the company and only the answer is unreadable.
            hideForDowngrade()
            return .failed(.unavailable)
        } catch {
            guard epoch == accountEpoch else { return .failed(.unavailable) }
            let failure = (error as? CompanyAPIError).map(CompanyCreateFailure.init) ?? .unavailable
            createTracker.failed(failure)
            persistPendingCreate()
            actionFailure()
            return .failed(failure)
        }
    }

    /// The person edited the name after a failed try: that attempt is no longer
    /// the one they mean to retry, so the next create is a new request.
    func abandonPendingCreate() {
        guard !isCreating, createTracker.pending != nil else { return }
        createTracker.abandoned()
        persistPendingCreate()
    }

    /// The name of the create that is waiting for an answer, if any.
    var pendingCreateName: String? { createTracker.pending?.displayName }

    private func persistPendingCreate() {
        guard prefs.pendingCreate != createTracker.pending else { return }
        prefs.pendingCreate = createTracker.pending
        prefsJournal.save(prefs)
    }

    // MARK: Leave

    func leave(companyID: String) async {
        guard let client = client(), (try? NativeID(companyID)) != nil else { return }
        loadJournalIfNeeded()
        if leaveTracker.pending?.companyID != companyID {
            let requestID = UUID().uuidString.lowercased()
            guard (try? NativeID(requestID)) != nil else { return }
            leaveTracker.begin(companyID: companyID, requestID: requestID)
            journal.save(leaveTracker)
        }
        leavePending.insert(companyID)
        actionError = nil
        actionErrorCompany = companyID
        await replayLeave(companyID: companyID, client: client)
    }

    private func replayLeave(companyID: String, client: CompanyWorkspaceAPI) async {
        guard let pending = leaveTracker.pending, pending.companyID == companyID,
              let company = try? NativeID(companyID),
              let request = try? NativeID(pending.requestID) else { return }
        for attempt in 0..<CompanyConvergence.attempts {
            if Task.isCancelled { return }
            do {
                let acknowledgement = try await client.leaveCompany(companyID: company,
                                                                    requestID: request)
                guard self.client() === client else { return }
                if leaveTracker.apply(acknowledgement) {
                    finishLeave(companyID: companyID)
                    return
                }
                // Authority ended at `revoking`; the same request is replayed
                // until the ban is witnessed.
                await refresh()
            } catch let error as CompanyAPIError {
                guard self.client() === client else { return }
                leaveTracker.apply(error)
                if !leaveTracker.isPending {
                    leavePending.remove(companyID)
                    journal.save(leaveTracker)
                    actionError = error.isLastAdmin ? "lastAdmin" : "unavailable"
                    actionErrorCompany = companyID
                    if error.isLastAdmin { actionFailure() }
                    await refresh()
                    return
                }
                actionError = "unavailable"
                actionErrorCompany = companyID
            } catch {
                guard self.client() === client else { return }
                if CompanyWireDegrade.shouldDegrade(error) {
                    hideForDowngrade()
                    return
                }
                actionError = "unavailable"
                actionErrorCompany = companyID
            }
            if attempt + 1 < CompanyConvergence.attempts {
                do { try await Task.sleep(for: .milliseconds(CompanyConvergence.delayMilliseconds)) }
                catch { return }
            }
        }
        // A still-`revoking` company keeps its request; the next foreground
        // or list refresh replays it.
        journal.save(leaveTracker)
    }

    private func finishLeave(companyID: String) {
        let rooms = roomDirectory.roomIDs(companyID: companyID)
            .union(conversations.roomDirectory.roomIDs(companyID: companyID))
            .union(privateCosBindings.views[companyID]?.binding.map { [$0.roomId] } ?? [])
        privateCosBindings.retain(companies: Set(privateCosBindings.views.keys).subtracting([companyID]))
        classificationBase &+= 1
        leavePending.remove(companyID)
        journal.save(leaveTracker)
        noticeCompanies.remove(companyID)
        roomDirectory.remove(companyID: companyID)
        conversations.remove(companyID: companyID)
        channelsByCompany.removeValue(forKey: companyID)
        snapshotsByCompany.removeValue(forKey: companyID)
        if !rooms.isEmpty { onLeft(rooms) }
        Task { await refresh() }
    }

    private func resumePendingLeaveIfNeeded(client: CompanyWorkspaceAPI, scope: UInt64) async {
        loadJournalIfNeeded()
        guard let pending = leaveTracker.pending else { return }
        guard let list, list.companies.contains(where: { $0.id.rawValue == pending.companyID }) else {
            // No longer a member: the acknowledgement was lost, the list is
            // the authority.
            leaveTracker = CompanyLeaveTracker()
            journal.save(leaveTracker)
            leavePending.remove(pending.companyID)
            return
        }
        leavePending.insert(pending.companyID)
        guard leaveTasks[pending.companyID] == nil else { return }
        leaveTasks[pending.companyID] = Task { @MainActor [weak self] in
            defer { self?.leaveTasks[pending.companyID] = nil }
            await self?.replayLeave(companyID: pending.companyID, client: client)
        }
        _ = scope
    }

    private func loadJournalIfNeeded() {
        guard !hasLoadedJournal else { return }
        hasLoadedJournal = true
        leaveTracker = journal.load()
        if let pending = leaveTracker.pending { leavePending.insert(pending.companyID) }
    }

    private func actionFailure() { actionFailureToken &+= 1 }

    // MARK: Chat

    func claim(roomID: String) -> CompanyRoomClaim? { roomDirectory.claim(roomID: roomID) }
    func isCompanyChannel(_ roomID: String) -> Bool { roomDirectory.isCompanyChannel(roomID) }
    func conversationClaim(roomID: String) -> ConversationRoomClaim? { conversations.claim(roomID: roomID) }

    /// A room that claims the company conversation type and has no directory record matching its
    /// company, conversation and room. Its transcript, composer, header, badges and notifications
    /// are all closed; it is only kept out of Personal.
    func isQuarantinedConversation(_ roomID: String) -> Bool {
        !privateCosBindings.roomIDs.contains(roomID)
            && conversationTypeClaims.contains(roomID) && conversations.claim(roomID: roomID) == nil
            && !roomDirectory.isCompanyChannel(roomID)
    }

    // MARK: Conversation actions, fenced to the selected company

    /// New message. The company the person is in is captured before the call and checked again
    /// after it: if they have moved to another company while the room was being made, the new
    /// conversation is listed ("Setting up…" or ready) but nothing is opened.
    func startConversation(companyID: String, others: [String]) async -> ConversationStartOutcome {
        let selected = activeCompanyID
        let outcome = await conversations.start(
            companyID: companyID, others: others,
            isCurrent: { [weak self] in self?.isStillSelected(companyID, captured: selected) ?? false })
        return fenced(outcome, companyID: companyID, selected: selected)
    }

    func addConversationPeople(companyID: String, sourceConversationID: String,
                               others: [String]) async -> ConversationStartOutcome {
        let selected = activeCompanyID
        let outcome = await conversations.addPeople(
            companyID: companyID, sourceConversationID: sourceConversationID, others: others,
            isCurrent: { [weak self] in self?.isStillSelected(companyID, captured: selected) ?? false })
        return fenced(outcome, companyID: companyID, selected: selected)
    }

    /// The company the person was in when they acted is still the one shown, after every await.
    private func isStillSelected(_ companyID: String, captured: String?) -> Bool {
        captured == companyID && activeCompanyID == companyID
    }

    private func fenced(_ outcome: ConversationStartOutcome, companyID: String,
                        selected: String?) -> ConversationStartOutcome {
        guard case let .opened(roomID) = outcome else { return outcome }
        guard selected == companyID, activeCompanyID == companyID,
              conversations.claim(roomID: roomID)?.companyID == companyID,
              conversations.canMutate(companyID: companyID) else { return .settingUp }
        return outcome
    }

    /// Whether `companyID` is still the company Workplace shows and the room is still that
    /// company's conversation (or channel). Navigation checks this after every await.
    func isSelected(companyID: String, owning roomID: String) -> Bool {
        guard activeCompanyID == companyID else { return false }
        switch roomClassification(roomID) {
        case let .conversation(claim): return claim.companyID == companyID
        case let .privateCos(owner): return owner == companyID
        case let .company(claim): return claim.companyID == companyID
        case .quarantined, .personal, .unknown: return false
        }
    }
    func isConversationRoom(_ roomID: String) -> Bool { conversations.claim(roomID: roomID) != nil }

    /// Each listed company's rooms on this phone (its channels and your
    /// conversations in it), by company ID: what the panel's "Team Spaces in
    /// common" reads (desktop `matrixSharedCompanies`).
    func companyRooms() -> [(companyID: String, name: String, roomIDs: [String])] {
        (list?.companies ?? []).compactMap { company in
            let id = company.id.rawValue
            let rooms = roomDirectory.roomIDs(companyID: id).union(conversations.roomDirectory.roomIDs(companyID: id))
            guard !rooms.isEmpty else { return nil }
            return (id, company.displayName, rooms.sorted())
        }
    }

    func companyName(_ companyID: String) -> String? {
        list?.companies.first(where: { $0.id.rawValue == companyID })?.displayName
    }

    /// The company's Workplace root. `signals` carries the Matrix unread state
    /// of its channel rooms; a channel the SDK does not know yet has no mark.
    func workspace(companyID: String, signals: CompanyRoomSignals = [:],
                   activity: [String: Date] = [:]) -> CompanyWorkspacePresentation? {
        guard let copy, let companyIDValue = try? NativeID(companyID),
              let company = list?.companies.first(where: { $0.id == companyIDValue })
        else { return nil }
        let directory = channelsByCompany[companyID]
        var channels = (directory?.channels ?? [])
            .sorted { left, right in
                if left.channel.isDefault != right.channel.isDefault { return left.channel.isDefault }
                return left.channel.displayName.compare(right.channel.displayName,
                                                         options: [.caseInsensitive, .diacriticInsensitive],
                                                         locale: Locale(identifier: copy.design.locale))
                    == .orderedAscending
            }
            .map { entry in
                let input = entry.room.roomId.flatMap { signals[$0] }
                return CompanyChannelRow(
                    id: entry.channel.id.rawValue,
                    title: copy.channelName(entry.channel.displayName, isDefault: entry.channel.isDefault),
                    state: copy.channelState(entry.channel.state.rawValue),
                    roomID: entry.room.roomId,
                    memberCount: Int(entry.memberCount),
                    canOpen: entry.room.state == "ready" && entry.room.roomId != nil,
                    badge: input.map(Badge.mark(for:)) ?? .none,
                    isMuted: input?.isMuted ?? false)
            }
        if let binding = privateCosBindings.views[companyID]?.binding {
            let input = signals[binding.roomId]
            channels.append(CompanyChannelRow(
                id: "private-cos:" + binding.scope.pair.membershipIncarnation.rawValue,
                title: privateCosRoomTitle(binding.roomId) ?? binding.roomId,
                state: "", roomID: binding.roomId, memberCount: 2, canOpen: true,
                badge: input.map(Badge.mark(for:)) ?? .none, isMuted: input?.isMuted ?? false))
        }
        let members = members(companyID: companyID, copy: copy)
        return CompanyWorkspacePresentation(
            id: companyID,
            title: company.displayName,
            channels: channels,
            members: members,
            channelsLoading: channelsLoading.contains(companyID) && directory == nil,
            membersLoading: membersLoading.contains(companyID) && snapshotsByCompany[companyID] == nil,
            leavePending: leavePending.contains(companyID),
            notice: noticeCompanies.contains(companyID) ? copy.convergeFailed : nil,
            error: actionErrorCompany == companyID
                ? actionError.map { companyErrorText($0, copy: copy) }
                : nil,
            conversations: conversationSection(companyID: companyID, signals: signals, activity: activity,
                                               copy: copy))
    }

    private func conversationSection(companyID: String, signals: CompanyRoomSignals,
                                     activity: [String: Date], copy: CompanyCopy) -> ConversationSectionPresentation? {
        guard let section = conversations.section(companyID: companyID, signals: signals, activity: activity,
                                                  locale: Locale(identifier: copy.design.locale)) else { return nil }
        let notice = conversations.refusal(companyID: companyID)
            .map { ConversationCopy(design: copy.design).refusal($0) }
        return ConversationSectionPresentation(rows: section.rows, hidden: section.hidden,
                                               isLoading: section.isLoading, failed: section.failed,
                                               isStale: section.isStale, notice: notice)
    }

    /// The people the New message / Add people picker offers for a company.
    func conversationPeople(companyID: String, excluding kept: Set<String> = []) -> [ConversationPerson] {
        guard let snapshot = snapshotsByCompany[companyID] else { return [] }
        return conversations.candidates(members: snapshot.members, companyID: companyID, excluding: kept)
    }

    // MARK: Unread and mentions

    /// The Matrix unread state of the rooms that are company channels, from
    /// the live room list.
    /// Each company's logo: the `m.room.avatar` of one of its joined channels.
    /// The platform writes the same logo to every channel, and the desktop
    /// reads it the same way (atum-app `team-space/company-avatar.ts`). A
    /// member's photo (the room's hero) is never a company's logo.
    func logoURIs(from rooms: [LiveProductRoom]) -> [String: String] {
        var logos = [String: String]()
        for companyID in roomDirectory.companyIDs {
            let channels = roomDirectory.roomIDs(companyID: companyID)
            let uri = rooms
                .filter { channels.contains($0.id) && !$0.isInvitation }
                .sorted { $0.id < $1.id }
                .compactMap(\.roomAvatarURL)
                .first { $0.hasPrefix("mxc://") }
            if let uri { logos[companyID] = uri }
        }
        return logos
    }

    func roomSignals(from rooms: [LiveProductRoom]) -> CompanyRoomSignals {
        var signals = CompanyRoomSignals()
        for room in rooms where isTeamSpaceRoom(room.id) && !room.isInvitation {
            signals[room.id] = Badge.Input(highlights: room.highlightCount,
                                           notifications: room.notificationCount,
                                           hasUnreadActivity: room.unreadCount > 0,
                                           isMarkedUnread: room.isMarkedUnread,
                                           isMuted: room.isMuted)
        }
        return signals
    }

    private func channelInputs(companyID: String, signals: CompanyRoomSignals) -> [Badge.Input] {
        // A conversation counts toward its company's mark by the same rule as a channel
        // (hidden ones too: the room list does not know the hidden flag).
        roomDirectory.roomIDs(companyID: companyID)
            .union(conversations.roomDirectory.roomIDs(companyID: companyID))
            .union(privateCosBindings.views[companyID]?.binding.map { [$0.roomId] } ?? [])
            .compactMap { signals[$0] }
    }

    /// A company channel or a conversation the directory lists.
    private func isTeamSpaceRoom(_ roomID: String) -> Bool {
        privateCosBindings.roomIDs.contains(roomID)
            || roomDirectory.isCompanyChannel(roomID) || conversations.claim(roomID: roomID) != nil
    }

    func companyBadge(companyID: String, signals: CompanyRoomSignals) -> Badge {
        TeamSpaceBadges.company(channels: channelInputs(companyID: companyID, signals: signals))
    }

    /// The switcher sheet's companies: every one, with its own mark (none on
    /// the active one, which is flagged instead). A single company is listed
    /// too: the sheet is also where a person creates another.
    func switcherEntries(signals: CompanyRoomSignals) -> [CompanySwitcherEntry] {
        guard let list, !list.companies.isEmpty else { return [] }
        let active = activeCompanyID
        return list.companies.map { company in
            CompanySwitcherEntry(id: company.id.rawValue, title: company.displayName,
                                 badge: TeamSpaceBadges.switcherMark(
                                     companyBadge(companyID: company.id.rawValue, signals: signals),
                                     isActive: company.id.rawValue == active),
                                 isActive: company.id.rawValue == active)
        }
    }

    /// The Workplace tab's mark: company mentions, then invitations waiting,
    /// then plain unread.
    func tabBadge(signals: CompanyRoomSignals) -> Badge {
        guard phase == .ready, let list else { return .none }
        return TeamSpaceBadges.tab(
            companies: list.companies.map { companyBadge(companyID: $0.id.rawValue, signals: signals) },
            pendingInvitations: pendingInvitationCount)
    }

    /// Company channels' share of the app-icon count, by Home's rule.
    func appIconRows(signals: CompanyRoomSignals) -> [Badge.AppIconRow] {
        signals.values.map { Badge.AppIconRow(input: $0) }
    }

    /// People a mention can name in this channel: the company roster's
    /// handles and names, matched to the room's members by handle.
    func mentionRoster(roomID: String) -> [MentionRosterEntry] {
        guard let companyID = roomDirectory.companyID(roomID: roomID),
              let snapshot = snapshotsByCompany[companyID] else { return [] }
        return snapshot.members.compactMap { member in
            member.handle.map { MentionRosterEntry(handle: $0, name: member.displayName) }
        }
    }

    func members(companyID: String) -> [CompanyMemberRow] {
        guard let copy else { return [] }
        return members(companyID: companyID, copy: copy)
    }

    private func members(companyID: String, copy: CompanyCopy) -> [CompanyMemberRow] {
        guard let snapshot = snapshotsByCompany[companyID] else { return [] }
        return snapshot.members
            .map { member in
                let name = member.displayName
                    ?? member.handle.map { "@" + $0 }
                    ?? copy.text(CompanyCopyKey("someone"))
                return CompanyMemberRow(
                    id: member.memberRef,
                    name: name,
                    handle: member.handle,
                    role: copy.role(member.role),
                    state: copy.memberState(member.state),
                    isSelf: member.isSelf)
            }
            .sorted { left, right in
                if left.isSelf != right.isSelf { return left.isSelf }
                let order = left.name.compare(right.name,
                                              options: [.caseInsensitive, .diacriticInsensitive],
                                              range: nil, locale: Locale(identifier: copy.design.locale))
                if order != .orderedSame { return order == .orderedAscending }
                return left.id < right.id
            }
    }

    func isLeavePending(companyID: String) -> Bool { leavePending.contains(companyID) }

    private func companyErrorText(_ key: String, copy: CompanyCopy) -> String {
        switch key {
        case "lastAdmin": copy.lastAdmin
        case "denied": copy.text(CompanyCopyKey("denied"))
        case "conflict": copy.text(CompanyCopyKey("conflict"))
        case "limit": copy.text(CompanyCopyKey("limit"))
        case "invalid": copy.text(CompanyCopyKey("invalid"))
        case "missing": copy.text(CompanyCopyKey("missing"))
        case "authentication": copy.text(CompanyCopyKey("authentication"))
        default: copy.text(CompanyCopyKey("unavailable"))
        }
    }
}
