import Foundation

public enum MASHTTPFailure: Error, Equatable {
    case invalidRequest, invalidResponse, responseTooLarge, redirectRefused
    case bodyReplayRefused, authenticationRefused, transportUnavailable, cancelled
    case httpStatus(Int)
}

/// Token delivery timing is separate from JWT verification time. Installation
/// uses requestStartedAt for conservative response-derived expiry.
public struct MASCodeDelivery: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let grant: OIDCVerifiedGrant
    public let requestStartedAt, responseReceivedAt: Date
    public var description: String { "MASCodeDelivery(<secrets redacted>)" }
    public var debugDescription: String { description }
}

/// One bounded HTTPS request per operation. No cookies, ambient credentials,
/// redirects, caches, automatic application retries or raw error propagation.
public final class MASHTTP: Sendable {
    private let protocols: [URLProtocol.Type]?
    public init() { protocols = nil }
    init(protocols: [URLProtocol.Type]) { self.protocols = protocols }

    public func discovery(at url: URL, expectedIssuer: String) async throws -> MASMetadata {
        let bytes = try await json(get(url))
        return try MASMetadata.decode(bytes, expectedIssuer: expectedIssuer)
    }
    public func jwks(for metadata: MASMetadata) async throws -> Data {
        try await json(get(metadata.jwksURI))
    }
    public func exchange(_ callback: OIDCAcceptedCallback, metadata: MASMetadata) async throws -> MASCodeDelivery {
        guard callback.flow.issuer == metadata.issuer, callback.flow.tokenEndpoint == metadata.tokenEndpoint else { throw MASHTTPFailure.invalidRequest }
        let started = Date()
        let response = try OIDCTokenResponse.decode(await json(callback.tokenRequest()))
        let received = Date()
        let keys = try await jwks(for: metadata)
        return MASCodeDelivery(grant: try callback.verifyGrant(response, jwks: keys, metadata: metadata, now: Date()),
                               requestStartedAt: started, responseReceivedAt: received)
    }
    public func refresh(_ request: URLRequest, metadata: MASMetadata) async throws -> OIDCRefreshReply {
        guard request.url == metadata.tokenEndpoint, request.httpMethod == "POST" else { throw MASHTTPFailure.invalidRequest }
        let response = try OIDCTokenResponse.decode(await json(request))
        // No ID token means there is no signature input requiring a key fetch.
        let keys = response.idToken == nil ? Data() : try await jwks(for: metadata)
        return OIDCRefreshReply(response: response, jwks: keys, verificationTime: Date())
    }
    /// The app is pinned to Atum's production homeserver. A raw caller URL or
    /// decoded whoami JSON cannot mint this authenticated device receipt.
    public func matrixWhoami(grant: OIDCVerifiedGrant) async throws -> MatrixAuthenticatedDevice {
        guard let requested = grant.requestedDeviceID, grant.identity.isAuthorizationCode else {
            throw OIDCFailure.deviceMismatch
        }
        var request = get(MatrixAuthenticatedDevice.whoamiURL)
        let authorization = "Bearer " + grant.response.accessToken
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let bytes = try await json(request, matrixAuthorization: authorization)
        return try MatrixAuthenticatedDevice.delivered(bytes, grant: grant, requested: requested)
    }
    /// The sole domain read allowed before three-way account binding. A Matrix
    /// grant cannot authorize it, and no caller-supplied URL is accepted.
    static let domainMeURL = URL(string: "https://api.atumplatform.com/api/matrix/v1/me")!
    public func domainMe(grant: OIDCVerifiedGrant) async throws -> OIDCMe {
        guard grant.requestedDeviceID == nil, grant.identity.isAuthorizationCode,
              grant.response.scope == nil || grant.response.scope == "openid" else { throw OIDCGrantFailure.invalidIdentity }
        var request = get(Self.domainMeURL)
        let authorization = "Bearer " + grant.response.accessToken
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        return try NativeAPI.decode(OIDCMe.self, from: await json(request, bearer: authorization))
    }
    /// RFC7009 acknowledges an unknown/already-revoked token with HTTP200 and
    /// does not require a JSON response. Each token POST is sent once.
    func revokeDomain(_ record: OIDCStoredGrant, metadata: MASMetadata) async throws {
        for request in try Self.domainRevocationRequests(record, metadata: metadata) {
            _ = try await json(request, acknowledgementOnly: true)
        }
    }
    public func revokeDrive(_ record: OIDCStoredGrant, metadata: MASMetadata) async throws {
        guard record.clientID == MASPublicClients.drive else {
            throw MASHTTPFailure.invalidRequest
        }
        try await revokeDomain(record, metadata: metadata)
    }
    static func domainRevocationRequests(_ record: OIDCStoredGrant, metadata: MASMetadata) throws -> [URLRequest] {
        guard record.issuer == metadata.issuer else { throw MASHTTPFailure.invalidRequest }
        return [(record.refreshToken, "refresh_token"), (record.accessToken, "access_token")].map { token, hint in
            var request = URLRequest(url: metadata.revocationEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = OIDCForm.encode([("client_id", record.clientID), ("token", token), ("token_type_hint", hint)])
            return request
        }
    }
    private func get(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"; request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    private func json(_ input: URLRequest, matrixAuthorization: String? = nil, bearer: String? = nil,
                      acknowledgementOnly: Bool = false) async throws -> Data {
        let authorization = matrixAuthorization ?? bearer
        guard let url = input.url, MASMetadata.isHTTPS(url), url.query == nil,
              ["GET", "POST"].contains(input.httpMethod),
              input.value(forHTTPHeaderField: "Authorization") == authorization,
              authorization == nil || (input.httpMethod == "GET" &&
                  (matrixAuthorization != nil ? url == MatrixAuthenticatedDevice.whoamiURL : url == Self.domainMeURL)),
              input.value(forHTTPHeaderField: "Cookie") == nil,
              input.value(forHTTPHeaderField: "Origin") == nil,
              input.httpBodyStream == nil else { throw MASHTTPFailure.invalidRequest }
        if input.httpMethod == "POST" {
            guard input.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded",
                  let body = input.httpBody, !body.isEmpty, body.count <= 65_536 else { throw MASHTTPFailure.invalidRequest }
        } else if input.httpBody != nil { throw MASHTTPFailure.invalidRequest }
        let operation = MASJSONOperation(request: input, protocols: protocols, acknowledgementOnly: acknowledgementOnly)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
    }
}

/// A streamed upload may ask for its initial body and later a replay. Only the
/// first stream is supplied; ambiguity is resolved by the grant coordinator.
final class MASOneShotBody: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    init(_ data: Data?) { self.data = data }
    func consume() -> InputStream? {
        lock.withLock {
            guard let data else { return nil }
            self.data = nil
            return InputStream(data: data)
        }
    }
    func clear() { lock.withLock { data = nil } }
}

// Delegate callbacks use a serial operation queue; cancellation/start can run
// elsewhere, so every mutable shared field is protected by this lock.
private final class MASJSONOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let maximum = 262_144
    private let lock = NSLock()
    private let request: URLRequest
    private let protocols: [URLProtocol.Type]?
    private let body: MASOneShotBody
    private let acknowledgementOnly: Bool
    private var session: URLSession?
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<Data, any Error>?
    private var bytes = Data()
    private var acceptedResponse = false
    private var finished = false

    init(request: URLRequest, protocols: [URLProtocol.Type]?, acknowledgementOnly: Bool) {
        self.request = request; self.protocols = protocols; self.acknowledgementOnly = acknowledgementOnly
        body = MASOneShotBody(request.httpBody)
    }
    func start(_ continuation: CheckedContinuation<Data, any Error>) {
        let task: URLSessionTask? = lock.withLock {
            guard !finished else { return nil }
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            config.urlCredentialStorage = nil; config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 30
            config.waitsForConnectivity = false
            if let protocols { config.protocolClasses = protocols }
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            self.session = session
            var input = request
            input.httpShouldHandleCookies = false
            input.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            input.setValue("application/json", forHTTPHeaderField: "Accept")
            let task: URLSessionTask
            if input.httpMethod == "POST" {
                input.setValue(String(input.httpBody!.count), forHTTPHeaderField: "Content-Length")
                input.httpBody = nil
                task = session.uploadTask(withStreamedRequest: input)
            } else { task = session.dataTask(with: input) }
            self.task = task
            return task
        }
        guard let task else { continuation.resume(throwing: MASHTTPFailure.cancelled); return }
        task.resume()
    }
    func cancel() { finish(.failure(MASHTTPFailure.cancelled)) }
    private func finish(_ result: Result<Data, any Error>) {
        let completion: (CheckedContinuation<Data, any Error>?, URLSession?)? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            let values = (continuation, session)
            continuation = nil; session = nil; task = nil; bytes.removeAll(keepingCapacity: false)
            return values
        }
        guard let completion else { return }
        body.clear()
        completion.1?.invalidateAndCancel()
        completion.0?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        let stream = body.consume()
        completionHandler(stream)
        if stream == nil { finish(.failure(MASHTTPFailure.bodyReplayRefused)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(MASHTTPFailure.redirectRefused))
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }
    private func handle(_ challenge: URLAuthenticationChallenge, _ completion: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completion(.performDefaultHandling, nil)
        } else {
            completion(.cancelAuthenticationChallenge, nil)
            finish(.failure(MASHTTPFailure.authenticationRefused))
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url == request.url else {
            completionHandler(.cancel); finish(.failure(MASHTTPFailure.invalidResponse)); return
        }
        guard response.statusCode == 200 else {
            completionHandler(.cancel); finish(.failure(MASHTTPFailure.httpStatus(response.statusCode))); return
        }
        guard acknowledgementOnly || response.mimeType?.lowercased() == "application/json" else {
            completionHandler(.cancel); finish(.failure(MASHTTPFailure.invalidResponse)); return
        }
        if let value = response.value(forHTTPHeaderField: "Content-Length") {
            guard let count = Int64(value), count >= 0 else {
                completionHandler(.cancel); finish(.failure(MASHTTPFailure.invalidResponse)); return
            }
            guard count <= Self.maximum else {
                completionHandler(.cancel); finish(.failure(MASHTTPFailure.responseTooLarge)); return
            }
        }
        lock.withLock { acceptedResponse = true }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let oversized = lock.withLock {
            guard !finished else { return false }
            guard bytes.count <= Self.maximum - data.count else { return true }
            bytes.append(data); return false
        }
        if oversized { finish(.failure(MASHTTPFailure.responseTooLarge)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if error != nil { finish(.failure(MASHTTPFailure.transportUnavailable)); return }
        let result: Result<Data, any Error> = lock.withLock {
            acceptedResponse ? .success(bytes) : .failure(MASHTTPFailure.invalidResponse)
        }
        finish(result)
    }
}
