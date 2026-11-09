import AtumChat
import AtumNativeAPI
import Foundation
import MatrixRustSDK

// The stateful SDK → AtumChat mapper (plan §2.2, §2.3 rules 2, 3, 6, 10;
// B19, B21). One per `TimelineController`, used only by its projector task.
// It composes the stateless pieces of `SDKValueMapping.swift`. Names are
// checked against the pinned bindings (atum-matrix-rust-components-swift
// 26.10.15-atum.2, 66c18d37).

/// What the mapper knows about the room it maps for, fixed when the chat
/// opens.
struct ItemMapperRoom: Sendable {
    let roomID: String
    let context: RoomContext
    /// `Room.latestEncryptionState()` at open: false for a plain room (0.20
    /// agent and bot rooms), true with encryption, nil while unknown. Unknown
    /// is treated as encrypted by the plaintext rule.
    let isEncrypted: Bool?
    /// Server-authored names for the owner's agents and the catalog bots,
    /// keyed by Matrix user ID (`MobileSenderLabelPolicy`).
    let knownNames: [String: String]
    let catalogBotUserIDs: Set<String>
    /// The app's copy language, for a catalog bot's two-language notice
    /// (`MobileAppBotRoomPolicy.noticeLine`, §4.2 item 3).
    let languageCode: String
}

/// One mapped SDK item: the row value plus the facts the contract does not
/// carry yet.
struct MappedItem: Sendable {
    let item: ChatItem
    /// The SDK's `TimelineItem.uniqueId()`, for the S0 identity probe only.
    let uniqueID: String
    /// B21: the quote's details when the item replies to an event.
    let replyDetails: ChatReplyDetails?
    /// A failed send the SDK parked because the server rejected the access
    /// token (`QueueWedgeError.expiredAccessToken`). The SDK only unparks it
    /// through its own token refresh, which this app does not use, so the
    /// controller retries it once on a renewed session (the hotfix rule,
    /// `MobileSendRecoveryPolicy.autoRetriesAfterRenewal`).
    let isTokenParked: Bool
    /// A message sent without encryption into an encrypted room
    /// (`MobilePlaintextEventPolicy`): never shown as a normal message.
    let isHiddenPlaintext: Bool
    /// A failed send's closed failure class and whether the SDK disabled the
    /// queue (`_recoverable`) or parked the request (`_parked`), for the
    /// content-free `send_failed` log line. Nil unless the send failed.
    let sendFailureClass: String?
}

final class ItemMapper {
    private let room: ItemMapperRoom
    private let calendar: Calendar
    private var identities: DisplayIdentityTable

    /// `aliases`: the previous timeline's (`DisplayIdentityTable`), so a
    /// timeline rebuilt on a token renewal keeps every row's ID.
    init(room: ItemMapperRoom, aliases: [String: String] = [:], calendar: Calendar = .current) {
        self.room = room
        self.calendar = calendar
        identities = DisplayIdentityTable(aliases: aliases)
    }

    /// Event ID → display ID of my phone-sent messages, for the next timeline.
    var aliases: [String: String] { identities.aliases }

    /// Before mapping a `reset` or `clear` batch.
    func beginReset() { identities.beginReset() }

    /// After every batch.
    func finishBatch() { identities.finishBatch() }

    func map(_ timelineItem: TimelineItem) -> MappedItem {
        let uniqueID = timelineItem.uniqueId().id
        if let virtual = timelineItem.asVirtual() {
            let kind = ChatItem.Kind(virtual)
            return MappedItem(item: ChatItem(id: identities.id(uniqueID: uniqueID, virtual: kind, calendar: calendar),
                                             kind: kind),
                              uniqueID: uniqueID, replyDetails: nil, isTokenParked: false, isHiddenPlaintext: false,
                              sendFailureClass: nil)
        }
        guard let event = timelineItem.asEvent() else {
            // Neither virtual nor an event: nothing the bindings define today.
            return MappedItem(item: ChatItem(id: identities.id(uniqueID: uniqueID, virtual: nil),
                                             kind: .placeholder(.unsupported)),
                              uniqueID: uniqueID, replyDetails: nil, isTokenParked: false, isHiddenPlaintext: false,
                              sendFailureClass: nil)
        }
        return map(event, uniqueID: uniqueID)
    }

    private func map(_ event: EventTimelineItem, uniqueID: String) -> MappedItem {
        let content = Self.content(event.content)
        let relations = ChatItem.relations(event.content)
        let hiddenPlaintext = isHiddenPlaintext(event, content: content)
        let media = hiddenPlaintext ? nil : ChatMedia.fromTimelineContent(event.content)
        let kind: ChatItem.Kind = hiddenPlaintext ? .roomState : Self.presentationKind(content.kind, media: media)
        let sender = event.sender
        let sentEventID: String? = if case let .sent(eventId)? = event.localSendState { eventId } else { nil }
        let ref = ChatEventRef(event.eventOrTransactionId)
        // agent-turns/1.4 markers come from the SDK's latest content JSON
        // (edits applied). Parse them only for this room's agents, so a
        // stranger cannot make a notice look transient or an interim.
        let markers = room.context.agentUserIDs.contains(sender) && (kind == .notice || kind == .message) &&
            !hiddenPlaintext
            ? AtumTurnMarkers.parse(json: event.lazyProvider.latestJson())
            : AtumTurnMarkers()
        let item = ChatItem(
            // §2.3 rule 2, the one place a row's ID is chosen; the rule is
            // `DisplayIdentityTable` (AtumChat, tested).
            id: identities.id(uniqueID: uniqueID, ref: ref, sentEventID: sentEventID),
            kind: kind,
            sender: sender,
            senderName: MobileSenderLabelPolicy.label(senderID: sender,
                                                      profileDisplayName: ChatItem.senderName(event.senderProfile),
                                                      knownNames: room.knownNames),
            isOwn: event.isOwn,
            isLocalEcho: ChatItem.isLocalEcho(event),
            timestamp: ChatItem.date(event.timestamp),
            delivery: ChatDelivery(event.localSendState, isRemote: event.isRemote),
            eventOrTransactionId: ref,
            body: hiddenPlaintext ? "" : body(content, kind: kind, sender: sender),
            media: media,
            isEdited: content.isEdited,
            replyTo: relations.replyTo,
            threadRoot: relations.threadRoot,
            reactions: ChatItem.reactions(event.reactions),
            receiptUserIDs: ChatItem.receiptUserIDs(event.readReceipts),
            resultFor: ChatItem.resultFor(kind: kind, sender: sender, replyTo: relations.replyTo,
                                          agentUserIDs: room.context.agentUserIDs),
            appBotMeta: appBotMeta(event, kind: kind),
            botAPI: botAPIMessage(event, kind: kind),
            senderAvatarURI: ChatItem.senderAvatarURI(event.senderProfile),
            interim: markers.interim,
            progress: markers.progress
        )
        return MappedItem(item: item, uniqueID: uniqueID,
                          replyDetails: hiddenPlaintext ? nil : replyDetails(event.content),
                          isTokenParked: Self.isTokenParked(event.localSendState),
                          isHiddenPlaintext: hiddenPlaintext,
                          sendFailureClass: event.isOwn ? Self.sendFailureClass(event.localSendState) : nil)
    }

    /// SVGs travel as Matrix `m.image` but must be a file row: homeservers do
    /// not provide usable thumbnails. `MediaKind` owns that MIME decision;
    /// this mapper only changes the already-mapped presentation kind.
    private static func presentationKind(_ kind: ChatItem.Kind, media: ChatMedia?) -> ChatItem.Kind {
        guard case .image = kind, let media,
              !MediaKind.usesImagePresentation(mimetype: media.mimetype, filename: media.filename) else {
            return kind
        }
        return .file(name: media.filename ?? "")
    }

    /// §4.2 item 3 (S1, text only until S5's buttons): in a bot room, a
    /// notice from the room's catalog bot shows the line in the app's
    /// language; everything else shows its body as sent.
    private func body(_ content: RowContent, kind: ChatItem.Kind, sender: String) -> String {
        guard room.context.kind == .appBot else { return content.body }
        return MobileAppBotRoomPolicy.noticeLine(body: content.body,
                                                 senderIsCatalogBot: room.context.agentUserIDs.contains(sender),
                                                 isNotice: kind == .notice, languageCode: room.languageCode)
    }

    // MARK: B19 content (SDK cases → AtumChat's mirrors; `ContentRules` decides)

    /// A row kind, its body and the edited flag for one event's content.
    static func content(_ content: TimelineItemContent) -> RowContent {
        let (fact, isEdited) = Self.fact(content)
        return ContentRules.content(fact, isEdited: isEdited)
    }

    private static func fact(_ content: TimelineItemContent) -> (ContentFact, isEdited: Bool) {
        if ChatItem.Kind.isRoomState(content) { return (.roomState, false) }
        switch content {
        case let .msgLike(messageLike):
            return fact(messageLike.kind)
        case .failedToParseMessageLike, .failedToParseState:
            return (.parseFailure, false)
        case .callInvite, .rtcNotification, .roomMembership, .profileChange, .state:
            return (.roomState, false)
        }
    }

    private static func fact(_ kind: MsgLikeKind) -> (ContentFact, isEdited: Bool) {
        switch kind {
        case let .message(message):
            return (fact(message.msgType), message.isEdited)
        case let .sticker(body, _, _):
            return (.sticker(body: body), false)
        case let .poll(question, _, _, _, _, _, hasBeenEdited):
            return (.poll(question: question), hasBeenEdited)
        case .redacted:
            return (.redacted, false)
        case let .unableToDecrypt(encrypted):
            return (.undecryptable(cause(encrypted)), false)
        case .other:
            return (.customMessageLike, false)
        case .liveLocation:
            return (.liveLocation, false)
        }
    }

    private static func fact(_ type: MessageType) -> ContentFact {
        switch type {
        case let .text(text): .text(body: text.body)
        case let .emote(emote): .emote(body: emote.body)
        case let .notice(notice): .notice(body: notice.body)
        case let .image(image): .image(caption: image.caption, width: image.info?.width.map(Double.init),
                                       height: image.info?.height.map(Double.init))
        case let .file(file): .file(name: file.filename, caption: file.caption)
        case let .video(video): .video(name: video.filename, caption: video.caption)
        case let .audio(audio): .audio(name: audio.filename, caption: audio.caption)
        case let .location(location): .location(description: location.description, body: location.body)
        case let .gallery(gallery): .gallery(body: gallery.body)
        case let .other(_, body): .otherMessageType(body: body)
        }
    }

    /// `UtdCause` (`matrix_sdk_crypto.swift`) case for case; exhaustive, so
    /// an SDK bump that adds a cause fails to compile here.
    private static func cause(_ message: EncryptedMessage) -> UndecryptableCause {
        guard case let .megolmV1AesSha2(_, cause) = message else { return .notMegolm }
        switch cause {
        case .unknown: return .unknown
        case .sentBeforeWeJoined: return .sentBeforeWeJoined
        case .verificationViolation: return .verificationViolation
        case .unsignedDevice: return .unsignedDevice
        case .unknownDevice: return .unknownDevice
        case .historicalMessageAndBackupIsDisabled: return .historicalMessageAndBackupIsDisabled
        case .withheldForUnverifiedOrInsecureDevice: return .withheldForUnverifiedOrInsecureDevice
        case .withheldBySender: return .withheldBySender
        case .historicalMessageAndDeviceIsUnverified: return .historicalMessageAndDeviceIsUnverified
        }
    }

    // MARK: B21 reply details

    private func replyDetails(_ content: TimelineItemContent) -> ChatReplyDetails? {
        guard case let .msgLike(messageLike) = content, let inReplyTo = messageLike.inReplyTo else { return nil }
        let eventID = inReplyTo.eventId()
        let state: ChatReplyDetails.State
        switch inReplyTo.event() {
        case .unavailable:
            state = .unavailable
        case .pending:
            state = .pending
        case .error:
            state = .error
        case let .ready(repliedContent, sender, senderProfile, _, _):
            let mapped = Self.content(repliedContent)
            let name = MobileSenderLabelPolicy.label(senderID: sender,
                                                     profileDisplayName: ChatItem.senderName(senderProfile),
                                                     knownNames: room.knownNames)
            state = .ready(sender: sender, senderName: name,
                           preview: ReplyPreview(kind: mapped.kind, body: mapped.body))
        }
        return ChatReplyDetails(eventID: eventID, state: state)
    }

    // MARK: Plaintext rule, bot metadata, token parking

    /// Rule 10 and `MobilePlaintextEventPolicy`: in a room with encryption
    /// (or not known yet), a message the SDK marks as sent in the clear is
    /// not shown as a normal message. Plain rooms skip `getShields`.
    private func isHiddenPlaintext(_ event: EventTimelineItem, content: RowContent) -> Bool {
        guard room.isEncrypted != false, content.kind.isEventContent, content.kind != .roomState else {
            return false
        }
        let sentInClear: Bool
        if case .red(code: .sentInClear) = event.lazyProvider.getShields(strict: false) {
            sentInClear = true
        } else {
            sentInClear = false
        }
        return !MobilePlaintextEventPolicy.shows(roomEncrypted: room.isEncrypted, sentInClear: sentInClear)
    }

    /// `appBotMeta` (§2.3 rule 6, S5's parser input): the latest JSON of a
    /// notice from a catalog bot in a plain bot room, edits included
    /// (`LazyTimelineItemProvider.latestJson()`). Stored raw; never parsed
    /// here. Everything else carries none.
    private func appBotMeta(_ event: EventTimelineItem, kind: ChatItem.Kind) -> String? {
        guard room.isEncrypted == false, kind == .notice,
              room.catalogBotUserIDs.contains(event.sender) else { return nil }
        return event.lazyProvider.latestJson()
    }

    /// Transport mode never reaches this projection. Every formatted Bot API
    /// body/photo stands on its own latest event envelope from the exact
    /// catalog bot in a plain room; malformed metadata leaves the ordinary
    /// Matrix message intact.
    private func botAPIMessage(_ event: EventTimelineItem, kind: ChatItem.Kind) -> BotAPIMessage? {
        guard room.isEncrypted == false,
              room.catalogBotUserIDs.contains(event.sender) else { return nil }
        switch kind {
        case .message, .image: break
        default: return nil
        }
        guard let latestJSON = event.lazyProvider.latestJson() else { return nil }
        return BotAPIMessage.parse(
            latestJSON: latestJSON,
            authorization: .init(expectedCatalogBotUserID: event.sender,
                                 itemSender: event.sender, roomIsEncrypted: false)
        )
    }

    private static func isTokenParked(_ state: EventSendState?) -> Bool {
        guard case let .sendingFailed(error, isRecoverable)? = state, !isRecoverable,
              case .expiredAccessToken = error else { return false }
        return true
    }

    /// The hotfix's closed classes (raw SDK errors can carry user IDs,
    /// device IDs, MIME types or server text and are never logged).
    private static func sendFailureClass(_ state: EventSendState?) -> String? {
        guard case let .sendingFailed(error, isRecoverable)? = state else { return nil }
        let failure: String = switch error {
        case .crossVerificationRequired: "device_verification_required"
        case .insecureDevices, .identityViolations: "room_devices_unverified"
        case .expiredAccessToken: "token_rejected"
        case .missingMediaContent, .invalidMimeType: "media_unavailable"
        case .genericApiError: "service_unavailable"
        }
        return failure + (isRecoverable ? "_recoverable" : "_parked")
    }
}
