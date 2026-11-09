/// What the quote view draws for a reply (B21), from the SDK's
/// `InReplyToDetails.event()` (`.ready`, `.pending`, `.unavailable`,
/// `.error`). The source sends it by the replying item's ID
/// (`ChatTimelineBatch.replyDetails`); the projection puts it on the row
/// (`ChatRow.replyDetails`, contract amendment, S1 day 1).
public struct ChatReplyDetails: Equatable, Hashable, Sendable {
    public enum State: Equatable, Hashable, Sendable {
        /// The SDK has the replied-to event.
        case ready(sender: String, senderName: String?, preview: ReplyPreview)
        /// The SDK is fetching it.
        case pending
        /// Not loaded yet. The store asks the SDK once
        /// (`Timeline.fetchDetailsForEvent`), which turns it into `pending`,
        /// then `ready` or `error`, through ordinary `set` diffs.
        case unavailable
        /// The fetch failed: the quote shows a quiet generic line.
        case error
    }

    /// The replied-to event.
    public var eventID: String
    public var state: State

    public init(eventID: String, state: State) {
        self.eventID = eventID
        self.state = state
    }

    /// Only a reply whose original is not loaded yet needs a fetch.
    public var needsFetch: Bool { state == .unavailable }

    /// The replying events to fetch details for: each remote row whose
    /// details are `unavailable`, once per event (`alreadyRequested`). A
    /// local echo cannot be fetched for (the SDK accepts remote event IDs
    /// only); its details arrive with its remote copy.
    public static func fetchRequests(rows: [ChatRow], alreadyRequested: Set<String>) -> [String] {
        rows.compactMap { row in
            guard row.replyDetails?.needsFetch == true, case let .event(eventID)? = row.item.eventOrTransactionId,
                  !alreadyRequested.contains(eventID) else { return nil }
            return eventID
        }
    }
}

/// The quoted content, reduced to what the quote view draws. Built from the
/// replied-to event with the same B19 mapping as a timeline row.
public enum ReplyPreview: Equatable, Hashable, Sendable {
    /// Text, notice, emote and the text fallbacks of B19 (location,
    /// stickers, polls, other message types): the raw body, never parsed.
    case text(String)
    case image
    case file(name: String)
    case placeholder(ChatItem.PlaceholderReason)
    /// Room state or anything with no content to quote.
    case unsupported

    /// The preview for a replied-to event mapped to a row kind and body.
    public init(kind: ChatItem.Kind, body: String) {
        switch kind {
        case .message, .notice:
            self = .text(body)
        case .image:
            self = .image
        case let .file(name):
            self = .file(name: name)
        case let .placeholder(reason):
            self = .placeholder(reason)
        case .roomState, .dayDivider, .readMarker, .timelineStart, .typing, .loadingEarlier:
            self = .unsupported
        }
    }
}
