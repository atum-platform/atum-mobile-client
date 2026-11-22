import Foundation

/// The company room's platform-proven agent and audience. The app supplies
/// this from the current joined-room binding, never from a timeline event.
public struct CompanyTurnBinding: Equatable, Hashable, Sendable {
    public enum Audience: Equatable, Hashable, Sendable {
        case channel(id: String)
        case privateCos(memberPrincipal: String, membershipIncarnation: String)
    }

    public let companyID: String
    public let agentPrincipal: String
    public let agentUserID: String
    public let roomID: String
    public let audience: Audience

    public init(companyID: String, agentPrincipal: String, agentUserID: String,
                roomID: String, audience: Audience) {
        self.companyID = companyID
        self.agentPrincipal = agentPrincipal
        self.agentUserID = agentUserID
        self.roomID = roomID
        self.audience = audience
    }

    func admits(_ item: ChatItem, threadRoot: String?) -> Bool {
        guard let marker = item.companyTurn, !item.isOwn, item.sender == agentUserID else { return false }
        let turn = marker.identity
        return item.threadRoot == turn.threadRoot
            && turn.companyID == companyID && turn.agentPrincipal == agentPrincipal
            && turn.roomID == roomID && turn.audience == audience
            && (threadRoot == nil || turn.threadRoot == threadRoot)
    }
}

/// Public turn identity from the company progress or interim marker.
public struct CompanyTurnMarker: Equatable, Hashable, Sendable {
    struct Identity: Equatable, Hashable, Sendable {
        let companyID: String
        let agentPrincipal: String
        let audience: CompanyTurnBinding.Audience
        let roomID: String
        let threadRoot: String
        let taskID: String
        let invocationID: String
    }

    let identity: Identity
    let trigger: String
    let revision: Int
    let revisedAt: Date?

    static let profile = "atum.agent-turns/1.6"

    static func claimed(_ content: [String: Any]) -> Bool {
        let progress = content["io.atum.progress"] as? [String: Any]
        return content["io.atum.company"] != nil || progress?["profile"] as? String == profile
            || progress?["scope"] as? String == "company"
    }

    static func parse(_ content: [String: Any], at: Date?) -> AtumTurnMarkers? {
        guard let kind = content["msgtype"] as? String, let body = content["body"] as? String,
              (1...1_000).contains(body.utf16.count),
              let relation = content["m.relates_to"] as? [String: Any],
              Set(relation.keys) == ["rel_type", "event_id", "is_falling_back", "m.in_reply_to"],
              relation["rel_type"] as? String == "m.thread", jsonBool(relation["is_falling_back"]) == false,
              let root = matrixID(relation["event_id"], prefix: "$"),
              let reply = relation["m.in_reply_to"] as? [String: Any], Set(reply.keys) == ["event_id"],
              let trigger = matrixID(reply["event_id"], prefix: "$") else { return nil }

        let required: Set<String> = ["profile", "scope", "companyId", "agentPrincipal", "audience",
                                     "roomId", "threadRootEventId", "taskId", "invocationId", "revision"]
        let interim = kind == "m.text"
        let key = interim ? "io.atum.company" : "io.atum.progress"
        guard let raw = content[key] as? [String: Any],
              raw["profile"] as? String == profile, raw["scope"] as? String == "company",
              raw["threadRootEventId"] as? String == root,
              let companyID = uuid(raw["companyId"]), let principal = uuid(raw["agentPrincipal"]),
              let taskID = uuid(raw["taskId"]), let invocationID = uuid(raw["invocationId"]),
              let roomID = matrixID(raw["roomId"], prefix: "!"), let audience = audience(raw["audience"]),
              let revision = jsonInteger(raw["revision"]), (0...48).contains(revision) else { return nil }

        let identity = Identity(companyID: companyID, agentPrincipal: principal, audience: audience,
                                roomID: roomID, threadRoot: root, taskID: taskID, invocationID: invocationID)
        let marker = CompanyTurnMarker(identity: identity, trigger: trigger, revision: revision, revisedAt: at)
        let contentKeys: Set<String> = ["msgtype", "body", key, "m.relates_to"]
        if interim {
            guard Set(raw.keys) == required, Set(content.keys) == contentKeys.union(["io.atum.interim"]),
                  jsonBool(content["io.atum.interim"]) == true else { return nil }
            return AtumTurnMarkers(interim: true, company: marker)
        }

        let progressKeys = required.union(["phase", "kind"])
        let presentation = content["io.atum.presentation"]
        guard kind == "m.notice", Set(raw.keys).isSuperset(of: progressKeys),
              Set(raw.keys).isSubset(of: progressKeys.union(["device", "heartbeat"])),
              Set(content.keys).isSubset(of: contentKeys.union(["io.atum.presentation"])),
              presentation == nil || presentation is [String: Any],
              let phase = raw["phase"] as? String, ["working", "waiting", "settled"].contains(phase),
              let activity = raw["kind"] as? String, ["todo", "heartbeat", "device", "touch_id", "settled"].contains(activity),
              raw["device"] == nil || (raw["device"] as? String).map({ (1...80).contains($0.utf16.count) }) == true,
              raw["heartbeat"] == nil || jsonBool(raw["heartbeat"]) != nil else { return nil }
        let progress = AtumTurnMarkers.progress(raw, presentation: presentation)
        return AtumTurnMarkers(progress: progress, company: marker)
    }

    static func acceptsEdit(_ outer: [String: Any], replacement: [String: Any], original: [String: Any],
                            next: AtumTurnMarkers, first: AtumTurnMarkers) -> Bool {
        let key = next.interim ? "io.atum.company" : "io.atum.progress"
        var allowed: Set<String> = ["msgtype", "body", key, "m.new_content", "m.relates_to"]
        allowed.insert(next.interim ? "io.atum.interim" : "io.atum.presentation")
        guard let prior = first.company, let current = next.company,
              prior.identity == current.identity, prior.trigger == current.trigger,
              current.revision > prior.revision, first.interim == next.interim,
              first.progress?.phase != .settled,
              let relation = outer["m.relates_to"] as? [String: Any],
              Set(relation.keys) == ["rel_type", "event_id"],
              relation["rel_type"] as? String == "m.replace",
              let id = matrixID(original["event_id"], prefix: "$"), relation["event_id"] as? String == id,
              Set(outer.keys).isSubset(of: allowed),
              let msgtype = outer["msgtype"] as? String, msgtype == replacement["msgtype"] as? String,
              let body = outer["body"] as? String, (1...1_002).contains(body.utf16.count),
              let outerMarker = outer[key] as? [String: Any], let innerMarker = replacement[key] as? [String: Any],
              let outerData = try? JSONSerialization.data(withJSONObject: outerMarker, options: .sortedKeys),
              let innerData = try? JSONSerialization.data(withJSONObject: innerMarker, options: .sortedKeys),
              outerData == innerData else { return false }
        return next.interim ? jsonBool(outer["io.atum.interim"]) == true
            : outer["io.atum.presentation"] == nil || outer["io.atum.presentation"] is [String: Any]
    }

    private static func audience(_ value: Any?) -> CompanyTurnBinding.Audience? {
        guard let raw = value as? [String: Any] else { return nil }
        switch raw["kind"] as? String {
        case "channel":
            guard Set(raw.keys) == ["kind", "channelId"], let id = uuid(raw["channelId"]) else { return nil }
            return .channel(id: id)
        case "private":
            guard Set(raw.keys) == ["kind", "memberPrincipal", "membershipIncarnation"],
                  let member = uuid(raw["memberPrincipal"]), let incarnation = uuid(raw["membershipIncarnation"])
            else { return nil }
            return .privateCos(memberPrincipal: member, membershipIncarnation: incarnation)
        default: return nil
        }
    }

    private static func uuid(_ value: Any?) -> String? {
        guard let text = value as? String,
              text.range(of: #"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z"#,
                         options: .regularExpression) != nil else { return nil }
        return text
    }

    private static func matrixID(_ value: Any?, prefix: Character) -> String? {
        guard let id = value as? String, id.first == prefix, (2...1_024).contains(id.utf8.count),
              id.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        return id
    }
}

/// Terminal turn identities and accepted revisions, carried by one projector.
struct CompanyTurnMemory: Sendable {
    private var ended = Set<CompanyTurnMarker.Identity>()
    private var accepted = [String: ChatItem]()

    mutating func prepare(_ items: [ChatItem], context: RoomContext, now: Date?) -> (items: [ChatItem], expires: Date?) {
        let binding = context.activeCompanyBinding
        var newest = [CompanyTurnMarker.Identity: Date]()
        var projected: [ChatItem] = []
        projected.reserveCapacity(items.count)
        for var item in items {
            if let binding,
               let prior = accepted[item.id], binding.admits(prior, threadRoot: context.companyThreadRoot),
               let known = prior.companyTurn {
                if item.isRedacted {
                    if prior.isProgressLine { ended.insert(known.identity) }
                } else if item.companyTurn.map({
                    $0.identity != known.identity || $0.trigger != known.trigger || $0.revision <= known.revision
                }) ?? item.isEdited {
                    item = prior
                }
            }
            if let binding, binding.admits(item, threadRoot: context.companyThreadRoot), let marker = item.companyTurn {
                accepted[item.id] = item
                if let progress = item.progress {
                    if progress.phase == .settled { ended.insert(marker.identity) }
                    let at = marker.revisedAt ?? item.timestamp
                    newest[marker.identity] = max(newest[marker.identity] ?? at, at)
                }
            } else if context.companyView || item.companyTurn != nil {
                item.companyTurn = nil
                item.progress = nil
                item.interim = false
            }
            projected.append(item)
        }

        var nextExpiry: Date?
        projected = projected.filter { item in
            guard let marker = item.companyTurn, item.isProgressLine else { return true }
            guard !ended.contains(marker.identity) else { return false }
            if let now, let revised = newest[marker.identity] {
                let expiry = revised.addingTimeInterval(540.001)
                guard now < expiry else { return false }
                nextExpiry = min(nextExpiry ?? expiry, expiry)
            }
            return true
        }
        return (projected, nextExpiry)
    }
}
