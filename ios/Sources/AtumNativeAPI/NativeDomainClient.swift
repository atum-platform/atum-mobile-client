import Foundation

/// Failure metadata intentionally excludes request credentials and response
/// bodies. Callers may inspect the typed HTTP envelope without receiving server
/// text that could be accidentally rendered or logged.
public enum NativeDomainClientFailure: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case invalidRequest, invalidResponse, responseTooLarge, redirectRefused
    case transportUnavailable, cancelled, authenticationRefused
    case http(NativeHTTPFailure)
    case assistantName(AssistantNameRefusal)

    public var description: String {
        switch self {
        case .invalidRequest: return "NativeDomainClientFailure.invalidRequest"
        case .invalidResponse: return "NativeDomainClientFailure.invalidResponse"
        case .responseTooLarge: return "NativeDomainClientFailure.responseTooLarge"
        case .redirectRefused: return "NativeDomainClientFailure.redirectRefused"
        case .transportUnavailable: return "NativeDomainClientFailure.transportUnavailable"
        case .cancelled: return "NativeDomainClientFailure.cancelled"
        case .authenticationRefused: return "NativeDomainClientFailure.authenticationRefused"
        case let .http(failure): return "NativeDomainClientFailure.http(" + failure.response.error.rawValue + ")"
        case let .assistantName(refusal): return "NativeDomainClientFailure.assistantName(" + refusal.rawValue + ")"
        }
    }
    public var debugDescription: String { description }
}

/// One roster read plus the optional A38 acknowledgement. The ack echoes the
/// zone this caller sent or is absent; it is never another owner's value.
public struct AgentsRead: Sendable {
    public let response: AgentsResponse
    public let timeZoneAck: String?
}

/// Main-process-only client for explicit operations on the fixed native domain API. The
/// refresh coordinator remains the only authority that can expose a bearer;
/// SwiftUI receives typed domain values and safe failures only.
@MainActor public final class NativeDomainClient: CompanyWorkspaceAPI, CompanyConversationsAPI, CompanyPrivateCosAPI, ApplePurchasesAPI {
    private static let baseURL = URL(string: "https://api.atumplatform.com/api/matrix/v1")!
    private static let agentsURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/agents")!
    private static let agentLifecycleURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/agents/lifecycle")!
    private static let appsURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/apps")!
    private static let officialAccountsURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/official-accounts")!
    private static let storeCatalogURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/store/catalog")!
    private static let walletURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/wallet")!
    private static let walletHistoryURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/wallet/history")!
    private static let aliasLookupURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/aliases/lookup")!
    private static let assistantURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/assistant")!
    private static let cloudDisclosureURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/cloud/disclosure")!
    private static let companiesURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/companies")!
    private static let companyCapabilitiesURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/company-capabilities")!
    private static let privateCosCapabilityURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/cloud/controller/company-private-cos")!
    private static let driveAccountURL = DriveContract.accountURL

    typealias Authorization = @MainActor @Sendable (_ forceRefresh: Bool) async throws -> String
    public typealias AuthenticationFailureObserver = @MainActor @Sendable (any Error) -> Void
    private let authorization: Authorization
    private let authenticationFailureObserver: AuthenticationFailureObserver
    private let protocolClasses: [URLProtocol.Type]?

    /// The caller supplies the opaque, Keychain-backed domain grant and its
    /// already-hardened exchange. No token is returned from this API.
    public init(refresh: OIDCGrantRefresh,
                preflight: @escaping OIDCGrantRefresh.Preflight = {},
                exchange: @escaping OIDCGrantRefresh.Exchange,
                onAuthenticationFailure: @escaping AuthenticationFailureObserver = { _ in }) {
        authorization = { forceRefresh in
            if forceRefresh {
                return try await refresh.refresh(now: Date(), preflight: preflight, exchange: exchange)
            }
            return try await refresh.accessToken(now: Date(), preflight: preflight, exchange: exchange)
        }
        authenticationFailureObserver = onAuthenticationFailure
        protocolClasses = nil
    }

    /// Test-only transport and credential seam. It has no caller-supplied
    /// origin and is internal to this module's testable build.
    init(testAuthorization: @escaping Authorization, protocolClasses: [URLProtocol.Type],
         onAuthenticationFailure: @escaping AuthenticationFailureObserver = { _ in }) {
        authorization = testAuthorization
        authenticationFailureObserver = onAuthenticationFailure
        self.protocolClasses = protocolClasses
    }

    private static let applePaths = ["products", "account-token", "transactions"].map {
        "/api/matrix/v1/store/apple/" + $0
    }

    public func appleProducts() async throws -> AppleProductsResponse {
        try await appleRequest(AppleProductsResponse.self, operation: "products", body: nil)
    }

    public func appleAccountToken() async throws -> AppleAccountTokenResponse {
        try await appleRequest(AppleAccountTokenResponse.self, operation: "account-token", body: nil)
    }

    public func appleTransaction(_ input: AppleTransactionRequest) async throws -> AppleTransactionResponse {
        try await appleRequest(AppleTransactionResponse.self, operation: "transactions",
                               body: JSONEncoder().encode(input))
    }

    private func appleRequest<T: Decodable>(_ type: T.Type, operation: String, body: Data?) async throws -> T {
        let url = Self.baseURL.appendingPathComponent("store/apple/" + operation)
        guard Self.applePaths.contains(url.path), (operation == "transactions") == (body != nil)
        else { throw NativeDomainClientFailure.invalidRequest }
        for forceRefresh in [false, true] {
            let token = try await authorize(forceRefresh: forceRefresh)
            try requireActiveTask()
            let result = try await perform(url: url, token: token, method: body == nil ? "GET" : "POST",
                                           body: body, maximumRequestBodyBytes: 16_512,
                                           maximumResponseBodyBytes: 65_536)
            try requireActiveTask()
            if (200..<300).contains(result.status) { return try decode(type, data: result.body) }
            let failure = try decode(ApplePurchaseError.self, data: result.body)
            guard result.status == failure.error.status else { throw NativeDomainClientFailure.invalidResponse }
            if failure.error == .unauthenticated && !forceRefresh { continue }
            if failure.error == .unauthenticated {
                authenticationFailureObserver(NativeDomainClientFailure.authenticationRefused)
            }
            throw failure
        }
        throw NativeDomainClientFailure.authenticationRefused
    }

    public func agents() async throws -> AgentsResponse {
        try await agents(timeZone: nil).response
    }

    /// The roster read may report the device time
    /// zone (A38). The report is best effort: an invalid value is omitted
    /// rather than failing the read, and the acknowledgement is exposed only
    /// to the caller that sent a value.
    public func agents(timeZone: String?) async throws -> AgentsRead {
        var headers: [String: String] = [:]
        if let timeZone, OwnerTimeZoneContract.isValid(timeZone) {
            headers[OwnerTimeZoneContract.requestHeader] = timeZone
        }
        let result = try await requestWithHeaders(AgentsResponse.self, url: Self.agentsURL,
                                                  method: "GET", body: nil,
                                                  acceptsAssistantNameRefusal: false,
                                                  extraHeaders: headers)
        return AgentsRead(response: result.value,
                          timeZoneAck: Self.header(OwnerTimeZoneContract.acknowledgementHeader,
                                                   in: result.headers))
    }

    /// `atum.agent-lifecycle/1`: whether this account may create a cloud
    /// assistant from the phone and which consent version to report. The phone
    /// never invents a capability or a disclosure version.
    public func agentLifecycleCapability() async throws -> AgentLifecycleCapability {
        try await read(AgentLifecycleCapability.self, url: Self.agentLifecycleURL)
    }

    /// One durable operation identified by the caller's account-scoped UUID.
    /// Begin creates the identity/runtime/room; resume observes the same
    /// operation after a retry, termination or foreground return. Both are the
    /// one closed route and both echo the same request ID.
    public func beginAgentLifecycle(_ input: AgentLifecycleBegin) async throws -> AgentLifecycleSnapshot {
        let snapshot = try await agentLifecycleOperation(input)
        guard snapshot.requestID == input.requestId else { throw NativeDomainClientFailure.invalidResponse }
        return snapshot
    }

    public func resumeAgentLifecycle(_ input: AgentLifecycleResume) async throws -> AgentLifecycleSnapshot {
        let snapshot = try await agentLifecycleOperation(input)
        guard snapshot.requestID == input.requestId else { throw NativeDomainClientFailure.invalidResponse }
        return snapshot
    }

    /// The active Cloud disclosure version, for the sign-in sentence the person
    /// was shown. A read that fails or answers outside the contract is `nil`:
    /// placement then keeps today's Mac-first behaviour, and sign-in never
    /// blocks on consent discovery.
    public func cloudDisclosureVersion() async -> Int64? {
        do { return try await read(CloudDisclosureResponse.self, url: Self.cloudDisclosureURL).version }
        catch { return nil }
    }

    /// Stops one cloud turn through the same MAS-authorized, bounded transport
    /// as the other native calls. Only a strictly correlated 200 is confirmed.
    public func cloudStop(_ input: CloudTurnStop.Request) async throws -> CloudTurnStop.Response {
        let body: Data
        do { body = try input.body() }
        catch { throw NativeDomainClientFailure.invalidRequest }
        let response = try await response(
            url: Self.baseURL.appendingPathComponent("cloud/stop"), method: "POST", body: body,
            maximumRequestBodyBytes: 4_096, maximumResponseBodyBytes: 262_144
        )
        do { return try CloudTurnStop.response(response.body, for: input) }
        catch { throw NativeDomainClientFailure.invalidResponse }
    }

    /// First sign-in: the platform creates this account's default assistant and
    /// starter Protons if they are missing. Every step is idempotent, so a
    /// failure is simply retried by the next sign-in. `{disclosureVersion}`
    /// additionally asks the platform to place that assistant in the cloud
    /// (`atum.cloud-first-use/1.1` A1, vendored at `c18386519c28`) — the
    /// consent the person was shown at sign-in; `nil` sends `{}`, which keeps
    /// the Mac-first behaviour exactly.
    ///
    /// The production Shell that predates the versioned body refuses it with a
    /// 4xx. That refusal is not an error: the same request is retried exactly
    /// once with `{}`, so an old and a new Shell both work.
    public func ensureAssistant(disclosureVersion: Int64?, timeZone: String? = nil) async throws {
        let version = disclosureVersion.flatMap { (1...Int64(Int32.max)).contains($0) ? $0 : nil }
        let versionedBody = version.flatMap { Data("{\"disclosureVersion\":\($0)}".utf8) }
        var headers: [String: String] = [:]
        if let timeZone, OwnerTimeZoneContract.isValid(timeZone) {
            headers[OwnerTimeZoneContract.requestHeader] = timeZone
        }
        var response = try await performAuthorized(url: Self.assistantURL,
                                                   body: versionedBody ?? Data("{}".utf8),
                                                   extraHeaders: headers)
        if versionedBody != nil, response.status == 400 || response.status == 422 {
            response = try await performAuthorized(url: Self.assistantURL, body: Data("{}".utf8),
                                                   extraHeaders: headers)
        }
        guard response.status == 200 else { throw NativeDomainClientFailure.http(try httpFailure(response)) }
        _ = try decode(AssistantProvisionResponse.self, data: response.body)
    }

    /// Reads the eligible, server-authored app projection. It does not issue a
    /// launch, connect a provider, or make a Matrix room available.
    public func apps() async throws -> AppCatalogResponse {
        try await read(AppCatalogResponse.self, url: Self.appsURL)
    }

    /// The platform's official accounts: who the Founder is and which accounts
    /// carry a mark. Preparation no longer reads a principal, email or identity
    /// lookup; only the closed answer above becomes state.
    public func officialAccounts() async throws -> OfficialAccountsResponse {
        try await read(OfficialAccountsResponse.self, url: Self.officialAccountsURL,
                       maximumResponseBodyBytes: 32_768)
    }

    public func appWorkspace(slug: String) async throws -> AppWorkspaceSnapshot {
        let snapshot = try await read(AppWorkspaceSnapshot.self, url: try appURL(slug))
        guard snapshot.slug == slug else { throw NativeDomainClientFailure.invalidResponse }
        return snapshot
    }

    public func appBotStatus(slug: String) async throws -> AppBotSetupStatus {
        try await read(AppBotSetupStatus.self, url: try appURL(slug, suffix: "bot"))
    }

    /// Records only the displayed version and locale. Provenance is derived
    /// from the admitted iOS MAS client and is intentionally not representable
    /// in this request type.
    public func acceptAppBotConsent(slug: String,
                                    value: AppBotConsentRequest) async throws -> AppBotSetupStatus {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        let status = try await request(AppBotSetupStatus.self,
                                       url: try appURL(slug, suffix: "bot/consent"),
                                       method: "POST", body: body,
                                       acceptsAssistantNameRefusal: false)
        guard status.consent.state == .accepted,
              status.consent.disclosureVersion == value.disclosureVersion,
              status.consent.locale == value.locale else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return status
    }

    /// The platform's canonical-room arbitration for an app bot's chat. A 404
    /// (or an explicit `not_found`) is the older Shell without the route and
    /// answers `.routeAbsent`; any other refusal is an error, never a fallback.
    public func startAppBot(slug: String, value: AppBotStartRequest) async throws -> AppBotStartResult {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        let response = try await performAuthorized(url: try appURL(slug, suffix: "bot/start"), body: body)
        switch response.status {
        case 200:
            let answer = try decode(AppBotStartAnswer.self, data: response.body)
            return answer == .notFound ? .routeAbsent : .answer(answer)
        case 404:
            return .routeAbsent
        default:
            throw NativeDomainClientFailure.http(try httpFailure(response))
        }
    }

    public func appConnection(slug: String) async throws -> AppConnectionSnapshot {
        let snapshot = try await read(AppConnectionSnapshot.self,
                                      url: try appURL(slug, suffix: "connection"))
        guard snapshot.app == slug else { throw NativeDomainClientFailure.invalidResponse }
        return snapshot
    }

    public func beginAppConnection(slug: String,
                                   value: AppLinkConnectRequest) async throws -> AppLinkConnectResponse {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        return try await request(AppLinkConnectResponse.self,
                                 url: try appURL(slug, suffix: "connect"),
                                 method: "POST", body: body,
                                 acceptsAssistantNameRefusal: false)
    }

    public func confirmAppConnection(slug: String,
                                     value: AppLinkConfirmRequest) async throws -> AppLinkConfirmResponse {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        return try await request(AppLinkConfirmResponse.self,
                                 url: try appURL(slug, suffix: "connect/confirm"),
                                 method: "POST", body: body,
                                 acceptsAssistantNameRefusal: false)
    }

    public func appIntake(slug: String) async throws -> AppIntakeStatus {
        try await read(AppIntakeStatus.self, url: try appURL(slug, suffix: "bot/intake"))
    }

    public func submitAppIntake(slug: String,
                                value: AppIntakeSubmission) async throws -> AppIntakeStatus {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        let response = try await response(url: try appURL(slug, suffix: "bot/intake"),
                                          method: "POST", body: body,
                                          maximumRequestBodyBytes: 16_384,
                                          maximumResponseBodyBytes: 262_144)
        if response.status == 200 { return try decode(AppIntakeStatus.self, data: response.body) }
        if response.status == 400 {
            let failure: AppIntakeErrorResponse
            do { failure = try NativeAPI.decode(AppIntakeErrorResponse.self, from: response.body) }
            catch { throw NativeDomainClientFailure.invalidResponse }
            throw AppIntakeSubmissionFailure.invalid(field: failure.field)
        }
        throw NativeDomainClientFailure.http(try httpFailure(response))
    }

    public func launchApp(slug: String, value: AppLaunchRequest) async throws -> AppLaunchResponse {
        guard AppOnboardingPolicy.allowsLaunch(slug: slug, routeID: value.routeID) else {
            throw NativeDomainClientFailure.invalidRequest
        }
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        return try await request(AppLaunchResponse.self,
                                 url: try appURL(slug, suffix: "launch"),
                                 method: "POST", body: body,
                                 acceptsAssistantNameRefusal: false)
    }

    /// Only the five native-admitted Store operations; topups/tasks and the
    /// desktop-only per-purchase status route are intentionally absent.
    public func storeEntitlements() async throws -> StoreEntitlementsResponse {
        try await storeRead(StoreEntitlementsResponse.self, path: "entitlements")
    }

    public func storePurchases() async throws -> StorePurchasesResponse {
        try await storeRead(StorePurchasesResponse.self, path: "purchases")
    }

    public func acquireStoreItem(_ attempt: StorePurchaseAttempt) async throws -> StorePurchaseResult {
        let data = try await storeData(url: Self.baseURL.appendingPathComponent("store/purchases"),
            method: "POST", body: attempt.body, extraHeaders: [
                StoreWire.capabilitiesHeader: StoreWire.capabilities,
                "Idempotency-Key": attempt.idempotencyKey.rawValue
            ])
        let result = try StoreWire.decode(StorePurchaseResult.self, from: data)
        try attempt.validate(result)
        return result
    }

    public func cancelStoreSubscription(_ id: NativeID) async throws -> StoreEntitlement {
        let data = try await storeData(url: Self.baseURL.appendingPathComponent("store/entitlements/" + id.rawValue + "/cancel"),
            method: "POST", body: Data("{}".utf8), extraHeaders: [StoreWire.capabilitiesHeader: StoreWire.capabilities])
        let result = try StoreWire.decode(StoreEntitlement.self, from: data)
        guard result.id == id, result.subscription?.state == .cancelled else { throw NativeDomainClientFailure.invalidResponse }
        return result
    }

    private func storeRead<T: Decodable>(_ type: T.Type, path: String) async throws -> T {
        let data = try await storeData(url: Self.baseURL.appendingPathComponent("store/" + path),
            method: "GET", body: nil, extraHeaders: [StoreWire.capabilitiesHeader: StoreWire.capabilities])
        return try StoreWire.decode(type, from: data)
    }

    private func storeData(url: URL, method: String, body: Data?, extraHeaders: [String: String]) async throws -> Data {
        try await response(url: url, method: method, body: body,
            maximumRequestBodyBytes: 4096, maximumResponseBodyBytes: 1_048_576,
            extraHeaders: extraHeaders).body
    }

    public func storeCatalog() async throws -> StoreCatalogResponse {
        try await storeRead(StoreCatalogResponse.self, path: "catalog")
    }

    public func wallet() async throws -> WalletResponse {
        try await read(WalletResponse.self, url: Self.walletURL)
    }

    /// Starts or observes this signed-in account's personal Drive mapping.
    /// The domain bearer is used only at Shell; the returned server URL never
    /// carries file authority.
    public func driveAccount() async throws -> DriveAccount {
        let response = try await performAuthorized(url: Self.driveAccountURL,
                                                   body: Data("{}".utf8))
        guard response.status == 200 else {
            throw NativeDomainClientFailure.http(try httpFailure(response))
        }
        return try DriveAccount.decode(response.body)
    }

    /// Resolves one exact public handle through the owner-bound directory.
    /// The typed handle keeps arbitrary query strings out of the bearer
    /// transport; the response is still only a lookup, never room authority.
    public func aliasLookup(handle: NativeHandle) async throws -> AliasLookupResponse {
        var components = URLComponents(url: Self.aliasLookupURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "handle", value: handle.rawValue)]
        guard let url = components.url else { throw NativeDomainClientFailure.invalidRequest }
        let response = try await read(AliasLookupResponse.self, url: url)
        switch response {
        case let .assigned(value):
            guard value.handle == handle else { throw NativeDomainClientFailure.invalidResponse }
        case let .unassigned(returned, _):
            guard returned == handle else { throw NativeDomainClientFailure.invalidResponse }
        }
        return response
    }

    /// Probes and reads the company directory under `Atum-Company-Wire: 1.1`.
    /// A v1 answer is returned as `.v1`, never widened into the 1.1 shapes.
    public func companyList() async throws -> CompanyRead<CompanyList> {
        try CompanyWorkspaceWire.decodeList(try await companyData(url: Self.companiesURL,
                                                                  method: "GET", body: nil))
    }

    public func companySnapshot(companyID: NativeID) async throws -> CompanyRead<CompanySnapshot> {
        try CompanyWorkspaceWire.decodeSnapshot(
            try await companyData(url: try companyURL(companyID), method: "GET", body: nil))
    }

    public func companyChannels(companyID: NativeID) async throws -> CompanyRead<CompanyChannelDirectory> {
        try CompanyWorkspaceWire.decodeChannelDirectory(
            try await companyData(url: try companyURL(companyID, suffix: "channels"),
                                  method: "GET", body: nil))
    }

    public func acceptCompanyInvitation(companyID: NativeID, requestID: NativeID,
                                        invitationID: NativeID) async throws -> CompanySnapshot {
        let body: Data
        do {
            body = try JSONEncoder().encode(CompanyAcceptRequest(requestId: requestID,
                                                                 invitationId: invitationID))
        } catch {
            throw CompanyAPIError.invalid
        }
        let data = try await companyData(url: try companyURL(companyID, suffix: "accept"),
                                         method: "POST", body: body)
        let snapshot = try CompanyWorkspaceWire.decodeSnapshotV11(data)
        guard snapshot.company.id == companyID else { throw CompanyAPIError.invalid }
        return snapshot
    }

    public func leaveCompany(companyID: NativeID, requestID: NativeID) async throws -> CompanyLeaveAcknowledgement {
        let body: Data
        do {
            body = try JSONEncoder().encode(CompanyLeaveRequest(requestId: requestID))
        } catch {
            throw CompanyAPIError.invalid
        }
        let data = try await companyData(url: try companyURL(companyID, suffix: "leave"),
                                         method: "POST", body: body)
        let acknowledgement = try CompanyWorkspaceWire.decodeLeave(data)
        guard acknowledgement.companyId == companyID else { throw CompanyAPIError.invalid }
        return acknowledgement
    }

    /// `POST /companies` under `Atum-Company-Wire: 1.1`. The answer is the new
    /// company's first snapshot. A v1 answer (a rolled-back Shell) is a
    /// `CompanyWireRefusal`, never shown as a mistake in the name. The name is
    /// sent exactly as `CompanyName` shapes it, and the platform, not this
    /// client, decides who may create.
    public func createCompany(requestID: NativeID, displayName: String) async throws -> CompanySnapshot {
        guard let name = CompanyName.normalized(displayName), name == displayName else {
            throw CompanyAPIError.invalid
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(CompanyCreateRequest(requestId: requestID, displayName: name))
        } catch {
            throw CompanyAPIError.invalid
        }
        let data = try await companyData(url: Self.companiesURL, method: "POST", body: body)
        return try CompanyWorkspaceWire.decodeSnapshotV11(data)
    }

    // MARK: Company conversations (wire 1.5)

    /// `GET /company-capabilities` under `Atum-Company-Wire: 1.3`: whether this
    /// server and tenant have company DMs and group DMs on.
    public func companyCapabilities() async throws -> CompanyCapabilities {
        try decodeConversationAnswer(
            try await companyData(url: Self.companyCapabilitiesURL, method: "GET", body: nil, wire: .v1_3)
        ) { try CompanyConversationWire.decodeCapabilities($0) }
    }

    public func companyConversations(companyID: NativeID) async throws -> CompanyConversationDirectory {
        let directory = try decodeConversationAnswer(
            try await companyData(url: try companyURL(companyID, suffix: "conversations"),
                                  method: "GET", body: nil, wire: .v1_5)
        ) { try CompanyConversationWire.decodeDirectory($0) }
        guard directory.conversations.allSatisfy({ $0.companyId == companyID }) else {
            throw CompanyAPIError.invalid
        }
        return directory
    }

    public func openCompanyConversation(companyID: NativeID, requestID: NativeID,
                                        participantMemberRefs: [String]) async throws -> CompanyConversationAnswer {
        guard ConversationPeople.isWellFormed(participantMemberRefs) else { throw CompanyAPIError.invalid }
        let body = try conversationBody(CompanyConversationOpenRequest(
            requestId: requestID, participantMemberRefs: participantMemberRefs))
        let answer = try decodeConversationAnswer(
            try await companyData(url: try companyURL(companyID, suffix: "conversations"),
                                  method: "POST", body: body, wire: .v1_5)
        ) { try CompanyConversationWire.decodeAnswer($0) }
        guard CompanyConversationBinding.holds(answer, companyID: companyID,
                                               requestedRefs: participantMemberRefs) else {
            throw CompanyAPIError.invalid
        }
        return answer
    }

    public func expandCompanyConversation(companyID: NativeID, sourceConversationID: NativeID,
                                          requestID: NativeID,
                                          participantMemberRefs: [String]) async throws -> CompanyConversationAnswer {
        guard ConversationPeople.isWellFormed(participantMemberRefs), participantMemberRefs.count >= 3 else {
            throw CompanyAPIError.invalid
        }
        let body = try conversationBody(CompanyConversationExpandRequest(
            requestId: requestID, sourceConversationId: sourceConversationID,
            participantMemberRefs: participantMemberRefs))
        let url = try companyURL(companyID, suffix: "conversations/" + sourceConversationID.rawValue + "/expand")
        let answer = try decodeConversationAnswer(
            try await companyData(url: url, method: "POST", body: body, wire: .v1_5)
        ) { try CompanyConversationWire.decodeAnswer($0) }
        guard CompanyConversationBinding.holds(answer, companyID: companyID,
                                               requestedRefs: participantMemberRefs,
                                               sourceID: sourceConversationID) else {
            throw CompanyAPIError.invalid
        }
        return answer
    }

    public func setCompanyConversationHidden(companyID: NativeID, conversationID: NativeID, requestID: NativeID,
                                             hidden: Bool) async throws -> CompanyConversationHiddenAnswer {
        let body = try conversationBody(CompanyConversationHiddenRequest(requestId: requestID, hidden: hidden))
        let url = try companyURL(companyID, suffix: "conversations/" + conversationID.rawValue + "/hidden")
        let answer = try decodeConversationAnswer(
            try await companyData(url: url, method: "POST", body: body, wire: .v1_5)
        ) { try CompanyConversationWire.decodeHidden($0) }
        guard CompanyConversationBinding.holds(answer, conversationID: conversationID, hidden: hidden) else {
            throw CompanyAPIError.invalid
        }
        return answer
    }

    private func conversationBody<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) }
        catch { throw CompanyAPIError.invalid }
    }

    /// An answer that is not the closed shape (an unknown key, a forged digest,
    /// the wrong schema) is `.invalid`: a refusal, never data.
    private func decodeConversationAnswer<T>(_ data: Data, _ decode: (Data) throws -> T) throws -> T {
        do { return try decode(data) }
        catch { throw CompanyAPIError.invalid }
    }

    public func companyPrivateCosCapability() async throws -> CompanyPrivateCosCapability {
        try NativeAPI.decode(CompanyPrivateCosCapability.self, from:
            try await companyData(url: Self.privateCosCapabilityURL, method: "GET", body: nil, wire: .v1_3))
    }

    public func companyPrivateCosView(companyID: NativeID) async throws -> CompanyPrivateCosView {
        let view = try NativeAPI.decode(CompanyPrivateCosView.self, from:
            try await companyData(url: try companyURL(companyID, suffix: "private-cos"),
                                  method: "GET", body: nil, wire: .v1_3))
        guard view.pair.companyPrincipal == companyID else { throw CompanyAPIError.invalid }
        return view
    }

    private func companyData(url: URL, method: String, body: Data?,
                             wire: CompanyWire = .v1_1) async throws -> Data {
        do {
            return try await requestData(url: url, method: method, body: body,
                                         acceptsAssistantNameRefusal: false, companyWire: wire,
                                         maximumRequestBodyBytes: 4_096,
                                         maximumResponseBodyBytes: CompanyWorkspaceWire.maximumBytes)
        } catch let failure as NativeDomainClientFailure {
            throw CompanyAPIError(failure)
        } catch let refusal as CompanyWireRefusal {
            throw refusal
        }
    }

    /// Creates only the platform registry/MAS identity. Callers must not call
    /// this a usable assistant until a definition, answering runtime and
    /// canonical Matrix conversation have their own authoritative success.
    public func createAgent(_ input: AgentCreateRequest) async throws -> AgentsResponse.Agent {
        let body: Data
        do { body = try JSONEncoder().encode(input) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        let agent = try await request(AgentsResponse.Agent.self, url: Self.agentsURL,
                                      method: "POST", body: body,
                                      acceptsAssistantNameRefusal: true)
        guard !agent.isDefault, agent.status == .active, agent.matrixUser != nil
        else { throw NativeDomainClientFailure.invalidResponse }
        return agent
    }

    public func agentDefinition(assistantID: NativeID) async throws -> AgentDefinitionSnapshot {
        try await read(AgentDefinitionSnapshot.self, url: try agentDefinitionURL(assistantID))
    }

    public func writeAgentDefinition(assistantID: NativeID,
                                     value: AgentDefinitionWrite) async throws -> AgentDefinitionSnapshot {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        let snapshot = try await request(AgentDefinitionSnapshot.self,
                                         url: try agentDefinitionURL(assistantID),
                                         method: "PUT", body: body,
                                         acceptsAssistantNameRefusal: true)
        guard snapshot.assistant.id == assistantID, snapshot.definition != nil
        else { throw NativeDomainClientFailure.invalidResponse }
        return snapshot
    }

    public func writeAgentAvatar(assistantID: NativeID,
                                 value: AgentAvatarWrite) async throws -> AgentDefinitionSnapshot {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        let snapshot = try await request(AgentDefinitionSnapshot.self,
                                         url: try agentURL(assistantID, suffix: "avatar"),
                                         method: "PUT", body: body,
                                         acceptsAssistantNameRefusal: false,
                                         maximumRequestBodyBytes: 2_800_000)
        guard snapshot.assistant.id == assistantID,
              snapshot.assistant.principal == value.targetPrincipal else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return snapshot
    }

    public func agentPresentation(assistantID: NativeID) async throws -> AgentPresentationSnapshot {
        let snapshot = try await read(AgentPresentationSnapshot.self,
                                      url: try agentURL(assistantID, suffix: "presentation"))
        guard snapshot.assistantID == assistantID else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return snapshot
    }

    public func writeAgentPresentation(assistantID: NativeID,
                                       value: AgentPresentationWrite) async throws -> AgentPresentationSnapshot {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        let snapshot = try await request(AgentPresentationSnapshot.self,
                                         url: try agentURL(assistantID, suffix: "presentation"),
                                         method: "PUT", body: body,
                                         acceptsAssistantNameRefusal: false,
                                         maximumRequestBodyBytes: 4_096)
        guard snapshot.assistantID == assistantID else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return snapshot
    }

    public func agentRoutines(assistantID: NativeID) async throws -> AgentRoutinesSnapshot {
        let snapshot = try await read(AgentRoutinesSnapshot.self,
                                      url: try agentURL(assistantID, suffix: "routines"),
                                      maximumResponseBodyBytes: 4_500_000)
        guard snapshot.assistantID == assistantID else { throw NativeDomainClientFailure.invalidResponse }
        return snapshot
    }

    public func createAgentRoutine(assistantID: NativeID,
                                   value: AgentRoutineCreate) async throws -> AgentRoutine {
        let result = try await agentRoutineMutation(assistantID: assistantID, value: value)
        guard case let .routine(routine) = result else { throw NativeDomainClientFailure.invalidResponse }
        return routine
    }

    public func updateAgentRoutine(assistantID: NativeID,
                                   value: AgentRoutineUpdate) async throws -> AgentRoutine {
        let result = try await agentRoutineMutation(assistantID: assistantID, value: value)
        guard case let .routine(routine) = result, routine.id == value.routineId else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return routine
    }

    public func runAgentRoutine(assistantID: NativeID,
                                value: AgentRoutineAction) async throws -> AgentRoutine {
        guard value.operation == .run else { throw NativeDomainClientFailure.invalidRequest }
        let result = try await agentRoutineMutation(assistantID: assistantID, value: value)
        guard case let .routine(routine) = result, routine.id == value.routineId else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return routine
    }

    public func deleteAgentRoutine(assistantID: NativeID,
                                   value: AgentRoutineAction) async throws {
        guard value.operation == .delete else { throw NativeDomainClientFailure.invalidRequest }
        let result = try await agentRoutineMutation(assistantID: assistantID, value: value)
        guard case let .deleted(id, revision) = result,
              id == value.routineId, revision == value.expectedRevision else {
            throw NativeDomainClientFailure.invalidResponse
        }
    }

    public func agentRoutineRuns(assistantID: NativeID,
                                 routineID: NativeID) async throws -> AgentRoutineRunsSnapshot {
        let snapshot = try await read(AgentRoutineRunsSnapshot.self,
                                      url: try agentRoutineRunsURL(assistantID, routineID))
        guard snapshot.routineID == routineID else { throw NativeDomainClientFailure.invalidResponse }
        return snapshot
    }

    public func managedModels(agentPrincipal: NativeID) async throws -> ManagedModelSnapshot {
        let snapshot = try await read(ManagedModelSnapshot.self,
                                      url: try agentURL(agentPrincipal, suffix: "models"))
        guard snapshot.agentPrincipal == agentPrincipal else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return snapshot
    }

    public func writeManagedModel(agentPrincipal: NativeID,
                                  value: ManagedModelWrite) async throws -> ManagedModelSnapshot {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        let snapshot = try await request(ManagedModelSnapshot.self,
                                         url: try agentURL(agentPrincipal, suffix: "model-choice"),
                                         method: "PUT", body: body,
                                         acceptsAssistantNameRefusal: false)
        guard snapshot.agentPrincipal == agentPrincipal else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return snapshot
    }

    /// Reads the server's one default per agent destination. The snapshot is
    /// display-safe but remains server authority: the phone never fabricates
    /// a Mac, recommendation, cap, spend state, or saved choice.
    public func managedModelDestinations(agentPrincipal: NativeID) async throws
        -> ManagedModelDestinationSnapshot {
        let snapshot = try await read(
            ManagedModelDestinationSnapshot.self,
            url: try agentURL(agentPrincipal, suffix: "model-destinations")
        )
        guard snapshot.agentPrincipal == agentPrincipal else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return snapshot
    }

    /// Writes exactly one destination choice under the provider's revision
    /// and policy fences. Only the decoded response may be shown as saved.
    public func writeManagedModelDestination(agentPrincipal: NativeID,
                                             value: ManagedModelDestinationWrite) async throws
        -> ManagedModelDestinationSnapshot {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        let snapshot = try await request(
            ManagedModelDestinationSnapshot.self,
            url: try agentURL(agentPrincipal, suffix: "model-destinations"),
            method: "PUT", body: body,
            acceptsAssistantNameRefusal: false
        )
        guard snapshot.agentPrincipal == agentPrincipal else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return snapshot
    }

    // MARK: Agent home (`atum.agent-home/2.5`)

    /// The narrow owner projection: authoritative home, current reachability,
    /// real named Macs and exact 2.5 capability negotiation.
    public func agentHome(agentPrincipal: NativeID) async throws -> AgentHomeSnapshot {
        let snapshot = try await agentHomeRead(AgentHomeSnapshot.self,
                                               url: try agentHomeURL(agentPrincipal, suffix: "owner"))
        guard snapshot.agentPrincipal == agentPrincipal else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return snapshot
    }

    /// A sanitized platform projection of one Mac's catalog. There is no
    /// provider discovery, account reference or credential route on the phone.
    public func agentHomeCatalog(agentPrincipal: NativeID, deviceServiceID: NativeID) async throws
        -> AgentHomeMacCatalog {
        let catalog = try await agentHomeRead(
            AgentHomeMacCatalog.self,
            url: try agentHomeURL(agentPrincipal, suffix: "catalogs/" + deviceServiceID.rawValue),
            maximumResponseBodyBytes: AgentHomeContract.maximumCatalogResponseBytes
        )
        guard catalog.agentPrincipal == agentPrincipal,
              catalog.deviceServiceID == deviceServiceID else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return catalog
    }

    public func agentHomeModelApplication(agentPrincipal: NativeID) async throws
        -> AgentHomeModelApplication {
        let value = try await agentHomeRead(AgentHomeModelApplication.self,
                                            url: try agentHomeURL(agentPrincipal,
                                                                  suffix: "owner/model-choice/application"))
        guard value.agentPrincipal == agentPrincipal else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return value
    }

    // The four owner writes take the bearer request ID from the caller. A retry
    // of one logical operation passes the SAME `requestID` together with the
    // same `input.idempotencyKey` (see `AgentHomeOwnerWrites`); neither is made
    // again until the owner starts another operation.

    public func preflightAgentHomeMove(_ input: AgentHomePreflightInput, requestID: NativeID) async throws
        -> AgentHomeMovePreflight {
        let request = AgentHomePreflightRequest(
            meta: AgentHomeOwnerMeta(requestID: requestID), input: input
        )
        return try await agentHomeRequest(AgentHomeMovePreflight.self,
                                          agentPrincipal: input.agentPrincipal,
                                          suffix: "owner/preflight", body: request)
    }

    public func moveAgentHome(_ input: AgentHomeMoveInput, requestID: NativeID) async throws
        -> AgentHomeMoveCommandResult {
        let request = AgentHomeMoveRequest(meta: AgentHomeOwnerMeta(requestID: requestID), input: input)
        return try await agentHomeRequest(AgentHomeMoveCommandResult.self,
                                          agentPrincipal: input.agentPrincipal,
                                          suffix: "owner/moves", body: request,
                                          acceptedStatuses: [200, 202, 409])
    }

    public func cancelAgentHomeMove(_ input: AgentHomeCancelInput, requestID: NativeID) async throws
        -> AgentHomeMoveCommandResult {
        let request = AgentHomeCancelRequest(meta: AgentHomeOwnerMeta(requestID: requestID), input: input)
        return try await agentHomeRequest(AgentHomeMoveCommandResult.self,
                                          agentPrincipal: input.agentPrincipal,
                                          suffix: "owner/moves", body: request, method: "DELETE",
                                          acceptedStatuses: [200, 409])
    }

    public func agentHomeMoveProgress(agentPrincipal: NativeID, moveID: NativeID) async throws
        -> AgentHomeMoveProgress {
        let value = try await agentHomeRead(AgentHomeMoveProgress.self,
                                            url: try agentHomeURL(agentPrincipal,
                                                                  suffix: "owner/moves/" + moveID.rawValue))
        guard value.agentPrincipal == agentPrincipal, value.moveID == moveID else {
            throw NativeDomainClientFailure.invalidResponse
        }
        return value
    }

    public func writeAgentHomeModelChoice(_ input: AgentHomeModelChoiceInput, requestID: NativeID) async throws
        -> AgentHomeModelChoiceResult {
        let request = AgentHomeModelChoiceWrite(meta: AgentHomeOwnerMeta(requestID: requestID),
                                                input: input)
        return try await agentHomeRequest(AgentHomeModelChoiceResult.self,
                                          agentPrincipal: input.agentPrincipal,
                                          suffix: "owner/model-choice", body: request,
                                          method: "PUT", acceptedStatuses: [200, 409])
    }

    /// `before` is an opaque server cursor. It is neither decoded nor rebuilt
    /// from a history row, and the client sends no default `limit` parameter.
    public func walletHistory(limit: Int? = nil, before: String? = nil) async throws -> WalletHistoryResponse {
        guard limit.map({ (1...100).contains($0) }) ?? true else { throw NativeDomainClientFailure.invalidRequest }
        if let before {
            guard before.unicodeScalars.count <= 256, before.unicodeScalars.count >= 1,
                  before.unicodeScalars.allSatisfy({ scalar in
                      (scalar.value >= 65 && scalar.value <= 90) ||
                      (scalar.value >= 97 && scalar.value <= 122) ||
                      (scalar.value >= 48 && scalar.value <= 57) || scalar == "_" || scalar == "-"
                  }) else { throw NativeDomainClientFailure.invalidRequest }
        }
        var components = URLComponents(url: Self.walletHistoryURL, resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw NativeDomainClientFailure.invalidRequest }
        return try await read(WalletHistoryResponse.self, url: url)
    }

    private func read<T: Decodable>(_ type: T.Type, url: URL,
                                    maximumResponseBodyBytes: Int = 262_144) async throws -> T {
        try await request(type, url: url, method: "GET", body: nil,
                          acceptsAssistantNameRefusal: false,
                          maximumResponseBodyBytes: maximumResponseBodyBytes)
    }

    private func agentHomeRead<T: Decodable>(_ type: T.Type, url: URL,
                                             maximumResponseBodyBytes: Int = 262_144) async throws -> T {
        let result = try await requestWithHeaders(
            type, url: url, method: "GET", body: nil,
            acceptsAssistantNameRefusal: false,
            maximumResponseBodyBytes: maximumResponseBodyBytes,
            extraHeaders: agentHomeHeaders
        )
        try validateAgentHomeWire(result.headers)
        return result.value
    }

    private func agentHomeRequest<T: Decodable, Body: Encodable>(
        _ type: T.Type, agentPrincipal: NativeID, suffix: String, body value: Body,
        method: String = "POST", acceptedStatuses: Set<Int> = [200]
    ) async throws -> T {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        let result = try await requestWithHeaders(
            type, url: try agentHomeURL(agentPrincipal, suffix: suffix),
            method: method, body: body,
            acceptsAssistantNameRefusal: false,
            maximumRequestBodyBytes: 65_536,
            maximumResponseBodyBytes: 262_144,
            extraHeaders: agentHomeHeaders,
            acceptedStatuses: acceptedStatuses
        )
        try validateAgentHomeWire(result.headers)
        return result.value
    }

    private var agentHomeHeaders: [String: String] {
        [AgentHomeContract.wireHeader: AgentHomeContract.wireVersion]
    }

    private func validateAgentHomeWire(_ headers: [String: String]) throws {
        guard Self.header(AgentHomeContract.wireHeader, in: headers) == AgentHomeContract.profile else {
            throw NativeDomainClientFailure.invalidResponse
        }
    }

    private func request<T: Decodable>(_ type: T.Type, url: URL, method: String, body: Data?,
                                       acceptsAssistantNameRefusal: Bool,
                                       maximumRequestBodyBytes: Int = 262_144,
                                       maximumResponseBodyBytes: Int = 262_144,
                                       acceptedStatuses: Set<Int> = [200]) async throws -> T {
        try await requestWithHeaders(type, url: url, method: method, body: body,
                                     acceptsAssistantNameRefusal: acceptsAssistantNameRefusal,
                                     maximumRequestBodyBytes: maximumRequestBodyBytes,
                                     maximumResponseBodyBytes: maximumResponseBodyBytes,
                                     acceptedStatuses: acceptedStatuses).value
    }

    private func requestWithHeaders<T: Decodable>(_ type: T.Type, url: URL, method: String, body: Data?,
                                                  acceptsAssistantNameRefusal: Bool,
                                                  maximumRequestBodyBytes: Int = 262_144,
                                                  maximumResponseBodyBytes: Int = 262_144,
                                                  extraHeaders: [String: String] = [:],
                                                  acceptedStatuses: Set<Int> = [200])
        async throws -> (value: T, headers: [String: String]) {
        let response = try await response(url: url, method: method, body: body,
                                          acceptsAssistantNameRefusal: acceptsAssistantNameRefusal,
                                          companyWire: nil,
                                          maximumRequestBodyBytes: maximumRequestBodyBytes,
                                          maximumResponseBodyBytes: maximumResponseBodyBytes,
                                          extraHeaders: extraHeaders,
                                          acceptedStatuses: acceptedStatuses)
        return (try decode(type, data: response.body), response.headers)
    }

    private func requestData(url: URL, method: String, body: Data?,
                             acceptsAssistantNameRefusal: Bool, companyWire: CompanyWire?,
                             maximumRequestBodyBytes: Int = 262_144,
                             maximumResponseBodyBytes: Int = 262_144) async throws -> Data {
        try await response(url: url, method: method, body: body,
                           acceptsAssistantNameRefusal: acceptsAssistantNameRefusal,
                           companyWire: companyWire,
                           maximumRequestBodyBytes: maximumRequestBodyBytes,
                           maximumResponseBodyBytes: maximumResponseBodyBytes).body
    }

    private func response(url: URL, method: String, body: Data?,
                          acceptsAssistantNameRefusal: Bool = false, companyWire: CompanyWire? = nil,
                          maximumRequestBodyBytes: Int,
                          maximumResponseBodyBytes: Int,
                          extraHeaders: [String: String] = [:],
                          acceptedStatuses: Set<Int> = [200]) async throws -> NativeDomainHTTPResponse {
        do { try Task.checkCancellation() }
        catch { throw NativeDomainClientFailure.cancelled }
        let firstToken = try await authorize(forceRefresh: false)
        try requireActiveTask()
        let first = try await perform(url: url, token: firstToken, method: method, body: body,
                                      companyWire: companyWire,
                                      maximumRequestBodyBytes: maximumRequestBodyBytes,
                                      maximumResponseBodyBytes: maximumResponseBodyBytes,
                                      extraHeaders: extraHeaders)
        try requireActiveTask()
        if acceptedStatuses.contains(first.status) { return first }
        if first.status == 422, acceptsAssistantNameRefusal {
            throw NativeDomainClientFailure.assistantName(try assistantNameRefusal(first.body))
        }
        let firstFailure = try httpFailure(first)
        guard firstFailure.response.error == .unauthenticated else { throw NativeDomainClientFailure.http(firstFailure) }

        // A domain 401 is the only automatic retry. The coordinator enforces
        // single-flight rotation and persists the replacement before exposure.
        try requireActiveTask()
        let refreshedToken = try await authorize(forceRefresh: true)
        try requireActiveTask()
        let second = try await perform(url: url, token: refreshedToken, method: method, body: body,
                                       companyWire: companyWire,
                                       maximumRequestBodyBytes: maximumRequestBodyBytes,
                                       maximumResponseBodyBytes: maximumResponseBodyBytes,
                                       extraHeaders: extraHeaders)
        try requireActiveTask()
        if acceptedStatuses.contains(second.status) { return second }
        if second.status == 422, acceptsAssistantNameRefusal {
            throw NativeDomainClientFailure.assistantName(try assistantNameRefusal(second.body))
        }
        let failure = NativeDomainClientFailure.http(try httpFailure(second))
        if case let .http(http) = failure, http.response.error == .unauthenticated {
            authenticationFailureObserver(failure)
        }
        throw failure
    }

    /// `POST` with the same single-flight 401 refresh as `request`, but
    /// returning the raw response so a caller can answer a refused body
    /// itself (the assistant placement retries a 4xx with the empty body).
    private func performAuthorized(url: URL, body: Data,
                                   extraHeaders: [String: String] = [:]) async throws -> NativeDomainHTTPResponse {
        do { try Task.checkCancellation() }
        catch { throw NativeDomainClientFailure.cancelled }
        let firstToken = try await authorize(forceRefresh: false)
        try requireActiveTask()
        let first = try await perform(url: url, token: firstToken, method: "POST", body: body,
                                      maximumRequestBodyBytes: 4_096, maximumResponseBodyBytes: 262_144,
                                      extraHeaders: extraHeaders)
        try requireActiveTask()
        guard first.status == 401 else { return first }

        // A domain 401 is the only automatic retry. The coordinator enforces
        // single-flight rotation and persists the replacement before exposure.
        let refreshedToken = try await authorize(forceRefresh: true)
        try requireActiveTask()
        let second = try await perform(url: url, token: refreshedToken, method: "POST", body: body,
                                       maximumRequestBodyBytes: 4_096, maximumResponseBodyBytes: 262_144,
                                       extraHeaders: extraHeaders)
        try requireActiveTask()
        if second.status == 401 {
            authenticationFailureObserver(NativeDomainClientFailure.authenticationRefused)
        }
        return second
    }

    func authorize(forceRefresh: Bool) async throws -> String {
        do {
            return try await authorization(forceRefresh)
        } catch {
            authenticationFailureObserver(error)
            throw error
        }
    }

    private func requireActiveTask() throws {
        do { try Task.checkCancellation() }
        catch { throw NativeDomainClientFailure.cancelled }
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do { return try NativeAPI.decode(type, from: data) }
        catch { throw NativeDomainClientFailure.invalidResponse }
    }

    private func httpFailure(_ response: NativeDomainHTTPResponse) throws -> NativeHTTPFailure {
        do { return try NativeHTTPFailure(status: response.status, headers: response.headers, body: response.body) }
        catch { throw NativeDomainClientFailure.invalidResponse }
    }

    private func assistantNameRefusal(_ data: Data) throws -> AssistantNameRefusal {
        do { return try NativeAPI.decode(AssistantNameRefusalResponse.self, from: data).error }
        catch { throw NativeDomainClientFailure.invalidResponse }
    }

    private func perform(url: URL, token: String, method: String,
                         body: Data?, companyWire: CompanyWire? = nil, maximumRequestBodyBytes: Int,
                         maximumResponseBodyBytes: Int,
                         extraHeaders: [String: String] = [:]) async throws -> NativeDomainHTTPResponse {
        guard isApprovedURL(url), isBearerToken(token), ["DELETE", "GET", "POST", "PUT"].contains(method),
              maximumRequestBodyBytes >= 0, (body?.count ?? 0) <= maximumRequestBodyBytes,
              (0...4_500_000).contains(maximumResponseBodyBytes),
              (method == "GET") == (body == nil),
              extraHeaders.allSatisfy({ name, value in
                  if url.path.hasPrefix(Self.baseURL.path + "/store/") {
                      if name == StoreWire.capabilitiesHeader { return value == StoreWire.capabilities }
                      if name == "Idempotency-Key" {
                          return url.path == Self.baseURL.path + "/store/purchases" && method == "POST"
                              && (try? NativeID(value)) != nil
                      }
                  }
                  if name == OwnerTimeZoneContract.requestHeader {
                      return OwnerTimeZoneContract.isValid(value)
                  }
                  return name == AgentHomeContract.wireHeader && value == AgentHomeContract.wireVersion
              })
        else { throw NativeDomainClientFailure.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let companyWire { request.setValue(companyWire.rawValue, forHTTPHeaderField: CompanyWire.headerName) }
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let operation = NativeDomainJSONOperation(request: request, protocolClasses: protocolClasses,
                                                  maximumBodyBytes: maximumResponseBodyBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: {
            operation.cancel()
        }
    }

    private func companyURL(_ companyID: NativeID, suffix: String? = nil) throws -> URL {
        var value = Self.companiesURL.absoluteString + "/" + companyID.rawValue
        if let suffix { value += "/" + suffix }
        guard let url = URL(string: value) else { throw NativeDomainClientFailure.invalidRequest }
        return url
    }

    private func agentDefinitionURL(_ assistantID: NativeID) throws -> URL {
        try agentURL(assistantID, suffix: "definition")
    }

    private func agentLifecycleOperation<T: Encodable>(_ value: T) async throws -> AgentLifecycleSnapshot {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        return try await request(AgentLifecycleSnapshot.self,
                                 url: Self.agentLifecycleURL,
                                 method: "POST", body: body,
                                 acceptsAssistantNameRefusal: true,
                                 maximumRequestBodyBytes: 4_096)
    }

    private func agentRoutineMutation<T: Encodable>(assistantID: NativeID,
                                                     value: T) async throws -> AgentRoutineMutationResult {
        let body: Data
        do { body = try JSONEncoder().encode(value) }
        catch { throw NativeDomainClientFailure.invalidRequest }
        return try await request(AgentRoutineMutationResult.self,
                                 url: try agentURL(assistantID, suffix: "routines"),
                                 method: "POST", body: body,
                                 acceptsAssistantNameRefusal: false)
    }

    private func agentRoutineRunsURL(_ assistantID: NativeID, _ routineID: NativeID) throws -> URL {
        guard let url = URL(string: Self.baseURL.absoluteString + "/agents/" + assistantID.rawValue
                            + "/routines/" + routineID.rawValue + "/runs") else {
            throw NativeDomainClientFailure.invalidRequest
        }
        return url
    }

    private func agentURL(_ id: NativeID, suffix: String) throws -> URL {
        guard ["definition", "avatar", "presentation", "models", "model-choice",
               "model-destinations", "routines"].contains(suffix),
              let url = URL(string: Self.baseURL.absoluteString + "/agents/" + id.rawValue + "/" + suffix)
        else { throw NativeDomainClientFailure.invalidRequest }
        return url
    }

    private func agentHomeURL(_ id: NativeID, suffix: String? = nil) throws -> URL {
        let tail = suffix.map { "/" + $0 } ?? ""
        guard let url = URL(string: Self.baseURL.absoluteString + "/agents/" + id.rawValue + "/home" + tail),
              isAgentPath(url.path) else { throw NativeDomainClientFailure.invalidRequest }
        return url
    }

    private func appURL(_ slug: String, suffix: String? = nil) throws -> URL {
        _ = try checkedString(slug, minimum: 1, maximum: 64, pattern: "[a-z][a-z0-9_-]{0,63}")
        let tail = suffix.map { "/" + $0 } ?? ""
        guard [nil, "bot", "bot/consent", "bot/intake", "bot/start", "connection", "connect",
               "connect/confirm", "launch"].contains(suffix),
              let url = URL(string: Self.appsURL.absoluteString + "/" + slug + tail) else {
            throw NativeDomainClientFailure.invalidRequest
        }
        return url
    }

    private func isApprovedURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "api.atumplatform.com", url.port == nil,
              url.user == nil, url.password == nil, url.fragment == nil else { return false }
        guard url.path.hasPrefix(Self.baseURL.path + "/") else { return false }
        let allowedPaths = [Self.agentsURL.path, Self.agentLifecycleURL.path,
                            Self.appsURL.path, Self.officialAccountsURL.path,
                            Self.storeCatalogURL.path,
                            Self.walletURL.path, Self.walletHistoryURL.path, Self.aliasLookupURL.path,
                            Self.assistantURL.path, Self.cloudDisclosureURL.path, CloudTurnStop.path,
                            Self.companiesURL.path, Self.companyCapabilitiesURL.path,
                            Self.driveAccountURL.path, Self.privateCosCapabilityURL.path]
        let storeRoot = Self.baseURL.path + "/store/"
        let storeTail = String(url.path.dropFirst(storeRoot.count))
        let storeParts = storeTail.split(separator: "/", omittingEmptySubsequences: false)
        let nativeStorePath = url.path.hasPrefix(storeRoot) && (
            ["catalog", "entitlements", "purchases"].contains(storeTail)
            || (storeParts.count == 3 && storeParts[0] == "entitlements" && storeParts[2] == "cancel"
                && (try? NativeID(String(storeParts[1]))) != nil))
        let dynamicAgentPath = isAgentPath(url.path)
        let dynamicCompanyPath = isCompanyPath(url.path)
        let dynamicAppPath = isAppPath(url.path)
        guard allowedPaths.contains(url.path) || Self.applePaths.contains(url.path) || dynamicAgentPath || dynamicCompanyPath || dynamicAppPath || nativeStorePath
        else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let query = components.queryItems ?? []
        if dynamicAgentPath || dynamicCompanyPath || dynamicAppPath { return url.query == nil }
        if url.path == Self.aliasLookupURL.path {
            guard query.count == 1, query[0].name == "handle", let value = query[0].value,
                  (try? NativeHandle(value)) != nil else { return false }
            return true
        }
        guard url.path == Self.walletHistoryURL.path else { return url.query == nil }
        guard query.count <= 2, Set(query.map(\.name)).count == query.count,
              query.allSatisfy({ ["limit", "before"].contains($0.name) && $0.value != nil }) else { return false }
        for item in query {
            if item.name == "limit" {
                guard let value = item.value, let limit = Int(value), String(limit) == value, (1...100).contains(limit) else { return false }
            } else if item.name == "before" {
                guard let value = item.value, value.unicodeScalars.count >= 1, value.unicodeScalars.count <= 256,
                      value.unicodeScalars.allSatisfy({ scalar in
                          (scalar.value >= 65 && scalar.value <= 90) ||
                          (scalar.value >= 97 && scalar.value <= 122) ||
                          (scalar.value >= 48 && scalar.value <= 57) || scalar == "_" || scalar == "-"
                      }) else { return false }
            }
        }
        return true
    }

    private func isCompanyPath(_ path: String) -> Bool {
        let prefix = Self.companiesURL.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let parts = path.dropFirst(prefix.count)
            .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, (try? NativeID(first)) != nil else { return false }
        if parts.count == 1 { return true }
        if parts.count == 2 { return ["accept", "leave", "channels", "conversations", "private-cos"].contains(parts[1]) }
        // conversations/{id} and conversations/{id}/expand|hidden
        guard parts[1] == "conversations", (try? NativeID(parts[2])) != nil else { return false }
        if parts.count == 3 { return true }
        return parts.count == 4 && ["expand", "hidden"].contains(parts[3])
    }

    private func isAgentPath(_ path: String) -> Bool {
        let prefix = Self.baseURL.path + "/agents/"
        guard path.hasPrefix(prefix) else { return false }
        let tail = path.dropFirst(prefix.count)
        let parts = tail.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, (try? NativeID(parts[0])) != nil else { return false }
        if parts[1] == "home" { return isAgentHomePath(Array(parts.dropFirst(2))) }
        if parts.count == 2 {
            return ["definition", "avatar", "presentation", "models", "model-choice",
                    "model-destinations", "routines"].contains(parts[1])
        }
        return parts.count == 4 && parts[1] == "routines" && parts[3] == "runs"
            && (try? NativeID(parts[2])) != nil
    }

    private func isAgentHomePath(_ tail: [String]) -> Bool {
        if tail == ["owner"] || tail == ["owner", "preflight"]
            || tail == ["owner", "moves"] || tail == ["owner", "model-choice"]
            || tail == ["owner", "model-choice", "application"] { return true }
        if tail.count == 2, tail[0] == "catalogs" { return (try? NativeID(tail[1])) != nil }
        if tail.count == 3, tail[0] == "owner", tail[1] == "moves" {
            return (try? NativeID(tail[2])) != nil
        }
        return false
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func isAppPath(_ path: String) -> Bool {
        let prefix = Self.appsURL.path + "/"
        guard path.hasPrefix(prefix) else { return false }
        let parts = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard let slug = parts.first,
              (try? checkedString(slug, minimum: 1, maximum: 64,
                                  pattern: "[a-z][a-z0-9_-]{0,63}")) != nil else { return false }
        let suffix = parts.dropFirst().joined(separator: "/")
        return ["", "bot", "bot/consent", "bot/intake", "bot/start", "connection", "connect",
                "connect/confirm", "launch"].contains(suffix)
    }

    private func isBearerToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8_192 && !value.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }
    }
}

private struct NativeDomainHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

/// Mirrors MASHTTP's one-operation ephemeral session design, but retains a
/// bounded non-200 JSON body solely to decode the frozen error envelope.
private final class NativeDomainJSONOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: URLRequest
    private let protocolClasses: [URLProtocol.Type]?
    private let maximumBodyBytes: Int
    private var session: URLSession?
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<NativeDomainHTTPResponse, any Error>?
    private var status: Int?
    private var headers: [String: String] = [:]
    private var bytes = Data()
    private var acceptedResponse = false
    private var finished = false

    init(request: URLRequest, protocolClasses: [URLProtocol.Type]?, maximumBodyBytes: Int) {
        self.request = request
        self.protocolClasses = protocolClasses
        self.maximumBodyBytes = maximumBodyBytes
    }

    func start(_ continuation: CheckedContinuation<NativeDomainHTTPResponse, any Error>) {
        let task: URLSessionTask? = lock.withLock {
            guard !finished else { return nil }
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = false
            if let protocolClasses { config.protocolClasses = protocolClasses }
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            self.session = session
            var input = request
            input.httpShouldHandleCookies = false
            input.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let task = session.dataTask(with: input)
            self.task = task
            return task
        }
        guard let task else {
            continuation.resume(throwing: NativeDomainClientFailure.cancelled)
            return
        }
        task.resume()
    }

    func cancel() { finish(.failure(NativeDomainClientFailure.cancelled)) }

    private func finish(_ result: Result<NativeDomainHTTPResponse, any Error>) {
        let completion: (CheckedContinuation<NativeDomainHTTPResponse, any Error>?, URLSession?)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let values = (continuation, session)
            continuation = nil
            session = nil
            task = nil
            status = nil
            headers.removeAll(keepingCapacity: false)
            bytes.removeAll(keepingCapacity: false)
            return values
        }
        guard let completion else { return }
        completion.1?.invalidateAndCancel()
        completion.0?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(NativeDomainClientFailure.redirectRefused))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        _ completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completion(.performDefaultHandling, nil)
        } else {
            completion(.cancelAuthenticationChallenge, nil)
            finish(.failure(NativeDomainClientFailure.authenticationRefused))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url == request.url,
              Self.isJSON(response.value(forHTTPHeaderField: "Content-Type")) else {
            completionHandler(.cancel)
            finish(.failure(NativeDomainClientFailure.invalidResponse))
            return
        }
        if let rawLength = response.value(forHTTPHeaderField: "Content-Length") {
            guard !rawLength.isEmpty, rawLength.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let length = Int64(rawLength) else {
                completionHandler(.cancel)
                finish(.failure(NativeDomainClientFailure.invalidResponse))
                return
            }
            guard length <= maximumBodyBytes else {
                completionHandler(.cancel)
                finish(.failure(NativeDomainClientFailure.responseTooLarge))
                return
            }
        }
        let responseHeaders = response.allHeaderFields.reduce(into: [String: String]()) { values, pair in
            guard let key = pair.key as? String, let value = pair.value as? String else { return }
            values[key] = value
        }
        lock.withLock {
            guard !finished else { return }
            status = response.statusCode
            headers = responseHeaders
            acceptedResponse = true
        }
        completionHandler(.allow)
    }

    private static func isJSON(_ contentType: String?) -> Bool {
        guard let contentType else { return false }
        let mediaType = contentType.split(separator: ";", maxSplits: 1,
                                          omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return mediaType.caseInsensitiveCompare("application/json") == .orderedSame
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = lock.withLock {
            guard !finished else { return false }
            guard data.count <= maximumBodyBytes, bytes.count <= maximumBodyBytes - data.count else { return true }
            bytes.append(data)
            return false
        }
        if oversized { finish(.failure(NativeDomainClientFailure.responseTooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if error != nil {
            finish(.failure(NativeDomainClientFailure.transportUnavailable))
            return
        }
        let result: Result<NativeDomainHTTPResponse, any Error> = lock.withLock {
            guard acceptedResponse, let status else { return .failure(NativeDomainClientFailure.invalidResponse) }
            return .success(NativeDomainHTTPResponse(status: status, headers: headers, body: bytes))
        }
        finish(result)
    }
}
