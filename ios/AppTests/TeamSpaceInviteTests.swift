@testable import AtumMobile
import AtumChat
import AtumDesign
import AtumNativeAPI
import XCTest

/// Wave 3 TS-11 (invite people, links, join with a link) and TS-13 (create a channel,
/// Favorites and Archived) on the company model, against a stub client.
final class TeamSpaceInviteTests: XCTestCase {
    private enum StubFailure: Error { case unavailable }

    @MainActor
    private final class API: CompanyWorkspaceAPI, CompanyInvitesAPI, @unchecked Sendable {
        var companies: [String]
        var role: String
        var invites = [(company: String, handle: String, method: CompanyInviteMethod)]()
        var inviteFailure: CompanyAPIError?
        var snapshotReads = 0
        var createRequests = [String]()
        var createFailures = [CompanyAPIError]()
        var redeemCompany: String?

        init(companies: [String], role: String) {
            self.companies = companies
            self.role = role
        }

        // MARK: Workspace

        func companyList() async throws -> CompanyRead<CompanyList> {
            .v1_1(try NativeAPI.decode(CompanyList.self, from: JSONSerialization.data(withJSONObject: [
                "schemaVersion": 2,
                "companies": companies.map { ["id": $0, "displayName": "Atum", "role": role, "authorityGeneration": 1] },
                "invitations": [], "canCreate": false,
            ])))
        }
        func companySnapshot(companyID: NativeID) async throws -> CompanyRead<CompanySnapshot> {
            snapshotReads += 1
            var members: [[String: Any]] = [
                ["memberRef": String(repeating: "a", count: 43), "role": role, "state": "active", "self": true,
                 "handle": "minh", "displayName": "Minh"],
            ]
            if invites.contains(where: { $0.handle == "lan" }) {
                members.append(["memberRef": String(repeating: "b", count: 43), "role": "member", "state": "invited",
                                "self": false, "handle": "lan", "displayName": "Lan"])
            }
            return .v1_1(try NativeAPI.decode(CompanySnapshot.self, from: JSONSerialization.data(withJSONObject: [
                "schemaVersion": 2,
                "company": ["id": companyID.rawValue, "displayName": "Atum", "role": role, "authorityGeneration": 1],
                "members": members, "projects": [], "defaultChannelId": NSNull(),
            ])))
        }
        func companyChannels(companyID: NativeID) async throws -> CompanyRead<CompanyChannelDirectory> {
            func channel(_ id: String, _ name: String, _ state: String, _ room: String) -> [String: Any] {
                ["schemaVersion": 2,
                 "channel": ["id": id, "companyId": companyID.rawValue, "displayName": name, "visibility": "company",
                             "state": state, "projectId": NSNull(), "authorityGeneration": 1, "channelGeneration": 1],
                 "memberCount": 2, "room": ["state": "ready", "roomId": room]]
            }
            return .v1_1(try NativeAPI.decode(CompanyChannelDirectory.self, from: JSONSerialization.data(
                withJSONObject: ["schemaVersion": 2, "channels": [
                    channel("00000000-0000-4000-8000-000000000001", "launch", "active", "!launch:atum.test"),
                    channel("00000000-0000-4000-8000-000000000002", "old", "archived", "!old:atum.test"),
                    channel("00000000-0000-4000-8000-000000000003", "ops", "active", "!ops:atum.test"),
                ]])))
        }
        func acceptCompanyInvitation(companyID: NativeID, requestID: NativeID,
                                     invitationID: NativeID) async throws -> CompanySnapshot {
            throw StubFailure.unavailable
        }
        func leaveCompany(companyID: NativeID, requestID: NativeID) async throws -> CompanyLeaveAcknowledgement {
            throw StubFailure.unavailable
        }
        func createCompany(requestID: NativeID, displayName: String) async throws -> CompanySnapshot {
            throw StubFailure.unavailable
        }

        // MARK: Invites

        func companyInviteReadiness() async throws -> CompanyInviteReadiness { throw CompanyAPIError.transport }
        func inviteToCompany(companyID: NativeID, requestID: NativeID, handle: String,
                             method: CompanyInviteMethod) async throws {
            if let inviteFailure { throw inviteFailure }
            invites.append((companyID.rawValue, handle, method))
        }
        func companyInviteLinks(companyID: NativeID) async throws -> [CompanyInviteLinkSummary] { [] }
        func createCompanyInviteLink(companyID: NativeID, requestID: NativeID) async throws -> CompanyInviteLinkCreated {
            throw CompanyAPIError.transport
        }
        func revokeCompanyInviteLink(companyID: NativeID, linkID: NativeID, requestID: NativeID) async throws {}
        func previewCompanyInviteLink(token: CompanyInviteLinkToken) async throws -> CompanyInviteLinkPreview {
            throw CompanyAPIError.refused(.missing, reason: "invite_link_unavailable", retryAfter: nil)
        }
        func redeemCompanyInviteLink(requestID: NativeID, token: CompanyInviteLinkToken) async throws
            -> CompanyInviteLinkRedeemed {
            let company = try XCTUnwrap(redeemCompany)
            companies.append(company)
            return try NativeAPI.decode(CompanyInviteLinkRedeemed.self, from: JSONSerialization.data(withJSONObject: [
                "schemaVersion": 3, "companyId": company, "memberRef": String(repeating: "c", count: 43),
                "role": "member", "state": "active",
                "link": ["id": "00000000-0000-4000-8000-507f79cf6e24", "maxUses": 5, "usesRemaining": 4,
                         "consumedNow": true, "replayed": false],
            ]))
        }
        func createCompanyChannel(companyID: NativeID, requestID: NativeID,
                                  displayName: String) async throws -> CompanyChannelEntry {
            createRequests.append(requestID.rawValue)
            if !createFailures.isEmpty { throw createFailures.removeFirst() }
            return try NativeAPI.decode(CompanyChannelEntry.self, from: JSONSerialization.data(withJSONObject: [
                "schemaVersion": 2,
                "channel": ["id": "00000000-0000-4000-8000-000000000009", "companyId": companyID.rawValue,
                            "displayName": displayName, "visibility": "company", "state": "provisioning",
                            "projectId": NSNull(), "authorityGeneration": 1, "channelGeneration": 1],
                "memberCount": 1, "room": ["state": "provisioning", "roomId": NSNull()],
            ]))
        }
    }

    private let company = "00000000-0000-4000-8000-157a30343cf3"
    private let joined = "00000000-0000-4000-8000-68ce1b921bf1"

    @MainActor
    private func model(_ api: API) throws -> (CompanyWorkspaceModel, String) {
        let account = "invite-" + UUID().uuidString
        let model = CompanyWorkspaceModel()
        model.copy = CompanyCopy(design: try LiveDesign())
        model.clientProvider = { api }
        model.invitesProvider = { api }
        model.beginAccountScope(account)
        return (model, account)
    }

    private func clearPrefs(_ account: String) {
        UserDefaults.standard.removeObject(forKey: CompanyLocalPrefsJournal.key(forAccount: account))
    }

    @MainActor
    func testAnAdminInvitesByHandleOnTheLegacyWire() async throws {
        let api = API(companies: [company], role: "admin")
        let (model, account) = try model(api)
        defer { clearPrefs(account) }
        await model.refresh()
        let abilities = model.inviteAbilities(companyID: company)
        XCTAssertEqual(abilities, CompanyInviteAbilities(invite: true, method: .legacy))
        XCTAssertTrue(model.menuAllowed(companyID: company, inviteAvailable: abilities.invite).invite)
        XCTAssertEqual(model.inviteStanding(companyID: company, handle: "minh"), .member)
        XCTAssertEqual(model.inviteStanding(companyID: company, handle: "lan"), .none)

        let reads = api.snapshotReads
        let outcome = await model.invite(companyID: company, handle: "lan")
        XCTAssertEqual(outcome, .invited)
        XCTAssertEqual(api.invites.map(\.handle), ["lan"])
        XCTAssertEqual(api.invites.first?.method, .legacy)
        XCTAssertGreaterThan(api.snapshotReads, reads, "the roster is read again after an invite")
        XCTAssertEqual(model.inviteStanding(companyID: company, handle: "lan"), .invited)
    }

    @MainActor
    func testARefusedInviteSaysWhy() async throws {
        let api = API(companies: [company], role: "admin")
        api.inviteFailure = .refused(.missing, reason: "invite_target_unavailable", retryAfter: nil)
        let (model, account) = try model(api)
        defer { clearPrefs(account) }
        await model.refresh()
        let outcome = await model.invite(companyID: company, handle: "nobody")
        XCTAssertEqual(outcome, .refused(.missing, reason: "invite_target_unavailable"))
        api.inviteFailure = .transport
        let lost = await model.invite(companyID: company, handle: "nobody")
        XCTAssertEqual(lost, .unavailable)
    }

    /// The wave 3 pin carries `inviteLinkUsage` with two number arguments; the
    /// invite sheet's link rows used to pass words and trapped on open.
    @MainActor
    func testTheLinkUsageLineTakesItsCountsAsNumbers() throws {
        let design = try LiveDesign()
        let team = TeamSpaceCopy(design: design)
        let key = "shared.matrix-team-space-copy.copy.inviteLinkUsage"
        let line = team.inviteLinkUsage(used: 2, max: 5)
        if design.copy.parameterKinds(key) == ["number", "number"] {
            XCTAssertEqual(line, design.text(key, arguments: [.number(2), .number(5)]))
        }
        XCTAssertTrue(line.contains("2") && line.contains("5"), line)
    }

    @MainActor
    func testAnUnknownHandleIsWordedByTheWireThatAnswered() throws {
        let design = try LiveDesign()
        let team = TeamSpaceCopy(design: design)
        let copy = CompanyCopy(design: design)
        let refused = CompanyInviteOutcome.refused(.missing, reason: "invite_target_unavailable")
        XCTAssertEqual(CompanyInviteText.failure(refused, method: .legacy, team: team, copy: copy),
                       team.refusal("invite_target_unavailable"))
        XCTAssertEqual(CompanyInviteText.failure(refused, method: .admin, team: team, copy: copy),
                       team.inviteCantInvite)
        XCTAssertEqual(CompanyInviteText.failure(.refused(.denied, reason: nil), method: .admin, team: team, copy: copy),
                       team.inviteNotAllowed)
    }

    @MainActor
    func testAMemberGetsNoSheetAndNoCall() async throws {
        let api = API(companies: [company], role: "member")
        let (model, account) = try model(api)
        defer { clearPrefs(account) }
        await model.refresh()
        XCTAssertEqual(model.inviteAbilities(companyID: company), .none)
        XCTAssertFalse(model.channelCreationAllowed(companyID: company))
        let outcome = await model.invite(companyID: company, handle: "lan")
        XCTAssertEqual(outcome, .refused(.denied, reason: nil))
        XCTAssertTrue(api.invites.isEmpty)
    }

    @MainActor
    func testWithoutAnInviteClientNothingIsDrawn() async throws {
        let api = API(companies: [company], role: "admin")
        let (model, account) = try model(api)
        defer { clearPrefs(account) }
        model.invitesProvider = { nil }
        await model.refresh()
        XCTAssertEqual(model.inviteAbilities(companyID: company), .none)
        XCTAssertFalse(model.channelCreationAllowed(companyID: company))
    }

    @MainActor
    func testALostChannelCreateReplaysTheSameRequest() async throws {
        let api = API(companies: [company], role: "admin")
        let (model, account) = try model(api)
        defer { clearPrefs(account) }
        await model.refresh()
        XCTAssertTrue(model.channelCreationAllowed(companyID: company))
        api.createFailures = [.transport]
        let first = await model.createChannel(companyID: company, named: " launch plans ")
        XCTAssertEqual(first, .failed(.transport))
        let second = await model.createChannel(companyID: company, named: "launch plans")
        XCTAssertEqual(second, .created(roomID: nil), "still being prepared")
        XCTAssertEqual(api.createRequests.count, 2)
        XCTAssertEqual(api.createRequests[0], api.createRequests[1], "a lost answer is replayed, never a second channel")
        // A finished create forgets its request: the next one is new.
        _ = await model.createChannel(companyID: company, named: "launch plans")
        XCTAssertNotEqual(api.createRequests[2], api.createRequests[1])
        // A refusal is final for its request.
        api.createFailures = [.refused(.conflict, reason: nil, retryAfter: nil)]
        _ = await model.createChannel(companyID: company, named: "ops")
        _ = await model.createChannel(companyID: company, named: "ops")
        XCTAssertNotEqual(api.createRequests[3], api.createRequests[4])
    }

    @MainActor
    func testFavouritesAndArchivedFlagTheRows() async throws {
        let api = API(companies: [company], role: "member")
        let (model, account) = try model(api)
        defer { clearPrefs(account) }
        await model.refresh()
        let workspace = try XCTUnwrap(model.workspace(companyID: company,
                                                      favourites: ["!launch:atum.test", "!old:atum.test"]))
        let plan = CompanyChannelSectionPlan.split(workspace.channels, isFavourite: \.isFavourite,
                                                   isArchived: \.isArchived, matches: { _ in true })
        XCTAssertEqual(plan.favorites.map(\.title), ["launch"])
        XCTAssertEqual(plan.channels.map(\.title), ["ops"])
        XCTAssertEqual(plan.archived.map(\.title), ["old"])
    }

    @MainActor
    func testJoiningWithALinkOpensTheCompany() async throws {
        let api = API(companies: [company], role: "member")
        api.redeemCompany = joined
        let (model, account) = try model(api)
        defer { clearPrefs(account) }
        await model.refresh()
        let token = try XCTUnwrap(CompanyInviteLinkToken(token: String(repeating: "t", count: 43)))
        let failed = await model.previewInviteLink(token)
        XCTAssertEqual(failed, .failure(.invalid, preview: nil))

        let preview = try NativeAPI.decode(CompanyInviteLinkPreview.self, from: JSONSerialization.data(withJSONObject: [
            "schemaVersion": 3, "company": ["id": joined, "displayName": "Labs"], "role": "member",
            "inviter": ["handle": "minh", "displayName": NSNull()], "expiresAt": 4_000_000_000,
            "maxUses": 5, "usesRemaining": 5,
        ]))
        let request = try NativeID(UUID().uuidString.lowercased())
        let state = await model.redeemInviteLink(token, requestID: request, preview: preview)
        XCTAssertEqual(state, .complete(preview, .joined, companyID: joined))
        XCTAssertEqual(model.activeCompanyID, joined)
    }
}
