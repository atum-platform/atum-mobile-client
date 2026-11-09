import Foundation

/// The Atum turn markers a client may read from an agent event
/// (`atum.agent-turns/1.4` A7–A9). Parsed from the SDK's `latestJson()`, which
/// already applies an edit's `m.new_content`; the parser still prefers that
/// object when an edit event is passed whole.
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
        // `latestJson()` is the latest content. An edit event passed whole
        // carries the same marker twice; the new content wins.
        let content = object["m.new_content"] as? [String: Any] ?? object
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
