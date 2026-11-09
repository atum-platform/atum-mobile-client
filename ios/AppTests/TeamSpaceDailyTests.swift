@testable import AtumMobile
import AtumChat
import AtumNativeAPI
import XCTest

/// Workplace daily-use slice (U1/U2/U4): the active company's channel list with
/// Matrix unread marks, the invitation signal and the persisted "Not now", the
/// per-channel mute path, and the roster behind the `@` picker.
final class TeamSpaceDailyTests: XCTestCase {
    private enum StubFailure: Error { case unavailable }

    @MainActor
    private final class API: CompanyWorkspaceAPI, @unchecked Sendable {
        var list: CompanyList
        let directories: [String: CompanyChannelDirectory]
        let snapshots: [String: CompanySnapshot]

        init(list: CompanyList, directories: [String: CompanyChannelDirectory],
             snapshots: [String: CompanySnapshot]) {
            self.list = list
            self.directories = directories
            self.snapshots = snapshots
        }

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
            throw StubFailure.unavailable
        }
    }

    private let companyA = "00000000-0000-4000-8000-157a30343cf3"
    private let companyB = "00000000-0000-4000-8000-35600c849c7c"
    private let channelA = "00000000-0000-4000-8000-c3182f81c210"
    private let channelA2 = "00000000-0000-4000-8000-09dc16902af6"
    private let channelB = "00000000-0000-4000-8000-fc32a98981c4"
    private let invitation = "00000000-0000-4000-8000-a2059be8d5a7"
    private let roomA = "!general-a:atum.test"
    private let roomA2 = "!ops-a:atum.test"
    private let roomB = "!general-b:atum.test"

    private func list(companies: [String], invitations: [String] = []) throws -> CompanyList {
        try NativeAPI.decode(CompanyList.self, from: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "companies": companies.enumerated().map { index, id in [
                "id": id, "displayName": "Company \(index + 1)",
                "role": "member", "authorityGeneration": 1,
            ] },
            "invitations": invitations.map { id in [
                "id": id, "companyId": "00000000-0000-4000-8000-8059425b58ac",
                "displayName": "Labs", "role": "member",
                "inviter": ["handle": "boss", "displayName": "The Boss"],
            ] },
            "canCreate": false,
        ]))
    }

    private func channel(companyID: String, id: String, name: String, isDefault: Bool,
                         roomID: String) -> [String: Any] {
        var channel: [String: Any] = [
            "id": id, "companyId": companyID, "displayName": name, "visibility": "company",
            "state": "active", "projectId": NSNull(), "authorityGeneration": 1,
            "channelGeneration": 1,
        ]
        // `systemKey` is absent, not null, on an ordinary channel.
        if isDefault { channel["systemKey"] = "default" }
        return [
            "schemaVersion": 2,
            "channel": channel,
            "memberCount": 2,
            "room": ["state": "ready", "roomId": roomID],
        ]
    }

    private func directory(companyID: String,
                           _ channels: [[String: Any]]) throws -> CompanyChannelDirectory {
        try NativeAPI.decode(CompanyChannelDirectory.self, from: JSONSerialization.data(
            withJSONObject: ["schemaVersion": 2, "channels": channels]))
    }

    private func snapshot(companyID: String, channelID: String) throws -> CompanySnapshot {
        try NativeAPI.decode(CompanySnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "company": ["id": companyID, "displayName": "Company",
                        "role": "member", "authorityGeneration": 1],
            "members": [
                ["memberRef": String(repeating: "a", count: 43), "role": "member",
                 "state": "active", "self": true, "handle": "owner", "displayName": "Owner"],
                ["memberRef": String(repeating: "b", count: 43), "role": "member",
                 "state": "active", "self": false, "handle": "anna", "displayName": "Anna Lê"],
            ],
            "projects": [], "defaultChannelId": channelID,
        ]))
    }

    @MainActor
    private func api(companies: [String], invitations: [String] = []) throws -> API {
        API(list: try list(companies: companies, invitations: invitations),
            directories: [
                companyA: try directory(companyID: companyA, [
                    channel(companyID: companyA, id: channelA, name: "general", isDefault: true, roomID: roomA),
                    channel(companyID: companyA, id: channelA2, name: "ops", isDefault: false, roomID: roomA2),
                ]),
                companyB: try directory(companyID: companyB, [
                    channel(companyID: companyB, id: channelB, name: "general", isDefault: true, roomID: roomB),
                ]),
            ],
            snapshots: [companyA: try snapshot(companyID: companyA, channelID: channelA),
                        companyB: try snapshot(companyID: companyB, channelID: channelB)])
    }

    @MainActor
    private func model(_ api: API, account: String) throws -> CompanyWorkspaceModel {
        let model = CompanyWorkspaceModel()
        model.copy = CompanyCopy(design: try LiveDesign())
        model.clientProvider = { api }
        model.beginAccountScope(account)
        return model
    }

    private func room(_ id: String, unread: Int = 0, notifications: Int = 0, highlights: Int = 0,
                      muted: Bool = false) -> LiveProductRoom {
        LiveProductRoom(id: id, kind: .group, title: id, unreadCount: unread,
                        notificationCount: notifications, highlightCount: highlights, isMuted: muted)
    }

    private func clearPrefs(_ account: String) {
        UserDefaults.standard.removeObject(forKey: CompanyLocalPrefsJournal.key(forAccount: account))
    }

    // MARK: Unread and mentions

    @MainActor
    func testChannelRowsCarryTheMatrixMarkAndBoldOnlyWhenItMatters() async throws {
        let account = "daily-" + UUID().uuidString
        defer { clearPrefs(account) }
        let model = try model(try api(companies: [companyA]), account: account)
        await model.refresh()

        let signals = model.roomSignals(from: [
            room(roomA, unread: 4, notifications: 4, highlights: 2),
            room(roomA2, unread: 6, notifications: 6, muted: true),
            room("!personal:atum.test", unread: 9, notifications: 9),
        ])
        XCTAssertEqual(Set(signals.keys), [roomA, roomA2], "a personal group is not a company channel")

        let workspace = try XCTUnwrap(model.workspace(companyID: companyA, signals: signals))
        let general = try XCTUnwrap(workspace.channels.first { $0.roomID == roomA })
        let ops = try XCTUnwrap(workspace.channels.first { $0.roomID == roomA2 })
        XCTAssertEqual(general.badge, .mention(4))
        XCTAssertTrue(general.isBold)
        XCTAssertEqual(ops.badge, .quietDot)
        XCTAssertTrue(ops.isMuted)
        XCTAssertFalse(ops.isBold)
        XCTAssertEqual(workspace.channels.first?.roomID, roomA, "the default channel leads")
    }

    @MainActor
    func testCompanyTabAndAppIconFoldTheChannels() async throws {
        let account = "daily-" + UUID().uuidString
        defer { clearPrefs(account) }
        let model = try model(try api(companies: [companyA, companyB]), account: account)
        await model.refresh()
        let signals = model.roomSignals(from: [
            room(roomA, unread: 4, notifications: 4, highlights: 2),
            room(roomB, unread: 1, notifications: 1),
        ])
        XCTAssertEqual(model.companyBadge(companyID: companyA, signals: signals), .mention(4))
        XCTAssertEqual(model.companyBadge(companyID: companyB, signals: signals), .dot)
        XCTAssertEqual(model.tabBadge(signals: signals), .mention(4))
        XCTAssertEqual(Badge.appIconCount(model.appIconRows(signals: signals)), 5,
                       "company mentions and unread count toward the app icon like Home rows")
        XCTAssertEqual(model.switcherEntries(signals: signals).map(\.badge), [.none, .dot],
                       "no mark on the company you are in (A, active); B shows its dot")
        model.selectCompany(companyB)
        XCTAssertEqual(model.switcherEntries(signals: signals).map(\.badge), [.mention(4), .none])
    }

    @MainActor
    func testTheSwitcherPicksTheCompanyAndKeepsItAcrossARestart() async throws {
        let account = "daily-" + UUID().uuidString
        defer { clearPrefs(account) }
        let first = try model(try api(companies: [companyA, companyB]), account: account)
        await first.refresh()
        XCTAssertEqual(first.activeCompanyID, companyA)
        first.selectCompany(companyB)
        XCTAssertEqual(first.activeCompanyID, companyB)

        let second = try model(try api(companies: [companyA, companyB]), account: account)
        await second.refresh()
        XCTAssertEqual(second.activeCompanyID, companyB)

        let gone = try model(try api(companies: [companyA]), account: account)
        await gone.refresh()
        XCTAssertEqual(gone.activeCompanyID, companyA, "a company that left the list falls back to the first")
    }

    @MainActor
    func testTheTabMarkIsSpokenWithItsNumbers() throws {
        let copy = CompanyCopy(design: try LiveDesign())
        let mention = copy.tabMarkDescription(.mention(4))
        XCTAssertTrue(mention.contains("4"), mention)
        XCTAssertTrue(mention.contains(copy.markDescription(.mention(4)).last ?? "?"), mention)
        let invitations = copy.tabMarkDescription(.count(2))
        XCTAssertTrue(invitations.contains(copy.invitationsTitle), invitations)
        XCTAssertTrue(invitations.contains("2"), invitations)
        XCTAssertEqual(copy.tabMarkDescription(.dot), copy.markDescription(.dot).joined(separator: ", "))
        XCTAssertEqual(copy.tabMarkDescription(.none), "")
    }

    @MainActor
    func testARouteIntoAnotherCompanysRoomMakesThatCompanyTheWorkplaceRoot() async throws {
        let account = "daily-" + UUID().uuidString
        defer { clearPrefs(account) }
        let model = try model(try api(companies: [companyA, companyB]), account: account)
        await model.refresh()
        XCTAssertEqual(model.activeCompanyID, companyA)

        model.activateCompany(owning: roomB)
        XCTAssertEqual(model.activeCompanyID, companyB, "Back from the chat lands on company B's list")

        model.activateCompany(owning: "!personal:atum.test")
        XCTAssertEqual(model.activeCompanyID, companyB, "a room that is not a company channel changes nothing")

        let restarted = try self.model(try api(companies: [companyA, companyB]), account: account)
        await restarted.refresh()
        XCTAssertEqual(restarted.activeCompanyID, companyB, "tab restoration shows the routed company")
    }

    // MARK: Invitation signal

    @MainActor
    func testAPendingInvitationBadgesTheTabAndNotNowSurvivesARestart() async throws {
        let account = "daily-" + UUID().uuidString
        defer { clearPrefs(account) }
        let first = try model(try api(companies: [companyA], invitations: [invitation]), account: account)
        await first.refresh()
        XCTAssertEqual(first.pendingInvitationCount, 1)
        XCTAssertEqual(first.invitationRows().count, 1)
        XCTAssertEqual(first.tabBadge(signals: [:]), .count(1))
        XCTAssertTrue(first.isVisible)

        first.declineInvitation(invitation)
        XCTAssertEqual(first.pendingInvitationCount, 0)
        XCTAssertEqual(first.tabBadge(signals: [:]), .none)
        XCTAssertTrue(first.invitationRows().isEmpty)

        let relaunch = try model(try api(companies: [companyA], invitations: [invitation]), account: account)
        await relaunch.refresh()
        XCTAssertEqual(relaunch.pendingInvitationCount, 0, "Not now is remembered")

        let other = "daily-" + UUID().uuidString
        defer { clearPrefs(other) }
        let otherAccount = try model(try api(companies: [companyA], invitations: [invitation]), account: other)
        await otherAccount.refresh()
        XCTAssertEqual(otherAccount.pendingInvitationCount, 1, "the answer is per account")
    }

    @MainActor
    func testAnInvitationOnlyAccountStillHasAWorkplaceTab() async throws {
        let account = "daily-" + UUID().uuidString
        defer { clearPrefs(account) }
        let model = try model(try api(companies: [], invitations: [invitation]), account: account)
        await model.refresh()
        XCTAssertTrue(model.isVisible)
        XCTAssertNil(model.activeCompanyID)
        XCTAssertEqual(model.tabBadge(signals: [:]), .count(1))
    }

    @MainActor
    func testAnInvitationThePlatformDroppedIsForgotten() async throws {
        let account = "daily-" + UUID().uuidString
        defer { clearPrefs(account) }
        let live = try api(companies: [companyA], invitations: [invitation])
        let first = try model(live, account: account)
        await first.refresh()
        first.declineInvitation(invitation)
        live.list = try list(companies: [companyA])
        await first.refresh()

        // It comes back as a new, unanswered invitation if the platform lists it again.
        live.list = try list(companies: [companyA], invitations: [invitation])
        await first.refresh()
        XCTAssertEqual(first.pendingInvitationCount, 1)
    }

    // MARK: Mention roster

    @MainActor
    func testTheRosterBehindTheMentionPickerComesFromTheCompanySnapshot() async throws {
        let account = "daily-" + UUID().uuidString
        defer { clearPrefs(account) }
        let model = try model(try api(companies: [companyA]), account: account)
        await model.refresh()
        let roster = model.mentionRoster(roomID: roomA)
        XCTAssertEqual(roster.map(\.handle).sorted(), ["anna", "owner"])
        XCTAssertEqual(roster.first { $0.handle == "anna" }?.name, "Anna Lê")
        XCTAssertTrue(model.mentionRoster(roomID: "!personal:atum.test").isEmpty)
    }
}
