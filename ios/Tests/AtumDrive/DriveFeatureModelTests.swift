import Foundation
import XCTest
@testable import AtumDrive
@testable import AtumNativeAPI

@MainActor @available(macOS 14.0, *)
final class DriveFeatureModelTests: XCTestCase {
    private var roots = [URL]()

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots = []
        super.tearDown()
    }

    private func cache() throws -> DriveCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-drive-model-" + UUID().uuidString, isDirectory: true)
        roots.append(root)
        return try DriveCache(
            root: root.appendingPathComponent("v1/scope", isDirectory: true),
            configuration: .init(evictableBudgetBytes: 1_024, minimumFreeBytes: 0),
            availableCapacity: { 1_000_000 }
        )
    }

    private func item(name: String = "Notes.txt", etag: String = "etag-one",
                      mimeType: String = "text/plain") throws -> DriveItem {
        try DriveItem(
            id: "storage-fixture$space-fixture!file-1", name: name, kind: .file,
            etag: etag, size: 5,
            webDavURL: URL(string: "https://drive.atum.test/dav/spaces/storage-fixture$space-fixture/\(name)")!,
            mimeType: mimeType,
            parentDriveID: "storage-fixture$space-fixture",
            parentID: DrivePage.rootParentID
        )
    }

    private func page(items: [DriveItem]) throws -> DrivePage {
        try DrivePage(driveID: "storage-fixture$space-fixture",
                      parentID: DrivePage.rootParentID, items: items)
    }

    private func stage(_ data: Data, cache: DriveCache) async throws -> URL {
        let url = try await cache.prepareDownload(expectedBytes: Int64(data.count))
        try data.write(to: url)
        return url
    }

    func testColdOfflineStartPaintsLastGoodAndOpensKeptFile() async throws {
        let cache = try cache()
        let item = try item()
        try await cache.store(page: page(items: [item]))
        _ = try await cache.commit(stage(Data("hello".utf8), cache: cache),
                                   item: item, keepOffline: true)
        let calls = MainActorCounter()
        let model = DriveFeatureModel()
        model.configure(accountID: "@owner:atum.test", resume: {
            calls.value += 1
            return LiveDriveAccess(cache: cache, state: .offline)
        }, connect: {
            XCTFail("cold offline start must not launch Connect")
            return LiveDriveAccess(cache: cache, state: .offline)
        })

        await model.start()
        await model.start()
        XCTAssertEqual(calls.value, 1, "tab reappearance reuses one access object")
        XCTAssertEqual(model.connection, .offline)
        XCTAssertEqual(model.directory(parentID: DrivePage.rootParentID).items, [item])
        XCTAssertEqual(model.directory(parentID: DrivePage.rootParentID).condition, .stale)

        await model.open(item)
        XCTAssertEqual(model.preview?.url.lastPathComponent.split(separator: ".").last, "txt")
        XCTAssertTrue(model.preview?.isStale == true)
    }

    func testServiceFailureAfterCacheCreationStillPublishesLastGood() async throws {
        let cache = try cache()
        let item = try item()
        try await cache.store(page: page(items: [item]))
        let model = DriveFeatureModel()
        model.configure(accountID: "owner", resume: {
            LiveDriveAccess(cache: cache, state: .serviceUnavailable)
        }, connect: { LiveDriveAccess(cache: cache, state: .serviceUnavailable) })
        await model.start()
        XCTAssertEqual(model.connection, .serviceUnavailable)
        XCTAssertEqual(model.directory(parentID: DrivePage.rootParentID).items, [item])
        XCTAssertEqual(model.directory(parentID: DrivePage.rootParentID).condition, .stale)
    }

    func testActiveStartIsIdempotentAndCallsTheServerOnce() async throws {
        let cache = try cache()
        let reader = FakeDriveReader(rootResults: [.success(try page(items: [try item()]))])
        let calls = MainActorCounter()
        let model = DriveFeatureModel()
        model.configure(accountID: "owner", resume: {
            calls.value += 1
            return LiveDriveAccess(cache: cache, state: .active(reader))
        }, connect: { LiveDriveAccess(cache: cache, state: .active(reader)) })
        await model.start()
        await model.start()
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(reader.rootCalls, 1)
        XCTAssertEqual(model.connection, .ready)
    }

    func testConcurrentStartJoinsOneResumeAndOneClientLoad() async throws {
        let cache = try cache()
        let reader = FakeDriveReader(rootResults: [.success(try page(items: [try item()]))])
        let gate = AsyncGate()
        let calls = MainActorCounter()
        let model = DriveFeatureModel()
        model.configure(accountID: "owner", resume: {
            calls.value += 1
            await gate.suspend()
            return LiveDriveAccess(cache: cache, state: .active(reader))
        }, connect: { LiveDriveAccess(cache: cache, state: .active(reader)) })
        let first = Task { await model.start() }
        while !(await gate.hasWaiter) { await Task.yield() }
        let second = Task { await model.start() }
        await gate.open()
        await first.value
        await second.value
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(reader.rootCalls, 1)
    }

    func testSuspendedResumeCannotPublishAfterWithdraw() async throws {
        let cache = try cache()
        let gate = AsyncGate()
        let model = DriveFeatureModel()
        model.configure(accountID: "owner", resume: {
            await gate.suspend()
            return LiveDriveAccess(cache: cache, state: .offline)
        }, connect: { LiveDriveAccess(cache: cache, state: .offline) })
        let start = Task { await model.start() }
        while !(await gate.hasWaiter) { await Task.yield() }
        await model.withdraw(reason: .forcedSessionEnd)
        await gate.open()
        await start.value
        XCTAssertEqual(model.connection, .idle)
        XCTAssertTrue(model.directories.isEmpty)
        XCTAssertEqual(model.lastExitReason, .forcedSessionEnd)
    }

    func testEmptyConnectionStatesNeverFlashConnectForAnExistingSession() async throws {
        let cases: [(LiveDriveAccessState, DriveConnectionState, DriveDirectoryCondition)] = [
            (.provisioning, .provisioning, .loading),
            (.reauthenticationRequired, .reauthenticationRequired, .needsConnection),
            (.offline, .offline, .offline),
            (.serviceUnavailable, .serviceUnavailable, .failed),
            (.denied, .denied, .denied),
            (.storageUnavailable, .storageUnavailable, .failed),
        ]
        for (accessState, connection, condition) in cases {
            let cache = try cache()
            let model = DriveFeatureModel()
            model.configure(accountID: UUID().uuidString, resume: {
                LiveDriveAccess(cache: cache, state: accessState)
            }, connect: { LiveDriveAccess(cache: cache, state: accessState) })
            await model.start()
            XCTAssertEqual(model.connection, connection)
            XCTAssertEqual(model.directory(parentID: DrivePage.rootParentID).condition, condition)
            XCTAssertNotEqual(model.connection, .disconnected)
            XCTAssertNotEqual(
                DrivePresentationPolicy.emptyState(
                    connection: model.connection,
                    directory: model.directory(parentID: DrivePage.rootParentID).condition
                ),
                .connect,
                "an existing session never renders the Connect empty state"
            )
        }
    }

    func testConnectionStatesMapToDistinctRenderedCopyKeys() {
        XCTAssertEqual(DrivePresentationPolicy.connectionCopy(
            connection: .offline, hasItems: false, directory: .offline), .offline)
        XCTAssertEqual(DrivePresentationPolicy.connectionCopy(
            connection: .offline, hasItems: true, directory: .stale), .stale)
        XCTAssertEqual(DrivePresentationPolicy.connectionCopy(
            connection: .reauthenticationRequired, hasItems: true, directory: .stale),
                       .signInAgain)
        for state in [DriveConnectionState.serviceUnavailable, .rateLimited, .timedOut,
                      .secureConnectionFailed, .storageUnavailable] {
            XCTAssertEqual(DrivePresentationPolicy.connectionCopy(
                connection: state, hasItems: false, directory: .failed), .unavailable)
        }
        if case .serviceUnavailable = DriveAccessFailurePolicy.state(for: .storageUnavailable) {
            // Expected: a locked Keychain is retryable and never asks the person to sign in.
        } else {
            XCTFail("storage-unavailable OIDC custody must stay retryable")
        }
        if case .reauthenticationRequired = DriveAccessFailurePolicy.state(for: .reauthenticationRequired) {
            // Expected.
        } else {
            XCTFail("a refused grant still requires sign-in")
        }
    }

    func testDownloadReauthenticationBecomesSignInStateWithoutGenericAlert() async throws {
        let cache = try cache()
        let item = try item()
        let reader = FakeDriveReader(rootResults: [.success(try page(items: [item]))])
        reader.download = { _, _, _ in throw DriveFailure.reauthenticationRequired }
        let model = DriveFeatureModel()
        model.configure(accountID: "owner", resume: {
            LiveDriveAccess(cache: cache, state: .active(reader))
        }, connect: { LiveDriveAccess(cache: cache, state: .active(reader)) })
        await model.start()
        await model.open(item)
        XCTAssertEqual(model.connection, .reauthenticationRequired)
        XCTAssertNil(model.notice)
    }

    func testDownload404RelistsTheParent() async throws {
        let cache = try cache()
        let item = try item()
        let reader = FakeDriveReader(rootResults: [
            .success(try page(items: [item])), .success(try page(items: [])),
        ])
        reader.download = { _, _, _ in throw DriveFailure.notFound }
        let model = DriveFeatureModel()
        model.configure(accountID: "owner", resume: {
            LiveDriveAccess(cache: cache, state: .active(reader))
        }, connect: { LiveDriveAccess(cache: cache, state: .active(reader)) })
        await model.start()
        await model.open(item)
        XCTAssertEqual(reader.rootCalls, 2)
        XCTAssertTrue(model.directory(parentID: DrivePage.rootParentID).items.isEmpty)
        XCTAssertEqual(model.notice, .changed)
    }

    func testFailedCacheStoreDoesNotHideFreshServerListing() async throws {
        let cache = try cache()
        let root = try XCTUnwrap(roots.last).appendingPathComponent("v1/scope")
        let manifest = root.appendingPathComponent("manifest.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        let item = try item()
        let reader = FakeDriveReader(rootResults: [.success(try page(items: [item]))])
        let model = DriveFeatureModel()
        model.configure(accountID: "owner", resume: {
            LiveDriveAccess(cache: cache, state: .active(reader))
        }, connect: { LiveDriveAccess(cache: cache, state: .active(reader)) })
        await model.start()
        XCTAssertEqual(model.directory(parentID: DrivePage.rootParentID).items, [item])
        XCTAssertEqual(model.directory(parentID: DrivePage.rootParentID).condition, .fresh)
        XCTAssertEqual(model.notice, .storageUnavailable)
    }

    func testWithdrawCancelsTransfersAndInvalidatesTheOutgoingCache() async throws {
        let cache = try cache()
        let item = try item()
        let reader = FakeDriveReader(rootResults: [.success(try page(items: [item]))])
        reader.download = { _, _, _ in
            try await Task.sleep(for: .seconds(60))
        }
        let model = DriveFeatureModel()
        model.configure(accountID: "owner", resume: {
            LiveDriveAccess(cache: cache, state: .active(reader))
        }, connect: { LiveDriveAccess(cache: cache, state: .active(reader)) })
        await model.start()
        let transfer = Task { await model.open(item) }
        while model.busyItemIDs.isEmpty { await Task.yield() }
        await model.withdraw(reason: .signInAgain)
        await transfer.value
        XCTAssertEqual(model.connection, .idle)
        XCTAssertTrue(model.directories.isEmpty)
        XCTAssertEqual(model.lastExitReason, .signInAgain,
                       "the sign-in-again path owns an explicit Drive withdrawal")
        do {
            _ = try await cache.page(parentID: DrivePage.rootParentID)
            XCTFail("withdrawn cache must not remain readable")
        } catch let failure as DriveFailure {
            XCTAssertEqual(failure, .storageUnavailable)
        }
    }

    func testPreviewPolicyRefusesActiveFormats() throws {
        XCTAssertFalse(DrivePreviewPolicy.allowsQuickLook(
            try item(name: "page.html", mimeType: "text/html")
        ))
        XCTAssertFalse(DrivePreviewPolicy.allowsQuickLook(
            try item(name: "drawing.svg", mimeType: "image/svg+xml")
        ))
        XCTAssertTrue(DrivePreviewPolicy.allowsQuickLook(
            try item(name: "plan.pdf", mimeType: "application/pdf")
        ))
        XCTAssertTrue(DrivePreviewPolicy.allowsQuickLook(
            try item(name: "clip.mp4", mimeType: "video/mp4")
        ))
        for name in ["page.mhtml", "page.shtml", "drawing.svgz", "style.xsl"] {
            XCTAssertFalse(DrivePreviewPolicy.allowsQuickLook(
                try item(name: name, mimeType: "text/plain")
            ))
        }
        XCTAssertFalse(DrivePreviewPolicy.allowsQuickLook(
            try item(name: "drawing.svgz", mimeType: "image/png")
        ))
        XCTAssertTrue(DrivePreviewPolicy.allowsQuickLook(
            try item(name: "README", mimeType: "text/plain")
        ))
    }

    func testOldOpenAndKeepOperationsCannotPublishAfterAccountChange() async throws {
        let cache = try cache()
        let item = try item()
        let reader = FakeDriveReader(rootResults: [.success(try page(items: [item]))])
        let gate = AsyncGate()
        reader.download = { item, url, progress in
            await gate.suspend()
            progress(item.size, item.size)
            try Data("hello".utf8).write(to: url)
        }
        let model = DriveFeatureModel()
        model.configure(accountID: "owner-a", resume: {
            LiveDriveAccess(cache: cache, state: .active(reader))
        }, connect: { LiveDriveAccess(cache: cache, state: .active(reader)) })
        await model.start()
        let opening = Task { await model.open(item) }
        while !(await gate.hasWaiter) { await Task.yield() }
        model.configure(accountID: "owner-b", resume: {
            LiveDriveAccess(cache: nil, state: .storageUnavailable)
        }, connect: { LiveDriveAccess(cache: nil, state: .storageUnavailable) })
        await gate.open()
        await opening.value
        XCTAssertNil(model.preview)
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.keptItemIDs.isEmpty)
        XCTAssertTrue(model.transferProgress.isEmpty)
    }

    func testOldKeepOfflineCannotPublishAfterAccountChange() async throws {
        let cache = try cache()
        let item = try item()
        let reader = FakeDriveReader(rootResults: [.success(try page(items: [item]))])
        let gate = AsyncGate()
        reader.download = { item, url, progress in
            await gate.suspend()
            progress(item.size, item.size)
            try Data("hello".utf8).write(to: url)
        }
        let model = DriveFeatureModel()
        model.configure(accountID: "owner-a", resume: {
            LiveDriveAccess(cache: cache, state: .active(reader))
        }, connect: { LiveDriveAccess(cache: cache, state: .active(reader)) })
        await model.start()
        let keeping = Task { await model.toggleKeepOffline(item) }
        while !(await gate.hasWaiter) { await Task.yield() }
        model.configure(accountID: "owner-b", resume: {
            LiveDriveAccess(cache: nil, state: .storageUnavailable)
        }, connect: { LiveDriveAccess(cache: nil, state: .storageUnavailable) })
        await gate.open()
        await keeping.value
        XCTAssertTrue(model.keptItemIDs.isEmpty)
        XCTAssertNil(model.notice)
        XCTAssertTrue(model.transferProgress.isEmpty)
    }
}

@MainActor private final class MainActorCounter {
    var value = 0
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var hasWaiter: Bool { continuation != nil }

    func suspend() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor private final class FakeDriveReader: DriveReading {
    var rootResults: [Result<DrivePage, any Error>]
    var rootCalls = 0
    var childrenResult: Result<DrivePage, any Error>?
    var download: (DriveItem, URL, @escaping @Sendable (Int64, Int64) -> Void) async throws -> Void = {
        item, url, progress in
        progress(item.size, item.size)
        try Data(repeating: 1, count: Int(item.size)).write(to: url)
    }

    init(rootResults: [Result<DrivePage, any Error>]) { self.rootResults = rootResults }

    func rootPage() async throws -> DrivePage {
        rootCalls += 1
        guard !rootResults.isEmpty else { throw DriveFailure.invalidResponse }
        return try rootResults.removeFirst().get()
    }

    func children(driveID: String, parentID: String) async throws -> DrivePage {
        guard let childrenResult else { throw DriveFailure.invalidResponse }
        return try childrenResult.get()
    }

    func download(_ item: DriveItem, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await download(item, destination, progress)
    }
}
