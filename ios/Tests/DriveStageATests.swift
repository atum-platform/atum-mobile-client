import Foundation
import XCTest
@testable import AtumNativeAPI

final class DriveContractFixtureTests: XCTestCase {
    private var pack: URL {
        get throws {
            try XCTUnwrap(Bundle.module.url(forResource: "mobile-drive-v1", withExtension: nil))
        }
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: pack.appendingPathComponent("fixtures/" + name))
    }

    func testVendoredPackPinsTheFrozenContract() throws {
        let pin = try String(contentsOf: pack.appendingPathComponent("PINNED-SHA256"),
                             encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(pin, DriveContract.digest)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: pack.appendingPathComponent("VENDORED.json"))
            ) as? [String: String]
        )
        XCTAssertEqual(manifest["contract"], DriveContract.id)
        XCTAssertEqual(manifest["digest"], DriveContract.digest)
    }

    func testRegistrationAndAdmissionAcceptOnlyTheFrozenDriveAudience() throws {
        XCTAssertEqual(
            try DriveClientRegistration.decode(fixture("client-registration.json")).clientID,
            MASPublicClients.drive
        )
        XCTAssertThrowsError(
            try DriveClientRegistration.decode(fixture("client-registration-secret.json"))
        )
        XCTAssertThrowsError(
            try DriveClientRegistration.decode(fixture("client-registration-wrong-id.json"))
        )
        XCTAssertEqual(
            try DriveAdmission.decode(fixture("admission-ios-drive.facts.json")).clientID,
            MASPublicClients.drive
        )
        XCTAssertEqual(
            try DriveAdmission.decode(fixture("admission-desktop.facts.json")).clientID,
            "01JDRVCMPNXQ7R8S9T0V2W3X4Y"
        )
        XCTAssertThrowsError(
            try DriveAdmission.decode(fixture("admission-domain.facts.json"))
        )
    }

    func testAccountPageDownloadAndDenialFixturesDecodeFailClosed() throws {
        let account = try DriveAccount.decode(fixture("account-active.response.json"))
        XCTAssertEqual(account.state, .active)
        XCTAssertEqual(account.serverURL.absoluteString, "https://drive.atum.test")
        XCTAssertThrowsError(
            try DriveAccount.decode(fixture("account-subject-leak.response.json"))
        )

        let page = try DrivePage.decodeContract(fixture("page.json"))
        XCTAssertEqual(page.items.map(\.kind), [.file, .folder])
        XCTAssertEqual(page.items.first?.name, "Notes.txt")
        XCTAssertThrowsError(
            try DrivePage.decodeContract(fixture("page-incomplete.json"))
        )

        let download = try DriveDownload.decodeContract(fixture("download.json"))
        XCTAssertEqual(download.etag, "etag-file-1")
        XCTAssertEqual(download.size, 12)

        let denial = try DriveDenial.decodeContract(fixture("denial-provisioning.json"))
        XCTAssertEqual(denial.reason, .provisioning)
        XCTAssertEqual(denial.retryAfter, 10)
        XCTAssertThrowsError(
            try DriveDenial.decodeContract(fixture("denial-provider-detail.json"))
        )
    }
}

@MainActor final class DriveAuthContractTests: XCTestCase {
    func testDriveFlowUsesItsOwnAudienceAndExactlyOpenID() throws {
        let metadata = try MASMetadata.decode(
            Data(#"{"issuer":"https://auth.atumplatform.com/","authorization_endpoint":"https://auth.atumplatform.com/authorize","token_endpoint":"https://auth.atumplatform.com/oauth2/token","jwks_uri":"https://auth.atumplatform.com/oauth2/jwks","revocation_endpoint":"https://auth.atumplatform.com/oauth2/revoke","id_token_signing_alg_values_supported":["RS256"],"code_challenge_methods_supported":["S256"]}"#.utf8),
            expectedIssuer: "https://auth.atumplatform.com/"
        )
        let clients = try MASPublicClients(
            matrix: "01JPHNMXPQ7R8S9T0V2W3X4Y5Z",
            domain: "01JPHNDXPQ7R8S9T0V2W3X4Y5Z"
        )
        let flows = OIDCFlows()
        let flow = try flows.begin(.drive, clients: clients, metadata: metadata)
        let query = try XCTUnwrap(
            URLComponents(url: flow.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems
        )
        let fields = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value) })
        XCTAssertEqual(flow.clientID, MASPublicClients.drive)
        XCTAssertEqual(fields["client_id"]!, MASPublicClients.drive)
        XCTAssertEqual(fields["scope"]!, "openid")
        XCTAssertEqual(fields["redirect_uri"]!, MASPublicClients.callback.absoluteString)
        XCTAssertEqual(fields["code_challenge_method"]!, "S256")
        XCTAssertNotNil(fields["state"]!)
        XCTAssertNotNil(fields["nonce"]!)
        XCTAssertNotNil(fields["code_challenge"]!)
        XCTAssertNotEqual(flow.clientID, clients.matrix)
        XCTAssertNotEqual(flow.clientID, clients.domain)
    }
}

final class DriveCacheTests: XCTestCase {
    private var roots = [URL]()

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func cache(budget: Int64 = 8, capacity: Int64 = 1_000_000,
                       minimumFree: Int64 = 0) throws -> DriveCache {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-drive-cache-test-" + UUID().uuidString, isDirectory: true)
        let root = base.appendingPathComponent("v1/scope", isDirectory: true)
        roots.append(base)
        return try DriveCache(
            root: root,
            configuration: .init(evictableBudgetBytes: budget,
                                 minimumFreeBytes: minimumFree),
            availableCapacity: { capacity }
        )
    }

    private func item(_ suffix: String, size: Int64 = 6, etag: String? = nil) throws -> DriveItem {
        try DriveItem(
            id: "storage-fixture$space-fixture!" + suffix,
            name: "\(suffix).txt",
            kind: .file,
            etag: etag ?? "etag-" + suffix,
            size: size,
            webDavURL: URL(
                string: "https://drive.atum.test/dav/spaces/storage-fixture$space-fixture/\(suffix).txt"
            )!
        )
    }

    private func stage(_ bytes: Data, in cache: DriveCache) async throws -> URL {
        let url = try await cache.prepareDownload(expectedBytes: Int64(bytes.count))
        try bytes.write(to: url)
        return url
    }

    func testLastGoodPageSurvivesAndEvictionNeverRemovesKeptItems() async throws {
        let cache = try cache()
        let first = try item("first")
        let second = try item("second")
        let page = try DrivePage(
            driveID: "storage-fixture$space-fixture",
            parentID: DrivePage.rootParentID,
            items: [first, second]
        )
        try await cache.store(page: page)
        let cachedPage = try await cache.page(parentID: DrivePage.rootParentID)
        XCTAssertEqual(cachedPage, page)

        let firstURL = try await cache.commit(
            stage(Data(repeating: 1, count: 6), in: cache),
            item: first,
            keepOffline: true,
            now: Date(timeIntervalSince1970: 1)
        )
        _ = try await cache.commit(
            stage(Data(repeating: 2, count: 6), in: cache),
            item: second,
            keepOffline: false,
            now: Date(timeIntervalSince1970: 2)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        let firstIsKept = try await cache.isKept(first)
        let cachedFirst = try await cache.cachedURL(for: first)
        let cachedSecond = try await cache.cachedURL(for: second)
        XCTAssertTrue(firstIsKept)
        XCTAssertNotNil(cachedFirst)
        XCTAssertNotNil(cachedSecond)
    }

    func testLRUEvictsOnlyEvictableFilesAndUsesETagKeyedAtomicPaths() async throws {
        let cache = try cache()
        let first = try item("first")
        let second = try item("second")
        let firstURL = try await cache.commit(
            stage(Data(repeating: 1, count: 6), in: cache),
            item: first,
            keepOffline: false,
            now: Date(timeIntervalSince1970: 1)
        )
        let secondURL = try await cache.commit(
            stage(Data(repeating: 2, count: 6), in: cache),
            item: second,
            keepOffline: false,
            now: Date(timeIntervalSince1970: 2)
        )
        XCTAssertNotEqual(firstURL.lastPathComponent, secondURL.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        let evicted = try await cache.cachedURL(for: first)
        XCTAssertNil(evicted)
        XCTAssertEqual(try Data(contentsOf: secondURL), Data(repeating: 2, count: 6))
    }

    func testLowDiskRefusesBeforeCreatingAStagingFile() async throws {
        let cache = try cache(capacity: 10, minimumFree: 8)
        do {
            _ = try await cache.prepareDownload(expectedBytes: 3)
            XCTFail("low disk must refuse the download")
        } catch let failure as DriveFailure {
            XCTAssertEqual(failure, .lowDisk)
        }
    }

    func testAChangedKeptItemRetainsItsLastDownloadedETagUntilReplacement() async throws {
        let cache = try cache()
        let old = try item("versioned", etag: "etag-old")
        let current = try item("versioned", etag: "etag-current")
        let oldURL = try await cache.commit(
            stage(Data(repeating: 4, count: 6), in: cache),
            item: old,
            keepOffline: true
        )
        let keptBeforeUpdate = try await cache.isKept(current)
        let currentURL = try await cache.cachedURL(for: current)
        let retainedURL = try await cache.retainedURL(for: current)
        XCTAssertTrue(keptBeforeUpdate)
        XCTAssertNil(currentURL)
        XCTAssertEqual(retainedURL, oldURL)

        try await cache.setKept(false, for: current)
        let keptAfterRemoval = try await cache.isKept(current)
        XCTAssertFalse(keptAfterRemoval)
    }

    func testWithdrawInvalidatesEveryHandleBeforeDeletion() async throws {
        let cache = try cache()
        let value = try item("kept")
        _ = try await cache.commit(
            stage(Data(repeating: 7, count: 6), in: cache),
            item: value,
            keepOffline: true
        )
        try await cache.withdraw()
        do {
            _ = try await cache.cachedURL(for: value)
            XCTFail("withdrawn account cache must be unreachable")
        } catch let failure as DriveFailure {
            XCTAssertEqual(failure, .storageUnavailable)
        }
    }

    func testCorruptManifestRecoversAndStartupSweepRemovesOrphans() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-drive-recovery-" + UUID().uuidString, isDirectory: true)
        roots.append(base)
        let root = base.appendingPathComponent("v1/scope", isDirectory: true)
        let files = root.appendingPathComponent("files", isDirectory: true)
        let incoming = root.appendingPathComponent("incoming", isDirectory: true)
        let tombstone = base.appendingPathComponent("v1/.withdrawn-old", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tombstone, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("manifest.json"))
        try Data("orphan".utf8).write(to: files.appendingPathComponent("orphan.txt"))
        try Data("partial".utf8).write(to: incoming.appendingPathComponent("partial.download"))

        let cache = try DriveCache(
            root: root,
            configuration: .init(evictableBudgetBytes: 8, minimumFreeBytes: 0),
            availableCapacity: { 1_000_000 }
        )
        let recoveredPage = try await cache.page(parentID: DrivePage.rootParentID)
        XCTAssertNil(recoveredPage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.appendingPathComponent("orphan.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.appendingPathComponent("partial.download").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
    }

    func testPageMetadataPrunesByCountAndTotalItems() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-drive-pages-" + UUID().uuidString, isDirectory: true)
        roots.append(base)
        let cache = try DriveCache(
            root: base.appendingPathComponent("v1/scope", isDirectory: true),
            configuration: .init(evictableBudgetBytes: 8, minimumFreeBytes: 0,
                                 maxPageCount: 2, maxCachedItems: 2),
            availableCapacity: { 1_000_000 }
        )
        for index in 1...3 {
            let page = try DrivePage(
                driveID: "storage-fixture$space-fixture",
                parentID: "parent-\(index)",
                items: [try item("page-\(index)")]
            )
            try await cache.store(page: page, now: Date(timeIntervalSince1970: Double(index)))
        }
        let first = try await cache.page(parentID: "parent-1")
        let second = try await cache.page(parentID: "parent-2")
        let third = try await cache.page(parentID: "parent-3")
        XCTAssertNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotNil(third)
    }
}

@MainActor final class DriveClientTests: XCTestCase {
    override func tearDown() {
        DriveTestProtocol.state.reset()
        super.tearDown()
    }

    private func client() throws -> DriveClient {
        try client(DriveTestAuthorization())
    }

    private func client(_ authorization: DriveTestAuthorization) throws -> DriveClient {
        try DriveClient(
            serverURL: URL(string: "https://drive.atum.test")!,
            testAuthorization: { force in try authorization.token(forceRefresh: force) },
            protocolClasses: [DriveTestProtocol.self]
        )
    }

    func testAccountGrantDrivesReadsAnd401RefreshWithoutBrowserOrDriveGrant() async throws {
        let auth = DriveTestAuthorization()
        let domain = NativeDomainClient(testAuthorization: { force in try auth.token(forceRefresh: force) },
                                        protocolClasses: [DriveTestProtocol.self])
        let drive = try DriveClient(serverURL: URL(string: "https://drive.atum.test")!,
                                    domainClient: domain, protocolClasses: [DriveTestProtocol.self])
        DriveTestProtocol.state.handler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer first-token" {
                return .init(status: 401)
            }
            return .json(#"{"value":[{"id":"personal-space","name":"My files","driveType":"personal"}]}"#)
        }
        _ = try await drive.personalDrive()
        XCTAssertEqual(auth.forces, [false, true])
        XCTAssertEqual(DriveTestProtocol.state.requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer first-token", "Bearer refreshed-token"])
    }

    func testAccountGrantFailureUsesAccountRecoveryAndNeverDriveSignIn() async throws {
        var recovery = MobileDomainRecoveryState.available
        let domain = NativeDomainClient(testAuthorization: { _ in throw OIDCGrantFailure.reauthenticationRequired },
                                        protocolClasses: [DriveTestProtocol.self],
                                        onAuthenticationFailure: { recovery = MobileDomainRecoveryPolicy.state(for: $0) })
        let drive = try DriveClient(serverURL: URL(string: "https://drive.atum.test")!,
                                    domainClient: domain, protocolClasses: [DriveTestProtocol.self])
        do {
            _ = try await drive.personalDrive()
            XCTFail("expired account grant must fail")
        } catch {
            XCTAssertEqual(error as? DriveFailure, .serviceUnavailable(retryAfter: nil))
        }
        XCTAssertEqual(recovery, .reauthenticationRequired)
        XCTAssertTrue(DriveTestProtocol.state.requests.isEmpty)
    }

    func testIngress401WithHealthyAccountDoesNotOfferDriveSignIn() async throws {
        let domain = NativeDomainClient(testAuthorization: { _ in "account-token" },
                                        protocolClasses: [DriveTestProtocol.self])
        let drive = try DriveClient(serverURL: URL(string: "https://drive.atum.test")!,
                                    domainClient: domain, protocolClasses: [DriveTestProtocol.self])
        DriveTestProtocol.state.handler = { _ in .init(status: 401) }
        do {
            _ = try await drive.personalDrive()
            XCTFail("ingress denial must fail")
        } catch {
            XCTAssertEqual(error as? DriveFailure, .serviceUnavailable(retryAfter: nil))
        }
        XCTAssertEqual(DriveTestProtocol.state.requests.count, 2)
    }

    private func graphFixture(_ name: String) throws -> String {
        let base = try XCTUnwrap(Bundle.module.url(
            forResource: "opencloud-drive-graph", withExtension: nil
        ))
        return try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8)
    }

    private func body(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 256)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            result.append(buffer, count: count)
        }
        return result
    }

    func testRootListingFollowsOnlySamePathPaginationAndMapsFileFacts() async throws {
        let drives = try graphFixture("me-drives.response.json")
        let root = try graphFixture("root-children.response.json")
        DriveTestProtocol.state.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer first-token")
            switch (request.url?.path, request.url?.query) {
            case ("/graph/v1.0/me/drives", nil):
                return .json(drives)
            case ("/graph/v1.0/me/drive/root/children", nil):
                return .json(root)
            default:
                return .init(status: 404)
            }
        }

        let page = try await client().rootPage()
        XCTAssertEqual(page.parentID, DrivePage.rootParentID)
        XCTAssertEqual(page.items.map(\.name), ["Notes.txt", "Projects"])
        XCTAssertEqual(page.items.map(\.kind), [.file, .folder])
        XCTAssertNotNil(page.items[0].modifiedAt, "nanosecond timestamp parses")
        XCTAssertNil(page.items[1].modifiedAt, "one bad date does not fail the folder")
        XCTAssertEqual(page.items[0].parentID, "storage-fixture$space-fixture")
        XCTAssertEqual(DriveTestProtocol.state.requests.count, 2)
    }

    func testFolderChildrenAcceptParentReferenceAndNanosecondOffset() async throws {
        let folder = try graphFixture("folder-children.response.json")
        DriveTestProtocol.state.handler = { request in
            XCTAssertEqual(request.url?.path,
                           "/graph/v1.0/drives/storage-fixture$space-fixture/items/storage-fixture$space-fixture!folder-1/children")
            return .json(folder)
        }
        let page = try await client().children(
            driveID: "storage-fixture$space-fixture",
            parentID: "storage-fixture$space-fixture!folder-1"
        )
        XCTAssertEqual(page.items.first?.parentDriveID, "storage-fixture$space-fixture")
        XCTAssertEqual(page.items.first?.parentID, "storage-fixture$space-fixture!folder-1")
        XCTAssertNotNil(page.items.first?.modifiedAt)
    }

    func testOversizedFolderTruncatesWithAFlagInsteadOfFailing() async throws {
        let drives = try graphFixture("me-drives.response.json")
        let values: [[String: Any]] = (0...500).map { index in
            ["id": "storage-fixture$space-fixture!item-\(index)",
             "name": "item-\(index).txt", "eTag": "etag-\(index)", "size": 1,
             "webDavUrl": "https://drive.atum.test/dav/spaces/storage-fixture$space-fixture/item-\(index).txt",
             "file": ["mimeType": "text/plain"]]
        }
        let root = String(decoding: try JSONSerialization.data(withJSONObject: ["value": values]),
                          as: UTF8.self)
        DriveTestProtocol.state.handler = { request in
            request.url?.path == "/graph/v1.0/me/drives" ? .json(drives) : .json(root)
        }
        let page = try await client().rootPage()
        XCTAssertEqual(page.items.count, 500)
        XCTAssertTrue(page.isTruncated)
    }

    /// OpenCloud's `/me/drives` lists every visible space. Spaces this client
    /// does not read (the virtual Shares space, mount points) may lack fields a
    /// drive needs; they are skipped, and the one well-formed personal drive wins.
    func testPersonalDriveSkipsSpacesItDoesNotReadAndKeepsExactlyOnePersonal() async throws {
        let drives = #"""
        {"@odata.context":"https://drive.atum.test/graph/v1.0/$metadata#drives","value":[
          {"driveAlias":"virtual/shares","driveType":"virtual","id":"storage-fixture$shares-fixture",
           "root":{"id":"storage-fixture$shares-fixture","webDavUrl":"https://drive.atum.test/dav/spaces/storage-fixture$shares-fixture"},
           "webUrl":"https://drive.atum.test/f/storage-fixture$shares-fixture"},
          {"driveType":"mountpoint","id":"storage-fixture$mount-fixture","name":42,
           "root":{"remoteItem":{"driveAlias":"project/team","id":"remote-fixture"}}},
          {"driveAlias":"personal/fixture-owner","driveType":"personal","id":"storage-fixture$space-fixture",
           "name":"Fixture owner","owner":{"user":{"displayName":"Fixture owner","id":"fixture-owner-id"}},
           "quota":{"remaining":999853685,"state":"normal","total":1000000000,"used":146315},
           "root":{"eTag":"\"910af0061161c42d8d1224df6c4a2527\"","id":"storage-fixture$space-fixture",
                   "webDavUrl":"https://drive.atum.test/dav/spaces/storage-fixture$space-fixture"}}
        ]}
        """#
        DriveTestProtocol.state.handler = { _ in .json(drives) }
        let drive = try await client().personalDrive()
        XCTAssertEqual(drive.id, "storage-fixture$space-fixture")
    }

    /// The owner's personal root on production (2026-11-04): OpenCloud lists its
    /// folders without `webDavUrl`. Folders are browsed by id, so they list; a
    /// file still needs its WebDAV address to be downloaded.
    func testRootListsFoldersWithoutWebDavURLButRefusesSuchAFile() async throws {
        let drives = try graphFixture("me-drives.response.json")
        let folders = #"""
        {"value":[
          {"eTag":"\"a1\"","folder":{"childCount":3},"id":"storage-fixture$space-fixture!folder-a",
           "lastModifiedDateTime":"2026-11-02T08:12:13.455527853Z","name":"Folder A",
           "parentReference":{"driveId":"storage-fixture$space-fixture","id":"storage-fixture$space-fixture"},"size":1200},
          {"eTag":"\"b2\"","folder":{"childCount":0},"id":"storage-fixture$space-fixture!folder-b",
           "name":"Folder B","size":0}
        ]}
        """#
        let fileWithoutAddress = #"""
        {"value":[{"eTag":"\"c3\"","file":{"mimeType":"text/plain"},"id":"storage-fixture$space-fixture!file-c",
                   "name":"c.txt","size":5}]}
        """#
        DriveTestProtocol.state.handler = { request in
            request.url?.path == "/graph/v1.0/me/drives" ? .json(drives) : .json(folders)
        }
        let page = try await client().rootPage()
        XCTAssertEqual(page.items.map(\.name), ["Folder A", "Folder B"])
        XCTAssertEqual(page.items.map(\.kind), [.folder, .folder])
        XCTAssertTrue(page.items.allSatisfy { $0.webDavURL == nil })

        DriveTestProtocol.state.handler = { request in
            request.url?.path == "/graph/v1.0/me/drives" ? .json(drives) : .json(fileWithoutAddress)
        }
        do {
            _ = try await client().rootPage()
            XCTFail("a file without a WebDAV address must be refused")
        } catch let failure as DriveFailure {
            XCTAssertEqual(failure, .invalidResponse)
        }
    }

    func testPersonalDriveStillRefusesTwoPersonalDrivesAndNestedCredentials() async throws {
        let personal = #"{"driveType":"personal","id":"storage-fixture$space-fixture","name":"A"}"#
        let other = #"{"driveType":"personal","id":"storage-fixture$space-other","name":"B"}"#
        let shares = #"{"driveType":"virtual","id":"storage-fixture$shares-fixture","root":{"token":"must-refuse"}}"#
        for body in [#"{"value":[\#(personal),\#(other)]}"#,
                     #"{"value":[\#(shares),\#(personal)]}"#] {
            DriveTestProtocol.state.handler = { _ in .json(body) }
            do {
                _ = try await client().personalDrive()
                XCTFail("must be refused: \(body.prefix(60))")
            } catch let failure as DriveFailure {
                XCTAssertEqual(failure, .invalidResponse)
            }
        }
    }

    func testRawGraphRejectsCredentialsButNotOwnerMetadata() async throws {
        DriveTestProtocol.state.handler = { _ in
            .json(#"{"value":[{"id":"storage-fixture$space-fixture","name":"Personal","driveType":"personal","owner":{"user":{"id":"ordinary-owner-id"}},"accessToken":"must-refuse"}]}"#)
        }
        do {
            _ = try await client().personalDrive()
            XCTFail("credential-bearing Graph metadata must be refused")
        } catch let failure as DriveFailure {
            XCTAssertEqual(failure, .invalidResponse)
        }
    }

    func testA401RefreshesExactlyOnceAndAuthorityDenialStaysAuthoritative() async throws {
        let authorization = DriveTestAuthorization()
        DriveTestProtocol.state.handler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer first-token" {
                return .init(status: 401, headers: ["X-Atum-Drive-Denial": "expired"])
            }
            return .init(status: 403, headers: ["X-Atum-Drive-Denial": "not_allowed"])
        }
        do {
            _ = try await client(authorization).personalDrive()
            XCTFail("the authoritative denial must not become an empty drive")
        } catch let failure as DriveFailure {
            XCTAssertEqual(failure, .denied(.notAllowed))
        }
        XCTAssertEqual(authorization.forces, [false, true])
        XCTAssertEqual(DriveTestProtocol.state.requests.count, 2)
    }

    func testTransportAndProviderFailuresStayDistinct() async throws {
        let cases: [(DriveTestProtocol.Reply, DriveFailure)] = [
            (.init(error: URLError(.notConnectedToInternet)), .offline),
            (.init(error: URLError(.timedOut)), .timedOut),
            (.init(error: URLError(.secureConnectionFailed)), .secureConnectionFailed),
            (.init(status: 503, headers: ["Retry-After": "7"]),
             .serviceUnavailable(retryAfter: 7)),
            (.init(status: 429, headers: ["Retry-After": "15"]),
             .rateLimited(retryAfter: 15)),
        ]
        for (reply, expected) in cases {
            DriveTestProtocol.state.reset()
            DriveTestProtocol.state.handler = { _ in reply }
            do {
                _ = try await client().personalDrive()
                XCTFail("failure \(expected) must remain distinct")
            } catch let failure as DriveFailure {
                XCTAssertEqual(failure, expected)
            }
        }
    }

    func testDownloadRequiresTheSelectedETagAndExactLength() async throws {
        let bytes = Data("hello".utf8)
        let progress = DriveProgressRecorder()
        DriveTestProtocol.state.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "etag-one")
            return .init(status: 200, headers: ["ETag": "etag-one"], chunks: [bytes])
        }
        let item = try DriveItem(
            id: "storage-fixture$space-fixture!one",
            name: "Notes.txt",
            kind: .file,
            etag: "etag-one",
            size: 5,
            webDavURL: URL(
                string: "https://drive.atum.test/dav/spaces/storage-fixture$space-fixture/Notes.txt"
            )!
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-drive-download-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await client().download(item, to: destination) { completed, total in
            progress.record(completed: completed, total: total)
        }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(progress.values.last?.0, 5)
        XCTAssertEqual(progress.values.last?.1, 5)
    }

    func testDownloadNeverWritesErrorBodiesAndMapsStatusBeforeStreaming() async throws {
        let item = try DriveItem(
            id: "storage-fixture$space-fixture!one", name: "Notes.txt", kind: .file,
            etag: "etag-one", size: 5,
            webDavURL: URL(string: "https://drive.atum.test/dav/spaces/storage-fixture$space-fixture/Notes.txt")!
        )
        for (status, expected) in [(412, DriveFailure.changed),
                                   (403, DriveFailure.denied(.notAllowed)),
                                   (404, DriveFailure.notFound)] {
            DriveTestProtocol.state.reset()
            DriveTestProtocol.state.handler = { _ in
                .init(status: status,
                      headers: ["X-Atum-Drive-Denial": "not_allowed"],
                      chunks: [Data("provider error body".utf8)])
            }
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("atum-drive-error-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: destination) }
            do {
                try await client().download(item, to: destination)
                XCTFail("status \(status) must fail")
            } catch let failure as DriveFailure {
                XCTAssertEqual(failure, expected)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testA401ErrorBodyIsDiscardedBeforeTheRefreshedDownload() async throws {
        let authorization = DriveTestAuthorization()
        let bytes = Data("hello".utf8)
        DriveTestProtocol.state.handler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer first-token" {
                return .init(status: 401, headers: ["X-Atum-Drive-Denial": "expired"],
                             chunks: [Data("must not reach the file".utf8)])
            }
            return .init(status: 200, headers: ["ETag": "etag-one"], chunks: [bytes])
        }
        let item = try DriveItem(
            id: "storage-fixture$space-fixture!one", name: "Notes.txt", kind: .file,
            etag: "etag-one", size: 5,
            webDavURL: URL(string: "https://drive.atum.test/dav/spaces/storage-fixture$space-fixture/Notes.txt")!
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-drive-refresh-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await client(authorization).download(item, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(authorization.forces, [false, true])
    }

    func testDownloadCancellationClosesAndDeletesTheStagingFile() async throws {
        DriveTestProtocol.state.handler = { _ in .init(held: true) }
        let item = try DriveItem(
            id: "storage-fixture$space-fixture!one", name: "Notes.txt", kind: .file,
            etag: "etag-one", size: 5,
            webDavURL: URL(string: "https://drive.atum.test/dav/spaces/storage-fixture$space-fixture/Notes.txt")!
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-drive-cancel-" + UUID().uuidString)
        let task = Task { try await client().download(item, to: destination) }
        while DriveTestProtocol.state.requests.isEmpty { await Task.yield() }
        task.cancel()
        do {
            try await task.value
            XCTFail("cancelled transfer must not succeed")
        } catch let failure as DriveFailure {
            XCTAssertEqual(failure, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRedirectIsRefused() async throws {
        DriveTestProtocol.state.handler = { _ in
            .init(redirect: URL(string: "https://drive.atum.test/dav/spaces/other/file")!)
        }
        do {
            _ = try await client().personalDrive()
            XCTFail("redirect must be refused")
        } catch let failure as DriveFailure {
            XCTAssertEqual(failure, .redirectRefused)
        }
    }

    func testDomainBootstrapPostsOnlyTheEmptyObjectWithDomainAuthority() async throws {
        DriveTestProtocol.state.handler = { request in
            XCTAssertEqual(request.url, DriveContract.accountURL)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(self.body(request), Data("{}".utf8))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer domain-token")
            return .json(#"{"state":"active","serverUrl":"https://drive.atum.test"}"#)
        }
        let domain = NativeDomainClient(
            testAuthorization: { _ in "domain-token" },
            protocolClasses: [DriveTestProtocol.self]
        )
        let account = try await domain.driveAccount()
        XCTAssertEqual(account.state, .active)
        XCTAssertEqual(DriveTestProtocol.state.requests.count, 1)
    }
}

@MainActor private final class DriveTestAuthorization {
    private(set) var forces = [Bool]()

    func token(forceRefresh: Bool) throws -> String {
        forces.append(forceRefresh)
        return forceRefresh ? "refreshed-token" : "first-token"
    }
}

private final class DriveProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = [(Int64, Int64)]()
    var values: [(Int64, Int64)] { lock.withLock { recorded } }
    func record(completed: Int64, total: Int64) {
        lock.withLock { recorded.append((completed, total)) }
    }
}

private final class DriveTestProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: @unchecked Sendable {
        var status = 200
        var headers = [String: String]()
        var chunks = [Data]()
        var error: Error?
        var redirect: URL?
        var held = false

        static func json(_ value: String) -> Self {
            .init(headers: ["Content-Type": "application/json"],
                  chunks: [Data(value.utf8)])
        }
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var block: ((URLRequest) -> Reply)?
        private var observed = [URLRequest]()

        var handler: ((URLRequest) -> Reply)? {
            get { lock.withLock { block } }
            set { lock.withLock { block = newValue } }
        }

        var requests: [URLRequest] { lock.withLock { observed } }

        func receive(_ request: URLRequest) -> Reply {
            let action = lock.withLock {
                observed.append(request)
                return block
            }
            return action?(request) ?? .init(error: URLError(.unsupportedURL))
        }

        func reset() {
            lock.withLock {
                block = nil
                observed = []
            }
        }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool {
        ["drive.atum.test", "api.atumplatform.com"].contains(request.url?.host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.state.receive(request)
        if reply.held { return }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        if let target = reply.redirect {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 302, httpVersion: nil,
                headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: target),
                redirectResponse: response
            )
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status,
            httpVersion: nil, headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
