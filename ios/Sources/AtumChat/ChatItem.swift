import Foundation

// AtumChat is the pure chat core of the iPhone revamp (plan §2.2). It imports
// no Matrix SDK, SwiftUI or UIKit, so `swift test` proves every rule that
// decides what the person sees. The app layer (`ios/App/Chat/SDK`) maps SDK
// values onto these types; nothing here names an SDK type.

/// One entry of a room's timeline, as plain values (plan §2.3 rule 6).
///
/// The timeline buffer holds one `ChatItem` per SDK `TimelineItem`, at the
/// same index. The projection adds two synthetic kinds (`typing`,
/// `loadingEarlier`) that never enter the buffer.
/// Media facts the pure chat core can carry without importing an SDK. The
/// handles are opaque to AtumChat; the app layer owns their mapping back to
/// Matrix media sources. Byte size is only an upload-limit input and is never
/// presentation copy.
public struct ChatMedia: Equatable, Hashable, Sendable {
    public var sourceHandle: String
    public var thumbnailSourceHandle: String?
    public var mimetype: String?
    public var filename: String?
    public var isAnimated: Bool
    public var byteSize: UInt64?
    /// Native message type survives missing or misleading MIME/filename data.
    public var nativeKind: MediaKind?
    public var isVoice: Bool

    public func presentationKind(fallbackFilename: String? = nil) -> MediaKind {
        nativeKind ?? MediaKind(mimetype: mimetype, filename: filename ?? fallbackFilename)
    }

    public init(sourceHandle: String, thumbnailSourceHandle: String? = nil,
                mimetype: String? = nil, filename: String? = nil,
                isAnimated: Bool = false, byteSize: UInt64? = nil,
                nativeKind: MediaKind? = nil, isVoice: Bool = false) {
        self.sourceHandle = sourceHandle
        self.thumbnailSourceHandle = thumbnailSourceHandle
        self.mimetype = mimetype
        self.filename = filename
        self.isAnimated = isAnimated
        self.byteSize = byteSize
        self.nativeKind = nativeKind
        self.isVoice = isVoice
    }
}

public struct ChatItem: Identifiable, Equatable, Hashable, Sendable {
    /// Stable display identity (§2.3 rule 2), chosen in one place,
    /// `DisplayIdentityTable`, and never the SDK's raw
    /// `TimelineItem.uniqueId()`, which is generated per timeline instance
    /// (the phone rebuilds its timeline on every token renewal):
    /// - a remote event: its event ID;
    /// - a local echo: `local.<transaction ID>`; once its send state names
    ///   the event ID, that event ID is aliased to this key, so the remote
    ///   copy keeps the row's ID, and the aliases are handed to the next
    ///   timeline;
    /// - a virtual item, by what it is (`virtual.` prefix): a day divider by
    ///   its calendar day, the read marker and the start header by fixed IDs;
    /// - a held send (no timeline attached): `atum.held.<n>`; the synthetic
    ///   typing and loading rows: `atum.` IDs (`Projection`).
    /// Scripted items keep the fixed IDs their scenario gives them.
    /// (Contract amendment, S1 day 1.)
    public var id: String
    public var kind: Kind
    /// Matrix user ID of the sender. Empty for virtual and synthetic rows.
    public var sender: String
    /// The sender's display name when the SDK has a ready profile.
    public var senderName: String?
    /// Sent by this Matrix account, from any device. Styles only: follow and
    /// pill rules never read it (the Mac and the phone are the same user).
    public var isOwn: Bool
    /// Sent from this device (`origin == .local`, a local send state or a
    /// transaction ID). The only flag FollowPolicy reads for "my send".
    public var isLocalEcho: Bool
    public var timestamp: Date
    public var delivery: ChatDelivery
    /// Event ID once the server has it, else the local transaction ID.
    public var eventOrTransactionId: ChatEventRef?
    /// The message text as typed, for text, notice and emote kinds; the
    /// fallback body where a placeholder has one; empty otherwise.
    ///
    /// Rule 6 lists `body (parsed)`. The contract keeps the raw text here
    /// (Copy copies it; my plain-text sends show it literally) and puts the
    /// parsed form in the app layer, because it is a rendering type AtumChat
    /// cannot name: the store's projector Task parses markdown off the main
    /// actor once per `(id, body)` into a cache it publishes together with
    /// the snapshot (rule 3), and row views look the parsed body up by
    /// `(id, body)`. No view parses in `body` (§2.6).
    public var body: String
    /// Image/file download inputs. Nil for text, notices, placeholders and
    /// legacy scripted media boxes that do not exercise S4 loading.
    public var media: ChatMedia?
    public var isEdited: Bool
    /// Event ID this message replies to (`MsgLikeContent.inReplyTo`).
    public var replyTo: String?
    /// Thread root event ID. Thread messages always show their quote (B21,
    /// desktop `message.thread`); added to the rule-6 list for that rule.
    public var threadRoot: String?
    public var reactions: [ChatReaction]
    /// Users whose read receipt sits on this item, sorted.
    public var receiptUserIDs: [String]
    /// The event a text answer from the room's agent or bot replies to
    /// (B17, B21). Derived from `replyTo` with `ChatItem.resultFor(...)`.
    public var resultFor: String?
    /// Raw `io.atum.app_bot` JSON, read only for catalog-bot senders in plain
    /// bot rooms (S5). Never parsed here.
    public var appBotMeta: String?
    /// Strict per-message Bot API presentation metadata. Catalog transport
    /// mode never populates this; the SDK mapper requires the exact catalog
    /// bot sender and `io.atum.bot_api/1` envelope for every message.
    public var botAPI: BotAPIMessage?
    /// The sender's Matrix avatar URI (`ProfileDetails.avatarUrl`), for the
    /// squircle beside the last bubble of an incoming run (§9.1). Nil when
    /// the profile has no avatar.
    public var senderAvatarURI: String?
    /// `io.atum.interim: true`: the agent's mid-turn remark is a real message
    /// (agent-turns/1.4 A9). It never ends a working line's turn and is never
    /// the answer for the no-answer line.
    public var interim: Bool
    /// The `io.atum.progress` marker on a working-line notice (agent-turns/1.4
    /// A7/A8). Nil for every other row.
    public var progress: ChatProgress?

    public init(id: String, kind: Kind, sender: String = "", senderName: String? = nil,
                isOwn: Bool = false, isLocalEcho: Bool = false,
                timestamp: Date = Date(timeIntervalSince1970: 0),
                delivery: ChatDelivery = .remote, eventOrTransactionId: ChatEventRef? = nil,
                body: String = "", media: ChatMedia? = nil, isEdited: Bool = false, replyTo: String? = nil,
                threadRoot: String? = nil, reactions: [ChatReaction] = [],
                receiptUserIDs: [String] = [], resultFor: String? = nil,
                appBotMeta: String? = nil, botAPI: BotAPIMessage? = nil,
                senderAvatarURI: String? = nil,
                interim: Bool = false, progress: ChatProgress? = nil) {
        self.id = id
        self.kind = kind
        self.sender = sender
        self.senderName = senderName
        self.isOwn = isOwn
        self.isLocalEcho = isLocalEcho
        self.timestamp = timestamp
        self.delivery = delivery
        self.eventOrTransactionId = eventOrTransactionId
        self.body = body
        self.media = media
        self.isEdited = isEdited
        self.replyTo = replyTo
        self.threadRoot = threadRoot
        self.reactions = reactions
        self.receiptUserIDs = receiptUserIDs
        self.resultFor = resultFor
        self.appBotMeta = appBotMeta
        self.botAPI = botAPI
        self.senderAvatarURI = senderAvatarURI
        self.interim = interim
        self.progress = progress
    }

    /// What a row is (plan §2.2: message | notice | image | file |
    /// placeholder | dayDivider | readMarker | timelineStart | typing |
    /// loadingEarlier, plus `roomState`).
    public enum Kind: Equatable, Hashable, Sendable {
        /// `m.text` and `m.emote` (an emote shows as text, B19).
        case message
        /// `m.notice`: one quiet centred line (B17).
        case notice
        /// Sized from `ImageInfo` so the row never changes height (B19).
        case image(width: Double?, height: Double?)
        case file(name: String)
        case placeholder(PlaceholderReason)
        /// An item that takes an SDK index but never shows. They stay in the
        /// buffer for index alignment; the projection always hides them, and
        /// the pill never counts them.
        /// - Room state and call events (SDK `TimelineItemContent.state`,
        ///   `.callInvite`, `.rtcNotification`): the timeline filter excludes
        ///   only membership and profile changes (§2.3 rule 1), so room
        ///   creation, name, topic, power-level and encryption events still
        ///   take indices.
        /// - A message sent in the clear into an encrypted room
        ///   (`MobilePlaintextEventPolicy`, rule 10): mapped here with an
        ///   empty body, so it is never shown as a normal message (contract
        ///   amendment, S1 day 1).
        case roomState
        /// SDK `VirtualTimelineItem.dateDivider(ts:)`.
        case dayDivider(Date)
        case readMarker
        case timelineStart
        /// Synthetic last row while a real `m.typing` is active (B10).
        case typing(names: [String])
        /// Synthetic first row while older history loads (B5, S1b).
        case loadingEarlier

        /// SDK virtual items: date dividers, the read marker, the start.
        public var isVirtual: Bool {
            switch self {
            case .dayDivider, .readMarker, .timelineStart: true
            default: false
            }
        }

        /// Rows added by the projection, never present in the buffer.
        public var isSynthetic: Bool {
            switch self {
            case .typing, .loadingEarlier: true
            default: false
            }
        }

        /// Something a person (or agent) sent: what sender lines, quotes and
        /// the jump pill are about.
        public var isEventContent: Bool { !isVirtual && !isSynthetic }
    }

    /// Why a row shows a placeholder instead of content (B19). One
    /// fixed-height line. The words come from the exported copy, by key
    /// (atum-app `apps/desktop/src/matrix/mobile-copy.ts`); none is
    /// written here, so this comment cannot drift from the export.
    public enum PlaceholderReason: Equatable, Hashable, Sendable {
        /// Kinds with no body (`MsgLikeKind.other`, `.liveLocation`,
        /// parse failures): `src.matrix.mobile-copy.mobileChatCopy.placeholder.unsupported`.
        case unsupported
        /// A deleted message:
        /// `src.matrix.mobile-copy.mobileChatCopy.placeholder.redacted`.
        case redacted
        /// `UtdCause` says old history (sent before we joined, or backup
        /// and verification missing):
        /// `src.matrix.mobile-copy.mobileChatCopy.placeholder.undecryptableOldHistory`.
        case undecryptableOldHistory
        /// Every other cause:
        /// `src.matrix.mobile-copy.mobileChatCopy.placeholder.undecryptable`.
        case undecryptable
    }

    /// The server event ID, once known. A local echo keeps its transaction
    /// ID as `eventOrTransactionId` until its remote copy replaces it, but
    /// `.sent(eventID:)` already carries the event ID: replies and receipts
    /// that point at it must match in that window (B21 quotes, B7 Seen).
    public var eventID: String? {
        if case let .event(id) = eventOrTransactionId { return id }
        if case let .sent(id) = delivery { return id }
        return nil
    }

    /// Counted by the jump pill (B4): content from anyone except this
    /// device. Notices, virtual and synthetic rows never count.
    public var countsAsNewMessage: Bool {
        guard !isLocalEcho else { return false }
        switch kind {
        case .message, .image, .file, .placeholder: return true
        default: return false
        }
    }

    /// The agent posted an `io.atum.progress` working line (agent-turns/1.4).
    public var isProgressLine: Bool { progress != nil }

    /// SDK redaction. A redacted agent message renders nothing (1.4 A7): the
    /// agent removes only its own working lines and a duplicated interim
    /// remark, never a person's message.
    public var isRedacted: Bool {
        if case .placeholder(.redacted) = kind { return true }
        return false
    }

    /// B17/B21: a text message from the room's agent or bot that replies to
    /// an event is that event's result. Notices are status lines, never
    /// results.
    public static func resultFor(kind: Kind, sender: String, replyTo: String?,
                                 agentUserIDs: Set<String>) -> String? {
        guard kind == .message, agentUserIDs.contains(sender) else { return nil }
        return replyTo
    }

    /// §2.3 rule 5: sent from this device. Never inferred from `isOwn`.
    public static func isLocalEcho(originIsLocal: Bool, hasLocalSendState: Bool,
                                   hasTransactionID: Bool) -> Bool {
        originIsLocal || hasLocalSendState || hasTransactionID
    }
}

/// SDK `EventOrTransactionId` as a plain value.
public enum ChatEventRef: Equatable, Hashable, Sendable {
    case event(String)
    case transaction(String)
}

/// Where a message is on its way to the server (SDK `EventSendState`,
/// `SDK:34795-34826`). Only the facts the UI needs: the failure's error
/// payload stays in the app layer.
public enum ChatDelivery: Equatable, Hashable, Sendable {
    /// From the server, with no local send state (anyone's message,
    /// including mine from another device).
    case remote
    /// `.notSentYet`: queued or uploading. Nil means the SDK has no bounded
    /// upload fraction; S4 draws a ring only for a finite 0...1 value.
    case sending(progress: Double? = nil)
    /// `.sent(eventId:)`: the server accepted it.
    case sent(eventID: String)
    /// `.sendingFailed(isRecoverable:)`: recoverable failures disabled the
    /// room's queue; unrecoverable ones parked the request (B8).
    case failed(isRecoverable: Bool)

    /// A ring is valid only for a finite, normalized SDK fraction. Invalid
    /// producer values fall back to the ordinary track-only sending state.
    public var uploadProgress: Double? {
        guard case let .sending(progress?) = self, progress.isFinite,
              (0...1).contains(progress) else { return nil }
        return progress
    }

    /// An item with no local send state is settled if it is remote and
    /// still sending otherwise (the hotfix's rule for local echoes).
    public static func resolve(_ localState: ChatDelivery?, isRemote: Bool) -> ChatDelivery {
        localState ?? (isRemote ? .remote : .sending())
    }
}

/// One reaction key and who reacted (SDK `Reaction`).
public struct ChatReaction: Equatable, Hashable, Sendable {
    public var key: String
    public var senderIDs: [String]

    public init(key: String, senderIDs: [String]) {
        self.key = key
        self.senderIDs = senderIDs
    }

    public var count: Int { senderIDs.count }

    public func includes(_ userID: String) -> Bool { senderIDs.contains(userID) }
}

/// The `io.atum.progress` marker on an agent's working line
/// (`atum.agent-turns/1.4` A2/A7/A8). Only the phase decides what a client
/// does: `settled` hides the line even before the publisher's redaction.
public struct ChatProgress: Equatable, Hashable, Sendable {
    public enum Phase: String, Equatable, Hashable, Sendable {
        case working
        case waiting
        case settled
        /// A marker with a phase this build does not know: treat it as live
        /// rather than deleting a working line early.
        case unknown
    }

    public var phase: Phase
    /// `kind` and `revision` are carried for tests and future presentation;
    /// the transient rule reads `phase` only.
    public var kind: String?
    public var revision: Int?

    public init(phase: Phase, kind: String? = nil, revision: Int? = nil) {
        self.phase = phase
        self.kind = kind
        self.revision = revision
    }
}
