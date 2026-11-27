// Lifecycle adapted from Element X iOS's Apache-2.0 NSEUserSession pattern.
// Copyright 2023 New Vector Ltd. Modifications Copyright 2026 Anka Ventures Vietnam Company Limited.
// Licensed under the Apache License, Version 2.0; see Vendor/Notices/ElementX-NSE.md.
import Foundation
import AtumNativeAPI
import AtumChat
import MatrixRustSDK

/// Reject overlapping fetches rather than retaining multiple SDK clients inside
/// the extension's small memory budget. Each accepted request owns a fresh client.
actor MatrixNotificationFetcher {
    static let shared = MatrixNotificationFetcher()
    private var busy = false

    func fetch(roomID: String, eventID: String, copy: RichPushPresentation.Copy) async throws -> FetchedNotification {
        guard !busy else { throw NotificationFallbackReason.fetchBusy }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        let reader = try MatrixSessionReader.notificationReader()
        let ticket = try await MatrixNotificationSession.current()
        let paths: MatrixStorePaths
        do { paths = try MatrixStoreDirectory().requireExisting(generation: ticket.generation) }
        catch let error as MatrixStoreFailure { throw error }
        catch { throw NotificationFallbackReason.storeUnavailable }
        let oauth = try JSONSerialization.data(withJSONObject: ["client_id": ticket.session.clientID])
        guard let oauthData = String(data: oauth, encoding: .utf8) else { throw FetchFailure.unavailable }
        // Custody already refreshed under the shared lock. The SDK must never spend a token.
        let session = Session(accessToken: ticket.session.accessToken, refreshToken: nil,
                              userId: ticket.session.userID, deviceId: ticket.session.deviceID,
                              homeserverUrl: ticket.session.homeserver, oauthData: oauthData,
                              slidingSyncVersion: .native)
        let delegate = ReadOnlyNotificationSession(reader: reader, ticket: ticket, session: session)
        let client: Client
        do {
            client = try await ClientBuilder()
                .homeserverUrl(url: ticket.session.homeserver)
                .disableWellKnownLookup(disableWellKnownLookup: true)
                .sqliteStore(config: SqliteStoreBuilder(dataPath: paths.data.path, cachePath: paths.cache.path)
                    .passphrase(passphrase: ticket.passphrase)
                    .systemIsMemoryConstrained())
                .disableAutomaticTokenRefresh()
                .autoEnableCrossSigning(autoEnableCrossSigning: false)
                .autoEnableBackups(autoEnableBackups: false)
                .slidingSyncVersionBuilder(versionBuilder: .native)
                .crossProcessLockConfig(crossProcessLockConfig: .multiProcess(holderName: "atum-nse-" + UUID().uuidString))
                .setSessionDelegate(sessionDelegate: delegate)
                .requestConfig(config: RequestConfig(retryLimit: 0, timeout: 5_000,
                                                      maxConcurrentRequests: 2, maxRetryTime: 5_000))
                .build()
        } catch { throw NotificationFallbackReason.sdkBuildFailed }
        do {
            try Task.checkCancellation()
            try delegate.requireCurrent()
            // No SyncService, room list, verification, backup or encryption setup.
            await client.enableAllSendQueues(enable: false)
            do { try await client.restoreSessionWith(session: session, roomLoadSettings: .one(roomId: roomID)) }
            catch { throw NotificationFallbackReason.sdkRestoreFailed }
            guard try client.userId() == session.userId, try client.deviceId() == session.deviceId,
                  let curve = await client.encryption().curve25519Key(),
                  let ed = await client.encryption().ed25519Key() else { throw FetchFailure.unavailable }
            try ticket.verifyDeviceKeys(curve25519: curve, ed25519: ed)
            try delegate.requireCurrent()
            try Task.checkCancellation()
            let notifications = try await client.notificationClientWithTimeouts(
                processSetup: .multipleProcesses,
                timeouts: NotificationClientTimeouts(syncPollTimeout: 1, syncNetworkTimeout: 4,
                    decryptionDeadline: 5, encryptionSyncPollTimeout: 1, encryptionSyncNetworkTimeout: 3))
            let status = try await notifications.getNotification(roomId: roomID, eventId: eventID)
            try Task.checkCancellation()
            let result: RichPushPresentation.Result
            if await Self.suppressesTeamNotification(
                status, client: client, notifications: notifications,
                roomID: roomID, eventID: eventID, ownUserID: session.userId
            ) {
                result = .suppress
            } else {
                result = try Self.presentation(status, eventID: eventID, ownUserID: session.userId, copy: copy)
            }
            // The big image is best effort: any failure here keeps the rich text.
            let face = await Self.face(status, result: result, roomID: roomID, ownUserID: session.userId,
                                       store: try? NotificationSharedStore()) { uri, side in
                let source = try MediaSource.fromUrl(url: uri)
                return try await client.getMediaThumbnail(mediaSource: source, width: UInt64(side), height: UInt64(side))
            }
            try? await client.pause()
            try delegate.requireCurrent()
            try Task.checkCancellation()
            return FetchedNotification(result: result, face: face)
        } catch {
            try? await client.pause()
            throw error
        }
    }

    /// Apply presentation preferences only to events the SDK notification
    /// client admitted. All account data and event facts come from Matrix.
    private static func suppressesTeamNotification(_ status: NotificationStatus, client: Client,
                                                   notifications: NotificationClient,
                                                   roomID: String, eventID: String, ownUserID: String) async -> Bool {
        guard case let .event(item) = status, case let .timeline(event) = item.event,
              event.eventId() == eventID else { return false }
        let cachedRoom = try? client.getRoom(roomId: roomID)
        guard let room = (try? notifications.getRoom(roomId: roomID)) ?? cachedRoom else { return false }
        var create = (try? await room.stateEvents(eventType: .roomCreate))?.first { $0.stateKey.isEmpty }
        if create == nil, let cachedRoom {
            create = (try? await cachedRoom.stateEvents(eventType: .roomCreate))?.first { $0.stateKey.isEmpty }
        }
        guard TeamNotificationPolicy.applies(
            toRoomType: MobileRoomTypePolicy.roomType(createContentJSON: create?.contentJson)
        ) else { return false }

        let raw: String?
        do { raw = try await client.accountData(eventType: TeamNotificationPolicy.legacyType) }
        catch { return false }
        let legacy = raw.flatMap(TeamNotificationPolicy.Legacy.parse)
        guard raw == nil || legacy != nil else { return false }

        let rootID = event.threadRootEventId() ?? item.threadId
        async let account = notificationRecord(.account, client: client)
        async let hours = notificationRecord(.quietHours, client: client)
        async let channel = notificationRecord(.channel(roomID), client: client)
        async let thread = notificationRecord(rootID.map { .thread(roomID: roomID, rootID: $0) }, client: client)
        let policy = await TeamNotificationPolicy(roomID: roomID, rootID: rootID, legacy: legacy,
                                                  account: account, quietHours: hours, channel: channel, thread: thread)
        var inherited = false
        if policy.legacyChannel == .mentions || policy.legacyChannel == .nothing {
            let settings = await client.getNotificationSettings()
            do { inherited = try await settings.getUserDefinedRoomNotificationMode(roomId: roomID) == nil }
            catch { /* A failed read carries no evidence of inheritance. */ }
        }
        let now = Date.now
        if policy.suppressesAdmittedNotification(roomIsInherited: inherited, hasAttention: true, now: now) {
            return true
        }
        guard policy.suppressesAdmittedNotification(roomIsInherited: inherited, hasAttention: false, now: now)
        else { return false }

        let mentions = TeamNotificationPolicy.intentionalMentions(eventJSON: item.rawEvent, ownUserID: ownUserID)
        if mentions.direct { return false }
        if mentions.room, let levels = try? await room.getPowerLevels(),
           (try? levels.canUserTriggerRoomNotification(userId: event.senderId())) == true { return false }
        // The extension can use the SDK's cached thread summary. It does not
        // fetch thread history while the notification delivery deadline runs.
        if let rootID,
           let thread = cachedRoom?.threadListService().items().first(where: { $0.rootEvent.eventId == rootID }),
           thread.rootEvent.sender == ownUserID || thread.latestEvent?.sender == ownUserID { return false }
        return true
    }

    private static func notificationRecord(_ target: TeamNotificationPolicy.Target?, client: Client) async
        -> TeamNotificationPolicy.Record? {
        guard let target, let raw = try? await client.accountData(eventType: target.eventType) else { return nil }
        return TeamNotificationPolicy.Record.parse(raw, for: target)
    }

    static func presentation(_ status: NotificationStatus, eventID: String, ownUserID: String,
                             copy: RichPushPresentation.Copy) throws -> RichPushPresentation.Result {
        switch status {
        case .eventFilteredOut, .eventRedacted: return .suppress
        case .eventNotFound: throw NotificationFallbackReason.eventNotFound
        case let .event(item):
            let sender: String
            let kind: RichPushItem.Kind
            switch item.event {
            case let .invite(userID): sender = userID; kind = .invite
            case let .timeline(event):
                guard event.eventId() == eventID else { throw NotificationFallbackReason.eventMismatch }
                sender = event.senderId()
                switch try event.content() {
                case let .messageLike(content):
                    switch content {
                    case .roomEncrypted: kind = .undecryptable
                    case .sticker: kind = .sticker
                    case let .roomMessage(type, _):
                        switch type {
                        case let .text(content): kind = .text(content.body)
                        case let .notice(content): kind = .notice(content.body)
                        case let .emote(content): kind = .emote(content.body)
                        case .image: kind = .image
                        case .video: kind = .video
                        case .audio: kind = .audio
                        case .file: kind = .file
                        case .location: kind = .location
                        default: kind = .unsupported
                        }
                    default: kind = .unsupported
                    }
                case .state: kind = .unsupported
                }
            }
            let result = RichPushPresentation.map(RichPushItem(senderID: sender,
                senderName: item.senderInfo.displayName, roomName: item.roomInfo.displayName,
                isDirect: item.roomInfo.isDirect, kind: kind), ownUserID: ownUserID, copy: copy)
            if case .generic = result { throw NotificationFallbackReason.presentationUnavailable }
            return result
        }
    }

    /// The communication plan for a fetched event and its image: the app's
    /// drawn face from the shared store, else a cached or freshly fetched SDK
    /// thumbnail (one URI at a time, each with a short deadline), else nil for
    /// the monogram. Image sources come from the SDK item and the app's
    /// directory, never from the push.
    static func face(_ status: NotificationStatus, result: RichPushPresentation.Result, roomID: String,
                     ownUserID: String, store: NotificationSharedStore?,
                     thumbnail: @escaping @Sendable (String, Int) async throws -> Data) async -> CommunicationFace? {
        guard case let .content(content) = result, case let .event(item) = status else { return nil }
        let senderID: String
        switch item.event {
        case let .invite(userID): senderID = userID
        case let .timeline(event): senderID = event.senderId()
        }
        let input = CommunicationNotificationPolicy.Input(
            roomID: roomID, senderName: content.senderName, senderAvatarURI: item.senderInfo.avatarUrl,
            roomName: content.roomName, roomAvatarURI: item.roomInfo.avatarUrl, isDirect: item.roomInfo.isDirect)
        let entry = CommunicationNotificationPolicy.entry(roomID: roomID, ownUserID: ownUserID,
                                                          directory: store?.readDirectory())
        guard let plan = CommunicationNotificationPolicy.plan(input, entry: entry) else { return nil }
        let image = await CommunicationNotification.image(for: plan, store: store, thumbnail: thumbnail)
        return CommunicationFace(plan: plan, roomID: roomID, senderID: senderID, senderName: content.senderName,
                                 ownUserID: ownUserID, image: image)
    }

    private enum FetchFailure: Error { case unavailable }
}


/// Copy-only callback. Session mutation invalidates the result; it never writes
/// a Keychain record and cannot access the app's domain/recovery credential APIs.
private final class ReadOnlyNotificationSession: ClientSessionDelegate, @unchecked Sendable {
    private let reader: MatrixSessionReader
    private let ticket: MatrixCustodyTicket
    private let session: Session
    private let lock = NSLock()
    private var changed = false
    init(reader: MatrixSessionReader, ticket: MatrixCustodyTicket, session: Session) {
        self.reader = reader; self.ticket = ticket; self.session = session
    }
    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard userId == session.userId else { throw MatrixCustodyFailure.invalidIdentity }
        try requireCurrent()
        return session
    }
    func saveSessionInKeychain(session: Session) {
        if session != self.session { lock.withLock { changed = true } }
    }
    func requireCurrent() throws {
        guard !lock.withLock({ changed }) else { throw MatrixCustodyFailure.recoveryRequired }
        try reader.recheck(ticket)
    }
}

/// Closed public reason codes only: never interpolate errors or account/event data.
enum NotificationFallbackReason: String, Error {
    case invalidPayload = "invalid_payload", fetchBusy = "fetch_busy"
    case refreshBusy = "refresh_busy", refreshFailed = "refresh_failed"
    case refreshInterrupted = "refresh_interrupted", refreshTimeout = "refresh_timeout"
    case recordChanged = "record_changed", keychainLocked = "keychain_locked"
    case custodyUnavailable = "custody_unavailable", expired
    case storeLocked = "store_locked", storeUnavailable = "store_unavailable"
    case fetchTimeout = "fetch_timeout", fetchFailed = "fetch_failed"
    case sdkBuildFailed = "sdk_build_failed", sdkRestoreFailed = "sdk_restore_failed"
    case eventNotFound = "event_not_found", eventMismatch = "event_mismatch"
    case presentationUnavailable = "presentation_unavailable"
    case systemExpiry = "system_expiry"

    static func classify(_ error: any Error) -> Self {
        if let reason = error as? Self { return reason }
        if let failure = error as? MatrixRefreshFailure {
            switch failure {
            case .busy: return .refreshBusy
            case .unavailable: return .custodyUnavailable
            case .recordChanged: return .recordChanged
            case .timedOut: return .refreshTimeout
            case .keychainLocked: return .keychainLocked
            }
        }
        if let failure = error as? OIDCGrantFailure {
            return failure == .refreshInterrupted ? .refreshInterrupted : .refreshFailed
        }
        if error is MASHTTPFailure { return .refreshFailed }
        if let failure = error as? MatrixStoreFailure {
            return failure == .locked ? .storeLocked : .storeUnavailable
        }
        if let failure = error as? MatrixCustodyFailure {
            return failure == .expired ? .expired : .custodyUnavailable
        }
        return .fetchFailed
    }
}
