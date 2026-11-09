import XCTest
@testable import AtumNativeAPI

/// 0.20 shave-down behavior contracts for the phone: one conversation per
/// agent (its other rooms are not listed anywhere), sender labels that never show
/// a raw Matrix ID, invites accepted only from known agents and bots, and a
/// generic, content-free pusher whose app ID follows the build.
final class PlainRoomsAndPushTests: XCTestCase {
    // MARK: One conversation per agent

    func testRoomWithoutEncryptionIsTheAgentsChatEvenWhenOlder() throws {
        let choice = try XCTUnwrap(MobileAgentRoomPolicy.choose([
            MobileAgentRoomCandidate(roomID: "!old-encrypted", encrypted: true, latestTimestamp: 9_000),
            MobileAgentRoomCandidate(roomID: "!plain", encrypted: false, latestTimestamp: 100),
            MobileAgentRoomCandidate(roomID: "!older-encrypted", encrypted: true, latestTimestamp: 50)
        ]))
        XCTAssertEqual(choice.chatRoomID, "!plain")
        XCTAssertEqual(choice.reason, .plain)
        XCTAssertEqual(choice.hiddenRoomIDs, ["!old-encrypted", "!older-encrypted"])
    }

    func testMultiplePlainRoomsAreRefusedInsteadOfGuessingFromActivity() {
        // A duplicate plain room can be a retired conversation. Picking the
        // newest one makes a send keep the wrong room newest forever, so this
        // invariant failure has no chat until the duplicate is repaired.
        let rooms = [
            MobileAgentRoomCandidate(roomID: "!a", encrypted: true, latestTimestamp: 10),
            MobileAgentRoomCandidate(roomID: "!b", encrypted: nil, latestTimestamp: 30),
            MobileAgentRoomCandidate(roomID: "!c", encrypted: false, latestTimestamp: 20),
            MobileAgentRoomCandidate(roomID: "!d", encrypted: false, latestTimestamp: 5)
        ]
        for permutation in [rooms, rooms.reversed(), [rooms[2], rooms[0], rooms[3], rooms[1]]] {
            XCTAssertNil(MobileAgentRoomPolicy.choose(permutation))
        }
    }

    func testWithoutAPlainRoomTheMostRecentRoomStaysTheChat() throws {
        // Before an account moves to 0.20 rooms the agent still has a chat:
        // the most recent room, even with encryption.
        let choice = try XCTUnwrap(MobileAgentRoomPolicy.choose([
            MobileAgentRoomCandidate(roomID: "!moon-1", encrypted: true, latestTimestamp: 100),
            MobileAgentRoomCandidate(roomID: "!moon-2", encrypted: true, latestTimestamp: 300),
            MobileAgentRoomCandidate(roomID: "!moon-3", encrypted: nil, latestTimestamp: nil)
        ]))
        XCTAssertEqual(choice.chatRoomID, "!moon-2")
        XCTAssertEqual(choice.reason, .noPlainRoom)
        XCTAssertEqual(choice.hiddenRoomIDs, ["!moon-1", "!moon-3"])

        let single = try XCTUnwrap(MobileAgentRoomPolicy.choose([
            MobileAgentRoomCandidate(roomID: "!only", encrypted: true, latestTimestamp: 1)
        ]))
        XCTAssertEqual(single.chatRoomID, "!only")
        XCTAssertEqual(single.reason, .noPlainRoom)
        XCTAssertEqual(single.hiddenRoomIDs, [])
        XCTAssertNil(MobileAgentRoomPolicy.choose([]))
    }

    func testChatListShowsOnlyThePlainRoomOfAnAgentAndEveryPeopleRoom() {
        let listing = MobileAgentRoomPolicy.listing([
            MobileRosterRoomEntry(roomID: "!moon-encrypted-new", agentKey: "agent:moon",
                                  encrypted: true, latestTimestamp: 900),
            MobileRosterRoomEntry(roomID: "!group", agentKey: nil, encrypted: true, latestTimestamp: 800),
            MobileRosterRoomEntry(roomID: "!andy-plain", agentKey: "app:andy",
                                  encrypted: false, latestTimestamp: 700),
            MobileRosterRoomEntry(roomID: "!moon-unknown", agentKey: "agent:moon",
                                  encrypted: nil, latestTimestamp: 600),
            MobileRosterRoomEntry(roomID: "!lan", agentKey: nil, encrypted: false, latestTimestamp: 500),
            MobileRosterRoomEntry(roomID: "!moon-plain", agentKey: "agent:moon",
                                  encrypted: false, latestTimestamp: 400),
            MobileRosterRoomEntry(roomID: "!andy-encrypted", agentKey: "app:andy",
                                  encrypted: true, latestTimestamp: 300)
        ])
        // Input order is kept; each agent or bot appears once, at its plain
        // room's place; people and group rooms are untouched (encrypted or not).
        XCTAssertEqual(listing.listedRoomIDs, ["!group", "!andy-plain", "!lan", "!moon-plain"])
        XCTAssertEqual(listing.choices["agent:moon"]?.chatRoomID, "!moon-plain")
        XCTAssertEqual(listing.choices["agent:moon"]?.hiddenRoomIDs, ["!moon-encrypted-new", "!moon-unknown"])
        XCTAssertEqual(listing.choices["app:andy"]?.hiddenRoomIDs, ["!andy-encrypted"])
        XCTAssertNil(listing.choices["!group"])
    }

    func testChatListHidesEveryDuplicatePlainRoomButKeepsPeopleRooms() {
        let listing = MobileAgentRoomPolicy.listing([
            MobileRosterRoomEntry(roomID: "!agent-main", agentKey: "agent:atum",
                                  encrypted: false, latestTimestamp: 100),
            MobileRosterRoomEntry(roomID: "!person", agentKey: nil,
                                  encrypted: true, latestTimestamp: 90),
            MobileRosterRoomEntry(roomID: "!agent-duplicate", agentKey: "agent:atum",
                                  encrypted: false, latestTimestamp: 200)
        ])

        XCTAssertEqual(listing.listedRoomIDs, ["!person"])
        XCTAssertNil(listing.choices["agent:atum"])
        XCTAssertEqual(listing.duplicatePlainRoomCounts, ["agent:atum": 2])
    }

    func testNoAgentRoomIsListedTwiceAndHiddenRoomsAreNeverListed() {
        var rooms = [MobileRosterRoomEntry]()
        for index in 0..<12 {
            let agentKey: String? = index % 4 == 0 ? nil : "agent:\(index % 3)"
            let encrypted: Bool? = index % 5 == 0 ? nil : index % 2 == 0
            let timestamp = UInt64((index * 37) % 11)
            rooms.append(MobileRosterRoomEntry(roomID: "!r\(index)", agentKey: agentKey,
                                               encrypted: encrypted, latestTimestamp: timestamp))
        }
        // The same room ID twice must not give two rows.
        rooms.append(MobileRosterRoomEntry(roomID: "!r1", agentKey: "agent:1", encrypted: true, latestTimestamp: 1))

        let listing = MobileAgentRoomPolicy.listing(rooms)
        let listed: [String] = listing.listedRoomIDs
        XCTAssertEqual(listed.count, Set(listed).count)
        let hidden = Set(listing.choices.values.flatMap(\.hiddenRoomIDs))
        XCTAssertTrue(hidden.isDisjoint(with: listed))

        let agentKeys = Set(rooms.compactMap(\.agentKey))
        for key in agentKeys {
            let candidates = rooms.filter { $0.agentKey == key }
            let candidateIDs = Set(candidates.map(\.roomID))
            let listedForAgent = listed.filter { candidateIDs.contains($0) }
            if let choice = listing.choices[key] {
                XCTAssertEqual(listedForAgent, [choice.chatRoomID], key)
                XCTAssertEqual(Set(choice.hiddenRoomIDs), candidateIDs.subtracting([choice.chatRoomID]), key)
                XCTAssertNil(listing.duplicatePlainRoomCounts[key], key)
            } else {
                XCTAssertEqual(listedForAgent, [], key)
                let plainCount = candidates.count { $0.encrypted == false }
                XCTAssertGreaterThan(plainCount, 1, key)
                XCTAssertEqual(listing.duplicatePlainRoomCounts[key], plainCount, key)
            }
        }
        for room in rooms where room.agentKey == nil {
            XCTAssertTrue(listed.contains(room.roomID), room.roomID)
        }
        let empty = MobileAgentRoomPolicy.listing([])
        XCTAssertEqual(empty.listedRoomIDs, [])
        XCTAssertEqual(empty.duplicatePlainRoomCounts, [:])
    }

    // MARK: Sender labels

    func testSenderLabelUsesTheAgentNameThenTheProfileNameAndNeverTheMatrixID() {
        let agent = "@agent-7f3a:example.invalid"
        XCTAssertEqual(MobileSenderLabelPolicy.label(senderID: agent, profileDisplayName: "agent-7f3a",
                                                     knownNames: [agent: "Atum Bot"]), "Atum Bot")
        XCTAssertEqual(MobileSenderLabelPolicy.label(senderID: "@lan:example.invalid",
                                                     profileDisplayName: "  Lan  ", knownNames: [:]), "Lan")
        for profile in [nil, "", "   ", "@lan:example.invalid", "@someone:else.org", "a\u{0007}b"] as [String?] {
            XCTAssertNil(MobileSenderLabelPolicy.label(senderID: "@lan:example.invalid",
                                                       profileDisplayName: profile, knownNames: [:]),
                         String(describing: profile))
        }
        // A broken server name falls back to the profile name, not the ID.
        XCTAssertEqual(MobileSenderLabelPolicy.label(senderID: agent, profileDisplayName: "Moon",
                                                     knownNames: [agent: agent]), "Moon")
    }

    func testAPersonCannotTakeTheNameOfAKnownAgentOrBot() {
        let agent = "@agent-moon:example.invalid"
        let bot = "@app-andy:atumplatform.com"
        let known = [agent: "Moon", bot: "Andy"]
        let person = "@lan:example.invalid"
        // The real agent keeps its name, whatever its profile says.
        XCTAssertEqual(MobileSenderLabelPolicy.label(senderID: agent, profileDisplayName: "Moon",
                                                     knownNames: known), "Moon")
        // A person whose profile name matches an agent or bot gets no label,
        // ignoring case, full-width forms and spacing.
        for spoof in ["Moon", " moon ", "MOON", "Ｍｏｏｎ", "andy", "Andy"] {
            XCTAssertNil(MobileSenderLabelPolicy.label(senderID: person, profileDisplayName: spoof,
                                                       knownNames: known), spoof)
        }
        // Names that only look alike are still a person's own name.
        XCTAssertEqual(MobileSenderLabelPolicy.label(senderID: person, profileDisplayName: "Moonlight",
                                                     knownNames: known), "Moonlight")
        XCTAssertEqual(MobileSenderLabelPolicy.label(senderID: person, profileDisplayName: "Lan",
                                                     knownNames: known), "Lan")
    }

    // MARK: Which rooms can be an agent's chat

    func testANamedGroupWithEmptyHeroesIsNeverAnAgentsChat() {
        let agent = "@agent-moon:example.invalid"
        // The server sends no heroes for a named room; the member count still
        // says it is a group, so the agent speaking last does not matter.
        XCTAssertEqual(MobileAgentRoomPolicy.candidateUserIDs(memberCount: 4, heroes: [],
                                                              latestSenderID: agent), [])
        XCTAssertEqual(MobileAgentRoomPolicy.candidateUserIDs(memberCount: 3, heroes: [agent],
                                                              latestSenderID: agent), [])
        XCTAssertEqual(MobileAgentRoomPolicy.candidateUserIDs(memberCount: 9, heroes: [agent, "@lan:x"],
                                                              latestSenderID: nil), [])
    }

    func testARoomWithTheOwnerAndOneOtherMemberCanBeTheAgentsChat() {
        let agent = "@agent-moon:example.invalid"
        // Named 1:1 room, no heroes, the agent spoke last.
        XCTAssertEqual(MobileAgentRoomPolicy.candidateUserIDs(memberCount: 2, heroes: [],
                                                              latestSenderID: agent), [agent])
        // Unnamed 1:1 room: the hero is the agent even when the owner spoke last.
        XCTAssertEqual(MobileAgentRoomPolicy.candidateUserIDs(memberCount: 2, heroes: [agent],
                                                              latestSenderID: "@owner:example.invalid"),
                       [agent, "@owner:example.invalid"])
        // The agent has invited the owner and nobody else yet.
        XCTAssertEqual(MobileAgentRoomPolicy.candidateUserIDs(memberCount: 1, heroes: [agent],
                                                              latestSenderID: nil), [agent])
    }

    // MARK: No downgrade

    func testAPlainMessageInARoomWithEncryptionIsNotShown() {
        XCTAssertFalse(MobilePlaintextEventPolicy.shows(roomEncrypted: true, sentInClear: true))
        // Unknown room state keeps the refusal.
        XCTAssertFalse(MobilePlaintextEventPolicy.shows(roomEncrypted: nil, sentInClear: true))
        // Encrypted messages in an encrypted room show as today.
        XCTAssertTrue(MobilePlaintextEventPolicy.shows(roomEncrypted: true, sentInClear: false))
    }

    func testRoomsWithoutEncryptionShowEveryMessage() {
        XCTAssertTrue(MobilePlaintextEventPolicy.shows(roomEncrypted: false, sentInClear: false))
        XCTAssertTrue(MobilePlaintextEventPolicy.shows(roomEncrypted: false, sentInClear: true))
    }

    // MARK: Invites

    func testInvitesAreAcceptedOnlyFromKnownAgentsAndBots() {
        let known: Set<String> = ["@agent-1:example.invalid", "@app-moon:atumplatform.com"]
        XCTAssertTrue(MobileInvitePolicy.shouldAutoAccept(inviterID: "@agent-1:example.invalid",
                                                          knownAgentAndBotUserIDs: known))
        XCTAssertTrue(MobileInvitePolicy.shouldAutoAccept(inviterID: "@app-moon:atumplatform.com",
                                                          knownAgentAndBotUserIDs: known))
        for inviter in [nil, "", "@stranger:example.invalid", "@app-moonish:example.invalid",
                        "@agent-1:evil.example"] as [String?] {
            XCTAssertFalse(MobileInvitePolicy.shouldAutoAccept(inviterID: inviter, knownAgentAndBotUserIDs: known),
                           String(describing: inviter))
        }
        // Before /agents and /apps load, nothing is accepted on its own.
        XCTAssertFalse(MobileInvitePolicy.shouldAutoAccept(inviterID: "@agent-1:example.invalid",
                                                           knownAgentAndBotUserIDs: []))
    }

    // MARK: Push

    func testPusherAppIDFollowsTheBuild() {
        XCTAssertEqual(MobileAPNSEnvironment.forBuild(isDebug: true).appID, "com.atum.mobile.ios.dev")
        XCTAssertEqual(MobileAPNSEnvironment.forBuild(isDebug: false).appID, "com.atum.mobile.ios.prod")
    }

    func testPusherFieldsMatchTheContractBodyAndCarryOnlyTheGenericAlert() throws {
        let token = try APNsDeviceToken(bytes: Data(repeating: 0x5c, count: 32))
        for environment in [MobileAPNSEnvironment.sandbox, .production] {
            let fields = try MobilePush.pusherFields(token: token, environment: environment,
                                                     device: .iPhone, locale: .vi)
            let body = try MobilePush.registration(MobilePush.register(token: token, environment: environment,
                                                                       device: .iPhone, locale: .vi))
            XCTAssertEqual(fields.appID, body.environment.appID)
            XCTAssertEqual(fields.pushkey, String(repeating: "5c", count: 32))
            XCTAssertEqual(fields.appDisplayName, "Atum")
            XCTAssertEqual(fields.deviceDisplayName, "iPhone")
            XCTAssertEqual(fields.lang, "vi")
            XCTAssertEqual(fields.url, "https://push.atumplatform.com/_matrix/push/v1/notify")
            XCTAssertEqual(fields.format, "event_id_only")

            let payload = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(fields.defaultPayloadJSON.utf8)) as? [String: Any])
            XCTAssertEqual(Set(payload.keys), ["aps"])
            let aps = try XCTUnwrap(payload["aps"] as? [String: Any])
            XCTAssertEqual(Set(aps.keys), ["mutable-content", "alert"])
            XCTAssertEqual(aps["mutable-content"] as? Int, 1)
            let alert = try XCTUnwrap(aps["alert"] as? [String: Any])
            XCTAssertEqual(alert as? [String: String], ["loc-key": "ATUM_NEW_MESSAGE"])
            // The routing token never appears in a printed value.
            XCTAssertFalse(String(describing: fields).contains("5c5c"))
        }
    }

    func testPushLocaleFollowsThePhoneLanguageWithVietnameseFirst() {
        let cases: [(String, MobilePushLocale)] = [
            ("vi-VN", .vi), ("vi", .vi), ("en-US", .en), ("en_GB", .en), ("ja-JP", .ja),
            ("zh-Hans-CN", .zh), ("zh-CN", .zh), ("zh-Hant-TW", .zhHant), ("zh-HK", .zhHant),
            ("fr-FR", .vi), ("", .vi)
        ]
        for (tag, expected) in cases {
            XCTAssertEqual(MobilePushLocale(languageTag: tag), expected, tag)
        }
    }
}
