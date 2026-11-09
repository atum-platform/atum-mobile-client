import AtumNativeAPI
import XCTest
@testable import AtumMobile

/// The chat list composition for a catalog app bot that has no chat yet. The
/// app (`acme`) is unknown to the phone; whatever makes its row appear and
/// start must come from the catalog alone.
final class AppStartRosterTests: XCTestCase {
    private let acmeAppID = "00000000-0000-4000-8000-f6222a1106ee"

    private func descriptor(slug: String = "acme", id: String = "00000000-0000-4000-8000-f6222a1106ee",
                            botState: String = "active", disclosure: Int = 1,
                            rosterDefault: Bool = true) throws -> AppDescriptor {
        let icon: [String: Any] = ["url": "https://cdn.atumplatform.com/apps/\(slug).png",
                                   "sha256": String(repeating: "a", count: 64)]
        let app: [String: Any] = [
            "app": slug, "app_id": id,
            "app_version_id": "00000000-0000-4000-8000-f1d11edf5c5c",
            "name": ["en": slug.capitalized], "subtitle": ["en": "Skin guidance"],
            "description": NSNull(), "icon": icon, "accent": NSNull(), "affiliation": NSNull(),
            "verified": false, "availability": "available", "roster_default": rosterDefault,
            "roster_order": 5, "supported_modes": ["direct"], "has_surface": false,
            "link": ["mode": "external_account", "state": "never_linked"],
            "bot": [
                "v": 1, "user_id": "@app-\(slug):atumplatform.com", "handle": "\(slug)_bot",
                "display_name": slug.capitalized, "avatar": icon, "device_generation": 1,
                "device": ["device_id": "X.1", "ed25519": String(repeating: "A", count: 43),
                           "curve25519": String(repeating: "B", count: 43)],
                "state": botState, "groups": false, "consent": "required",
                "disclosure_version": disclosure, "open_route_id": "open",
                "open_shared_memory": false, "purchase_route_id": "purchase",
                "guest_enabled": true, "direct_profile": "atum.turn-memory/2",
            ] as [String: Any],
        ]
        let body = try JSONSerialization.data(
            withJSONObject: ["profile": "atum.app-catalog/1", "apps": [app]])
        return try NativeAPI.decode(AppCatalogResponse.self, from: body).apps[0]
    }

    private func input(_ apps: [AppDescriptor], rooms: [LiveMatrixRoomRow] = [],
                       pointers: [String: String] = [:]) -> LiveRosterRows.Input {
        LiveRosterRows.Input(
            agents: [], apps: apps, rooms: rooms, invites: [], pointers: pointers,
            hiddenRooms: MobileHiddenRoomLedger(),
            appShortcuts: Dictionary(uniqueKeysWithValues: apps.map { ($0.appID, .absent) }),
            locale: "en"
        )
    }

    private func room(_ roomID: String, with bot: String) -> LiveMatrixRoomRow {
        LiveMatrixRoomRow(
            roomID: roomID, displayName: "Acme", avatarURL: nil, latestText: "Hello",
            latestPreviewContent: .text("Hello"), latestSenderID: bot, latestSenderName: "Acme",
            latestIsOwn: false, latestIsNotice: false, latestSendState: .sent,
            latestTimestamp: 1_000, unreadCount: 0, notificationCount: 0, highlightCount: 0,
            isMarkedUnread: false, isFavourite: false, isMuted: false, isDirect: true,
            memberUserIDs: [bot], memberCount: 2, roomType: nil, isEncrypted: false
        )
    }

    func testARosterDefaultBotWithNoChatIsListedAndStartsItsOwnFlow() throws {
        let acme = try descriptor()
        let row = try XCTUnwrap(LiveRosterRows.rows(input([acme])).rows
            .first { $0.id == "app:" + acmeAppID })
        XCTAssertTrue(row.awaitsStart)
        XCTAssertTrue(row.canOpen, "the row is tappable: it starts the flow")
        XCTAssertEqual(row.title, "Acme")
        XCTAssertEqual(row.detail, "Skin guidance")
    }

    func testTheSameAppWithAChatReopensItAndIsNotWaitingToStart() throws {
        let acme = try descriptor()
        let bot = "@app-acme:atumplatform.com"
        let rows = LiveRosterRows.rows(input(
            [acme], rooms: [room("!acme-dm:example.invalid", with: bot)],
            pointers: [acmeAppID: "!acme-dm:example.invalid"]
        )).rows
        // The chat is a room row; no extra "start" row is invented beside it.
        XCTAssertFalse(rows.contains { $0.awaitsStart })
        XCTAssertTrue(rows.contains { $0.id == "!acme-dm:example.invalid" })
    }

    func testABotThePhoneCannotStartHasNoRow() throws {
        for refused in [
            try descriptor(botState: "paused"),
            try descriptor(botState: "unavailable"),
            try descriptor(disclosure: 2),
            try descriptor(rosterDefault: false),
        ] {
            XCTAssertFalse(LiveRosterRows.rows(input([refused])).rows
                .contains { $0.id.hasPrefix("app:") }, "\(refused.bot?.state ?? .unavailable)")
        }
    }
}
