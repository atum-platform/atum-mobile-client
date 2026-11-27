import AtumChat
import AtumNativeAPI
import MatrixRustSDK

enum RoomNotificationFailure: Error {
    case unavailable
    case changeInProgress
    case customPushRules
    /// The Matrix mode succeeded. A retry may still need to retire the legacy preference.
    case legacyPreferenceNotRetired
}

extension LiveAppModel {
    /// Key the caller's observation task by this session's identity and the active room ID.
    var notificationSettingsSession: LiveMatrixSession? {
        guard let liveMatrix, liveMatrix.hasCompletedInitialSync, liveMatrix.isReady,
              (try? liveMatrix.runtime.requireCurrent()) != nil else { return nil }
        return liveMatrix
    }

    /// The chat info sheet's notification menu. Reading it in a view body
    /// observes session readiness, so the sheet re-keys its observation.
    var chatNotificationActions: ChatNotificationActions {
        guard let session = notificationSettingsSession else { return ChatNotificationActions() }
        return ChatNotificationActions(session: .init(
            id: ObjectIdentifier(session),
            observe: { roomID, onChange in
                try await session.observeRoomNotificationSettings(roomID: roomID, onChange: onChange)
            },
            set: { try await session.setRoomNotificationChoice(roomID: $0, choice: $1) },
            legacyLevel: { await session.legacyRoomNotificationLevel(roomID: $0) }
        ))
    }
}

extension LiveMatrixSession {
    func roomNotificationSettings(roomID: String) async throws -> ChatNotificationSettings {
        let room = try notificationRoom(roomID)
        guard let snapshot = try await notificationSnapshot(room: room) else {
            throw RoomNotificationFailure.unavailable
        }
        return snapshot
    }

    /// Runs until the sheet's task is cancelled or the session becomes unavailable.
    /// Register before the first read so a sync racing the opening read is observed.
    func observeRoomNotificationSettings(
        roomID: String, onChange: @MainActor (ChatNotificationSettings) -> Void
    ) async throws {
        let room = try notificationRoom(roomID)
        let settings = await runtime.client.getNotificationSettings()
        let (changes, signal) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let listener = RoomNotificationListener(signal)
        settings.setDelegate(delegate: listener)
        let roomInfo = room.subscribeToRoomInfoUpdates(listener: listener)
        defer {
            roomInfo.cancel()
            settings.setDelegate(delegate: nil)
            signal.finish()
        }

        signal.yield()
        var previous: ChatNotificationSettings?
        for await _ in changes {
            try Task.checkCancellation()
            if let snapshot = try await notificationSnapshot(room: room), snapshot != previous {
                previous = snapshot
                onChange(snapshot)
            }
        }
    }

    func setRoomNotificationChoice(roomID: String, choice: ChatNotificationChoice) async throws {
        let room = try notificationRoom(roomID)
        guard changingRoomNotificationModes.insert(roomID).inserted else {
            throw RoomNotificationFailure.changeInProgress
        }
        defer { changingRoomNotificationModes.remove(roomID) }

        let settings = await runtime.client.getNotificationSettings()
        let rawRules = try await settings.getRawPushRules()
        guard RoomPushRulePolicy.canChangeMode(rawRules: rawRules, roomID: roomID) else {
            throw RoomNotificationFailure.customPushRules
        }
        try requireNotificationRoom(room)
        switch choice {
        case let .set(mode):
            try await settings.setRoomNotificationMode(roomId: roomID, mode: mode.sdkMode)
        case .restoreDefault:
            try await settings.restoreDefaultRoomNotificationMode(roomId: roomID)
        }
        try requireNotificationRoom(room)
        do {
            let create = try await room.stateEvents(eventType: .roomCreate).first { $0.stateKey.isEmpty }
            guard TeamNotificationPolicy.applies(
                toRoomType: MobileRoomTypePolicy.roomType(createContentJSON: create?.contentJson)
            ) else { return }
            try await retireLegacyRoomNotificationPreference(room: room, roomID: roomID)
        } catch {
            throw RoomNotificationFailure.legacyPreferenceNotRetired
        }
    }

    /// ML2 UI integration (read only): a quieter pre-parity channel level that still
    /// narrows an inherited Team Space room, so the menu can show it as the desktop
    /// menu does. Reads the synced store, as the notification extension does; nil
    /// for other rooms, unreadable data or a level that does not narrow.
    func legacyRoomNotificationLevel(roomID: String) async -> ChatNotificationMode? {
        guard let room = try? notificationRoom(roomID),
              let creates = try? await room.stateEvents(eventType: .roomCreate),
              TeamNotificationPolicy.applies(toRoomType: MobileRoomTypePolicy.roomType(
                  createContentJSON: creates.first { $0.stateKey.isEmpty }?.contentJson))
        else { return nil }
        let target = TeamNotificationPolicy.Target.channel(roomID)
        let channel = (try? await runtime.client.accountData(eventType: target.eventType))
            .flatMap { TeamNotificationPolicy.Record.parse($0, for: target) }
        let legacy = (try? await runtime.client.accountData(eventType: TeamNotificationPolicy.legacyType))
            .flatMap(TeamNotificationPolicy.Legacy.parse)
        guard (try? requireNotificationRoom(room)) != nil else { return nil }
        switch TeamNotificationPolicy(roomID: roomID, legacy: legacy, channel: channel).legacyChannel {
        case .mentions: return .mentionsAndKeywords
        case .nothing: return .off
        case .all, nil: return nil
        }
    }

    private func notificationRoom(_ roomID: String) throws -> Room {
        let room = try room(id: roomID)
        try requireNotificationRoom(room)
        return room
    }

    private func requireNotificationRoom(_ room: Room) throws {
        try runtime.requireCurrent()
        guard isReady, hasCompletedInitialSync, room.membership() == .joined, !room.isSpace() else {
            throw RoomNotificationFailure.unavailable
        }
    }

    private func notificationSnapshot(room: Room) async throws -> ChatNotificationSettings? {
        try requireNotificationRoom(room)
        let info = try await room.roomInfo()
        guard info.encryptionState != .unknown else { return nil }
        let encrypted = info.encryptionState == .encrypted
        // The observer and the SDK's in-memory settings listener handle the
        // same sync event independently. Read a fresh settings object from
        // the synced store rather than racing the listener's in-memory update.
        let settings = await runtime.client.getNotificationSettings()
        let value = try await settings.getRoomNotificationSettings(
            roomId: info.id, isEncrypted: encrypted, isOneToOne: info.joinedMembersCount == 2)
        let mentionCaveat = encrypted ? !(await settings.canPushEncryptedEventToDevice()) : false
        try requireNotificationRoom(room)
        try Task.checkCancellation()
        return ChatNotificationSettings(effectiveMode: ChatNotificationMode(value.mode),
                                        isInherited: value.isDefault,
                                        hasEncryptedMentionCaveat: mentionCaveat)
    }

    private func retireLegacyRoomNotificationPreference(room: Room, roomID: String) async throws {
        let target = TeamNotificationPolicy.Target.channel(roomID)
        let current: TeamNotificationPolicy.Record?
        if let json = try await room.fetchGlobalAccountDataRaw(eventType: target.eventType) {
            guard let record = TeamNotificationPolicy.Record.parse(json, for: target) else {
                throw RoomNotificationFailure.legacyPreferenceNotRetired
            }
            guard !record.isInherited else { return }
            current = record
        } else {
            current = nil
            guard let json = try await room.fetchGlobalAccountDataRaw(eventType: TeamNotificationPolicy.legacyType)
            else { return }
            guard let legacy = TeamNotificationPolicy.Legacy.parse(json) else {
                throw RoomNotificationFailure.legacyPreferenceNotRetired
            }
            guard TeamNotificationPolicy(roomID: roomID, legacy: legacy).legacyChannel != nil else { return }
        }

        let revision = current?.revision ?? 0
        let retirement = try TeamNotificationPolicy.Record.retiringChannel(roomID, previousRevision: revision)
        try requireNotificationRoom(room)
        try await runtime.client.setAccountData(eventType: target.eventType, content: retirement)
        guard let json = try await room.fetchGlobalAccountDataRaw(eventType: target.eventType),
              let confirmed = TeamNotificationPolicy.Record.parse(json, for: target),
              confirmed.isInherited, confirmed.revision == revision + 1 else {
            throw RoomNotificationFailure.legacyPreferenceNotRetired
        }
        try requireNotificationRoom(room)
    }
}

private final class RoomNotificationListener: NotificationSettingsDelegate, RoomInfoListener {
    let signal: AsyncStream<Void>.Continuation

    init(_ signal: AsyncStream<Void>.Continuation) { self.signal = signal }

    func settingsDidChange() { signal.yield() }
    func call(roomInfo: RoomInfo) { signal.yield() }
}

private extension ChatNotificationMode {
    init(_ mode: RoomNotificationMode) {
        switch mode {
        case .allMessages: self = .all
        case .mentionsAndKeywordsOnly: self = .mentionsAndKeywords
        case .mute: self = .off
        }
    }

    var sdkMode: RoomNotificationMode {
        switch self {
        case .all: .allMessages
        case .mentionsAndKeywords: .mentionsAndKeywordsOnly
        case .off: .mute
        }
    }
}
