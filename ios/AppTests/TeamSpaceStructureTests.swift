@testable import AtumMobile
import AtumChat
import AtumNativeAPI
import XCTest

/// Wave 2 Team Space structure (TS-6..TS-9): the company menu's entries, the room
/// labels Activity, Saved and Pinned rows use, and the channel facts behind the
/// chrome. The fixtures are `TeamSpaceDailyTests`' (two companies, member viewer).
final class TeamSpaceStructureTests: XCTestCase {
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

    private func clearPrefs(_ account: String) {
        UserDefaults.standard.removeObject(forKey: CompanyLocalPrefsJournal.key(forAccount: account))
    }

    @MainActor
    func testAMemberMenuIsOverviewMembersAndLeave() async throws {
        let account = "structure-" + UUID().uuidString
        defer { clearPrefs(account) }
        let model = try model(try api(companies: [companyA]), account: account)
        await model.refresh()
        let allowed = model.menuAllowed(companyID: companyA)
        XCTAssertEqual(allowed, CompanyMenuAllowed(overview: true, members: true, leave: true),
                       "no invite, settings or wallet for a member, and no create while the platform says no")
        XCTAssertEqual(model.menuAllowed(companyID: nil), CompanyMenuAllowed())
        XCTAssertEqual(model.viewerRole(companyID: companyA), model.copy?.role(.member))
    }

    /// Communication notifications: the app's directory names a channel as
    /// Team Space does ("# channel · Company"), carries the company logo, and
    /// marks assistant and app chats for their header face. People chats and
    /// placeholder rows get no entry (the extension uses the SDK's facts).
    @MainActor
    func testNotificationDirectoryNamesChannelsLikeTeamSpaceWithTheCompanyLogo() async throws {
        let account = "structure-" + UUID().uuidString
        defer { clearPrefs(account) }
        let model = try model(try api(companies: [companyA, companyB]), account: account)
        await model.refresh()
        let copy = try XCTUnwrap(model.copy)
        let rooms = [
            LiveProductRoom(id: roomA, kind: .group, title: "general", roomAvatarURL: "mxc://atum.test/logo-a"),
            LiveProductRoom(id: roomA2, kind: .group, title: "ops"),
            LiveProductRoom(id: "!agent:atum.test", kind: .agent, title: "Atlas",
                            matrixAvatarURL: "mxc://atum.test/atlas"),
            LiveProductRoom(id: "!bot:atum.test", kind: .agent, title: "Moon", isAppBotRoom: true),
            LiveProductRoom(id: "!friend:atum.test", kind: .people, title: "Friend"),
            LiveProductRoom(id: "app:moon", kind: .agent, title: "Moon", isAppBotRoom: true),
        ]
        let input = try XCTUnwrap(NotificationRoomPublisher.input(ownUserID: "@me:atum.test", rooms: rooms,
                                                                  workspace: model))
        let general = try XCTUnwrap(input.rooms[roomA])
        XCTAssertEqual(general.kind, .teamChannel)
        XCTAssertEqual(general.groupName, "# " + copy.channelName("general", isDefault: true) + " · Company 1")
        XCTAssertEqual(general.companyLogoURI, "mxc://atum.test/logo-a")
        XCTAssertEqual(general.companyName, "Company 1")
        XCTAssertEqual(input.rooms[roomA2]?.groupName, "# ops · Company 1")
        XCTAssertEqual(input.rooms[roomA2]?.companyLogoURI, "mxc://atum.test/logo-a",
                       "a channel without its own avatar still carries the company logo")
        XCTAssertEqual(input.rooms["!agent:atum.test"], NotificationRoomEntry(kind: .assistant, faceName: "Atlas"))
        XCTAssertEqual(input.rooms["!bot:atum.test"]?.kind, .appBot)
        XCTAssertNil(input.rooms["!friend:atum.test"])
        XCTAssertNil(input.rooms["app:moon"])
        XCTAssertEqual(input.faces.map(\.roomID), ["!agent:atum.test", "!bot:atum.test"])
        XCTAssertEqual(input.faces.first?.kind, .assistant)
        XCTAssertEqual(input.faces.last?.kind, .app)
        XCTAssertTrue(input.faces[0].expectsPhoto)
        XCTAssertNotEqual(input.faces[0].fileName, input.faces[1].fileName)
        XCTAssertNil(NotificationRoomPublisher.input(ownUserID: nil, rooms: rooms, workspace: model))
    }

    @MainActor
    func testRoomLabelsAreTheCompanyDirectorysOnly() async throws {
        let account = "structure-" + UUID().uuidString
        defer { clearPrefs(account) }
        let model = try model(try api(companies: [companyA, companyB]), account: account)
        await model.refresh()
        let copy = try XCTUnwrap(model.copy)
        let general = try XCTUnwrap(model.teamSpaceRoomLabel(roomID: roomA))
        XCTAssertEqual(general.companyID, companyA)
        XCTAssertEqual(general.name, "# " + copy.channelName("general", isDefault: true))
        XCTAssertEqual(model.teamSpaceRoomLabel(roomID: roomA2)?.name, "# ops")
        XCTAssertNil(model.teamSpaceRoomLabel(roomID: "!personal:atum.test"))
        let rooms = model.teamSpaceRoomIDs(companyID: companyA)
        XCTAssertTrue(rooms.isSuperset(of: [roomA, roomA2]))
        XCTAssertFalse(rooms.contains(roomB), "another company's channel never reaches this inbox")
    }

    @MainActor
    func testChannelMemberCountIsThePlatformsCount() async throws {
        let account = "structure-" + UUID().uuidString
        defer { clearPrefs(account) }
        let model = try model(try api(companies: [companyA]), account: account)
        await model.refresh()
        XCTAssertEqual(model.channelMemberCount(roomID: roomA), 2)
        XCTAssertNil(model.channelMemberCount(roomID: "!personal:atum.test"))
    }
}
