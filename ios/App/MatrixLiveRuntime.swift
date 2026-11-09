import Foundation
import AtumNativeAPI
import MatrixRustSDK

enum MatrixLiveRuntimeFailure: Error {
    case identityMismatch
    case unexpectedSessionMutation
    case invalidRecoveryKey
    case recoveryNotReady
    case founderUnavailable
}

enum MatrixLiveRecoveryStatus: Equatable, Sendable {
    case unknown
    case ready
    case available
    case unavailable
}

struct MatrixLiveRecoverySnapshot: Equatable, Sendable {
    let recovery: MatrixLiveRecoveryStatus

    /// Closed log code for this snapshot; no identifiers.
    var logCode: String {
        switch recovery {
        case .ready: "ready"
        case .available: "incomplete"
        case .unavailable: "unavailable"
        case .unknown: "unknown"
        }
    }
}

/// The signed-in person's own profile, as shown in Settings.
struct MatrixOwnProfile: Equatable, Sendable {
    let displayName: String?
    let avatarURL: String?
}

/// The one live Matrix client owned by the main app. It uses the SDK's
/// encrypted SQLite stores and multi-process lease; no second app lock or token
/// store is introduced here.
@MainActor
final class MatrixLiveRuntime {
    let client: Client
    let ticket: MatrixCustodyTicket
    private let reader: MatrixSessionReader
    private let delegate: MatrixLiveSessionDelegate
    private let sessionStore: MatrixSessionKeychain
    private let marker: OIDCInstallationMarker
    private let recoveryStore: MatrixRecoveryKeychain
    private var recoveryObserver: MatrixLiveRecoveryObserver?
    private var recoveryStateStream: TaskHandle?
    private var recoverySink: (@MainActor @Sendable (MatrixLiveRecoverySnapshot) -> Void)?
    /// Set on resume when this phone's device keys no longer match the ones
    /// recorded at sign-in: old encrypted history cannot open here, so the
    /// optional "restore messages" entry is not offered. Never blocking.
    fileprivate(set) var oldHistoryUnavailable = false

    private init(client: Client, ticket: MatrixCustodyTicket,
                 reader: MatrixSessionReader, delegate: MatrixLiveSessionDelegate,
                 sessionStore: MatrixSessionKeychain, marker: OIDCInstallationMarker,
                 recoveryStore: MatrixRecoveryKeychain) {
        self.client = client
        self.ticket = ticket
        self.reader = reader
        self.delegate = delegate
        self.sessionStore = sessionStore
        self.marker = marker
        self.recoveryStore = recoveryStore
    }

    static func create(prepared: MatrixCustodyTicket,
                       store: MatrixSessionKeychain,
                       marker: OIDCInstallationMarker,
                       recoveryStore: MatrixRecoveryKeychain,
                       directories: MatrixStoreDirectory,
                       reader: MatrixSessionReader) async throws -> MatrixLiveRuntime {
        let paths = try directories.createPrepared(generation: prepared.generation)
        let session = try sdkSession(prepared.session)
        let delegate = MatrixLiveSessionDelegate(session: session)
        let client = try await build(paths: paths, ticket: prepared, delegate: delegate)
        do {
            try store.recheck(prepared, marker: marker)
            try await client.restoreSession(session: session)
            try store.recheck(prepared, marker: marker)
            guard try client.session() == session,
                  try client.userId() == session.userId,
                  try client.deviceId() == session.deviceId,
                  let curve = await client.encryption().curve25519Key(),
                  let ed = await client.encryption().ed25519Key() else {
                throw MatrixLiveRuntimeFailure.identityMismatch
            }
            _ = try directories.requireExisting(generation: prepared.generation)
            let ready = try store.commitPrepared(prepared, marker: marker,
                                                 curve25519: curve, ed25519: ed)
            try reader.recheck(ready)
            try delegate.activate(reader: reader, ticket: ready)
            try delegate.requireCurrent()
            return MatrixLiveRuntime(client: client, ticket: ready,
                                     reader: reader, delegate: delegate,
                                     sessionStore: store, marker: marker,
                                     recoveryStore: recoveryStore)
        } catch {
            try? await client.pause()
            throw error
        }
    }

    static func resume(ticket: MatrixCustodyTicket,
                       store: MatrixSessionKeychain,
                       marker: OIDCInstallationMarker,
                       recoveryStore: MatrixRecoveryKeychain,
                       directories: MatrixStoreDirectory,
                       reader: MatrixSessionReader) async throws -> MatrixLiveRuntime {
        try reader.recheck(ticket)
        let paths = try directories.requireExisting(generation: ticket.generation)
        let session = try sdkSession(ticket.session)
        let delegate = MatrixLiveSessionDelegate(session: session)
        try delegate.activate(reader: reader, ticket: ticket)
        let client = try await build(paths: paths, ticket: ticket, delegate: delegate)
        do {
            // 0.20 (E4): the stock SDK restore over the existing store, so the
            // committed project signs in and resumes without the candidate SDK.
            _ = try ticket.requiredDeviceKeys()
            try await client.restoreSession(session: session)
            guard try client.session() == session,
                  try client.userId() == session.userId,
                  try client.deviceId() == session.deviceId,
                  let curve = await client.encryption().curve25519Key(),
                  let ed = await client.encryption().ed25519Key() else {
                throw MatrixLiveRuntimeFailure.identityMismatch
            }
            try delegate.requireCurrent()
            let runtime = MatrixLiveRuntime(client: client, ticket: ticket,
                                            reader: reader, delegate: delegate,
                                            sessionStore: store, marker: marker,
                                            recoveryStore: recoveryStore)
            // The device keys must still be the ones recorded at sign-in. A
            // mismatch only means old encrypted history cannot open on this
            // phone; plain chats keep working, so it never blocks the app.
            do {
                try ticket.verifyDeviceKeys(curve25519: curve, ed25519: ed)
                LiveFlowLog.session(.resumeKeys, outcome: "match")
            } catch {
                runtime.oldHistoryUnavailable = true
                LiveFlowLog.session(.resumeKeys, outcome: "mismatch_history_unavailable")
            }
            return runtime
        } catch {
            try? await client.pause()
            throw error
        }
    }

    func requireCurrent() throws {
        try reader.recheck(ticket)
        try delegate.requireCurrent()
    }

    /// Observe only the SDK-owned recovery value required by S6's optional
    /// restore row. The retired comparison state never enters the UI.
    func observeRecovery(
        onChange: @escaping @MainActor @Sendable (MatrixLiveRecoverySnapshot) -> Void
    ) {
        stopObservingRecovery()
        recoverySink = onChange
        let observer = MatrixLiveRecoveryObserver(runtime: self)
        let encryption = client.encryption()
        recoveryObserver = observer
        recoveryStateStream = encryption.recoveryStateListener(listener: observer)
        Task { @MainActor [weak self] in await self?.publishRecoverySnapshot() }
    }

    func stopObservingRecovery() {
        recoveryStateStream?.cancel()
        recoveryObserver = nil
        recoveryStateStream = nil
        recoverySink = nil
    }

    fileprivate func publishRecoverySnapshot() async {
        guard let recoverySink else { return }
        guard let snapshot = try? await recoverySnapshot() else { return }
        recoverySink(snapshot)
    }

    /// Profile text is presentation only. The verified custody user ID remains
    /// authoritative, and a network/profile failure cannot switch identity or
    /// make a signed-in session unavailable.
    func currentProfile() async -> MatrixOwnProfile? {
        do {
            try requireCurrent()
            let userID = ticket.session.userID
            let profile = try await client.getProfile(userId: userID)
            try requireCurrent()
            guard profile.userId == userID else { return nil }
            return MatrixOwnProfile(displayName: Self.presentableName(profile.displayName),
                                    avatarURL: Self.presentableAvatar(profile.avatarUrl))
        } catch {
            return nil
        }
    }

    func currentDisplayName() async -> String? {
        await currentProfile()?.displayName
    }

    /// The person's own display name, the same write as the desktop profile
    /// editor's `client.setDisplayName`. Callers validate the name first.
    func setOwnDisplayName(_ name: String) async throws {
        try requireCurrent()
        try await client.setDisplayName(name: name)
        try requireCurrent()
    }

    /// The person's own photo: the SDK uploads it to the media repository and
    /// points the profile at it (the desktop's `uploadContent` + `setAvatarUrl`).
    /// Nil removes it. Returns the avatar the profile now holds.
    func setOwnAvatar(mimeType: String, data: Data?) async throws -> String? {
        try requireCurrent()
        if let data {
            try await client.uploadAvatar(mimeType: mimeType, data: data)
        } else {
            try await client.removeAvatar()
        }
        try requireCurrent()
        let current = try? await client.avatarUrl()
        try requireCurrent()
        return Self.presentableAvatar(current ?? nil)
    }

    private static func presentableName(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              (1...128).contains(raw.unicodeScalars.count),
              !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return raw
    }

    private static func presentableAvatar(_ value: String?) -> String? {
        guard let value, value.lowercased().hasPrefix("mxc://") else { return nil }
        return value
    }

    /// Register this phone's Matrix pusher. The fields come from the
    /// contract-b body (`MobilePush.pusherFields`): event IDs only and the
    /// generic alert, so the push gateway never receives message text.
    func setPusher(_ fields: MobilePusherFields) async throws {
        try requireCurrent()
        guard fields.format == "event_id_only" else { throw MatrixLiveRuntimeFailure.identityMismatch }
        try await client.setPusher(
            identifiers: PusherIdentifiers(pushkey: fields.pushkey, appId: fields.appID),
            kind: .http(data: HttpPusherData(url: fields.url, format: .eventIdOnly,
                                             defaultPayload: fields.defaultPayloadJSON)),
            appDisplayName: fields.appDisplayName,
            deviceDisplayName: fields.deviceDisplayName,
            profileTag: nil,
            lang: fields.lang,
            append: false
        )
        try requireCurrent()
    }

    /// Delete this phone's pusher by its contract identifiers. Used on token
    /// rotation (after the new pusher is set) and on sign-out, while the
    /// session still authenticates.
    func removePusher(pushkey: String, appID: String) async throws {
        try requireCurrent()
        try await client.deletePusher(identifiers: PusherIdentifiers(pushkey: pushkey, appId: appID))
        try requireCurrent()
    }

    /// The desktop's durable pointer to this person's one room with an app
    /// bot, read from the SDK's account-data store. Nil when absent or when
    /// the read fails; the caller falls back and logs which branch it took.
    func appBotPointerRoomID(appID: String, botUserID: String) async -> String? {
        do {
            try requireCurrent()
            let content = try await client.accountData(
                eventType: MobileAppBotRoomPolicy.pointerEventType(appID: appID)
            )
            try requireCurrent()
            return MobileAppBotRoomPolicy.pointerRoomID(contentJSON: content, botUserID: botUserID)
        } catch {
            LiveFlowLog.botRoom(.pointer, outcome: "read_failed", roomID: nil)
            return nil
        }
    }

    /// The person's explicit global app-shortcut preference from the same
    /// synchronized SDK account-data store the desktop writes. This is a
    /// cache read, not a network request: nil content means "no event" only
    /// after this local session is ready and has completed its initial sync.
    /// Before that point, and on any failed, stale-session or malformed read,
    /// the result is `unknown` so the roster never substitutes a guessed
    /// default. The pinned SDK exposes only closed account-data observers, so
    /// callers re-read this on the existing product/foreground/session-ready
    /// refresh and fence the result to the current runtime and account.
    func appShortcutState(appID: String, canReadCachedAccountData: Bool) async -> MobileAppShortcutState {
        guard canReadCachedAccountData else {
            return .unknown
        }
        guard let eventType = MobileAppShortcutPolicy.eventType(appID: appID) else {
            return .unknown
        }
        do {
            try requireCurrent()
            let content = try await client.accountData(eventType: eventType)
            try requireCurrent()
            return MobileAppShortcutPolicy.state(contentJSON: content)
        } catch {
            return .unknown
        }
    }

    /// Writes one closed app-shortcut preference through the SDK's existing
    /// global account-data API, then requires the synchronized SDK store to
    /// read back that exact value. Runtime replacement invalidates the write at
    /// every await; no raw credential HTTP or second preference store exists.
    func setAppShortcutVisibility(
        appID: String,
        visibility: MobileAppShortcutPolicy.Visibility
    ) async -> MobileAppShortcutWriteOutcome {
        guard let eventType = MobileAppShortcutPolicy.eventType(appID: appID) else {
            return .failed
        }
        return await MobileAppShortcutWritePolicy.perform(
            visibility: visibility,
            write: { content in
                try self.requireCurrent()
                try await self.client.setAccountData(eventType: eventType, content: content)
                try self.requireCurrent()
            },
            read: {
                try self.requireCurrent()
                let content = try await self.client.accountData(eventType: eventType)
                try self.requireCurrent()
                return content
            },
            pause: {
                try? await Task.sleep(for: .milliseconds(150))
            },
            isCurrent: {
                (try? self.requireCurrent()) != nil
            }
        )
    }

    /// The person's Founder-chat record from the synchronized SDK account-data
    /// store. A nil cache entry is authoritative absence only after the local
    /// session is ready and its initial sync has completed; before that point
    /// every result stays `unknown` and no read is attempted.
    func founderChatMarker(canReadCachedAccountData: Bool) async -> MobileFounderPolicy.ChatMarker {
        guard canReadCachedAccountData else { return .unknown }
        do {
            try requireCurrent()
            let content = try await client.accountData(eventType: MobileFounderPolicy.markerEventType)
            try requireCurrent()
            return MobileFounderPolicy.marker(accountDataJSON: content)
        } catch {
            return .unknown
        }
    }

    /// The canonical post-write Founder marker as the homeserver has it now.
    /// The selected `.atum.2` binding routes this one event type through the
    /// SDK's authenticated client; it exposes neither credentials nor an
    /// arbitrary HTTP surface. Failure stays unknown and never authorizes a
    /// second room or destructive loser cleanup.
    func fetchFounderChatMarker(roomID: String) async -> MobileFounderPolicy.ChatMarker {
        do {
            try requireCurrent()
            guard let room = try client.getRoom(roomId: roomID) else { return .unknown }
            let content = try await room.fetchGlobalAccountDataRaw(
                eventType: MobileFounderPolicy.markerEventType
            )
            try requireCurrent()
            return MobileFounderPolicy.marker(accountDataJSON: content)
        } catch {
            return .unknown
        }
    }

    /// Records the one canonical account-data marker. A present record, even
    /// one an older build cannot read, is the durable no-recreate authority.
    func writeFounderChatMarker(founder: String, roomID: String,
                                atMilliseconds: Int64) async throws {
        guard let content = MobileFounderPolicy.accountRecordJSON(
            founder: founder, roomID: roomID, atMilliseconds: atMilliseconds
        ) else {
            throw MatrixLiveRuntimeFailure.founderUnavailable
        }
        try requireCurrent()
        try await client.setAccountData(eventType: MobileFounderPolicy.markerEventType,
                                        content: content)
        try requireCurrent()
    }

    /// The canonical new-room recipe: plain, private, direct, one Founder
    /// invite and shared history. The room-state marker is sent immediately
    /// afterwards because the pinned `CreateRoomParameters` has no initial
    /// state field. The room is never encrypted here, so an existing encrypted
    /// legacy Founder room is only ever re-used, never downgraded.
    func createFounderChat(founder: String) async throws -> String {
        guard MobileFounderPolicy.roomMarkJSON(founder: founder) != nil else {
            throw MatrixLiveRuntimeFailure.founderUnavailable
        }
        try requireCurrent()
        let roomID = try await client.createRoom(request: CreateRoomParameters(
            name: nil,
            isEncrypted: false,
            isDirect: true,
            visibility: .private,
            preset: .privateChat,
            invite: [founder],
            historyVisibilityOverride: .shared
        ))
        try requireCurrent()
        // The account marker is the no-recreate authority. The room marker is
        // still written for canonical adoption, but a refusal after the room
        // exists must not strand an unrecorded room that the next pass would
        // duplicate.
        if let room = try? client.getRoom(roomId: roomID),
           let mark = MobileFounderPolicy.roomMarkJSON(founder: founder) {
            do {
                _ = try await room.sendStateEventRaw(eventType: MobileFounderPolicy.markerEventType,
                                                     stateKey: "", content: mark)
            } catch {
                LiveFlowLog.creation(.founder, outcome: "room_marker_refused", code: "matrix")
            }
        }
        try requireCurrent()
        return roomID
    }

    /// The room-state facts canonical adoption requires. A custom state type is
    /// only available from the SDK's cache when the sliding-sync subscription
    /// asked for it; an empty marker therefore fails closed instead of guessing
    /// from a room name or avatar.
    func founderRoomCandidate(roomID: String, ownUserID: String) async -> MobileFounderPolicy.RoomCandidate? {
        guard let room = try? client.getRoom(roomId: roomID) else { return nil }
        let createEvents = (try? await room.stateEvents(eventType: .roomCreate)) ?? []
        let create = createEvents.first { $0.stateKey.isEmpty }
        let markEvents = (try? await room.stateEvents(
            eventType: stateEventTypeFromString(s: MobileFounderPolicy.markerEventType)
        )) ?? []
        let mark = markEvents.first { $0.stateKey.isEmpty }
        let members = await Self.cachedMembership(room: room)
        let memberIDs = members?
            .filter { $0.value == .join || $0.value == .invite }
            .map(\.key)
            .sorted() ?? []
        return MobileFounderPolicy.RoomCandidate(
            roomID: roomID,
            creatorUserID: create?.sender,
            markerSenderUserID: mark?.sender,
            markerFounderUserID: mark.flatMap { MobileFounderPolicy.roomMark(JSON: $0.contentJson) },
            isJoined: room.membership() == .joined,
            memberCount: UInt64(memberIDs.count),
            memberUserIDs: memberIDs,
            createdAtMilliseconds: create?.timestamp.flatMap { Int64(exactly: $0) },
            membershipKnown: members != nil
        )
    }

    /// Desktop's room-usability rule: this account is joined, and the Founder
    /// is joined or invited. A missing room/membership cache is unknown, not a
    /// left room and never permission to create a replacement.
    func founderRoomUsability(roomID: String, founder: String)
        async -> MobileFounderPolicy.RoomUsability {
        guard let candidate = await founderRoomCandidate(
            roomID: roomID, ownUserID: ticket.session.userID
        ) else { return .unknown }
        return MobileFounderPolicy.roomUsability(candidate, founder: founder)
    }

    /// The oldest room this account created and marked for the same Founder,
    /// with exactly the owner and Founder in it. No heuristic fallback.
    func adoptableFounderRoom(founder: String, ownUserID: String,
                              candidateRoomIDs: [String]) async -> String? {
        var candidates = [MobileFounderPolicy.RoomCandidate]()
        for roomID in candidateRoomIDs {
            guard (try? requireCurrent()) != nil else { return nil }
            if let candidate = await founderRoomCandidate(roomID: roomID, ownUserID: ownUserID) {
                candidates.append(candidate)
            }
        }
        guard (try? requireCurrent()) != nil else { return nil }
        return MobileFounderPolicy.adoptableRoomID(candidates, founder: founder,
                                                   ownUserID: ownUserID)
    }

    /// Membership of a two-person Founder room, joined or invited, from the
    /// SDK cache. `nil` means the cache could not answer, so adoption fails
    /// closed.
    private static func cachedMembership(
        room: Room
    ) async -> [String: MembershipState]? {
        do {
            let iterator = try await room.membersNoSync()
            let maximum = min(Int(iterator.len()), 1_000)
            var result = [String: MembershipState]()
            while result.count < maximum,
                  let chunk = iterator.nextChunk(chunkSize: UInt32(min(100, maximum - result.count))),
                  !chunk.isEmpty {
                for member in chunk {
                    result[member.userId] = member.membership
                }
            }
            return result
        } catch {
            return nil
        }
    }

    /// Current SDK-owned recovery fact for the optional S6 restore row.
    func recoverySnapshot() async throws -> MatrixLiveRecoverySnapshot {
        try requireCurrent()
        let recovery: MatrixLiveRecoveryStatus = switch client.encryption().recoveryState() {
        case .enabled: .ready
        case .incomplete: .available
        case .disabled: .unavailable
        case .unknown: .unknown
        }
        try requireCurrent()
        return MatrixLiveRecoverySnapshot(recovery: recovery)
    }

    /// Import only a key the owner explicitly supplied. The SDK validates it
    /// and downloads the account backup; no device comparison UI is involved.
    func recover(using recoveryKey: String) async throws -> MatrixLiveRecoverySnapshot {
        try await recoverAndPersist(recoveryKey: recoveryKey)
    }

    func pause() async {
        stopObservingRecovery()
        try? await client.pause()
    }

    private func recoverAndPersist(
        recoveryKey: String
    ) async throws -> MatrixLiveRecoverySnapshot {
        let value = recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...MobileOwnerRecoveryProtocol.maximumRecoveryKeyBytes).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (scalar == " " || CharacterSet.alphanumerics.contains(scalar))
              })
        else {
            throw MatrixLiveRuntimeFailure.invalidRecoveryKey
        }

        #if !ATUM_SDK_CANDIDATE_STUDY
        // Stock SDK: the SDK validates the key, keeps the backup key in its own
        // store and reports readiness. The phone-only key journal is a
        // candidate-lane feature and is not written here.
        try requireCurrent()
        try await client.encryption().recover(recoveryKey: value)
        try requireCurrent()
        var lastStockSnapshot: MatrixLiveRecoverySnapshot?
        for _ in 0..<MobileOwnerRecoveryTiming.readinessPollCount {
            try Task.checkCancellation()
            let snapshot = try await recoverySnapshot()
            lastStockSnapshot = snapshot
            if snapshot.recovery == .ready {
                LiveFlowLog.recovery(.readiness, outcome: "ready", code: snapshot.logCode)
                return snapshot
            }
            try await Task.sleep(
                for: .seconds(MobileOwnerRecoveryTiming.readinessPollIntervalSeconds)
            )
        }
        LiveFlowLog.recovery(.readiness, outcome: "timeout", code: lastStockSnapshot?.logCode)
        throw MatrixLiveRuntimeFailure.recoveryNotReady
        #else
        try requireCurrent()
        let recovered = try await client.encryption().recoverWithDetails(
            recoveryKey: value,
            expectedKeyId: nil
        )
        try requireCurrent()
        let input = try MatrixRecoveryInput(recoveryKey: recovered.recoveryKey,
                                            keyID: recovered.keyId,
                                            metadataJSON: recovered.metadataJson)
        // 0.20: sign-in no longer prepares the phone-only key journal, so a
        // missing journal must not undo a key the SDK already accepted.
        do {
            _ = try recoveryStore.replaceAfterVerifiedRecovery(
                input,
                session: ticket,
                sessionStore: sessionStore,
                marker: marker
            )
            LiveFlowLog.session(.recoveryJournal, outcome: "replaced")
        } catch {
            LiveFlowLog.session(.recoveryJournal, outcome: "skipped_" + LiveAuthDiagnostics.code(error))
        }
        var lastSnapshot: MatrixLiveRecoverySnapshot?
        for _ in 0..<MobileOwnerRecoveryTiming.readinessPollCount {
            try Task.checkCancellation()
            let snapshot = try await recoverySnapshot()
            lastSnapshot = snapshot
            if snapshot.recovery == .ready {
                LiveFlowLog.recovery(.readiness, outcome: "ready", code: snapshot.logCode)
                return snapshot
            }
            try await Task.sleep(
                for: .seconds(MobileOwnerRecoveryTiming.readinessPollIntervalSeconds)
            )
        }
        LiveFlowLog.recovery(.readiness, outcome: "timeout", code: lastSnapshot?.logCode)
        throw MatrixLiveRuntimeFailure.recoveryNotReady
        #endif
    }

    #if ATUM_SDK_CANDIDATE_STUDY
    static func prepareRecovery(session: MatrixCustodyTicket,
                                store: MatrixSessionKeychain,
                                marker: OIDCInstallationMarker) throws -> MatrixRecoveryTicket {
        let journal = MatrixRecoveryKeychain()
        return try journal.prepare(session: session, sessionStore: store, marker: marker) {
            let value = try prepareRecoveryKey()
            try validatePreparedRecoveryKey(input: value)
            return try MatrixRecoveryInput(recoveryKey: value.recoveryKey,
                                           keyID: value.keyId,
                                           metadataJSON: value.metadataJson)
        }
    }
    #endif

    private static func sdkSession(_ stored: MatrixStoredSession) throws -> Session {
        let oauth = try JSONSerialization.data(withJSONObject: ["client_id": stored.clientID],
                                               options: .sortedKeys)
        guard let oauthData = String(data: oauth, encoding: .utf8) else {
            throw MatrixLiveRuntimeFailure.identityMismatch
        }
        return Session(accessToken: stored.accessToken,
                       refreshToken: stored.refreshToken,
                       userId: stored.userID,
                       deviceId: stored.deviceID,
                       homeserverUrl: stored.homeserver,
                       oauthData: oauthData,
                       slidingSyncVersion: .native)
    }

    private static func build(paths: MatrixStorePaths, ticket: MatrixCustodyTicket,
                              delegate: MatrixLiveSessionDelegate) async throws -> Client {
        let sqlite = SqliteStoreBuilder(dataPath: paths.data.path,
                                        cachePath: paths.cache.path)
            .passphrase(passphrase: ticket.passphrase)
        return try await ClientBuilder()
            .homeserverUrl(url: ticket.session.homeserver)
            .disableWellKnownLookup(disableWellKnownLookup: true)
            .sqliteStore(config: sqlite)
            .disableAutomaticTokenRefresh()
            .autoEnableCrossSigning(autoEnableCrossSigning: false)
            .autoEnableBackups(autoEnableBackups: false)
            .slidingSyncVersionBuilder(versionBuilder: .native)
            .crossProcessLockConfig(crossProcessLockConfig: .multiProcess(
                holderName: "atum-main-" + ticket.generation.uuidString))
            .setSessionDelegate(sessionDelegate: delegate)
            .requestConfig(config: RequestConfig(retryLimit: 2,
                                                  timeout: 30_000,
                                                  maxConcurrentRequests: 8,
                                                  maxRetryTime: 30_000))
            .build()
    }
}

/// Recovery callbacks may arrive off the main actor. The runtime cancels the
/// handle before pause or replacement.
private final class MatrixLiveRecoveryObserver: RecoveryStateListener, @unchecked Sendable {
    private weak var runtime: MatrixLiveRuntime?

    init(runtime: MatrixLiveRuntime) { self.runtime = runtime }

    func onUpdate(status _: RecoveryState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await runtime?.publishRecoverySnapshot()
        }
    }
}

/// SDK callbacks are synchronous and may arrive off the main actor. During the
/// first local restore no network/sync operation is exposed; after the custody
/// record is promoted, every retrieval rechecks that exact ready envelope.
final class MatrixLiveSessionDelegate: ClientSessionDelegate, @unchecked Sendable {
    let session: Session
    private let lock = NSLock()
    private var authority: (MatrixSessionReader, MatrixCustodyTicket)?
    private var unexpectedMutation = false

    init(session: Session) { self.session = session }

    func activate(reader: MatrixSessionReader, ticket: MatrixCustodyTicket) throws {
        try reader.recheck(ticket)
        lock.withLock { authority = (reader, ticket) }
    }

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard userId == session.userId else { throw MatrixCustodyFailure.invalidIdentity }
        if let current = lock.withLock({ authority }) {
            try current.0.recheck(current.1)
        }
        return session
    }

    func saveSessionInKeychain(session value: Session) {
        guard value != session else { return }
        lock.withLock { unexpectedMutation = true }
    }

    func requireCurrent() throws {
        guard !lock.withLock({ unexpectedMutation }) else {
            throw MatrixLiveRuntimeFailure.unexpectedSessionMutation
        }
        guard let current = lock.withLock({ authority }) else {
            throw MatrixCustodyFailure.interruptedPreparation
        }
        try current.0.recheck(current.1)
    }
}

/// The S3 push lifecycle talks to the live client through this transport.
extension MatrixLiveRuntime: MobilePusherTransport {}
