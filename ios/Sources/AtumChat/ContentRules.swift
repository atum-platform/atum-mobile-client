import Foundation

// B19's decision table on plain values. The app's `ItemMapper` translates the
// SDK's `TimelineItemContent`, `MsgLikeKind`, `MessageType` and `UtdCause`
// case for case into these mirrors (no decisions there); the rules below
// decide every row kind, body and placeholder, so `swift test` proves them.

/// SDK `UtdCause` (`matrix_sdk_crypto.swift`), one case per SDK case, plus
/// `notMegolm` for an undecryptable message that carries no cause (Olm or an
/// unknown scheme).
public enum UndecryptableCause: Equatable, Hashable, Sendable, CaseIterable {
    case unknown
    case sentBeforeWeJoined
    case verificationViolation
    case unsignedDevice
    case unknownDevice
    case historicalMessageAndBackupIsDisabled
    case withheldForUnverifiedOrInsecureDevice
    case withheldBySender
    case historicalMessageAndDeviceIsUnverified
    case notMegolm
}

/// One event's content as plain facts.
public enum ContentFact: Equatable, Sendable {
    // `MsgLikeKind.message`, by `MessageType`.
    case text(body: String)
    case emote(body: String)
    case notice(body: String)
    case image(caption: String?, width: Double?, height: Double?)
    case file(name: String, caption: String?)
    case video(name: String, caption: String?)
    case audio(name: String, caption: String?)
    case location(description: String?, body: String, geoURI: String? = nil)
    case gallery(body: String)
    /// A message type the bindings do not name, with its fallback body.
    case otherMessageType(body: String)
    // Other `MsgLikeKind`s.
    case sticker(body: String)
    case poll(question: String)
    case redacted
    case undecryptable(UndecryptableCause)
    /// A custom message-like event (`MsgLikeKind.other`): no body.
    case customMessageLike
    case liveLocation
    // Other `TimelineItemContent`s.
    case parseFailure
    /// Room state, membership, profile and call events.
    case roomState
}

/// A row's kind, body and edited flag for one event.
public struct RowContent: Equatable, Sendable {
    public var kind: ChatItem.Kind
    public var body: String
    public var isEdited: Bool

    public init(kind: ChatItem.Kind, body: String, isEdited: Bool) {
        self.kind = kind
        self.body = body
        self.isEdited = isEdited
    }
}

public enum ContentRules {
    /// B19: every kind maps to a row; nothing vanishes silently.
    /// - text, emote → text; notice → the quiet line;
    /// - image → a box sized from its info (no download until S4), its
    ///   caption as body; file, video, audio → a file row with its name;
    /// - location → its description, else its body; other message types,
    ///   galleries → their body; stickers → their body; polls → the
    ///   question; all as plain text, or the generic placeholder when the
    ///   body is empty;
    /// - redacted → the deleted placeholder; undecryptable → by cause group;
    /// - custom message-likes, live locations, parse failures → the generic
    ///   placeholder (they carry no body);
    /// - room state and call events → the hidden `roomState` kind.
    /// `isEdited` is the SDK's flag (messages and polls only).
    public static func content(_ fact: ContentFact, isEdited: Bool = false) -> RowContent {
        switch fact {
        case let .text(body), let .emote(body):
            return RowContent(kind: .message, body: body, isEdited: isEdited)
        case let .notice(body):
            return RowContent(kind: .notice, body: body, isEdited: isEdited)
        case let .image(caption, width, height):
            return RowContent(kind: .image(width: width, height: height), body: caption ?? "", isEdited: isEdited)
        case let .file(name, caption), let .video(name, caption), let .audio(name, caption):
            return RowContent(kind: .file(name: name), body: caption ?? "", isEdited: isEdited)
        case let .location(description, body, geoURI):
            let fallback = [description, body, geoURI]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            return text(fallback, isEdited: isEdited)
        case let .gallery(body), let .otherMessageType(body):
            return text(body, isEdited: isEdited)
        case let .sticker(body):
            return text(body, isEdited: false)
        case let .poll(question):
            return text(question, isEdited: isEdited)
        case .redacted:
            return RowContent(kind: .placeholder(.redacted), body: "", isEdited: false)
        case let .undecryptable(cause):
            return RowContent(kind: .placeholder(placeholderReason(cause)), body: "", isEdited: false)
        case .customMessageLike, .liveLocation, .parseFailure:
            return RowContent(kind: .placeholder(.unsupported), body: "", isEdited: false)
        case .roomState:
            return RowContent(kind: .roomState, body: "", isEdited: false)
        }
    }

    /// B19: old history the phone never had keys for ("Tin nhắn cũ không có
    /// trên thiết bị này.") is a message sent before we joined, or a
    /// device-historical one with backup off or this device unverified.
    /// Every other cause is "Không mở được tin nhắn này.".
    public static func placeholderReason(_ cause: UndecryptableCause) -> ChatItem.PlaceholderReason {
        switch cause {
        case .sentBeforeWeJoined, .historicalMessageAndBackupIsDisabled, .historicalMessageAndDeviceIsUnverified:
            return .undecryptableOldHistory
        case .unknown, .verificationViolation, .unsignedDevice, .unknownDevice,
             .withheldForUnverifiedOrInsecureDevice, .withheldBySender, .notMegolm:
            return .undecryptable
        }
    }

    private static func text(_ body: String, isEdited: Bool) -> RowContent {
        body.isEmpty
            ? RowContent(kind: .placeholder(.unsupported), body: "", isEdited: isEdited)
            : RowContent(kind: .message, body: body, isEdited: isEdited)
    }
}
