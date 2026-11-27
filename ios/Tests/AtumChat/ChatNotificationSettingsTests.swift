import Foundation
import XCTest
@testable import AtumChat

final class ChatNotificationSettingsTests: XCTestCase {
    private let room = "!team:example.test"
    private let root = "$root"
    private let legacyJSON = """
    {"version":1,"accountLevel":"mentions",
     "quietHours":{"enabled":true,"startMinute":1320,"endMinute":420,"timeZone":"UTC"},
     "channelOverrides":{"!team:example.test":"nothing","!other:example.test":"mentions"},
     "threadOverrides":{"!team:example.test":{"$root":"nothing","$other":"all"}}}
    """

    func testExplicitAllDiffersFromInheritedAllAndInheritedMentions() {
        for mode in [ChatNotificationMode.all, .mentionsAndKeywords, .off] {
            let explicit = ChatNotificationSettings(effectiveMode: mode, isInherited: false,
                                                    hasEncryptedMentionCaveat: true)
            let inherited = ChatNotificationSettings(effectiveMode: mode, isInherited: true,
                                                     hasEncryptedMentionCaveat: true)
            XCTAssertEqual(explicit.selection, .set(mode))
            XCTAssertEqual(inherited.selection, .restoreDefault)
            XCTAssertEqual(explicit.effectiveMode, inherited.effectiveMode)
            XCTAssertNotEqual(explicit, inherited)
        }
    }

    func testRetirementShadowsOnlyItsChannelThroughLaterRestores() throws {
        let legacy = try XCTUnwrap(TeamNotificationPolicy.Legacy.parse(legacyJSON))
        let target = TeamNotificationPolicy.Target.channel(room)
        let before = TeamNotificationPolicy(roomID: room, legacy: legacy)
        XCTAssertTrue(before.suppressesAdmittedNotification(roomIsInherited: true, hasAttention: true, now: day))
        XCTAssertFalse(before.suppressesAdmittedNotification(roomIsInherited: false, hasAttention: true, now: day))

        let json = try TeamNotificationPolicy.Record.retiringChannel(room, previousRevision: 4)
        let retirement = try XCTUnwrap(TeamNotificationPolicy.Record.parse(json, for: target))
        XCTAssertEqual(retirement.revision, 5)
        XCTAssertTrue(retirement.isInherited)
        XCTAssertNil(TeamNotificationPolicy.Record.parse(json, for: .channel("!other:example.test")))
        XCTAssertNil(TeamNotificationPolicy.Record.parse(
            json.replacingOccurrences(of: "\"expected_revision\":4", with: "\"expected_revision\":3"), for: target))

        let after = TeamNotificationPolicy(roomID: room, legacy: legacy, channel: retirement)
        XCTAssertFalse(after.suppressesAdmittedNotification(roomIsInherited: true, hasAttention: false, now: day))
        let other = TeamNotificationPolicy(roomID: "!other:example.test", legacy: legacy)
        XCTAssertTrue(other.suppressesAdmittedNotification(roomIsInherited: true, hasAttention: false, now: day))
        let thread = TeamNotificationPolicy(roomID: room, rootID: root, legacy: legacy, channel: retirement)
        XCTAssertTrue(thread.suppressesAdmittedNotification(roomIsInherited: false, hasAttention: true, now: day))
        XCTAssertTrue(thread.suppressesAdmittedNotification(roomIsInherited: true, hasAttention: true, now: day))
    }

    func testTargetKeysAndThreadOverridesMatchDesktopAccountData() throws {
        let channel = TeamNotificationPolicy.Target.channel(room)
        let thread = TeamNotificationPolicy.Target.thread(roomID: room, rootID: root)
        XCTAssertEqual(channel.eventType,
                       "io.atum.notification.v2.39ef4df6af08b196b8a391272438ccccaa9f2abe2e16961266b2703719678a88")
        XCTAssertEqual(thread.eventType,
                       "io.atum.notification.v2.2c5c38b54eea603510bc519de6e1f94e2a3432a371d92bbc570bf7609bdedc46")

        let json = """
        {"version":2,"revision":2,"expected_revision":1,
         "change":{"scope":"thread","roomId":"!team:example.test","rootId":"$root","level":"inherit"}}
        """
        let legacy = try XCTUnwrap(TeamNotificationPolicy.Legacy.parse(legacyJSON))
        let target = try XCTUnwrap(TeamNotificationPolicy.Record.parse(json, for: thread))
        let inherited = TeamNotificationPolicy(roomID: room, rootID: root, legacy: legacy, thread: target)
        XCTAssertTrue(inherited.suppressesAdmittedNotification(roomIsInherited: false, hasAttention: false, now: day))
        XCTAssertFalse(inherited.suppressesAdmittedNotification(roomIsInherited: false, hasAttention: true, now: day))
        let mainTimeline = TeamNotificationPolicy(roomID: room, legacy: legacy)
        XCTAssertFalse(mainTimeline.suppressesAdmittedNotification(
            roomIsInherited: false, hasAttention: false, now: day))
    }

    func testQuietHoursStayInEffectWithExplicitAllAndAcrossMidnight() throws {
        let legacy = try XCTUnwrap(TeamNotificationPolicy.Legacy.parse(legacyJSON))
        let policy = TeamNotificationPolicy(roomID: room, legacy: legacy)
        for (hour, expected) in [(0, true), (6, true), (7, false), (21, false), (22, true), (23, true)] {
            let now = Date(timeIntervalSince1970: TimeInterval(hour * 3_600))
            XCTAssertEqual(policy.suppressesAdmittedNotification(roomIsInherited: false, hasAttention: true, now: now),
                           expected)
        }
    }

    func testTeamMentionsRequireIntentionalMetadata() {
        let user = "@viewer:example.test"
        let noMetadata = TeamNotificationPolicy.intentionalMentions(
            eventJSON: #"{"content":{"body":"@viewer:example.test"}} "#, ownUserID: user)
        XCTAssertFalse(noMetadata.direct)
        XCTAssertFalse(noMetadata.room)
        let withMetadata = TeamNotificationPolicy.intentionalMentions(
            eventJSON: #"{"content":{"m.mentions":{"user_ids":["@viewer:example.test"],"room":true}}}"#,
            ownUserID: user)
        XCTAssertTrue(withMetadata.direct)
        XCTAssertTrue(withMetadata.room)
    }

    func testProtectsConditionalRulesOutsideTheRoomMode() {
        let mute = """
        {"global":{"override":[{"rule_id":"!team:example.test","actions":[],
          "conditions":[{"kind":"event_match","key":"room_id","pattern":"!team:example.test"}]}]}}
        """
        XCTAssertTrue(RoomPushRulePolicy.canChangeMode(rawRules: mute, roomID: room))
        let compound = """
        {"global":{"override":[{"rule_id":"quiet-member","actions":[],
          "conditions":[{"kind":"event_match","key":"room_id","pattern":"!team:example.test"},
                        {"kind":"event_match","key":"sender","pattern":"@member:example.test"}]}]}}
        """
        XCTAssertFalse(RoomPushRulePolicy.canChangeMode(rawRules: compound, roomID: room))
        XCTAssertTrue(RoomPushRulePolicy.canChangeMode(rawRules: compound, roomID: "!other:example.test"))
        XCTAssertFalse(RoomPushRulePolicy.canChangeMode(
            rawRules: mute.replacingOccurrences(of: "\"override\"", with: "\"underride\""), roomID: room))
        XCTAssertTrue(RoomPushRulePolicy.canChangeMode(rawRules: nil, roomID: room))
    }

    private var day: Date { Date(timeIntervalSince1970: 12 * 3_600) }
}
