import Foundation

@MainActor public protocol DriveReading: AnyObject {
    func rootPage() async throws -> DrivePage
    func children(driveID: String, parentID: String) async throws -> DrivePage
    func download(_ item: DriveItem, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

public extension DriveReading {
    func download(_ item: DriveItem, to destination: URL) async throws {
        try await download(item, to: destination, progress: { _, _ in })
    }
}

/// The narrow read-only Graph/WebDAV client selected by
/// `atum.mobile-drive/1`. It has no upload, mutation, sharing or public-link
/// operation.
@MainActor public final class DriveClient: DriveReading {
    typealias Authorization = @MainActor @Sendable (_ forceRefresh: Bool) async throws -> String
    private static let listingLimit = 500

    private var usesAccountGrant = false
    private let serverURL: URL
    private let authorization: Authorization
    private let protocolClasses: [URLProtocol.Type]?
    private let permitsTestHost: Bool

    public init(serverURL: URL, refresh: OIDCGrantRefresh,
                exchange: @escaping OIDCGrantRefresh.Exchange) throws {
        try Self.validateServer(serverURL, permitsTestHost: false)
        self.serverURL = serverURL
        authorization = { forceRefresh in
            if forceRefresh {
                return try await refresh.refresh(now: Date(), exchange: exchange)
            }
            return try await refresh.accessToken(now: Date(), exchange: exchange)
        }
        protocolClasses = nil
        permitsTestHost = false
    }

    /// Shares the account client's single refresh chain and recovery observer.
    public convenience init(serverURL: URL, domainClient: NativeDomainClient) throws {
        try self.init(serverURL: serverURL, domainClient: domainClient, protocolClasses: nil)
    }

    init(serverURL: URL, domainClient: NativeDomainClient,
         protocolClasses: [URLProtocol.Type]?) throws {
        try Self.validateServer(serverURL, permitsTestHost: protocolClasses != nil)
        self.serverURL = serverURL
        authorization = { force in try await domainClient.authorize(forceRefresh: force) }
        self.protocolClasses = protocolClasses
        permitsTestHost = protocolClasses != nil
        usesAccountGrant = true
    }

    init(serverURL: URL, testAuthorization: @escaping Authorization,
         protocolClasses: [URLProtocol.Type]) throws {
        try Self.validateServer(serverURL, permitsTestHost: true)
        self.serverURL = serverURL
        authorization = testAuthorization
        self.protocolClasses = protocolClasses
        permitsTestHost = true
    }

    public func personalDrive() async throws -> DriveSpace {
        let url = try endpoint(path: "/graph/v1.0/me/drives")
        let response = try await json(url)
        let decoded: GraphCollection<ListedDrive>
        do {
            decoded = try NativeAPI.decode(
                GraphCollection<ListedDrive>.self,
                from: response,
                forbidden: DriveContract.forbiddenRawGraphFields
            )
        } catch {
            throw DriveFailure.invalidResponse
        }
        // `/me/drives` lists every space the account can see, not only the
        // personal one: OpenCloud adds the virtual "Shares" space and project or
        // mount-point spaces whose shape this client does not read. One such
        // element must not fail the whole listing; only well-formed personal
        // drives count, and there must be exactly one.
        let personal = decoded.value.compactMap(\.drive).filter { $0.driveType == "personal" }
        guard personal.count == 1, decoded.nextLink == nil else {
            throw DriveFailure.invalidResponse
        }
        return try DriveSpace(id: personal[0].id, name: personal[0].name)
    }

    public func rootPage() async throws -> DrivePage {
        let drive = try await personalDrive()
        return try await list(
            endpoint: endpoint(path: "/graph/v1.0/me/drive/root/children"),
            driveID: drive.id,
            parentID: DrivePage.rootParentID
        )
    }

    public func children(driveID: String, parentID: String) async throws -> DrivePage {
        _ = try DriveSpace(id: driveID, name: "Drive")
        _ = try checkedString(parentID, minimum: 1, maximum: 1_024)
        let drive = try encodedPathComponent(driveID)
        let parent = try encodedPathComponent(parentID)
        return try await list(
            endpoint: endpoint(
                percentEncodedPath: "/graph/v1.0/drives/\(drive)/items/\(parent)/children"
            ),
            driveID: driveID,
            parentID: parentID
        )
    }

    /// Streams the exact selected ETag to an account-cache staging file. The
    /// caller atomically promotes it only after this method verifies headers
    /// and length.
    public func download(_ item: DriveItem, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        guard item.kind == .file, let webDavURL = item.webDavURL, sameOrigin(webDavURL),
              webDavURL.path.hasPrefix("/dav/spaces/"),
              webDavURL.query == nil,
              item.size <= Int64(Int.max) else {
            throw DriveFailure.invalidRequest
        }
        let response = try await downloadAttempt(item, to: destination, forceRefresh: false,
                                                 progress: progress)
        if response.status == 401 {
            try? FileManager.default.removeItem(at: destination)
            let second = try await downloadAttempt(item, to: destination, forceRefresh: true,
                                                   progress: progress)
            try validateDownload(second, item: item, destination: destination)
        } else {
            try validateDownload(response, item: item, destination: destination)
        }
    }

    private func list(endpoint first: URL, driveID: String,
                      parentID: String) async throws -> DrivePage {
        var next: URL? = first
        var seen = Set<String>()
        var items = [DriveItem]()
        var pages = 0
        var truncated = false

        listing: while let current = next {
            guard pages < 100, allowedPageURL(current, matchingPath: first.path) else {
                throw DriveFailure.invalidResponse
            }
            pages += 1
            let body = try await json(current)
            let page: GraphCollection<GraphItem>
            do {
                page = try NativeAPI.decode(
                    GraphCollection<GraphItem>.self,
                    from: body,
                    forbidden: DriveContract.forbiddenRawGraphFields
                )
            } catch {
                throw DriveFailure.invalidResponse
            }
            for wire in page.value {
                guard seen.insert(wire.id).inserted else {
                    throw DriveFailure.invalidResponse
                }
                guard items.count < Self.listingLimit else {
                    truncated = true
                    break listing
                }
                let item = try wire.item()
                if let url = item.webDavURL, !sameOrigin(url) { throw DriveFailure.invalidResponse }
                items.append(item)
            }
            if let value = page.nextLink {
                if items.count >= Self.listingLimit {
                    truncated = true
                    break
                }
                guard value.utf8.count <= 4_096, let url = URL(string: value),
                      allowedPageURL(url, matchingPath: first.path) else {
                    throw DriveFailure.invalidResponse
                }
                next = url
            } else {
                next = nil
            }
        }
        return try DrivePage(driveID: driveID, parentID: parentID, items: items,
                             isTruncated: truncated)
    }

    private func json(_ url: URL) async throws -> Data {
        let first = try await response(url, forceRefresh: false, maximumBodyBytes: 4_500_000)
        if first.status == 401 {
            let second = try await response(url, forceRefresh: true, maximumBodyBytes: 4_500_000)
            guard (200...299).contains(second.status) else { throw failure(second) }
            return second.body
        }
        guard (200...299).contains(first.status) else { throw failure(first) }
        return first.body
    }

    private func response(_ url: URL, forceRefresh: Bool,
                          maximumBodyBytes: Int) async throws -> DriveHTTPResponse {
        do { try Task.checkCancellation() }
        catch { throw DriveFailure.cancelled }
        let token: String
        do { token = try await authorization(forceRefresh) }
        catch { throw usesAccountGrant ? DriveFailure.serviceUnavailable(retryAfter: nil) : DriveFailure.reauthenticationRequired }
        guard allowedReadURL(url), Self.isBearer(token) else {
            throw DriveFailure.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let operation = DriveDataOperation(
            request: request,
            protocolClasses: protocolClasses,
            maximumBodyBytes: maximumBodyBytes
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: {
            operation.cancel()
        }
    }

    private func downloadAttempt(_ item: DriveItem, to destination: URL,
                                 forceRefresh: Bool,
                                 progress: @escaping @Sendable (Int64, Int64) -> Void)
        async throws -> DriveHTTPResponse {
        do { try Task.checkCancellation() }
        catch { throw DriveFailure.cancelled }
        let token: String
        do { token = try await authorization(forceRefresh) }
        catch { throw usesAccountGrant ? DriveFailure.serviceUnavailable(retryAfter: nil) : DriveFailure.reauthenticationRequired }
        guard Self.isBearer(token), let webDavURL = item.webDavURL, allowedReadURL(webDavURL) else {
            throw DriveFailure.invalidRequest
        }
        var request = URLRequest(url: webDavURL)
        request.httpMethod = "GET"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(item.etag, forHTTPHeaderField: "If-Match")
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let operation = DriveDownloadOperation(
            request: request,
            destination: destination,
            protocolClasses: protocolClasses,
            maximumBodyBytes: item.size,
            progress: progress
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: {
            operation.cancel()
        }
    }

    private func validateDownload(_ response: DriveHTTPResponse, item: DriveItem,
                                  destination: URL) throws {
        guard (200...299).contains(response.status) else {
            try? FileManager.default.removeItem(at: destination)
            throw failure(response)
        }
        let values = try destination.resourceValues(forKeys: [.fileSizeKey])
        guard Int64(values.fileSize ?? -1) == item.size,
              Self.header("etag", in: response.headers) == item.etag else {
            try? FileManager.default.removeItem(at: destination)
            throw DriveFailure.invalidResponse
        }
    }

    private func failure(_ response: DriveHTTPResponse) -> DriveFailure {
        let raw = Self.header("x-atum-drive-denial", in: response.headers)
        let reason = raw.flatMap(DriveDenialReason.init(rawValue:)) ?? .unknown
        switch response.status {
        case 401:
            return usesAccountGrant ? .serviceUnavailable(retryAfter: nil) : .reauthenticationRequired
        case 403:
            return .denied(reason)
        case 404:
            return .notFound
        case 409, 412:
            return .changed
        case 429:
            return .rateLimited(retryAfter: Self.retryAfter(response.headers))
        case 507:
            return .serverQuota
        case 503 where reason == .provisioning:
            return .provisioning(retryAfter: Self.retryAfter(response.headers))
        case 503:
            return .serviceUnavailable(retryAfter: Self.retryAfter(response.headers))
        default:
            return .invalidResponse
        }
    }

    private func endpoint(path: String) throws -> URL {
        guard path.first == "/", !path.contains("?") else { throw DriveFailure.invalidRequest }
        return try endpoint(percentEncodedPath: path)
    }

    private func endpoint(percentEncodedPath: String) throws -> URL {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = percentEncodedPath
        guard let url = components?.url, sameOrigin(url) else { throw DriveFailure.invalidRequest }
        return url
    }

    private func encodedPathComponent(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 1_024 else { throw DriveFailure.invalidRequest }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let result = value.addingPercentEncoding(withAllowedCharacters: allowed),
              !result.isEmpty else { throw DriveFailure.invalidRequest }
        return result
    }

    private func allowedReadURL(_ url: URL) -> Bool {
        guard sameOrigin(url), url.user == nil, url.password == nil, url.fragment == nil else {
            return false
        }
        return url.path.hasPrefix("/graph/v1.0/") || url.path.hasPrefix("/dav/spaces/")
    }

    private func allowedPageURL(_ url: URL, matchingPath path: String) -> Bool {
        guard allowedReadURL(url), url.path == path else { return false }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return (components.queryItems ?? []).allSatisfy {
            ["$skiptoken", "$top"].contains($0.name) && $0.value?.isEmpty == false
        }
    }

    private func sameOrigin(_ url: URL) -> Bool {
        url.scheme == serverURL.scheme && url.host == serverURL.host && url.port == serverURL.port
    }

    private static func validateServer(_ url: URL, permitsTestHost: Bool) throws {
        guard url.scheme == "https", url.port == nil, url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil,
              url.host == "drive.atumplatform.com"
                || (permitsTestHost && url.host == "drive.atum.test") else {
            throw DriveFailure.invalidAccount
        }
    }

    private static func isBearer(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8_192 && !value.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func retryAfter(_ headers: [String: String]) -> Int? {
        guard let value = header("retry-after", in: headers),
              let seconds = Int(value), (1...300).contains(seconds) else { return nil }
        return seconds
    }
}

private struct GraphCollection<Value: Decodable>: Decodable {
    let value: [Value]
    let nextLink: String?

    private enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

private struct GraphDrive: Decodable {
    let id: String
    let name: String
    let driveType: String
}

/// One element of `/me/drives`, kept only when it is a well-formed drive. The
/// credential scan still covers the whole raw collection before decoding.
private struct ListedDrive: Decodable {
    let drive: GraphDrive?

    init(from decoder: any Decoder) throws {
        drive = try? GraphDrive(from: decoder)
    }
}

private struct GraphItem: Decodable {
    struct Folder: Decodable { let childCount: Int? }
    struct File: Decodable { let mimeType: String? }
    struct ParentReference: Decodable {
        let driveId: String?
        let id: String?
    }

    let id: String
    let name: String
    let eTag: String
    let size: Int64
    let webDavURL: URL?
    let lastModifiedDateTime: String?
    let folder: Folder?
    let file: File?
    let parentReference: ParentReference?

    private enum CodingKeys: String, CodingKey {
        case id, name, eTag, size, lastModifiedDateTime, folder, file, parentReference
        case webDavURL = "webDavUrl"
    }

    func item() throws -> DriveItem {
        guard (folder == nil) != (file == nil) else { throw DriveFailure.invalidResponse }
        // A file is read through its WebDAV address; only folders may lack one.
        guard file == nil || webDavURL != nil else { throw DriveFailure.invalidResponse }
        let modifiedAt: Date?
        if let lastModifiedDateTime {
            modifiedAt = Self.date(lastModifiedDateTime)
        } else {
            modifiedAt = nil
        }
        return try DriveItem(
            id: id,
            name: name,
            kind: folder == nil ? .file : .folder,
            etag: eTag,
            size: size,
            webDavURL: webDavURL,
            modifiedAt: modifiedAt,
            mimeType: file?.mimeType,
            parentDriveID: parentReference?.driveId,
            parentID: parentReference?.id
        )
    }

    private static func date(_ value: String) -> Date? {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = precise.date(from: value) { return parsed }
        if let dot = value.firstIndex(of: ".") {
            let suffix = value[dot...]
            if let zone = suffix.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
                let fraction = value[value.index(after: dot)..<zone]
                if fraction.count > 6 {
                    let shortened = String(value[..<value.index(after: dot)])
                        + String(fraction.prefix(6)) + String(value[zone...])
                    if let parsed = precise.date(from: shortened) { return parsed }
                }
            }
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

private struct DriveHTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
}

private class DriveOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let lock = NSLock()
    let request: URLRequest
    let protocolClasses: [URLProtocol.Type]?
    var session: URLSession?
    var task: URLSessionTask?
    var continuation: CheckedContinuation<DriveHTTPResponse, any Error>?
    var status: Int?
    var headers = [String: String]()
    var accepted = false
    var finished = false

    init(request: URLRequest, protocolClasses: [URLProtocol.Type]?) {
        self.request = request
        self.protocolClasses = protocolClasses
    }

    func start(_ continuation: CheckedContinuation<DriveHTTPResponse, any Error>) {
        let newTask: URLSessionTask? = lock.withLock {
            guard !finished else { return nil }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            configuration.waitsForConnectivity = false
            if let protocolClasses { configuration.protocolClasses = protocolClasses }
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self,
                                     delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: request)
            self.task = task
            return task
        }
        guard let newTask else {
            continuation.resume(throwing: DriveFailure.cancelled)
            return
        }
        newTask.resume()
    }

    func cancel() { finish(.failure(DriveFailure.cancelled)) }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(DriveFailure.redirectRefused))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              http.url == request.url else {
            completionHandler(.cancel)
            finish(.failure(DriveFailure.invalidResponse))
            return
        }
        do {
            try prepareForResponse(status: http.statusCode)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
            return
        }
        lock.withLock {
            status = http.statusCode
            headers = http.allHeaderFields.reduce(into: [:]) { result, entry in
                guard let key = entry.key as? String else { return }
                result[key] = String(describing: entry.value)
            }
            accepted = true
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        consume(data)
    }

    func consume(_ data: Data) {}
    func prepareForResponse(status: Int) throws {}

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(Self.transportFailure(error)))
        } else {
            complete()
        }
    }

    private static func transportFailure(_ error: any Error) -> DriveFailure {
        let code = (error as? URLError)?.code
            ?? URLError.Code(rawValue: (error as NSError).code)
        switch code {
        case .cancelled: return .cancelled
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return .offline
        case .timedOut: return .timedOut
        case .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return .secureConnectionFailed
        default:
            return .serviceUnavailable(retryAfter: nil)
        }
    }

    func complete() {
        let response: DriveHTTPResponse? = lock.withLock {
            guard accepted, let status else { return nil }
            return DriveHTTPResponse(status: status, headers: headers, body: Data())
        }
        finish(response.map(Result.success) ?? .failure(DriveFailure.invalidResponse))
    }

    func finish(_ result: Result<DriveHTTPResponse, any Error>) {
        let state: (CheckedContinuation<DriveHTTPResponse, any Error>?, URLSessionTask?, URLSession?) = lock.withLock {
            guard !finished else { return (nil, nil, nil) }
            finished = true
            let value = (continuation, task, session)
            continuation = nil
            task = nil
            session = nil
            return value
        }
        state.1?.cancel()
        state.2?.invalidateAndCancel()
        state.0?.resume(with: result)
    }
}

private final class DriveDataOperation: DriveOperation, @unchecked Sendable {
    private let maximumBodyBytes: Int
    private var bytes = Data()

    init(request: URLRequest, protocolClasses: [URLProtocol.Type]?, maximumBodyBytes: Int) {
        self.maximumBodyBytes = maximumBodyBytes
        super.init(request: request, protocolClasses: protocolClasses)
    }

    override func consume(_ data: Data) {
        let tooLarge = lock.withLock { () -> Bool in
            guard !finished else { return false }
            guard bytes.count <= maximumBodyBytes - data.count else { return true }
            bytes.append(data)
            return false
        }
        if tooLarge { finish(.failure(DriveFailure.responseTooLarge)) }
    }

    override func complete() {
        let response: DriveHTTPResponse? = lock.withLock {
            guard accepted, let status else { return nil }
            return DriveHTTPResponse(status: status, headers: headers, body: bytes)
        }
        finish(response.map(Result.success) ?? .failure(DriveFailure.invalidResponse))
    }
}

private final class DriveDownloadOperation: DriveOperation, @unchecked Sendable {
    private let destination: URL
    private let maximumBodyBytes: Int64
    private let progress: @Sendable (Int64, Int64) -> Void
    private let fileLock = NSLock()
    private var written: Int64 = 0
    private var handle: FileHandle?
    private var streamsBody = false

    init(request: URLRequest, destination: URL, protocolClasses: [URLProtocol.Type]?,
         maximumBodyBytes: Int64,
         progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.maximumBodyBytes = maximumBodyBytes
        self.progress = progress
        super.init(request: request, protocolClasses: protocolClasses)
    }

    override func start(_ continuation: CheckedContinuation<DriveHTTPResponse, any Error>) {
        try? FileManager.default.removeItem(at: destination)
        super.start(continuation)
    }

    override func prepareForResponse(status: Int) throws {
        guard (200...299).contains(status) else {
            try? FileManager.default.removeItem(at: destination)
            fileLock.withLock { streamsBody = false }
            return
        }
        do {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw DriveFailure.storageUnavailable
            }
            var protectedURL = destination
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try protectedURL.setResourceValues(values)
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: destination.path
            )
            #endif
            let opened = try FileHandle(forWritingTo: destination)
            fileLock.withLock {
                handle = opened
                streamsBody = true
                written = 0
            }
            progress(0, maximumBodyBytes)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw DriveFailure.storageUnavailable
        }
    }

    override func consume(_ data: Data) {
        do {
            guard fileLock.withLock({ streamsBody }) else { return }
            let completed: Int64 = try fileLock.withLock {
                guard streamsBody, let handle,
                      written <= maximumBodyBytes - Int64(data.count) else {
                    throw DriveFailure.responseTooLarge
                }
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                return written
            }
            progress(completed, maximumBodyBytes)
        } catch let failure as DriveFailure {
            finish(.failure(failure))
        } catch {
            finish(.failure(DriveFailure.storageUnavailable))
        }
    }

    override func complete() {
        do {
            try closeHandle()
            super.complete()
        } catch {
            finish(.failure(DriveFailure.storageUnavailable))
        }
    }

    override func finish(_ result: Result<DriveHTTPResponse, any Error>) {
        try? closeHandle()
        if case .failure = result { try? FileManager.default.removeItem(at: destination) }
        super.finish(result)
    }

    private func closeHandle() throws {
        try fileLock.withLock {
            streamsBody = false
            if let handle {
                try handle.close()
                self.handle = nil
            }
        }
    }
}
