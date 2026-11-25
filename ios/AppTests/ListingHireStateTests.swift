import AtumChat
@testable import AtumMobile
import AtumNativeAPI
import XCTest

/// W4-E1: hiring the Researcher from the New assistant sheet (desktop PR #100,
/// `listing-hire.tsx` `useListingHire`). The flow's phases, its moves and the
/// request ledger that keeps one hire one hire.
@MainActor final class ListingHireStateTests: XCTestCase {
    private static let owner = "@owner:atum.test"

    private func listing(paid: Bool = false, price: Int64 = 60_000) throws -> OpenAgentListing {
        try OpenAgentListing(listingID: "open/agents/researcher", displayName: "Researcher",
                             title: ["en": "Researcher", "vi": "Nhà nghiên cứu"],
                             summary: ["en": "Finds sources."], glyph: "🔎",
                             seatPriceProtons: price, hireRequired: paid)
    }

    /// A scripted run: answers in order, records what it was asked.
    @MainActor private final class Runs {
        var answers: [ListingHireResult]
        var calls: [(name: String, confirmed: Bool, account: String)] = []
        /// When set, an answer waits until `release()`.
        var held = false
        init(_ answers: [ListingHireResult]) { self.answers = answers }
        func run(_ listing: OpenAgentListing, _ name: String, _ confirmed: Bool,
                 _ account: String) async -> ListingHireResult {
            calls.append((name, confirmed, account))
            while held { await Task.yield() }
            return answers.isEmpty ? .hired : answers.removeFirst()
        }
        func release() { held = false }
    }

    private func settle(_ flow: ListingHireFlow, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<50 where flow.isHiring { await Task.yield() }
        XCTAssertFalse(flow.isHiring, "the hire never answered", file: file, line: line)
    }

    func testAFreeSeatHiresInOnePressWithNoPrice() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.hired])
        flow.pick(try listing(), name: "Researcher", account: Self.owner, run: runs.run)
        XCTAssertEqual(flow.hire?.phase, .hiring)
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .done)
        XCTAssertEqual(runs.calls.count, 1)
        XCTAssertEqual(runs.calls.first?.confirmed, false)
        flow.reset()
        XCTAssertNil(flow.hire)
    }

    func testAThirdAssistantShowsThePriceOnceThenHiresConfirmed() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.hired])
        flow.pick(try listing(paid: true), name: "Researcher", account: Self.owner, run: runs.run)
        XCTAssertEqual(flow.hire?.phase, .confirm(priceProtons: 60_000))
        XCTAssertTrue(runs.calls.isEmpty, "nothing is hired before the price is confirmed")
        flow.confirm()
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .done)
        XCTAssertEqual(runs.calls.map(\.confirmed), [true])
    }

    func testAStaleQuoteLeadsToTheConfirmStepWithThePlatformsPrice() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.refused(.hireRequired(priceProtons: 61_000)), .hired])
        flow.pick(try listing(), name: "Researcher", account: Self.owner, run: runs.run)
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .confirm(priceProtons: 61_000))
        flow.confirm()
        await settle(flow)
        XCTAssertEqual(runs.calls.map(\.confirmed), [false, true])
        XCTAssertEqual(flow.hire?.phase, .done)
    }

    func testRetryReusesTheConfirmationAndFinalRefusalsOfferNoRetry() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.refused(.retry), .hired])
        flow.pick(try listing(paid: true), name: "Researcher", account: Self.owner, run: runs.run)
        flow.confirm()
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .failed(nil))
        flow.retry()
        await settle(flow)
        XCTAssertEqual(runs.calls.map(\.confirmed), [true, true])
        XCTAssertEqual(flow.hire?.phase, .done)

        for (refusal, phase) in [(OpenAgentHireRefusal.name, ListingHirePhase.failed(.name)),
                                 (.limit, .failed(.limit)), (.account, .failed(.account))] {
            let other = ListingHireFlow()
            let refused = Runs([.refused(refusal)])
            other.pick(try listing(), name: "Researcher", account: Self.owner, run: refused.run)
            await settle(other)
            XCTAssertEqual(other.hire?.phase, phase)
            other.retry()
            XCTAssertEqual(refused.calls.count, 1, "a final refusal is never retried")
        }
    }

    func testAShortWalletOffersTopUpThenTheSamePrice() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.refused(.short)])
        flow.pick(try listing(paid: true), name: "Researcher", account: Self.owner, run: runs.run)
        flow.confirm()
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .short(priceProtons: 60_000))
        flow.toppedUp()
        XCTAssertEqual(flow.hire?.phase, .confirm(priceProtons: 60_000))
    }

    func testAHireUnderWayOutlivesTheSheetAndIgnoresBackAndOtherPicks() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.hired])
        flow.pick(try listing(), name: "Researcher", account: Self.owner, run: runs.run)
        flow.sheetClosed()
        flow.reset()
        flow.pick(try listing(paid: true), name: "Researcher 2", account: Self.owner, run: runs.run)
        XCTAssertEqual(flow.hire?.name, "Researcher")
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .done)
        // Closing on any other state lets it go.
        flow.sheetClosed()
        XCTAssertNil(flow.hire)
    }

    func testTheHiredNameIsTheLocalTitleNumberedPastTakenNames() throws {
        let researcher = try listing()
        XCTAssertEqual(ListingAssistantName.name(for: researcher, locale: "vi", others: ["Atum"]), "Nhà nghiên cứu")
        XCTAssertEqual(ListingAssistantName.name(for: researcher, locale: "en", others: ["Atum", "researcher"]),
                       "Researcher 2")
        XCTAssertEqual(ListingAssistantName.name(for: researcher, locale: "ja", others: []), "Researcher")
    }

    func testAPricedSeatFollowsTheStoreSpendGate() {
        XCTAssertFalse(ListingHireGate.allowsPaidHire(priceProtons: 60_000, checkoutOpen: false))
        XCTAssertTrue(ListingHireGate.allowsPaidHire(priceProtons: 60_000, checkoutOpen: true))
        // A required hire with no real quote is unavailable, never "free".
        XCTAssertFalse(ListingHireGate.allowsPaidHire(priceProtons: 0, checkoutOpen: true))
        XCTAssertFalse(ListingHireGate.allowsPaidHire(priceProtons: -1, checkoutOpen: true))
        XCTAssertTrue(ListingHireGate.allowsRequest(confirmed: false, checkoutOpen: false))
        XCTAssertFalse(ListingHireGate.allowsRequest(confirmed: true, checkoutOpen: false))
        XCTAssertTrue(ListingHireGate.allowsRequest(confirmed: true, checkoutOpen: true))
    }

    // MARK: Review fixes (Sol review of 952b5f8)

    /// Finding 1: confirmed while checkout was open, the answer was lost,
    /// checkout closed. The stored confirmation, not only the one given now,
    /// decides: nothing that can spend goes out while checkout is closed.
    func testAConfirmedRequestNeverGoesOutWhileCheckoutIsClosed() {
        let stored = LiveListingHireStore.Pending(requestID: "00000000-0000-4000-8000-000000000001",
                                                  name: "Researcher", hireConfirmed: true)
        var minted = 0
        let mint: () -> String? = { minted += 1; return "00000000-0000-4000-8000-00000000000\(minted + 1)" }
        // Retry (confirmation carried by the flow) and a shelf pick (none
        // given now, the stored one restored): both stop at the gate.
        for confirmedNow in [true, false] {
            XCTAssertEqual(ListingHireRequestPlan.make(earlier: stored, name: "Researcher 2",
                                                       hireConfirmed: confirmedNow, checkoutOpen: false,
                                                       newRequestID: mint), .checkoutClosed)
        }
        XCTAssertEqual(ListingHireRequestPlan.make(earlier: nil, name: "Researcher", hireConfirmed: true,
                                                   checkoutOpen: false, newRequestID: mint), .checkoutClosed)
        XCTAssertEqual(minted, 0, "no request is minted for a hire that can't go out")
        // Open again: the same request, its name and its confirmation.
        XCTAssertEqual(ListingHireRequestPlan.make(earlier: stored, name: "Researcher 2", hireConfirmed: false,
                                                   checkoutOpen: true, newRequestID: mint),
                       .send(stored, fresh: false))
        // An unconfirmed request can't spend, so it goes out either way.
        var unconfirmed = stored
        unconfirmed.hireConfirmed = false
        XCTAssertEqual(ListingHireRequestPlan.make(earlier: unconfirmed, name: "Researcher", hireConfirmed: false,
                                                   checkoutOpen: false, newRequestID: mint),
                       .send(unconfirmed, fresh: false))
        XCTAssertEqual(ListingHireRequestPlan.make(earlier: nil, name: "Researcher", hireConfirmed: false,
                                                   checkoutOpen: false, newRequestID: mint),
                       .send(.init(requestID: "00000000-0000-4000-8000-000000000002", name: "Researcher",
                                   hireConfirmed: false), fresh: true))
    }

    /// Finding 1: the gate's refusal returns to the price, and a price that
    /// isn't positive can never be confirmed.
    func testAClosedGateReturnsToThePriceAndAZeroQuoteCantBeConfirmed() async throws {
        XCTAssertEqual(ListingHireFlow.phase(after: .checkoutClosed, quote: 60_000), .confirm(priceProtons: 60_000))
        let flow = ListingHireFlow()
        let runs = Runs([])
        flow.pick(try listing(paid: true, price: 0), name: "Researcher", account: Self.owner, run: runs.run)
        XCTAssertEqual(flow.hire?.phase, .confirm(priceProtons: 0))
        flow.confirm()
        XCTAssertEqual(flow.hire?.phase, .confirm(priceProtons: 0))
        XCTAssertTrue(runs.calls.isEmpty, "a zero quote was confirmed")
    }

    /// Finding 2: A leaves a paid hire, it fails, B signs in and taps
    /// Retry. The hire belonged to A: it is gone, and nothing runs.
    func testAnAccountChangeLetsTheHireGoSoItsConfirmationNeverReachesAnotherAccount() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.refused(.retry)])
        flow.pick(try listing(paid: true), name: "Researcher", account: Self.owner, run: runs.run)
        flow.confirm()
        await settle(flow)
        flow.sheetClosed()
        XCTAssertNil(flow.hire)
        // Mid-hire too: the late answer for A changes nothing for B.
        let held = Runs([.hired])
        held.held = true
        flow.pick(try listing(paid: true), name: "Researcher", account: Self.owner, run: held.run)
        flow.confirm()
        XCTAssertTrue(flow.isHiring)
        for _ in 0..<10 { await Task.yield() }
        flow.accountChanged(to: "@other:atum.test")
        XCTAssertNil(flow.hire, "the old account's hire survived the account change")
        held.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(flow.hire)
        flow.retry()
        flow.confirm()
        XCTAssertEqual(runs.calls.map(\.account), [Self.owner])
        XCTAssertEqual(held.calls.map(\.account), [Self.owner])
        // The same account signing in again keeps a hire that is its own.
        flow.pick(try listing(paid: true), name: "Researcher", account: "@other:atum.test", run: runs.run)
        flow.accountChanged(to: "@other:atum.test")
        XCTAssertNotNil(flow.hire)
        flow.accountChanged(to: nil)
        XCTAssertNil(flow.hire)
    }

    /// Finding 2: the ledger is keyed by the account's full digest, never
    /// the 32-bit log fingerprint.
    func testTheLedgerKeyIsTheAccountsFullDigest() {
        let name = LiveListingHireStore.fileName(matrixUserID: Self.owner)
        XCTAssertTrue(name.hasSuffix(".json"))
        let digest = String(name.dropLast(".json".count))
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(digest, LiveFlowLog.fingerprint(Self.owner))
        XCTAssertNotEqual(name, LiveListingHireStore.fileName(matrixUserID: "@other:atum.test"))
    }

    /// Finding 4: a hire placed as `capacity` waits for its chat instead of
    /// saying it is in the chats, then reads done once the chat opens.
    func testAHireWhoseChatIsntOpenYetIsSettingUpUntilItOpens() async throws {
        let id = try NativeID("6f1c1d8e-3b5a-4c2e-9a7d-1e2f3a4b5c6d")
        let flow = ListingHireFlow()
        let runs = Runs([.settingUp(assistantID: id)])
        flow.pick(try listing(), name: "Researcher", account: Self.owner, run: runs.run)
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .settingUp(assistantID: id))
        flow.retry()
        XCTAssertEqual(runs.calls.count, 1, "a hire that is made is never sent again")
        flow.chatAvailable()
        XCTAssertEqual(flow.hire?.phase, .done)
        flow.chatAvailable()
        XCTAssertEqual(flow.hire?.phase, .done)
    }

    /// Finding 5: desktop's collision rules, by the platform's name key and
    /// the catalog's app names.
    func testTheHiredNameStepsPastLookAlikesAndAppNames() throws {
        let researcher = try listing()
        XCTAssertEqual(ListingAssistantName.name(for: researcher, locale: "en", others: ["Re-searcher"]),
                       "Researcher 2")
        XCTAssertEqual(ListingAssistantName.name(for: researcher, locale: "en", others: ["Researcher 🔎"]),
                       "Researcher 2")
        XCTAssertEqual(ListingAssistantName.name(for: researcher, locale: "en",
                                                 others: ["Researcher", "Researcher 2", "Re searcher 3"]),
                       "Researcher 4")
        XCTAssertEqual(ListingAssistantName.name(for: researcher, locale: "vi", others: ["Nhà Nghiên-cứu"]),
                       "Nhà nghiên cứu 2")
        // Accents count: another Vietnamese name is not a duplicate.
        XCTAssertEqual(ListingAssistantName.name(for: researcher, locale: "vi", others: ["Nha nghien cuu"]),
                       "Nhà nghiên cứu")
        // An app's name is never a hired assistant's, the catalog name
        // included: nothing valid is nil, and nothing is sent (r2 finding 6).
        XCTAssertNil(ListingAssistantName.name(for: researcher, locale: "en", others: [],
                                               apps: ["Research er"]))
        XCTAssertEqual(ListingAssistantName.name(for: researcher, locale: "vi", others: [],
                                                 apps: ["Researcher"]), "Nhà nghiên cứu")
    }

    private func ledgerDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ListingHireStateTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheRequestLedgerKeepsOneRequestPerListingUntilItsOwnAnswerClearsIt() throws {
        let directory = try ledgerDirectory()
        let store = LiveListingHireStore(matrixUserID: Self.owner, directory: directory)
        let id = "open/agents/researcher"
        XCTAssertNil(try store.pending(id), "no file is an empty ledger")
        try store.save(.init(requestID: "00000000-0000-4000-8000-000000000001", name: "Researcher",
                             hireConfirmed: false), for: id)
        var pending = try XCTUnwrap(try store.pending(id))
        pending.hireConfirmed = true
        pending.assistantID = "6f1c1d8e-3b5a-4c2e-9a7d-1e2f3a4b5c6d"
        try store.save(pending, for: id)
        // It survives a relaunch (a new store on the same file).
        XCTAssertEqual(try LiveListingHireStore(matrixUserID: Self.owner, directory: directory).pending(id), pending)
        // Another account never sees it.
        XCTAssertNil(try LiveListingHireStore(matrixUserID: "@other:atum.test", directory: directory).pending(id))
        // Only the request it observed is cleared.
        try store.clear(id, requestID: "00000000-0000-4000-8000-000000000002")
        XCTAssertEqual(try store.pending(id)?.hireConfirmed, true)
        try store.clear(id, requestID: pending.requestID)
        XCTAssertNil(try store.pending(id))
    }

    /// Review r2 finding 2: an unreadable ledger is unknown, never empty, and
    /// a write that fails is reported, so the model mints and sends nothing.
    func testAnUnreadableOrUnwritableLedgerRefusesInsteadOfReadingEmpty() throws {
        let directory = try ledgerDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(LiveListingHireStore.fileName(matrixUserID: Self.owner))
        try Data("not json".utf8).write(to: file)
        let store = LiveListingHireStore(matrixUserID: Self.owner, directory: directory)
        XCTAssertThrowsError(try store.pending("open/agents/researcher"))
        XCTAssertThrowsError(try store.save(.init(requestID: "00000000-0000-4000-8000-000000000001",
                                                  name: "Researcher", hireConfirmed: false),
                                            for: "open/agents/researcher"),
                             "a save over an unreadable ledger would drop its requests")
        XCTAssertEqual(try Data(contentsOf: file), Data("not json".utf8), "the unreadable ledger was overwritten")

        // A ledger path that can't be written (a file where its folder goes).
        let blocked = try ledgerDirectory()
        try Data().write(to: blocked)
        XCTAssertThrowsError(try LiveListingHireStore(matrixUserID: Self.owner, directory: blocked)
            .save(.init(requestID: "00000000-0000-4000-8000-000000000001", name: "Researcher",
                        hireConfirmed: false), for: "open/agents/researcher"))
    }

    /// Review r2 finding 3: a name refusal keeps the request. The next try
    /// sends the same UUID under the name picked then; any other stored
    /// request keeps its own name (the platform refuses a changed one).
    func testANameRefusalKeepsTheRequestAndTheNextTryRenamesIt() {
        var stored = LiveListingHireStore.Pending(requestID: "00000000-0000-4000-8000-000000000001",
                                                  name: "Researcher", hireConfirmed: true)
        var minted = 0
        let mint: () -> String? = { minted += 1; return nil }
        XCTAssertEqual(ListingHireRequestPlan.make(earlier: stored, name: "Researcher 2", hireConfirmed: false,
                                                   checkoutOpen: true, newRequestID: mint),
                       .send(stored, fresh: false))
        stored.nameRefused = true
        XCTAssertEqual(ListingHireRequestPlan.make(earlier: stored, name: "Researcher 2", hireConfirmed: false,
                                                   checkoutOpen: true, newRequestID: mint),
                       .send(.init(requestID: stored.requestID, name: "Researcher 2", hireConfirmed: true),
                             fresh: false))
        XCTAssertEqual(minted, 0, "a refused name minted a new request")
    }

    /// Review r2 finding 5: a closed checkout returns to the price this hire
    /// showed (the platform's quote, not the catalog's), and a `hire_required`
    /// with no usable price never enables Hire: it is a retry, whose
    /// unconfirmed request fetches a fresh quote.
    func testAClosedCheckoutKeepsTheShownQuoteAndAMissingQuoteNeverEnablesHire() async throws {
        let flow = ListingHireFlow()
        let runs = Runs([.refused(.hireRequired(priceProtons: 61_000)), .checkoutClosed,
                         .refused(.hireRequired(priceProtons: nil)), .refused(.hireRequired(priceProtons: 0)),
                         .refused(.hireRequired(priceProtons: 62_000))])
        flow.pick(try listing(), name: "Researcher", account: Self.owner, run: runs.run)
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .confirm(priceProtons: 61_000))
        flow.confirm()
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .confirm(priceProtons: 61_000), "the catalog's 60,000 replaced the quote")

        let unquoted = ListingHireFlow()
        unquoted.pick(try listing(), name: "Researcher", account: Self.owner, run: runs.run)
        await settle(unquoted)
        XCTAssertEqual(unquoted.hire?.phase, .failed(nil))
        unquoted.confirm()
        unquoted.retry()
        await settle(unquoted)
        XCTAssertEqual(unquoted.hire?.phase, .failed(nil), "a zero quote is not a price")
        unquoted.retry()
        await settle(unquoted)
        XCTAssertEqual(unquoted.hire?.phase, .confirm(priceProtons: 62_000))
        XCTAssertEqual(runs.calls.map(\.confirmed), [false, true, false, false, false],
                       "a hire was confirmed without a usable quote")

        // No quote shown at all (a stored confirmation): not available, no Hire.
        XCTAssertEqual(ListingHireFlow.phase(after: .checkoutClosed, quote: nil), .confirm(priceProtons: 0))
        XCTAssertFalse(ListingHireGate.allowsPaidHire(priceProtons: 0, checkoutOpen: true))
    }

    /// Review r2 finding 6: no valid name, the name line, nothing sent.
    func testAListingWithNoValidNameShowsTheNameLineAndSendsNothing() throws {
        let researcher = try listing()
        XCTAssertNil(ListingAssistantName.name(for: researcher, locale: "en", others: [], apps: ["Researcher"]))
        let flow = ListingHireFlow()
        flow.refuseName(researcher, shownAs: researcher.title(locale: "en"), account: Self.owner)
        XCTAssertEqual(flow.hire?.phase, .failed(.name))
        XCTAssertEqual(flow.hire?.name, "Researcher")
        flow.retry()
        flow.confirm()
        XCTAssertEqual(flow.hire?.phase, .failed(.name))
        flow.reset()
        XCTAssertNil(flow.hire)
    }

    /// W4-Z2 (desktop #132): without beta features the Researcher reads
    /// "Coming soon" and a press starts nothing and sends no hire request,
    /// not even the name line. With them the same press hires as today.
    func testWithoutBetaFeaturesAShelfPressStartsNoHireAndSendsNothing() async throws {
        let researcher = try listing()
        let flow = ListingHireFlow()
        let runs = Runs([.hired])
        flow.press(researcher, name: "Researcher", shownAs: "Researcher", account: Self.owner,
                   betaFeatures: false, run: runs.run)
        flow.press(researcher, name: nil, shownAs: "Researcher", account: Self.owner,
                   betaFeatures: false, run: runs.run)
        flow.confirm()
        flow.retry()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(flow.hire)
        XCTAssertTrue(runs.calls.isEmpty, "a hire request went out without beta features")

        flow.press(researcher, name: "Researcher", shownAs: "Researcher", account: Self.owner,
                   betaFeatures: true, run: runs.run)
        XCTAssertEqual(flow.hire?.phase, .hiring)
        await settle(flow)
        XCTAssertEqual(flow.hire?.phase, .done)
        XCTAssertEqual(runs.calls.count, 1)
        flow.reset()
        flow.press(researcher, name: nil, shownAs: "Researcher", account: Self.owner,
                   betaFeatures: true, run: runs.run)
        XCTAssertEqual(flow.hire?.phase, .failed(.name))
        XCTAssertEqual(runs.calls.count, 1)
    }

    /// Review r2 finding 4: Done needs a Home row that opens the hired
    /// assistant's chat. No room yet, or duplicate plain rooms Home won't
    /// choose between, is the waiting row, which can't open.
    func testTheHireIsDoneOnlyWhenHomeOpensItsAssistantsChat() throws {
        let assistant = try NativeID("6f1c1d8e-3b5a-4c2e-9a7d-1e2f3a4b5c6d")
        let bot = "@agent-researcher:atum.test"
        let agents = try NativeAPI.decode(AgentsResponse.self, from: JSONSerialization.data(withJSONObject: [[
            "id": assistant.rawValue, "identity_id": NSNull(), "display_name": "Researcher",
            "slug": NSNull(), "avatar": "", "avatar_url": NSNull(), "is_default": false,
            "lifecycle_revision": 1, "identity_revision": 1, "definition_revision": 1,
            "status": "active", "principal": assistant.rawValue, "matrixUser": bot,
        ] as [String: Any]])).agents
        func room(_ id: String) -> LiveMatrixRoomRow {
            LiveMatrixRoomRow(
                roomID: id, displayName: id, avatarURL: nil, latestText: nil, latestPreviewContent: .none,
                latestSenderID: bot, latestSenderName: nil, latestIsOwn: false, latestIsNotice: false,
                latestSendState: .sent, latestTimestamp: 1_000, unreadCount: 0, notificationCount: 0,
                highlightCount: 0, isMarkedUnread: false, isFavourite: false, isMuted: false, isDirect: true,
                memberUserIDs: [bot], memberCount: 2, roomType: nil, isEncrypted: false)
        }
        func rows(_ rooms: [LiveMatrixRoomRow]) -> [LiveProductRoom] {
            LiveRosterRows.rows(.init(agents: agents, apps: [], rooms: rooms, invites: [], pointers: [:],
                                      hiddenRooms: MobileHiddenRoomLedger(), locale: "en")).rows
        }
        XCTAssertFalse(ListingHireChat.opens(assistant, in: rows([])), "no room yet")
        XCTAssertTrue(ListingHireChat.opens(assistant, in: rows([room("!one:atum.test")])))
        XCTAssertFalse(ListingHireChat.opens(assistant, in: rows([room("!one:atum.test"), room("!two:atum.test")])),
                       "duplicate plain rooms are suppressed by Home")
        XCTAssertFalse(ListingHireChat.opens(assistant, in: rows([room("!one:atum.test")]),
                                             quarantined: { $0 == "!one:atum.test" }))
        XCTAssertFalse(ListingHireChat.opens(try NativeID("00000000-0000-4000-8000-000000000009"),
                                             in: rows([room("!one:atum.test")])))
    }

    func testEveryHireWordIsInThePinnedExportInBothLanguages() throws {
        let copy = try LiveDesign().copy
        for locale in ["en", "vi"] {
            for key in [ListingHireCopy.readyToHire, ListingHireCopy.hire, ListingHireCopy.short,
                        ListingHireCopy.nameRefused, ListingHireCopy.limitRefused, ListingHireCopy.accountRefused,
                        ListingHireCopy.back, ListingHireCopy.retry, ListingHireCopy.done,
                        ListingHireCopy.purchasesClosed, ListingHireCopy.newAssistant,
                        "src.matrix.roster-create-copy.copies.createAssistant"] {
                XCTAssertFalse(try copy.text(key, locale: locale, arguments: []).isEmpty, key)
            }
            for key in [ListingHireCopy.price, ListingHireCopy.hiring, ListingHireCopy.hired, ListingHireCopy.failed,
                        ListingHireCopy.settingUp] {
                XCTAssertTrue(try copy.text(key, locale: locale, arguments: [.text("X")]).contains("X"), key)
            }
        }
        XCTAssertEqual(try copy.text(ListingHireCopy.price, locale: "en",
                                     arguments: [.text(ProtonAmountFormat.price(60_000_000_000, locale: "en"))]),
                       "60,000 Protons/month")
        XCTAssertEqual(try copy.text(ListingHireCopy.price, locale: "vi",
                                     arguments: [.text(ProtonAmountFormat.price(60_000_000_000, locale: "vi"))]),
                       "60.000 Proton/tháng")
    }
}
