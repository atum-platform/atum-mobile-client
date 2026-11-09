import Foundation
import Observation
import AtumNativeAPI

public enum LiveDriveAccessState {
    case disconnected
    case provisioning
    case denied
    case reauthenticationRequired
    case offline
    case serviceUnavailable
    case timedOut
    case secureConnectionFailed
    case rateLimited
    case storageUnavailable
    case active(any DriveReading)
}

public struct LiveDriveAccess: @unchecked Sendable {
    public let cache: DriveCache?
    public let state: LiveDriveAccessState

    public init(cache: DriveCache?, state: LiveDriveAccessState) {
        self.cache = cache
        self.state = state
    }
}

public enum DriveConnectionState: Equatable {
    case idle
    case connecting
    case disconnected
    case ready
    case provisioning
    case denied
    case reauthenticationRequired
    case offline
    case serviceUnavailable
    case timedOut
    case secureConnectionFailed
    case rateLimited
    case storageUnavailable
    case failed
}

public enum DriveDirectoryCondition: Equatable {
    case loading
    case fresh
    case stale
    case offline
    case needsConnection
    case denied
    case failed
}

public struct DriveDirectoryPresentation: Equatable {
    public var items = [DriveItem]()
    public var condition = DriveDirectoryCondition.loading
    public var isTruncated = false

    public init(items: [DriveItem] = [],
                condition: DriveDirectoryCondition = .loading,
                isTruncated: Bool = false) {
        self.items = items
        self.condition = condition
        self.isTruncated = isTruncated
    }
}

public enum DriveNotice: String, Identifiable {
    case needsConnection
    case downloadFailed
    case lowDisk
    case serverQuota
    case denied
    case changed
    case storageUnavailable

    public var id: String { rawValue }
}

public enum DriveLocalPresentation: Sendable {
    case quickLook
    case export
}

public struct DrivePreview: Identifiable {
    public let id = UUID()
    public let url: URL
    public let name: String
    public let isStale: Bool
    public let presentation: DriveLocalPresentation

    public init(url: URL, name: String, isStale: Bool,
                presentation: DriveLocalPresentation) {
        self.url = url
        self.name = name
        self.isStale = isStale
        self.presentation = presentation
    }
}

@MainActor
@Observable
@available(macOS 14.0, *)
public final class DriveFeatureModel {
    public typealias Access = @MainActor () async throws -> LiveDriveAccess

    public private(set) var connection = DriveConnectionState.idle
    public private(set) var directories = [String: DriveDirectoryPresentation]()
    public private(set) var rootDriveID: String?
    public private(set) var keptItemIDs = Set<String>()
    public private(set) var busyItemIDs = Set<String>()
    public private(set) var transferProgress = [String: Double]()
    public private(set) var lastExitReason: DriveExitReason?
    public var preview: DrivePreview?
    public var notice: DriveNotice?

    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var resumeAccess: Access?
    @ObservationIgnored private var connectAccess: Access?
    @ObservationIgnored private var cache: DriveCache?
    @ObservationIgnored private var client: (any DriveReading)?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var provisioningTask: Task<Void, Never>?
    @ObservationIgnored private var retryTasks = [String: Task<Void, Never>]()
    @ObservationIgnored private var retryCounts = [String: Int]()
    @ObservationIgnored private var provisioningAttempts = 0
    @ObservationIgnored private var transferTasks = [String: Task<Void, Never>]()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var generation: UInt64 = 0

    public init() {}

    public func configure(accountID: String, resume: @escaping Access,
                          connect: @escaping Access) {
        guard self.accountID != accountID else {
            resumeAccess = resume
            connectAccess = connect
            return
        }
        generation &+= 1
        startTask?.cancel()
        provisioningTask?.cancel()
        retryTasks.values.forEach { $0.cancel() }
        startTask = nil
        provisioningTask = nil
        retryTasks = [:]
        retryCounts = [:]
        provisioningAttempts = 0
        transferTasks.values.forEach { $0.cancel() }
        transferTasks = [:]
        started = false
        lastExitReason = nil
        self.accountID = accountID
        resumeAccess = resume
        connectAccess = connect
        cache = nil
        client = nil
        connection = .idle
        directories = [:]
        rootDriveID = nil
        keptItemIDs = []
        busyItemIDs = []
        transferProgress = [:]
        preview = nil
        notice = nil
    }

    public func start() async {
        guard !started, startTask == nil, let resumeAccess else { return }
        started = true
        let token = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let access = try await resumeAccess()
                guard token == generation else { return }
                await receive(access, refreshRoot: true, token: token)
            } catch {
                guard token == generation else { return }
                connection = Self.connection(for: error)
                var root = directories[DrivePage.rootParentID] ?? .init()
                root.condition = root.items.isEmpty ? .failed : .stale
                directories[DrivePage.rootParentID] = root
            }
            if token == generation { startTask = nil }
        }
        startTask = task
        await task.value
    }

    public func connect() async {
        guard connection != .connecting, let connectAccess else { return }
        connection = .connecting
        let token = generation
        do {
            let access = try await connectAccess()
            guard token == generation else { return }
            await receive(access, refreshRoot: true, token: token)
        } catch {
            guard token == generation else { return }
            connection = Self.connection(for: error)
        }
    }

    public func directory(parentID: String) -> DriveDirectoryPresentation {
        directories[parentID] ?? .init()
    }

    public func load(parentID: String, driveID: String?) async {
        let token = generation
        if let cache {
            do {
                if let page = try await cache.page(parentID: parentID) {
                    guard token == generation else { return }
                    publish(page, condition: client == nil ? .stale : .loading)
                    await refreshKept(page.items, token: token)
                }
            } catch {
                guard token == generation else { return }
                notice = .storageUnavailable
            }
        }

        guard let client else {
            guard token == generation else { return }
            var value = directories[parentID] ?? .init()
            value.condition = value.items.isEmpty ? .needsConnection : .stale
            directories[parentID] = value
            return
        }
        var loading = directories[parentID] ?? .init()
        if loading.items.isEmpty { loading.condition = .loading }
        directories[parentID] = loading
        do {
            let page: DrivePage
            if parentID == DrivePage.rootParentID {
                page = try await client.rootPage()
            } else {
                guard let driveID else { throw DriveFailure.invalidRequest }
                page = try await client.children(driveID: driveID, parentID: parentID)
            }
            guard token == generation else { return }
            publish(page, condition: .fresh)
            await refreshKept(page.items, token: token)
            do { try await cache?.store(page: page) }
            catch { notice = .storageUnavailable }
            retryTasks[parentID]?.cancel()
            retryTasks[parentID] = nil
            retryCounts[parentID] = nil
            connection = .ready
        } catch {
            guard token == generation else { return }
            publishFailure(error, parentID: parentID, driveID: driveID)
        }
    }

    public func open(_ item: DriveItem) async {
        guard item.kind == .file, transferTasks[item.id] == nil else { return }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performOpen(item)
        }
        transferTasks[item.id] = task
        await task.value
        transferTasks[item.id] = nil
    }

    private func performOpen(_ item: DriveItem) async {
        let token = generation
        busyItemIDs.insert(item.id)
        defer {
            busyItemIDs.remove(item.id)
            transferProgress[item.id] = nil
        }
        do {
            let local = try await localFile(for: item, keepOffline: false, token: token)
            guard !Task.isCancelled, token == generation else { return }
            preview = DrivePreview(
                url: local.url,
                name: item.name,
                isStale: local.isStale || connection != .ready,
                presentation: DrivePreviewPolicy.allowsQuickLook(item) ? .quickLook : .export
            )
        } catch {
            if error is CancellationError || error as? DriveFailure == .cancelled { return }
            guard !Task.isCancelled, token == generation else { return }
            if error as? DriveFailure == .notFound {
                await load(parentID: item.parentID ?? DrivePage.rootParentID,
                           driveID: item.parentDriveID ?? rootDriveID)
                guard !Task.isCancelled, token == generation else { return }
            }
            publishTransferFailure(error)
        }
    }

    public func toggleKeepOffline(_ item: DriveItem) async {
        guard item.kind == .file, transferTasks[item.id] == nil, let cache else { return }
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performToggleKeepOffline(item, cache: cache)
        }
        transferTasks[item.id] = task
        await task.value
        transferTasks[item.id] = nil
    }

    private func performToggleKeepOffline(_ item: DriveItem, cache: DriveCache) async {
        let token = generation
        busyItemIDs.insert(item.id)
        defer {
            busyItemIDs.remove(item.id)
            transferProgress[item.id] = nil
        }
        do {
            if keptItemIDs.contains(item.id) {
                try await cache.setKept(false, for: item)
                guard !Task.isCancelled, token == generation else { return }
                keptItemIDs.remove(item.id)
            } else {
                _ = try await localFile(for: item, keepOffline: true, token: token)
                guard !Task.isCancelled, token == generation else { return }
                keptItemIDs.insert(item.id)
            }
        } catch {
            if error is CancellationError || error as? DriveFailure == .cancelled { return }
            guard !Task.isCancelled, token == generation else { return }
            publishTransferFailure(error)
        }
    }

    public func dismissPreview() {
        preview = nil
        guard let cache else { return }
        Task { try? await cache.releasePreview() }
    }

    public func cancelTransfer(itemID: String) {
        transferTasks[itemID]?.cancel()
    }

    public func withdraw(reason: DriveExitReason = .signOut) async {
        generation &+= 1
        startTask?.cancel()
        provisioningTask?.cancel()
        retryTasks.values.forEach { $0.cancel() }
        transferTasks.values.forEach { $0.cancel() }
        startTask = nil
        provisioningTask = nil
        retryTasks = [:]
        retryCounts = [:]
        provisioningAttempts = 0
        transferTasks = [:]
        started = false
        let outgoing = cache
        cache = nil
        client = nil
        accountID = nil
        connection = .idle
        directories = [:]
        rootDriveID = nil
        keptItemIDs = []
        busyItemIDs = []
        transferProgress = [:]
        preview = nil
        notice = nil
        lastExitReason = reason
        try? await outgoing?.withdraw()
    }

    private func receive(_ access: LiveDriveAccess, refreshRoot: Bool,
                         token: UInt64) async {
        guard token == generation else { return }
        guard let accessCache = access.cache else {
            cache = nil
            client = nil
            connection = .storageUnavailable
            setRootCondition(.failed)
            return
        }
        cache = accessCache
        let cachedPage = try? await accessCache.page(parentID: DrivePage.rootParentID)
        guard token == generation else { return }
        if let page = cachedPage {
            publish(page, condition: .stale)
            await refreshKept(page.items, token: token)
            guard token == generation else { return }
        }
        switch access.state {
        case .disconnected:
            client = nil
            connection = .disconnected
            var root = directories[DrivePage.rootParentID] ?? .init()
            root.condition = root.items.isEmpty ? .needsConnection : .stale
            directories[DrivePage.rootParentID] = root
        case .provisioning:
            client = nil
            connection = .provisioning
            scheduleProvisioningRetry()
        case .denied:
            client = nil
            connection = .denied
            var root = directories[DrivePage.rootParentID] ?? .init()
            root.condition = root.items.isEmpty ? .denied : .stale
            directories[DrivePage.rootParentID] = root
        case .reauthenticationRequired:
            client = nil
            connection = .reauthenticationRequired
            setRootCondition(.needsConnection)
        case .offline:
            client = nil
            connection = .offline
            setRootCondition(.offline)
        case .serviceUnavailable:
            client = nil
            connection = .serviceUnavailable
            setRootCondition(.failed)
        case .timedOut:
            client = nil
            connection = .timedOut
            setRootCondition(.failed)
        case .secureConnectionFailed:
            client = nil
            connection = .secureConnectionFailed
            setRootCondition(.failed)
        case .rateLimited:
            client = nil
            connection = .rateLimited
            setRootCondition(.failed)
        case .storageUnavailable:
            client = nil
            connection = .storageUnavailable
            setRootCondition(.failed)
        case let .active(client):
            provisioningTask?.cancel()
            provisioningTask = nil
            provisioningAttempts = 0
            self.client = client
            connection = .ready
            if refreshRoot {
                await load(parentID: DrivePage.rootParentID, driveID: rootDriveID)
                guard token == generation else { return }
            }
        }
    }

    private func publish(_ page: DrivePage, condition: DriveDirectoryCondition) {
        if page.parentID == DrivePage.rootParentID { rootDriveID = page.driveID }
        directories[page.parentID] = DriveDirectoryPresentation(
            items: page.items.sorted {
                if $0.kind != $1.kind { return $0.kind == .folder }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            condition: condition,
            isTruncated: page.isTruncated
        )
    }

    private func setRootCondition(_ empty: DriveDirectoryCondition) {
        var root = directories[DrivePage.rootParentID] ?? .init()
        root.condition = root.items.isEmpty ? empty : .stale
        directories[DrivePage.rootParentID] = root
    }

    private func refreshKept(_ items: [DriveItem], token: UInt64) async {
        guard let cache else { return }
        var ids = keptItemIDs
        for item in items where item.kind == .file {
            if (try? await cache.isKept(item)) == true { ids.insert(item.id) }
            else { ids.remove(item.id) }
        }
        guard token == generation else { return }
        keptItemIDs = ids
    }

    private func localFile(for item: DriveItem, keepOffline: Bool, token: UInt64) async throws
        -> (url: URL, isStale: Bool) {
        guard let cache else { throw DriveFailure.storageUnavailable }
        if let url = try await cache.cachedURL(for: item) {
            try requireCurrent(token)
            if keepOffline {
                try await cache.setKept(true, for: item)
                try requireCurrent(token)
            }
            return (url, false)
        }
        let retained = try await cache.retainedURL(for: item)
        try requireCurrent(token)
        guard let client else {
            if let retained { return (retained, true) }
            throw DriveFailure.offline
        }
        var staging: URL?
        do {
            let prepared = try await cache.prepareDownload(expectedBytes: item.size)
            try requireCurrent(token)
            staging = prepared
            try await client.download(item, to: prepared) { [weak self] completed, total in
                Task { @MainActor [weak self] in
                    guard let self, total > 0, token == self.generation,
                          self.busyItemIDs.contains(item.id) else { return }
                    self.transferProgress[item.id] = min(1, Double(completed) / Double(total))
                }
            }
            try requireCurrent(token)
            let committed = try await cache.commit(prepared, item: item,
                                                   keepOffline: keepOffline)
            try requireCurrent(token)
            return (committed, false)
        } catch {
            if let staging { try? FileManager.default.removeItem(at: staging) }
            if let retained, let failure = error as? DriveFailure,
               failure == .offline || failure == .providerUnavailable || failure == .lowDisk
                || failure == .timedOut || failure == .secureConnectionFailed
                || failure.isTemporarilyUnavailable {
                return (retained, true)
            }
            throw error
        }
    }

    private func requireCurrent(_ token: UInt64) throws {
        guard !Task.isCancelled, token == generation else { throw DriveFailure.cancelled }
    }

    private func publishFailure(_ error: any Error, parentID: String, driveID: String?) {
        var value = directories[parentID] ?? .init()
        switch error as? DriveFailure {
        case .reauthenticationRequired:
            connection = .reauthenticationRequired
            value.condition = value.items.isEmpty ? .needsConnection : .stale
        case .denied:
            connection = .denied
            value.condition = value.items.isEmpty ? .denied : .stale
        case let .provisioning(retryAfter):
            connection = .provisioning
            value.condition = value.items.isEmpty ? .offline : .stale
            scheduleDirectoryRetry(parentID: parentID, driveID: driveID,
                                   after: retryAfter ?? 10)
        case let .serviceUnavailable(retryAfter):
            connection = .serviceUnavailable
            value.condition = value.items.isEmpty ? .failed : .stale
            scheduleDirectoryRetry(parentID: parentID, driveID: driveID,
                                   after: retryAfter ?? 5)
        case let .rateLimited(retryAfter):
            connection = .rateLimited
            value.condition = value.items.isEmpty ? .failed : .stale
            scheduleDirectoryRetry(parentID: parentID, driveID: driveID,
                                   after: retryAfter ?? 15)
        case .timedOut:
            connection = .timedOut
            value.condition = value.items.isEmpty ? .failed : .stale
        case .secureConnectionFailed:
            connection = .secureConnectionFailed
            value.condition = value.items.isEmpty ? .failed : .stale
        case .storageUnavailable:
            connection = .storageUnavailable
            value.condition = value.items.isEmpty ? .failed : .stale
        case .providerUnavailable:
            connection = .serviceUnavailable
            value.condition = value.items.isEmpty ? .failed : .stale
        case .offline:
            connection = .offline
            value.condition = value.items.isEmpty ? .offline : .stale
        default:
            value.condition = value.items.isEmpty ? .failed : .stale
        }
        directories[parentID] = value
    }

    private func scheduleProvisioningRetry() {
        guard provisioningTask == nil, provisioningAttempts < 6,
              let resumeAccess else { return }
        provisioningAttempts += 1
        let token = generation
        provisioningTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            guard let self, token == generation else { return }
            self.provisioningTask = nil
            do {
                let access = try await resumeAccess()
                guard token == generation else { return }
                await self.receive(access, refreshRoot: true, token: token)
                guard token == self.generation else { return }
            } catch {
                guard token == generation else { return }
                self.connection = Self.connection(for: error)
            }
        }
    }

    private func scheduleDirectoryRetry(parentID: String, driveID: String?,
                                        after seconds: Int) {
        guard retryTasks[parentID] == nil,
              retryCounts[parentID, default: 0] < 3 else { return }
        retryCounts[parentID, default: 0] += 1
        let token = generation
        retryTasks[parentID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) }
            catch { return }
            guard let self, token == generation else { return }
            self.retryTasks[parentID] = nil
            await self.load(parentID: parentID, driveID: driveID)
        }
    }

    private func publishTransferFailure(_ error: any Error) {
        switch error as? DriveFailure {
        case .lowDisk: notice = .lowDisk
        case .serverQuota: notice = .serverQuota
        case .denied: notice = .denied
        case .changed, .notFound: notice = .changed
        case .reauthenticationRequired:
            connection = .reauthenticationRequired
            notice = nil
        case .offline:
            connection = .offline
            notice = .needsConnection
        case .timedOut:
            connection = .timedOut
            notice = .downloadFailed
        case .secureConnectionFailed:
            connection = .secureConnectionFailed
            notice = .downloadFailed
        case .serviceUnavailable, .rateLimited, .providerUnavailable:
            connection = .serviceUnavailable
            notice = .downloadFailed
        case .storageUnavailable: notice = .storageUnavailable
        case .cancelled: break
        default: notice = .downloadFailed
        }
    }

    private static func connection(for error: any Error) -> DriveConnectionState {
        switch error as? DriveFailure {
        case .reauthenticationRequired: .reauthenticationRequired
        case .denied: .denied
        case .provisioning: .provisioning
        case .offline: .offline
        case .serviceUnavailable, .providerUnavailable: .serviceUnavailable
        case .timedOut: .timedOut
        case .secureConnectionFailed: .secureConnectionFailed
        case .rateLimited: .rateLimited
        case .storageUnavailable: .storageUnavailable
        default: .failed
        }
    }
}

public enum DrivePreviewPolicy {
    private static let activeExtensions: Set<String> = [
        "html", "htm", "xhtml", "svg", "webarchive", "xml",
    ]
    private static let inertExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp",
        "pdf", "txt", "md", "markdown", "csv", "rtf",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key",
        "mp3", "m4a", "aac", "wav", "aiff", "mp4", "mov", "m4v",
    ]
    private static let inertApplicationTypes: Set<String> = [
        "application/pdf", "application/rtf", "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-excel",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.ms-powerpoint",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.apple.pages", "application/vnd.apple.numbers",
        "application/vnd.apple.keynote",
    ]

    public static func allowsQuickLook(_ item: DriveItem) -> Bool {
        let ext = (item.name as NSString).pathExtension.lowercased()
        let mime = item.mimeType?.lowercased()
        let activeMIME = mime == "image/svg+xml" || mime == "text/html"
            || mime == "application/xhtml+xml" || mime == "application/x-webarchive"
            || mime == "application/xml" || mime == "text/xml"
        guard !activeMIME else { return false }
        if ext.isEmpty {
            guard let mime else { return false }
            return mime.hasPrefix("image/") || mime.hasPrefix("audio/")
                || mime.hasPrefix("video/") || mime == "text/plain"
                || mime == "text/csv" || inertApplicationTypes.contains(mime)
        }
        guard !activeExtensions.contains(ext), inertExtensions.contains(ext) else { return false }
        return true
    }
}
