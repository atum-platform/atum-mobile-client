import AtumChat
import Foundation
import MatrixRustSDK

// Stateless mapping of Matrix SDK timeline values onto the AtumChat contract
// (plan §2.2: `ios/App/Chat/SDK` is the only folder that touches SDK timeline
// types; AtumChat never imports the SDK). Names are checked against the pinned
// bindings, atum-matrix-rust-components-swift 26.10.15-atum.2 (66c18d37, upstream
// components release 26.10.15 plus Atum's patch); `SDK:` lines are
// `matrix_sdk_ffi.swift`, `SDK-ui:` lines `matrix_sdk_ui.swift`, as numbered in the
// 26.10.02 generated file where the names were first checked.
//
// S0 seed for WS1: the stateful, per-TimelineController `ItemMapper` (S1a)
// builds `ChatItem`s with these pieces, picks the display ID (the alias table
// if the S0 probe shows `uniqueId` changing) and maps message content per B19.
// Nothing calls this file yet.

extension ChatDiff {
    /// `TimelineDiff` (`SDK:45556-45576`). Only inserted or set values cross
    /// the mapper (§2.3 rule 3); indices pass through unchanged (rule 4).
    init(_ diff: TimelineDiff, mapping map: (TimelineItem) -> ChatItem) {
        switch diff {
        case let .append(values): self = .append(values.map(map))
        case .clear: self = .clear
        case let .pushFront(value): self = .pushFront(map(value))
        case let .pushBack(value): self = .pushBack(map(value))
        case .popFront: self = .popFront
        case .popBack: self = .popBack
        case let .insert(index, value): self = .insert(index: Int(index), item: map(value))
        case let .set(index, value): self = .set(index: Int(index), item: map(value))
        case let .remove(index): self = .remove(index: Int(index))
        case let .truncate(length): self = .truncate(length: Int(length))
        case let .reset(values): self = .reset(values.map(map))
        }
    }
}

extension ChatEventRef {
    /// `EventOrTransactionId` (`SDK:34720-34725`).
    init(_ id: EventOrTransactionId) {
        switch id {
        case let .eventId(eventId): self = .event(eventId)
        case let .transactionId(transactionId): self = .transaction(transactionId)
        }
    }
}

extension ChatDelivery {
    /// `EventTimelineItem.localSendState` (`EventSendState`,
    /// `SDK:34795-34826`) and `isRemote` (`SDK:21796`). The failure's
    /// `QueueWedgeError` stays here in the app layer; the contract keeps only
    /// `isRecoverable`, which picks the retry call (B8).
    init(_ state: EventSendState?, isRemote: Bool) {
        let local: ChatDelivery?
        switch state {
        case nil: local = nil
        case let .notSentYet(progress)?: local = .sending(progress: progress?.atumNormalizedFraction)
        case let .sendingFailed(_, isRecoverable)?: local = .failed(isRecoverable: isRecoverable)
        case let .sent(eventId)?: local = .sent(eventID: eventId)
        }
        self = ChatDelivery.resolve(local, isRemote: isRemote)
    }
}

extension MediaUploadProgress {
    /// The SDK uses abstract units because encryption may change a payload's
    /// byte size while it uploads. Only a bounded fraction is safe to hand to
    /// the UI; a zero total or an out-of-range producer value becomes S4's
    /// track-only ring.
    var atumNormalizedFraction: Double? {
        let value = progress
        guard value.total > 0, value.current <= value.total else { return nil }
        let fraction = Double(value.current) / Double(value.total)
        return fraction.isFinite && (0...1).contains(fraction) ? fraction : nil
    }
}

extension ChatMedia {
    /// The Matrix SDK owns live media handles. AtumChat gets only a durable,
    /// opaque JSON representation, so a later presentation layer can rebuild
    /// the source with `MediaSource.fromJson(json:)` without retaining FFI
    /// objects in timeline state.
    static func fromTimelineContent(_ content: TimelineItemContent) -> ChatMedia? {
        guard case let .msgLike(messageLike) = content,
              case let .message(message) = messageLike.kind else { return nil }
        switch message.msgType {
        case let .image(image):
            return ChatMedia(sourceHandle: image.source.toJson(),
                             thumbnailSourceHandle: image.info?.thumbnailSource?.toJson(),
                             mimetype: image.info?.mimetype, filename: image.filename,
                             isAnimated: image.info?.isAnimated == true, byteSize: image.info?.size)
        case let .file(file):
            return ChatMedia(sourceHandle: file.source.toJson(),
                             thumbnailSourceHandle: file.info?.thumbnailSource?.toJson(),
                             mimetype: file.info?.mimetype, filename: file.filename,
                             byteSize: file.info?.size)
        case let .video(video):
            return ChatMedia(sourceHandle: video.source.toJson(),
                             thumbnailSourceHandle: video.info?.thumbnailSource?.toJson(),
                             mimetype: video.info?.mimetype, filename: video.filename,
                             byteSize: video.info?.size, nativeKind: .video)
        case let .audio(audio):
            return ChatMedia(sourceHandle: audio.source.toJson(), mimetype: audio.info?.mimetype,
                             filename: audio.filename, byteSize: audio.info?.size,
                             nativeKind: .audio, isVoice: audio.voice != nil)
        case .emote, .gallery, .notice, .text, .location, .other:
            return nil
        }
    }
}

extension ChatItem.Kind {
    /// `VirtualTimelineItem` (`SDK:46534-46554`). `ts` is milliseconds since
    /// the Unix epoch (`Timestamp = UInt64`, `SDK:58446`).
    init(_ virtual: VirtualTimelineItem) {
        switch virtual {
        case let .dateDivider(ts): self = .dayDivider(ChatItem.date(ts))
        case .readMarker: self = .readMarker
        case .timelineStart: self = .timelineStart
        }
    }

    /// Room state and call events the chat never shows (`TimelineItemContent`,
    /// `SDK:45980-45998`). Membership and profile changes are filtered out by
    /// the timeline configuration already (§2.3 rule 1); they are listed so a
    /// filter change cannot turn them into placeholders. Parse failures are
    /// not here: B19 shows them as the generic placeholder.
    static func isRoomState(_ content: TimelineItemContent) -> Bool {
        switch content {
        case .state, .callInvite, .rtcNotification, .roomMembership, .profileChange: true
        case .msgLike, .failedToParseMessageLike, .failedToParseState: false
        }
    }
}

extension ChatItem {
    static func date(_ milliseconds: UInt64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }

    /// §2.3 rule 5: sent from this device. `origin` is `EventItemOrigin`
    /// (`SDK-ui:540-556`); no logic relies on its `.cache` case (B2).
    static func isLocalEcho(_ event: EventTimelineItem) -> Bool {
        let hasTransactionID: Bool
        if case .transactionId = event.eventOrTransactionId { hasTransactionID = true } else { hasTransactionID = false }
        return isLocalEcho(originIsLocal: event.origin == .local,
                           hasLocalSendState: event.localSendState != nil,
                           hasTransactionID: hasTransactionID)
    }

    /// `ProfileDetails.ready(displayName:...)` (`SDK:39955-39959`).
    static func senderName(_ profile: ProfileDetails) -> String? {
        guard case let .ready(displayName, _, _, _, _) = profile else { return nil }
        return displayName
    }

    /// §9.1: the sender's Matrix avatar, for the squircle beside the last
    /// bubble of a run. Nil while the profile has no avatar.
    static func senderAvatarURI(_ profile: ProfileDetails) -> String? {
        guard case let .ready(_, _, avatarUrl, _, _) = profile else { return nil }
        return avatarUrl
    }

    /// `EventTimelineItem.reactions` (`SDK:21805`, `Reaction` `SDK:25614`).
    static func reactions(_ values: [Reaction]) -> [ChatReaction] {
        values.map { ChatReaction(key: $0.key, senderIDs: $0.senders.map(\.senderId)) }
    }

    /// `EventTimelineItem.readReceipts` (`SDK:21822`): who has read up to here.
    static func receiptUserIDs(_ receipts: [String: Receipt]) -> [String] {
        receipts.keys.sorted()
    }

    /// `MsgLikeContent.inReplyTo` (`SDK:23876`, `InReplyToDetails.eventId()`
    /// `SDK:7154`) and `threadRoot` (`SDK:23880`).
    static func relations(_ content: TimelineItemContent) -> (replyTo: String?, threadRoot: String?) {
        guard case let .msgLike(messageLike) = content else { return (nil, nil) }
        return (messageLike.inReplyTo?.eventId(), messageLike.threadRoot)
    }
}
