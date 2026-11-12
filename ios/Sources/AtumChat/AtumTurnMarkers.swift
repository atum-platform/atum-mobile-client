import Foundation

/// The Atum turn markers a client may read from an agent event
/// (`atum.agent-turns/1.4` A7–A9). The SDK's `latestJson()` is a full event
/// envelope, including edits. Unwrap `content`, then prefer `m.new_content`.
/// Bare content is also accepted for callers already holding decoded content.
///
/// The markers are presentation facts only. They never confer execution
/// authority and never change what a sender is.
public struct AtumTurnMarkers: Equatable, Sendable {
    /// `io.atum.interim: true`: an agent's real mid-turn remark.
    public var interim = false
    /// `io.atum.progress`: the one working-line notice of a turn.
    public var progress: ChatProgress?

    public init(interim: Bool = false, progress: ChatProgress? = nil) {
        self.interim = interim
        self.progress = progress
    }

    /// Parse the content JSON. A marker this build cannot read (a non-object,
    /// a wrong type) is ignored rather than guessed.
    public static func parse(json: String?) -> AtumTurnMarkers {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return AtumTurnMarkers()
        }
        // The pinned SDK explicitly returns the FULL raw event, not only its
        // content. An edit carries a replacement payload inside that content.
        // Never fall back to original markers when a replacement omits them.
        let eventContent: [String: Any]
        if let raw = object["content"] {
            guard let content = raw as? [String: Any] else { return AtumTurnMarkers() }
            eventContent = content
        } else {
            eventContent = object
        }
        let content: [String: Any]
        if let raw = eventContent["m.new_content"] {
            guard let replacement = raw as? [String: Any] else { return AtumTurnMarkers() }
            content = replacement
        } else {
            content = eventContent
        }
        var markers = AtumTurnMarkers()
        if let value = content["io.atum.interim"] as? Bool, value {
            markers.interim = true
        }
        if let raw = content["io.atum.progress"] as? [String: Any] {
            let phase = ChatProgress.Phase(rawString: raw["phase"] as? String)
            let revision = (raw["revision"] as? NSNumber)?.intValue
            markers.progress = ChatProgress(phase: phase,
                                            kind: raw["kind"] as? String,
                                            revision: revision)
        }
        return markers
    }
}

extension ChatProgress.Phase {
    init(rawString: String?) {
        switch rawString {
        case "working": self = .working
        case "waiting": self = .waiting
        case "settled": self = .settled
        default: self = .unknown
        }
    }
}
