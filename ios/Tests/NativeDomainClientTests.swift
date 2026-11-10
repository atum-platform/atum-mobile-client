import Foundation
import XCTest
@testable import AtumNativeAPI
import AtumPrototype
import AtumChat

@MainActor final class NativeDomainClientTests: XCTestCase {
    override func tearDown() {
        NativeDomainProtocol.state.reset()
        super.tearDown()
    }

    private func fixtures() throws -> NativeAPIFixtures { try NativeAPIFixtures() }

    private func client(_ authorization: TestAuthorization) -> NativeDomainClient {
        NativeDomainClient(testAuthorization: { forceRefresh in
            try authorization.token(forceRefresh: forceRefresh)
        }, protocolClasses: [NativeDomainProtocol.self])
    }

    private func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(bytes, count: count)
        }
        return result
    }

    private func appCatalogBody() -> Data {
        Data("""
        {
          "profile":"atum.app-catalog/1",
          "apps":[{
            "app":"moon",
            "app_id":"00000000-0000-4000-8000-bd7662a5eeb4",
            "app_version_id":"00000000-0000-4000-8000-b454f82c5857",
            "name":{"en":"Moon"},
            "subtitle":{"en":"Plan with clarity"},
            "description":null,
            "icon":{"url":"https://cdn.atumplatform.com/apps/moon.png","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
            "accent":"#AABBCC",
            "affiliation":"first_party",
            "verified":true,
            "verification":"official",
            "availability":"available",
            "roster_default":true,
            "roster_order":0,
            "supported_modes":["direct","shared_group"],
            "matrix_room_context":"addressed_only",
            "has_surface":true,
            "link":{"mode":"none","state":"never_linked"},
            "bot":{
              "v":1,
              "user_id":"@app-moon:atumplatform.com",
              "handle":"moon_bot",
              "display_name":"Moon",
              "avatar":{"url":"https://cdn.atumplatform.com/apps/moon-bot.png","sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},
              "device_generation":1,
              "device":{"device_id":"MOON.1","ed25519":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA","curve25519":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"},
              "state":"active",
              "groups":true,
              "consent":"accepted",
              "disclosure_version":1,
              "open_route_id":"open",
              "open_shared_memory":false,
              "purchase_route_id":"purchase"
            }
          }]
        }
        """.utf8)
    }

    private func absentShortcuts(_ apps: [AppDescriptor])
        -> [AppCatalogID: MobileAppShortcutState] {
        Dictionary(uniqueKeysWithValues: apps.map { ($0.appID, .absent) })
    }

    private func rosterCatalog(moonDefault: Bool = true, moonOrder: Int = 0,
                               comingSoonDefault: Bool = true, comingSoonOrder: Int = 6,
                               moonState: Any? = "available") throws -> AppCatalogResponse {
        let body = appCatalogBody()
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        var apps = value["apps"] as! [[String: Any]]
        apps[0]["roster_default"] = moonDefault
        apps[0]["roster_order"] = moonOrder
        if let moonState { apps[0]["roster_state"] = moonState }

        var vneid = apps[0]
        vneid["app"] = "vneid"
        vneid["app_id"] = "00000000-0000-4000-8000-b454f82c5857"
        vneid["app_version_id"] = "00000000-0000-4000-8000-f6222a1106ee"
        vneid["availability"] = "unavailable"
        vneid["roster_default"] = comingSoonDefault
        vneid["roster_order"] = comingSoonOrder
        vneid["roster_state"] = "coming_soon"
        vneid["has_surface"] = false
        vneid["link"] = ["mode": "none", "state": "never_linked"]
        vneid["bot"] = NSNull()
        apps.append(vneid)
        value["apps"] = apps
        return try NativeAPI.decode(
            AppCatalogResponse.self,
            from: JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        )
    }

    private func storeCatalogBody() -> Data {
        Data("""
        {
          "items":[{
            "itemId":"skill/official/decision-journal",
            "kind":"skill",
            "title":{"vi":"Nhật ký quyết định","en":"Decision journal"},
            "summary":{"vi":"Ghi lại quyết định rõ ràng","en":"Make decisions clear"},
            "description":{"vi":"Một kỹ năng riêng tư cho các ghi chú quyết định.","en":"A private skill for decision notes."},
            "tryPrompt":{"vi":"Giúp tôi bắt đầu nhật ký quyết định","en":"Help me start a decision journal"},
            "needs":["matrix"],
            "glyph":"✦",
            "accent":"#AABBCC",
            "featured":true,
            "sortOrder":0,
            "offer":{"id":"00000000-0000-4000-8000-f6222a1106ee","version":1,"priceMicroProtons":0,"scope":"account","billingInterval":"one_time","delivery":"bundled"}
          }]
        }
        """.utf8)
    }

    private let agentID = "00000000-0000-4000-8000-bcd314ea4ab5"
    private let agentPrincipal = "00000000-0000-4000-8000-123671cefaf3"

    private func agentRecord(definitionRevision: Int = 1, identityRevision: Int = 1,
                             matrixUser: Bool = false) -> [String: Any] {
        var value: [String: Any] = [
            "id": agentID,
            "identity_id": "00000000-0000-4000-8000-b29b9b97a5cc",
            "display_name": "Alfred",
            "slug": NSNull(),
            "avatar": "",
            "avatar_url": NSNull(),
            "is_default": false,
            "lifecycle_revision": 1,
            "identity_revision": identityRevision,
            "definition_revision": definitionRevision,
            "status": "active",
            "principal": agentPrincipal,
        ]
        if matrixUser { value["matrixUser"] = "@agent-alfred:atum.test" }
        return value
    }

    private func agentDefinitionBody(soul: String, definitionRevision: Int = 1,
                                     identityRevision: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "assistant": agentRecord(definitionRevision: definitionRevision,
                                     identityRevision: identityRevision),
            "definition": [
                "schema_version": 1,
                "soul": soul,
                "model_alias": "binh-minh",
                "reasoning": NSNull(),
                "skills": [],
            ],
            "definition_revision": definitionRevision,
            "identity_revision": identityRevision,
        ], options: .sortedKeys)
    }

    private func managedModelBody(revision: Int = 1,
                                  effort: String = "medium") throws -> Data {
        let digest = String(repeating: "a", count: 64)
        return try JSONSerialization.data(withJSONObject: [
            "profile": "atum.model-choice/1.1",
            "agentPrincipal": agentPrincipal,
            "revision": revision,
            "source": revision == 0 ? "default" : "saved",
            "policyVersion": "2026-10-13.1",
            "policyDigest": digest,
            "choice": ["v": 2, "source": "atum", "model": "sonnet", "effort": effort],
            "models": [[
                "alias": "sonnet",
                "displayName": "Anthropic Claude Sonnet 5.5",
                "providerModel": "anthropic/claude-sonnet-5.5",
                "contextBudget": 120_000,
                "outputBudget": 16_384,
                "efforts": ["low", "medium", "high"],
                "defaultEffort": "high",
                "cost": [
                    "currency": "USD", "inputPerMtok": "2.00", "outputPerMtok": "10.00",
                    "maxTurnMicroProtons": 19_626_624_000,
                ],
                "eligibility": ["state": "ready"],
                "inputModalities": ["text", "image", "file"],
                "supportsTools": true,
            ]],
            "runtimes": [["runtime": "cloud"]],
            "grant": [
                "profile": "atum.model-grant/1", "state": "active", "alias": "sonnet",
                "model": "sonnet", "effort": effort, "policyDigest": digest,
                "contextBudget": 120_000, "outputBudget": 16_384,
                "maxTurnMicroProtons": 19_626_624_000,
            ],
        ], options: .sortedKeys)
    }

    private func managedModelDestinationsBody(revision: Int = 3,
                                              cloudModel: String = "nguyet-thuc") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "profile": "atum.model-choice/1.3",
            "agentPrincipal": agentPrincipal,
            "revision": revision,
            "policyDigest": "489e82bcce6008fd0cae824623b3e323bf7a8820a18e34bf8bab815f7999d7a0",
            "recommended": ["source": "atum", "model": "nguyet-thuc", "effort": "medium"],
            "choices": [
                ["destination": "cloud", "source": "atum", "model": cloudModel, "effort": "medium"],
                ["destination": "mac:mini-b", "source": "atum", "model": "nhat-thuc", "effort": "medium"],
            ],
            "dailyCap": ["dailyProtons": 200_000, "timeZone": "Asia/Ho_Chi_Minh",
                         "warningPercent": 80, "counts": "atum_billed_only"],
            "spend": ["day": "2026-10-20", "usedProtons": 42_000,
                      "state": "normal", "notice": "none"],
        ], options: .sortedKeys)
    }

    private func agentPresentationBody(title: Any = NSNull(), identityRevision: Int = 3,
                                       shape: String = "spark", color: String = "violet") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "profile": "atum.agent-presentation/1",
            "assistant_id": agentID,
            "assistant_principal": agentPrincipal,
            "title": title,
            "mark": ["shape": shape, "color": color],
            "default_mark": ["shape": "circle", "color": "blue"],
            "avatar_url": NSNull(),
            "identity_revision": identityRevision,
        ], options: .sortedKeys)
    }

    private func routineRecord(revision: Int = 3, enabled: Bool = true) -> [String: Any] {
        [
            "id": "00000000-0000-4000-8000-736e81c7ee66",
            "title": "Morning brief", "instruction": "Summarize my priorities.",
            "schedule": ["kind": "daily", "hour": 8, "minute": 30],
            "timezone": "Asia/Ho_Chi_Minh", "enabled": enabled,
            "notifications": true, "revision": revision,
            "nextRunAt": enabled ? 1_800_003_600_000 : NSNull(), "lastRun": NSNull(),
        ]
    }

    private func agentRoutinesBody(revision: Int = 3, enabled: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "profile": "atum.agent-routines/1", "assistantId": agentID,
            "assistantPrincipal": agentPrincipal, "serverTime": 1_800_000_000_000, "legacyState": "clear",
            "routines": [routineRecord(revision: revision, enabled: enabled)],
        ], options: .sortedKeys)
    }

    func testPrivateCosUsesOnlyExactAuthenticatedReadRoutesAndRefreshes401() async throws {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "company-private-cos", withExtension: nil))
        let capability = try Data(contentsOf: directory.appendingPathComponent("v1.3-capability.response.json"))
        let view = try Data(contentsOf: directory.appendingPathComponent("v1-lazy-first-open.preparing.response.json"))
        let company = try NativeID("a1000000-0000-4000-8000-000000000001")
        var calls = 0
        NativeDomainProtocol.state.handler = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Atum-Company-Wire"), "1.3")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertTrue((self.body(of: request) ?? Data()).isEmpty)
            if calls == 1 { return .init(status: 401, chunks: [Data("{\"error\":\"matrix_401\"}".utf8)]) }
            return .json(request.url?.path.hasSuffix("/controller/company-private-cos") == true ? capability : view)
        }
        let auth = TestAuthorization(first: "synthetic-old", refreshed: "synthetic-new")
        let api = client(auth)
        _ = try await api.companyPrivateCosCapability()
        let binding = try await api.companyPrivateCosView(companyID: company)
        XCTAssertEqual(binding.binding?.roomId,
                       "!private-cos-a:atum.example")
        XCTAssertEqual(auth.refreshCalls, 1)
        XCTAssertEqual(NativeDomainProtocol.state.requests.map { $0.url?.path }, [
            "/api/matrix/v1/cloud/controller/company-private-cos",
            "/api/matrix/v1/cloud/controller/company-private-cos",
            "/api/matrix/v1/companies/" + company.rawValue + "/private-cos",
        ])
        XCTAssertEqual(NativeDomainProtocol.state.requests.prefix(2).map {
            $0.value(forHTTPHeaderField: "Authorization")
        }, ["Bearer synthetic-old", "Bearer synthetic-new"])
    }

    func testPrivateCosEnsurePostsTheFrozenBodyAndAcceptsTheAsyncPreparingAnswer() async throws {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "company-private-cos", withExtension: nil))
        let accepted = try Data(contentsOf: directory.appendingPathComponent("v1.1-ensure-accepted.response.json"))
        let company = try NativeID("37700000-0000-4000-8000-000000000001")
        let requestID = try NativeID("a7000000-0000-4000-8000-000000000001")
        var sent: Data?
        NativeDomainProtocol.state.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Atum-Company-Wire"), "1.3")
            sent = self.body(of: request)
            return .init(status: 202, chunks: [accepted])
        }
        let api = client(TestAuthorization(first: "synthetic-old", refreshed: "synthetic-new"))
        let view = try await api.ensureCompanyPrivateCos(
            companyID: company, request: CompanyPrivateCosEnsureRequest(requestId: requestID, trigger: .dmOpen))
        XCTAssertEqual(view.state, "preparing")
        XCTAssertNil(view.binding)
        XCTAssertEqual(NativeDomainProtocol.state.requests.map { $0.url?.path },
                       ["/api/matrix/v1/companies/" + company.rawValue + "/private-cos"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent)) as? [String: AnyHashable])
        XCTAssertEqual(body, ["schemaVersion": 1, "requestId": requestID.rawValue, "action": "ensure",
                              "trigger": "dm_open"])
    }

    func testPrivateCosRefusesWrongCompanyForbiddenAbsentAndOversizeWithoutRetry() async throws {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "company-private-cos", withExtension: nil))
        let view = try Data(contentsOf: directory.appendingPathComponent("v1-lazy-first-open.preparing.response.json"))
        let company = try NativeID("a1000000-0000-4000-8000-000000000002")
        let api = client(TestAuthorization(first: "synthetic-token"))
        NativeDomainProtocol.state.handler = { _ in .json(view) }
        do { _ = try await api.companyPrivateCosView(companyID: company); XCTFail("wrong company admitted") }
        catch { }
        for status in [403, 404, 503] {
            NativeDomainProtocol.state.reset()
            NativeDomainProtocol.state.handler = { _ in
                .init(status: status, chunks: [Data("{\"schemaVersion\":1,\"error\":{\"code\":\"denied\"}}".utf8)])
            }
            do { _ = try await api.companyPrivateCosView(companyID: company); XCTFail("refusal admitted") }
            catch { }
            XCTAssertEqual(NativeDomainProtocol.state.requests.count, 1)
        }
        NativeDomainProtocol.state.reset()
        NativeDomainProtocol.state.handler = { _ in .json(Data(repeating: 32, count: 262_145)) }
        do { _ = try await api.companyPrivateCosView(companyID: company); XCTFail("unbounded view admitted") }
        catch { }
    }

    func testOfficialAccountsUsesTheOneExactNativeRoute() async throws {
        let founder = "@synthetic-user-0017:example.invalid"
        let response = Data("""
        {"profile":"atum.official-accounts/1",
         "founder":{"user_id":"\(founder)","updates_room_id":"!updates:example.invalid"},
         "accounts":[{"user_id":"\(founder)","tier":"official","role":"founder","handle":"founder",
                      "roster_default":true,"roster_order":0,"roster_state":"available"}]}
        """.utf8)

        NativeDomainProtocol.state.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString,
                           "https://api.atumplatform.com/api/matrix/v1/official-accounts")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                           "Bearer p2-official-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-atum-principal"))
            XCTAssertTrue((self.body(of: request) ?? Data()).isEmpty)
            return .json(response)
        }

        let parsed = try await client(TestAuthorization(first: "p2-official-token"))
            .officialAccounts()
        XCTAssertEqual(parsed.founder?.userID, founder)
        XCTAssertEqual(parsed.accounts.count, 1)
        XCTAssertEqual(parsed.accounts[0].tier, .official)
        XCTAssertEqual(parsed.accounts[0].role, .founder)
        XCTAssertEqual(parsed.founderHandle, "founder")
        XCTAssertEqual(parsed.founderRoster,
                       OfficialFounderRoster(defaultVisible: true, order: 0, state: .available))
        XCTAssertEqual(NativeDomainProtocol.state.requests.count, 1)
    }

    func testReadURLsQueryHeadersAndStrictDecoding() async throws {
        let fixture = try fixtures()
        let authorization = TestAuthorization(first: "p2-read-token")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "api.atumplatform.com", .path: "/", .name: "ambient", .value: "must-not-send", .secure: "TRUE"
        ]))
        HTTPCookieStorage.shared.setCookie(cookie)
        defer { HTTPCookieStorage.shared.deleteCookie(cookie) }
        NativeDomainProtocol.state.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer p2-read-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-atum-principal"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            switch request.url?.path {
            case "/api/matrix/v1/agents": return .json(try! fixture.data("agents.response.json"))
            case "/api/matrix/v1/apps": return .json(self.appCatalogBody())
            case "/api/matrix/v1/store/catalog": return .json(self.storeCatalogBody())
            case "/api/matrix/v1/wallet":
                return .init(headers: ["Content-Type": "Application/JSON; charset=utf-8"],
                             chunks: [try! fixture.data("wallet.response.json")])
            case "/api/matrix/v1/wallet/history": return .json(try! fixture.data("wallet-history.response.json"))
            case "/api/matrix/v1/aliases/lookup":
                XCTAssertEqual(request.url?.query, "handle=lan_anh")
                return .json(try! fixture.data("alias-lookup-assigned.response.json"))
            default: XCTFail("Unexpected native endpoint"); return .init(status: 404, chunks: [Data("{}".utf8)])
            }
        }

        let value = client(authorization)
        let agents = try await value.agents()
        let apps = try await value.apps()
        let store = try await value.storeCatalog()
        let wallet = try await value.wallet()
        let history = try await value.walletHistory(limit: 100, before: "cursor_20261008-01")
        let alias = try await value.aliasLookup(handle: NativeHandle("lan_anh"))
        XCTAssertFalse(agents.agents.isEmpty)
        XCTAssertEqual(apps.apps.first?.app, "moon")
        XCTAssertEqual(apps.apps.first?.bot?.userID.rawValue, "@app-moon:atumplatform.com")
        XCTAssertEqual(store.items.first?.itemID, "skill/official/decision-journal")
        XCTAssertEqual(store.items.first?.title.localized(locale: "en"), "Decision journal")
        XCTAssertGreaterThanOrEqual(wallet.balances.available, 0)
        XCTAssertFalse(history.entries.isEmpty)
        XCTAssertEqual(alias.humanMessageTarget?.rawValue, "@user-0123456789abcdef0123456789abcdef:atum.test")
        XCTAssertEqual(NativeDomainProtocol.state.requests.map { $0.url?.absoluteString }, [
            "https://api.atumplatform.com/api/matrix/v1/agents",
            "https://api.atumplatform.com/api/matrix/v1/apps",
            "https://api.atumplatform.com/api/matrix/v1/store/catalog",
            "https://api.atumplatform.com/api/matrix/v1/wallet",
            "https://api.atumplatform.com/api/matrix/v1/wallet/history?limit=100&before=cursor_20261008-01",
            "https://api.atumplatform.com/api/matrix/v1/aliases/lookup?handle=lan_anh"
        ])

        do { _ = try await value.walletHistory(limit: 0); XCTFail("Invalid limit accepted") }
        catch let failure as NativeDomainClientFailure { XCTAssertEqual(failure, .invalidRequest) }
        do { _ = try await value.walletHistory(before: "not/a/cursor"); XCTFail("Invalid cursor accepted") }
        catch let failure as NativeDomainClientFailure { XCTAssertEqual(failure, .invalidRequest) }
        XCTAssertEqual(NativeDomainProtocol.state.requests.count, 6)
    }

    private func bootstrapBody() -> Data {
        Data("""
        {"agentPrincipal":"00000000-0000-4000-8000-123671cefaf3","matrixUser":"@agent-0123456789abcdef0123:atum.test","starter":{"state":"granted","amount":1}}
        """.utf8)
    }

    private func requestBody(_ request: URLRequest) -> String {
        String(decoding: body(of: request) ?? Data(), as: UTF8.self)
    }

    func testSignInPlacementSendsTheDisclosureVersionAndRetriesARefusedBodyOnce() async throws {
        NativeDomainProtocol.state.handler = { request in
            switch request.url?.path {
            case "/api/matrix/v1/cloud/disclosure":
                XCTAssertEqual(request.httpMethod, "GET")
                return .json(Data("{\"kind\":\"cloud\",\"version\":3}".utf8))
            case "/api/matrix/v1/assistant":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                if self.requestBody(request) == "{\"disclosureVersion\":3}" {
                    return .init(status: 400, chunks: [Data("{\"error\":\"matrix_400\"}".utf8)])
                }
                XCTAssertEqual(self.requestBody(request), "{}")
                return .json(self.bootstrapBody())
            default:
                XCTFail("Unexpected native endpoint")
                return .init(status: 404, chunks: [Data("{}".utf8)])
            }
        }

        let value = client(TestAuthorization(first: "p1-placement-token"))
        let version = await value.cloudDisclosureVersion()
        XCTAssertEqual(version, 3)
        try await value.ensureAssistant(disclosureVersion: version)
        XCTAssertEqual(NativeDomainProtocol.state.requests.map { $0.url?.path }, [
            "/api/matrix/v1/cloud/disclosure",
            "/api/matrix/v1/assistant",
            "/api/matrix/v1/assistant"
        ], "the versioned body is refused once, then the empty body provisions")
    }

    func testSignInPlacementUsesTheEmptyBodyWhenTheDisclosureReadFails() async throws {
        var posts = 0
        NativeDomainProtocol.state.handler = { request in
            switch request.url?.path {
            case "/api/matrix/v1/cloud/disclosure":
                return .init(status: 503, chunks: [Data("{\"error\":\"matrix_503\"}".utf8)])
            case "/api/matrix/v1/assistant":
                posts += 1
                XCTAssertEqual(self.requestBody(request), "{}")
                return .json(self.bootstrapBody())
            default:
                XCTFail("Unexpected native endpoint")
                return .init(status: 404, chunks: [Data("{}".utf8)])
            }
        }

        let value = client(TestAuthorization(first: "p1-placement-token"))
        let version = await value.cloudDisclosureVersion()
        XCTAssertNil(version, "an unavailable disclosure keeps the Mac-first body")
        try await value.ensureAssistant(disclosureVersion: version)
        XCTAssertEqual(posts, 1)
    }

    func testSignInPlacementRetriesAVersionedBodyRefusedWith422() async throws {
        var bodies: [String] = []
        NativeDomainProtocol.state.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/matrix/v1/assistant")
            XCTAssertEqual(request.value(forHTTPHeaderField: OwnerTimeZoneContract.requestHeader),
                           "America/Los_Angeles")
            bodies.append(self.requestBody(request))
            if bodies.count == 1 { return .init(status: 422, chunks: [Data("{\"error\":\"matrix_400\"}".utf8)]) }
            return .json(self.bootstrapBody())
        }

        try await client(TestAuthorization(first: "p1-placement-token"))
            .ensureAssistant(disclosureVersion: 7, timeZone: "America/Los_Angeles")
        XCTAssertEqual(bodies, ["{\"disclosureVersion\":7}", "{}"])
    }

    func testSignInPlacementStopsAfterOneEmptyBodyRetryAndSurfacesTheRefusal() async throws {
        var bodies: [String] = []
        NativeDomainProtocol.state.handler = { request in
            bodies.append(self.requestBody(request))
            return .init(status: 400, chunks: [Data("{\"error\":\"matrix_400\"}".utf8)])
        }

        do {
            try await client(TestAuthorization(first: "p1-placement-token"))
                .ensureAssistant(disclosureVersion: 1)
            XCTFail("A refused placement was accepted")
        } catch let failure as NativeDomainClientFailure {
            guard case let .http(http) = failure else { return XCTFail("Unexpected failure \(failure)") }
            XCTAssertEqual(http.response.error, .badRequest)
        }
        XCTAssertLessThanOrEqual(bodies.count, 2, "at most one empty-body retry")
        XCTAssertEqual(bodies.first, "{\"disclosureVersion\":1}")
    }

    func testSignInPlacementRefreshesTheGrantOnceOn401() async throws {
        var bodies: [String] = []
        NativeDomainProtocol.state.handler = { request in
            bodies.append(self.requestBody(request))
            if bodies.count == 1 { return .init(status: 401, chunks: [Data("{\"error\":\"matrix_401\"}".utf8)]) }
            return .json(self.bootstrapBody())
        }

        let authorization = TestAuthorization(first: "p1-placement-old", refreshed: "p1-placement-new")
        try await client(authorization).ensureAssistant(disclosureVersion: nil,
                                                       timeZone: "America/Los_Angeles")
        XCTAssertEqual(bodies, ["{}", "{}"], "the body is replayed unchanged")
        XCTAssertEqual(NativeDomainProtocol.state.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, [
            "Bearer p1-placement-old", "Bearer p1-placement-new"
        ])
        XCTAssertEqual(authorization.refreshCalls, 1)
        XCTAssertEqual(NativeDomainProtocol.state.requests.map {
            $0.value(forHTTPHeaderField: OwnerTimeZoneContract.requestHeader)
        }, ["America/Los_Angeles", "America/Los_Angeles"])
    }

    func testSignInPlacementOmitsInvalidTimeZoneInsteadOfInventingOne() async throws {
        NativeDomainProtocol.state.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: OwnerTimeZoneContract.requestHeader))
            return .json(self.bootstrapBody())
        }
        try await client(TestAuthorization(first: "p1-placement-token"))
            .ensureAssistant(disclosureVersion: 1, timeZone: "not a time zone")
        XCTAssertEqual(NativeDomainProtocol.state.requests.count, 1)
    }

    func testSignInPlacementValidatesTheProvisioningReplyShape() async throws {
        NativeDomainProtocol.state.handler = { _ in
            .json(Data("{\"agentPrincipal\":\"not-a-uuid\",\"matrixUser\":\"@agent-0123456789abcdef0123:atum.test\"}".utf8))
        }
        do {
            try await client(TestAuthorization(first: "p1-placement-token"))
                .ensureAssistant(disclosureVersion: nil)
            XCTFail("A malformed provisioning reply was accepted")
        } catch let failure as NativeDomainClientFailure {
            XCTAssertEqual(failure, .invalidResponse)
        }
    }

    func testStoreCatalogValidatesBoundedListingAndOfferMetadata() throws {
        let body = storeCatalogBody()
        let catalog = try NativeAPI.decode(StoreCatalogResponse.self, from: body)
        let item = try XCTUnwrap(catalog.items.first)
        XCTAssertEqual(item.kind, .skill)
        XCTAssertEqual(item.summary.localized(locale: "fr"), "Make decisions clear")
        XCTAssertEqual(item.offer?.billingInterval, .oneTime)
        XCTAssertNil(item.offer?.renewalPriceMicroProtons)

        func edited(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            mutate(&value)
            return try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        }

        let additive = try edited { root in
            var items = root["items"] as! [[String: Any]]
            items[0]["ownership"] = ["state": "available", "source": NSNull(), "assistantIds": [], "until": NSNull()]
            items[0]["future_presentation"] = ["badge": "new"]
            root["items"] = items
        }
        XCTAssertNoThrow(try NativeAPI.decode(StoreCatalogResponse.self, from: additive))

        let duplicate = try edited { root in
            var items = root["items"] as! [[String: Any]]
            items.append(items[0])
            root["items"] = items
        }
        XCTAssertThrowsError(try NativeAPI.decode(StoreCatalogResponse.self, from: duplicate))

        let invalidItem = try edited { root in
            var items = root["items"] as! [[String: Any]]
            items[0]["itemId"] = "skill/invalid url https://example.com"
            root["items"] = items
        }
        XCTAssertThrowsError(try NativeAPI.decode(StoreCatalogResponse.self, from: invalidItem))

        let invalidOffer = try edited { root in
            var items = root["items"] as! [[String: Any]]
            var offer = items[0]["offer"] as! [String: Any]
            offer["renewalPriceMicroProtons"] = 1
            items[0]["offer"] = offer
            root["items"] = items
        }
        XCTAssertThrowsError(try NativeAPI.decode(StoreCatalogResponse.self, from: invalidOffer))

        let missingVietnamese = try edited { root in
            var items = root["items"] as! [[String: Any]]
            items[0]["title"] = ["en": "Decision journal"]
            root["items"] = items
        }
        XCTAssertThrowsError(try NativeAPI.decode(StoreCatalogResponse.self, from: missingVietnamese))

        let tooMany = try edited { root in
            let item = (root["items"] as! [[String: Any]])[0]
            root["items"] = Array(repeating: item, count: 1_001)
        }
        XCTAssertThrowsError(try NativeAPI.decode(StoreCatalogResponse.self, from: tooMany))
    }

    func testStoreCatalogUsesTheSameBounded401Refresh() async throws {
        let authorization = TestAuthorization(first: "p2-store-old", refreshed: "p2-store-new")
        var requestCount = 0
        NativeDomainProtocol.state.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/matrix/v1/store/catalog")
            if requestCount == 1 { return .init(status: 401, chunks: [Data("{\"error\":\"matrix_401\"}".utf8)]) }
            return .json(self.storeCatalogBody())
        }

        let catalog = try await client(authorization).storeCatalog()
        XCTAssertEqual(catalog.items.count, 1)
        XCTAssertEqual(authorization.normalCalls, 1)
        XCTAssertEqual(authorization.refreshCalls, 1)
        XCTAssertEqual(NativeDomainProtocol.state.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, [
            "Bearer p2-store-old", "Bearer p2-store-new"
        ])
    }

    func testAliasLookupRejectsAResponseForAnotherHandle() async throws {
        let fixture = try fixtures()
        NativeDomainProtocol.state.handler = { request in
            XCTAssertEqual(request.url?.absoluteString,
                           "https://api.atumplatform.com/api/matrix/v1/aliases/lookup?handle=lan")
            return .json(try! fixture.data("alias-lookup-assigned.response.json"))
        }
        do {
            _ = try await client(TestAuthorization(first: "p2-alias-token"))
                .aliasLookup(handle: NativeHandle("lan"))
            XCTFail("Mismatched directory response accepted")
        } catch let failure as NativeDomainClientFailure {
            XCTAssertEqual(failure, .invalidResponse)
        }
    }

    func testAgentCreateAndDefinitionWritesUseOnlyExactTypedRoutes() async throws {
        let authorization = TestAuthorization(first: "p2-agent-token")
        let value = client(authorization)
        var step = 0
        NativeDomainProtocol.state.handler = { request in
            step += 1
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer p2-agent-token")
            switch step {
            case 1:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.url?.path, "/api/matrix/v1/agents")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let data = try! XCTUnwrap(self.body(of: request))
                let body = try! XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(body["requestId"] as? String, "00000000-0000-4000-8000-c9ead89f3604")
                XCTAssertEqual(body["displayName"] as? String, "Alfred")
                return .json(try! JSONSerialization.data(withJSONObject: self.agentRecord(matrixUser: true)))
            case 2:
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/matrix/v1/agents/\(self.agentID)/definition")
                return .json(try! self.agentDefinitionBody(soul: "# Alfred\n\n## What you do\n\nPlans."))
            case 3:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.url?.path, "/api/matrix/v1/agents/\(self.agentID)/definition")
                let data = try! XCTUnwrap(self.body(of: request))
                let body = try! XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                XCTAssertEqual(Set(body.keys), ["expected_definition_revision", "expected_identity_revision",
                                                 "display_name", "avatar", "definition"])
                XCTAssertEqual(body["expected_definition_revision"] as? Int, 1)
                let definition = body["definition"] as? [String: Any]
                XCTAssertEqual(definition?["soul"] as? String, "Be concise.")
                return .json(try! self.agentDefinitionBody(soul: "Be concise.", definitionRevision: 2))
            default:
                XCTFail("Unexpected request")
                return .init(status: 503, chunks: [Data("{}".utf8)])
            }
        }

        let created = try await value.createAgent(AgentCreateRequest(
            requestId: NativeID("00000000-0000-4000-8000-c9ead89f3604"),
            displayName: " Alfred "
        ))
        XCTAssertEqual(created.id.rawValue, agentID)
        let snapshot = try await value.agentDefinition(assistantID: NativeID(agentID))
        var definition = try XCTUnwrap(snapshot.definition)
        definition.soul = "Be concise."
        let written = try await value.writeAgentDefinition(
            assistantID: NativeID(agentID),
            value: try AgentDefinitionWrite(snapshot: snapshot, definition: definition)
        )
        XCTAssertEqual(written.definition?.soul, "Be concise.")
        XCTAssertEqual(written.definitionRevision, 2)
        XCTAssertEqual(step, 3)
    }

    func testAgentLifecycleCapabilityBeginAndResumeUseTheOneClosedRoute() async throws {
        let value = client(TestAuthorization(first: "p2-lifecycle-token"))
        let requestID = try NativeID("00000000-0000-4000-8000-f2e3447907ab")
        let enrollmentID = "00000000-0000-4000-8000-5a158f7e24f0"
        let executorID = "00000000-0000-4000-8000-ff5a7ca461b8"
        let roomID = "!assistant:atum.test"
        var step = 0
        NativeDomainProtocol.state.handler = { request in
            step += 1
            XCTAssertEqual(request.url?.path, "/api/matrix/v1/agents/lifecycle")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer p2-lifecycle-token")
            if step == 1 {
                XCTAssertEqual(request.httpMethod, "GET")
                return .json(Data("""
                {"profile":"atum.agent-lifecycle/1","available":true,"disclosureVersion":1}
                """.utf8))
            }
            XCTAssertEqual(request.httpMethod, "POST")
            let data = try! XCTUnwrap(self.body(of: request))
            let body = try! XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["requestId"] as? String, requestID.rawValue)
            if step == 2 {
                XCTAssertEqual(body["operation"] as? String, "begin")
                XCTAssertEqual(body["displayName"] as? String, "Alfred")
                XCTAssertEqual(body["ownerDevice"] as? String, "ATUM_IOS_DEVICE")
                XCTAssertEqual(body["disclosureVersion"] as? Int, 1)
            } else {
                XCTAssertEqual(Set(body.keys), ["operation", "requestId"])
                XCTAssertEqual(body["operation"] as? String, "resume")
            }
            var assistant = self.agentRecord(matrixUser: true)
            assistant["definition_revision"] = 1
            assistant["answering"] = "cloud"
            return .json(try! JSONSerialization.data(withJSONObject: [
                "profile": "atum.agent-lifecycle/1",
                "requestId": requestID.rawValue,
                "state": "ready",
                "assistant": assistant,
                "enrollment": [
                    "enrollmentId": enrollmentID,
                    "kind": "cloud",
                    "agentPrincipal": self.agentPrincipal,
                    "executorId": executorID,
                    "state": "active",
                    "trust": "trusted",
                    "conversationReady": true,
                ],
                "roomId": roomID,
            ]))
        }

        let capability = try await value.agentLifecycleCapability()
        XCTAssertTrue(capability.available)
        XCTAssertEqual(capability.disclosureVersion, 1)
        let begun = try await value.beginAgentLifecycle(try AgentLifecycleBegin(
            requestId: requestID, displayName: " Alfred ",
            ownerDevice: "ATUM_IOS_DEVICE", disclosureVersion: 1
        ))
        XCTAssertEqual(begun.state, .ready)
        XCTAssertEqual(begun.roomID, roomID)
        XCTAssertTrue(begun.enrollment?.conversationReady == true)
        let resumed = try await value.resumeAgentLifecycle(AgentLifecycleResume(requestId: requestID))
        XCTAssertEqual(resumed, begun)
        XCTAssertEqual(step, 3)
    }

    func testAgentLifecycleRefusesAFalseReadySnapshot() throws {
        func object(answering: String = "cloud", trust: String = "trusted") -> [String: Any] {
            var assistant = agentRecord(matrixUser: true)
            assistant["definition_revision"] = 1
            assistant["answering"] = answering
            return [
                "profile": "atum.agent-lifecycle/1",
                "requestId": "00000000-0000-4000-8000-f2e3447907ab",
                "state": "ready",
                "assistant": assistant,
                "enrollment": [
                    "enrollmentId": "00000000-0000-4000-8000-5a158f7e24f0",
                    "kind": "cloud", "agentPrincipal": agentPrincipal,
                    "executorId": "00000000-0000-4000-8000-ff5a7ca461b8",
                    "state": "active", "trust": trust, "conversationReady": true,
                ],
                "roomId": "!assistant:atum.test",
            ]
        }

        func body(_ object: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: object)
        }

        XCTAssertThrowsError(try NativeAPI.decode(
            AgentLifecycleSnapshot.self, from: body(object(answering: "local"))
        ))
        XCTAssertThrowsError(try NativeAPI.decode(
            AgentLifecycleSnapshot.self, from: body(object(trust: "pending"))
        ))

        var mismatchedPrincipal = object()
        var enrollment = try XCTUnwrap(mismatchedPrincipal["enrollment"] as? [String: Any])
        enrollment["agentPrincipal"] = "00000000-0000-4000-8000-3bb21d2d5e41"
        mismatchedPrincipal["enrollment"] = enrollment
        XCTAssertThrowsError(try NativeAPI.decode(
            AgentLifecycleSnapshot.self, from: body(mismatchedPrincipal)
        ))

        var unknownEnrollmentField = object()
        enrollment = try XCTUnwrap(unknownEnrollmentField["enrollment"] as? [String: Any])
        enrollment["unexpected"] = "not-allowed"
        unknownEnrollmentField["enrollment"] = enrollment
        XCTAssertThrowsError(try NativeAPI.decode(
            AgentLifecycleSnapshot.self, from: body(unknownEnrollmentField)
        ))
    }

    func testAgentNameRefusalIsTypedAndNeverTreatedAsAnHTTPBody() async throws {
        NativeDomainProtocol.state.handler = { _ in
            .init(status: 422, chunks: [Data("{\"error\":\"assistant_name_reserved\"}".utf8)])
        }
        do {
            _ = try await client(TestAuthorization(first: "p2-agent-token")).createAgent(
                AgentCreateRequest(requestId: NativeID("00000000-0000-4000-8000-c9ead89f3604"),
                                   displayName: "Moon")
            )
            XCTFail("Name refusal accepted")
        } catch let failure as NativeDomainClientFailure {
            XCTAssertEqual(failure, .assistantName(.reserved))
        }
    }

    func testManagedModelReadAndWriteUsePrincipalFencedRoutes() async throws {
        let principal = try NativeID(agentPrincipal)
        let requestID = try NativeID("00000000-0000-4000-8000-27d9e39c4896")
        let value = client(TestAuthorization(first: "p2-model-token"))
        var step = 0
        NativeDomainProtocol.state.handler = { request in
            step += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer p2-model-token")
            if step == 1 {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, "/api/matrix/v1/agents/\(self.agentPrincipal)/models")
                return .json(try! self.managedModelBody())
            }
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/matrix/v1/agents/\(self.agentPrincipal)/model-choice")
            let data = try! XCTUnwrap(self.body(of: request))
            let body = try! XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["profile"] as? String, "atum.model-choice/1.1")
            XCTAssertEqual(body["requestId"] as? String, requestID.rawValue)
            XCTAssertEqual(body["expectedRevision"] as? Int, 1)
            XCTAssertEqual((body["choice"] as? [String: Any])?["effort"] as? String, "high")
            return .json(try! self.managedModelBody(revision: 2, effort: "high"))
        }

        let snapshot = try await value.managedModels(agentPrincipal: principal)
        XCTAssertEqual(snapshot.models.first?.displayName, "Anthropic Claude Sonnet 5.5")
        XCTAssertEqual(snapshot.choice.effort, .medium)
        let write = try ManagedModelWrite(requestId: requestID, snapshot: snapshot,
                                          model: "sonnet", effort: .high)
        let saved = try await value.writeManagedModel(agentPrincipal: principal, value: write)
        XCTAssertEqual(saved.revision, 2)
        XCTAssertEqual(saved.choice.effort, .high)
        XCTAssertEqual(step, 2)
    }

    func testManagedModelDestinationReadAndWriteUseTheFrozenOwnerRoute() async throws {
        let principal = try NativeID(agentPrincipal)
        let requestID = try NativeID("00000000-0000-4000-8000-303617b97302")
        let value = client(TestAuthorization(first: "p2-destination-token"))
        var step = 0
        NativeDomainProtocol.state.handler = { request in
            step += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                           "Bearer p2-destination-token")
            XCTAssertEqual(request.url?.path,
                           "/api/matrix/v1/agents/\(self.agentPrincipal)/model-destinations")
            if step == 1 {
                XCTAssertEqual(request.httpMethod, "GET")
                return .json(try! self.managedModelDestinationsBody())
            }
            XCTAssertEqual(request.httpMethod, "PUT")
            let data = try! XCTUnwrap(self.body(of: request))
            let body = try! XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(body.keys),
                           ["profile", "requestId", "expectedRevision", "policyDigest", "choice"])
            XCTAssertEqual(body["profile"] as? String, "atum.model-choice/1.3")
            XCTAssertEqual(body["requestId"] as? String, requestID.rawValue)
            XCTAssertEqual(body["expectedRevision"] as? Int, 3)
            let choice = try! XCTUnwrap(body["choice"] as? [String: Any])
            XCTAssertEqual(Set(choice.keys), ["destination", "source", "model", "effort"])
            XCTAssertEqual(choice["destination"] as? String, "cloud")
            XCTAssertEqual(choice["source"] as? String, "atum")
            XCTAssertEqual(choice["model"] as? String, "nhat-thuc")
            XCTAssertEqual(choice["effort"] as? String, "medium")
            XCTAssertNil(body["token"])
            return .json(try! self.managedModelDestinationsBody(revision: 4,
                                                                cloudModel: "nhat-thuc"))
        }

        let snapshot = try await value.managedModelDestinations(agentPrincipal: principal)
        XCTAssertEqual(snapshot.revision, 3)
        XCTAssertEqual(snapshot.choices.count, 2)
        let write = try ManagedModelDestinationWrite(
            requestId: requestID, snapshot: snapshot,
            destination: ManagedModelDestinationID("cloud"), model: "nhat-thuc"
        )
        let saved = try await value.writeManagedModelDestination(agentPrincipal: principal,
                                                                 value: write)
        XCTAssertEqual(saved.revision, 4)
        XCTAssertEqual(saved.effectiveModel(for: try ManagedModelDestinationID("cloud")),
                       "nhat-thuc")
        XCTAssertEqual(step, 2)
    }

    func testAgentAvatarWriteBindsCanonicalTargetAndUsesBoundedImageBody() async throws {
        let target = try NativeID(agentPrincipal)
        let image = try AgentAvatarImage(type: .jpeg, data: Data([0xff, 0xd8, 0xff, 0xd9]))
        NativeDomainProtocol.state.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/api/matrix/v1/agents/\(self.agentID)/avatar")
            let data = try! XCTUnwrap(self.body(of: request))
            let body = try! XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertTrue(body["originPrincipal"] is NSNull)
            XCTAssertEqual(body["targetPrincipal"] as? String, self.agentPrincipal)
            let avatar = body["avatar"] as? [String: Any]
            XCTAssertEqual(avatar?["type"] as? String, "image/jpeg")
            XCTAssertEqual(avatar?["base64"] as? String, "/9j/2Q==")
            return .json(try! self.agentDefinitionBody(soul: "Be concise."))
        }
        let result = try await client(TestAuthorization(first: "p2-avatar-token"))
            .writeAgentAvatar(assistantID: NativeID(agentID),
                              value: AgentAvatarWrite(targetPrincipal: target, avatar: image))
        XCTAssertEqual(result.assistant.principal, target)
    }

    func testAgentPresentationReadAndWriteUseRevisionFencedClosedBody() async throws {
        let assistantID = try NativeID(agentID)
        let value = client(TestAuthorization(first: "p2-presentation-token"))
        var step = 0
        NativeDomainProtocol.state.handler = { request in
            step += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                           "Bearer p2-presentation-token")
            XCTAssertEqual(request.url?.path,
                           "/api/matrix/v1/agents/\(self.agentID)/presentation")
            if step == 1 {
                XCTAssertEqual(request.httpMethod, "GET")
                return .json(try! self.agentPresentationBody())
            }
            XCTAssertEqual(request.httpMethod, "PUT")
            let data = try! XCTUnwrap(self.body(of: request))
            let body = try! XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["expected_identity_revision"] as? Int, 3)
            XCTAssertTrue(body["title"] is NSNull)
            XCTAssertEqual((body["mark"] as? [String: Any])?["shape"] as? String, "heart")
            XCTAssertEqual((body["mark"] as? [String: Any])?["color"] as? String, "coral")
            return .json(try! self.agentPresentationBody(identityRevision: 4,
                                                         shape: "heart", color: "coral"))
        }

        let snapshot = try await value.agentPresentation(assistantID: assistantID)
        XCTAssertEqual(snapshot.mark, AgentMark(shape: .spark, color: .violet))
        XCTAssertEqual(snapshot.defaultMark, AgentMark(shape: .circle, color: .blue))
        let write = try AgentPresentationWrite(snapshot: snapshot, title: "  ",
                                               mark: AgentMark(shape: .heart, color: .coral))
        let saved = try await value.writeAgentPresentation(assistantID: assistantID, value: write)
        XCTAssertEqual(saved.identityRevision, 4)
        XCTAssertNil(saved.title)
        XCTAssertEqual(step, 2)
    }

    func testAgentRoutineCRUDRunAndHistoryUseOnlyTypedRevisionFencedRoutes() async throws {
        let assistantID = try NativeID(agentID)
        let routineID = try NativeID("00000000-0000-4000-8000-736e81c7ee66")
        let requestID = try NativeID("00000000-0000-4000-8000-ab798b5c9eee")
        let value = client(TestAuthorization(first: "p2-routine-token"))
        var step = 0
        NativeDomainProtocol.state.handler = { request in
            step += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer p2-routine-token")
            let base = "/api/matrix/v1/agents/\(self.agentID)/routines"
            if step == 1 {
                XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.path, base)
                return .json(try! self.agentRoutinesBody())
            }
            if step == 5 {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url?.path, base + "/\(routineID.rawValue)/runs")
                return .json(Data("""
                {"profile":"atum.agent-routine-runs/1","routineId":"\(routineID.rawValue)","runs":[]}
                """.utf8))
            }
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.path, base)
            let data = try! XCTUnwrap(self.body(of: request))
            let body = try! XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(body["cron"]); XCTAssertNil(body["owner"])
            switch step {
            case 2:
                XCTAssertEqual(body["operation"] as? String, "create")
                XCTAssertEqual((body["schedule"] as? [String: Any])?["kind"] as? String, "daily")
            case 3:
                XCTAssertEqual(body["operation"] as? String, "update")
                XCTAssertEqual(body["expectedRevision"] as? Int, 3)
            case 4: XCTAssertEqual(body["operation"] as? String, "run")
            case 6:
                XCTAssertEqual(body["operation"] as? String, "delete")
                return .json(try! JSONSerialization.data(withJSONObject: [
                    "profile": "atum.agent-routines/1", "outcome": "deleted",
                    "routineId": routineID.rawValue, "revision": 3,
                ]))
            default: XCTFail("Unexpected routine step")
            }
            return .json(try! JSONSerialization.data(withJSONObject: [
                "profile": "atum.agent-routines/1", "routine": self.routineRecord(),
            ], options: .sortedKeys))
        }

        let snapshot = try await value.agentRoutines(assistantID: assistantID)
        let current = try XCTUnwrap(snapshot.routines.first)
        let create = try AgentRoutineCreate(requestId: requestID, title: current.title,
                                            instruction: current.instruction, schedule: current.schedule,
                                            timezone: current.timezone, enabled: true, notifications: true)
        let created = try await value.createAgentRoutine(assistantID: assistantID, value: create)
        XCTAssertEqual(created.id, routineID)
        let update = try AgentRoutineUpdate(requestId: requestID, routine: current, title: current.title,
                                            instruction: current.instruction, schedule: current.schedule,
                                            timezone: current.timezone, enabled: false, notifications: true)
        let updated = try await value.updateAgentRoutine(assistantID: assistantID, value: update)
        XCTAssertEqual(updated.id, routineID)
        let action = AgentRoutineAction(operation: .run, requestId: requestID, routine: current)
        let run = try await value.runAgentRoutine(assistantID: assistantID, value: action)
        XCTAssertEqual(run.id, routineID)
        let runs = try await value.agentRoutineRuns(assistantID: assistantID, routineID: routineID)
        XCTAssertTrue(runs.runs.isEmpty)
        try await value.deleteAgentRoutine(assistantID: assistantID,
                                           value: AgentRoutineAction(operation: .delete,
                                                                     requestId: requestID,
                                                                     routine: current))
        XCTAssertEqual(step, 6)
    }

    func testAppCatalogAcceptsOnlyKnownProfileAndSafePresentationExtensions() throws {
        let body = appCatalogBody()
        let catalog = try NativeAPI.decode(AppCatalogResponse.self, from: body)
        let app = try XCTUnwrap(catalog.apps.first)
        XCTAssertEqual(app.name.localized(locale: "vi", fallback: app.app), "Moon")
        XCTAssertEqual(app.verification, .official)
        XCTAssertEqual(app.matrixRoomContext, .addressedOnly)
        XCTAssertEqual(app.bot?.state, .active)
        XCTAssertEqual(
            app.displayAvatarCandidates.map(\.sha256),
            [String(repeating: "b", count: 64), String(repeating: "a", count: 64)],
            "the bot URL keeps its bot digest before the app-icon fallback"
        )
        XCTAssertEqual(
            app.displayAvatarCandidates.map(\.url.absoluteString),
            ["https://cdn.atumplatform.com/apps/moon-bot.png",
             "https://cdn.atumplatform.com/apps/moon.png"]
        )

        func edited(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            mutate(&value)
            return try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        }

        let additive = try edited { root in
            var apps = root["apps"] as! [[String: Any]]
            apps[0]["future_presentation"] = ["card": "new"]
            apps[0]["verification"] = "future_tier"
            root["apps"] = apps
        }
        let future = try NativeAPI.decode(AppCatalogResponse.self, from: additive)
        XCTAssertNil(future.apps[0].verification)

        let wrongProfile = try edited { $0["profile"] = "atum.app-catalog/2" }
        XCTAssertThrowsError(try NativeAPI.decode(AppCatalogResponse.self, from: wrongProfile))

        let duplicate = try edited { root in
            var apps = root["apps"] as! [[String: Any]]
            apps.append(apps[0])
            root["apps"] = apps
        }
        XCTAssertThrowsError(try NativeAPI.decode(AppCatalogResponse.self, from: duplicate))

        let refusedIconURL = try edited { root in
            var apps = root["apps"] as! [[String: Any]]
            var icon = apps[0]["icon"] as! [String: Any]
            icon["url"] = "http://cdn.atumplatform.com/apps/moon.png#fragment"
            apps[0]["icon"] = icon
            root["apps"] = apps
        }
        XCTAssertThrowsError(try NativeAPI.decode(AppCatalogResponse.self, from: refusedIconURL))

        let hostlessIconURL = try edited { root in
            var apps = root["apps"] as! [[String: Any]]
            var icon = apps[0]["icon"] as! [String: Any]
            icon["url"] = "https:/apps/moon.png"
            apps[0]["icon"] = icon
            root["apps"] = apps
        }
        XCTAssertThrowsError(try NativeAPI.decode(AppCatalogResponse.self, from: hostlessIconURL))

        let oversizedRosterOrder = try edited { root in
            var apps = root["apps"] as! [[String: Any]]
            apps[0]["roster_order"] = 2_147_483_648
            root["apps"] = apps
        }
        XCTAssertThrowsError(try NativeAPI.decode(AppCatalogResponse.self, from: oversizedRosterOrder))

        let activeBotWithoutDevice = try edited { root in
            var apps = root["apps"] as! [[String: Any]]
            var bot = apps[0]["bot"] as! [String: Any]
            bot["device"] = NSNull()
            apps[0]["bot"] = bot
            root["apps"] = apps
        }
        XCTAssertThrowsError(try NativeAPI.decode(AppCatalogResponse.self, from: activeBotWithoutDevice))
    }

    func testAppAvatarCandidatesCoverEveryGenericDescriptorShape() throws {
        func descriptor(_ mutate: (inout [String: Any]) -> Void = { _ in }) throws
            -> AppDescriptor {
            var root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: appCatalogBody()) as? [String: Any]
            )
            var apps = try XCTUnwrap(root["apps"] as? [[String: Any]])
            mutate(&apps[0])
            root["apps"] = apps
            return try NativeAPI.decode(
                AppCatalogResponse.self,
                from: JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
            ).apps[0]
        }
        func pairs(_ app: AppDescriptor) -> [(String, String)] {
            AppAvatarCandidates.candidates(for: app).map {
                ($0.url.absoluteString, $0.sha256)
            }
        }

        let differing = try descriptor()
        XCTAssertEqual(pairs(differing).map { $0.0 }, [
            "https://cdn.atumplatform.com/apps/moon-bot.png",
            "https://cdn.atumplatform.com/apps/moon.png",
        ])
        XCTAssertEqual(pairs(differing).map { $0.1 }, [
            String(repeating: "b", count: 64),
            String(repeating: "a", count: 64),
        ], "each differing digest remains paired with its own URL")

        let deduplicated = try descriptor { app in
            let bot = app["bot"] as! [String: Any]
            app["icon"] = bot["avatar"]
        }
        XCTAssertEqual(AppAvatarCandidates.candidates(for: deduplicated).count, 1)

        let iconOnly = try descriptor { $0["bot"] = NSNull() }
        XCTAssertEqual(pairs(iconOnly).map { $0.0 },
                       ["https://cdn.atumplatform.com/apps/moon.png"])

        let botAvatarOnly = try descriptor { $0["icon"] = NSNull() }
        XCTAssertEqual(pairs(botAvatarOnly).map { $0.0 },
                       ["https://cdn.atumplatform.com/apps/moon-bot.png"])

        let unknownSlug = try descriptor { $0["app"] = "future-app" }
        XCTAssertEqual(pairs(unknownSlug).map { $0.0 }, pairs(differing).map { $0.0 },
                       "candidate selection never switches on a known slug")
        XCTAssertEqual(pairs(unknownSlug).map { $0.1 }, pairs(differing).map { $0.1 },
                       "candidate selection never switches on a known slug")
    }

    func testMobileTrustSASHistoryAndDefaultAppRosterPoliciesFailClosed() throws {
        XCTAssertFalse(MobileMatrixTrustPolicy.canSend(.unknown))
        XCTAssertFalse(MobileMatrixTrustPolicy.canSend(.unverified))
        XCTAssertTrue(MobileMatrixTrustPolicy.canSend(.verified))

        XCTAssertTrue(MobileMatrixSASPolicy.isComplete(format: .emoji, count: 7))
        XCTAssertFalse(MobileMatrixSASPolicy.isComplete(format: .emoji, count: 3))
        XCTAssertTrue(MobileMatrixSASPolicy.isComplete(format: .decimal, count: 3))
        XCTAssertFalse(MobileMatrixSASPolicy.isComplete(format: .decimal, count: 2))
        XCTAssertEqual(MobileMatrixSASPolicy.decimals(
            fromEmojiIndices: [0, 0, 0, 0, 0, 0, 0]
        ), [1_000, 1_000, 1_000])
        XCTAssertEqual(MobileMatrixSASPolicy.decimals(
            fromEmojiIndices: [63, 63, 63, 63, 63, 63, 63]
        ), [9_191, 9_191, 9_191])
        XCTAssertEqual(MobileMatrixSASPolicy.decimals(
            fromEmojiIndices: [0, 18, 13, 5, 25, 56, 38]
        ), [1_036, 4_349, 6_060])
        XCTAssertEqual(MobileMatrixSASPolicy.decimals(
            fromSASBytes: [0x01, 0x23, 0x45, 0x67, 0x89]
        ), [1_036, 4_349, 6_060])
        XCTAssertNil(MobileMatrixSASPolicy.decimals(
            fromSASBytes: [0x01, 0x23, 0x45, 0x67]
        ))
        XCTAssertNil(MobileMatrixSASPolicy.decimals(
            fromEmojiIndices: [0, 18, 13, 5, 25, 56]
        ))
        XCTAssertNil(MobileMatrixSASPolicy.decimals(
            fromEmojiIndices: [0, 18, 13, 5, 25, 56, 64]
        ))
        XCTAssertEqual(MobileMatrixSASPolicy.validatedDecimals([1_000, 4_349, 9_191]),
                       [1_000, 4_349, 9_191])
        XCTAssertNil(MobileMatrixSASPolicy.validatedDecimals([999, 4_349, 6_060]))
        XCTAssertNil(MobileMatrixSASPolicy.validatedDecimals([1_000, 4_349]))
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(MobileMatrixVerificationPolicy.requiresRefresh(
            expiresAt: now.addingTimeInterval(
                MobileMatrixVerificationPolicy.minimumSessionLifetimeSeconds
            ),
            now: now
        ))
        XCTAssertFalse(MobileMatrixVerificationPolicy.requiresRefresh(
            expiresAt: now.addingTimeInterval(
                MobileMatrixVerificationPolicy.minimumSessionLifetimeSeconds + 1
            ),
            now: now
        ))
        XCTAssertTrue(MobileMatrixVerificationPolicy.requiresRefresh(
            expiresAt: now.addingTimeInterval(-1),
            now: now
        ))
        XCTAssertEqual(MobileMatrixHistoryPolicy.initialPageCount, 4)
        XCTAssertEqual(MobileMatrixHistoryPolicy.initialPageSize, 50)
        XCTAssertEqual(MobileMatrixHistoryPolicy.maximumInitialEventCount, 200)
        XCTAssertEqual(MobileMatrixLeasePolicy.sdkLeaseMilliseconds, 500)
        XCTAssertGreaterThan(MobileMatrixLeasePolicy.reopenDelayMilliseconds,
                             MobileMatrixLeasePolicy.sdkLeaseMilliseconds)

        let catalog = try NativeAPI.decode(AppCatalogResponse.self, from: appCatalogBody())
        let app = try XCTUnwrap(catalog.apps.first)
        XCTAssertEqual(MobileAppRosterPolicy.defaultRows(
            from: catalog.apps, shortcuts: absentShortcuts(catalog.apps)
        ).map(\.app), ["moon"])
        XCTAssertTrue(MobileAppRosterPolicy.defaultRows(
            from: catalog.apps, excluding: [app.appID],
            shortcuts: absentShortcuts(catalog.apps)
        ).isEmpty)

        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: appCatalogBody()) as? [String: Any])
        var apps = value["apps"] as! [[String: Any]]
        apps[0]["bot"] = NSNull()
        apps[0]["availability"] = "unavailable"
        value["apps"] = apps
        let unavailable = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        let unavailableCatalog = try NativeAPI.decode(AppCatalogResponse.self, from: unavailable)
        XCTAssertTrue(MobileAppRosterPolicy.defaultRows(
            from: unavailableCatalog.apps,
            shortcuts: absentShortcuts(unavailableCatalog.apps)
        ).isEmpty)
    }

    func testRosterStateIsClosedLegacyAvailableAndComingSoonGrantsNothing() throws {
        let body = appCatalogBody()

        func edited(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            var apps = value["apps"] as! [[String: Any]]
            mutate(&apps[0])
            value["apps"] = apps
            return try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        }

        let legacy = try NativeAPI.decode(AppCatalogResponse.self, from: body).apps[0]
        XCTAssertNil(legacy.rosterState)
        XCTAssertEqual(legacy.effectiveRosterState, .available)

        let available = try NativeAPI.decode(
            AppCatalogResponse.self,
            from: try edited { $0["roster_state"] = "available" }
        ).apps[0]
        XCTAssertEqual(available.rosterState, .available)

        let comingSoon = try NativeAPI.decode(
            AppCatalogResponse.self,
            from: try edited {
                $0["app"] = "vneid"
                $0["availability"] = "unavailable"
                $0["roster_state"] = "coming_soon"
                $0["has_surface"] = false
                $0["link"] = ["mode": "none", "state": "never_linked"]
                $0["bot"] = NSNull()
            }
        ).apps[0]
        XCTAssertEqual(comingSoon.rosterState, .comingSoon)
        XCTAssertEqual(comingSoon.availability, .unavailable)
        XCTAssertNil(comingSoon.bot)
        XCTAssertFalse(comingSoon.hasSurface)
        XCTAssertEqual(comingSoon.link.mode, .none)

        for invalid in ["hidden", "Coming_Soon", "", "available ", 1, true] as [Any] {
            XCTAssertThrowsError(try NativeAPI.decode(
                AppCatalogResponse.self,
                from: try edited { $0["roster_state"] = invalid }
            ), "unknown roster_state must fail closed: \(invalid)")
        }
        XCTAssertThrowsError(try NativeAPI.decode(
            AppCatalogResponse.self,
            from: try edited { $0["roster_state"] = NSNull() }
        ))

        // A presentation-only entry cannot smuggle executable authority.
        for mutate in [
            { (app: inout [String: Any]) in app["availability"] = "available" },
            { (app: inout [String: Any]) in app["has_surface"] = true },
            { (app: inout [String: Any]) in app["link"] = ["mode": "external_account", "state": "linked"] },
        ] {
            XCTAssertThrowsError(try NativeAPI.decode(
                AppCatalogResponse.self,
                from: try edited {
                    $0["availability"] = "unavailable"
                    $0["roster_state"] = "coming_soon"
                    $0["has_surface"] = false
                    $0["link"] = ["mode": "none", "state": "never_linked"]
                    $0["bot"] = NSNull()
                    mutate(&$0)
                }
            ))
        }
        XCTAssertThrowsError(try NativeAPI.decode(
            AppCatalogResponse.self,
            from: try edited {
                $0["availability"] = "unavailable"
                $0["roster_state"] = "coming_soon"
                $0["has_surface"] = false
                $0["link"] = ["mode": "none", "state": "never_linked"]
            }
        ), "coming soon with a bot identity is refused")
    }

    func testMobileRosterDefaultsObeyServerStateBotOrderAndPins() throws {
        func shape(_ entries: [MobileAppRosterPolicy.Entry]) -> [String] {
            entries.map { entry in
                switch entry {
                case .shortcut: return "shortcut:" + entry.app.app
                case .comingSoon: return "coming:" + entry.app.app
                }
            }
        }

        let both = try rosterCatalog()
        let moon = try XCTUnwrap(both.apps.first { $0.app == "moon" })
        XCTAssertEqual(shape(MobileAppRosterPolicy.entries(
            from: both.apps, shortcuts: absentShortcuts(both.apps)
        )), ["shortcut:moon", "coming:vneid"])

        // A bot no longer bypasses roster_default.
        let noBotDefault = try rosterCatalog(moonDefault: false)
        XCTAssertEqual(shape(MobileAppRosterPolicy.entries(
            from: noBotDefault.apps, shortcuts: absentShortcuts(noBotDefault.apps)
        )), ["coming:vneid"])
        // A pin on the bot's chosen chat is an explicit person choice.
        XCTAssertEqual(shape(MobileAppRosterPolicy.entries(
            from: noBotDefault.apps, pinned: [moon.appID],
            shortcuts: absentShortcuts(noBotDefault.apps)
        )), ["shortcut:moon", "coming:vneid"])
        // Ordering is effective roster_order, then UUID.
        let reordered = try rosterCatalog(moonOrder: 6, comingSoonOrder: 0)
        XCTAssertEqual(shape(MobileAppRosterPolicy.entries(
            from: reordered.apps, shortcuts: absentShortcuts(reordered.apps)
        )), ["coming:vneid", "shortcut:moon"])
        // A legacy missing roster_state is available.
        let legacy = try rosterCatalog(moonState: nil)
        XCTAssertEqual(MobileAppRosterPolicy.entries(
            from: legacy.apps, shortcuts: absentShortcuts(legacy.apps)
        ).map(\.app.app), ["moon", "vneid"])
        let none = try rosterCatalog(moonDefault: false, comingSoonDefault: false)
        XCTAssertEqual(MobileAppRosterPolicy.entries(
            from: none.apps, shortcuts: absentShortcuts(none.apps)
        ), [])
    }

    func testAppShortcutEventAndStateMatchTheDesktopCanonicalShape() {
        let appID = "00000000-0000-4000-8000-bd7662a5eeb4"
        XCTAssertEqual(MobileAppShortcutPolicy.eventType(appID: appID),
                       "io.atum.app_shortcut." + appID)
        XCTAssertEqual(MobileAppShortcutPolicy.eventType(appID: appID.uppercased()),
                       "io.atum.app_shortcut." + appID)
        for invalid in ["", "moon", appID + "x", "not-a-uuid",
                        "11111111-1111-1111-1111-111111111111"] {
            XCTAssertNil(MobileAppShortcutPolicy.eventType(appID: invalid), invalid)
        }

        XCTAssertEqual(MobileAppShortcutPolicy.state(contentJSON: nil), .absent)
        XCTAssertEqual(MobileAppShortcutPolicy.state(
            contentJSON: #"{"version":1,"visibility":"shown"}"#
        ), .shown)
        XCTAssertEqual(MobileAppShortcutPolicy.state(
            contentJSON: #"{"version":1,"visibility":"hidden"}"#
        ), .hidden)
        XCTAssertEqual(MobileAppShortcutPolicy.state(
            contentJSON: #"{"version":1,"visibility":"shown","future":true}"#
        ), .shown)
        for malformed in [
            #"{"version":2,"visibility":"shown"}"#,
            #"{"version":1,"visibility":"SHOWN"}"#,
            #"{"version":1,"visibility":"default"}"#,
            #"{"version":1}"#,
            #"{"version":true,"visibility":"shown"}"#,
            #"{"version":1,"visibility":true}"#,
            #""shown""#,
            "[]",
            "",
        ] {
            XCTAssertEqual(MobileAppShortcutPolicy.state(contentJSON: malformed),
                           .unknown, malformed)
        }
        XCTAssertEqual(
            MobileAppShortcutPolicy.contentJSON(visibility: .shown),
            #"{"version":1,"visibility":"shown"}"#
        )
        XCTAssertEqual(
            MobileAppShortcutPolicy.contentJSON(visibility: .hidden),
            #"{"version":1,"visibility":"hidden"}"#
        )
    }

    func testAppShortcutWriteRequiresExactReadbackAndFencesStaleScope() async {
        var writes = [String]()
        var reads = [
            #"{"version":1,"visibility":"hidden"}"#,
            #"{"version":1,"visibility":"shown"}"#,
        ]
        var pauses = 0
        var current = true
        let confirmed = await MobileAppShortcutWritePolicy.perform(
            visibility: .shown,
            attempts: 3,
            write: { writes.append($0) },
            read: { reads.removeFirst() },
            pause: { pauses += 1 },
            isCurrent: { current }
        )
        XCTAssertEqual(confirmed, .confirmed)
        XCTAssertEqual(writes, [#"{"version":1,"visibility":"shown"}"#])
        XCTAssertEqual(pauses, 1)

        let unconfirmed = await MobileAppShortcutWritePolicy.perform(
            visibility: .hidden,
            attempts: 2,
            write: { _ in },
            read: { #"{"version":1,"visibility":"shown"}"# },
            pause: {},
            isCurrent: { true }
        )
        XCTAssertEqual(unconfirmed, .unconfirmed)

        current = false
        var staleWriteCount = 0
        let staleBeforeWrite = await MobileAppShortcutWritePolicy.perform(
            visibility: .shown,
            write: { _ in staleWriteCount += 1 },
            read: { nil },
            pause: {},
            isCurrent: { current }
        )
        XCTAssertEqual(staleBeforeWrite, .stale)
        XCTAssertEqual(staleWriteCount, 0)

        current = true
        let staleAfterWrite = await MobileAppShortcutWritePolicy.perform(
            visibility: .shown,
            write: { _ in current = false },
            read: { XCTFail("a stale write must not read back"); return nil },
            pause: {},
            isCurrent: { current }
        )
        XCTAssertEqual(staleAfterWrite, .stale)
    }

    func testAppShortcutWriteReportsTransportFailureWithoutReadback() async {
        enum Refusal: Error { case denied }
        var readCount = 0
        let outcome = await MobileAppShortcutWritePolicy.perform(
            visibility: .hidden,
            write: { _ in throw Refusal.denied },
            read: { readCount += 1; return nil },
            pause: {},
            isCurrent: { true }
        )
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(readCount, 0)
    }

    func testExplicitShortcutWinsOverServerDefaultAndUnknownFailsClosed() throws {
        let both = try rosterCatalog()
        let moon = try XCTUnwrap(both.apps.first { $0.app == "moon" })
        let vneid = try XCTUnwrap(both.apps.first { $0.app == "vneid" })
        let noDefaults = try rosterCatalog(moonDefault: false, comingSoonDefault: false)

        func shape(_ entries: [MobileAppRosterPolicy.Entry]) -> [String] {
            entries.map { entry in
                switch entry {
                case .shortcut: return "shortcut:" + entry.app.app
                case .comingSoon: return "coming:" + entry.app.app
                }
            }
        }

        // Explicit shown beats a false server default for both live and
        // coming-soon rows.
        XCTAssertEqual(shape(MobileAppRosterPolicy.entries(
            from: noDefaults.apps,
            shortcuts: [moon.appID: .shown, vneid.appID: .shown]
        )), ["shortcut:moon", "coming:vneid"])

        // Explicit hidden beats a true server default.
        XCTAssertEqual(shape(MobileAppRosterPolicy.entries(
            from: both.apps,
            shortcuts: [moon.appID: .hidden, vneid.appID: .hidden]
        )), [])

        // No event follows the server default.
        XCTAssertEqual(shape(MobileAppRosterPolicy.entries(
            from: both.apps, shortcuts: absentShortcuts(both.apps)
        )), ["shortcut:moon", "coming:vneid"])

        // Loading, a failed read and malformed content never guess a default.
        for state in [MobileAppShortcutState.unknown,
                      MobileAppShortcutPolicy.state(contentJSON: "{}")] {
            XCTAssertEqual(shape(MobileAppRosterPolicy.entries(
                from: both.apps,
                shortcuts: [moon.appID: state, vneid.appID: state]
            )), [])
        }

        // A shown preference never turns an unavailable executable app into a
        // shortcut.
        var unavailableValue = try XCTUnwrap(
            JSONSerialization.jsonObject(with: appCatalogBody()) as? [String: Any]
        )
        var unavailableApps = unavailableValue["apps"] as! [[String: Any]]
        unavailableApps[0]["availability"] = "unavailable"
        unavailableValue["apps"] = unavailableApps
        let unavailable = try NativeAPI.decode(
            AppCatalogResponse.self,
            from: JSONSerialization.data(withJSONObject: unavailableValue, options: .sortedKeys)
        ).apps[0]
        XCTAssertEqual(MobileAppRosterPolicy.entries(
            from: [unavailable], shortcuts: [unavailable.appID: .shown]
        ), [])
    }

    func testAppShortcutRefreshKeepsUnknownUntilInitialSyncAndDropsLateReads() async throws {
        let both = try rosterCatalog()
        let moon = try XCTUnwrap(both.apps.first { $0.app == "moon" })
        var reads = [AppCatalogID]()
        var current = true

        @MainActor func states(canRead: Bool,
                               existing: [AppCatalogID: MobileAppShortcutState],
                               content: String?)
            async -> [AppCatalogID: MobileAppShortcutState]? {
            await MobileAppShortcutRefreshPolicy.states(
                existing: existing,
                candidates: [moon.appID],
                canReadCachedAccountData: canRead,
                read: { appID in
                    reads.append(appID)
                    return MobileAppShortcutPolicy.state(contentJSON: content)
                },
                isCurrent: { current }
            )
        }
        @MainActor func rows(_ states: [AppCatalogID: MobileAppShortcutState]?) -> [String] {
            MobileAppRosterPolicy.entries(from: [moon], shortcuts: states ?? [:])
                .map { "shortcut:" + $0.app.app }
        }

        // A hidden preference does not flash before the cache is authoritative:
        // the nil pre-sync cache result is never read and the row stays absent.
        let beforeSync = await states(canRead: false,
                                      existing: [moon.appID: .hidden],
                                      content: nil)
        XCTAssertEqual(beforeSync, [moon.appID: .unknown])
        XCTAssertTrue(reads.isEmpty)
        XCTAssertEqual(rows(beforeSync), [])

        // First-sync completion makes the same nil cache result authoritative:
        // absent follows the true server default and the row appears.
        let afterSync = await states(canRead: true,
                                     existing: beforeSync ?? [:],
                                     content: nil)
        XCTAssertEqual(afterSync, [moon.appID: .absent])
        XCTAssertEqual(reads, [moon.appID])
        XCTAssertEqual(rows(afterSync), ["shortcut:moon"])

        // An existing hidden preference still wins once the gate opens.
        let hidden = await states(
            canRead: true,
            existing: afterSync ?? [:],
            content: #"{"version":1,"visibility":"hidden"}"#
        )
        XCTAssertEqual(hidden, [moon.appID: .hidden])
        XCTAssertEqual(rows(hidden), [])

        // A read that loses its runtime/account/generation/readiness fence is
        // discarded instead of publishing a late answer from another account.
        current = false
        let late = await states(
            canRead: true,
            existing: hidden ?? [:],
            content: #"{"version":1,"visibility":"shown"}"#
        )
        XCTAssertNil(late)
    }

    func testMobileRosterHasNoLegacySuggestionCapAndDropsUnavailableBots() throws {
        let body = appCatalogBody()
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let template = (value["apps"] as! [[String: Any]])[0]
        var apps = [[String: Any]]()
        for index in 0..<5 {
            var app = template
            app["app"] = "app-\(index)"
            app["app_id"] = String(format: "00000000-0000-4000-8000-%012d", index + 1)
            app["app_version_id"] = String(format: "00000000-0000-4000-8000-%012d", index + 101)
            app["roster_default"] = true
            app["roster_order"] = index
            app["availability"] = "available"
            app["has_surface"] = true
            if index > 0 { app["bot"] = NSNull() }
            apps.append(app)
        }
        value["apps"] = apps
        let catalog = try NativeAPI.decode(
            AppCatalogResponse.self,
            from: JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        )
        XCTAssertEqual(MobileAppRosterPolicy.entries(
            from: catalog.apps, shortcuts: absentShortcuts(catalog.apps)
        ).count, 5, "the server default set is not client-capped")

        var unavailableValue = value
        var unavailableApps = unavailableValue["apps"] as! [[String: Any]]
        unavailableApps[0]["availability"] = "unavailable"
        unavailableValue["apps"] = unavailableApps
        let unavailable = try NativeAPI.decode(
            AppCatalogResponse.self,
            from: JSONSerialization.data(withJSONObject: unavailableValue, options: .sortedKeys)
        )
        XCTAssertEqual(MobileAppRosterPolicy.entries(
            from: unavailable.apps, shortcuts: absentShortcuts(unavailable.apps)
        ).count, 4, "an unavailable app never becomes a shortcut")
    }

    func test401RefreshesOnceAndRetriesOnce() async throws {
        let authorization = TestAuthorization(first: "p2-old-token", refreshed: "p2-new-token")
        let body = Data("{\"error\":\"matrix_401\"}".utf8)
        NativeDomainProtocol.state.handler = { _ in .init(status: 401, chunks: [body]) }
        do {
            _ = try await client(authorization).wallet()
            XCTFail("Second 401 accepted")
        } catch let failure as NativeDomainClientFailure {
            guard case let .http(http) = failure else { return XCTFail("Unexpected failure \(failure)") }
            XCTAssertEqual(http.response.error, .unauthenticated)
        }
        XCTAssertEqual(authorization.normalCalls, 1)
        XCTAssertEqual(authorization.refreshCalls, 1)
        XCTAssertEqual(NativeDomainProtocol.state.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, [
            "Bearer p2-old-token", "Bearer p2-new-token"
        ])
    }

    func testAuthorizationAndTerminal401FailuresNotifyDomainRecovery() async throws {
        var observed = [MobileDomainRecoveryState]()
        let interrupted = NativeDomainClient(
            testAuthorization: { _ in throw OIDCGrantFailure.refreshInterrupted },
            protocolClasses: [NativeDomainProtocol.self],
            onAuthenticationFailure: { observed.append(MobileDomainRecoveryPolicy.state(for: $0)) }
        )
        do {
            _ = try await interrupted.wallet()
            XCTFail("interrupted grant authorized a request")
        } catch {
            XCTAssertEqual(error as? OIDCGrantFailure, .refreshInterrupted)
        }
        XCTAssertEqual(observed, [.reauthenticationRequired])
        XCTAssertTrue(NativeDomainProtocol.state.requests.isEmpty)

        NativeDomainProtocol.state.reset()
        observed.removeAll()
        let authorization = TestAuthorization(first: "p2-old-token", refreshed: "p2-new-token")
        let body = Data("{\"error\":\"matrix_401\"}".utf8)
        NativeDomainProtocol.state.handler = { _ in .init(status: 401, chunks: [body]) }
        let refused = NativeDomainClient(
            testAuthorization: { forceRefresh in
                try authorization.token(forceRefresh: forceRefresh)
            },
            protocolClasses: [NativeDomainProtocol.self],
            onAuthenticationFailure: { observed.append(MobileDomainRecoveryPolicy.state(for: $0)) }
        )
        do {
            _ = try await refused.wallet()
            XCTFail("second 401 accepted")
        } catch let failure as NativeDomainClientFailure {
            guard case let .http(http) = failure else { return XCTFail("Unexpected failure \(failure)") }
            XCTAssertEqual(http.response.error, .unauthenticated)
        }
        XCTAssertEqual(observed, [.reauthenticationRequired])
        XCTAssertEqual(NativeDomainProtocol.state.requests.count, 2)
    }

    func testHTTPFailurePreservesRetryAfterWithoutBodyOrTokenLeakage() async throws {
        let token = "p2-secret-token-must-not-leak"
        let authorization = TestAuthorization(first: token)
        let privateBody = "private server body " + token
        NativeDomainProtocol.state.handler = { _ in
            .init(status: 429, headers: ["Content-Type": "application/json", "Retry-After": "120"],
                  chunks: [Data("{\"error\":\"matrix_429\"}".utf8)])
        }
        do {
            _ = try await client(authorization).agents()
            XCTFail("Rate limit accepted")
        } catch let failure as NativeDomainClientFailure {
            guard case let .http(http) = failure else { return XCTFail("Unexpected failure \(failure)") }
            XCTAssertEqual(http.retryAfterSeconds, 120)
        }

        NativeDomainProtocol.state.reset()
        NativeDomainProtocol.state.handler = { _ in .init(status: 400, chunks: [Data(privateBody.utf8)]) }
        do {
            _ = try await client(authorization).wallet()
            XCTFail("Undecodable private body accepted")
        } catch {
            let text = String(describing: error) + String(reflecting: error)
            XCTAssertFalse(text.contains(token))
            XCTAssertFalse(text.contains(privateBody))
        }
    }

    func testRedirectCancellationAndResponseBoundsAreRefused() async throws {
        let authorization = TestAuthorization(first: "p2-bound-token")
        let value = client(authorization)
        let variants: [(NativeDomainProtocol.Reply, NativeDomainClientFailure)] = [
            (.init(headers: ["Content-Type": "text/html"], chunks: [Data("<html>".utf8)]), .invalidResponse),
            (.init(headers: ["Content-Type": "application/json", "Content-Length": "262145"]), .responseTooLarge),
            (.init(chunks: [Data(repeating: 120, count: 131_072), Data(repeating: 120, count: 131_073)]), .responseTooLarge),
            (.init(chunks: [Data("{}".utf8)], responseURL: URL(string: "https://foreign.invalid/response")!), .invalidResponse),
            (.init(redirect: URL(string: "https://foreign.invalid/credential")!), .redirectRefused)
        ]
        for (reply, expected) in variants {
            NativeDomainProtocol.state.handler = { _ in reply }
            do {
                _ = try await value.wallet()
                XCTFail("Unsafe response accepted")
            } catch let failure as NativeDomainClientFailure {
                XCTAssertEqual(failure, expected)
            }
        }
        XCTAssertFalse(NativeDomainProtocol.state.requests.contains { $0.url?.host == "foreign.invalid" })

        NativeDomainProtocol.state.reset()
        let started = expectation(description: "request started")
        NativeDomainProtocol.state.handler = { _ in started.fulfill(); return .init(held: true) }
        let task = Task { try await value.wallet() }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled request completed")
        } catch let failure as NativeDomainClientFailure {
            XCTAssertEqual(failure, .cancelled)
        }
        XCTAssertEqual(NativeDomainProtocol.state.requests.count, 1)

        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await value.wallet()
        }
        do {
            _ = try await preCancelled.value
            XCTFail("Pre-cancelled request started")
        } catch let failure as NativeDomainClientFailure {
            XCTAssertEqual(failure, .cancelled)
        }
        XCTAssertEqual(NativeDomainProtocol.state.requests.count, 1)
    }

    func testCancellationWhileAuthorizationIsPendingNeverStartsARequest() async throws {
        let gate = AuthorizationGate()
        let value = NativeDomainClient(testAuthorization: { _ in
            await gate.token()
        }, protocolClasses: [NativeDomainProtocol.self])
        let task = Task { try await value.wallet() }
        await gate.waitUntilStarted()
        task.cancel()
        gate.release("p2-never-sent-token")

        do {
            _ = try await task.value
            XCTFail("Cancelled authorization started a request")
        } catch let failure as NativeDomainClientFailure {
            XCTAssertEqual(failure, .cancelled)
        }
        XCTAssertTrue(NativeDomainProtocol.state.requests.isEmpty)
    }

    // MARK: Company workspace (B19 S4)

    private func companyFixture(_ name: String) throws -> Data {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "company-workspace-v1.1", withExtension: nil))
        return try Data(contentsOf: base.appendingPathComponent(name))
    }

    func testCompanyListSendsTheOneOneHeaderAndReportsV1() async throws {
        NativeDomainProtocol.state.handler = { _ in
            .json(try! self.companyFixture("v1.list.response.json"))
        }
        let read = try await client(TestAuthorization(first: "token")).companyList()
        XCTAssertEqual(read, .v1)
        let request = try XCTUnwrap(NativeDomainProtocol.state.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/matrix/v1/companies")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Atum-Company-Wire"), "1.1")
        XCTAssertNil(request.url?.query)
    }

    func testCompanyListDecodesTheOneOneDirectory() async throws {
        NativeDomainProtocol.state.handler = { _ in
            .json(try! self.companyFixture("list.response.json"))
        }
        let read = try await client(TestAuthorization(first: "token")).companyList()
        let value = try XCTUnwrap(read.value)
        XCTAssertEqual(value.companies.count, 1)
        XCTAssertEqual(value.invitations.first?.inviter.handle, "minh")
        XCTAssertTrue(value.canCreate)
    }

    func testAcceptPostsTheExactBodyUnderTheHeader() async throws {
        let company = try NativeID("00000000-0000-4000-8000-2a39c7cf131c")
        let requestID = try NativeID("00000000-0000-4000-8000-175097128f22")
        let invitationID = try NativeID("00000000-0000-4000-8000-55301f2eb1d3")
        NativeDomainProtocol.state.handler = { _ in
            .json(try! self.companyFixture("snapshot-member.response.json"))
        }
        let snapshot = try await client(TestAuthorization(first: "token"))
            .acceptCompanyInvitation(companyID: company, requestID: requestID,
                                     invitationID: invitationID)
        XCTAssertEqual(snapshot.company.id, company)
        let request = try XCTUnwrap(NativeDomainProtocol.state.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path,
                       "/api/matrix/v1/companies/00000000-0000-4000-8000-2a39c7cf131c/accept")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Atum-Company-Wire"), "1.1")
        let body = try XCTUnwrap(body(of: request))
        let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(object, ["requestId": "00000000-0000-4000-8000-175097128f22",
                                "invitationId": "00000000-0000-4000-8000-55301f2eb1d3"])
    }

    func testAcceptRefusesAnAnswerForAnotherCompany() async throws {
        let company = try NativeID("00000000-0000-4000-8000-2a39c7cf131c")
        NativeDomainProtocol.state.handler = { _ in
            var body = try! JSONSerialization.jsonObject(
                with: try! self.companyFixture("snapshot-member.response.json")) as! [String: Any]
            var value = body["company"] as! [String: Any]
            value["id"] = "00000000-0000-4000-8000-48f58564068b"
            body["company"] = value
            return .json(try! JSONSerialization.data(withJSONObject: body))
        }
        do {
            _ = try await client(TestAuthorization(first: "token"))
                .acceptCompanyInvitation(
                    companyID: company,
                    requestID: try NativeID("00000000-0000-4000-8000-175097128f22"),
                    invitationID: try NativeID("00000000-0000-4000-8000-55301f2eb1d3"))
            XCTFail("a snapshot for another company must be refused")
        } catch let error as CompanyAPIError {
            XCTAssertEqual(error, .invalid)
        }
    }

    func testLeavePostsTheRequestAndKeepsRevoking() async throws {
        let company = try NativeID("00000000-0000-4000-8000-2a39c7cf131c")
        let requestID = try NativeID("00000000-0000-4000-8000-175097128f22")
        NativeDomainProtocol.state.handler = { _ in
            .json(try! self.companyFixture("leave.response.json"))
        }
        let acknowledgement = try await client(TestAuthorization(first: "token"))
            .leaveCompany(companyID: company, requestID: requestID)
        XCTAssertEqual(acknowledgement.state, .revoking)
        XCTAssertFalse(acknowledgement.isFinished)
        let request = try XCTUnwrap(NativeDomainProtocol.state.requests.first)
        XCTAssertEqual(request.url?.path,
                       "/api/matrix/v1/companies/00000000-0000-4000-8000-2a39c7cf131c/leave")
        let body = try XCTUnwrap(body(of: request))
        let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(object, ["requestId": "00000000-0000-4000-8000-175097128f22"])
    }

    func testCreateCompanyPostsTheExactBodyToTheCollectionUnderTheHeader() async throws {
        let requestID = try NativeID("00000000-0000-4000-8000-175097128f22")
        NativeDomainProtocol.state.handler = { _ in
            .json(try! self.companyFixture("snapshot-create.response.json"))
        }
        let snapshot = try await client(TestAuthorization(first: "token"))
            .createCompany(requestID: requestID, displayName: "Công ty Atum")
        XCTAssertEqual(snapshot.company.displayName, "Công ty Atum")
        XCTAssertEqual(snapshot.company.role, .admin)
        XCTAssertNotNil(snapshot.defaultChannelId, "create seeds the default channel")
        let request = try XCTUnwrap(NativeDomainProtocol.state.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/matrix/v1/companies")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Atum-Company-Wire"), "1.1")
        let body = try XCTUnwrap(body(of: request))
        let object = try JSONSerialization.jsonObject(with: body) as? [String: String]
        XCTAssertEqual(object, ["requestId": "00000000-0000-4000-8000-175097128f22",
                                "displayName": "Công ty Atum"],
                       "exactly the two keys the platform accepts")
    }

    func testCreateCompanyAV1AnswerDegradesInsteadOfShowingAMistakeInTheName() async throws {
        NativeDomainProtocol.state.handler = { _ in
            .json(try! self.companyFixture("v1.snapshot.response.json"))
        }
        do {
            _ = try await client(TestAuthorization(first: "token"))
                .createCompany(requestID: try NativeID("00000000-0000-4000-8000-175097128f22"),
                               displayName: "Công ty Atum")
            XCTFail("a v1 snapshot must not be widened into a created company")
        } catch let refusal as CompanyWireRefusal {
            XCTAssertEqual(refusal, .v1Answer)
        }
    }

    func testCreateCompanyKeepsThePlatformsClosedRefusalAsItsOwnReason() async throws {
        NativeDomainProtocol.state.handler = { _ in
            .init(status: 403, chunks: [try! self.companyFixture("error-creation-closed.response.json")])
        }
        do {
            _ = try await client(TestAuthorization(first: "token"))
                .createCompany(requestID: try NativeID("00000000-0000-4000-8000-175097128f22"),
                               displayName: "Công ty Atum")
            XCTFail("a refused create must throw")
        } catch let error as CompanyAPIError {
            XCTAssertEqual(error, .refused(.denied, reason: "company_creation_closed", retryAfter: nil))
            XCTAssertEqual(CompanyCreateFailure(error), .closed)
        }
    }

    func testCreateCompanyNeverSendsANameThePlatformWouldRefuse() async throws {
        NativeDomainProtocol.state.handler = { _ in
            .json(try! self.companyFixture("snapshot-create.response.json"))
        }
        let requestID = try NativeID("00000000-0000-4000-8000-175097128f22")
        for name in [" padded", "padded ", "", "line\nbreak", String(repeating: "a", count: 121)] {
            do {
                _ = try await client(TestAuthorization(first: "token"))
                    .createCompany(requestID: requestID, displayName: name)
                XCTFail("\(name.debugDescription) must be shaped before it is sent")
            } catch let error as CompanyAPIError {
                XCTAssertEqual(error, .invalid)
            }
        }
        XCTAssertTrue(NativeDomainProtocol.state.requests.isEmpty, "nothing reached the network")
    }

    func testAppOnboardingUsesOnlyTypedIOSBodiesAndNarrowRoutes() async throws {
        let initiation = "00000000-0000-4000-8000-3cdc9c4bc004"
        let version = "00000000-0000-4000-8000-088a99dcb870"
        let returnCode = String(repeating: "R", count: 43)
        let launchCode = String(repeating: "L", count: 43)
        NativeDomainProtocol.state.handler = { request in
            let path = request.url!.path
            let payload: String
            switch path {
            case "/api/matrix/v1/apps/moon/bot/consent":
                payload = """
                {"profile":"atum.app-bot-status/1","bot":null,
                 "consent":{"state":"accepted","disclosure_version":3,"locale":"vi","accepted_at":"2026-10-20T10:00:00.000Z"},
                 "link":{"state":"never_linked","ready":false,"available":false},"room_id":null}
                """
            case "/api/matrix/v1/apps/moon/connect":
                payload = "{\"authorize_url\":\"https://moon.atumplatform.com/atum/lien-ket?claim_ticket=fixture\",\"initiation_id\":\"\(initiation)\"}"
            case "/api/matrix/v1/apps/moon/connect/confirm":
                payload = "{\"status\":\"confirmed\"}"
            case "/api/matrix/v1/apps/moon/launch":
                payload = "{\"launch_url\":\"https://moon.atumplatform.com/atum/launch?code=\(launchCode)\",\"expires_at\":\"2026-10-20T10:01:00.000Z\"}"
            default:
                return .init(status: 404, chunks: [Data("{\"error\":\"matrix_404\"}".utf8)])
            }
            return .json(Data(payload.utf8))
        }
        let value = client(TestAuthorization(first: "phone-domain-token"))
        _ = try await value.acceptAppBotConsent(
            slug: "moon", value: try AppBotConsentRequest(disclosureVersion: 3, locale: .vietnamese)
        )
        let nonce = try AppLinkNonce(bytes: Data(repeating: 5, count: 32))
        let connect = try await value.beginAppConnection(slug: "moon", value: AppLinkConnectRequest(nonce: nonce))
        let callback = URL(string: nonce.redirectURL.absoluteString
                           + "?code=\(returnCode)&initiation_id=\(initiation)")!
        let proof = try AppLinkReturnProof.parse(callback, nonce: nonce,
                                                 initiationID: connect.initiationID)
        _ = try await value.confirmAppConnection(
            slug: "moon", value: try AppLinkConfirmRequest(proof: proof, disclosureVersion: 3)
        )
        let versionData = Data("""
        {"profile":"atum.app-workspace/1","descriptor":{"app":"moon","app_version_id":"\(version)"},
         "manifest":{"profile":"atum.remote-app-manifest/1","app":{"slug":"moon","app_version_id":"\(version)"},"launch":{},"routes":[]},
         "web_origin":"https://moon.atumplatform.com","network_origins":[]}
        """.utf8)
        let appVersion = try NativeAPI.decode(AppWorkspaceSnapshot.self, from: versionData).appVersionID
        _ = try await value.launchApp(
            slug: "moon", value: try AppLaunchRequest(appVersionID: appVersion, routeID: "readings")
        )

        XCTAssertEqual(NativeDomainProtocol.state.requests.map { $0.url?.path }, [
            "/api/matrix/v1/apps/moon/bot/consent",
            "/api/matrix/v1/apps/moon/connect",
            "/api/matrix/v1/apps/moon/connect/confirm",
            "/api/matrix/v1/apps/moon/launch",
        ])
        let bodies = try NativeDomainProtocol.state.requests.map { request -> [String: Any] in
            let data = try XCTUnwrap(body(of: request))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        XCTAssertEqual(Set(bodies[0].keys), ["disclosure_version", "locale"])
        XCTAssertNil(bodies[0]["accepted_via"])
        XCTAssertEqual(Set(bodies[1].keys), ["redirect_uri"])
        XCTAssertEqual(Set(bodies[2].keys), ["initiation_id", "return_code", "confirmation", "consent_provenance"])
        XCTAssertNil(bodies[2]["accepted_via"])
        XCTAssertEqual(Set(bodies[3].keys), ["app_version_id", "route_id"])
    }

    // MARK: Canonical-room arbitration (`POST /apps/{slug}/bot/start`)

    func testBotStartSendsTheRequestAndReadsEveryAnswerIgnoringUnknownFields() async throws {
        let replies = [
            #"{"state":"ready","roomId":"!room:example.invalid","botUserId":"@app-acme:atumplatform.com","extra":{"x":1}}"#,
            #"{"state":"create","botUserId":"@app-acme:atumplatform.com","hint":"later"}"#,
            #"{"state":"unavailable","reason":"not_published","note":"n"}"#,
            #"{"state":"unavailable","reason":"a_future_reason"}"#,
        ]
        var next = 0
        NativeDomainProtocol.state.handler = { _ in
            defer { next += 1 }
            return .json(Data(replies[next].utf8))
        }
        let value = client(TestAuthorization(first: "phone-domain-token"))
        let id = UUID()
        let request = try AppBotStartRequest(requestID: id, appVersion: "v1", roomID: "!mine:example.invalid")
        let ready = try await value.startAppBot(slug: "acme", value: request)
        XCTAssertEqual(ready, .answer(.ready(roomID: "!room:example.invalid",
                                             botUserID: "@app-acme:atumplatform.com")))
        let create = try await value.startAppBot(slug: "acme", value: request)
        XCTAssertEqual(create, .answer(.create(botUserID: "@app-acme:atumplatform.com")))
        let unpublished = try await value.startAppBot(slug: "acme", value: request)
        XCTAssertEqual(unpublished, .answer(.unavailable(.notPublished)))
        let future = try await value.startAppBot(slug: "acme", value: request)
        XCTAssertEqual(future, .answer(.unavailable(.other)))

        let sent = NativeDomainProtocol.state.requests
        XCTAssertEqual(Set(sent.map { $0.url?.path }), ["/api/matrix/v1/apps/acme/bot/start"])
        XCTAssertEqual(sent.first?.httpMethod, "POST")
        XCTAssertEqual(sent.first?.value(forHTTPHeaderField: "Authorization"), "Bearer phone-domain-token")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(body(of: try XCTUnwrap(sent.first)))) as? [String: String])
        XCTAssertEqual(object, ["requestId": id.uuidString.lowercased(), "appVersion": "v1",
                                "roomId": "!mine:example.invalid"])
        // Optional fields are left out, not sent null.
        let bare = try AppBotStartRequest(requestID: id)
        let bareObject = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(bare)) as? [String: String])
        XCTAssertEqual(bareObject, ["requestId": id.uuidString.lowercased()])
        XCTAssertThrowsError(try AppBotStartRequest(roomID: "not-a-room"))
    }

    func testBotStartOnAnOlderShellIsRouteAbsentAndOtherFailuresAreNotAFallback() async throws {
        let value = client(TestAuthorization(first: "phone-domain-token"))
        let request = try AppBotStartRequest()
        // A 404 with the Matrix error, with another JSON body, and with no body.
        for reply in [
            NativeDomainProtocol.Reply(status: 404, chunks: [Data("{\"error\":\"matrix_404\"}".utf8)]),
            NativeDomainProtocol.Reply(status: 404, chunks: [Data("{\"error\":\"not_found\"}".utf8)]),
            NativeDomainProtocol.Reply(status: 404),
            .json(Data(#"{"state":"not_found"}"#.utf8)),
        ] {
            NativeDomainProtocol.state.handler = { _ in reply }
            let result = try await value.startAppBot(slug: "acme", value: request)
            XCTAssertEqual(result, .routeAbsent)
        }
        // A refusal the route itself made is an error: no fallback to local creation.
        NativeDomainProtocol.state.handler = { _ in
            .init(status: 503, chunks: [Data("{\"error\":\"matrix_503\"}".utf8)])
        }
        do {
            _ = try await value.startAppBot(slug: "acme", value: request)
            XCTFail("a 503 must surface")
        } catch let failure as NativeDomainClientFailure {
            guard case let .http(http) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(http.response.error, .unavailable)
        }
        // The shared transport refuses any non-JSON response (an HTML 404 from an
        // edge in front of an older Shell included): that is an error, as for
        // every other route, not a silent fallback.
        NativeDomainProtocol.state.handler = { _ in
            .init(status: 404, headers: ["Content-Type": "text/html"], chunks: [Data("<h1>Not Found</h1>".utf8)])
        }
        do {
            _ = try await value.startAppBot(slug: "acme", value: request)
            XCTFail("a non-JSON reply is not an answer")
        } catch let failure as NativeDomainClientFailure {
            XCTAssertEqual(failure, .invalidResponse)
        }
        // An unknown state is refused, not guessed.
        NativeDomainProtocol.state.handler = { _ in .json(Data(#"{"state":"maybe"}"#.utf8)) }
        do {
            _ = try await value.startAppBot(slug: "acme", value: request)
            XCTFail("unknown state")
        } catch let failure as NativeDomainClientFailure {
            XCTAssertEqual(failure, .invalidResponse)
        }
    }
}

@MainActor private final class TestAuthorization: @unchecked Sendable {
    private let first: String
    private let refreshed: String?
    private(set) var normalCalls = 0
    private(set) var refreshCalls = 0

    init(first: String, refreshed: String? = nil) {
        self.first = first
        self.refreshed = refreshed
    }

    func token(forceRefresh: Bool) throws -> String {
        if forceRefresh {
            refreshCalls += 1
            guard let refreshed else { throw OIDCGrantFailure.reauthenticationRequired }
            return refreshed
        }
        normalCalls += 1
        return first
    }
}

@MainActor private final class AuthorizationGate: @unchecked Sendable {
    private var continuation: CheckedContinuation<String, Never>?
    private var started = false

    func token() async -> String {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release(_ token: String) {
        continuation?.resume(returning: token)
        continuation = nil
    }
}

private final class NativeDomainProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: @unchecked Sendable {
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var chunks: [Data] = []
        var responseURL: URL? = nil
        var error: Error? = nil
        var redirect: URL? = nil
        var held = false
        static func json(_ data: Data) -> Self { .init(chunks: [data]) }
        static func agentHome(_ data: Data, status: Int = 200) -> Self {
            .init(status: status,
                  headers: ["Content-Type": "application/json",
                            AgentHomeContract.wireHeader: AgentHomeContract.profile],
                  chunks: [data])
        }
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var block: ((URLRequest) -> Reply)?
        private var observed: [URLRequest] = []
        var handler: ((URLRequest) -> Reply)? {
            get { lock.withLock { block } }
            set { lock.withLock { block = newValue } }
        }
        var requests: [URLRequest] { lock.withLock { observed } }
        func receive(_ request: URLRequest) -> Reply {
            let action = lock.withLock { observed.append(request); return block }
            return action?(request) ?? .init(error: URLError(.unsupportedURL))
        }
        func reset() { lock.withLock { block = nil; observed = [] } }
    }

    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.atumplatform.com" || request.url?.host == "foreign.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.receive(request)
        if reply.held { return }
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        if let target = reply.redirect {
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: reply.responseURL ?? request.url!, statusCode: reply.status,
                                       httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for data in reply.chunks { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

// MARK: Agent home (wire 2.5)

extension NativeDomainClientTests {
    private func agentHomePack(_ name: String) throws -> Data {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "agent-home-v2.5", withExtension: nil))
        return try Data(contentsOf: base.appendingPathComponent("fixtures/" + name))
    }

    private func assertPhoneOwnerWrite(_ sent: URLRequest, fixture name: String,
                                       file: StaticString = #filePath, line: UInt = #line) throws {
        var actual = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(body(of: sent), file: file, line: line)
        ) as? [String: Any], file: file, line: line)
        var expected = try XCTUnwrap(JSONSerialization.jsonObject(
            with: agentHomePack(name)
        ) as? [String: Any], file: file, line: line)
        let meta = try XCTUnwrap(actual.removeValue(forKey: "meta") as? [String: String],
                                 file: file, line: line)
        let expectedMeta = try XCTUnwrap(expected.removeValue(forKey: "meta") as? [String: String],
                                         file: file, line: line)
        XCTAssertEqual(Set(meta.keys), ["requestId", "surface", "authenticatedChannel"],
                       file: file, line: line)
        XCTAssertEqual(meta["surface"], "phone", file: file, line: line)
        XCTAssertEqual(meta["authenticatedChannel"], "phone", file: file, line: line)
        XCTAssertNoThrow(try NativeID(XCTUnwrap(meta["requestId"])), file: file, line: line)
        XCTAssertEqual(meta["requestId"], expectedMeta["requestId"],
                       "the client sends the request ID the caller made, never one of its own",
                       file: file, line: line)
        XCTAssertEqual(Set(expectedMeta.keys), Set(meta.keys), file: file, line: line)
        XCTAssertEqual(actual as NSDictionary, expected as NSDictionary, file: file, line: line)
    }

    func testAgentHomeReadsUseOnlyTheExactAllowlistedPaths() async throws {
        let agent = try NativeID("00000000-0000-4000-8000-bd7662a5eeb4")
        let device = try NativeID("00000000-0000-4000-8000-b454f82c5857")
        let move = try NativeID("00000000-0000-4000-8000-303617b97302")
        NativeDomainProtocol.state.handler = { request in
            switch request.url!.path {
            case "/api/matrix/v1/agents/\(agent.rawValue)/home/owner":
                .agentHome(try! self.agentHomePack("owner.placement.snapshot.json"))
            case "/api/matrix/v1/agents/\(agent.rawValue)/home/catalogs/\(device.rawValue)":
                .agentHome(try! self.agentHomePack("mac.connection-catalog.fresh.json"))
            case "/api/matrix/v1/agents/\(agent.rawValue)/home/owner/model-choice/application":
                .agentHome(try! self.agentHomePack("model-choice.projection.applied.json"))
            case "/api/matrix/v1/agents/\(agent.rawValue)/home/owner/moves/\(move.rawValue)":
                .agentHome(try! self.agentHomePack("owner.move.progress.ready.json"))
            default: .init(status: 404)
            }
        }
        let value = client(TestAuthorization(first: "phone-domain-token"))
        _ = try await value.agentHome(agentPrincipal: agent)
        _ = try await value.agentHomeCatalog(agentPrincipal: agent, deviceServiceID: device)
        _ = try await value.agentHomeModelApplication(agentPrincipal: agent)
        _ = try await value.agentHomeMoveProgress(agentPrincipal: agent, moveID: move)

        let sent = NativeDomainProtocol.state.requests
        XCTAssertEqual(sent.map(\.httpMethod), ["GET", "GET", "GET", "GET"])
        XCTAssertEqual(sent.map { $0.url?.query }, [nil, nil, nil, nil])
        XCTAssertTrue(sent.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer phone-domain-token" })
        XCTAssertTrue(sent.allSatisfy {
            $0.value(forHTTPHeaderField: AgentHomeContract.wireHeader) == AgentHomeContract.wireVersion
        })
    }

    func testAgentHomePreflightSendsBearerOnlyMetadataAndRefusesRedirects() async throws {
        let fixtureName = "owner.move.preflight-request.unsigned-phone.json"
        let fixture = try agentHomePack(fixtureName)
        let request = try NativeAPI.decode(AgentHomePreflightRequest.self, from: fixture)
        NativeDomainProtocol.state.handler = { _ in
            .agentHome(try! self.agentHomePack("owner.move.preflight.actual-losses.json"))
        }
        let value = client(TestAuthorization(first: "token"))
        _ = try await value.preflightAgentHomeMove(request.input, requestID: request.meta.requestID)
        let sent = try XCTUnwrap(NativeDomainProtocol.state.requests.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url?.path,
                       "/api/matrix/v1/agents/00000000-0000-4000-8000-bd7662a5eeb4/home/owner/preflight")
        XCTAssertEqual(sent.value(forHTTPHeaderField: AgentHomeContract.wireHeader),
                       AgentHomeContract.wireVersion)
        XCTAssertNil(sent.url?.query)
        try assertPhoneOwnerWrite(sent, fixture: fixtureName)

        NativeDomainProtocol.state.reset()
        NativeDomainProtocol.state.handler = { _ in .init(redirect: URL(string: "https://foreign.invalid/steal")!) }
        do {
            _ = try await value.preflightAgentHomeMove(request.input, requestID: request.meta.requestID)
            XCTFail("owner commands must never follow a redirect")
        } catch let failure as NativeDomainClientFailure {
            XCTAssertEqual(failure, .redirectRefused)
        }
    }

    func testAgentHomeMoveCancelAndModelWriteUseTheirSourceAwareRoutes() async throws {
        let value = client(TestAuthorization(first: "token"))
        let moveRequest = try NativeAPI.decode(AgentHomeMoveRequest.self,
                                               from: agentHomePack("owner.move.request.unsigned-phone.json"))
        let cancelRequest = try NativeAPI.decode(AgentHomeCancelRequest.self,
                                                 from: agentHomePack("owner.move.cancel.unsigned-phone.json"))
        let modelRequest = try NativeAPI.decode(AgentHomeModelChoiceWrite.self,
                                                from: agentHomePack("owner.model-choice.write.unsigned-phone.json"))
        NativeDomainProtocol.state.handler = { request in
            if request.httpMethod == "DELETE" {
                return .agentHome(try! self.agentHomePack("owner.move.progress.failed.owner_cancelled.json"))
            }
            if request.httpMethod == "PUT" {
                return .agentHome(try! self.agentHomePack("owner.model-choice.receipt.json"))
            }
            return .agentHome(try! self.agentHomePack("owner.move.progress.finishing.json"), status: 202)
        }
        _ = try await value.moveAgentHome(moveRequest.input, requestID: moveRequest.meta.requestID)
        _ = try await value.cancelAgentHomeMove(cancelRequest.input, requestID: cancelRequest.meta.requestID)
        _ = try await value.writeAgentHomeModelChoice(modelRequest.input,
                                                      requestID: modelRequest.meta.requestID)
        XCTAssertEqual(NativeDomainProtocol.state.requests.map(\.httpMethod), ["POST", "DELETE", "PUT"])
        XCTAssertEqual(NativeDomainProtocol.state.requests.map { $0.url!.path }, [
            "/api/matrix/v1/agents/00000000-0000-4000-8000-bd7662a5eeb4/home/owner/moves",
            "/api/matrix/v1/agents/00000000-0000-4000-8000-bd7662a5eeb4/home/owner/moves",
            "/api/matrix/v1/agents/00000000-0000-4000-8000-bd7662a5eeb4/home/owner/model-choice",
        ])
        try assertPhoneOwnerWrite(NativeDomainProtocol.state.requests[0],
                                  fixture: "owner.move.request.unsigned-phone.json")
        try assertPhoneOwnerWrite(NativeDomainProtocol.state.requests[1],
                                  fixture: "owner.move.cancel.unsigned-phone.json")
        try assertPhoneOwnerWrite(NativeDomainProtocol.state.requests[2],
                                  fixture: "owner.model-choice.write.unsigned-phone.json")
    }

    /// 2.5: a retry of one logical owner write reuses BOTH the bearer request ID
    /// and the operation idempotency key, so the platform sees one request twice,
    /// not two requests that happen to share a key.
    func testAgentHomeOwnerWriteRetryRepeatsTheRequestIDAndTheIdempotencyKey() async throws {
        let preflight = try NativeAPI.decode(AgentHomePreflightRequest.self,
                                             from: agentHomePack("owner.move.preflight-request.unsigned-phone.json"))
        let move = try NativeAPI.decode(AgentHomeMoveRequest.self,
                                        from: agentHomePack("owner.move.request.unsigned-phone.json"))
        let cancel = try NativeAPI.decode(AgentHomeCancelRequest.self,
                                          from: agentHomePack("owner.move.cancel.unsigned-phone.json"))
        let model = try NativeAPI.decode(AgentHomeModelChoiceWrite.self,
                                         from: agentHomePack("owner.model-choice.write.unsigned-phone.json"))
        NativeDomainProtocol.state.handler = { request in
            if request.httpMethod == "DELETE" {
                return .agentHome(try! self.agentHomePack("owner.move.progress.failed.owner_cancelled.json"))
            }
            if request.httpMethod == "PUT" {
                return .agentHome(try! self.agentHomePack("owner.model-choice.receipt.json"))
            }
            if request.url?.path.hasSuffix("/owner/preflight") == true {
                return .agentHome(try! self.agentHomePack("owner.move.preflight.actual-losses.json"))
            }
            return .agentHome(try! self.agentHomePack("owner.move.progress.finishing.json"), status: 202)
        }
        let value = client(TestAuthorization(first: "token"))
        for _ in 0..<2 {
            _ = try await value.preflightAgentHomeMove(preflight.input, requestID: preflight.meta.requestID)
            _ = try await value.moveAgentHome(move.input, requestID: move.meta.requestID)
            _ = try await value.cancelAgentHomeMove(cancel.input, requestID: cancel.meta.requestID)
            _ = try await value.writeAgentHomeModelChoice(model.input, requestID: model.meta.requestID)
        }

        let sent = NativeDomainProtocol.state.requests
        XCTAssertEqual(sent.count, 8)
        let bodies = try sent.map { request in
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body(of: request))) as? NSDictionary)
        }
        let identities: [(request: NativeID, key: NativeID)] = [
            (preflight.meta.requestID, preflight.input.idempotencyKey),
            (move.meta.requestID, move.input.idempotencyKey),
            (cancel.meta.requestID, cancel.input.idempotencyKey),
            (model.meta.requestID, model.input.idempotencyKey),
        ]
        for (index, body) in bodies.enumerated() {
            let identity = identities[index % 4]
            let meta = try XCTUnwrap(body["meta"] as? [String: String])
            XCTAssertEqual(meta["requestId"], identity.request.rawValue,
                           "write \(index % 4) must repeat its request ID on a retry")
            XCTAssertEqual(body["idempotencyKey"] as? String, identity.key.rawValue,
                           "write \(index % 4) must repeat its idempotency key on a retry")
        }
        for offset in 0..<4 {
            XCTAssertEqual(bodies[offset], bodies[offset + 4],
                           "a retry is byte-for-byte the same request, not a fresh one")
        }
    }

    /// The client has no request-ID source of its own: another logical operation
    /// is the caller handing it another ID.
    func testAgentHomeOwnerWriteNeverMakesARequestIDOfItsOwn() async throws {
        let request = try NativeAPI.decode(AgentHomePreflightRequest.self,
                                           from: agentHomePack("owner.move.preflight-request.unsigned-phone.json"))
        NativeDomainProtocol.state.handler = { _ in
            .agentHome(try! self.agentHomePack("owner.move.preflight.actual-losses.json"))
        }
        let value = client(TestAuthorization(first: "token"))
        let other = try NativeID("00000000-0000-4000-8000-f2da1f9533d4")
        _ = try await value.preflightAgentHomeMove(request.input, requestID: request.meta.requestID)
        _ = try await value.preflightAgentHomeMove(request.input, requestID: other)
        let requestIDs = try NativeDomainProtocol.state.requests.map { sent in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body(of: sent))) as? [String: Any])
            return try XCTUnwrap((json["meta"] as? [String: String])?["requestId"])
        }
        XCTAssertEqual(requestIDs, [request.meta.requestID.rawValue, other.rawValue])
    }

    func testAgentHomeConflictBodiesAreDecodedAndTheWireReplyIsRequired() async throws {
        let request = try NativeAPI.decode(AgentHomeMoveRequest.self,
                                           from: agentHomePack("owner.move.request.unsigned-phone.json"))
        let value = client(TestAuthorization(first: "token"))
        NativeDomainProtocol.state.handler = { _ in
            .agentHome(try! self.agentHomePack("owner.move.refusal.feature_losses_changed.json"), status: 409)
        }
        guard case let .refused(refusal) = try await value.moveAgentHome(request.input,
                                                                         requestID: request.meta.requestID) else {
            return XCTFail("the signed 409 refusal must reach the UI")
        }
        XCTAssertEqual(refusal.reason, .featureLossesChanged)

        NativeDomainProtocol.state.reset()
        NativeDomainProtocol.state.handler = { _ in
            .json(try! self.agentHomePack("owner.move.preflight.actual-losses.json"))
        }
        let preflight = try NativeAPI.decode(AgentHomePreflightRequest.self,
                                             from: agentHomePack("owner.move.preflight-request.unsigned-phone.json"))
        do {
            _ = try await value.preflightAgentHomeMove(preflight.input, requestID: preflight.meta.requestID)
            XCTFail("a reply without the negotiated 2.5 wire cannot be trusted")
        } catch let failure as NativeDomainClientFailure {
            XCTAssertEqual(failure, .invalidResponse)
        }
    }
}

// MARK: Company conversations (wire 1.5)

extension NativeDomainClientTests {
    private func conversationPack(_ name: String) throws -> Data {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "company-workspace-v1.5", withExtension: nil))
        return try Data(contentsOf: base.appendingPathComponent("fixtures/" + name))
    }

    private var conversationCompany: NativeID { get throws { try NativeID("00000000-0000-4000-8000-87c6455cae48") } }
    private var conversationRequest: NativeID { get throws { try NativeID("00000000-0000-4000-8000-f9ae298d66d3") } }
    private var conversationID: NativeID { get throws { try NativeID("00000000-0000-4000-8000-f6c6b8bb709f") } }
    private var anh: String { "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE" }
    private var bao: String { "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI" }
    private var chi: String { "AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM" }

    func testCapabilitiesAreReadUnderTheDiscoveryWire() async throws {
        let base = try XCTUnwrap(Bundle.module.url(forResource: "company-workspace-v1.3-capabilities", withExtension: nil))
        NativeDomainProtocol.state.handler = { _ in
            .json(try! Data(contentsOf: base.appendingPathComponent("capabilities-active.response.json")))
        }
        let capabilities = try await client(TestAuthorization(first: "token")).companyCapabilities()
        XCTAssertFalse(capabilities.offersConversations, "the pack's fixture has the activation off")
        let request = try XCTUnwrap(NativeDomainProtocol.state.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/matrix/v1/company-capabilities")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Atum-Company-Wire"), "1.3")
        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.httpBody)
    }

    func testTheConversationListIsReadUnder15AndMustBelongToTheCompanyAsked() async throws {
        NativeDomainProtocol.state.handler = { _ in .json(try! self.conversationPack("conversation-directory.response.json")) }
        let directory = try await client(TestAuthorization(first: "token"))
            .companyConversations(companyID: try conversationCompany)
        XCTAssertEqual(directory.conversations.count, 1)
        let request = try XCTUnwrap(NativeDomainProtocol.state.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path,
                       "/api/matrix/v1/companies/00000000-0000-4000-8000-87c6455cae48/conversations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Atum-Company-Wire"), "1.5")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")

        // The same list for another company is not an answer.
        do {
            _ = try await client(TestAuthorization(first: "token"))
                .companyConversations(companyID: try NativeID("00000000-0000-4000-8000-c70f27930704"))
            XCTFail("a list for another company must be refused")
        } catch let error as CompanyAPIError {
            XCTAssertEqual(error, .invalid)
        }
    }

    func testOpenSendsExactlyTheRequestIdAndRefsUnder15AndReadsTheAnswer() async throws {
        NativeDomainProtocol.state.handler = { _ in .json(try! self.conversationPack("conversation-open.response.json")) }
        let answer = try await client(TestAuthorization(first: "token"))
            .openCompanyConversation(companyID: try conversationCompany, requestID: try conversationRequest,
                                     participantMemberRefs: [anh, bao])
        XCTAssertEqual(answer.conversation.id, try conversationID)
        let request = try XCTUnwrap(NativeDomainProtocol.state.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path,
                       "/api/matrix/v1/companies/00000000-0000-4000-8000-87c6455cae48/conversations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Atum-Company-Wire"), "1.5")
        let body = try XCTUnwrap(body(of: request))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["requestId", "participantMemberRefs"], "no room id, user id, handle or address")
        XCTAssertEqual(object["requestId"] as? String, "00000000-0000-4000-8000-f9ae298d66d3")
        XCTAssertEqual(object["participantMemberRefs"] as? [String], [anh, bao])
    }

    func testOpenRefusesAnAnswerForAnotherSetOrBreakingTheShapeBeforeAnyRequestIsSent() async throws {
        // The answer is for {anh, bao}; the person asked for {anh, chi}.
        NativeDomainProtocol.state.handler = { _ in .json(try! self.conversationPack("conversation-open.response.json")) }
        do {
            _ = try await client(TestAuthorization(first: "token"))
                .openCompanyConversation(companyID: try conversationCompany, requestID: try conversationRequest,
                                         participantMemberRefs: [anh, chi])
            XCTFail("an answer for another set must be refused")
        } catch let error as CompanyAPIError {
            XCTAssertEqual(error, .invalid)
        }
        NativeDomainProtocol.state.reset()
        for refs in [[anh], [anh, anh], [anh, "@bao:example.invalid"], Array(repeating: bao, count: 10)] {
            do {
                _ = try await client(TestAuthorization(first: "token"))
                    .openCompanyConversation(companyID: try conversationCompany, requestID: try conversationRequest,
                                             participantMemberRefs: refs)
                XCTFail("a malformed set must not be sent")
            } catch let error as CompanyAPIError {
                XCTAssertEqual(error, .invalid)
            }
        }
        XCTAssertTrue(NativeDomainProtocol.state.requests.isEmpty)
    }

    func testExpandNamesTheSourceInThePathAndBodyAndNeverReturnsTheSource() async throws {
        let group = try conversationPack("conversation-group.response.json")
        NativeDomainProtocol.state.handler = { _ in .json(group) }
        let answer = try await client(TestAuthorization(first: "token"))
            .expandCompanyConversation(companyID: try conversationCompany, sourceConversationID: try conversationID,
                                       requestID: try conversationRequest, participantMemberRefs: [anh, bao, chi])
        XCTAssertEqual(answer.conversation.participants.count, 3)
        let request = try XCTUnwrap(NativeDomainProtocol.state.requests.first)
        XCTAssertEqual(request.url?.path, "/api/matrix/v1/companies/00000000-0000-4000-8000-87c6455cae48"
                       + "/conversations/00000000-0000-4000-8000-f6c6b8bb709f/expand")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Atum-Company-Wire"), "1.5")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body(of: request))) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["requestId", "sourceConversationId", "participantMemberRefs"])
        XCTAssertEqual(object["sourceConversationId"] as? String, "00000000-0000-4000-8000-f6c6b8bb709f")

        // An expansion needs three; the answer being the source itself is refused.
        NativeDomainProtocol.state.reset()
        do {
            _ = try await client(TestAuthorization(first: "token"))
                .expandCompanyConversation(companyID: try conversationCompany, sourceConversationID: try conversationID,
                                           requestID: try conversationRequest, participantMemberRefs: [anh, bao])
            XCTFail("an expansion to two people is not an expansion")
        } catch let error as CompanyAPIError {
            XCTAssertEqual(error, .invalid)
        }
        XCTAssertTrue(NativeDomainProtocol.state.requests.isEmpty)
        let same = try conversationPack("conversation-group.response.json")
        NativeDomainProtocol.state.handler = { _ in .json(same) }
        do {
            _ = try await client(TestAuthorization(first: "token"))
                .expandCompanyConversation(companyID: try conversationCompany,
                                           sourceConversationID: try NativeID("00000000-0000-4000-8000-8a4e23bab81e"),
                                           requestID: try conversationRequest, participantMemberRefs: [anh, bao, chi])
            XCTFail("an expand answer that is its own source must be refused")
        } catch let error as CompanyAPIError {
            XCTAssertEqual(error, .invalid)
        }
    }

    func testHideSendsOnlyTheRequestAndStateAndChecksTheAnswer() async throws {
        NativeDomainProtocol.state.handler = { _ in .json(try! self.conversationPack("conversation-hidden.response.json")) }
        let answer = try await client(TestAuthorization(first: "token"))
            .setCompanyConversationHidden(companyID: try conversationCompany, conversationID: try conversationID,
                                          requestID: try conversationRequest, hidden: true)
        XCTAssertTrue(answer.hidden)
        let request = try XCTUnwrap(NativeDomainProtocol.state.requests.first)
        XCTAssertEqual(request.url?.path, "/api/matrix/v1/companies/00000000-0000-4000-8000-87c6455cae48"
                       + "/conversations/00000000-0000-4000-8000-f6c6b8bb709f/hidden")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Atum-Company-Wire"), "1.5")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body(of: request))) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["requestId", "hidden"])
        XCTAssertEqual(object["hidden"] as? Bool, true)

        // The fixture answers hidden=true; unhiding is not satisfied by it.
        do {
            _ = try await client(TestAuthorization(first: "token"))
                .setCompanyConversationHidden(companyID: try conversationCompany, conversationID: try conversationID,
                                              requestID: try conversationRequest, hidden: false)
            XCTFail("an answer for the wrong state must be refused")
        } catch let error as CompanyAPIError {
            XCTAssertEqual(error, .invalid)
        }
    }

    func testATypedRefusalReachesTheCallerAndAPrivateDetailDoesNot() async throws {
        NativeDomainProtocol.state.handler = { _ in
            .init(status: 404, chunks: [try! self.conversationPack("conversation-error-unavailable.response.json")])
        }
        do {
            _ = try await client(TestAuthorization(first: "token"))
                .companyConversations(companyID: try conversationCompany)
            XCTFail("a 404 must throw")
        } catch let error as CompanyAPIError {
            XCTAssertEqual(ConversationRefusal(error), .conversationUnavailable)
        }
        // A second detail key (a participant count) is not the closed refusal: nothing is surfaced.
        NativeDomainProtocol.state.handler = { _ in
            .init(status: 404, chunks: [try! self.conversationPack("conversation-error-leak.response.json")])
        }
        do {
            _ = try await client(TestAuthorization(first: "token"))
                .companyConversations(companyID: try conversationCompany)
            XCTFail("a 404 must throw")
        } catch let error as CompanyAPIError {
            XCTAssertEqual(error, .invalid)
            XCTAssertEqual(ConversationRefusal(error), .lost)
        }
    }
}

// MARK: Apple purchases (frozen d1)

extension NativeDomainClientTests {
    func testApplePurchaseRoutesUseSameMASBearerAndExactRequestShape() async throws {
        let products = try ApplePurchaseTestData.data(.productsOpen)
        let token = try ApplePurchaseTestData.data(.accountToken)
        let transaction = try ApplePurchaseTestData.data(.transactionCredited)
        NativeDomainProtocol.state.handler = { request in
            switch request.url!.path {
            case "/api/matrix/v1/store/apple/products": return .json(products)
            case "/api/matrix/v1/store/apple/account-token": return .json(token)
            case "/api/matrix/v1/store/apple/transactions": return .init(status: 201, chunks: [transaction])
            default: return .init(status: 404)
            }
        }
        let client = client(TestAuthorization(first: "synthetic-mas-bearer"))
        _ = try await client.appleProducts()
        _ = try await client.appleAccountToken()
        _ = try await client.appleTransaction(.init(signedTransaction: "synthetic.payload.signature"))
        let requests = NativeDomainProtocol.state.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET", "POST"])
        for request in requests {
            XCTAssertEqual(request.url?.host, "api.atumplatform.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-mas-bearer")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        }
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(body(of: requests[2]))) as! [String: String]
        XCTAssertEqual(object, ["signedTransaction": "synthetic.payload.signature"])
    }

    func testApple401RefreshAndClosed422CodesAndStatusMismatch() async throws {
        let transaction = try ApplePurchaseTestData.data(.transactionReplayed)
        NativeDomainProtocol.state.handler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
                return .init(status: 401, chunks: [Data(#"{"error":"matrix_401"}"#.utf8)])
            }
            return .json(transaction)
        }
        let authorization = TestAuthorization(first: "old", refreshed: "new")
        _ = try await client(authorization).appleTransaction(.init(signedTransaction: "a.b.c"))
        XCTAssertEqual(NativeDomainProtocol.state.requests.count, 2)
        let invalidSignature = try ApplePurchaseTestData.data(.errorInvalidSignature)
        for status in [422, 503] {
            NativeDomainProtocol.state.handler = { _ in .init(status: status, chunks: [invalidSignature]) }
            do {
                _ = try await client(TestAuthorization(first: "valid")).appleTransaction(.init(signedTransaction: "a.b.c"))
                XCTFail("An error must not become a transaction acknowledgement")
            } catch let error as ApplePurchaseError {
                XCTAssertEqual(status, 422); XCTAssertEqual(error.reason, .invalidSignature)
            } catch let error as NativeDomainClientFailure {
                XCTAssertEqual(status, 503); XCTAssertEqual(error, .invalidResponse)
            }
        }
    }
}

// MARK: Live cloud turn Stop

extension NativeDomainClientTests {
    private var stopRequestID: String { "8e0a2c4e-6b8d-4f0b-8d2f-4a6c8e0b2d79" }
    private var stopRoomID: String { "!stop-room:atum.test" }
    private var stopEventID: String { "$stop-question" }

    private func stopRequest() throws -> CloudTurnStop.Request {
        try CloudTurnStop.Request(requestId: NativeID(stopRequestID), agentPrincipal: NativeID(agentPrincipal),
                                  roomId: MatrixRoomID(stopRoomID), eventId: MatrixEventID(stopEventID))
    }

    private func stopReply(_ state: String, eventID: String? = nil) -> Data {
        Data("""
        {"agentPrincipal":"\(agentPrincipal)","target":{"kind":"turn","roomId":"\(stopRoomID)",\
        "eventId":"\(eventID ?? stopEventID)"},"state":"\(state)","stoppedAt":1790672700000}
        """.utf8)
    }

    private func stopAgent(answering: Any? = "cloud", status: String = "active",
                           matrixUser: Bool = true) throws -> AgentsResponse.Agent {
        var record = agentRecord(matrixUser: matrixUser)
        if !matrixUser { record["matrixUser"] = NSNull() }
        record["answering"] = answering
        record["status"] = status
        return try NativeAPI.decode(AgentsResponse.Agent.self,
                                    from: JSONSerialization.data(withJSONObject: record))
    }

    func testCloudStopExactPOSTUsesBearerAndNoCookies() async throws {
        let expected = try stopRequest().body()
        NativeDomainProtocol.state.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.atumplatform.com/api/matrix/v1/cloud/stop")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(self.body(of: request), expected)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer stop-domain-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
            return .json(self.stopReply("stopped"))
        }
        let result = try await client(TestAuthorization(first: "stop-domain-token")).cloudStop(stopRequest())
        XCTAssertEqual(result.state, .stopped)
        XCTAssertEqual(NativeDomainProtocol.state.requests.count, 1)
    }

    func testCloudStopKeepsRequestIDAndBodyAcrossSingle401Refresh() async throws {
        let authorization = TestAuthorization(first: "stop-old-token", refreshed: "stop-new-token")
        NativeDomainProtocol.state.handler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer stop-old-token" {
                return .init(status: 401, chunks: [Data(#"{"error":"matrix_401"}"#.utf8)])
            }
            return .json(self.stopReply("stop_requested"))
        }
        let result = try await client(authorization).cloudStop(stopRequest())
        XCTAssertEqual(result.state, .stopRequested)
        XCTAssertEqual(authorization.refreshCalls, 1)
        let sent = NativeDomainProtocol.state.requests
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(body(of: sent[0]), try stopRequest().body())
        XCTAssertEqual(body(of: sent[0]), body(of: sent[1]))
        XCTAssertEqual(sent[1].value(forHTTPHeaderField: "Authorization"), "Bearer stop-new-token")
    }

    func testCloudStopEnforces4096RequestAnd262144ResponseBudgets() async throws {
        let value = client(TestAuthorization(first: "stop-budget-token"))
        // Both IDs fit their contract, but JSON escaping takes the body over
        // the native write budget. No bearer request may leave the client.
        let escaped = String(repeating: "\"", count: 1_023)
        let tooLarge = try CloudTurnStop.Request(
            requestId: NativeID(stopRequestID), agentPrincipal: NativeID(agentPrincipal),
            roomId: MatrixRoomID("!" + escaped), eventId: MatrixEventID("$" + escaped)
        )
        XCTAssertGreaterThan(try tooLarge.body().count, 4_096)
        do { _ = try await value.cloudStop(tooLarge); XCTFail("Oversized stop sent") }
        catch let failure as NativeDomainClientFailure { XCTAssertEqual(failure, .invalidRequest) }
        XCTAssertTrue(NativeDomainProtocol.state.requests.isEmpty)

        let maximumIDs = try CloudTurnStop.Request(
            requestId: NativeID(stopRequestID), agentPrincipal: NativeID(agentPrincipal),
            roomId: MatrixRoomID("!" + String(repeating: "r", count: 1_023)),
            eventId: MatrixEventID("$" + String(repeating: "e", count: 1_023))
        )
        NativeDomainProtocol.state.handler = { _ in .json(Data("{}".utf8)) }
        do { _ = try await value.cloudStop(maximumIDs); XCTFail("Uncorrelated reply accepted") }
        catch let failure as NativeDomainClientFailure { XCTAssertEqual(failure, .invalidResponse) }
        XCTAssertEqual(NativeDomainProtocol.state.requests.count, 1, "Maximum ordinary IDs fit the request budget")

        let valid = stopReply("completed")
        let atBudget = valid + Data(repeating: 32, count: 262_144 - valid.count)
        NativeDomainProtocol.state.handler = { _ in .json(atBudget) }
        let accepted = try await value.cloudStop(stopRequest())
        XCTAssertEqual(accepted.state, .completed)
        for reply in [
            NativeDomainProtocol.Reply(headers: ["Content-Type": "application/json", "Content-Length": "262145"]),
            .init(chunks: [atBudget, Data([32])]),
        ] {
            NativeDomainProtocol.state.handler = { _ in reply }
            do { _ = try await value.cloudStop(stopRequest()); XCTFail("Oversized response accepted") }
            catch let failure as NativeDomainClientFailure { XCTAssertEqual(failure, .responseTooLarge) }
        }
    }

    func testCloudStopUsesClosedErrorsAndStrictCorrelatedReplies() async throws {
        let authorization = TestAuthorization(first: "stop-refusal-token")
        let value = client(authorization)
        for (status, code) in [(403, "matrix_403"), (404, "matrix_404"), (503, "matrix_503")] {
            NativeDomainProtocol.state.handler = { _ in
                .init(status: status, chunks: [Data("{\"error\":\"\(code)\"}".utf8)])
            }
            do { _ = try await value.cloudStop(stopRequest()); XCTFail("Refusal accepted") }
            catch let failure as NativeDomainClientFailure {
                guard case let .http(http) = failure else { return XCTFail("Expected closed HTTP failure") }
                XCTAssertEqual(http.response.error.rawValue, code)
            }
        }
        XCTAssertEqual(authorization.refreshCalls, 0, "Only unauthenticated may trigger a refresh")
        for reply in [
            NativeDomainProtocol.Reply(status: 403, chunks: [Data(#"{"error":"not_admitted"}"#.utf8)]),
            .json(stopReply("stopped", eventID: "$another-turn")),
            .json(stopReply("stopping")),
            .json(Data("{}".utf8)),
            .init(headers: ["Content-Type": "text/html"], chunks: [Data("<html>".utf8)]),
        ] {
            NativeDomainProtocol.state.handler = { _ in reply }
            do { _ = try await value.cloudStop(stopRequest()); XCTFail("Unconfirmed response accepted") }
            catch let failure as NativeDomainClientFailure { XCTAssertEqual(failure, .invalidResponse) }
        }
        NativeDomainProtocol.state.handler = { _ in
            .init(redirect: URL(string: "https://foreign.invalid/stop")!)
        }
        do { _ = try await value.cloudStop(stopRequest()); XCTFail("Redirect followed") }
        catch let failure as NativeDomainClientFailure { XCTAssertEqual(failure, .redirectRefused) }
        XCTAssertTrue(NativeDomainProtocol.state.requests.allSatisfy { $0.url?.host == "api.atumplatform.com" })
    }

    func testLiveStopRouteOnlyExistsForAnActiveCloudRoomWithDomainAccess() throws {
        let cloud = try stopAgent()
        let route = CloudAssistantTurnStop(agent: cloud, roomID: stopRoomID, routeAvailable: true)
        XCTAssertEqual(route?.agentPrincipal, cloud.principal)
        XCTAssertEqual(route?.roomID.rawValue, stopRoomID)
        let answeringModes: [Any?] = ["local", "future_destination", nil, NSNull(), 42]
        for answering in answeringModes {
            XCTAssertNil(CloudAssistantTurnStop(agent: try stopAgent(answering: answering),
                                                roomID: stopRoomID, routeAvailable: true))
        }
        XCTAssertNil(CloudAssistantTurnStop(agent: nil, roomID: stopRoomID, routeAvailable: true))
        XCTAssertNil(CloudAssistantTurnStop(agent: cloud, roomID: stopRoomID, routeAvailable: false))
        XCTAssertNil(CloudAssistantTurnStop(agent: cloud, roomID: "invalid", routeAvailable: true))
        XCTAssertNil(CloudAssistantTurnStop(agent: try stopAgent(status: "retired"),
                                            roomID: stopRoomID, routeAvailable: true))
        XCTAssertNil(CloudAssistantTurnStop(agent: try stopAgent(matrixUser: false),
                                            roomID: stopRoomID, routeAvailable: true))
    }

    func testLiveStopBridgeDrivesStoppedRequestedAndCompletedPhases() async throws {
        let route = try XCTUnwrap(CloudAssistantTurnStop(agent: stopAgent(), roomID: stopRoomID,
                                                        routeAvailable: true))
        let value = client(TestAuthorization(first: "stop-live-token"))
        for (reply, phase) in [("stopped", AssistantTurnStop.Phase.stopped),
                               ("stop_requested", .stopping), ("completed", .finishing)] {
            NativeDomainProtocol.state.handler = { _ in .json(self.stopReply(reply)) }
            var state = AssistantTurnStop()
            state.observe(.init(unanswered: stopEventID, working: true))
            let intent = try XCTUnwrap(state.beginStop(newRequestID: stopRequestID))
            XCTAssertEqual(state.phase, .stopping)
            state.resolve(await route.stop(intent, using: value), for: intent)
            XCTAssertEqual(state.phase, phase)
            if reply == "stop_requested" {
                XCTAssertNil(state.beginStop(newRequestID: UUID().uuidString.lowercased()))
                state.observe(.idle)
                XCTAssertEqual(state.phase, .idle, "The room, not stop_requested, confirms the end")
            }
        }
    }

    func testLiveStopBridgeFailuresRemainHonestAndRetryTheSameRequest() async throws {
        let route = try XCTUnwrap(CloudAssistantTurnStop(agent: stopAgent(), roomID: stopRoomID,
                                                        routeAvailable: true))
        let value = client(TestAuthorization(first: "stop-live-token"))
        // Native forbidden/not-admitted, gate off, missing route, transport
        // loss and an unrelated 200 all leave the running turn unconfirmed.
        for reply in [
            NativeDomainProtocol.Reply(status: 403, chunks: [Data(#"{"error":"matrix_403","details":{"reason":"not_admitted"}}"#.utf8)]),
            .init(status: 503, chunks: [Data(#"{"error":"matrix_503","details":{"reason":"cloud_disabled"}}"#.utf8)]),
            .init(status: 404, chunks: [Data(#"{"error":"matrix_404"}"#.utf8)]),
            .init(error: URLError(.notConnectedToInternet)),
            .json(stopReply("stopped", eventID: "$another-turn")),
        ] {
            NativeDomainProtocol.state.reset()
            NativeDomainProtocol.state.handler = { _ in reply }
            var state = AssistantTurnStop()
            state.observe(.init(unanswered: stopEventID, working: true))
            let first = try XCTUnwrap(state.beginStop(newRequestID: stopRequestID))
            var unavailable = false
            state.resolve(await route.stop(first, using: value, onRouteUnavailable: { unavailable = true }),
                          for: first)
            XCTAssertEqual(state.phase, .failed)
            XCTAssertTrue(state.offersStop)
            XCTAssertTrue(state.isWorking)
            XCTAssertEqual(unavailable, [403, 404, 503].contains(reply.status))
            // The live host withdraws a known unavailable action until facts
            // refresh; after refresh (or transient failure) the same turn may
            // retry, always with its retained request ID.
            if unavailable {
                XCTAssertNil(CloudAssistantTurnStop(agent: try stopAgent(), roomID: stopRoomID,
                                                    routeAvailable: false))
            }
            let retry = try XCTUnwrap(state.beginStop(newRequestID: UUID().uuidString.lowercased()))
            XCTAssertEqual(retry, first)
            NativeDomainProtocol.state.handler = { _ in .json(self.stopReply("stopped")) }
            state.resolve(await route.stop(retry, using: value), for: retry)
            XCTAssertEqual(state.phase, .stopped)
            let requests = NativeDomainProtocol.state.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(body(of: requests[0]), body(of: requests[1]))
        }
    }
}
