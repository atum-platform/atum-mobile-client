import Foundation
import XCTest
import AtumDesign
@testable import AtumNativeAPI

final class MobileFounderTests: XCTestCase {
    private let founder = "@synthetic-user-0017:example.invalid"
    private let other = "@synthetic-user-0018:example.invalid"

    private func decode(_ object: [String: Any]) throws -> OfficialAccountsResponse {
        try NativeAPI.decode(OfficialAccountsResponse.self,
                             from: JSONSerialization.data(withJSONObject: object,
                                                          options: .sortedKeys))
    }

    private func answer(founder: Any? = nil, accounts: [[String: Any]]? = nil) -> [String: Any] {
        [
            "profile": OfficialAccountsResponse.profile,
            "founder": founder ?? ["user_id": self.founder],
            "accounts": accounts ?? [[
                "user_id": self.founder,
                "tier": "official",
                "role": "founder",
                "handle": "founder",
            ]],
        ]
    }

    func testClosedProfileReadsOnlyTheNamedFounderAndKnownFields() throws {
        let parsed = try decode(answer(
            founder: ["user_id": founder, "updates_room_id": "!updates:example.invalid"],
            accounts: [[
                "user_id": founder,
                "tier": "official",
                "role": "founder",
                "handle": "founder",
                "roster_default": false,
                "roster_order": 9,
                "roster_state": "coming_soon",
                "private_email": "founder@example.test",
                "principal": "00000000-0000-4000-8000-11e594f48195",
            ], [
                "user_id": other,
                "tier": "verified",
                "role": NSNull(),
                "handle": NSNull(),
            ]]
        ))

        XCTAssertEqual(parsed.founder?.userID, founder)
        XCTAssertEqual(parsed.accounts.count, 2)
        XCTAssertEqual(parsed.accounts[0].tier, .official)
        XCTAssertEqual(parsed.accounts[0].role, .founder)
        XCTAssertEqual(parsed.accounts[0].handle, "founder")
        XCTAssertEqual(parsed.accounts[0].rosterDefault, false)
        XCTAssertEqual(parsed.accounts[0].rosterOrder, 9)
        XCTAssertEqual(parsed.accounts[0].rosterState, .comingSoon)
        XCTAssertNil(parsed.accounts[1].role)
        XCTAssertNil(parsed.accounts[1].handle)
        XCTAssertEqual(parsed.founderRoster,
                       OfficialFounderRoster(defaultVisible: false, order: 9, state: .comingSoon))
        XCTAssertEqual(parsed.founderHandle, "founder")

        // An older producer omits every optional presentation field.
        let legacy = try decode(answer())
        XCTAssertEqual(legacy.founderRoster,
                       OfficialFounderRoster(defaultVisible: true, order: 0, state: .available))
        XCTAssertNil(legacy.accounts[0].rosterDefault)
        XCTAssertNil(legacy.accounts[0].rosterOrder)
        XCTAssertNil(legacy.accounts[0].rosterState)
    }

    func testClosedProfileRefusesBrokenPromisesAndMalformedRows() throws {
        XCTAssertThrowsError(try decode([
            "profile": "atum.official-accounts/2",
            "founder": NSNull(),
            "accounts": [],
        ]))
        XCTAssertThrowsError(try decode(answer(founder: NSNull(), accounts: [[
            "user_id": founder, "tier": "official", "role": "founder", "handle": "founder",
        ]])))
        XCTAssertThrowsError(try decode(answer(founder: ["user_id": other], accounts: [[
            "user_id": founder, "tier": "official", "role": "founder", "handle": "founder",
        ]])))
        XCTAssertThrowsError(try decode(answer(accounts: [[
            "user_id": founder, "tier": "verified", "role": "founder", "handle": "founder",
        ]])))
        XCTAssertThrowsError(try decode(answer(accounts: [[
            "user_id": founder, "tier": "official", "role": "support", "handle": "founder",
        ]])))
        XCTAssertThrowsError(try decode(answer(accounts: [[
            "user_id": founder, "tier": "official", "role": "founder", "handle": "No Spaces",
        ]])))
        XCTAssertThrowsError(try decode(answer(accounts: [
            ["user_id": founder, "tier": "official", "role": "founder"],
            ["user_id": founder, "tier": "verified", "role": NSNull()],
        ])))

        for roster in [
            ["roster_default": NSNull()],
            ["roster_default": "yes"],
            ["roster_order": -1],
            ["roster_order": 1.5],
            ["roster_order": 2_147_483_648],
            ["roster_order": "0"],
            ["roster_state": "hidden"],
            ["roster_state": NSNull()],
        ] as [[String: Any]] {
            var row = ["user_id": founder, "tier": "official", "role": "founder"] as [String: Any]
            roster.forEach { row[$0.key] = $0.value }
            XCTAssertThrowsError(try decode(answer(accounts: [row])), "\(roster)")
        }

        let many = (0..<64).map { index in
            ["user_id": "@user-\(String(format: "%032d", index)):atumplatform.com",
             "tier": "verified", "role": NSNull()] as [String: Any]
        }
        XCTAssertThrowsError(try decode(answer(accounts: [
            ["user_id": founder, "tier": "official", "role": "founder"],
        ] + many)))
    }

    func testFounderMarkerAndRoomMarkAreClosedV1Records() throws {
        let record = #"{"v":1,"founder":"\#(founder)","room":"!chat:example.invalid","at":1759000000000}"#
        XCTAssertEqual(MobileFounderPolicy.record(JSON: record),
                       .init(founder: founder, roomID: "!chat:example.invalid",
                             atMilliseconds: 1_759_000_000_000))
        XCTAssertEqual(MobileFounderPolicy.marker(accountDataJSON: record),
                       .present(founder: founder, roomID: "!chat:example.invalid"))
        XCTAssertEqual(MobileFounderPolicy.marker(accountDataJSON: nil), .absent)
        XCTAssertEqual(MobileFounderPolicy.marker(accountDataJSON: #"{"v":2,"someday":true}"#),
                       .present(founder: nil, roomID: nil))

        for invalid in [
            #"{"v":2,"founder":"\#(founder)","room":"!chat:test","at":1}"#,
            #"{"v":1,"founder":"founder","room":"!chat:test","at":1}"#,
            #"{"v":1,"founder":"\#(founder)","room":"chat","at":1}"#,
            #"{"v":1,"founder":"\#(founder)","room":"!chat:test","at":-1}"#,
            #"{"v":1,"founder":"\#(founder)","room":"!chat:test","at":1.5}"#,
            #"{"v":true,"founder":"\#(founder)","room":"!chat:test","at":1}"#,
            "[]",
            "",
        ] {
            XCTAssertNil(MobileFounderPolicy.record(JSON: invalid), invalid)
        }

        XCTAssertEqual(MobileFounderPolicy.roomMark(JSON: #"{"v":1,"founder":"\#(founder)"}"#),
                       founder)
        XCTAssertNil(MobileFounderPolicy.roomMark(JSON: #"{"v":2,"founder":"\#(founder)"}"#))
        XCTAssertNil(MobileFounderPolicy.roomMark(JSON: #"{"v":1,"founder":"founder"}"#))

        let encoded = try XCTUnwrap(MobileFounderPolicy.roomMarkJSON(founder: founder))
        XCTAssertEqual(MobileFounderPolicy.roomMark(JSON: encoded), founder)
        let account = try XCTUnwrap(MobileFounderPolicy.accountRecordJSON(
            founder: founder, roomID: "!chat:test", atMilliseconds: 7_321
        ))
        XCTAssertEqual(MobileFounderPolicy.record(JSON: account),
                       .init(founder: founder, roomID: "!chat:test", atMilliseconds: 7_321))
        XCTAssertNil(MobileFounderPolicy.accountRecordJSON(
            founder: "founder", roomID: "!chat:test", atMilliseconds: 1
        ))
    }

    func testFounderAutoActionWaitsForReadinessOffersADraftAndNeverCreates() {
        let founderID = founder
        func action(_ marker: MobileFounderPolicy.ChatMarker,
                    missingFounder: Bool = false,
                    roster: OfficialFounderRoster? = nil,
                    ready: Bool = true,
                    synced: Bool = true,
                    usability: MobileFounderPolicy.RoomUsability = .usable,
                    own: String = "@alice:test") -> MobileFounderPolicy.AutoAction {
            MobileFounderPolicy.autoAction(
                founder: missingFounder ? nil : founderID,
                roster: roster,
                marker: marker,
                ownUserID: own,
                sessionReady: ready,
                completedInitialSync: synced,
                existingRoomUsability: usability
            )
        }

        XCTAssertEqual(action(.absent, missingFounder: true), .unavailable)
        XCTAssertEqual(action(.absent, own: founderID), .founderMode)
        XCTAssertEqual(action(.absent, ready: false), .wait(.notReady))
        XCTAssertEqual(action(.absent, synced: false), .wait(.notSynced))
        XCTAssertEqual(action(.unknown), .wait(.unknownMarker))
        XCTAssertEqual(action(.absent), .draft)
        XCTAssertEqual(action(.absent, roster: OfficialFounderRoster(defaultVisible: false,
                                                                     order: 0, state: .available)),
                       .suppressed)
        XCTAssertEqual(action(.absent, roster: OfficialFounderRoster(defaultVisible: true,
                                                                     order: 0, state: .comingSoon)),
                       .suppressed)
        XCTAssertEqual(action(.present(founder: founderID, roomID: "!chat:test")),
                       .bindExisting(roomID: "!chat:test"))
        XCTAssertEqual(action(.present(founder: founderID, roomID: "!chat:test"), usability: .unusable),
                       .decline)
        XCTAssertEqual(action(.present(founder: founderID, roomID: "!chat:test"), usability: .unknown),
                       .wait(.unknownRoom), "an unreadable cache keeps the current binding")
        XCTAssertEqual(action(.present(founder: nil, roomID: nil)), .decline)
        XCTAssertEqual(action(.present(founder: "@user-other:test", roomID: "!old:test")),
                       .decline)
    }

    func testExplicitContactOnlyReplacesWhenNoUsableChatExists() {
        let roster = OfficialFounderRoster(defaultVisible: false, order: 0, state: .comingSoon)
        func action(_ marker: MobileFounderPolicy.ChatMarker,
                    missingFounder: Bool = false,
                    ready: Bool = true,
                    synced: Bool = true,
                    usability: MobileFounderPolicy.RoomUsability = .usable,
                    own: String = "@alice:test") -> MobileFounderPolicy.ExplicitAction {
            MobileFounderPolicy.explicitAction(
                founder: missingFounder ? nil : self.founder,
                marker: marker,
                ownUserID: own,
                sessionReady: ready,
                completedInitialSync: synced,
                existingRoomUsability: usability
            )
        }

        XCTAssertEqual(action(.absent, missingFounder: true), .unavailable)
        XCTAssertEqual(action(.absent, own: founder), .founderMode)
        XCTAssertEqual(action(.absent, ready: false), .wait(.notReady))
        XCTAssertEqual(action(.absent, synced: false), .wait(.notSynced))
        XCTAssertEqual(action(.unknown), .wait(.unknownMarker))
        XCTAssertEqual(action(.absent), .createReplacement)
        XCTAssertEqual(action(.present(founder: founder, roomID: "!chat:test")),
                       .bindExisting(roomID: "!chat:test"))
        XCTAssertEqual(action(.present(founder: founder, roomID: "!left:test"), usability: .unusable),
                       .createReplacement)
        XCTAssertEqual(action(.present(founder: founder, roomID: "!chat:test"), usability: .unknown),
                       .wait(.unknownRoom), "Contact us cannot replace an unreadable room")
        XCTAssertEqual(action(.present(founder: nil, roomID: nil)), .createReplacement)
        XCTAssertEqual(action(.present(founder: other, roomID: "!old:test")),
                       .createReplacement)
        // Roster presentation never grants or denies the person's own request.
        XCTAssertEqual(MobileFounderPolicy.autoAction(
            founder: founder, roster: roster,
            marker: .present(founder: founder, roomID: "!chat:test"),
            ownUserID: "@alice:test", sessionReady: true,
            completedInitialSync: true, existingRoomUsability: .usable
        ), .bindExisting(roomID: "!chat:test"))
    }

    func testAdoptionRequiresTheExactOwnMarkedTwoPersonRoomAndPicksOldest() {
        let own = "@alice:test"
        let validOld = MobileFounderPolicy.RoomCandidate(
            roomID: "!old:test", creatorUserID: own, markerSenderUserID: own,
            markerFounderUserID: founder, isJoined: true, memberCount: 2,
            memberUserIDs: [founder, own], createdAtMilliseconds: 10
        )
        let validNew = MobileFounderPolicy.RoomCandidate(
            roomID: "!new:test", creatorUserID: own, markerSenderUserID: own,
            markerFounderUserID: founder, isJoined: true, memberCount: 2,
            memberUserIDs: [own, founder], createdAtMilliseconds: 20
        )
        let foreignCreator = MobileFounderPolicy.RoomCandidate(
            roomID: "!foreign:test", creatorUserID: other, markerSenderUserID: own,
            markerFounderUserID: founder, isJoined: true, memberCount: 2,
            memberUserIDs: [own, founder], createdAtMilliseconds: 1
        )
        let foreignSender = MobileFounderPolicy.RoomCandidate(
            roomID: "!foreign-sender:test", creatorUserID: own, markerSenderUserID: other,
            markerFounderUserID: founder, isJoined: true, memberCount: 2,
            memberUserIDs: [own, founder], createdAtMilliseconds: 2
        )
        let otherFounder = MobileFounderPolicy.RoomCandidate(
            roomID: "!other-founder:test", creatorUserID: own, markerSenderUserID: own,
            markerFounderUserID: other, isJoined: true, memberCount: 2,
            memberUserIDs: [own, other], createdAtMilliseconds: 3
        )
        let crowded = MobileFounderPolicy.RoomCandidate(
            roomID: "!crowded:test", creatorUserID: own, markerSenderUserID: own,
            markerFounderUserID: founder, isJoined: true, memberCount: 3,
            memberUserIDs: [own, founder, other], createdAtMilliseconds: 4
        )
        let notJoined = MobileFounderPolicy.RoomCandidate(
            roomID: "!left:test", creatorUserID: own, markerSenderUserID: own,
            markerFounderUserID: founder, isJoined: false, memberCount: 2,
            memberUserIDs: [own, founder], createdAtMilliseconds: 5
        )

        XCTAssertEqual(MobileFounderPolicy.adoptableRoomID(
            [validNew, foreignCreator, validOld, foreignSender, otherFounder, crowded, notJoined],
            founder: founder, ownUserID: own
        ), "!old:test")
        XCTAssertNil(MobileFounderPolicy.adoptableRoomID(
            [foreignCreator, foreignSender, otherFounder, crowded, notJoined],
            founder: founder, ownUserID: own
        ))
    }

    func testRoomUsabilityMatchesDesktopAndKeepsCacheMissUnknown() {
        let own = "@alice:test"
        let extra = MobileFounderPolicy.RoomCandidate(
            roomID: "!group:test", creatorUserID: own, markerSenderUserID: own,
            markerFounderUserID: founder, isJoined: true, memberCount: 3,
            memberUserIDs: [own, founder, other], createdAtMilliseconds: 1
        )
        XCTAssertEqual(MobileFounderPolicy.roomUsability(extra, founder: founder), .usable,
                       "extra members do not change desktop's recorded-room usability")
        XCTAssertEqual(MobileFounderPolicy.roomUsability(.init(
            roomID: "!unknown:test", creatorUserID: nil, markerSenderUserID: nil,
            markerFounderUserID: nil, isJoined: true, memberCount: 0,
            memberUserIDs: [], createdAtMilliseconds: nil, membershipKnown: false
        ), founder: founder), .unknown)
        XCTAssertEqual(MobileFounderPolicy.roomUsability(.init(
            roomID: "!left:test", creatorUserID: nil, markerSenderUserID: nil,
            markerFounderUserID: nil, isJoined: false, memberCount: 2,
            memberUserIDs: [own, founder], createdAtMilliseconds: nil
        ), founder: founder), .unusable)
        XCTAssertEqual(MobileFounderPolicy.roomUsability(.init(
            roomID: "!missing-founder:test", creatorUserID: nil, markerSenderUserID: nil,
            markerFounderUserID: nil, isJoined: true, memberCount: 1,
            memberUserIDs: [own], createdAtMilliseconds: nil
        ), founder: founder), .unusable)
        XCTAssertEqual(MobileFounderPolicy.roomUsability(nil, founder: founder), .unknown)
    }

    func testRaceResolutionIdentifiesOnlyTheRoomThisCallCreatedAsTheLoser() {
        XCTAssertEqual(MobileFounderPolicy.raceWinner(
            createdRoomID: "!mine:test", founder: founder,
            marker: .present(founder: founder, roomID: "!other:test")
        ), "!other:test")
        XCTAssertEqual(MobileFounderPolicy.raceWinner(
            createdRoomID: "!mine:test", founder: founder,
            marker: .present(founder: founder, roomID: "!mine:test")
        ), "!mine:test")
        XCTAssertEqual(MobileFounderPolicy.raceWinner(
            createdRoomID: "!mine:test", founder: founder, marker: .absent
        ), "!mine:test")
        XCTAssertEqual(MobileFounderPolicy.raceWinner(
            createdRoomID: "!mine:test", founder: founder, marker: .unknown
        ), "!mine:test")
        XCTAssertEqual(MobileFounderPolicy.raceWinner(
            createdRoomID: "!mine:test", founder: founder,
            marker: .present(founder: nil, roomID: nil)
        ), "!mine:test")

        let lost = MobileFounderPolicy.raceResolution(
            createdRoomID: "!mine:test", founder: founder,
            marker: .present(founder: founder, roomID: "!other:test")
        )
        XCTAssertEqual(lost.winnerRoomID, "!other:test")
        XCTAssertEqual(lost.retainedLoserRoomID, "!mine:test",
                       "message-state proof decides whether this loser is left or hidden")

        let won = MobileFounderPolicy.raceResolution(
            createdRoomID: "!mine:test", founder: founder,
            marker: .present(founder: founder, roomID: "!mine:test")
        )
        XCTAssertEqual(won.winnerRoomID, "!mine:test")
        XCTAssertNil(won.retainedLoserRoomID)
        XCTAssertNil(MobileFounderPolicy.raceResolution(
            createdRoomID: "!mine:test", founder: founder, marker: .absent
        ).retainedLoserRoomID)
        XCTAssertNil(MobileFounderPolicy.raceResolution(
            createdRoomID: "!mine:test", founder: founder, marker: .unknown
        ).retainedLoserRoomID)
        XCTAssertNil(MobileFounderPolicy.raceResolution(
            createdRoomID: "!mine:test", founder: founder,
            marker: .present(founder: nil, roomID: nil)
        ).retainedLoserRoomID)
    }

    @MainActor
    func testPinnedDesktopFounderFixtureDrivesThePhoneCreationFlow() async throws {
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Vendor/AtumDesign/fixtures/playground.json"))
        ) as? [String: Any])
        let scenarios = try XCTUnwrap(raw["scenarios"] as? [String: Any])
        let roster = try XCTUnwrap(scenarios["founder-roster"] as? [String: Any])
        let chat = try XCTUnwrap(scenarios["founder-chat"] as? [String: Any])
        let fixtureFounder = try XCTUnwrap(roster["founder"] as? [String: Any])
        let founderUserID = try XCTUnwrap(fixtureFounder["userId"] as? String)
        let roomID = try XCTUnwrap(chat["roomId"] as? String)
        let port = FounderRoomPortFake(
            markers: [.absent, .present(founder: founderUserID, roomID: roomID)],
            createdRoomID: roomID
        )
        let result = await MobileFounderPolicy.establishRoom(
            founder: founderUserID, ownUserID: "@an:example.invalid", port: port
        )

        XCTAssertEqual(result, .ready(roomID: roomID))
        XCTAssertEqual(port.createdRooms, [roomID])
        XCTAssertEqual(port.writtenRooms, [roomID])
        XCTAssertEqual(port.rememberedRooms, [roomID])
        XCTAssertEqual(port.calls.prefix(5), [
            "fetch:-", "adopt", "create", "write:\(roomID)", "direct:\(roomID)",
        ])
    }

    @MainActor
    func testAuthoritativeReadPreventsDoubleCreateAndOnlyThePersonRequestReplacesALeftChat() async {
        let existing = "!existing:test"
        let ready = FounderRoomPortFake(
            markers: [.present(founder: founder, roomID: existing)],
            usability: [existing: .usable]
        )
        let readyResult = await MobileFounderPolicy.establishRoom(
            founder: founder, ownUserID: "@alice:test", port: ready
        )
        XCTAssertEqual(readyResult, .ready(roomID: existing))
        XCTAssertTrue(ready.createdRooms.isEmpty)
        XCTAssertEqual(ready.calls, ["fetch:-", "usable:\(existing)"])

        let left = FounderRoomPortFake(
            markers: [.present(founder: founder, roomID: existing)],
            usability: [existing: .unusable]
        )
        let leftResult = await MobileFounderPolicy.establishRoom(
            founder: founder, ownUserID: "@alice:test", port: left
        )
        XCTAssertEqual(leftResult, .ready(roomID: left.createdRoomID))
        XCTAssertEqual(left.createdRooms, [left.createdRoomID],
                       "the person's own request may replace a chat they left")

        let unreadable = FounderRoomPortFake(
            markers: [.present(founder: founder, roomID: existing)],
            usability: [existing: .unknown]
        )
        let unreadableResult = await MobileFounderPolicy.establishRoom(
            founder: founder, ownUserID: "@alice:test", port: unreadable
        )
        XCTAssertEqual(unreadableResult, .wait)
        XCTAssertTrue(unreadable.createdRooms.isEmpty,
                      "unknown usability preserves the existing binding")
    }

    @MainActor
    func testUnknownAuthoritativeMarkerNeverCreates() async {
        let port = FounderRoomPortFake(markers: [.unknown])
        let result = await MobileFounderPolicy.establishRoom(
            founder: founder, ownUserID: "@alice:test", port: port
        )
        XCTAssertEqual(result, .wait)
        XCTAssertTrue(port.createdRooms.isEmpty)
        XCTAssertEqual(port.calls, ["fetch:-"])
    }

    func testSettingsContactUsOpensTheDraftWhileOneIsOffered() {
        XCTAssertEqual(MobileFounderPolicy.contactAction(founderDraftAvailable: true), .openDraft)
        XCTAssertEqual(MobileFounderPolicy.contactAction(founderDraftAvailable: false), .contactFounder)
    }

    func testDraftSendGoesOnlyIntoTheRoomItsOwnSendOpened() {
        XCTAssertTrue(MobileFounderPolicy.draftSendAllowed(roomID: "!founder:test",
                                                           conversationRoomID: "!founder:test"))
        // A chat opened in the gap (another row, a notification) never gets the first message.
        XCTAssertFalse(MobileFounderPolicy.draftSendAllowed(roomID: "!founder:test",
                                                            conversationRoomID: "!other:test"))
        XCTAssertFalse(MobileFounderPolicy.draftSendAllowed(roomID: "!founder:test",
                                                            conversationRoomID: nil))
    }

    @MainActor
    func testDraftOpenSharesOneCreationBetweenRapidSendsAndRetriesAFailure() async {
        var creates = 0
        let shared = MobileFounderPolicy.DraftOpen {
            creates += 1
            try? await Task.sleep(for: .milliseconds(20))
            return "!founder:test"
        }
        async let first = shared.room()
        async let second = shared.room()
        let (left, right) = await (first, second)
        XCTAssertEqual(left, "!founder:test")
        XCTAssertEqual(right, "!founder:test")
        XCTAssertEqual(creates, 1, "a rapid double send makes exactly one room")
        let again = await shared.room()
        XCTAssertEqual(again, "!founder:test")
        XCTAssertEqual(creates, 1)

        var fails = true
        let retried = MobileFounderPolicy.DraftOpen {
            if fails {
                fails = false
                return nil
            }
            return "!second:test"
        }
        let firstTry = await retried.room()
        XCTAssertNil(firstTry)
        let secondTry = await retried.room()
        XCTAssertEqual(secondTry, "!second:test")
    }

    @MainActor
    func testWriteThenFetchChoosesWinnerAndCleansMessageFreeCreatedLoser() async {
        let mine = "!mine:test"
        let winner = "!winner:test"
        let port = FounderRoomPortFake(
            markers: [.absent, .present(founder: founder, roomID: winner)],
            createdRoomID: mine,
            ownMessageState: .absent,
            leaveSucceeds: true
        )
        let result = await MobileFounderPolicy.establishRoom(
            founder: founder, ownUserID: "@alice:test", port: port
        )
        XCTAssertEqual(result, .ready(roomID: winner))
        XCTAssertEqual(port.calls, [
            "fetch:-", "adopt", "create", "write:\(mine)", "direct:\(mine)",
            "fetch:\(mine)", "own:\(mine)", "leave:\(mine)",
        ])
        XCTAssertEqual(port.leftRooms, [mine])
        XCTAssertTrue(port.hiddenRooms.isEmpty)
    }

    @MainActor
    func testAdoptedRoomIsWrittenAndReconciledButNeverDestructivelyCleaned() async {
        let adopted = "!adopted:test"
        let winner = "!winner:test"
        let port = FounderRoomPortFake(
            markers: [.absent, .present(founder: founder, roomID: winner)],
            adoptedRoomID: adopted
        )
        let result = await MobileFounderPolicy.establishRoom(
            founder: founder, ownUserID: "@alice:test", port: port
        )
        XCTAssertEqual(result, .ready(roomID: winner))
        XCTAssertTrue(port.createdRooms.isEmpty)
        XCTAssertEqual(port.writtenRooms, [adopted])
        XCTAssertEqual(port.calls, [
            "fetch:-", "adopt", "write:\(adopted)", "direct:\(adopted)",
            "fetch:\(adopted)",
        ])
        XCTAssertTrue(port.leftRooms.isEmpty)
        XCTAssertTrue(port.hiddenRooms.isEmpty)
    }

    @MainActor
    func testRaceLoserWithMessageOrFailedCleanupIsHidden() async {
        let mine = "!mine:test"
        let winner = "!winner:test"
        for (message, leaveSucceeds, expectsLeave) in [
            (MobileFounderPolicy.OwnMessageState.present, true, false),
            (.unknown, true, false),
            (.absent, false, true),
        ] {
            let port = FounderRoomPortFake(
                markers: [.absent, .present(founder: founder, roomID: winner)],
                createdRoomID: mine,
                ownMessageState: message,
                leaveSucceeds: leaveSucceeds
            )
            let result = await MobileFounderPolicy.establishRoom(
                founder: founder, ownUserID: "@alice:test", port: port
            )
            XCTAssertEqual(result, .ready(roomID: winner))
            XCTAssertEqual(port.hiddenRooms, [mine])
            XCTAssertEqual(!port.leftRooms.isEmpty, expectsLeave)
        }
    }

    @MainActor
    func testMarkerWriteFailureRetainsOneUnrecordedRoomWithoutFetchOrSecondCreate() async {
        let mine = "!mine:test"
        let port = FounderRoomPortFake(markers: [.absent], createdRoomID: mine,
                                       writeFails: true)
        let result = await MobileFounderPolicy.establishRoom(
            founder: founder, ownUserID: "@alice:test", port: port
        )
        XCTAssertEqual(result, .unrecorded(roomID: mine))
        XCTAssertEqual(port.createdRooms, [mine])
        XCTAssertEqual(port.calls, ["fetch:-", "adopt", "create", "write:\(mine)"])
        XCTAssertTrue(port.rememberedRooms.isEmpty)
    }

    func testLookalikeNameOrAvatarAlwaysFallsBackToInitials() {
        let raven = "mxc://atum.test/founder-raven"
        XCTAssertNil(MobileFounderPolicy.presentedAvatarURL(
            roomAvatarURL: "mxc://atum.test/other", roomName: "Founder",
            founderName: "Founder", founderAvatarURL: raven, isFounder: false
        ))
        XCTAssertNil(MobileFounderPolicy.presentedAvatarURL(
            roomAvatarURL: raven, roomName: "Someone else",
            founderName: "Founder", founderAvatarURL: raven, isFounder: false
        ))
        XCTAssertEqual(MobileFounderPolicy.presentedAvatarURL(
            roomAvatarURL: "mxc://atum.test/ordinary", roomName: "Someone else",
            founderName: "Founder", founderAvatarURL: raven, isFounder: false
        ), "mxc://atum.test/ordinary")
        XCTAssertEqual(MobileFounderPolicy.presentedAvatarURL(
            roomAvatarURL: "mxc://atum.test/copied", roomName: "Founder",
            founderName: "Founder", founderAvatarURL: raven, isFounder: true
        ), raven)
    }

    func testFounderIntroCopyMatchesDesktopInEveryPinnedLocale() throws {
        let copy = try AtumCopy()
        let key = "src.matrix.founder.founder-copy.FOUNDER_COPY.intro"
        let expected = [
            "en": "Questions, ideas or problems? Message me here. I usually reply within a day.",
            "vi": "Có câu hỏi, ý tưởng hay gặp sự cố? Nhắn cho tôi ở đây. Tôi thường trả lời trong vòng một ngày.",
            "ja": "質問、アイデア、問題があれば、ここでメッセージしてください。通常1日以内に返信します。",
            "zh": "有问题、想法或遇到故障？在这里给我发消息。我通常会在一天内回复。",
            "zh-Hant": "有問題、想法或遇到故障？在這裡傳訊息給我。我通常會在一天內回覆。",
        ]

        XCTAssertEqual(copy.locales, Set(expected.keys))
        for (locale, value) in expected {
            XCTAssertEqual(try copy.text(key, locale: locale), value, locale)
            XCTAssertEqual(try copy.text(
                "src.matrix.founder.founder-copy.FOUNDER_COPY.name", locale: locale
            ), "Founder", locale)
        }
    }

    func testOfficialAccountsRetriesAreSingleFlightScopedAndBounded() {
        let first = OfficialAccountsRetryCadence.Scope(accountID: "@alice:test", generation: 1)
        let next = OfficialAccountsRetryCadence.Scope(accountID: "@alice:test", generation: 2)
        let start = Date(timeIntervalSince1970: 1_000)
        var cadence = OfficialAccountsRetryCadence()

        XCTAssertTrue(cadence.begin(scope: first, now: start))
        cadence.activate(next)
        XCTAssertTrue(cadence.begin(scope: next, now: start),
                      "begin → client replacement releases the old read slot")
        XCTAssertTrue(cadence.abandon(scope: next))
        XCTAssertFalse(cadence.isReading)
        XCTAssertEqual(cadence.failures, 0, "cancellation/discard is not a service failure")
        XCTAssertTrue(cadence.begin(scope: next, now: start))
        XCTAssertTrue(cadence.succeed(scope: next))
        cadence.activate(first)

        XCTAssertTrue(cadence.begin(scope: first, now: start))
        XCTAssertFalse(cadence.begin(scope: first, now: start), "one account has one in-flight read")
        XCTAssertTrue(cadence.fail(scope: first, now: start))
        XCTAssertEqual(cadence.nextAllowedAt,
                       start.addingTimeInterval(OfficialAccountsRetryCadence.firstFailureDelay))
        XCTAssertFalse(cadence.begin(scope: first, now: start.addingTimeInterval(299)))

        let firstRetry = start.addingTimeInterval(300)
        XCTAssertTrue(cadence.begin(scope: first, now: firstRetry))
        XCTAssertTrue(cadence.fail(scope: first, now: firstRetry, retryAfterSeconds: 1_800))
        XCTAssertEqual(cadence.nextAllowedAt, firstRetry.addingTimeInterval(1_800),
                       "Retry-After may lengthen but never shorten the bounded backoff")
        XCTAssertFalse(cadence.begin(scope: first, now: firstRetry.addingTimeInterval(1_799)))

        XCTAssertTrue(cadence.begin(scope: next, now: start),
                      "a new client generation owns a fresh in-memory cache and retry gate")
        XCTAssertFalse(cadence.succeed(scope: first), "a late old-session answer is discarded")
        XCTAssertTrue(cadence.succeed(scope: next))
        XCTAssertEqual(cadence.failures, 0)
        XCTAssertNil(cadence.nextAllowedAt)
        XCTAssertTrue(cadence.begin(scope: next, now: start),
                      "a good answer remains refreshable on the next explicit trigger")
    }
}

@MainActor
private final class FounderRoomPortFake: MobileFounderPolicy.FounderRoomPort {
    private enum Failure: Error { case refused }

    var markers: [MobileFounderPolicy.ChatMarker]
    var usability: [String: MobileFounderPolicy.RoomUsability]
    var adoptedRoomID: String?
    var createdRoomID: String
    var createFails: Bool
    var writeFails: Bool
    var ownMessageState: MobileFounderPolicy.OwnMessageState
    var leaveSucceeds: Bool

    var calls = [String]()
    var createdRooms = [String]()
    var writtenRooms = [String]()
    var rememberedRooms = [String]()
    var leftRooms = [String]()
    var hiddenRooms = [String]()

    init(markers: [MobileFounderPolicy.ChatMarker],
         usability: [String: MobileFounderPolicy.RoomUsability] = [:],
         adoptedRoomID: String? = nil,
         createdRoomID: String = "!created:test",
         createFails: Bool = false,
         writeFails: Bool = false,
         ownMessageState: MobileFounderPolicy.OwnMessageState = .absent,
         leaveSucceeds: Bool = true) {
        self.markers = markers
        self.usability = usability
        self.adoptedRoomID = adoptedRoomID
        self.createdRoomID = createdRoomID
        self.createFails = createFails
        self.writeFails = writeFails
        self.ownMessageState = ownMessageState
        self.leaveSucceeds = leaveSucceeds
    }

    func serverMarker(anchorRoomID: String?) async -> MobileFounderPolicy.ChatMarker {
        calls.append("fetch:" + (anchorRoomID ?? "-"))
        return markers.isEmpty ? .unknown : markers.removeFirst()
    }

    func roomUsability(roomID: String, founder: String) async
        -> MobileFounderPolicy.RoomUsability {
        calls.append("usable:" + roomID)
        return usability[roomID] ?? .unknown
    }

    func adoptableRoomID(founder: String, ownUserID: String) async -> String? {
        calls.append("adopt")
        return adoptedRoomID
    }

    func createRoom(founder: String) async throws -> String {
        calls.append("create")
        if createFails { throw Failure.refused }
        createdRooms.append(createdRoomID)
        return createdRoomID
    }

    func writeMarker(founder: String, roomID: String) async throws {
        calls.append("write:" + roomID)
        if writeFails { throw Failure.refused }
        writtenRooms.append(roomID)
    }

    func rememberDirect(founder: String, roomID: String) async {
        calls.append("direct:" + roomID)
        rememberedRooms.append(roomID)
    }

    func ownMessageState(roomID: String, ownUserID: String) async
        -> MobileFounderPolicy.OwnMessageState {
        calls.append("own:" + roomID)
        return ownMessageState
    }

    func leaveAndForget(roomID: String) async -> Bool {
        calls.append("leave:" + roomID)
        leftRooms.append(roomID)
        return leaveSucceeds
    }

    func hide(roomID: String) {
        calls.append("hide:" + roomID)
        hiddenRooms.append(roomID)
    }
}
