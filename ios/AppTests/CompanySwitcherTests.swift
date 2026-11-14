@testable import AtumMobile
import AtumChat
import AtumNativeAPI
import XCTest

/// Workplace opens to the last-used company, the switcher lists every company
/// with its marks and a check on the current one, an account with nothing but
/// the right to create gets an empty state that offers it, and "Create
/// company" runs against a stubbed client: a retry after a lost answer replays
/// the same request, a refusal leaves nothing behind.
final class CompanySwitcherTests: XCTestCase {
    private enum StubFailure: Error { case unavailable }

    @MainActor
    private final class API: CompanyWorkspaceAPI, @unchecked Sendable {
        var list: CompanyList
        var directories: [String: CompanyChannelDirectory]
        var snapshots: [String: CompanySnapshot]
        /// What each `createCompany` call sees, in order.
        var creates: [(requestID: String, name: String)] = []
        /// What each call answers, in order. A success also joins the list.
        var results: [Result<CompanySnapshot, Error>] = []
        var makeEntries: (CompanySnapshot) throws -> (list: CompanyList, directory: CompanyChannelDirectory)
        /// While set, the next create suspends here until `release()`.
        var holdsNextCreate = false
        /// Whether the create that was held saw its task cancelled when released.
        var heldCreateWasCancelled = false
        private var held: CheckedContinuation<Void, Never>?

        init(list: CompanyList, directories: [String: CompanyChannelDirectory],
             snapshots: [String: CompanySnapshot],
             makeEntries: @escaping (CompanySnapshot) throws -> (list: CompanyList,
                                                                 directory: CompanyChannelDirectory)) {
            self.list = list
            self.directories = directories
            self.snapshots = snapshots
            self.makeEntries = makeEntries
        }

        var isHolding: Bool { held != nil }
        func release() { held?.resume(); held = nil }

        func companyList() async throws -> CompanyRead<CompanyList> { .v1_1(list) }
        func companySnapshot(companyID: NativeID) async throws -> CompanyRead<CompanySnapshot> {
            guard let value = snapshots[companyID.rawValue] else { throw StubFailure.unavailable }
            return .v1_1(value)
        }
        func companyChannels(companyID: NativeID) async throws -> CompanyRead<CompanyChannelDirectory> {
            guard let value = directories[companyID.rawValue] else { throw StubFailure.unavailable }
            return .v1_1(value)
        }
        func acceptCompanyInvitation(companyID: NativeID, requestID: NativeID,
                                     invitationID: NativeID) async throws -> CompanySnapshot {
            throw StubFailure.unavailable
        }
        func leaveCompany(companyID: NativeID,
                          requestID: NativeID) async throws -> CompanyLeaveAcknowledgement {
            throw StubFailure.unavailable
        }
        func createCompany(requestID: NativeID, displayName: String) async throws -> CompanySnapshot {
            creates.append((requestID.rawValue, displayName))
            if holdsNextCreate {
                holdsNextCreate = false
                await withCheckedContinuation { held = $0 }
                heldCreateWasCancelled = Task.isCancelled
            }
            guard !results.isEmpty else { throw StubFailure.unavailable }
            let snapshot = try results.removeFirst().get()
            let entries = try makeEntries(snapshot)
            list = entries.list
            directories[snapshot.company.id.rawValue] = entries.directory
            snapshots[snapshot.company.id.rawValue] = snapshot
            return snapshot
        }
    }

    private let companyA = "00000000-0000-4000-8000-91320823a72f"
    private let companyB = "00000000-0000-4000-8000-13746fa86639"
    private let created = "00000000-0000-4000-8000-13fa19405d8a"
    private let channelA = "00000000-0000-4000-8000-20f46db16790"
    private let channelB = "00000000-0000-4000-8000-4751d0e93f8a"
    private let channelNew = "00000000-0000-4000-8000-4e9fa4972ba4"
    private let roomA = "!general-a:atum.test"
    private let roomB = "!general-b:atum.test"
    private let roomNew = "!general-new:atum.test"

    // MARK: Fixtures

    private func list(_ companies: [(id: String, name: String)], canCreate: Bool) throws -> CompanyList {
        try NativeAPI.decode(CompanyList.self, from: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "companies": companies.map { company in [
                "id": company.id, "displayName": company.name,
                "role": "admin", "authorityGeneration": 1,
            ] },
            "invitations": [],
            "canCreate": canCreate,
        ]))
    }

    private func directory(companyID: String, channelID: String, roomID: String,
                           ready: Bool = true) throws -> CompanyChannelDirectory {
        try NativeAPI.decode(CompanyChannelDirectory.self, from: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "channels": [[
                "schemaVersion": 2,
                "channel": [
                    "id": channelID, "companyId": companyID, "displayName": "general",
                    "visibility": "company", "state": "active", "projectId": NSNull(),
                    "authorityGeneration": 1, "channelGeneration": 1, "systemKey": "default",
                ],
                "memberCount": 1,
                "room": ready ? ["state": "ready", "roomId": roomID] : ["state": "provisioning", "roomId": NSNull()],
            ]],
        ]))
    }

    private func snapshot(companyID: String, name: String, channelID: String) throws -> CompanySnapshot {
        try NativeAPI.decode(CompanySnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "company": ["id": companyID, "displayName": name, "role": "admin", "authorityGeneration": 1],
            "members": [[
                "memberRef": String(repeating: "a", count: 43), "role": "admin", "state": "active",
                "self": true, "handle": "owner", "displayName": "Owner",
            ]],
            "projects": [], "defaultChannelId": channelID,
        ]))
    }

    /// Two companies; a person who may create. `canCreate` and the starting
    /// companies are the knobs the tests need.
    @MainActor
    private func api(companies: [String], canCreate: Bool = true) throws -> API {
        let all = [(companyA, "Anka"), (companyB, "Studio")]
        let chosen = all.filter { companies.contains($0.0) }.map { (id: $0.0, name: $0.1) }
        let directories = [
            companyA: try directory(companyID: companyA, channelID: channelA, roomID: roomA),
            companyB: try directory(companyID: companyB, channelID: channelB, roomID: roomB),
        ]
        let snapshots = [
            companyA: try snapshot(companyID: companyA, name: "Anka", channelID: channelA),
            companyB: try snapshot(companyID: companyB, name: "Studio", channelID: channelB),
        ]
        return API(list: try list(chosen, canCreate: canCreate), directories: directories,
                   snapshots: snapshots, makeEntries: { [self] created in
            let existing = try list(chosen, canCreate: canCreate).companies
                .map { (id: $0.id.rawValue, name: $0.displayName) }
            return (try list(existing + [(created.company.id.rawValue, created.company.displayName)],
                             canCreate: canCreate),
                    try directory(companyID: created.company.id.rawValue,
                                  channelID: created.defaultChannelId?.rawValue ?? channelNew,
                                  roomID: roomNew))
        })
    }

    @MainActor
    private func model(_ api: API, account: String) throws -> CompanyWorkspaceModel {
        let model = CompanyWorkspaceModel()
        model.copy = CompanyCopy(design: try LiveDesign())
        model.clientProvider = { api }
        // The new channel's room is already joined, so convergence opens it at once.
        model.presence = { _ in .joined }
        model.beginAccountScope(account)
        return model
    }

    private func clearPrefs(_ account: String) {
        UserDefaults.standard.removeObject(forKey: CompanyLocalPrefsJournal.key(forAccount: account))
    }

    private func newCompanySnapshot(name: String = "Công ty Atum") throws -> CompanySnapshot {
        try snapshot(companyID: created, name: name, channelID: channelNew)
    }

    private func room(_ id: String, unread: Int = 0, notifications: Int = 0, highlights: Int = 0) -> LiveProductRoom {
        LiveProductRoom(id: id, kind: .group, title: id, unreadCount: unread,
                        notificationCount: notifications, highlightCount: highlights)
    }

    // MARK: Home search result from another company (review round 2, item 1)

    /// With company A shown in Workplace, a Home search result from company B
    /// opens: B is activated first, then the selection fence (the same
    /// `isSelected` check `AppRoot.openRoomAndRoute(_:requiringCompany:)` makes
    /// first and after every await) holds, and the real Router opens B's room
    /// in Workplace. Before the fix the fence ran with A active and refused.
    @MainActor
    func testHomeSearchResultFromAnotherCompanyActivatesItThenOpens() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let workspace = try model(try api(companies: [companyA, companyB]), account: account)
        await workspace.refresh()
        XCTAssertEqual(workspace.activeCompanyID, companyA)
        let router = Router()
        // What AppRoot's route does at its first fence and its final open.
        let route: (String, String) async -> Bool = { roomID, company in
            guard workspace.isSelected(companyID: company, owning: roomID) else { return false }
            router.openTeamSpace(roomId: roomID)
            return workspace.isSelected(companyID: company, owning: roomID)
        }
        func result(company: String, room: String, channel: String) -> CompanySearchResult {
            CompanySearchResult(companyID: company, channelID: channel, roomID: room, channelName: "general",
                                eventID: "$hit", sender: "@lan:atum.test", snippet: "launch", at: 0)
        }

        // A result whose company does not own the room changes nothing.
        let mislabeled = result(company: companyA, room: roomB, channel: channelB)
        var opened = await HomeSearchRoute.open(mislabeled, workspace: workspace, confirm: { true }, route: route)
        XCTAssertFalse(opened)
        XCTAssertEqual(workspace.activeCompanyID, companyA)
        XCTAssertNil(router.teamSpaceRoomID)

        // An unconfirmed result changes nothing either.
        let fromB = result(company: companyB, room: roomB, channel: channelB)
        opened = await HomeSearchRoute.open(fromB, workspace: workspace, confirm: { false }, route: route)
        XCTAssertFalse(opened)
        XCTAssertEqual(workspace.activeCompanyID, companyA)

        // The confirmed result from B: B active, B's room open in Workplace.
        opened = await HomeSearchRoute.open(fromB, workspace: workspace, confirm: { true }, route: route)
        XCTAssertTrue(opened, "a valid result from another company did not open")
        XCTAssertEqual(workspace.activeCompanyID, companyB)
        XCTAssertEqual(router.selectedTab, .teamSpace)
        XCTAssertEqual(router.teamSpaceRoomID, roomB)
    }

    // MARK: Last-used company

    @MainActor
    func testWorkplaceOpensToTheLastUsedCompanyNotTheFirst() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let first = try model(try api(companies: [companyA, companyB]), account: account)
        await first.refresh()
        XCTAssertEqual(first.activeCompanyID, companyA, "nothing chosen yet: the first")
        first.selectCompany(companyB)

        // A fresh launch of the same account lands on Studio's channel list.
        let relaunch = try model(try api(companies: [companyA, companyB]), account: account)
        await relaunch.refresh()
        XCTAssertEqual(relaunch.activeCompanyID, companyB)
        XCTAssertEqual(relaunch.workspace(companyID: relaunch.activeCompanyID ?? "")?.title, "Studio")
        XCTAssertEqual(relaunch.switcherEntries(signals: [:]).first { $0.isActive }?.title, "Studio")

        // Another account on the same phone keeps its own choice.
        let other = "switcher-" + UUID().uuidString
        defer { clearPrefs(other) }
        let stranger = try model(try api(companies: [companyA, companyB]), account: other)
        await stranger.refresh()
        XCTAssertEqual(stranger.activeCompanyID, companyA)
    }

    // MARK: Switcher list

    @MainActor
    func testTheSwitcherListsEveryCompanyEvenOneAndChecksTheCurrentOne() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let single = try model(try api(companies: [companyA]), account: account)
        await single.refresh()
        let alone = single.switcherEntries(signals: [:])
        XCTAssertEqual(alone.map(\.title), ["Anka"], "one company is still listed: the sheet is where a person creates another")
        XCTAssertEqual(alone.map(\.isActive), [true])

        let both = try model(try api(companies: [companyA, companyB]), account: account)
        await both.refresh()
        let signals = both.roomSignals(from: [
            room(roomA, unread: 4, notifications: 4, highlights: 2),
            room(roomB, unread: 1, notifications: 1),
        ])
        let entries = both.switcherEntries(signals: signals)
        XCTAssertEqual(entries.map(\.title), ["Anka", "Studio"])
        XCTAssertEqual(entries.map(\.badge), [.none, .dot], "the active company carries no mark; the other its dot")
        XCTAssertEqual(entries.map(\.isActive), [true, false])

        both.selectCompany(companyB)
        XCTAssertEqual(both.switcherEntries(signals: signals).map(\.isActive), [false, true],
                       "the check follows the choice")
        XCTAssertEqual(both.switcherEntries(signals: signals).map(\.badge), [.mention(4), .none],
                       "a mention pill on the company you left, nothing on the one you are in")
    }

    @MainActor
    func testAGoneCompanyFallsBackToTheMostRecentlyUsedThenTheFirst() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let both = try model(try api(companies: [companyA, companyB]), account: account)
        await both.refresh()
        both.selectCompany(companyB)
        both.selectCompany(companyA)
        both.selectCompany(companyB)

        // B is gone: A was used before it.
        let onlyA = try model(try api(companies: [companyA]), account: account)
        await onlyA.refresh()
        XCTAssertEqual(onlyA.activeCompanyID, companyA)

        // The list order changed and B is back: the remembered id, not position 0.
        let reordered = try model(try api(companies: [companyA, companyB]), account: account)
        await reordered.refresh()
        XCTAssertEqual(reordered.activeCompanyID, companyB)
    }

    @MainActor
    func testWithNothingRememberedWorkplaceOpensToTheFirstByNameThatIsReachableNotListPositionZero() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        // The platform lists Studio first; by name Anka comes first.
        let live = try api(companies: [companyA, companyB])
        live.list = try list([(companyB, "Studio"), (companyA, "Anka")], canCreate: true)
        let byName = try model(live, account: account)
        await byName.refresh()
        XCTAssertEqual(byName.activeCompanyID, companyA, "Anka, not the list's first element")

        // Anka's default channel is still being provisioned: skip it.
        let other = "switcher-" + UUID().uuidString
        defer { clearPrefs(other) }
        live.directories[companyA] = try directory(companyID: companyA, channelID: channelA,
                                                   roomID: roomA, ready: false)
        let skipping = try model(live, account: other)
        await skipping.refresh()
        XCTAssertEqual(skipping.activeCompanyID, companyB)

        // Nothing is reachable: still the first by name.
        live.directories[companyB] = try directory(companyID: companyB, channelID: channelB,
                                                   roomID: roomB, ready: false)
        let third = "switcher-" + UUID().uuidString
        defer { clearPrefs(third) }
        let none = try model(live, account: third)
        await none.refresh()
        XCTAssertEqual(none.activeCompanyID, companyA)

        // A remembered company wins over all of it.
        none.selectCompany(companyB)
        XCTAssertEqual(none.activeCompanyID, companyB)
    }

    // MARK: Empty state

    @MainActor
    func testAnAccountWithNoCompanyButTheRightToCreateStillGetsWorkplaceAndAnEmptyState() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let allowed = try model(try api(companies: [], canCreate: true), account: account)
        await allowed.refresh()
        XCTAssertTrue(allowed.isVisible, "the tab is not subdued: there is something to do")
        XCTAssertTrue(allowed.canCreate)
        XCTAssertNil(allowed.activeCompanyID)
        XCTAssertTrue(allowed.switcherEntries(signals: [:]).isEmpty)
        XCTAssertTrue(allowed.invitationRows().isEmpty)

        let closed = try model(try api(companies: [], canCreate: false), account: account)
        await closed.refresh()
        XCTAssertFalse(closed.isVisible, "nothing to show and nothing to do")
        XCTAssertFalse(closed.canCreate, "the closed account is not offered a button that always refuses")
    }

    @MainActor
    func testTheEmptyAndClosedWordsComeFromTheCopyTables() throws {
        let copy = CompanyCopy(design: try LiveDesign())
        let words: [(key: String, text: String)] = [
            ("emptyTitle", copy.emptyTitle), ("emptyBody", copy.emptyBody),
            ("creationClosed", copy.creationClosed), ("createCompany", copy.createAction),
            ("newCompany", copy.newCompanyTitle), ("companyName", copy.companyNameLabel),
            ("create", copy.createSubmit), ("companies", copy.companiesTitle),
            ("noCompanies", copy.noCompanies),
        ]
        for word in words {
            XCTAssertFalse(word.text.isEmpty, word.key)
            // An unresolved key falls back to its own bare name.
            XCTAssertNotEqual(word.text, word.key, "unresolved: \(word.key)")
        }
        for failure in [CompanyCreateFailure.closed, .invalidName, .denied, .conflict, .limit,
                        .authentication, .unavailable] {
            XCTAssertFalse(copy.createFailure(failure).isEmpty)
        }
        XCTAssertEqual(copy.createFailure(.closed), copy.creationClosed)
    }

    @MainActor
    func testTheLeaveConfirmNamesTheCompanyAndSaysAnInviteIsNeededToReturn() throws {
        let copy = CompanyCopy(design: try LiveDesign())
        XCTAssertEqual(copy.leaveTitle(company: "Anka"), "Leave Anka?")
        XCTAssertEqual(copy.leaveMessage, "Leave now; returning needs a new invitation.")
        XCTAssertNotEqual(copy.leaveMessage, "leaveReturnBody", "unresolved key")
        for locale in ["en", "vi", "ja", "zh", "zh-Hant"] {
            XCTAssertTrue(CompanyPendingCopy.leaveTitle(company: "Anka", locale: locale).contains("Anka"), locale)
            XCTAssertFalse(CompanyPendingCopy.text("leaveReturnBody", locale: locale).isEmpty, locale)
        }
    }

    // MARK: Create

    @MainActor
    func testCreateMakesTheNewCompanyTheActiveOneAndOpensItsDefaultChannel() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let live = try api(companies: [companyA])
        live.results = [.success(try newCompanySnapshot())]
        let model = try model(live, account: account)
        await model.refresh()

        let result = await model.createCompany(named: "  Công ty Atum \n")
        XCTAssertEqual(result, .created(roomID: roomNew))
        XCTAssertEqual(live.creates.count, 1)
        XCTAssertEqual(live.creates.first?.name, "Công ty Atum", "sent exactly as the platform accepts it")
        XCTAssertNotNil(try? NativeID(live.creates[0].requestID), "a request ID the platform accepts")
        XCTAssertEqual(model.activeCompanyID, created)
        XCTAssertEqual(model.switcherEntries(signals: [:]).map(\.title), ["Anka", "Công ty Atum"])
        XCTAssertEqual(model.workspace(companyID: created)?.title, "Công ty Atum")

        // The choice is the last-used company next launch.
        let relaunch = try self.model(live, account: account)
        await relaunch.refresh()
        XCTAssertEqual(relaunch.activeCompanyID, created)
    }

    @MainActor
    func testACreateThePlatformClosesLeavesNoCompanyAndEndsTheAttempt() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let live = try api(companies: [companyA])
        live.results = [
            .failure(CompanyAPIError.refused(.denied, reason: "company_creation_closed", retryAfter: nil)),
            .failure(CompanyAPIError.refused(.denied, reason: "company_creation_closed", retryAfter: nil)),
        ]
        let model = try model(live, account: account)
        await model.refresh()

        let first = await model.createCompany(named: "Studio")
        XCTAssertEqual(first, .failed(.closed))
        XCTAssertEqual(model.activeCompanyID, companyA, "nothing changed")
        XCTAssertEqual(model.switcherEntries(signals: [:]).count, 1)
        // A refusal is final, so the next try is a new request.
        let second = await model.createCompany(named: "Studio")
        XCTAssertEqual(second, .failed(.closed))
        XCTAssertEqual(live.creates.count, 2)
        XCTAssertNotEqual(live.creates[0].requestID, live.creates[1].requestID)
    }

    @MainActor
    func testARetryAfterALostAnswerReplaysTheSameRequestSoOnlyOneCompanyResults() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let live = try api(companies: [companyA])
        live.results = [.failure(CompanyAPIError.transport), .success(try newCompanySnapshot(name: "Studio"))]
        let model = try model(live, account: account)
        await model.refresh()

        let lost = await model.createCompany(named: "Studio")
        XCTAssertEqual(lost, .failed(.unavailable))
        let retried = await model.createCompany(named: "Studio")
        XCTAssertEqual(retried, .created(roomID: roomNew))
        XCTAssertEqual(live.creates.map(\.name), ["Studio", "Studio"])
        XCTAssertEqual(live.creates[0].requestID, live.creates[1].requestID,
                       "the platform answers the same company instead of creating a second one")
        XCTAssertEqual(model.switcherEntries(signals: [:]).count, 2)

        // Success ends the attempt: the same name again is a new request.
        live.results = [.failure(CompanyAPIError.transport)]
        _ = await model.createCompany(named: "Studio")
        XCTAssertNotEqual(live.creates[2].requestID, live.creates[0].requestID)
    }

    @MainActor
    func testANameThePlatformWouldRefuseNeverReachesTheClient() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let live = try api(companies: [companyA])
        let model = try model(live, account: account)
        await model.refresh()
        for name in ["", "   ", "\n\t", String(repeating: "x", count: 121)] {
            let result = await model.createCompany(named: name)
            XCTAssertEqual(result, .failed(.invalidName), name.debugDescription)
        }
        XCTAssertTrue(live.creates.isEmpty)
    }

    @MainActor
    func testAV1AnswerHidesWorkplaceInsteadOfBlamingTheName() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let live = try api(companies: [companyA])
        live.results = [.failure(CompanyWireRefusal.v1Answer)]
        let model = try model(live, account: account)
        await model.refresh()
        let result = await model.createCompany(named: "Studio")
        XCTAssertEqual(result, .failed(.unavailable))
        XCTAssertEqual(model.phase, .hidden)
        XCTAssertFalse(model.isVisible)
    }

    @MainActor
    func testASecondCreateWhileOneIsInFlightIsRefusedNotSentTwice() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let live = try api(companies: [companyA])
        live.results = [.success(try newCompanySnapshot(name: "Studio"))]
        live.holdsNextCreate = true
        let model = try model(live, account: account)
        await model.refresh()

        let first = Task { await model.createCompany(named: "Studio") }
        while !live.isHolding { await Task.yield() }
        let second = await model.createCompany(named: "Another")
        XCTAssertEqual(second, .failed(.unavailable))
        XCTAssertEqual(live.creates.count, 1, "the second tap never reached the platform")
        live.release()
        let finished = await first.value
        XCTAssertEqual(finished, .created(roomID: roomNew))
    }

    // MARK: Review round: idempotency, stale accounts, capability

    @MainActor
    func testARetryAfterARelaunchReplaysTheSameRequestSoNoSecondCompanyIsMade() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let live = try api(companies: [companyA])
        live.results = [.failure(CompanyAPIError.transport), .success(try newCompanySnapshot(name: "Studio"))]
        let first = try model(live, account: account)
        await first.refresh()
        let lost = await first.createCompany(named: "Studio")
        XCTAssertEqual(lost, .failed(.unavailable))
        XCTAssertEqual(first.pendingCreateName, "Studio")

        // The app is killed and reopened: a new model on the same store.
        let relaunch = try model(live, account: account)
        await relaunch.refresh()
        XCTAssertEqual(relaunch.pendingCreateName, "Studio", "the attempt survived the relaunch")
        let retried = await relaunch.createCompany(named: "  Studio ")
        XCTAssertEqual(retried, .created(roomID: roomNew))
        XCTAssertEqual(live.creates.map(\.name), ["Studio", "Studio"])
        XCTAssertEqual(live.creates[0].requestID, live.creates[1].requestID,
                       "the same request ID is sent, so the platform makes one company")
        XCTAssertNil(relaunch.pendingCreateName, "success ends the attempt")
        let later = try model(live, account: account)
        XCTAssertNil(later.pendingCreateName, "and it is gone from the store")
    }

    @MainActor
    func testAPersistedAttemptEndsOnARefusalAndIsNotReusedForAnotherName() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let live = try api(companies: [companyA])
        live.results = [
            .failure(CompanyAPIError.transport),
            .failure(CompanyAPIError.refused(.denied, reason: "company_creation_closed", retryAfter: nil)),
            .failure(CompanyAPIError.transport),
        ]
        let first = try model(live, account: account)
        await first.refresh()
        _ = await first.createCompany(named: "Studio")

        let relaunch = try model(live, account: account)
        await relaunch.refresh()
        // Another name is another request, and the platform's refusal is final.
        let refused = await relaunch.createCompany(named: "Other")
        XCTAssertEqual(refused, .failed(.closed))
        XCTAssertNotEqual(live.creates[0].requestID, live.creates[1].requestID)
        XCTAssertNil(relaunch.pendingCreateName)
        let again = try model(live, account: account)
        XCTAssertNil(again.pendingCreateName, "a refusal does not come back after a relaunch")
    }

    @MainActor
    func testEditingTheNameAfterAFailedTryDropsTheOldAttemptEvenAcrossARelaunch() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let live = try api(companies: [companyA])
        live.results = [.failure(CompanyAPIError.transport), .failure(CompanyAPIError.transport)]
        let model = try model(live, account: account)
        await model.refresh()
        _ = await model.createCompany(named: "Studio")
        model.abandonPendingCreate()
        XCTAssertNil(model.pendingCreateName)
        _ = await model.createCompany(named: "Studio")
        XCTAssertNotEqual(live.creates[0].requestID, live.creates[1].requestID,
                          "an edited name is a new request")
        let relaunch = try self.model(live, account: account)
        XCTAssertEqual(relaunch.pendingCreateName, "Studio", "the new attempt is the one kept")
        relaunch.abandonPendingCreate()
        XCTAssertNil(try self.model(live, account: account).pendingCreateName)
    }

    @MainActor
    func testACreateStartedForOneAccountNeverTouchesTheNextAccount() async throws {
        let accountA = "switcher-" + UUID().uuidString
        let accountB = "switcher-" + UUID().uuidString
        defer { clearPrefs(accountA); clearPrefs(accountB) }
        let apiA = try api(companies: [companyA])
        apiA.results = [.failure(CompanyAPIError.refused(.denied, reason: "company_creation_closed",
                                                         retryAfter: nil))]
        apiA.holdsNextCreate = true
        let apiB = try api(companies: [companyB])
        apiB.results = [.success(try newCompanySnapshot(name: "Beta"))]
        apiB.holdsNextCreate = true
        let model = try model(apiA, account: accountA)
        await model.refresh()

        let aCreate = Task { await model.createCompany(named: "Acme") }
        while !apiA.isHolding { await Task.yield() }

        // A signs out and B signs in while A's answer is still on the wire.
        model.clear()
        XCTAssertTrue(apiA.isHolding)
        model.clientProvider = { apiB }
        model.beginAccountScope(accountB)
        await model.refresh()
        XCTAssertEqual(model.activeCompanyID, companyB)
        let tokenBefore = model.actionFailureToken

        let bCreate = Task { await model.createCompany(named: "Beta") }
        while !apiB.isHolding { await Task.yield() }

        // A's create fails definitively now.
        apiA.release()
        let stale = await aCreate.value
        XCTAssertEqual(stale, .failed(.unavailable), "the old account's answer is dropped")
        XCTAssertTrue(apiA.heldCreateWasCancelled, "sign-out cancelled the create")
        XCTAssertEqual(model.actionFailureToken, tokenBefore, "B saw no failure from A")
        XCTAssertEqual(model.pendingCreateName, "Beta", "B's attempt was not cleared by A's refusal")
        XCTAssertEqual(model.activeCompanyID, companyB)

        // B is still mid-create: A's completion did not reopen the gate.
        let second = await model.createCompany(named: "Gamma")
        XCTAssertEqual(second, .failed(.unavailable))
        XCTAssertEqual(apiB.creates.map(\.name), ["Beta"], "the second tap never reached the platform")

        apiB.release()
        let finished = await bCreate.value
        XCTAssertEqual(finished, .created(roomID: roomNew))
        XCTAssertEqual(model.activeCompanyID, created)
        XCTAssertNil(model.pendingCreateName)
        // B can create again afterwards.
        apiB.results = [.failure(CompanyAPIError.transport)]
        let next = await model.createCompany(named: "Delta")
        XCTAssertEqual(next, .failed(.unavailable))
        XCTAssertEqual(apiB.creates.map(\.name), ["Beta", "Delta"])
        // A's own store keeps A's attempt: replaying it is safe.
        let stored = CompanyLocalPrefsJournal(key: CompanyLocalPrefsJournal.key(forAccount: accountA)).load()
        XCTAssertEqual(stored.pendingCreate?.displayName, "Acme")
    }

    @MainActor
    func testLosingTheRightToCreateStopsASubmitBeforeItReachesThePlatform() async throws {
        let account = "switcher-" + UUID().uuidString
        defer { clearPrefs(account) }
        let live = try api(companies: [companyA], canCreate: true)
        let model = try model(live, account: account)
        await model.refresh()
        XCTAssertTrue(model.canCreate)

        // The form is open; a refresh brings the platform's new answer.
        live.list = try list([(companyA, "Anka")], canCreate: false)
        await model.refresh()
        XCTAssertFalse(model.canCreate)
        let result = await model.createCompany(named: "Studio")
        XCTAssertEqual(result, .failed(.closed))
        XCTAssertTrue(live.creates.isEmpty, "nothing was sent")
        XCTAssertNil(model.pendingCreateName)
    }
}
