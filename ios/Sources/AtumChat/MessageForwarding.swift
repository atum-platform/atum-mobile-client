import Foundation

public enum ForwardRoomScope: Equatable, Sendable {
    case personal, ownAssistant, company(String), unavailable

    public func allowsForward(to destination: Self) -> Bool {
        guard self != .unavailable, destination != .unavailable else { return false }
        guard case let .company(companyID) = self else { return true }
        return destination == .company(companyID) || destination == .ownAssistant
    }
}

public enum ForwardFailure: Error, Equatable, Sendable {
    case unavailable, invalidEvent, sourceChanged, forbidden, encryptedAttachment, sendInProgress
    case failed, deliveryUnconfirmed
}

/// The only fields copied into a fresh Matrix message. No sender or event ID
/// is embedded in the outgoing payload.
public struct ForwardContent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case text = "m.text", image = "m.image", file = "m.file"
    }

    public enum Transfer: Equatable, Sendable {
        case reuse, encryptAndUpload
    }

    public let kind: Kind
    public let body: String
    public let formattedBody: String?
    public let filename: String?
    public let plainMediaURI: String?
    public let isEncryptedAttachment: Bool
    public let mimetype: String?
    public let byteSize: UInt64?
    public let width: UInt64?
    public let height: UInt64?
    public let json: String
    public let attachmentExtraJSON: String

    public func transfer(sourceEncrypted: Bool, destinationEncrypted: Bool) throws -> Transfer {
        if isEncryptedAttachment, !destinationEncrypted { throw ForwardFailure.encryptedAttachment }
        guard plainMediaURI != nil else { return .reuse }
        guard !sourceEncrypted else { throw ForwardFailure.invalidEvent }
        return destinationEncrypted ? .encryptAndUpload : .reuse
    }

    public init(originalEvent: String, latestEvent: String) throws {
        let original = try Self.eventContent(originalEvent)
        let latestEnvelope = try Self.eventContent(latestEvent)
        let relation = latestEnvelope["m.relates_to"] as? [String: Any]
        let latest: [String: Any]
        if relation?["rel_type"] as? String == "m.replace" {
            guard let revision = latestEnvelope["m.new_content"] as? [String: Any] else {
                throw ForwardFailure.invalidEvent
            }
            latest = revision
        } else {
            latest = latestEnvelope
        }
        guard original["io.atum.company_file"] == nil, latest["io.atum.company_file"] == nil,
              let msgtype = latest["msgtype"] as? String,
              let kind = Kind(rawValue: msgtype == "m.notice" ? Kind.text.rawValue : msgtype),
              let rawBody = latest["body"] as? String else { throw ForwardFailure.invalidEvent }
        let isReply = ((latest["m.relates_to"] ?? original["m.relates_to"]) as? [String: Any])?["m.in_reply_to"] != nil
        let body = isReply ? Self.withoutReplyFallback(rawBody) : rawBody
        guard !body.isEmpty,
              body.utf16.count <= 16_000 || ((try? JSONEncoder().encode(body).count) ?? Int.max) <= 40_000
        else { throw ForwardFailure.invalidEvent }

        var extra: [String: Any] = ["io.atum.forwarded": true]
        extra["io.atum.provenance"] = latest["io.atum.provenance"] ?? original["io.atum.provenance"]
        var content = extra
        content["msgtype"] = kind.rawValue
        content["body"] = body
        // An explicit empty intent also disables legacy text-based pings.
        content["m.mentions"] = [String: Any]()
        let formattedBody = (latest["format"] as? String) == "org.matrix.custom.html"
            ? (latest["formatted_body"] as? String).map(Self.withoutHTMLReplyFallback) : nil
        if let formattedBody {
            content["format"] = "org.matrix.custom.html"
            content["formatted_body"] = formattedBody
        }
        var plainURI: String?
        var encrypted = false
        var filename: String?
        var info = [String: Any]()
        if kind != .text {
            if let file = latest["file"] as? [String: Any], let descriptor = Self.encryptedMedia(file) {
                content["file"] = descriptor
                encrypted = true
            } else if latest["file"] == nil, let url = latest["url"] as? String, Self.isMediaURI(url) {
                content["url"] = url
                plainURI = url
            } else {
                throw ForwardFailure.invalidEvent
            }
            filename = latest["filename"] as? String
            content["filename"] = filename
            if let rawInfo = latest["info"] as? [String: Any] {
                info = Self.displayInfo(rawInfo)
                if let rawThumbnail = rawInfo["thumbnail_info"] as? [String: Any] {
                    if encrypted, let file = rawInfo["thumbnail_file"] as? [String: Any],
                       let descriptor = Self.encryptedMedia(file) {
                        info["thumbnail_file"] = descriptor
                        info["thumbnail_info"] = Self.displayInfo(rawThumbnail)
                    } else if !encrypted, let uri = rawInfo["thumbnail_url"] as? String, Self.isMediaURI(uri) {
                        info["thumbnail_url"] = uri
                        info["thumbnail_info"] = Self.displayInfo(rawThumbnail)
                    }
                }
            }
            if !info.isEmpty { content["info"] = info }
        }
        self.kind = kind
        self.body = body
        self.formattedBody = formattedBody
        self.filename = filename
        plainMediaURI = plainURI
        isEncryptedAttachment = encrypted
        mimetype = info["mimetype"] as? String
        byteSize = info["size"] as? UInt64
        width = info["w"] as? UInt64
        height = info["h"] as? UInt64
        let data = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        guard data.count <= 60_000 else { throw ForwardFailure.invalidEvent }
        json = String(decoding: data, as: UTF8.self)
        let extraData = try JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys])
        attachmentExtraJSON = String(decoding: extraData, as: UTF8.self)
    }

    private static func eventContent(_ json: String) throws -> [String: Any] {
        guard json.utf8.count <= 131_072,
              let event = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              event["type"] as? String == "m.room.message",
              let content = event["content"] as? [String: Any],
              (event["unsigned"] as? [String: Any])?["redacted_because"] == nil
        else { throw ForwardFailure.invalidEvent }
        return content
    }

    private static func displayInfo(_ source: [String: Any]) -> [String: Any] {
        var info = [String: Any]()
        info["mimetype"] = source["mimetype"] as? String
        for key in ["w", "h", "size"] { info[key] = source[key] as? UInt64 }
        return info
    }

    private static func encryptedMedia(_ source: [String: Any]) -> [String: Any]? {
        guard let uri = source["url"] as? String, isMediaURI(uri),
              source["v"] as? String == "v2", let iv = source["iv"] as? String,
              let hash = (source["hashes"] as? [String: Any])?["sha256"] as? String,
              let key = source["key"] as? [String: Any], key["kty"] as? String == "oct",
              key["alg"] as? String == "A256CTR", let secret = key["k"] as? String,
              let operations = key["key_ops"] as? [String], let extractable = key["ext"] as? Bool
        else { return nil }
        return [
            "url": uri, "v": "v2", "iv": iv, "hashes": ["sha256": hash],
            "key": ["kty": "oct", "alg": "A256CTR", "k": secret, "key_ops": operations, "ext": extractable]
        ]
    }

    static func isMediaURI(_ value: String) -> Bool {
        value.range(of: #"\Amxc://[^/\s?#]+/[^/\s?#]+\z"#, options: .regularExpression) != nil
    }

    static func withoutReplyFallback(_ value: String) -> String {
        guard value.hasPrefix("> <@") || value.hasPrefix("> * <@"),
              let separator = value.range(of: "\n\n"),
              value[..<separator.lowerBound].split(separator: "\n").allSatisfy({ $0.hasPrefix("> ") })
        else { return value }
        return String(value[separator.upperBound...])
    }

    private static func withoutHTMLReplyFallback(_ value: String) -> String {
        guard value.hasPrefix("<mx-reply>"), let end = value.range(of: "</mx-reply>") else { return value }
        return String(value[end.upperBound...])
    }
}
