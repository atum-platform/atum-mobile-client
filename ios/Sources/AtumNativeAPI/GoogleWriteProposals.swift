import CoreFoundation
import CryptoKit
import Foundation

public enum GoogleWriteProposalSource: Equatable, Sendable {
    case assistant(agentID: NativeID, roomID: String)
    case work
    case unsupported(String)
}

public enum GoogleWriteProposalKind: Equatable, Sendable {
    case sendEmail, createEvent, updateEvent, createDraft, updateDraft, mailbox, createLabel
    case unsupported(String)
}

public enum GoogleMailboxOperation: String, Codable, Equatable, Sendable {
    case archive, unarchive, star, unstar, trash, untrash
    case markRead = "mark_read", markUnread = "mark_unread"
    case addLabels = "add_labels", removeLabels = "remove_labels"
}

public struct GoogleWriteAttachment: Codable, Equatable, Sendable {
    public let filename: String
    public let mimeType: String
    public let size: Int64
    public let sha256: String?
}

public enum GoogleWriteClearedField: Equatable, Sendable {
    case location, description
}

/// Plain text and typed values for the UI to label, format and localize.
/// An omitted line represents an absent field. Present empty strings and arrays are retained.
public enum GoogleWritePreviewLine: Equatable, Sendable {
    case sourceID(String), eventID(String), draftID(String)
    case to([String]), cc([String]), bcc([String]), subject(String)
    case forwarded(from: String, subject: String), attachments([GoogleWriteAttachment])
    case reply, body(String), quote(String), quoteTruncated
    case threadID(String), inReplyTo(String), messageID(String)
    case title(String), start(String), end(String), location(String), description(String)
    case cleared(GoogleWriteClearedField)
    case mailboxTarget(conversation: Bool), labels([String]), name(String)
}

public struct GoogleWriteProposalList: Decodable, Sendable {
    public let proposals: [GoogleWriteProposal]

    private enum CodingKeys: String, CodingKey { case proposals }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var entries = try container.nestedUnkeyedContainer(forKey: .proposals)
        guard (entries.count ?? 0) <= 200 else { throw ContractViolation.invalidValue }
        var seen = Set<NativeID>()
        var proposals = [GoogleWriteProposal]()
        while !entries.isAtEnd {
            let entry = try entries.superDecoder()
            if let proposal = try? GoogleWriteProposal(from: entry), seen.insert(proposal.id).inserted {
                proposals.append(proposal)
            }
        }
        self.proposals = proposals
    }
}

public struct GoogleWriteProposal: Decodable, Equatable, Sendable {
    public let id: NativeID
    public let source: GoogleWriteProposalSource
    public let kind: GoogleWriteProposalKind
    public let digest: String
    public let previewLines: [GoogleWritePreviewLine]
    public let mailboxOperation: GoogleMailboxOperation?
    public let digestMatchesPreview: Bool

    private enum CodingKeys: String, CodingKey { case proposalId, operationId, source, agent, room, draft, digest, status }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(NativeID.self, forKey: .proposalId)
        digest = try container.decode(String.self, forKey: .digest)
        guard try container.decode(NativeID.self, forKey: .operationId) == id,
              try container.decode(String.self, forKey: .status) == "awaiting_owner",
              GoogleProposalRoute.isDigest(digest) else { throw ContractViolation.invalidValue }

        switch try container.decodeIfPresent(String.self, forKey: .source) {
        case nil, "assistant":
            let agent = try container.decode(NativeID.self, forKey: .agent)
            let room = try checkedString(container.decode(String.self, forKey: .room),
                                         minimum: 2, maximum: 1024, pattern: #"![^\s,]+"#)
            source = .assistant(agentID: agent, roomID: room)
        case "work":
            guard try container.decodeNil(forKey: .agent), try container.decodeNil(forKey: .room) else {
                throw ContractViolation.invalidValue
            }
            source = .work
        case let tag?:
            source = .unsupported(tag)
        }

        let draft = try container.superDecoder(forKey: .draft)
        let tag = try draft.container(keyedBy: DraftKey.self)
        // An absent action is Shell's resolved send-email shape. Explicit null is unsupported.
        let action = tag.contains(.action) ? try tag.decodeIfPresent(String.self, forKey: .action) ?? "" : nil
        let preview = try Self.preview(draft, action: action, source: source)
        kind = preview.kind
        previewLines = preview.lines
        mailboxOperation = preview.operation
        digestMatchesPreview = preview.digest == digest
    }

    private enum DraftKey: String, CodingKey { case action }

    private struct Preview {
        let kind: GoogleWriteProposalKind
        let lines: [GoogleWritePreviewLine]
        let operation: GoogleMailboxOperation?
        let digest: String?

        init(kind: GoogleWriteProposalKind, lines: [GoogleWritePreviewLine] = [],
             operation: GoogleMailboxOperation? = nil, draft: (any Encodable)? = nil) {
            self.kind = kind
            self.lines = lines
            self.operation = operation
            digest = draft.flatMap { try? GoogleDraftDigest.hex($0) }
        }
    }

    private static func preview(_ decoder: Decoder, action: String?, source: GoogleWriteProposalSource) throws -> Preview {
        if case .unsupported = source { return Preview(kind: .unsupported(action ?? "send_email")) }
        switch action {
        case nil:
            let draft = try GoogleEmailDraft(from: decoder)
            return Preview(kind: .sendEmail, lines: draft.lines,
                           draft: draft.sourceId == nil && draft.draftId == nil ? draft : nil)
        case "create_event", "update_event":
            let draft = try GoogleEventDraft(from: decoder)
            return Preview(kind: action == "create_event" ? .createEvent : .updateEvent, lines: draft.lines,
                           draft: (draft.eventId != nil) == (action == "update_event") ? draft : nil)
        case "create_draft", "update_draft":
            guard source == .work else { return Preview(kind: .unsupported(action ?? "")) }
            let draft = try GoogleEmailDraft(from: decoder)
            return Preview(kind: action == "create_draft" ? .createDraft : .updateDraft, lines: draft.lines,
                           draft: draft.sourceId != nil && (draft.draftId != nil) == (action == "update_draft") ? draft : nil)
        case "mailbox":
            guard source == .work else { return Preview(kind: .unsupported("mailbox")) }
            let draft = try GoogleMailboxDraft(from: decoder)
            guard let operation = GoogleMailboxOperation(rawValue: draft.operation) else {
                return Preview(kind: .unsupported(draft.operation))
            }
            let labelled = operation == .addLabels || operation == .removeLabels
            let singleTarget = (draft.threadId != nil) != (draft.messageId != nil)
            let validLabels = labelled ? draft.labels?.isEmpty == false : draft.labels == nil
            return Preview(kind: .mailbox, lines: draft.lines, operation: operation,
                           draft: singleTarget && validLabels ? draft : nil)
        case "create_label":
            guard source == .work else { return Preview(kind: .unsupported("create_label")) }
            let draft = try GoogleLabelDraft(from: decoder)
            return Preview(kind: .createLabel, lines: [.sourceID(draft.sourceId), .name(draft.name)], draft: draft)
        case let action?:
            return Preview(kind: .unsupported(action))
        }
    }
}

private struct GoogleEmailDraft: Codable {
    struct Forwarded: Codable {
        let messageId: String
        let from: String
        let date: String
        let subject: String
        let quotePreview: String
        let quoteLength: Int64
        let truncated: Bool?
    }

    let action: String?
    let sourceId: String?
    let draftId: String?
    let to: [String]
    let cc: [String]?
    let bcc: [String]?
    let subject: String
    let body: String
    let quote: String
    let references: [String]
    let threadId: String?
    let inReplyTo: String?
    let forwarded: Forwarded?
    let attachments: [GoogleWriteAttachment]

    var lines: [GoogleWritePreviewLine] {
        var lines = [GoogleWritePreviewLine]()
        if let sourceId { lines.append(.sourceID(sourceId)) }
        if let draftId { lines.append(.draftID(draftId)) }
        lines.append(.to(to))
        if let cc { lines.append(.cc(cc)) }
        if let bcc { lines.append(.bcc(bcc)) }
        lines.append(.subject(subject))
        if let forwarded { lines.append(.forwarded(from: forwarded.from, subject: forwarded.subject)) }
        lines.append(.attachments(attachments))
        if threadId != nil || inReplyTo != nil { lines.append(.reply) }
        if let threadId { lines.append(.threadID(threadId)) }
        if let inReplyTo { lines.append(.inReplyTo(inReplyTo)) }
        lines.append(.body(body))
        lines.append(.quote(quote))
        if forwarded?.truncated == true { lines.append(.quoteTruncated) }
        return lines
    }
}

private struct GoogleEventDraft: Codable {
    let action: String
    let sourceId: String
    let eventId: String?
    let title: String
    let start: String
    let end: String
    let location: String?
    let description: String?

    var lines: [GoogleWritePreviewLine] {
        var lines: [GoogleWritePreviewLine] = [.sourceID(sourceId)]
        if let eventId { lines.append(.eventID(eventId)) }
        lines += [.title(title), .start(start), .end(end)]
        if let location { lines.append(location.isEmpty ? .cleared(.location) : .location(location)) }
        if let description { lines.append(description.isEmpty ? .cleared(.description) : .description(description)) }
        return lines
    }
}

private struct GoogleMailboxDraft: Codable {
    let action: String
    let sourceId: String
    let operation: String
    let threadId: String?
    let messageId: String?
    let labels: [String]?

    var lines: [GoogleWritePreviewLine] {
        var lines: [GoogleWritePreviewLine] = [.sourceID(sourceId), .mailboxTarget(conversation: threadId != nil)]
        if let threadId { lines.append(.threadID(threadId)) }
        if let messageId { lines.append(.messageID(messageId)) }
        if let labels { lines.append(.labels(labels)) }
        return lines
    }
}

private struct GoogleLabelDraft: Codable {
    let action: String
    let sourceId: String
    let name: String
}

/// The typed draft is the only input. Additional wire draft fields are ignored by Codable,
/// so a Shell digest covering any such field cannot authorize this older preview.
enum GoogleDraftDigest {
    static func hex(_ draft: any Encodable) throws -> String {
        let data = try JSONEncoder().encode(draft)
        let object = try JSONSerialization.jsonObject(with: data)
        let canonical = try encode(object)
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode(_ value: Any) throws -> String {
        switch value {
        case let text as String:
            return quote(text)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let integer = number.int64Value
            guard (-NativeAPI.maximumInteger...NativeAPI.maximumInteger).contains(integer),
                  number.doubleValue == Double(integer) else { throw ContractViolation.invalidValue }
            return String(integer)
        case let array as [Any]:
            return "[" + (try array.map(encode)).joined(separator: ",") + "]"
        case let object as [String: Any]:
            let fields = object.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
            return "{" + (try fields.map { key, value in
                quote(key) + ":" + (try encode(value))
            }).joined(separator: ",") + "}"
        default:
            throw ContractViolation.invalidValue
        }
    }

    /// Platform canonicalJson uses NFC and JSON.stringify escaping.
    private static func quote(_ text: String) -> String {
        var result = "\""
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 8: result += #"\b"#
            case 9: result += #"\t"#
            case 10: result += #"\n"#
            case 12: result += #"\f"#
            case 13: result += #"\r"#
            case 34: result += #"\""#
            case 92: result += #"\\"#
            case 0...31: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

public enum GoogleWriteDecision: String, Sendable { case approve, decline }

public enum GoogleWriteDecisionResult: Equatable, Sendable {
    case accepted, refused, changed, unavailable, ambiguous
}

@MainActor public protocol GoogleWriteProposalAPI: AnyObject {
    func googleWriteProposals(isCurrent: @escaping NativeDispatchGate) async throws -> [GoogleWriteProposal]
    func decideGoogleWriteProposal(_ decision: GoogleWriteDecision, proposal: GoogleWriteProposal,
                                   isCurrent: @escaping NativeDispatchGate) async -> GoogleWriteDecisionResult
}

enum GoogleProposalRoute {
    static let url = URL(string: "https://api.atumplatform.com/api/connections/google/proposals")!
    static let header = HostAgentDesk.bridgeHeader
    static let version = HostAgentDesk.bridgeVersion
    static let approvalLimit: TimeInterval = 120
    // Leave time for the request and receipt to travel.
    static let decisionTimeout = approvalLimit + 15

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func matches(_ path: String) -> Bool {
        path == url.path || path.hasPrefix(url.path + "/")
    }

    static func allows(path: String, method: String) -> Bool {
        if path == url.path { return method == "GET" }
        guard path.hasPrefix(url.path + "/"), method == "POST" else { return false }
        let parts = path.dropFirst(url.path.count + 1).split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && (try? NativeID(String(parts[0]))) != nil
            && GoogleWriteDecision(rawValue: String(parts[1])) != nil
    }

    struct Request: Encodable { let digest: String }
    struct Receipt: Decodable {
        let proposalId: NativeID
        let digest: String
        let status: String
    }
}
