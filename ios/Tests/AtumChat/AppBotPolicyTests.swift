import Foundation
import XCTest
@testable import AtumChat

final class AppBotPolicyTests: XCTestCase {
    private let appID = "00000000-0000-4000-8000-e79acd97ac88"
    private let appSlug = "moon"
    private let botUserID = "@app-moon:atumplatform.com"

    private var authorization: AppBotMessage.Authorization {
        AppBotMessage.Authorization(expectedCatalogAppID: appID, expectedCatalogAppSlug: appSlug,
                                    expectedCatalogBotUserID: botUserID, itemSender: botUserID,
                                    roomIsEncrypted: false)
    }

    private var botAPIAuthorization: BotAPIMessage.Authorization {
        BotAPIMessage.Authorization(expectedCatalogBotUserID: botUserID,
                                    itemSender: botUserID, roomIsEncrypted: false)
    }

    private func metadata(code: String = "needs_setup", action: Any = NSNull()) -> [String: Any] {
        ["v": 1, "app_id": appID, "kind": "notice", "turn_id": NSNull(), "code": code, "action": action]
    }

    private func event(_ metadata: [String: Any]?, sender: String? = nil, edited: Bool = false) -> String {
        var content: [String: Any] = [:]
        if edited {
            content["m.relates_to"] = ["rel_type": "m.replace", "event_id": "$old"]
            if let metadata { content["m.new_content"] = ["io.atum.app_bot": metadata] }
        } else if let metadata {
            content["io.atum.app_bot"] = metadata
        }
        let object: [String: Any] = ["sender": sender ?? botUserID, "content": content]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func parse(_ metadata: [String: Any]?, sender: String? = nil, edited: Bool = false,
                       authorization: AppBotMessage.Authorization? = nil) -> AppBotMessage? {
        AppBotMessage.parse(latestJSON: event(metadata, sender: sender, edited: edited), authorization: authorization ?? self.authorization)
    }

    func testParsesEveryDesktopNoticeCodeAndNullAction() {
        XCTAssertEqual(AppBotMessage.Code.allCases.count, 19)
        for code in AppBotMessage.Code.allCases {
            XCTAssertEqual(parse(metadata(code: code.rawValue)), AppBotMessage(code: code, action: nil), code.rawValue)
        }
    }

    func testParsesEachAllowlistedActionOnlyAtItsExactShape() {
        XCTAssertEqual(parse(metadata(action: ["kind": "open_setup", "app": appSlug]))?.action, .openSetup(app: appSlug))
        XCTAssertEqual(parse(metadata(action: ["kind": "open_bot_dm", "app": appSlug]))?.action, .openBotDM(app: appSlug))
        XCTAssertEqual(parse(metadata(action: ["kind": "open_app_route", "app": appSlug, "route_id": "birth_intake-1"]))?.action,
                       .openAppRoute(app: appSlug, routeID: "birth_intake-1"))

        XCTAssertNil(parse(metadata(action: ["kind": "open_setup", "app": appSlug, "route_id": "extra"])))
        XCTAssertNil(parse(metadata(action: ["kind": "open_app_route", "app": appSlug, "route_id": "1bad"])))
        XCTAssertNil(parse(metadata(action: ["kind": "open_external", "app": appSlug])))
        XCTAssertNil(parse(metadata(action: ["kind": "open_setup", "app": "andy"])))
    }

    func testRejectsMalformedAndSpoofedMetadata() {
        var extra = metadata()
        extra["extra"] = true
        XCTAssertNil(parse(extra), "metadata may not grow new fields")

        var wrongVersion = metadata()
        wrongVersion["v"] = true
        XCTAssertNil(parse(wrongVersion), "booleans are not numeric versions")

        var wrongTurn = metadata()
        wrongTurn["turn_id"] = "turn"
        XCTAssertNil(parse(wrongTurn))
        XCTAssertNil(parse(metadata(code: "unknown")))
        XCTAssertNil(parse(metadata(), sender: "@attacker:example.invalid"), "raw event sender is an auth fact")

        var foreignItem = authorization
        foreignItem.itemSender = "@attacker:example.invalid"
        XCTAssertNil(parse(metadata(), authorization: foreignItem), "mapped item sender is an independent auth fact")

        var encrypted = authorization
        encrypted.roomIsEncrypted = true
        XCTAssertNil(parse(metadata(), authorization: encrypted), "app notice buttons never appear in encrypted rooms")

        var wrongAppID = metadata()
        wrongAppID["app_id"] = "00000000-0000-4000-8000-993224b4fe85"
        XCTAssertNil(parse(wrongAppID))
    }

    func testReadsEditedMetadataOnlyFromNewContent() {
        let replacement = metadata(code: "needs_intake", action: ["kind": "open_setup", "app": appSlug])
        XCTAssertEqual(parse(replacement, edited: true), AppBotMessage(code: .needsIntake, action: .openSetup(app: appSlug)))
        XCTAssertNil(parse(nil, edited: true), "an edit without metadata must become a plain notice")

        // The raw edit sender is checked even if the SDK has already applied
        // the replacement to the original event.
        XCTAssertNil(parse(replacement, sender: "@attacker:example.invalid", edited: true))
    }

    func testRejectsContentFragmentsAndNonReplacementNewContent() {
        let meta = metadata()
        let fragment = try! JSONSerialization.data(withJSONObject: ["io.atum.app_bot": meta])
        XCTAssertNil(AppBotMessage.parse(latestJSON: String(decoding: fragment, as: UTF8.self), authorization: authorization))

        let content: [String: Any] = [
            "io.atum.app_bot": meta,
            "m.new_content": ["io.atum.app_bot": metadata(code: "needs_intake")]
        ]
        let raw = try! JSONSerialization.data(withJSONObject: ["sender": botUserID, "content": content])
        XCTAssertEqual(AppBotMessage.parse(latestJSON: String(decoding: raw, as: UTF8.self), authorization: authorization)?.code, .needsSetup,
                       "m.new_content is meaningful only for m.replace")
    }

    func testBotAPIMetadataAloneProjectsFormattingAndPhotoFacts() throws {
        let metadata: [String: Any] = [
            "version": "io.atum.bot_api/1",
            "bot_id": "00000000-0000-4000-8000-f6222a1106ee",
            "public_message_id": 43,
            "fallback_text": "Inspect this",
            "keyboard": [
                [["label": "Open Moon", "kind": "url", "url": "https://moon.example/open"]],
                [
                    ["label": "Help", "kind": "url", "url": "https://moon.example/help"],
                    ["label": "Privacy", "kind": "url", "url": "https://moon.example/privacy"],
                ],
            ],
            "photo": [
                "file_ref": "mref_0123456789abcdef",
                "width": 1_280,
                "height": 960,
                "mime_type": "image/jpeg",
                "caption": "Inspect this",
            ],
        ]
        let content: [String: Any] = [
            "msgtype": "m.image",
            "body": "Inspect this",
            "format": "org.matrix.custom.html",
            "formatted_body": "Inspect <strong>this</strong>",
            "io.atum.bot_api": metadata,
        ]
        let raw = try JSONSerialization.data(withJSONObject: ["sender": botUserID, "content": content],
                                             options: [.sortedKeys])
        let parsed = BotAPIMessage.parse(latestJSON: String(decoding: raw, as: UTF8.self),
                                         authorization: botAPIAuthorization)
        XCTAssertEqual(parsed?.publicMessageID, 43)
        XCTAssertEqual(parsed?.formattedBody, "Inspect <strong>this</strong>")
        XCTAssertEqual(parsed?.keyboard?.map { $0.map(\.label) },
                       [["Open Moon"], ["Help", "Privacy"]],
                       "the native button layout preserves metadata rows and order")
        XCTAssertEqual(parsed?.photo, .init(fileReference: "mref_0123456789abcdef",
                                            width: 1_280, height: 960,
                                            mimeType: "image/jpeg", caption: "Inspect this"))
    }

    func testBotAPIMetadataFailureLeavesNoSpecialRenderingAuthority() throws {
        func raw(_ metadata: [String: Any], sender: String = "@app-moon:atumplatform.com") throws -> String {
            let content: [String: Any] = ["msgtype": "m.text", "body": "plain",
                                          "io.atum.bot_api": metadata]
            return String(decoding: try JSONSerialization.data(
                withJSONObject: ["sender": sender, "content": content], options: [.sortedKeys]
            ), as: UTF8.self)
        }
        let valid: [String: Any] = [
            "version": "io.atum.bot_api/1",
            "bot_id": "00000000-0000-4000-8000-f6222a1106ee",
            "public_message_id": 1,
        ]
        XCTAssertNotNil(BotAPIMessage.parse(latestJSON: try raw(valid),
                                            authorization: botAPIAuthorization))

        var extra = valid
        extra["transport_mode"] = "bot_api"
        XCTAssertNil(BotAPIMessage.parse(latestJSON: try raw(extra),
                                         authorization: botAPIAuthorization),
                     "catalog transport mode is never message presentation metadata")
        XCTAssertNil(BotAPIMessage.parse(latestJSON: try raw(valid, sender: "@person:example.invalid"),
                                         authorization: botAPIAuthorization))
        var encrypted = botAPIAuthorization
        encrypted.roomIsEncrypted = true
        XCTAssertNil(BotAPIMessage.parse(latestJSON: try raw(valid), authorization: encrypted))

        var badPhoto = valid
        badPhoto["photo"] = ["file_ref": "mref_short", "width": 1, "height": 1,
                             "mime_type": "image/jpeg"]
        XCTAssertNil(BotAPIMessage.parse(latestJSON: try raw(badPhoto),
                                         authorization: botAPIAuthorization))
    }

    func testBadBotAPIKeyboardDropsOnlyButtonsNeverTheMessage() throws {
        let base: [String: Any] = [
            "version": "io.atum.bot_api/1",
            "bot_id": "00000000-0000-4000-8000-f6222a1106ee",
            "public_message_id": 8,
            "fallback_text": "Still visible",
        ]
        func parse(_ keyboard: Any) throws -> BotAPIMessage? {
            var metadata = base
            metadata["keyboard"] = keyboard
            let content: [String: Any] = [
                "msgtype": "m.text",
                "body": "Still visible",
                "format": "org.matrix.custom.html",
                "formatted_body": "Still <strong>visible</strong>",
                "io.atum.bot_api": metadata,
            ]
            let raw = try JSONSerialization.data(
                withJSONObject: ["sender": botUserID, "content": content], options: [.sortedKeys]
            )
            return BotAPIMessage.parse(latestJSON: String(decoding: raw, as: UTF8.self),
                                       authorization: botAPIAuthorization)
        }

        for malformed in [
            [["not-a-row"]] as Any,
            [[[
                "label": "Callback", "kind": "callback", "url": "https://moon.example",
            ]]] as Any,
            [[[
                "label": "Insecure", "kind": "url", "url": "http://moon.example",
            ]]] as Any,
            [Array(repeating: ["label": "Too many", "kind": "url",
                               "url": "https://moon.example"], count: 5)] as Any,
        ] {
            let message = try XCTUnwrap(parse(malformed))
            XCTAssertNil(message.keyboard)
            XCTAssertEqual(message.fallbackText, "Still visible")
            XCTAssertEqual(message.formattedBody, "Still <strong>visible</strong>")
        }
    }

    func testNoticeButtonsKeepOnlyNewestActionFamily() {
        let older = AppBotNoticeButtons.Notice(id: "old", message: .init(code: .needsSetup, action: .openSetup(app: appSlug)))
        let latest = AppBotNoticeButtons.Notice(id: "new", message: .init(code: .needsIntake, action: .openSetup(app: appSlug)))
        let route = AppBotNoticeButtons.Notice(id: "route", message: .init(code: .busy, action: .openAppRoute(app: appSlug, routeID: "readings")))
        let context = AppBotNoticeButtons.Context(currentRoomID: "!current", botIsSetUp: false,
                                                  purchaseRouteID: "top_up", botRoomIDByApp: [:])
        XCTAssertEqual(AppBotNoticeButtons.actions(for: [older, latest, route], context: context),
                       ["new": .openSetup(app: appSlug), "route": .openAppRoute(app: appSlug, routeID: "readings")])
    }

    func testNoticeButtonsHideCompletedSetupAndDoNotResurrectOlderNotice() {
        let older = AppBotNoticeButtons.Notice(id: "old", message: .init(code: .needsSetup, action: .openSetup(app: appSlug)))
        let latest = AppBotNoticeButtons.Notice(id: "new", message: .init(code: .needsIntake, action: .openSetup(app: appSlug)))
        let context = AppBotNoticeButtons.Context(currentRoomID: "!current", botIsSetUp: true,
                                                  purchaseRouteID: nil, botRoomIDByApp: [:])
        XCTAssertTrue(AppBotNoticeButtons.actions(for: [older, latest], context: context).isEmpty)
    }

    func testNoticeButtonsHideAllowancePurchaseSelfTargetAndMissingCatalog() {
        let allowance = AppBotNoticeButtons.Notice(id: "allowance", message: .init(code: .allowanceExhausted,
                                                                                       action: .openSetup(app: appSlug)))
        let purchase = AppBotNoticeButtons.Notice(id: "purchase", message: .init(code: .busy,
                                                                                     action: .openAppRoute(app: appSlug, routeID: "top_up")))
        let selfTarget = AppBotNoticeButtons.Notice(id: "self", message: .init(code: .busy,
                                                                                   action: .openBotDM(app: appSlug)))
        let context = AppBotNoticeButtons.Context(currentRoomID: "!moon", botIsSetUp: false,
                                                  purchaseRouteID: "top_up", botRoomIDByApp: [appSlug: "!moon"])
        XCTAssertTrue(AppBotNoticeButtons.actions(for: [allowance, purchase, selfTarget], context: context).isEmpty)

        let missing = AppBotNoticeButtons.Context(currentRoomID: "!other", botIsSetUp: false,
                                                  purchaseRouteID: nil, botRoomIDByApp: [:])
        XCTAssertTrue(AppBotNoticeButtons.actions(for: [selfTarget], context: missing).isEmpty)
    }

    func testNoticeButtonsExposeCatalogTargetRoom() {
        let notice = AppBotNoticeButtons.Notice(id: "open", message: .init(code: .joined, action: .openBotDM(app: appSlug)))
        let context = AppBotNoticeButtons.Context(currentRoomID: "!group", botIsSetUp: false,
                                                  purchaseRouteID: nil, botRoomIDByApp: [appSlug: "!moon"])
        XCTAssertEqual(AppBotNoticeButtons.actions(for: [notice], context: context), ["open": .openBotDM(app: appSlug)])
    }

    func testAppBrandUsesAccentOnlyWhenOnAccentMeetsContrastThreshold() {
        XCTAssertEqual(AppBrand.resolve(accentHex: "#D8612F"),
                       .init(buttonFill: .accent(hex: "#D8612F", labelHex: "#1B1D22"), avatarRingHex: "#D8612F"))
        XCTAssertEqual(AppBrand.resolve(accentHex: "#5a9b8a"),
                       .init(buttonFill: .accent(hex: "#5A9B8A", labelHex: "#1B1D22"), avatarRingHex: "#5A9B8A"))
        XCTAssertEqual(AppBrand.resolve(accentHex: "#6a4bbc"), .init(buttonFill: .primary, avatarRingHex: nil))
        XCTAssertEqual(AppBrand.resolve(accentHex: nil), .init(buttonFill: .primary, avatarRingHex: nil))
        XCTAssertNil(AppBrand.normalizedHex("#1234"))
        XCTAssertNil(AppBrand.normalizedHex("D8612F"))
        XCTAssertGreaterThanOrEqual(AppBrand.contrastRatio(foregroundHex: "#1B1D22", backgroundHex: "#D8612F")!, 4.5)
        XCTAssertLessThan(AppBrand.contrastRatio(foregroundHex: "#1B1D22", backgroundHex: "#6A4BBC")!, 4.5)
    }
}
