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

    func fetch(roomID: String, eventID: String, copy: RichPushPresentation.Copy) async throws -> RichPushPresentation.Result {
        guard !busy else { throw FetchFailure.unavailable }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        let reader = try MatrixSessionReader.notificationReader()
        let ticket = try reader.loadCurrent()
        let paths = try MatrixStoreDirectory().requireExisting(generation: ticket.generation)
        let oauth = try JSONSerialization.data(withJSONObject: ["client_id": ticket.session.clientID])
        guard let oauthData = String(data: oauth, encoding: .utf8) else { throw FetchFailure.unavailable }
        // Deliberately do not give the SDK a refresh credential. Only the app rotates it.
        let session = Session(accessToken: ticket.session.accessToken, refreshToken: nil,
                              userId: ticket.session.userID, deviceId: ticket.session.deviceID,
                              homeserverUrl: ticket.session.homeserver, oauthData: oauthData,
                              slidingSyncVersion: .native)
        let delegate = ReadOnlyNotificationSession(reader: reader, ticket: ticket, session: session)
        let client = try await ClientBuilder()
            .homeserverUrl(url: ticket.session.homeserver)
            .disableWellKnownLookup(disableWellKnownLookup: true)
            .sqliteStore(config: SqliteStoreBuilder(dataPath: paths.data.path, cachePath: paths.cache.path)
                .passphrase(passphrase: ticket.passphrase))
            .disableAutomaticTokenRefresh()
            .autoEnableCrossSigning(autoEnableCrossSigning: false)
            .autoEnableBackups(autoEnableBackups: false)
            .slidingSyncVersionBuilder(versionBuilder: .native)
            .crossProcessLockConfig(crossProcessLockConfig: .multiProcess(holderName: "atum-nse-" + UUID().uuidString))
            .setSessionDelegate(sessionDelegate: delegate)
            .requestConfig(config: RequestConfig(retryLimit: 0, timeout: 5_000,
                                                  maxConcurrentRequests: 2, maxRetryTime: 5_000))
            .build()
        do {
            try Task.checkCancellation()
            try delegate.requireCurrent()
            // No SyncService, room list, verification, backup or encryption setup.
            await client.enableAllSendQueues(enable: false)
            try await client.restoreSessionWith(session: session, roomLoadSettings: .one(roomId: roomID))
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
            let result = try Self.presentation(status, eventID: eventID, ownUserID: session.userId, copy: copy)
            try? await client.pause()
            try delegate.requireCurrent()
            try Task.checkCancellation()
            return result
        } catch {
            try? await client.pause()
            throw error
        }
    }

    static func presentation(_ status: NotificationStatus, eventID: String, ownUserID: String,
                             copy: RichPushPresentation.Copy) throws -> RichPushPresentation.Result {
        switch status {
        case .eventFilteredOut, .eventRedacted: return .suppress
        case .eventNotFound: return .generic
        case let .event(item):
            let sender: String
            let kind: RichPushItem.Kind
            switch item.event {
            case let .invite(userID): sender = userID; kind = .invite
            case let .timeline(event):
                guard event.eventId() == eventID else { return .generic }
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
            return RichPushPresentation.map(RichPushItem(senderID: sender,
                senderName: item.senderInfo.displayName, roomName: item.roomInfo.displayName,
                isDirect: item.roomInfo.isDirect, kind: kind), ownUserID: ownUserID, copy: copy)
        }
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
