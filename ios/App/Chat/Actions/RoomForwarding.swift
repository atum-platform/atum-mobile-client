import AtumChat
import AtumNativeAPI
import Foundation
import MatrixRustSDK

@MainActor
final class RoomForwarding {
    struct Target: Identifiable, Equatable {
        let id: String
        let name: String
        let avatarURL: String?
        let isEncrypted: Bool
        let refusal: ForwardFailure?
    }

    enum Receipt: Equatable {
        case sent(eventID: String)
        case queuedAttachment
    }

    let preview: ForwardContent
    private let timeline: Timeline
    private let eventID: String
    private let source: Room
    private let session: LiveMatrixSession
    private let scope: (LiveMatrixRoomRow, Bool) -> ForwardRoomScope
    private let isCurrent: () -> Bool
    private var inFlight = Set<String>()
    private var receipts = [String: Receipt]()
    private var unconfirmed = Set<String>()

    init(source: Room, eventID: String, timeline: Timeline, preview: ForwardContent,
         session: LiveMatrixSession, scope: @escaping (LiveMatrixRoomRow, Bool) -> ForwardRoomScope,
         isCurrent: @escaping () -> Bool) {
        self.source = source
        self.eventID = eventID
        self.timeline = timeline
        self.preview = preview
        self.session = session
        self.scope = scope
        self.isCurrent = isCurrent
    }

    /// Reads send powers and membership from the same joined rooms the phone
    /// already syncs. Search is local to the picker, over these rows.
    func targets(matching query: String = "") async throws -> [Target] {
        try checkSession()
        let sourceScope = scopeFor(roomID: source.id(), destination: false)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = session.rooms.sorted {
            if $0.latestTimestamp != $1.latestTimestamp {
                return ($0.latestTimestamp ?? 0) > ($1.latestTimestamp ?? 0)
            }
            return $0.displayName.localizedCompare($1.displayName) == .orderedAscending
        }
        var result = [Target]()
        for row in rows {
            try checkSession()
            let name = row.privateTitle ?? row.displayName
            if !needle.isEmpty, (name + " " + row.displayName).range(
                of: needle, options: [.caseInsensitive, .diacriticInsensitive], locale: .current
            ) == nil { continue }
            guard sourceScope.allowsForward(to: scope(row, true)),
                  let room = try? session.room(id: row.roomID), await Self.canSend(in: room),
                  let encrypted = await SDKTimelineSource.encryption(of: room) else { continue }
            let refusal: ForwardFailure? = preview.isEncryptedAttachment && !encrypted ? .encryptedAttachment : nil
            result.append(Target(id: row.roomID, name: name, avatarURL: row.heroAvatarURL ?? row.avatarURL,
                                 isEncrypted: encrypted, refusal: refusal))
        }
        try checkSession()
        return result
    }

    /// Per-picker idempotency for successful actions. Raw sends have no
    /// caller-supplied transaction ID in this binding. A transport failure
    /// after submitting a write is ambiguous, so this picker never repeats it.
    func send(to roomID: String) async throws -> Receipt {
        try checkSession()
        if let receipt = receipts[roomID] { return receipt }
        guard !unconfirmed.contains(roomID) else { throw ForwardFailure.deliveryUnconfirmed }
        guard inFlight.insert(roomID).inserted else { throw ForwardFailure.sendInProgress }
        defer { inFlight.remove(roomID) }

        let current = try await Self.content(in: timeline, eventID: eventID)
        guard current == preview else { throw ForwardFailure.sourceChanged }
        let destination = try session.room(id: roomID)
        let (sourceEncrypted, destinationEncrypted) = try await validate(destination: destination)
        let transfer = try current.transfer(sourceEncrypted: sourceEncrypted, destinationEncrypted: destinationEncrypted)
        let receipt: Receipt
        switch transfer {
        case .reuse:
            do {
                receipt = .sent(eventID: try await destination.sendRaw(eventType: "m.room.message", content: current.json))
            } catch {
                unconfirmed.insert(roomID)
                throw ForwardFailure.deliveryUnconfirmed
            }
        case .encryptAndUpload:
            guard let uri = current.plainMediaURI else { throw ForwardFailure.invalidEvent }
            let client = session.runtime.client
            let limit = try await client.getMaxMediaUploadSize()
            if let size = current.byteSize, size > limit { throw ForwardFailure.failed }
            let mime = current.mimetype ?? "application/octet-stream"
            let name = current.filename ?? current.body
            let file = try await client.getMediaFile(mediaSource: MediaSource.fromUrl(url: uri),
                                                    filename: nil, mimeType: mime, useCache: false, tempDir: nil)
            let path = try file.path()
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attributes[.size] as? NSNumber)?.uint64Value, size <= limit
            else { throw ForwardFailure.failed }
            let destinationTimeline = try await destination.timeline()
            let latest = try await Self.content(in: timeline, eventID: eventID)
            guard latest == current else { throw ForwardFailure.sourceChanged }
            let (sourceEncryptedNow, destinationEncryptedNow) = try await validate(destination: destination)
            guard !sourceEncryptedNow, destinationEncryptedNow else { throw ForwardFailure.forbidden }
            let parameters = UploadParameters(
                source: .file(filename: path), caption: current.filename == nil ? nil : current.body,
                formattedCaption: current.formattedBody.map { FormattedBody(format: .html, body: $0) },
                mentions: Mentions(userIds: [], room: false), inReplyTo: nil,
                extraContentJson: current.attachmentExtraJSON
            )
            let attachment: AttachmentKind = switch current.kind {
            case .image:
                .image(imageInfo: ImageInfo(height: current.height, width: current.width, mimetype: mime, size: size,
                                            thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: nil),
                       thumbnailSource: nil)
            case .file:
                .file(fileInfo: FileInfo(mimetype: mime, size: size, thumbnailInfo: nil, thumbnailSource: nil))
            case .text:
                throw ForwardFailure.invalidEvent
            }
            // Keep the native file alive until the SDK ingests it. Stage a
            // named copy only if the download's basename would change it.
            var upload = parameters
            if URL(fileURLWithPath: path).lastPathComponent != name {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                defer { try? FileManager.default.removeItem(at: directory) }
                let basename = URL(fileURLWithPath: name).lastPathComponent
                guard !basename.isEmpty, basename != ".", basename != "..",
                      !basename.contains("/"), !basename.contains("\u{0}") else { throw ForwardFailure.invalidEvent }
                let staging = directory.appendingPathComponent(basename)
                try FileManager.default.copyItem(atPath: path, toPath: staging.path)
                upload.source = .file(filename: staging.path)
                try checkSession()
                receipt = try await enqueueAttachment(on: destinationTimeline, upload: upload, attachment: attachment,
                                                      roomID: roomID)
            } else {
                receipt = try await enqueueAttachment(on: destinationTimeline, upload: upload, attachment: attachment,
                                                      roomID: roomID)
            }
            withExtendedLifetime(file) {}
        }
        receipts[roomID] = receipt
        return receipt
    }

    private func enqueueAttachment(on timeline: Timeline, upload: UploadParameters,
                                   attachment: AttachmentKind, roomID: String) async throws -> Receipt {
        let handle = try timeline.sendAttachment(params: upload, attachment: attachment)
        do {
            try await handle.join()
        } catch {
            // The native timeline may already have a failed echo with retry
            // state. Sending afresh could duplicate it.
            unconfirmed.insert(roomID)
            throw ForwardFailure.deliveryUnconfirmed
        }
        return .queuedAttachment
    }

    private func checkSession() throws {
        try Task.checkCancellation()
        guard isCurrent(), source.membership() == .joined else { throw ForwardFailure.unavailable }
        try session.runtime.requireCurrent()
    }

    private func scopeFor(roomID: String, destination: Bool) -> ForwardRoomScope {
        guard let row = session.rooms.first(where: { $0.roomID == roomID }) else { return .unavailable }
        return scope(row, destination)
    }

    private func validate(destination: Room) async throws -> (Bool, Bool) {
        try checkSession()
        guard await Self.canSend(in: destination),
              let sourceEncrypted = await SDKTimelineSource.encryption(of: source),
              let destinationEncrypted = await SDKTimelineSource.encryption(of: destination)
        else { throw ForwardFailure.unavailable }
        let sourceScope = scopeFor(roomID: source.id(), destination: false)
        guard sourceScope.allowsForward(to: scopeFor(roomID: destination.id(), destination: true)),
              destination.membership() == .joined, destination.successorRoom() == nil,
              destination.encryptionState() != .encrypted || destinationEncrypted
        else { throw ForwardFailure.forbidden }
        try checkSession()
        return (sourceEncrypted, destinationEncrypted)
    }

    private static func canSend(in room: Room) async -> Bool {
        guard room.membership() == .joined, !room.isSpace(), room.successorRoom() == nil,
              let levels = try? await room.getPowerLevels() else { return false }
        return (try? levels.canUserSendMessage(userId: room.ownUserId(), message: .roomMessage)) == true
    }

    static func content(in timeline: Timeline, eventID: String) async throws -> ForwardContent {
        let event = try await timeline.getEventTimelineItemByEventId(eventId: eventID)
        guard event.isRemote, event.editSendState == nil, event.redactionSendState == nil,
              case .msgLike(let like) = event.content, case .message = like.kind,
              let latest = event.lazyProvider.latestJson() else { throw ForwardFailure.invalidEvent }
        let original = event.lazyProvider.debugInfo().originalJson ?? latest
        return try ForwardContent(originalEvent: original, latestEvent: latest)
    }
}

extension LiveAppModel {
    func roomForwardMenuContext(roomID: String) -> ForwardMenuContext? {
        guard let session = liveMatrix, let row = session.rooms.first(where: { $0.roomID == roomID }),
              forwardScope(row, destination: false) != .unavailable else { return nil }
        return ForwardMenuContext(canOpenPicker: session.isReady && (try? session.runtime.requireCurrent()) != nil)
    }

    func prepareForward(roomID: String, eventID: String,
                        stillCurrent: @escaping @MainActor () -> Bool) async throws -> RoomForwarding {
        guard MessageMenuRules.isPinEventID(eventID), let session = liveMatrix,
              stillCurrent(),
              let row = session.rooms.first(where: { $0.roomID == roomID }),
              let room = try? session.room(id: roomID), room.membership() == .joined,
              forwardScope(row, destination: false) != .unavailable
        else { throw ForwardFailure.unavailable }
        var configuration = SDKTimelineSource.configuration
        configuration.focus = .event(eventId: eventID, numContextEvents: 5,
                                     threadMode: .automatic(hideThreadedEvents: false))
        configuration.trackReadReceipts = .disabled
        let timeline = try await room.timelineWithConfiguration(configuration: configuration)
        let content = try await RoomForwarding.content(in: timeline, eventID: eventID)
        try Task.checkCancellation()
        guard liveMatrix === session, stillCurrent() else { throw ForwardFailure.unavailable }
        try session.runtime.requireCurrent()
        return RoomForwarding(source: room, eventID: eventID, timeline: timeline, preview: content, session: session,
                              scope: { [weak self] row, destination in
                                  self?.forwardScope(row, destination: destination) ?? .unavailable
                              }, isCurrent: { [weak self, weak session] in
                                  session != nil && self?.liveMatrix === session && stillCurrent()
                              })
    }

    private func forwardScope(_ row: LiveMatrixRoomRow, destination: Bool) -> ForwardRoomScope {
        guard row.hasCreateState, row.legacyAppBotMove == nil else { return .unavailable }
        switch companyWorkspace.roomClassification(row.roomID) {
        case .company(let claim):
            if destination {
                guard companyWorkspace.channelsByCompany[claim.companyID]?.channels.contains(where: {
                    $0.room.roomId == row.roomID && $0.room.state == "ready" && $0.channel.state == .active
                }) == true else { return .unavailable }
            }
            return .company(claim.companyID)
        case .conversation(let claim):
            if destination {
                let conversations = companyWorkspace.conversations
                guard claim.state == .active, conversations.isFresh(roomID: row.roomID),
                      conversations.conversation(roomID: row.roomID)?.hidden == false
                else { return .unavailable }
            }
            return .company(claim.companyID)
        case .privateCos, .notesSelf, .quarantined:
            return .unavailable
        case .personal, .unknown:
            guard let own = try? liveMatrix?.companyOwnUserID(),
                  let info = conversationInfo(roomID: row.roomID, title: row.displayName, ownUserID: own)
            else { return .unavailable }
            if destination, info.context.kind == .appBot { return .unavailable }
            if row.roomType == "io.atum.assistant", row.memberCount == 2, info.context.kind == .assistant {
                return .ownAssistant
            }
            // Unknown typed rooms may carry company ownership even before the
            // directory has caught up. A custom type alone grants no scope.
            return row.roomType == nil && companyWorkspace.personalChatRestoreClassification(row.roomID) == .personal
                ? .personal : .unavailable
        }
    }
}
