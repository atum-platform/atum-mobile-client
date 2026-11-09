import XCTest
@testable import AtumNativeAPI

/// 0.19.4 quality lane Q5/Q6 behavior contracts: a verified phone is never
/// blocked or nagged because old history is locked, and deleting a bot chat
/// on the phone hides the same room instead of leaving it.
final class QuietRecoveryAndBotRoomTests: XCTestCase {
    private let allRecovery: [MobileMatrixRecoveryStatus] = [.unknown, .ready, .incomplete, .unavailable]

    func testVerifiedPhoneIsReadyWhateverItsRecoveryState() {
        for recovery in allRecovery {
            XCTAssertEqual(MobileDeviceTrustPolicy.phase(verification: .verified, recovery: recovery), .ready)
            XCTAssertFalse(MobileDeviceTrustPolicy.shouldRequestVerification(verification: .verified,
                                                                            recovery: recovery))
        }
    }

    func testOnlyAnUnverifiedPhoneHasARequiredStep() {
        for recovery in allRecovery {
            XCTAssertEqual(MobileDeviceTrustPolicy.phase(verification: .unverified, recovery: recovery),
                           .actionRequired)
            XCTAssertTrue(MobileDeviceTrustPolicy.shouldRequestVerification(verification: .unverified,
                                                                           recovery: recovery))
            XCTAssertEqual(MobileDeviceTrustPolicy.phase(verification: .unknown, recovery: recovery), .checking)
        }
    }

    func testHistoryRecoveryIsOfferedToAnyPhoneWithLockedHistory() {
        // 0.20: chatting never depends on verification, so the optional
        // "restore messages" entry follows the backup state alone.
        XCTAssertTrue(MobileDeviceTrustPolicy.offersHistoryRecovery(verification: .unverified,
                                                                   recovery: .incomplete))
        XCTAssertFalse(MobileDeviceTrustPolicy.offersHistoryRecovery(verification: .unverified,
                                                                    recovery: .unavailable))
        for verification in [MobileMatrixVerificationStatus.unknown, .verified, .unverified] {
            for recovery in allRecovery {
                let offered = MobileDeviceTrustPolicy.offersHistoryRecovery(verification: verification,
                                                                           recovery: recovery)
                XCTAssertEqual(offered, recovery == .incomplete, "\(verification) \(recovery)")
            }
        }
    }

    func testBotRoomIsTheOwnersOneToOneRoomWithAnAppBot() {
        let catalog: Set<String> = ["@app-moon:atumplatform.com"]
        XCTAssertEqual(MobileAppBotRoomPolicy.botUserID(heroes: ["@app-moon:atumplatform.com"],
                                                        latestSenderID: nil, isDirect: true,
                                                        catalogBotUserIDs: catalog),
                       "@app-moon:atumplatform.com")
        // Without a catalog the official identities are still recognised.
        XCTAssertEqual(MobileAppBotRoomPolicy.botUserID(heroes: ["@app-andy:atumplatform.com"],
                                                        latestSenderID: nil, isDirect: false,
                                                        catalogBotUserIDs: []),
                       "@app-andy:atumplatform.com")
        // A group that contains a bot, a person, or a look-alike is not a bot room.
        XCTAssertNil(MobileAppBotRoomPolicy.botUserID(heroes: ["@app-moon:atumplatform.com", "@friend:example.invalid"],
                                                      latestSenderID: "@app-moon:atumplatform.com", isDirect: false,
                                                      catalogBotUserIDs: catalog))
        XCTAssertNil(MobileAppBotRoomPolicy.botUserID(heroes: ["@friend:example.invalid"],
                                                      latestSenderID: nil, isDirect: true,
                                                      catalogBotUserIDs: catalog))
        XCTAssertNil(MobileAppBotRoomPolicy.botUserID(heroes: ["@app-moonish:example.invalid"],
                                                      latestSenderID: nil, isDirect: true,
                                                      catalogBotUserIDs: catalog))
        // Missing heroes fall back to the latest sender only for a direct room.
        XCTAssertEqual(MobileAppBotRoomPolicy.botUserID(heroes: [], latestSenderID: "@app-moon:atumplatform.com",
                                                        isDirect: true, catalogBotUserIDs: catalog),
                       "@app-moon:atumplatform.com")
        XCTAssertNil(MobileAppBotRoomPolicy.botUserID(heroes: [], latestSenderID: "@app-moon:atumplatform.com",
                                                      isDirect: false, catalogBotUserIDs: catalog))
        // A catalog bot outside the official set is recognised from the catalog.
        XCTAssertTrue(MobileAppBotRoomPolicy.isAppBotUser("@app-next:example.invalid",
                                                          catalogBotUserIDs: ["@app-next:example.invalid"]))
        XCTAssertFalse(MobileAppBotRoomPolicy.isAppBotUser("@app-next:example.invalid", catalogBotUserIDs: []))
    }

    func testHiddenRoomStaysHiddenUntilANewerMessageOrAnExplicitOpen() {
        var ledger = MobileHiddenRoomLedger()
        ledger.hide(roomID: "!moon", latestTimestamp: 1_000, nowMillis: 1_000)
        XCTAssertTrue(ledger.isHidden(roomID: "!moon", latestTimestamp: 1_000))
        XCTAssertFalse(ledger.isHidden(roomID: "!other", latestTimestamp: 1_000))
        // A newer message brings the same room back.
        XCTAssertFalse(ledger.isHidden(roomID: "!moon", latestTimestamp: 1_001))

        // Opening the bot again reveals it explicitly.
        XCTAssertTrue(ledger.unhide(roomID: "!moon"))
        XCTAssertFalse(ledger.isHidden(roomID: "!moon", latestTimestamp: 1_000))
        XCTAssertFalse(ledger.unhide(roomID: "!moon"))

        // A room with no messages stays hidden until a message after the hide.
        ledger.hide(roomID: "!empty", latestTimestamp: nil, nowMillis: 5_000)
        XCTAssertTrue(ledger.isHidden(roomID: "!empty", latestTimestamp: nil))
        XCTAssertFalse(ledger.isHidden(roomID: "!empty", latestTimestamp: 5_001))
    }

    func testOldEventThatBecomesReadableLaterDoesNotRevealAHiddenRoom() {
        // Locked history: the latest event had no time when Delete chat was
        // tapped. Unlocking old messages or a restart then gives it a time
        // from before the hide; the room must stay hidden.
        var ledger = MobileHiddenRoomLedger()
        ledger.hide(roomID: "!moon", latestTimestamp: nil, nowMillis: 9_000)
        XCTAssertTrue(ledger.isHidden(roomID: "!moon", latestTimestamp: 4_000))
        XCTAssertEqual(ledger.pruneRevealed(latestTimestamps: ["!moon": 4_000]), [])
        XCTAssertTrue(ledger.isHidden(roomID: "!moon", latestTimestamp: 4_000))
        // Same when an older timestamp was known but newer locked events exist.
        ledger.hide(roomID: "!andy", latestTimestamp: 2_000, nowMillis: 9_000)
        XCTAssertTrue(ledger.isHidden(roomID: "!andy", latestTimestamp: 8_999))
        // A message after the hide reveals the room.
        XCTAssertEqual(ledger.pruneRevealed(latestTimestamps: ["!moon": 9_001, "!andy": 8_999]), ["!moon"])
        XCTAssertFalse(ledger.isHidden(roomID: "!moon", latestTimestamp: 9_001))
    }

    func testPointerNamesTheRoomOnlyForThisBotAndVersion() {
        let bot = "@app-moon:atumplatform.com"
        XCTAssertEqual(MobileAppBotRoomPolicy.pointerEventType(appID: "moon"), "io.atum.app_bot.dm.moon")
        XCTAssertEqual(MobileAppBotRoomPolicy.pointerRoomID(
            contentJSON: #"{"v":1,"room_id":"!canon:example.invalid","bot_user_id":"@app-moon:atumplatform.com"}"#,
            botUserID: bot), "!canon:example.invalid")
        for content in [nil, "", "not json",
                        #"{"v":2,"room_id":"!canon:x","bot_user_id":"@app-moon:atumplatform.com"}"#,
                        #"{"v":true,"room_id":"!canon:x","bot_user_id":"@app-moon:atumplatform.com"}"#,
                        #"{"v":1,"room_id":"!canon:x","bot_user_id":"@app-andy:atumplatform.com"}"#,
                        #"{"v":1,"room_id":"canon","bot_user_id":"@app-moon:atumplatform.com"}"#,
                        #"{"v":1,"bot_user_id":"@app-moon:atumplatform.com"}"#] as [String?] {
            XCTAssertNil(MobileAppBotRoomPolicy.pointerRoomID(contentJSON: content, botUserID: bot),
                         String(describing: content))
        }
    }

    func testManualKeyFailureBlamesTheKeyOnlyWhenTheKeyWasRejected() {
        XCTAssertEqual(MobileManualRecoveryKeyPolicy.presentation(
            forFailureCode: MobileRecoveryKeyFailureCode.keyRejected.rawValue), .retryKey)
        XCTAssertEqual(MobileManualRecoveryKeyPolicy.presentation(
            forFailureCode: MobileRecoveryKeyFailureCode.keyFormatInvalid.rawValue), .retryKey)
        // An accepted key that is still opening old messages is not a failure.
        XCTAssertEqual(MobileManualRecoveryKeyPolicy.presentation(
            forFailureCode: MobileRecoveryKeyFailureCode.acceptedStillRestoring.rawValue), .stillRestoring)
        // Network, storage and unknown errors never say the key was wrong.
        for code in ["sdk_recovery_client", "sdk_recovery_import", "recovery_storage_unavailable",
                     "unclassified_URLError", "cancelled", ""] {
            XCTAssertEqual(MobileManualRecoveryKeyPolicy.presentation(forFailureCode: code), .genericRetry, code)
        }
        XCTAssertGreaterThan(MobileManualRecoveryKeyPolicy.pendingWaitSeconds, 0)
    }

    func testPruneRevealsOnlyRoomsWithNewerMessagesAndKeepsUnloadedRooms() {
        var ledger = MobileHiddenRoomLedger()
        ledger.hide(roomID: "!moon", latestTimestamp: 10, nowMillis: 10)
        ledger.hide(roomID: "!andy", latestTimestamp: 20, nowMillis: 20)
        ledger.hide(roomID: "!loading", latestTimestamp: 30, nowMillis: 30)

        let revealed = ledger.pruneRevealed(latestTimestamps: ["!moon": 11, "!andy": 20])
        XCTAssertEqual(revealed, ["!moon"])
        XCTAssertFalse(ledger.isHidden(roomID: "!moon", latestTimestamp: 11))
        XCTAssertTrue(ledger.isHidden(roomID: "!andy", latestTimestamp: 20))
        // An empty or still-loading room list never wipes the owner's choice.
        XCTAssertEqual(ledger.pruneRevealed(latestTimestamps: [:]), [])
        XCTAssertTrue(ledger.isHidden(roomID: "!loading", latestTimestamp: 30))
    }

    func testHiddenRoomsSurviveARestart() throws {
        var ledger = MobileHiddenRoomLedger()
        ledger.hide(roomID: "!moon", latestTimestamp: 42, nowMillis: 42)
        let restored = try JSONDecoder().decode(MobileHiddenRoomLedger.self,
                                                from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored, ledger)
        XCTAssertTrue(restored.isHidden(roomID: "!moon", latestTimestamp: 42))
    }
}
