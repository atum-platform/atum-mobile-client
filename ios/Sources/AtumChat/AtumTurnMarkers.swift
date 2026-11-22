import CoreFoundation
import Foundation

/// Marker decoding for a bare Matrix content or the SDK's full latest event.
/// These fields are display facts. Sender and room admission belong to the caller.
public struct AtumTurnMarkers: Equatable, Sendable {
    public var interim: Bool
    public var progress: ChatProgress?
    public var company: CompanyTurnMarker?

    public init(interim: Bool = false, progress: ChatProgress? = nil, company: CompanyTurnMarker? = nil) {
        self.interim = interim
        self.progress = progress
        self.company = company
    }

    /// Use the same mapping for original events and the SDK's replacement view.
    public func apply(to item: inout ChatItem) {
        item.interim = interim
        item.progress = progress
        item.companyTurn = company
    }

    public static func parse(json: String?, originalJSON: String? = nil) -> AtumTurnMarkers {
        guard let envelope = object(json), let outer = content(envelope) else { return AtumTurnMarkers() }
        let replacement = outer["m.new_content"] as? [String: Any]
        guard outer["m.new_content"] == nil || replacement != nil else { return AtumTurnMarkers() }
        let shown = replacement ?? outer
        let original = object(originalJSON)
        let originalContent = original.flatMap(content)
        if CompanyTurnMarker.claimed(shown) || CompanyTurnMarker.claimed(outer)
            || originalContent.map(CompanyTurnMarker.claimed) == true {
            return companyMarkers(envelope, outer: outer, shown: shown, original: original, edited: replacement != nil)
        }

        var markers = AtumTurnMarkers(interim: jsonBool(shown["io.atum.interim"]) == true)
        guard let raw = shown["io.atum.progress"] as? [String: Any] else { return markers }
        var progress = Self.progress(raw, presentation: shown["io.atum.presentation"])
        if raw["profile"] as? String == "atum.agent-turns/1.3", raw["scope"] as? String == "owner_private",
           raw["trigger"] as? String == "cron", shown["msgtype"] as? String == "m.notice",
           progress.phase != .unknown, let kind = progress.kind,
           ["interim", "todo", "heartbeat", "device", "touch_id", "settled"].contains(kind),
           let revision = progress.revision, (0...48).contains(revision) {
            progress.isScheduled = true
            let selected = ChatScheduleExecution.parse(raw["schedule"])
            let first = originalContent?["io.atum.progress"] as? [String: Any]
            if replacement == nil || (first?["trigger"] as? String == "cron"
                && first?["profile"] as? String == "atum.agent-turns/1.3"
                && first?["scope"] as? String == "owner_private"
                && ChatScheduleExecution.parse(first?["schedule"]) == selected) {
                progress.schedule = selected
            }
        }
        markers.progress = progress
        return markers
    }

    static func progress(_ raw: [String: Any], presentation: Any?) -> ChatProgress {
        let phase = (raw["phase"] as? String).flatMap(ChatProgress.Phase.init(rawValue:)) ?? .unknown
        let kind = raw["kind"] as? String
        return ChatProgress(phase: phase, kind: kind, revision: jsonInteger(raw["revision"]),
                            presentation: status(presentation, kind: kind, phase: phase))
    }

    private static func status(_ value: Any?, kind: String?, phase: ChatProgress.Phase) -> ChatProgressPresentation? {
        guard let raw = value as? [String: Any], Set(raw.keys) == ["version", "code", "args"],
              jsonInteger(raw["version"]) == 1, let args = raw["args"] as? [String: Any] else { return nil }
        switch (raw["code"] as? String, kind, phase) {
        case ("tool_activity", "todo", .working):
            guard Set(args.keys) == ["activity"], let code = args["activity"] as? String,
                  let activity = ChatProgressPresentation.Activity(rawValue: code) else { return nil }
            return .toolActivity(activity)
        case ("heartbeat", "heartbeat", .working):
            guard Set(args.keys) == ["elapsed_minutes"], let minutes = jsonInteger(args["elapsed_minutes"]),
                  (1...1_440).contains(minutes) else { return nil }
            return .heartbeat(minutes: minutes)
        case ("approval_wait", "device", .waiting) where args.isEmpty:
            return .approvalWait
        case ("video_consent_required", "device", .waiting) where args.isEmpty:
            return .videoConsentRequired
        default:
            return nil
        }
    }

    private static func companyMarkers(_ envelope: [String: Any], outer: [String: Any],
                                       shown: [String: Any], original: [String: Any]?,
                                       edited: Bool) -> AtumTurnMarkers {
        let at = jsonInteger(envelope["origin_server_ts"]).map { Date(timeIntervalSince1970: Double($0) / 1_000) }
        guard let next = CompanyTurnMarker.parse(shown, at: at),
              let room = next.company?.identity.roomID,
              envelope["room_id"] == nil || envelope["room_id"] as? String == room else { return AtumTurnMarkers() }
        guard let original else { return edited ? AtumTurnMarkers() : next }
        if !edited {
            let originalID = original["event_id"] as? String
            let shownID = envelope["event_id"] as? String
            return originalID == shownID ? next : AtumTurnMarkers()
        }
        guard let firstContent = content(original), let first = CompanyTurnMarker.parse(firstContent, at: nil),
              let sender = envelope["sender"] as? String, sender == original["sender"] as? String,
              CompanyTurnMarker.acceptsEdit(outer, replacement: shown, original: original,
                                            next: next, first: first) else { return AtumTurnMarkers() }
        return next
    }

    private static func object(_ json: String?) -> [String: Any]? {
        guard let json else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    private static func content(_ object: [String: Any]) -> [String: Any]? {
        guard let content = object["content"] else { return object }
        return content as? [String: Any]
    }
}

/// Native identifiers are opaque. The execution key reserves ":" at the host.
public struct ChatScheduleExecution: Equatable, Hashable, Sendable {
    public let job: String
    public let execution: String

    public init?(job: String, execution: String) {
        guard [job, execution].allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 512
        }), !execution.contains(":") else { return nil }
        self.job = job
        self.execution = execution
    }

    public static func == (left: Self, right: Self) -> Bool {
        left.job.utf8.elementsEqual(right.job.utf8) && left.execution.utf8.elementsEqual(right.execution.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(Array(job.utf8))
        hasher.combine(Array(execution.utf8))
    }

    static func parse(_ value: Any?) -> ChatScheduleExecution? {
        guard let raw = value as? [String: Any], Set(raw.keys) == ["job", "execution"],
              let job = raw["job"] as? String, let execution = raw["execution"] as? String else { return nil }
        return ChatScheduleExecution(job: job, execution: execution)
    }
}

func jsonBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}

func jsonInteger(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    return Int(exactly: number.doubleValue)
}
