import AtumChat
import AtumDesign
import Foundation
import XCTest
@testable import AtumNativeAPI

/// W4-E6: the account's connections (`atum.account-connections/1`) as the
/// phone reads and draws them, ported from the desktop's `view.ts` and its
/// tests (`apps/desktop/src/app/connections/view.test.ts`, #106).
final class AccountConnectionsTests: XCTestCase {
    /// The desktop's typed example (`ACCOUNT_CONNECTIONS_FIXTURE`), on the wire.
    static let fixture = Data("""
    {"profile":"atum.account-connections/1","connections":[
      {"id":"codex","kind":"plan","provider":"codex","custody":"device","status":"connected",
       "devices":[{"deviceServiceId":"11111111-1111-4111-8111-11111111abcd","displayName":"MacBook Pro","status":"connected","observedAt":1795000000000}],
       "models":[{"id":"gpt-6","displayName":"GPT-6"},{"id":"gpt-6-mini","displayName":"GPT-6 mini"}],
       "reach":{"chat":"relay","work":"native","agents":"all"}},
      {"id":"claude","kind":"plan","provider":"claude","custody":"device","status":"connected",
       "devices":[{"deviceServiceId":"22222222-2222-4222-8222-22222222abcd","displayName":"Mac mini","status":"stale","observedAt":1794900000000}],
       "models":[{"id":"claude-sonnet-5-5","displayName":"Claude Sonnet 5.5"}],
       "reach":{"chat":"relay","work":"native","agents":"all"}},
      {"id":"antigravity","kind":"plan","provider":"antigravity","custody":"device","status":"not_connected",
       "devices":[],"models":[],"reach":{"chat":"none","work":"none","agents":"all"}},
      {"id":"opencode_go","kind":"apiKey","provider":"opencode_go","custody":"cloud","status":"not_connected","reach":{"chat":"direct","work":"none","agents":"all"}},
      {"id":"google","kind":"integration","provider":"google","custody":"cloud","status":"connected","reach":{"chat":"direct","work":"none","agents":"all"}},
      {"id":"owner_chats","kind":"tools","provider":"owner_chats","custody":"cloud","status":"connected","reach":{"chat":"direct","work":"none","agents":"all"}},
      {"id":"home_hub:strap","kind":"tools","provider":"home_hub:strap","custody":"cloud","status":"connected","reach":{"chat":"direct","work":"none","agents":"all"}}
    ]}
    """.utf8)

    private func registry(_ data: Data = fixture) throws -> AccountConnections {
        try NativeAPI.decode(AccountConnections.self, from: data)
    }

    /// The fixture with one substring replaced, for the strictness cases.
    private func mutated(_ from: String, _ to: String) -> Data {
        let text = String(decoding: Self.fixture, as: UTF8.self)
        precondition(text.contains(from), from)
        return Data(text.replacingOccurrences(of: from, with: to).utf8)
    }

    // MARK: The contract

    func testTheDesktopsFixtureDecodes() throws {
        let value = try registry()
        XCTAssertEqual(value.connections.map(\.id),
                       ["codex", "claude", "antigravity", "opencode_go", "google", "owner_chats", "home_hub:strap"])
        XCTAssertEqual(value.connections[1].devices.first?.stale, true)
        XCTAssertEqual(value.connections[0].plan, .codex)
        XCTAssertNil(value.connections[3].plan)
    }

    func testClaudeRegistryAndPickerIDsResolveToTheSamePlan() throws {
        for alias in [Self.fixture, mutated(#""claude""#, #""claude-plan""#),
                      mutated(#""id":"claude""#, #""id":"claude-plan""#)] {
            let value = try registry(alias)
            XCTAssertEqual(value.connections[1].plan, .claude)
            XCTAssertEqual(AccountConnectionsView.planRow(value, .claude).state, .stale)
        }
        XCTAssertEqual(AccountPlan.claude.pickerID, "claude-plan")
        XCTAssertEqual(AccountPlan.claude.rawValue, "claude")
    }

    func testAnAnswerOutsideTheContractIsNotShownAtAll() {
        let broken: [(String, String)] = [
            (#""profile":"atum.account-connections/1""#, #""profile":"atum.account-connections/2""#),
            (#""provider":"claude""#, #""provider":"codex""#),
            (#""displayName":"Mac mini""#, #""displayName":"an@example.invalid""#),
            (#""status":"stale""#, #""status":"asleep""#),
            (#""custody":"device","status":"not_connected""#, #""custody":"cloud","status":"not_connected""#),
            (#""agents":"all"}},"#, #""agents":"some"}},"#),
            (#""id":"home_hub:strap","kind":"tools","provider":"home_hub:strap""#,
             #""id":"home_hub:Strap","kind":"tools","provider":"home_hub:Strap""#),
            (#""observedAt":1795000000000"#, #""observedAt":1795000000000.5"#),
            (#""models":[],"reach""#, #""models":[],"token":"x","reach""#),
        ]
        for (from, to) in broken {
            XCTAssertThrowsError(try registry(mutated(from, to)), "\(from) → \(to)")
        }
    }

    func testDisplayLabelsUseTheDesktopsUTF16Bounds() throws {
        let deviceLabel = String(repeating: "🚀", count: 64)
        let modelLabel = String(repeating: "🚀", count: 100)
        let deviceField = #""displayName":"MacBook Pro""#
        let modelField = #""displayName":"GPT-6""#
        let deviceAnswer = try registry(mutated(deviceField, #""displayName":"\#(deviceLabel)""#))
        let modelAnswer = try registry(mutated(modelField, #""displayName":"\#(modelLabel)""#))
        XCTAssertEqual(deviceAnswer.connections[0].devices.first?.displayName, deviceLabel)
        XCTAssertEqual(modelAnswer.connections[0].models.first?.displayName, modelLabel)
        XCTAssertThrowsError(try registry(mutated(deviceField, #""displayName":"\#(deviceLabel)a""#)))
        XCTAssertThrowsError(try registry(mutated(modelField, #""displayName":"\#(modelLabel)a""#)))
    }

    func testObservedAtAcceptsIntegralDecimalsWithinTheSafeIntegerRange() throws {
        let field = #""observedAt":1795000000000"#
        let accepted: [(String, Int64)] = [("1.0", 1), ("9007199254740991.0", 9_007_199_254_740_991)]
        for (json, value) in accepted {
            let answer = try registry(mutated(field, #""observedAt":\#(json)"#))
            XCTAssertEqual(answer.connections[0].devices.first?.observedAt, value)
        }
        for json in ["1.5", "-1.0", "9007199254740992.0", "true", #""1.0""#] {
            XCTAssertThrowsError(try registry(mutated(field, #""observedAt":\#(json)"#)), json)
        }
    }

    // MARK: Rows (desktop view.test.ts)

    func testItAlwaysListsTheThreePlansConnectedFirstThenLastSeenThenTheRest() throws {
        XCTAssertEqual(AccountConnectionsView.planRows(try registry()).map { [$0.plan.rawValue, $0.state.rawValue] },
                       [["codex", "connected"], ["claude", "stale"], ["antigravity", "notConnected"]])
        XCTAssertEqual(AccountConnectionsView.planRows(nil).map(\.state), [.notConnected, .notConnected, .notConnected])
        XCTAssertEqual(AccountConnectionsView.planRows(nil).map(\.plan), [.codex, .claude, .antigravity])
    }

    func testNeedsAttentionSortsAfterConnectedAndOffersConnect() throws {
        let value = try registry(mutated(#""provider":"codex","custody":"device","status":"connected""#,
                                         #""provider":"codex","custody":"device","status":"needs_attention""#))
        let rows = AccountConnectionsView.planRows(value)
        XCTAssertEqual(rows.map(\.state), [.needsAttention, .stale, .notConnected])
        XCTAssertEqual(rows.map(\.offersConnect), [true, false, true])
        XCTAssertEqual(AccountConnectionsView.line(rows[0]), .needsAttention)
    }

    func testEachMacIsNamedByItsOwnNameNeverThisMac() throws {
        let value = try registry()
        XCTAssertEqual(AccountConnectionsView.line(AccountConnectionsView.planRow(value, .codex)), .onMacs("MacBook Pro"))
        XCTAssertEqual(AccountConnectionsView.line(AccountConnectionsView.planRow(value, .claude)), .lastSeen("Mac mini"))
        XCTAssertEqual(AccountConnectionsView.line(AccountConnectionsView.planRow(value, .antigravity)), .notConnected)
    }

    func testOnMacsNamesOnlyFreshMacsAndLastSeenNamesThemAll() {
        let fresh = AccountConnectionDevice(deviceServiceID: "a", displayName: "Studio", stale: false, observedAt: 1)
        let asleep = AccountConnectionDevice(deviceServiceID: "b", displayName: "Mac mini", stale: true, observedAt: 1)
        let other = AccountConnectionDevice(deviceServiceID: "c", displayName: "MacBook Air", stale: false, observedAt: 1)
        let mixed = AccountConnections(connections: [
            AccountConnection(id: "claude", kind: .plan, status: .connected, devices: [asleep, fresh, other])])
        let row = AccountConnectionsView.planRow(mixed, .claude)
        XCTAssertEqual(row.macs.map(\.name), ["Studio", "MacBook Air", "Mac mini"])
        XCTAssertEqual(AccountConnectionsView.line(row), .onMacs("Studio, MacBook Air"))
        let allAsleep = AccountConnections(connections: [
            AccountConnection(id: "claude", kind: .plan, status: .connected, devices: [asleep, asleep])])
        XCTAssertEqual(AccountConnectionsView.line(AccountConnectionsView.planRow(allAsleep, .claude)),
                       .lastSeen("Mac mini, Mac mini"))
    }

    func testAPlanWithNoMacLeftReadsNotConnectedWhateverItsStatusSays() {
        let value = AccountConnections(connections: AccountPlan.allCases.map {
            AccountConnection(id: $0.rawValue, kind: .plan, status: .connected,
                              models: [AccountConnectionModel(id: "m", displayName: "M")])
        })
        XCTAssertTrue(AccountConnectionsView.planRows(value).allSatisfy { $0.state == .notConnected && $0.models.isEmpty })
    }

    func testOpenCodeGoIsInTheCloudOnlyOnceConnected() throws {
        XCTAssertFalse(AccountConnectionsView.openCodeGoConnected(try registry()))
        XCTAssertTrue(AccountConnectionsView.openCodeGoConnected(try registry(mutated(
            #""provider":"opencode_go","custody":"cloud","status":"not_connected""#,
            #""provider":"opencode_go","custody":"cloud","status":"connected""#))))
        XCTAssertFalse(AccountConnectionsView.openCodeGoConnected(nil))
    }

    func testDataAndToolsAlwaysListsYourChatsAndTheHomeHubsTheRegistryHas() throws {
        XCTAssertEqual(AccountConnectionsView.toolRows(try registry()),
                       [.ownerChats, .homeHub(id: "home_hub:strap", name: "Strap", connected: true)])
        XCTAssertEqual(AccountConnectionsView.toolRows(nil), [.ownerChats])
        let hubFirst = AccountConnections(connections: [
            AccountConnection(id: "home_hub:situation-hub", kind: .tools, status: .notConnected)])
        XCTAssertEqual(AccountConnectionsView.toolRows(hubFirst),
                       [.ownerChats, .homeHub(id: "home_hub:situation-hub", name: "Situation hub", connected: false)])
        XCTAssertEqual(AccountConnectionsView.homeHubName("home_hub:situation-hub"), "Situation hub")
    }

    func testThePickerOffersConnectOnlyForPlansWithNothingToPick() throws {
        // A last-seen plan keeps its models: an asleep Mac never greys a plan.
        XCTAssertEqual(AccountConnectionsView.pickerConnectPlans(try registry()), [.antigravity])
        XCTAssertEqual(AccountConnectionsView.planRow(try registry(), .claude).models.map(\.id), ["claude-sonnet-5-5"])
    }

    func testTheConnectSheetLandsOnlyOnAFreshMac() throws {
        let value = try registry()
        XCTAssertTrue(AccountConnectionsView.connectLanded(value, plan: .codex))
        XCTAssertFalse(AccountConnectionsView.connectLanded(value, plan: .claude))
        XCTAssertFalse(AccountConnectionsView.connectLanded(value, plan: .antigravity))
        XCTAssertFalse(AccountConnectionsView.connectLanded(nil, plan: .codex))
    }

    // MARK: Words, from the pin

    private func text(_ copy: AtumCopy, _ phrase: AccountConnectionsCopy.Phrase, _ locale: String) throws -> String {
        try copy.text(phrase.key, locale: locale, arguments: phrase.arguments.map { .text($0) })
    }

    func testEveryLineAndSheetWordResolvesInEveryLocale() throws {
        let copy = try AtumCopy()
        let lines: [AccountPlanLine] = [.onMacs("Mac mini"), .lastSeen("Mac mini"), .needsAttention, .notConnected]
        var phrases = lines.map(AccountConnectionsCopy.line)
        for plan in AccountPlan.allCases {
            phrases += [AccountConnectionsCopy.sheetTitle(plan), AccountConnectionsCopy.done(plan),
                        AccountConnectionsCopy.pickerUse(plan)]
        }
        phrases += [AccountConnectionsCopy.subscriptions, AccountConnectionsCopy.dataAndTools,
                    AccountConnectionsCopy.inCloud, AccountConnectionsCopy.connect,
                    AccountConnectionsCopy.ownerChatsTitle, AccountConnectionsCopy.ownerChatsLine,
                    AccountConnectionsCopy.homeToolsLine, AccountConnectionsCopy.needsMac,
                    AccountConnectionsCopy.close, AccountConnectionsCopy.tryAgain, AccountConnectionsCopy.readFailed]
        for locale in copy.locales {
            for phrase in phrases {
                let value = try text(copy, phrase, locale)
                XCTAssertFalse(value.isEmpty, "\(locale) \(phrase.key)")
                XCTAssertFalse(value.contains("%"), "\(locale) \(phrase.key): \(value)")
            }
        }
    }

    func testTheDesktopsEnglishAndVietnameseWords() throws {
        let copy = try AtumCopy()
        let value = try registry()
        let line = { (plan: AccountPlan, locale: String) in
            try self.text(copy, AccountConnectionsCopy.line(AccountConnectionsView.line(
                AccountConnectionsView.planRow(value, plan))), locale)
        }
        XCTAssertEqual(try line(.codex, "en"), "On MacBook Pro")
        XCTAssertEqual(try line(.claude, "en"), "Last seen on Mac mini")
        XCTAssertEqual(try line(.antigravity, "vi"), "Chưa kết nối")
        XCTAssertEqual(try line(.codex, "vi"), "Trên MacBook Pro")
        XCTAssertEqual(try text(copy, AccountConnectionsCopy.sheetTitle(.claude), "en"), "Connect Claude")
        XCTAssertEqual(try text(copy, AccountConnectionsCopy.done(.codex), "en"), "ChatGPT is connected")
        XCTAssertEqual(try text(copy, AccountConnectionsCopy.pickerUse(.antigravity), "vi"), "Dùng gói Antigravity của bạn")
        XCTAssertEqual(try text(copy, AccountConnectionsCopy.needsMac, "en"), "Open Atum on your Mac to connect.")
    }

    func testAPlanKeyTakesOnlyTheChoiceItWasExportedFor() throws {
        let copy = try AtumCopy()
        let key = "src.matrix.mobile-copy.mobileScreensCopy.connections.sheet.title.plan=codex"
        XCTAssertEqual(try copy.text(key, locale: "en", arguments: [.text("codex")]), "Connect ChatGPT")
        XCTAssertThrowsError(try copy.text(key, locale: "en", arguments: [.text("claude")]))
        XCTAssertThrowsError(try copy.text(key, locale: "en", arguments: [.text("gemini")]))
        XCTAssertThrowsError(try copy.text(key, locale: "en"))
    }

    // MARK: Relay turn lines (relay-copy.ts, wave 4b)

    private func resolve(_ copy: AtumCopy, _ phrase: RelayTurnLine.Phrase, _ locale: String) throws -> String {
        var failure: Error?
        let value = phrase.resolve { key, arguments in
            do {
                return try copy.text(key, locale: locale, arguments: arguments.map {
                    switch $0 {
                    case let .text(value): .text(value)
                    case let .number(value): .number(value)
                    case .phrase: .text("")
                    }
                })
            } catch { failure = error; return "" }
        }
        if let failure { throw failure }
        return value
    }

    func testRelayTurnLinesSayTheDesktopsWords() throws {
        let copy = try AtumCopy()
        let line = { (chrome: RelayTurnChrome) -> String? in
            try RelayTurnLine.phrase(chrome, plan: "ChatGPT", model: "Nguyệt Thực").map { try self.resolve(copy, $0, "en") }
        }
        XCTAssertNil(try line(.none))
        XCTAssertEqual(try line(.waiting()), "Waiting for your Mac")
        XCTAssertEqual(try line(.waiting(waitingForAnswer: true)), "Waiting for your answer")
        XCTAssertEqual(try line(.waiting(waitingForAnswer: true, invalidAnswer: true)), "Reply again with a valid answer")
        XCTAssertEqual(try line(.needsOK), "Needs your OK on your Mac")
        XCTAssertEqual(try line(.limit(resetsAt: "14:00")), "ChatGPT limit reached · continues at 14:00")
        XCTAssertEqual(try line(.limit(resetsAt: nil)), "ChatGPT limit reached · continues when it resets")
        XCTAssertEqual(try line(.fallback(.macOff)), "Nguyệt Thực answered · your Mac was off")
        XCTAssertEqual(try line(.fallback(.limit)), "Nguyệt Thực answered · ChatGPT limit reached")
        XCTAssertEqual(try line(.late(finishedAt: "09:12")), "Finished on your Mac at 09:12")
        XCTAssertEqual(try line(.queued), "Waiting for the reply above")
        XCTAssertTrue(RelayTurnChrome.waiting(waitingForAnswer: true).isLive)
        XCTAssertFalse(RelayTurnChrome.late(finishedAt: "09:12").isLive)
    }

    func testEveryRelayLineResolvesInEveryLocale() throws {
        let copy = try AtumCopy()
        let chromes: [RelayTurnChrome] = [
            .waiting(), .waiting(waitingForAnswer: true), .waiting(waitingForAnswer: true, invalidAnswer: true),
            .needsOK, .limit(resetsAt: "14:00"), .limit(resetsAt: nil), .stopping, .stopped, .queued,
            .late(finishedAt: "09:12"), .empty, .failed,
        ] + ([.macOff, .consentOff, .switchOff, .limit, .other] as [RelayTurnChrome.FallbackReason])
            .map(RelayTurnChrome.fallback)
        for locale in copy.locales {
            for chrome in chromes {
                let phrase = try XCTUnwrap(RelayTurnLine.phrase(chrome, plan: "Claude", model: "Nguyệt Thực"))
                XCTAssertFalse(try resolve(copy, phrase, locale).isEmpty, "\(locale) \(chrome)")
            }
        }
    }

    func testTheUsagePhraseAndItsScheduledRuns() throws {
        let copy = try AtumCopy()
        let usage = { (value: RelayTurnLine.Usage, runs: Int64?) -> String in
            try RelayTurnLine.usage(value, scheduledRuns: runs).map { try self.resolve(copy, $0, "en") }
                .joined(separator: " · ")
        }
        XCTAssertEqual(try usage(.used(percent: 42, resetsAt: "Mon 9:00"), nil), "42% used · resets Mon 9:00")
        XCTAssertEqual(try usage(.used(percent: 140, resetsAt: nil), nil), "100% used")
        XCTAssertEqual(try usage(.limit(resetsAt: nil), 3), "Limit reached · 3 scheduled runs")
        // Desktop's own English for one run.
        XCTAssertEqual(try usage(.unknown, 1), "Usage not reported · 1 scheduled runs")
        XCTAssertEqual(try usage(.unknown, 0), "Usage not reported · 0 scheduled runs")
        XCTAssertEqual(try RelayTurnLine.usage(.unknown, scheduledRuns: 2).map { try resolve(copy, $0, "vi") }.last,
                       "2 lượt chạy theo lịch")
    }
}

/// The read is the desktop's own request on the existing device-services
/// transport: a POST of exactly `{"operation":"account_connections_read"}`.
@MainActor final class AccountConnectionsTransportTests: XCTestCase {
    func testTheReadPostsTheDesktopsOperationAndDecodesTheRegistry() async throws {
        let client = NativeDomainClient(testAuthorization: { _ in "native-token" },
                                        protocolClasses: [AccountConnectionsProtocol.self])
        AccountConnectionsProtocol.answer = (200, AccountConnectionsTests.fixture)
        let value = try await client.accountConnections()
        XCTAssertEqual(value.connections.count, 7)
        let seen = try XCTUnwrap(AccountConnectionsProtocol.seen)
        XCTAssertEqual(seen.method, "POST")
        XCTAssertEqual(seen.path, "/api/matrix/v1/device-services")
        XCTAssertEqual(seen.authorization, "Bearer native-token")
        XCTAssertEqual(seen.body, AccountConnectionsContract.requestBody)
        XCTAssertNil(seen.version, "a POST carries no device-service version header")

        AccountConnectionsProtocol.answer = (200, Data(#"{"profile":"atum.account-connections/1","connections":[{"id":"x"}]}"#.utf8))
        do { _ = try await client.accountConnections(); XCTFail("an unreadable registry was shown") }
        catch {}
        AccountConnectionsProtocol.answer = (503, Data(#"{"error":"matrix_503"}"#.utf8))
        do { _ = try await client.accountConnections(); XCTFail("a 503 was read as an answer") }
        catch {}
    }

    /// The connect sheet's poll can run as the app suspends, so it must never
    /// start the one-time token spend: no refresh of an expired bearer, no
    /// 401 replay, no authentication-failure report. The foreground read,
    /// the control, still refreshes once on a 401.
    func testAPollNeverRefreshesOrReplaysA401() async throws {
        let probe = PollProbe()
        let client = NativeDomainClient(
            testAuthorization: { forceRefresh in
                probe.refreshes.append(forceRefresh)
                return forceRefresh ? "refreshed-token" : "rotating-token"
            },
            protocolClasses: [AccountConnectionsProtocol.self],
            testStoredAuthorization: { probe.stored },
            onAuthenticationFailure: { _ in probe.failures += 1 })

        // A valid stored bearer: one request with it, and the registry.
        AccountConnectionsProtocol.reset(answers: [(200, AccountConnectionsTests.fixture)])
        let value = try await client.accountConnections(.poll)
        XCTAssertEqual(value.connections.count, 7)
        XCTAssertEqual(AccountConnectionsProtocol.requests, 1)
        XCTAssertEqual(AccountConnectionsProtocol.seen?.authorization, "Bearer stored-token")

        // A 401 is final: one request, no refresh, no replay, no report.
        AccountConnectionsProtocol.reset(answers: [(401, Data(#"{"error":"matrix_401"}"#.utf8)),
                                                   (200, AccountConnectionsTests.fixture)])
        do { _ = try await client.accountConnections(.poll); XCTFail("a 401 poll was replayed into an answer") }
        catch { XCTAssertEqual(error as? NativeDomainClientFailure, .authenticationRefused) }
        XCTAssertEqual(AccountConnectionsProtocol.requests, 1, "a poll never replays a 401")

        // A bearer that would need a refresh: no request at all.
        probe.stored = nil
        AccountConnectionsProtocol.reset(answers: [(200, AccountConnectionsTests.fixture)])
        do { _ = try await client.accountConnections(.poll); XCTFail("a poll ran without a stored bearer") }
        catch { XCTAssertEqual(error as? NativeDomainClientFailure, .authenticationRefused) }
        XCTAssertEqual(AccountConnectionsProtocol.requests, 0)

        XCTAssertEqual(probe.refreshes, [], "a poll never asks the grant for a bearer, let alone a refresh")
        XCTAssertEqual(probe.failures, 0, "a poll reports no authentication failure")

        // Control: the foreground read refreshes once on a 401 and replays.
        AccountConnectionsProtocol.reset(answers: [(401, Data(#"{"error":"matrix_401"}"#.utf8)),
                                                   (200, AccountConnectionsTests.fixture)])
        _ = try await client.accountConnections()
        XCTAssertEqual(probe.refreshes, [false, true])
        XCTAssertEqual(AccountConnectionsProtocol.requests, 2)
        XCTAssertEqual(AccountConnectionsProtocol.seen?.authorization, "Bearer refreshed-token")
    }
}

@MainActor private final class PollProbe {
    var refreshes: [Bool] = []
    var failures = 0
    var stored: String? = "stored-token"
}

private final class AccountConnectionsProtocol: URLProtocol, @unchecked Sendable {
    struct Seen { let method: String; let path: String; let authorization: String?; let body: Data?; let version: String? }
    nonisolated(unsafe) static var seen: Seen?
    nonisolated(unsafe) static var answer: (Int, Data) = (200, Data())
    /// Answered in order before `answer`; `requests` counts every request.
    nonisolated(unsafe) static var answers: [(Int, Data)] = []
    nonisolated(unsafe) static var requests = 0

    static func reset(answers: [(Int, Data)]) {
        self.answers = answers
        requests = 0
        seen = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen = Seen(method: request.httpMethod ?? "", path: request.url?.path ?? "",
                         authorization: request.value(forHTTPHeaderField: "Authorization"),
                         body: Self.body(of: request),
                         version: request.value(forHTTPHeaderField: "Atum-Device-Service-Version"))
        Self.requests += 1
        let (status, data) = Self.answers.isEmpty ? Self.answer : Self.answers.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                              headerFields: ["Content-Type": "application/json"])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            result.append(bytes, count: count)
        }
        return result
    }
}
