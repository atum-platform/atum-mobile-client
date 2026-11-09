import Foundation

/// How a row's display ID is chosen (plan §2.3 rule 2). The app's stateful
/// `ItemMapper` keeps one table per timeline and asks it for every item.
///
/// The SDK's `TimelineItem.uniqueId()` is opaque and generated per timeline
/// instance (`TimelineConfiguration.internalIdPrefix` exists "to distinguish
/// different timeline instances from each other"; a new timeline may count
/// from the start again). The phone rebuilds the timeline whenever it renews
/// the 300 s Matrix token, about every four minutes in the foreground, so a
/// display ID must never depend on a unique ID. Therefore:
/// - a remote event is keyed by its event ID;
/// - a local echo is keyed by its transaction ID (the send queue's own ID,
///   the same in every timeline); once its send state names the event ID
///   (`.sent(eventId:)`), that event ID is aliased to the echo's key, so its
///   remote copy keeps the same display ID;
/// - the aliases outlive the timeline: the store hands them to the next
///   table (`init(aliases:)`), so my phone-sent messages keep their IDs
///   across a rebuilt timeline, and an alias outlives its row, so a row paged
///   back in later keeps its ID too;
/// - virtual items are keyed by what they are: a day divider by its calendar
///   day, the read marker and the start header by fixed IDs;
/// - within one timeline an event item keeps the first ID it was given.
///
/// Together these keep every row's ID across the rebuild, so SwiftUI never
/// removes and re-inserts the transcript on a renewal. Two rows can still
/// share an ID for a moment (an echo and its remote copy, or two dividers of
/// one day while the SDK moves them); `Projection` keeps the first.
public struct DisplayIdentityTable: Sendable {
    /// SDK unique ID → the display ID this timeline gave it.
    private var assigned = [String: String]()
    /// Assignments from before a `reset`, reused for items the reset keeps.
    private var retained = [String: String]()
    /// Event ID → the display ID of the local echo it was sent as.
    public private(set) var aliases: [String: String]

    /// `aliases`: the previous timeline's, so a rebuilt timeline keeps the
    /// IDs of messages sent from this phone.
    public init(aliases: [String: String] = [:]) {
        self.aliases = aliases
    }

    /// Prefixes keep the key spaces apart (event IDs start with `$`;
    /// synthetic rows and held sends use `atum.`).
    public static let localPrefix = "local."
    public static let virtualPrefix = "virtual."
    public static let readMarkerID = virtualPrefix + "read-marker"
    public static let timelineStartID = virtualPrefix + "start"

    /// The display ID of a virtual item, from what it is. Day dividers use
    /// the calendar day in `calendar` (the device time zone in the app).
    public static func virtualID(_ kind: ChatItem.Kind, calendar: Calendar = .current) -> String? {
        switch kind {
        case let .dayDivider(date):
            let day = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = day.year, let month = day.month, let dayOfMonth = day.day else { return nil }
            return virtualPrefix + "day." + String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
        case .readMarker:
            return readMarkerID
        case .timelineStart:
            return timelineStartID
        default:
            return nil
        }
    }

    /// The display ID for one event item. `sentEventID` is the event ID a
    /// local echo's `.sent` state carries.
    public mutating func id(uniqueID: String, ref: ChatEventRef, sentEventID: String? = nil) -> String {
        let id: String
        if let existing = assigned[uniqueID] ?? retained[uniqueID] {
            id = existing
        } else {
            switch ref {
            case let .event(eventID):
                id = aliases[eventID] ?? eventID
            case let .transaction(transactionID):
                id = Self.localPrefix + transactionID
            }
        }
        assigned[uniqueID] = id
        if let sentEventID { aliases[sentEventID] = id }
        return id
    }

    /// The display ID for a virtual item (`virtualID`), or for an item the
    /// bindings do not define, keyed by its unique ID.
    public func id(uniqueID: String, virtual kind: ChatItem.Kind?, calendar: Calendar = .current) -> String {
        kind.flatMap { Self.virtualID($0, calendar: calendar) } ?? Self.virtualPrefix + uniqueID
    }

    /// Before mapping a `reset` or `clear` batch: the buffer starts again.
    /// Assignments survive only for items the reset brings back.
    public mutating func beginReset() {
        retained.merge(assigned) { current, _ in current }
        assigned.removeAll(keepingCapacity: true)
    }

    /// After every batch: forget assignments a reset did not bring back.
    /// Aliases stay (one per message sent from this phone while the chat is
    /// open).
    public mutating func finishBatch() {
        retained.removeAll()
    }
}
