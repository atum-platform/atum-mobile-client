import Foundation
import XCTest
@testable import AtumNativeAPI

final class AppOnboardingTests: XCTestCase {
    private let initiation = "00000000-0000-4000-8000-3cdc9c4bc004"
    private let version = "00000000-0000-4000-8000-088a99dcb870"

    func testDisclosureAndRoutePolicyIsTheFrozenNarrowSurface() {
        XCTAssertTrue(AppOnboardingPolicy.supports(disclosureVersion: 3, for: "moon"))
        XCTAssertTrue(AppOnboardingPolicy.supports(disclosureVersion: 2, for: "andy"))
        XCTAssertFalse(AppOnboardingPolicy.supports(disclosureVersion: 2, for: "moon"))
        XCTAssertFalse(AppOnboardingPolicy.supports(disclosureVersion: 1, for: "andy"))
        XCTAssertTrue(AppOnboardingPolicy.allowsLaunch(slug: "moon", routeID: "readings"))
        XCTAssertTrue(AppOnboardingPolicy.allowsLaunch(slug: "moon", routeID: "chat"))
        XCTAssertTrue(AppOnboardingPolicy.allowsLaunch(slug: "andy", routeID: "chat"))
        XCTAssertFalse(AppOnboardingPolicy.allowsLaunch(slug: "moon", routeID: "top-up"))
        XCTAssertFalse(AppOnboardingPolicy.allowsLaunch(slug: "moon", routeID: "purchase"))
        XCTAssertFalse(AppOnboardingPolicy.allowsLaunch(slug: "moon", routeID: "Pricing"))
        // Every other declared page opens, as on desktop; the server checks it is declared.
        XCTAssertTrue(AppOnboardingPolicy.allowsLaunch(slug: "moon", routeID: "history"))
        XCTAssertTrue(AppOnboardingPolicy.allowsLaunch(slug: "andy", routeID: "settings"))
        XCTAssertFalse(AppOnboardingPolicy.allowsLaunch(slug: "andy", routeID: ""))
        XCTAssertTrue(AppOnboardingPolicy.allowsComposerRoute(slug: "moon", routeID: "readings"))
        XCTAssertFalse(AppOnboardingPolicy.allowsComposerRoute(slug: "andy", routeID: "chat"))
    }

    func testAssociatedDomainReturnIsExactAndBoundToNonceAndInitiation() throws {
        let nonce = try AppLinkNonce(bytes: Data(repeating: 7, count: 32))
        let expected = try NativeID(initiation)
        let code = String(repeating: "B", count: 43)
        let canonical = URL(string: nonce.redirectURL.absoluteString
                            + "?code=\(code)&initiation_id=\(initiation)")!
        let proof = try AppLinkReturnProof.parse(canonical, nonce: nonce, initiationID: expected)
        XCTAssertEqual(proof.initiationID, expected)
        XCTAssertFalse(String(describing: proof).contains(code))

        for value in [
            nonce.redirectURL.absoluteString + "?initiation_id=\(initiation)&code=\(code)",
            nonce.redirectURL.absoluteString + "?code=\(code)&initiation_id=\(initiation)&x=1",
            nonce.redirectURL.absoluteString + "?code=\(code)&initiation_id=\(initiation)#x",
            nonce.redirectURL.absoluteString + "/?code=\(code)&initiation_id=\(initiation)",
        ] {
            XCTAssertThrowsError(try AppLinkReturnProof.parse(URL(string: value)!, nonce: nonce,
                                                              initiationID: expected), value)
        }
        let other = try NativeID("00000000-0000-4000-8000-19c9bb8e0635")
        XCTAssertThrowsError(try AppLinkReturnProof.parse(canonical, nonce: nonce,
                                                          initiationID: other))
    }

    func testGuardedConfirmCarriesOnlyTwoVisibleConsentSources() throws {
        let nonce = try AppLinkNonce(bytes: Data(repeating: 9, count: 32))
        let code = String(repeating: "C", count: 43)
        let id = try NativeID(initiation)
        let callback = URL(string: nonce.redirectURL.absoluteString
                           + "?code=\(code)&initiation_id=\(initiation)")!
        let proof = try AppLinkReturnProof.parse(callback, nonce: nonce, initiationID: id)
        let data = try JSONEncoder().encode(try AppLinkConfirmRequest(proof: proof,
                                                                      disclosureVersion: 3))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["initiation_id", "return_code", "confirmation", "consent_provenance"])
        XCTAssertNil(object["accepted_via"])
        let provenance = try XCTUnwrap(object["consent_provenance"] as? [String: Any])
        XCTAssertEqual(provenance["chat"] as? [String: AnyHashable], [
            "state": "accepted", "disclosure_version": 3,
        ])
        XCTAssertEqual(provenance["exact_pair"] as? [String: AnyHashable], [
            "state": "accepted", "source": "provider_page",
        ])
    }

    func testStatusRequiresCanonicalRoomFieldAndCurrentAcceptedConsent() throws {
        let data = Data("""
        {"profile":"atum.app-bot-status/1","bot":null,
         "consent":{"state":"accepted","disclosure_version":3,"locale":"vi","accepted_at":"2026-10-20T10:00:00.000Z"},
         "link":{"state":"linked","ready":true,"available":true},
         "room_id":"!moon:example.invalid"}
        """.utf8)
        let status = try NativeAPI.decode(AppBotSetupStatus.self, from: data)
        XCTAssertEqual(status.roomID?.rawValue, "!moon:example.invalid")
        XCTAssertEqual(status.consent.locale, .vietnamese)

        let availableBeforeLink = Data("""
        {"profile":"atum.app-bot-status/1","bot":null,
         "consent":{"state":"required","disclosure_version":3,"locale":null,"accepted_at":null},
         "link":{"state":"never_linked","ready":false,"available":true},"room_id":null}
        """.utf8)
        XCTAssertNil(try NativeAPI.decode(AppBotSetupStatus.self,
                                          from: availableBeforeLink).roomID)

        let missingRoom = Data("""
        {"profile":"atum.app-bot-status/1","bot":null,
         "consent":{"state":"required","disclosure_version":3,"locale":null,"accepted_at":null},
         "link":{"state":"never_linked","ready":false,"available":false}}
        """.utf8)
        XCTAssertThrowsError(try NativeAPI.decode(AppBotSetupStatus.self, from: missingRoom))
    }

    func testMoonIntakeSubmitsOnlyServerDeclaredMissingFields() throws {
        let data = Data("""
        {"complete":false,"missing":["birth_time","birth_city"],"fields":[
          {"name":"preferred_name","type":"text"},
          {"name":"dob","type":"date"},
          {"name":"birth_time","type":"time"},
          {"name":"birth_city","type":"text"},
          {"name":"gender","type":"select","options":[{"value":"female","label":"Female"}]}
        ]}
        """.utf8)
        let status = try NativeAPI.decode(AppIntakeStatus.self, from: data)
        XCTAssertEqual(status.missingFields.map(\.name), ["birth_time", "birth_city"])
        let submission = try AppIntakeSubmission(
            values: ["birth_time": " 08:30 ", "birth_city": " Hà Nội "],
            fields: status.missingFields
        )
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(submission)) as? [String: String]
        XCTAssertEqual(encoded, ["birth_time": "08:30", "birth_city": "Hà Nội"])
        XCTAssertThrowsError(try AppIntakeSubmission(
            values: ["birth_time": "", "birth_city": "Hà Nội"], fields: status.missingFields
        ))
    }

    func testWorkspaceComposerPlacementAndLaunchResponseStayTyped() throws {
        let workspaceData = Data("""
        {"profile":"atum.app-workspace/1",
         "descriptor":{"app":"moon","app_version_id":"\(version)"},
         "manifest":{"profile":"atum.remote-app-manifest/1",
          "app":{"slug":"moon","app_version_id":"\(version)"},
          "launch":{"profile":"atum.app-launch/1","path":"/atum/launch"},
          "routes":[
            {"id":"readings","label":{"vi":"Luận giải","en":"Readings"},"icon":"book","path":"/readings","placements":["composer"],"session":"required"},
            {"id":"chat","label":{"vi":"Chat","en":"Chat"},"icon":"message","path":"/chat","placements":["menu"],"session":"required"}
          ]},
         "web_origin":"https://moon.atumplatform.com","network_origins":[]}
        """.utf8)
        let workspace = try NativeAPI.decode(AppWorkspaceSnapshot.self, from: workspaceData)
        XCTAssertEqual(workspace.slug, "moon")
        XCTAssertEqual(workspace.routes.filter { $0.placements.contains(.composer) }.map(\.id), ["readings"])

        let launch = Data("""
        {"launch_url":"https://moon.atumplatform.com/atum/launch?code=\(String(repeating: "D", count: 43))",
         "expires_at":"2026-10-20T10:01:00.000Z"}
        """.utf8)
        XCTAssertEqual(try NativeAPI.decode(AppLaunchResponse.self, from: launch).launchURL.host,
                       "moon.atumplatform.com")
        let bad = Data("""
        {"launch_url":"https://moon.atumplatform.com/top-up?code=\(String(repeating: "D", count: 43))&x=1",
         "expires_at":"2026-10-20T10:01:00.000Z"}
        """.utf8)
        XCTAssertThrowsError(try NativeAPI.decode(AppLaunchResponse.self, from: bad))
    }
}
