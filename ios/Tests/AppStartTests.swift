import Foundation
import XCTest
@testable import AtumNativeAPI

/// The generic "start a chat" path for a catalog app bot. Every test here uses
/// an app the phone has never heard of (`acme`) and a guest app (`acme`) or a
/// linked one (`globex`): if any of them needed a code change, the plug-and-play
/// promise is broken.
@MainActor
final class AppStartTests: XCTestCase {
    private let acmeAppID = "00000000-0000-4000-8000-f6222a1106ee"
    private let acmeBot = "@app-acme:atumplatform.com"

    // MARK: Fixtures

    private func catalog(slug: String = "acme",
                         appID: String = "00000000-0000-4000-8000-f6222a1106ee",
                         guest: Bool = true,
                         directProfile: String? = "atum.turn-memory/2",
                         botState: String = "active",
                         withDevice: Bool = true,
                         disclosure: Int = 1,
                         availability: String = "available",
                         rosterState: String? = nil,
                         transportMode: Any? = nil) throws -> AppDescriptor {
        var bot: [String: Any] = [
            "v": 1,
            "user_id": "@app-\(slug):atumplatform.com",
            "handle": "\(slug)_bot",
            "display_name": slug.capitalized,
            "avatar": ["url": "https://cdn.atumplatform.com/apps/\(slug).png",
                       "sha256": String(repeating: "b", count: 64)],
            "device_generation": 1,
            "device": withDevice
                ? ["device_id": "ACME.1",
                   "ed25519": String(repeating: "A", count: 43),
                   "curve25519": String(repeating: "B", count: 43)] as Any
                : NSNull(),
            "state": botState,
            "groups": false,
            "consent": "required",
            "disclosure_version": disclosure,
            "open_route_id": "open",
            "open_shared_memory": false,
            "purchase_route_id": "purchase",
        ]
        if let transportMode { bot["transport_mode"] = transportMode }
        if guest { bot["guest_enabled"] = true }
        if let directProfile { bot["direct_profile"] = directProfile }
        var app: [String: Any] = [
            "app": slug,
            "app_id": appID,
            "app_version_id": "00000000-0000-4000-8000-f1d11edf5c5c",
            "name": ["en": slug.capitalized],
            "subtitle": ["en": "Plan with clarity"],
            "description": NSNull(),
            "icon": NSNull(),
            "accent": NSNull(),
            "affiliation": NSNull(),
            "verified": false,
            "availability": availability,
            "roster_default": true,
            "roster_order": 5,
            "supported_modes": ["direct"],
            "has_surface": false,
            "link": ["mode": guest ? "external_account" : "external_account",
                     "state": "never_linked"],
            "bot": bot,
        ]
        if let rosterState {
            app["roster_state"] = rosterState
            app["link"] = ["mode": "none", "state": "never_linked"]
            app["has_surface"] = false
            app["availability"] = "unavailable"
            app["bot"] = NSNull()
        }
        let body = try JSONSerialization.data(
            withJSONObject: ["profile": "atum.app-catalog/1", "apps": [app]],
            options: .sortedKeys
        )
        return try NativeAPI.decode(AppCatalogResponse.self, from: body).apps[0]
    }

    private func status(consent: String = "required", version: Int = 1,
                        link: String = "never_linked", linkReady: Bool = false,
                        guest: (enabled: Bool, state: String)? = (true, "start_required"),
                        roomID: String? = nil) throws -> AppBotSetupStatus {
        var object: [String: Any] = [
            "profile": "atum.app-bot-status/1",
            "bot": NSNull(),
            "consent": consent == "accepted"
                ? ["state": consent, "disclosure_version": version, "locale": "en",
                   "accepted_at": "2026-10-24T01:02:03.000Z"] as [String: Any]
                : ["state": consent, "disclosure_version": version, "locale": NSNull(),
                   "accepted_at": NSNull()] as [String: Any],
            "link": ["state": link, "ready": linkReady, "available": linkReady],
            "room_id": roomID.map { $0 as Any } ?? NSNull(),
        ]
        if let guest { object["guest"] = ["enabled": guest.enabled, "state": guest.state] }
        return try NativeAPI.decode(
            AppBotSetupStatus.self,
            from: JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        )
    }

    // MARK: Policy

    func testAnUnknownAppIsReadAtTheGenericDisclosureOnly() {
        XCTAssertTrue(AppOnboardingPolicy.supports(disclosureVersion: 1, for: "acme"))
        XCTAssertFalse(AppOnboardingPolicy.supports(disclosureVersion: 2, for: "acme"),
                       "a disclosure the phone has no reader for keeps the continue-on-computer handoff")
        XCTAssertFalse(AppOnboardingPolicy.supports(disclosureVersion: 3, for: "acme"))
        // The two contained readers are unchanged.
        XCTAssertTrue(AppOnboardingPolicy.supports(disclosureVersion: 3, for: "moon"))
        XCTAssertFalse(AppOnboardingPolicy.supports(disclosureVersion: 1, for: "moon"))
        XCTAssertTrue(AppOnboardingPolicy.supports(disclosureVersion: 2, for: "andy"))
        XCTAssertFalse(AppOnboardingPolicy.supports(disclosureVersion: 1, for: "andy"))
    }

    func testIntakeIsPinnedForMoonAndAndyAndDeclaredByTheProviderForOthers() throws {
        func intake(_ object: [String: Any]) throws -> AppIntakeStatus {
            try NativeAPI.decode(AppIntakeStatus.self,
                                 from: JSONSerialization.data(withJSONObject: object))
        }
        let complete = try intake(["complete": true, "missing": [], "fields": []])
        let acme = try intake([
            "complete": false, "missing": ["company"],
            "fields": [["name": "company", "type": "text"]],
        ])
        XCTAssertTrue(AppOnboardingPolicy.acceptsIntake(complete, for: "acme"))
        XCTAssertTrue(AppOnboardingPolicy.acceptsIntake(acme, for: "acme"))
        XCTAssertTrue(AppOnboardingPolicy.acceptsIntake(complete, for: "andy"))
        XCTAssertFalse(AppOnboardingPolicy.acceptsIntake(acme, for: "andy"))
        XCTAssertFalse(AppOnboardingPolicy.acceptsIntake(acme, for: "moon"))
        XCTAssertFalse(AppOnboardingPolicy.acceptsIntake(complete, for: "moon"))
    }

    func testTheCatalogGuestFieldsAreReadStrictlyAndNeverGrantByAccident() throws {
        let guest = try XCTUnwrap(catalog().bot)
        XCTAssertTrue(guest.guestEnabled)
        XCTAssertTrue(guest.supportsGuestChat)

        let legacy = try XCTUnwrap(catalog(guest: false, directProfile: nil).bot)
        XCTAssertFalse(legacy.guestEnabled)
        XCTAssertFalse(legacy.supportsGuestChat)

        // The flag without the v2 turn profile is not a guest grant.
        XCTAssertFalse(try XCTUnwrap(catalog(directProfile: nil).bot).supportsGuestChat)
        XCTAssertFalse(try XCTUnwrap(catalog(directProfile: "atum.turn-memory/1").bot).supportsGuestChat)
        // An unknown profile reads as absent instead of failing the whole catalog.
        let unknown = try XCTUnwrap(catalog(directProfile: "atum.turn-memory/9").bot)
        XCTAssertNil(unknown.directProfile)
        XCTAssertFalse(unknown.supportsGuestChat)
    }

    func testTransportModeIsTolerantPerBotAndDefaultsOnlyToLegacy() throws {
        XCTAssertEqual(try XCTUnwrap(catalog(transportMode: "bot_api").bot).transportMode, .botAPI)
        XCTAssertEqual(try XCTUnwrap(catalog(transportMode: "legacy_turn").bot).transportMode, .legacyTurn)
        XCTAssertEqual(try XCTUnwrap(catalog().bot).transportMode, .legacyTurn)
        XCTAssertEqual(try XCTUnwrap(catalog(transportMode: "future_transport").bot).transportMode,
                       .legacyTurn, "a future value must not opt the app into Bot API")
        XCTAssertEqual(try XCTUnwrap(catalog(transportMode: 7).bot).transportMode, .legacyTurn,
                       "one malformed additive field must not fail the containing catalog")
        XCTAssertEqual(try XCTUnwrap(catalog(transportMode: NSNull()).bot).transportMode, .legacyTurn)
    }

    func testTheRowOffersOpenStartOrNothingFromCatalogDataAlone() throws {
        let acme = try catalog()
        XCTAssertEqual(AppStartPolicy.action(for: acme, existingRoomID: nil), .startChat)
        XCTAssertEqual(AppStartPolicy.action(for: acme, existingRoomID: "!r:example.invalid"),
                       .open(roomID: "!r:example.invalid"))

        // A linked app with a published bot starts too.
        let globex = try catalog(slug: "globex", appID: "00000000-0000-4000-8000-fbfe405ca65f",
                                 guest: false, directProfile: nil)
        XCTAssertEqual(AppStartPolicy.action(for: globex, existingRoomID: nil), .startChat)

        let botAPI = try catalog(guest: false, directProfile: nil, disclosure: 99,
                                 transportMode: "bot_api")
        XCTAssertEqual(AppStartPolicy.action(for: botAPI, existingRoomID: nil), .startDirect,
                       "Bot API does not depend on a legacy disclosure reader")
        XCTAssertEqual(AppStartPolicy.action(for: botAPI,
                                             existingRoomID: "!bot-api:example.invalid"),
                       .open(roomID: "!bot-api:example.invalid"))
        XCTAssertNil(AppStartPolicy.mode(for: botAPI, status: try status(guest: nil)),
                     "Bot API must never enter the legacy consent/link mode")

        // Nothing the phone can start.
        for refused in [
            try catalog(botState: "paused"),
            try catalog(botState: "starting", withDevice: false),
            try catalog(botState: "unavailable"),
            try catalog(availability: "unavailable"),
            try catalog(disclosure: 2),
            try catalog(directProfile: nil),
            try catalog(rosterState: "coming_soon"),
        ] {
            XCTAssertEqual(AppStartPolicy.action(for: refused, existingRoomID: nil), .none)
        }
    }

    // MARK: Status

    func testTheGuestStatusProjectionDecodesAndKeepsTheDesktopInvariants() throws {
        XCTAssertEqual(try status().guest?.state, .startRequired)
        XCTAssertEqual(try status().guest?.enabled, true)
        XCTAssertNil(try status(guest: nil).guest, "an older platform has no projection")
        XCTAssertEqual(try status(guest: (false, "unsupported")).guest?.state, .unsupported)

        // Enabled iff not unsupported.
        XCTAssertThrowsError(try status(guest: (true, "unsupported")))
        XCTAssertThrowsError(try status(guest: (false, "ready")))
        // A linked guest state needs a ready linked account.
        XCTAssertThrowsError(try status(guest: (true, "linked")))
        XCTAssertNoThrow(try status(link: "linked", linkReady: true, guest: (true, "linked")))
        // A guest-enabled bot with a linked account is only linked or unavailable.
        XCTAssertThrowsError(try status(link: "linked", linkReady: true, guest: (true, "ready")))
        XCTAssertNoThrow(try status(link: "linked", linkReady: true, guest: (true, "unavailable")))
        // An unknown state is not guessed.
        XCTAssertThrowsError(try status(guest: (true, "soon")))
    }

    func testTheEntryModeComesFromTheCatalogAndTheStatus() throws {
        let acme = try catalog()
        XCTAssertEqual(AppStartPolicy.mode(for: acme, status: try status()), .guest)
        XCTAssertEqual(AppStartPolicy.mode(for: acme, status: try status(guest: (true, "ready"))), .guest)
        XCTAssertEqual(AppStartPolicy.mode(for: acme, status: try status(
            link: "linked", linkReady: true, guest: (true, "linked"))), .linked)
        // A guest bot on a platform without the projection is honestly unavailable.
        XCTAssertNil(AppStartPolicy.mode(for: acme, status: try status(guest: nil)))
        XCTAssertNil(AppStartPolicy.mode(for: acme, status: try status(guest: (true, "unavailable"))))
        // A linked-only app is linked whatever the status carries.
        let globex = try catalog(slug: "globex", appID: "00000000-0000-4000-8000-fbfe405ca65f",
                                 guest: false, directProfile: nil)
        XCTAssertEqual(AppStartPolicy.mode(for: globex, status: try status(guest: nil)), .linked)
    }

    func testGuestReadinessStandsOnCurrentConsentAndAReadyUnlinkedState() throws {
        let ready = try status(consent: "accepted", guest: (true, "ready"))
        XCTAssertTrue(AppStartPolicy.guestReady(ready, disclosureVersion: 1))
        XCTAssertFalse(AppStartPolicy.guestReady(ready, disclosureVersion: 2))
        XCTAssertFalse(AppStartPolicy.guestReady(
            try status(consent: "accepted", guest: (true, "start_required")), disclosureVersion: 1))
        XCTAssertFalse(AppStartPolicy.guestReady(
            try status(consent: "required", guest: (true, "ready")), disclosureVersion: 1))
        XCTAssertFalse(AppStartPolicy.guestReady(
            try status(consent: "accepted", guest: nil), disclosureVersion: 1))
    }

    // MARK: The guest start, end to end on scripted ports

    private final class Backend: AppStartBackend {
        var consents = [AppBotConsentRequest]()
        var statusReads = 0
        /// Statuses served after consent, in order; the last repeats.
        var script: [AppBotSetupStatus]
        /// The next this-many status reads throw, as a dropped connection would.
        var failingReads = 0
        init(script: [AppBotSetupStatus]) { self.script = script }
        func appBotStatus(slug: String) async throws -> AppBotSetupStatus {
            statusReads += 1
            if failingReads > 0 { failingReads -= 1; throw StatusDown() }
            return script.count > 1 ? script.removeFirst() : script[0]
        }
        /// A Shell without the route: every start answers route-absent.
        var startCalls = 0
        func startAppBot(slug: String, value: AppBotStartRequest) async throws -> AppBotStartResult {
            startCalls += 1
            return .routeAbsent
        }
        func acceptAppBotConsent(slug: String,
                                 value: AppBotConsentRequest) async throws -> AppBotSetupStatus {
            consents.append(value)
            return script.count > 1 ? script.removeFirst() : script[0]
        }
    }

    private final class Chats: AppBotChatPort {
        var existing: String?
        var creates = [(appID: String, bot: String)]()
        var created: String? = "!acme-dm:example.invalid"
        var opened = [String]()
        var opens = true
        func existingChat(appID: String, botUserID: String) async -> String? { existing }
        func createChat(appID: String, botUserID: String) async -> String? {
            creates.append((appID, botUserID))
            return created
        }
        func open(roomID: String) async -> Bool {
            opened.append(roomID)
            return opens
        }
    }

    private func consent() throws -> AppBotConsentRequest {
        try AppBotConsentRequest(disclosureVersion: 1, locale: .english)
    }

    func testBotAPIDirectStartReusesOrCreatesTheOrdinaryMatrixRoomWithoutABackend() async throws {
        let app = try catalog(guest: false, directProfile: nil, disclosure: 99,
                              transportMode: "bot_api")
        let existing = Chats()
        existing.existing = "!existing:example.invalid"
        let reusedRoomID = try await AppBotDirectStart.run(app: app, chats: existing)
        XCTAssertEqual(reusedRoomID, "!existing:example.invalid")
        XCTAssertTrue(existing.creates.isEmpty)
        XCTAssertTrue(existing.opened.isEmpty, "the resolver already joined and observed the room")

        let fresh = Chats()
        let createdRoomID = try await AppBotDirectStart.run(app: app, chats: fresh)
        XCTAssertEqual(createdRoomID, "!acme-dm:example.invalid")
        XCTAssertEqual(fresh.creates.map(\.appID), [acmeAppID])
        XCTAssertEqual(fresh.creates.map(\.bot), [acmeBot])
        XCTAssertEqual(fresh.opened, ["!acme-dm:example.invalid"])
        // This API has no AppStartBackend parameter: consent, Connect and
        // `/bot/start` are structurally unreachable from the Bot API path.
    }

    func testBotAPIDirectStartRefusesLegacyAndFailedRoomCreation() async throws {
        do {
            _ = try await AppBotDirectStart.run(app: try catalog(), chats: Chats())
            XCTFail("a legacy app cannot use the Bot API bypass")
        } catch let failure as AppStartFailure {
            XCTAssertEqual(failure, .unavailable)
        }

        let app = try catalog(guest: false, directProfile: nil, transportMode: "bot_api")
        let chats = Chats()
        chats.opens = false
        do {
            _ = try await AppBotDirectStart.run(app: app, chats: chats)
            XCTFail("a room that cannot be joined must not be opened")
        } catch let failure as AppStartFailure {
            XCTAssertEqual(failure, .noChat)
        }
    }

    func testGuestStartAcceptsTheDisclosureThenCreatesTheChatOnce() async throws {
        let acme = try catalog()
        // Consent answers start_required; the next read is ready.
        let backend = Backend(script: [
            try status(consent: "accepted", guest: (true, "start_required")),
            try status(consent: "accepted", guest: (true, "ready")),
        ])
        let chats = Chats()
        let roomID = try await AppGuestStart.run(app: acme, consent: try consent(),
                                                 backend: backend, chats: chats,
                                                 retryDelays: [.zero, .zero], sleep: { _ in })
        XCTAssertEqual(roomID, "!acme-dm:example.invalid")
        XCTAssertEqual(backend.consents.map(\.disclosureVersion), [1])
        XCTAssertEqual(backend.statusReads, 1)
        XCTAssertEqual(chats.creates.count, 1)
        XCTAssertEqual(chats.creates.first?.appID, acmeAppID)
        XCTAssertEqual(chats.creates.first?.bot, acmeBot)
    }

    func testGuestStartReusesTheChatThePersonAlreadyHas() async throws {
        let chats = Chats()
        chats.existing = "!old:example.invalid"
        let roomID = try await AppGuestStart.run(
            app: try catalog(), consent: try consent(),
            backend: Backend(script: [try status(consent: "accepted", guest: (true, "ready"))]),
            chats: chats, retryDelays: [], sleep: { _ in }
        )
        XCTAssertEqual(roomID, "!old:example.invalid")
        XCTAssertTrue(chats.creates.isEmpty, "a second room is never made")
    }

    func testGuestStartNeverCreatesAChatWhenThePlatformIsNotReady() async throws {
        let chats = Chats()
        let backend = Backend(script: [try status(consent: "accepted", guest: (true, "start_required"))])
        do {
            _ = try await AppGuestStart.run(app: try catalog(), consent: try consent(),
                                            backend: backend, chats: chats,
                                            retryDelays: [.zero, .zero], sleep: { _ in })
            XCTFail("a guest chat needs a ready platform state")
        } catch let failure as AppStartFailure {
            XCTAssertEqual(failure, .guestNotReady)
        }
        XCTAssertEqual(backend.statusReads, 2)
        XCTAssertTrue(chats.creates.isEmpty)

        // The platform answered for another disclosure version: not ready either.
        let stale = Backend(script: [try status(consent: "accepted", version: 2, guest: (true, "ready"))])
        do {
            _ = try await AppGuestStart.run(app: try catalog(), consent: try consent(),
                                            backend: stale, chats: chats, retryDelays: [],
                                            sleep: { _ in })
            XCTFail("consent to another version is not consent to this one")
        } catch let failure as AppStartFailure {
            XCTAssertEqual(failure, .guestNotReady)
        }
        XCTAssertTrue(chats.creates.isEmpty)
    }

    func testGuestStartReportsAChatThatCouldNotBeMade() async throws {
        let chats = Chats()
        chats.created = nil
        do {
            _ = try await AppGuestStart.run(
                app: try catalog(), consent: try consent(),
                backend: Backend(script: [try status(consent: "accepted", guest: (true, "ready"))]),
                chats: chats, retryDelays: [], sleep: { _ in }
            )
            XCTFail("no room means no chat")
        } catch let failure as AppStartFailure {
            XCTAssertEqual(failure, .noChat)
        }
    }

    func testGuestStartRefusesAnAppThatIsNotAGuestAppBeforeAnyConsent() async throws {
        let backend = Backend(script: [try status(guest: nil)])
        let chats = Chats()
        for app in [
            try catalog(guest: false, directProfile: nil),
            try catalog(botState: "paused"),
        ] {
            do {
                _ = try await AppGuestStart.run(app: app, consent: try consent(), backend: backend,
                                                chats: chats, retryDelays: [], sleep: { _ in })
                XCTFail("not a startable guest app")
            } catch let failure as AppStartFailure {
                XCTAssertEqual(failure, .unavailable)
            }
        }
        XCTAssertTrue(backend.consents.isEmpty, "no disclosure is recorded for a start that cannot happen")
        XCTAssertTrue(chats.creates.isEmpty)
    }

    // MARK: The chat the phone makes matches the desktop's recipe

    func testTheBotChatMarkerAndPointerUseTheDesktopShape() throws {
        let marker = try XCTUnwrap(MobileAppBotRoomPolicy.markerContentJSON(
            appID: acmeAppID, botUserID: acmeBot))
        let markerObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(marker.utf8)) as? [String: Any])
        XCTAssertEqual(markerObject["v"] as? Int, 1)
        XCTAssertEqual(markerObject["app_id"] as? String, acmeAppID)
        XCTAssertEqual(markerObject["bot_user_id"] as? String, acmeBot)
        XCTAssertEqual(MobileAppBotRoomPolicy.markerEventType, "io.atum.app_bot.dm")

        // The pointer the phone writes is the one it reads back.
        let pointer = try XCTUnwrap(MobileAppBotRoomPolicy.pointerContentJSON(
            roomID: "!acme-dm:example.invalid", botUserID: acmeBot))
        XCTAssertEqual(MobileAppBotRoomPolicy.pointerRoomID(contentJSON: pointer, botUserID: acmeBot),
                       "!acme-dm:example.invalid")
        XCTAssertNil(MobileAppBotRoomPolicy.pointerRoomID(
            contentJSON: pointer, botUserID: "@app-other:example.invalid"))
        XCTAssertEqual(MobileAppBotRoomPolicy.pointerEventType(appID: acmeAppID),
                       "io.atum.app_bot.dm." + acmeAppID)
        XCTAssertNil(MobileAppBotRoomPolicy.pointerContentJSON(roomID: "not-a-room", botUserID: acmeBot))
    }

    // MARK: The roster lists a roomless bot the phone can start

    func testARosterDefaultBotAppIsListedBeforeAnyRoomExists() throws {
        let acme = try catalog()
        let entries = MobileAppRosterPolicy.entries(
            from: [acme], shortcuts: [acme.appID: .absent]
        )
        XCTAssertEqual(entries.map(\.app.app), ["acme"])
        XCTAssertEqual(AppStartPolicy.action(for: entries[0].app, existingRoomID: nil), .startChat)
    }

    // MARK: Review round r1

    // MARK: Retry never accepts the disclosure for the person

    /// The loading step of an onboarding attempt, as `LiveAppModel` runs it,
    /// plus what a continuing flow would call. Counts the two calls that must
    /// not happen before the person presses Start.
    private func load(_ gate: inout AppOnboardingGate, backend: Backend,
                      counters: Counters) async -> Bool {
        do {
            _ = try await backend.appBotStatus(slug: "acme")
        } catch {
            gate.failed()
            return false
        }
        let proceed = gate.statusLoaded()
        if proceed {
            // What a continuing attempt does next: the disclosure, then the link.
            _ = try? await backend.acceptAppBotConsent(slug: "acme", value: consent())
            counters.linkBegins += 1
        }
        return proceed
    }

    private final class Counters { var linkBegins = 0 }

    private struct StatusDown: Error {}

    func testRetryAfterAFailedFirstReadReturnsToTheDisclosureAndAcceptsNothing() async throws {
        let backend = Backend(script: [try status(guest: (true, "start_required"))])
        backend.failingReads = 1
        let counters = Counters()
        // A roomless start: the disclosure is shown, nothing is accepted.
        var gate = AppOnboardingGate(automaticallyContinue: false)
        let first = await load(&gate, backend: backend, counters: counters)
        XCTAssertFalse(first)
        XCTAssertEqual(gate.phase, .failed)

        gate = gate.retried()
        let second = await load(&gate, backend: backend, counters: counters)
        XCTAssertFalse(second, "Retry must not continue by itself")
        XCTAssertEqual(gate.phase, .consent, "the sheet shows the disclosure")
        XCTAssertTrue(backend.consents.isEmpty, "no disclosure was recorded")
        XCTAssertEqual(counters.linkBegins, 0, "no provider link was started")
        XCTAssertEqual(backend.startCalls, 0, "no room arbitration before the person agreed")
        XCTAssertFalse(gate.consentStarted)

        // Only the person's own press continues.
        XCTAssertTrue(gate.startPressed())
        XCTAssertEqual(gate.phase, .continuing)
        XCTAssertFalse(gate.startPressed(), "a second press does nothing")
    }

    func testRetryAfterTheyPressedStartResumesAndTheNoticeEntryContinues() async throws {
        var gate = AppOnboardingGate(automaticallyContinue: false)
        XCTAssertFalse(gate.statusLoaded())
        XCTAssertTrue(gate.startPressed())
        gate.failed()
        XCTAssertTrue(gate.retried().consentStarted, "they already agreed: resume for them")

        // The chat notice's own button is the press.
        var notice = AppOnboardingGate(automaticallyContinue: true)
        XCTAssertTrue(notice.statusLoaded())
        XCTAssertEqual(notice.phase, .continuing)
        // A press that was never offered is refused.
        var loading = AppOnboardingGate(automaticallyContinue: false)
        XCTAssertFalse(loading.startPressed())
    }

    // MARK: The status reader ignores additive fields, not authority

    private func statusJSON(_ edit: (inout [String: Any]) -> Void) throws -> AppBotSetupStatus {
        var object: [String: Any] = [
            "profile": "atum.app-bot-status/1", "bot": NSNull(),
            "consent": ["state": "required", "disclosure_version": 1, "locale": NSNull(),
                        "accepted_at": NSNull()],
            "link": ["state": "never_linked", "ready": false, "available": false],
            "room_id": NSNull(),
            "guest": ["enabled": true, "state": "start_required"],
        ]
        edit(&object)
        return try NativeAPI.decode(AppBotSetupStatus.self,
                                    from: JSONSerialization.data(withJSONObject: object))
    }

    func testTheStatusReaderIgnoresUnknownRootAndGuestFields() throws {
        let extra = try statusJSON {
            $0["quota"] = ["remaining": 3]
            $0["future_flag"] = true
            $0["guest"] = ["enabled": true, "state": "ready", "limit": 20, "note": "x"]
        }
        XCTAssertEqual(extra.guest?.state, .ready)
        XCTAssertEqual(extra.consent.state, .required)

        let old = try statusJSON { $0.removeValue(forKey: "guest") }
        XCTAssertNil(old.guest, "an old payload without the projection still reads")
        XCTAssertEqual(old.link.state, .neverLinked)
    }

    func testTheRecognizedAuthorityFieldsStayExact() throws {
        XCTAssertThrowsError(try statusJSON { $0["profile"] = "atum.app-bot-status/2" })
        XCTAssertThrowsError(try statusJSON { $0["guest"] = ["enabled": true, "state": "soon"] })
        XCTAssertThrowsError(try statusJSON { $0["guest"] = ["state": "ready"] })
        XCTAssertThrowsError(try statusJSON { $0["guest"] = ["enabled": "yes", "state": "ready"] })
        XCTAssertThrowsError(try statusJSON { $0["guest"] = ["enabled": true, "state": "unsupported"] })
        XCTAssertThrowsError(try statusJSON { $0["guest"] = NSNull() })
        XCTAssertThrowsError(try statusJSON { $0.removeValue(forKey: "consent") })
        // The invariant against a linked account still holds with extras present.
        XCTAssertThrowsError(try statusJSON {
            $0["guest"] = ["enabled": true, "state": "linked", "extra": 1]
        })
    }

    // MARK: Records of a new chat are written first, with bounded retries

    private final class Records: AppBotChatWriter {
        var calls = [String]()
        var markerFailures: Int
        var pointerFailures: Int
        var markers = [String: String]()
        var pointer: String?
        init(markerFailures: Int = 0, pointerFailures: Int = 0) {
            self.markerFailures = markerFailures
            self.pointerFailures = pointerFailures
        }
        func writeMarker(roomID: String, content: String) async throws {
            calls.append("marker")
            if markerFailures > 0 { markerFailures -= 1; throw StatusDown() }
            markers[roomID] = content
        }
        func writePointer(content: String) async throws {
            calls.append("pointer")
            if pointerFailures > 0 { pointerFailures -= 1; throw StatusDown() }
            pointer = content
        }
    }

    func testAMarkerThatFailsIsRetriedThenTheRecordsAreWrittenInOrder() async throws {
        let records = Records(markerFailures: 2)
        var logs = [String]()
        var pauses = 0
        let outcome = await AppBotChatRecipe.finalize(
            roomID: "!acme-dm:example.invalid", appID: acmeAppID, botUserID: acmeBot,
            writer: records, sleep: { _ in pauses += 1 }, log: { logs.append($0) })
        XCTAssertTrue(outcome.markerWritten)
        XCTAssertEqual(outcome.markerAttempts, 3)
        XCTAssertTrue(outcome.pointerWritten)
        XCTAssertEqual(records.calls, ["marker", "marker", "marker", "pointer"],
                       "the marker is settled before the pointer names the room")
        XCTAssertEqual(pauses, 2)
        XCTAssertTrue(logs.isEmpty, "nothing to report when the records landed")
    }

    func testRecordsThatNeverLandAreBoundedLoggedAndDoNotBlockTheChat() async throws {
        let records = Records(markerFailures: 99, pointerFailures: 99)
        var logs = [String]()
        let outcome = await AppBotChatRecipe.finalize(
            roomID: "!acme-dm:example.invalid", appID: acmeAppID, botUserID: acmeBot,
            writer: records, sleep: { _ in }, log: { logs.append($0) })
        XCTAssertFalse(outcome.markerWritten)
        XCTAssertFalse(outcome.pointerWritten)
        XCTAssertEqual(outcome.markerAttempts, AppBotChatRecipe.attempts)
        XCTAssertEqual(outcome.pointerAttempts, AppBotChatRecipe.attempts)
        XCTAssertEqual(logs, ["marker_write_failed", "pointer_write_failed"],
                       "closed codes only: no room or user ID is logged")
    }

    // MARK: A room another device named is reused

    func testAPointerOnlyCandidateIsJoinedAndReusedBeforeItAppearsInSync() async throws {
        var joined = [String]()
        let room = await AppBotChatResolver.resolve(
            localChoice: nil, pointerRoomID: "!mac-made:example.invalid",
            join: { joined.append($0); return true }, appears: { _ in true })
        XCTAssertEqual(room, "!mac-made:example.invalid")
        XCTAssertEqual(joined, ["!mac-made:example.invalid"])

        // A pointer room that cannot be joined (left) or never shows is not reused.
        let refused = await AppBotChatResolver.resolve(
            localChoice: nil, pointerRoomID: "!left:example.invalid",
            join: { _ in false }, appears: { _ in true })
        XCTAssertNil(refused)
        let absent = await AppBotChatResolver.resolve(
            localChoice: nil, pointerRoomID: "!slow:example.invalid",
            join: { _ in true }, appears: { _ in false })
        XCTAssertNil(absent)
        let none = await AppBotChatResolver.resolve(
            localChoice: nil, pointerRoomID: nil, join: { _ in true }, appears: { _ in true })
        XCTAssertNil(none)
    }

    func testALocalChatWinsOverThePointerAndAnInvitationIsAccepted() async throws {
        var joined = [String]()
        let open = await AppBotChatResolver.resolve(
            localChoice: MobileAppBotChatChoice(roomID: "!here:example.invalid", action: .open,
                                                reason: .pointer),
            pointerRoomID: "!other:example.invalid",
            join: { joined.append($0); return true }, appears: { _ in true })
        XCTAssertEqual(open, "!here:example.invalid")
        XCTAssertTrue(joined.isEmpty)
        let invited = await AppBotChatResolver.resolve(
            localChoice: MobileAppBotChatChoice(roomID: "!invite:example.invalid", action: .join,
                                                reason: .invited),
            pointerRoomID: nil, join: { joined.append($0); return $0 == "!invite:example.invalid" },
            appears: { _ in true })
        XCTAssertEqual(invited, "!invite:example.invalid")
    }

    /// Both devices on one account share the pointer and the marker. Simulated
    /// through those two records only; this proves the phone leaves and reads
    /// the same records, not that two devices can never race.
    private final class SharedAccount: AppBotChatPort {
        let records = Records()
        var joinable = true
        var creates = 0
        let appID: String, bot: String
        init(appID: String, bot: String) { self.appID = appID; self.bot = bot }

        func existingChat(appID: String, botUserID: String) async -> String? {
            await AppBotChatResolver.resolve(
                localChoice: nil,
                pointerRoomID: MobileAppBotRoomPolicy.pointerRoomID(contentJSON: records.pointer,
                                                                    botUserID: botUserID),
                join: { _ in self.joinable }, appears: { _ in true })
        }
        func createChat(appID: String, botUserID: String) async -> String? {
            creates += 1
            let room = "!phone-made-\(creates):example.invalid"
            _ = await AppBotChatRecipe.finalize(roomID: room, appID: appID, botUserID: botUserID,
                                                writer: records, sleep: { _ in }, log: { _ in })
            return room
        }
    }

    func testPhoneFirstLeavesRecordsTheMacReadsAndMacFirstIsReusedByThePhone() async throws {
        let acme = try catalog()
        let ready = Backend(script: [try status(consent: "accepted", guest: (true, "ready"))])

        // Phone first: it makes the room and leaves the marker and the pointer.
        let account = SharedAccount(appID: acmeAppID, bot: acmeBot)
        let made = try await AppGuestStart.run(app: acme, consent: try consent(), backend: ready,
                                               chats: account, retryDelays: [], sleep: { _ in })
        XCTAssertEqual(account.creates, 1)
        let marker = try XCTUnwrap(account.records.markers[made])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(marker.utf8))
                        as? [String: Any])?["bot_user_id"] as? String, acmeBot)
        // The Mac reads the same pointer and chooses the same room.
        let pointed = try XCTUnwrap(MobileAppBotRoomPolicy.pointerRoomID(
            contentJSON: account.records.pointer, botUserID: acmeBot))
        let macChoice = MobileAppBotRoomPolicy.chooseChat(
            pointerRoomID: pointed,
            candidates: [MobileAppBotChatCandidate(roomID: made, membership: .joined,
                                                   isOneToOneWithBot: true, invitedByBot: false,
                                                   encrypted: false, lastMessageAt: 0, lastActiveAt: 1)])
        XCTAssertEqual(macChoice?.roomID, made)

        // A second start on the phone reuses it: no second room.
        let again = try await AppGuestStart.run(app: acme, consent: try consent(), backend: ready,
                                                chats: account, retryDelays: [], sleep: { _ in })
        XCTAssertEqual(again, made)
        XCTAssertEqual(account.creates, 1)

        // Mac first: its pointer is all the phone has, before sync shows the room.
        let macFirst = SharedAccount(appID: acmeAppID, bot: acmeBot)
        macFirst.records.pointer = MobileAppBotRoomPolicy.pointerContentJSON(
            roomID: "!mac-made:example.invalid", botUserID: acmeBot)
        let reused = try await AppGuestStart.run(app: acme, consent: try consent(), backend: ready,
                                                 chats: macFirst, retryDelays: [], sleep: { _ in })
        XCTAssertEqual(reused, "!mac-made:example.invalid")
        XCTAssertEqual(macFirst.creates, 0)
    }

    // MARK: Canonical-room arbitration, on a fake platform and two fake devices

    /// The platform's one decision per person and bot, shared by every device.
    private final class Platform {
        var canonical: String?
        var bot: String
        var unavailable: AppBotStartAnswer.Reason?
        var routeAbsent = false
        var calls = [AppBotStartRequest]()
        init(bot: String) { self.bot = bot }
    }

    /// One phone: a backend onto the shared platform and its own Matrix side.
    private final class Device: AppStartBackend, AppBotChatPort {
        let platform: Platform
        let name: String
        let ready: AppBotSetupStatus
        var held: String?
        var rooms = Set<String>()
        var created = [String](), left = [String](), recorded = [String]()
        var events = [String]()
        var transientFailures = 0
        var afterCreate: (() -> Void)?
        var fallbackCreates = 0
        init(_ name: String, platform: Platform, ready: AppBotSetupStatus) {
            self.name = name; self.platform = platform; self.ready = ready
        }

        // Backend
        func appBotStatus(slug: String) async throws -> AppBotSetupStatus { ready }
        func acceptAppBotConsent(slug: String, value: AppBotConsentRequest) async throws -> AppBotSetupStatus {
            events.append("consent")
            return ready
        }
        func startAppBot(slug: String, value: AppBotStartRequest) async throws -> AppBotStartResult {
            await Task.yield()
            events.append("start")
            platform.calls.append(value)
            if transientFailures > 0 { transientFailures -= 1; throw NativeDomainClientFailure.transportUnavailable }
            if platform.routeAbsent { return .routeAbsent }
            if let reason = platform.unavailable { return .answer(.unavailable(reason)) }
            guard let proposed = value.roomID else {
                return .answer(platform.canonical.map { .ready(roomID: $0, botUserID: platform.bot) }
                               ?? .create(botUserID: platform.bot))
            }
            if platform.canonical == nil { platform.canonical = proposed }
            return .answer(.ready(roomID: platform.canonical!, botUserID: platform.bot))
        }

        // Matrix side
        func existingChat(appID: String, botUserID: String) async -> String? { nil }
        func createChat(appID: String, botUserID: String) async -> String? {
            fallbackCreates += 1
            return "!\(name)-fallback:example.invalid"
        }
        func verifiedChat(appID: String, botUserID: String) async -> String? { held }
        func createPlainChat(botUserID: String) async -> String? {
            await Task.yield()
            let id = "!\(name)-\(created.count + 1):example.invalid"
            created.append(id); rooms.insert(id)
            afterCreate?()
            return id
        }
        func writeChatRecords(roomID: String, appID: String, botUserID: String) async {
            recorded.append(roomID)
        }
        func leave(roomID: String) async { left.append(roomID); rooms.remove(roomID) }
        func open(roomID: String) async -> Bool { rooms.insert(roomID); return true }
    }

    private func device(_ name: String, _ platform: Platform) throws -> Device {
        Device(name, platform: platform,
               ready: try status(consent: "accepted", guest: (true, "ready")))
    }

    private func start(_ device: Device, requestID: UUID = UUID()) async throws -> String {
        try await AppGuestStart.run(app: try catalog(), consent: try consent(), backend: device,
                                    chats: device, retryDelays: [], requestID: requestID,
                                    startRetryDelays: [.zero], sleep: { _ in })
    }

    func testReadyOpensTheNamedRoomWithoutCreatingAnything() async throws {
        let platform = Platform(bot: acmeBot)
        platform.canonical = "!mac:example.invalid"
        let phone = try device("phone", platform)
        let room = try await start(phone)
        XCTAssertEqual(room, "!mac:example.invalid")
        XCTAssertTrue(phone.created.isEmpty)
        XCTAssertTrue(phone.rooms.contains(room))
        XCTAssertEqual(platform.calls.count, 1)
        XCTAssertNil(platform.calls[0].roomID)
        XCTAssertEqual(platform.calls[0].appVersion, "00000000-0000-4000-8000-f1d11edf5c5c")
        XCTAssertEqual(phone.events, ["consent", "start"], "the disclosure is accepted first")
    }

    func testAVerifiedLocalChatIsOfferedForAdoption() async throws {
        let platform = Platform(bot: acmeBot)
        let phone = try device("phone", platform)
        phone.held = "!held:example.invalid"
        let room = try await start(phone)
        XCTAssertEqual(room, "!held:example.invalid")
        XCTAssertEqual(platform.calls.first?.roomID, "!held:example.invalid")
        XCTAssertEqual(platform.canonical, "!held:example.invalid")
        XCTAssertTrue(phone.created.isEmpty, "an adopted room is not replaced")
    }

    func testCreateThenReadyKeepsTheRoomAndWritesItsRecordsOnce() async throws {
        let platform = Platform(bot: acmeBot)
        let phone = try device("phone", platform)
        let id = UUID()
        let room = try await start(phone, requestID: id)
        XCTAssertEqual(room, "!phone-1:example.invalid")
        XCTAssertEqual(platform.canonical, room)
        XCTAssertEqual(platform.calls.count, 2)
        XCTAssertEqual(platform.calls.map(\.requestID), [id.uuidString.lowercased(), id.uuidString.lowercased()],
                       "the second call is the same attempt")
        XCTAssertNil(platform.calls[0].roomID)
        XCTAssertEqual(platform.calls[1].roomID, room)
        XCTAssertEqual(phone.recorded, [room])
        XCTAssertTrue(phone.left.isEmpty)
    }

    func testALoserLeavesItsRoomAndOpensTheWinner() async throws {
        let platform = Platform(bot: acmeBot)
        let phone = try device("phone", platform)
        // Another device's room wins while this one is making its own.
        phone.afterCreate = { platform.canonical = "!mac:example.invalid" }
        let room = try await start(phone)
        XCTAssertEqual(room, "!mac:example.invalid")
        XCTAssertEqual(phone.created, ["!phone-1:example.invalid"])
        XCTAssertEqual(phone.left, ["!phone-1:example.invalid"])
        XCTAssertTrue(phone.recorded.isEmpty, "a lost room leaves no records")
        XCTAssertEqual(phone.rooms, ["!mac:example.invalid"])
    }

    func testUnavailableShowsTheReasonAndCreatesNothing() async throws {
        for reason in [AppBotStartAnswer.Reason.appUnavailable, .botUnavailable, .notPublished] {
            let platform = Platform(bot: acmeBot)
            platform.unavailable = reason
            let phone = try device("phone", platform)
            do {
                _ = try await start(phone)
                XCTFail("unavailable must not open a chat")
            } catch let failure as AppStartFailure {
                XCTAssertEqual(failure, .platformUnavailable(reason))
            }
            XCTAssertTrue(phone.created.isEmpty)
            XCTAssertEqual(phone.fallbackCreates, 0, "unavailable is not a reason to create locally")
        }
    }

    func testAnOlderShellWithoutTheRouteFallsBackToLocalResolution() async throws {
        let platform = Platform(bot: acmeBot)
        platform.routeAbsent = true
        let phone = try device("phone", platform)
        let room = try await start(phone)
        XCTAssertEqual(room, "!phone-fallback:example.invalid")
        XCTAssertEqual(phone.fallbackCreates, 1)
        XCTAssertTrue(phone.created.isEmpty, "the arbitration path made nothing")
    }

    func testAnAnswerAboutAnotherBotFailsClosed() async throws {
        let platform = Platform(bot: "@app-other:example.invalid")
        let phone = try device("phone", platform)
        do {
            _ = try await start(phone)
            XCTFail("a different bot is not this app's chat")
        } catch let failure as AppStartFailure {
            XCTAssertEqual(failure, .unavailable)
        }
        XCTAssertTrue(phone.created.isEmpty)
    }

    func testARetriedCallKeepsTheRequestIDAndANewAttemptGetsANewOne() async throws {
        let platform = Platform(bot: acmeBot)
        platform.canonical = "!mac:example.invalid"
        let phone = try device("phone", platform)
        phone.transientFailures = 1
        _ = try await start(phone)
        XCTAssertEqual(platform.calls.count, 2)
        XCTAssertEqual(platform.calls[0].requestID, platform.calls[1].requestID)

        _ = try await start(phone)
        XCTAssertEqual(platform.calls.count, 3)
        XCTAssertNotEqual(platform.calls[2].requestID, platform.calls[0].requestID)
        let id = try XCTUnwrap(UUID(uuidString: platform.calls[2].requestID))
        XCTAssertEqual(id.uuidString.lowercased(), platform.calls[2].requestID)

        // A failure that is not transient is not retried and is not a fallback.
        phone.transientFailures = 0
        platform.calls = []
        let stubborn = ThrowingDevice(platform: platform, ready: phone.ready)
        do {
            _ = try await AppGuestStart.run(app: try catalog(), consent: try consent(),
                                            backend: stubborn, chats: phone, retryDelays: [],
                                            startRetryDelays: [.zero], sleep: { _ in })
            XCTFail("an error from the route must surface")
        } catch is ThrowingDevice.Down {} catch { XCTFail("\(error)") }
        XCTAssertEqual(stubborn.calls, 1)
    }

    private final class ThrowingDevice: AppStartBackend {
        struct Down: Error {}
        let platform: Platform
        let ready: AppBotSetupStatus
        var calls = 0
        init(platform: Platform, ready: AppBotSetupStatus) { self.platform = platform; self.ready = ready }
        func appBotStatus(slug: String) async throws -> AppBotSetupStatus { ready }
        func acceptAppBotConsent(slug: String, value: AppBotConsentRequest) async throws -> AppBotSetupStatus { ready }
        func startAppBot(slug: String, value: AppBotStartRequest) async throws -> AppBotStartResult {
            calls += 1
            throw Down()
        }
    }

    func testTwoDevicesStartingTogetherEndWithOneRoom() async throws {
        for _ in 0..<10 {
            let platform = Platform(bot: acmeBot)
            let phone = try device("phone", platform)
            let mac = try device("mac", platform)
            async let first = start(phone)
            async let second = start(mac)
            let (a, b) = try await (first, second)

            XCTAssertEqual(a, b, "both devices open the same room")
            let made = phone.created + mac.created
            let left = phone.left + mac.left
            XCTAssertEqual(made.count, 2, "both raced to create")
            XCTAssertEqual(made.filter { !left.contains($0) }, [a], "exactly one room survives")
            XCTAssertEqual(left.count, 1, "the loser left its room")
            XCTAssertEqual(phone.recorded + mac.recorded, [a], "only the winner wrote records")
            XCTAssertTrue(phone.rooms.contains(a) && mac.rooms.contains(a))
            XCTAssertEqual(platform.canonical, a)
        }
    }
}
