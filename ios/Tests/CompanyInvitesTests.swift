import Foundation
import XCTest
@testable import AtumNativeAPI

/// Wave 3 TS-11/TS-13: invite abilities, the typed handle, invite links (wire 1.2 fixtures
/// vendored from the desktop's public pack), join with a link and the channel sections.
final class CompanyInvitesTests: XCTestCase {
    private let company = "00000000-0000-4000-8000-68ce1b921bf1"

    private func fixture(_ name: String) throws -> Data {
        let dir = try XCTUnwrap(Bundle.module.url(forResource: "company-workspace-v1.2", withExtension: nil))
        return try Data(contentsOf: dir.appendingPathComponent(name))
    }

    private func capabilities(teamAdmin: String = "active", channelAdmission: String = "inactive",
                              wires: [String] = ["1", "1.1", "1.2", "1.3"]) throws -> CompanyCapabilities {
        let json: [String: Any] = [
            "schemaVersion": 4, "wireVersion": "1.3", "supportedWireVersions": wires,
            "features": ["ownership": true, "invitationLifecycle": true, "capabilityDiscovery": true,
                         "channelAdmission": true, "companyConversations": false],
            "activation": ["teamAdmin": teamAdmin, "channelAdmission": channelAdmission,
                           "companyConversations": "inactive"],
            "controller": ["roomReconciliation": "ready"],
        ]
        return try CompanyConversationWire.decodeCapabilities(JSONSerialization.data(withJSONObject: json))
    }

    // MARK: Profile and abilities

    func testNoCapabilitiesIsTheLegacyProfile() {
        XCTAssertEqual(CompanyTeamSpaceProfile.resolve(nil), .legacy)
    }

    func testTeamAdminNeedsTheWireAndTheActivation() throws {
        XCTAssertTrue(CompanyTeamSpaceProfile.resolve(try capabilities()).admin)
        XCTAssertFalse(CompanyTeamSpaceProfile.resolve(try capabilities(teamAdmin: "inactive")).admin)
        let c2 = CompanyTeamSpaceProfile.resolve(try capabilities(channelAdmission: "active",
                                                                  wires: ["1", "1.1", "1.2", "1.3", "1.4"]))
        XCTAssertTrue(c2.channels)
        XCTAssertTrue(c2.rooms)
        // Admission active but 1.4 not named: no channels profile.
        XCTAssertFalse(CompanyTeamSpaceProfile.resolve(try capabilities(channelAdmission: "active")).channels)
    }

    func testAMemberIsNeverOfferedTheSheet() {
        XCTAssertEqual(CompanyInviteAbilities.resolve(profile: .legacy, viewerIsAdmin: false, readiness: nil), .none)
        XCTAssertEqual(CompanyInviteAbilities.resolve(profile: .legacy, viewerIsAdmin: nil, readiness: nil), .none)
    }

    func testALegacyAdminInvitesByHandleWithoutLinks() {
        let abilities = CompanyInviteAbilities.resolve(profile: .legacy, viewerIsAdmin: true, readiness: nil)
        XCTAssertEqual(abilities, CompanyInviteAbilities(invite: true, method: .legacy, inviteLink: false,
                                                         revokeInviteLink: false))
    }

    func testATeamAdminAdminUsesC1InvitationsAndLinksWhenReady() throws {
        let profile = CompanyTeamSpaceProfile(admin: true)
        let ready = try NativeAPI.decode(CompanyInviteReadiness.self,
                                         from: fixture("invites-v1.capabilities.response.json"))
        XCTAssertEqual(ready.inviteLink, .ready)
        XCTAssertEqual(CompanyInviteAbilities.resolve(profile: profile, viewerIsAdmin: true, readiness: ready),
                       CompanyInviteAbilities(invite: true, method: .admin, inviteLink: true, revokeInviteLink: true))
        // No readiness answer (an older install): today's method, links for admins.
        XCTAssertTrue(CompanyInviteAbilities.resolve(profile: profile, viewerIsAdmin: true, readiness: nil).inviteLink)
    }

    func testALinkThatIsNotConfiguredIsNotOffered() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("invites-v1.capabilities.response.json")) as? [String: Any])
        json["inviteLink"] = "not_configured"
        let readiness = try NativeAPI.decode(CompanyInviteReadiness.self,
                                             from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(CompanyInviteAbilities.resolve(profile: CompanyTeamSpaceProfile(admin: true),
                                                      viewerIsAdmin: true, readiness: readiness).inviteLink)
        json["extra"] = true
        XCTAssertThrowsError(try NativeAPI.decode(CompanyInviteReadiness.self,
                                                  from: JSONSerialization.data(withJSONObject: json)))
    }

    // MARK: The typed person

    func testOnlyAnExactHandleIsAHandle() {
        XCTAssertEqual(CompanyInviteQuery.handle("@Lan_Nguyen"), "lan_nguyen")
        XCTAssertEqual(CompanyInviteQuery.handle("  minh "), "minh")
        XCTAssertNil(CompanyInviteQuery.handle("Lan Nguyễn"))
        XCTAssertNil(CompanyInviteQuery.handle("@ab"))
        XCTAssertNil(CompanyInviteQuery.handle("1abc"))
        XCTAssertNil(CompanyInviteQuery.handle("@@abc"))
        XCTAssertTrue(CompanyInviteQuery.isEmail("lan" + "@" + "example.com"))
        XCTAssertFalse(CompanyInviteQuery.isEmail("@lan"))
    }

    func testStandingComesFromTheRoster() throws {
        let snapshot = try CompanyWorkspaceWire.decodeSnapshotV11(Data(Self.snapshot.utf8))
        XCTAssertEqual(CompanyInviteStanding.resolve(handle: "minh", members: snapshot.members), .member)
        XCTAssertEqual(CompanyInviteStanding.resolve(handle: "lan", members: snapshot.members), .invited)
        XCTAssertEqual(CompanyInviteStanding.resolve(handle: "hoa", members: snapshot.members), .none)
        XCTAssertEqual(CompanyInviteStanding.resolve(handle: nil, members: snapshot.members), .none)
    }

    func testInviteBodiesNameTheHandleAndMemberRoleOnly() throws {
        let request = try NativeID("11111111-1111-4111-8111-111111111111")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            CompanyLegacyInviteRequest(requestId: request, memberHandle: "lan"))) as? [String: String]
        XCTAssertEqual(body, ["requestId": request.rawValue, "memberHandle": "lan", "role": "member"])
    }

    // MARK: Invite links

    func testTheFirstCreateCarriesTheLinkAndAReplayDoesNot() throws {
        guard case let .created(secret) = try CompanyInviteWire.decodeLinkCreated(fixture("invite-link.create.response.json"))
        else { return XCTFail("expected a created link") }
        XCTAssertEqual(secret.companyId.rawValue, company)
        XCTAssertEqual(secret.summary.maxUses, 5)
        XCTAssertTrue(secret.url.hasPrefix("https://"))
        // The secret never describes its text.
        XCTAssertFalse(String(describing: secret).contains("PUBLIC_FIXTURE"))
        XCTAssertFalse(String(reflecting: secret).contains("/j/"))

        guard case let .replayed(summary) = try CompanyInviteWire.decodeLinkCreated(
            fixture("invite-link.create-replay.response.json")) else { return XCTFail("expected a replay") }
        XCTAssertEqual(summary.uses, 2)
    }

    func testAListNeverCarriesALinkOrToken() throws {
        XCTAssertEqual(try CompanyInviteWire.decodeLinkList(fixture("invite-link.list.response.json")).isEmpty, false)
        XCTAssertThrowsError(try CompanyInviteWire.decodeLinkList(fixture("invite-link.list-url.response.json")))
        // The pack's list-with-a-token case (`invite-link.list-token`), built here: the repo ignores
        // `*token*.json` files.
        var withToken = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("invite-link.list.response.json")) as? [String: Any])
        var links = try XCTUnwrap(withToken["links"] as? [[String: Any]])
        links[0]["token"] = "PUBLIC_FIXTURE_ONLY_61818fe4de417671d243876c2279bbbe"
        withToken["links"] = links
        XCTAssertThrowsError(try CompanyInviteWire.decodeLinkList(JSONSerialization.data(withJSONObject: withToken)))
    }

    func testRevokeNamesTheLink() throws {
        let link = try NativeID("00000000-0000-4000-8000-507f79cf6e24")
        XCTAssertNoThrow(try CompanyInviteWire.decodeRevoked(fixture("invite-link.revoke.response.json"), linkID: link))
        let other = try NativeID("00000000-0000-4000-8000-7d72ef2bd9bc")
        XCTAssertThrowsError(try CompanyInviteWire.decodeRevoked(fixture("invite-link.revoke.response.json"), linkID: other))
    }

    func testDaysLeftRoundsUp() {
        XCTAssertEqual(CompanyInviteDays.left(expiresAt: 1_000 + 86_400 * 7, now: 1_000), 7)
        XCTAssertEqual(CompanyInviteDays.left(expiresAt: 1_000 + 3_600, now: 1_000), 1)
        XCTAssertEqual(CompanyInviteDays.left(expiresAt: 1_000, now: 2_000), 0)
    }

    // MARK: Join with a link

    func testAPastedLinkKeepsOnlyItsToken() throws {
        let token = "PUBLIC_FIXTURE_ONLY_61818fe4de417671d243876c2279bbbe"
        XCTAssertEqual(CompanyInviteLinkToken.parse(paste: "https://atum.app/j/" + token)?.rawValue, token)
        XCTAssertEqual(CompanyInviteLinkToken.parse(paste: " https://account.atumplatform.com/j#\(token) \n")?.rawValue,
                       token)
        XCTAssertNil(CompanyInviteLinkToken.parse(paste: "http://atum.app/j/" + token))
        XCTAssertNil(CompanyInviteLinkToken.parse(paste: "https://atum.app/j/" + token + "?x=1"))
        XCTAssertNil(CompanyInviteLinkToken.parse(paste: "https://user" + "@" + "atum.app/j/" + token))
        XCTAssertNil(CompanyInviteLinkToken.parse(paste: "https://atum.app:8443/j/" + token))
        XCTAssertNil(CompanyInviteLinkToken.parse(paste: "https://atum.app/x/" + token))
        XCTAssertNil(CompanyInviteLinkToken.parse(paste: "https://atum.app/j/short"))
        XCTAssertNil(CompanyInviteLinkToken.parse(paste: token))
        XCTAssertFalse(String(describing: try XCTUnwrap(CompanyInviteLinkToken(token: token))).contains(token))
    }

    func testTheTokenIsSentOnlyInTheRequestBody() throws {
        let token = try XCTUnwrap(CompanyInviteLinkToken(token: String(repeating: "a", count: 43)))
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            CompanyInviteLinkPreviewRequest(token: token))) as? [String: String]
        XCTAssertEqual(body, ["token": token.rawValue])
    }

    func testPreviewStates() throws {
        let preview = try NativeAPI.decode(CompanyInviteLinkPreview.self, from: fixture("invite-link.preview.response.json"))
        XCTAssertEqual(preview.companyName, "Công ty Atum")
        XCTAssertEqual(preview.inviterLabel, "Minh")
        XCTAssertEqual(CompanyInviteJoin.previewed(preview, now: preview.expiresAt - 10), .preview(preview))
        XCTAssertEqual(CompanyInviteJoin.previewed(preview, now: preview.expiresAt),
                       .failure(.expired, preview: preview))
        let gone = try NativeAPI.decode(CompanyInviteLinkPreview.self,
                                        from: fixture("invite-link.preview-inviter-gone.response.json"))
        XCTAssertNil(gone.inviterLabel)
        XCTAssertThrowsError(try NativeAPI.decode(CompanyInviteLinkPreview.self,
                                                  from: fixture("invite-link.preview-overused.response.json")))
        XCTAssertThrowsError(try NativeAPI.decode(CompanyInviteLinkPreview.self,
                                                  from: fixture("invite-link.preview-principal.response.json")))
    }

    func testAnUnknownLinkIsNotValidAndAnOutageIsUnchecked() {
        XCTAssertEqual(CompanyInviteJoin.previewFailed(CompanyAPIError.refused(.missing, reason: nil, retryAfter: nil)),
                       .failure(.invalid, preview: nil))
        XCTAssertEqual(CompanyInviteJoin.previewFailed(CompanyAPIError.refused(.missing, reason: "invite_link_unavailable",
                                                                              retryAfter: nil)),
                       .failure(.invalid, preview: nil))
        XCTAssertEqual(CompanyInviteJoin.previewFailed(CompanyAPIError.transport), .failure(.unavailable, preview: nil))
    }

    func testRedeemOutcomes() throws {
        let preview = try NativeAPI.decode(CompanyInviteLinkPreview.self, from: fixture("invite-link.preview.response.json"))
        let joined = try NativeAPI.decode(CompanyInviteLinkRedeemed.self, from: fixture("invite-link.redeem.response.json"))
        XCTAssertEqual(CompanyInviteJoin.redeemed(joined, preview: preview), .complete(preview, .joined, companyID: company))
        let member = try NativeAPI.decode(CompanyInviteLinkRedeemed.self,
                                          from: fixture("invite-link.redeem-member.response.json"))
        XCTAssertEqual(CompanyInviteJoin.redeemed(member, preview: preview),
                       .complete(preview, .alreadyMember, companyID: company))
        let replay = try NativeAPI.decode(CompanyInviteLinkRedeemed.self,
                                          from: fixture("invite-link.redeem-replay.response.json"))
        XCTAssertEqual(CompanyInviteJoin.redeemed(replay, preview: preview),
                       .complete(preview, .replayed, companyID: company))
        XCTAssertThrowsError(try NativeAPI.decode(CompanyInviteLinkRedeemed.self,
                                                  from: fixture("invite-link.redeem-overused.response.json")))
        let now = preview.expiresAt - 100
        XCTAssertEqual(CompanyInviteJoin.redeemFailed(CompanyAPIError.refused(.missing, reason: nil, retryAfter: nil),
                                                      preview: preview, now: now),
                       .failure(.revoked, preview: preview))
        XCTAssertEqual(CompanyInviteJoin.redeemFailed(CompanyAPIError.transport, preview: preview, now: now),
                       .failure(.unavailable, preview: preview))
        XCTAssertEqual(CompanyInviteJoin.redeemFailed(CompanyAPIError.transport, preview: preview,
                                                      now: preview.expiresAt),
                       .failure(.expired, preview: preview))
    }

    // MARK: Channels (TS-13)

    func testChannelNameRule() {
        XCTAssertEqual(CompanyChannelName.normalized("  launch plans "), "launch plans")
        XCTAssertNil(CompanyChannelName.normalized("   "))
        XCTAssertNil(CompanyChannelName.normalized(String(repeating: "a", count: 81)))
        XCTAssertNotNil(CompanyChannelName.normalized(String(repeating: "a", count: 80)))
        XCTAssertNil(CompanyChannelName.normalized("a\u{0007}b"))
        XCTAssertEqual(CompanyChannelName.problem(""), .required)
        XCTAssertEqual(CompanyChannelName.problem(String(repeating: "b", count: 81)), .tooLong)
        XCTAssertNil(CompanyChannelName.problem("ok"))
    }

    func testOnlyAdminsCreateAndC2WaitsForTheRoomController() {
        XCTAssertTrue(CompanyChannelCreation.allowed(profile: .legacy, viewerIsAdmin: true))
        XCTAssertFalse(CompanyChannelCreation.allowed(profile: .legacy, viewerIsAdmin: false))
        XCTAssertFalse(CompanyChannelCreation.allowed(profile: .legacy, viewerIsAdmin: nil))
        XCTAssertFalse(CompanyChannelCreation.allowed(profile: CompanyTeamSpaceProfile(channels: true, rooms: false),
                                                      viewerIsAdmin: true))
        XCTAssertTrue(CompanyChannelCreation.allowed(profile: CompanyTeamSpaceProfile(channels: true, rooms: true),
                                                     viewerIsAdmin: true))
    }

    func testSectionsSplitFavoritesChannelsAndArchived() {
        struct Row: Equatable { let name: String; let favourite: Bool; let archived: Bool }
        let rows = [Row(name: "general", favourite: false, archived: false),
                    Row(name: "launch", favourite: true, archived: false),
                    Row(name: "old", favourite: true, archived: true),
                    Row(name: "design", favourite: false, archived: false)]
        let plan = CompanyChannelSectionPlan.split(rows, isFavourite: \.favourite, isArchived: \.archived,
                                                   matches: { _ in true })
        XCTAssertEqual(plan.favorites.map(\.name), ["launch"])
        XCTAssertEqual(plan.channels.map(\.name), ["general", "design"])
        // An archived favourite stays in Archived.
        XCTAssertEqual(plan.archived.map(\.name), ["old"])
        let searched = CompanyChannelSectionPlan.split(rows, isFavourite: \.favourite, isArchived: \.archived,
                                                       matches: { $0.name.contains("l") })
        XCTAssertEqual(searched.favorites.map(\.name), ["launch"])
        XCTAssertEqual(searched.channels.map(\.name), ["general"])
        XCTAssertEqual(searched.archived.map(\.name), ["old"])
    }

    func testBeforeChannelsModeTheListStaysFlatLikeDesktop() {
        struct Row: Equatable { let name: String; let favourite: Bool; let archived: Bool }
        let rows = [Row(name: "general", favourite: false, archived: false),
                    Row(name: "launch", favourite: true, archived: false),
                    Row(name: "old", favourite: true, archived: true)]
        let flat = CompanyChannelSectionPlan.split(rows, isFavourite: \.favourite, isArchived: \.archived,
                                                   matches: { _ in true }, sectioned: false)
        XCTAssertEqual(flat.favorites, [])
        XCTAssertEqual(flat.archived, [])
        // Desktop order, archived inline.
        XCTAssertEqual(flat.channels.map(\.name), ["general", "launch", "old"])
        let searched = CompanyChannelSectionPlan.split(rows, isFavourite: \.favourite, isArchived: \.archived,
                                                       matches: { $0.name.contains("o") }, sectioned: false)
        XCTAssertEqual(searched.channels.map(\.name), ["old"])
    }

    // MARK: Fixture

    private static let snapshot = """
    {"schemaVersion":2,
     "company":{"id":"00000000-0000-4000-8000-68ce1b921bf1","displayName":"Atum","role":"admin","authorityGeneration":3},
     "members":[
      {"memberRef":"JDle0Nv3KQ9BfNKq-IM-sAoOQ1_ueYtjQz8llt4Y1Dc","role":"admin","state":"active","self":true,
       "handle":"minh","displayName":"Minh"},
      {"memberRef":"KDle0Nv3KQ9BfNKq-IM-sAoOQ1_ueYtjQz8llt4Y1Dc","role":"member","state":"invited","self":false,
       "handle":"lan","displayName":"Lan"}],
     "projects":[],"defaultChannelId":null}
    """
}
