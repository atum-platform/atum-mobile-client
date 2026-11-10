import Foundation

public enum SharedCollectionSection: String, CaseIterable, Sendable {
    case media, files, links
    public var previewCount: Int { self == .media ? 6 : 3 }
}

public struct SharedCollectionItem: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case image, video, file, audio, link }
    public enum Thumbnail: Equatable, Sendable {
        case scaled(source: String)
        case content(source: String)
    }
    public let id: String
    public let eventID: String
    public let sender: String
    public let timestamp: Date
    public let kind: Kind
    public let name: String?
    public let url: String?
    public let media: ChatMedia?
    public let thumbnail: Thumbnail?

    /// Resource spellings are byte-sensitive. Swift String equality otherwise
    /// treats canonically equivalent Unicode paths as the same resource.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.eventID == rhs.eventID && lhs.sender == rhs.sender
            && lhs.timestamp == rhs.timestamp && lhs.kind == rhs.kind && lhs.name == rhs.name
            && sameSpelling(lhs.url, rhs.url) && lhs.media == rhs.media && lhs.thumbnail == rhs.thumbnail
            && sameSpelling(lhs.media?.sourceHandle, rhs.media?.sourceHandle)
            && sameSpelling(lhs.media?.thumbnailSourceHandle, rhs.media?.thumbnailSourceHandle)
    }

    private static func sameSpelling(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs.utf16.elementsEqual(rhs.utf16)
        default: false
        }
    }

    /// Re-evaluate on every open, including held purchase links. Never send a
    /// collection URL directly to a browser or URLSession.
    public var linkDecision: LinkPolicy.Decision {
        url.map { LinkPolicy.decision(for: $0) } ?? .refuse
    }
}

/// Desktop matrix-room-shared.ts policy; the SDK adapter supplies latest
/// content, so aggregated edits intentionally use current text (M3 plan).
public enum SharedCollectionsPolicy {
    public static let pageEvents: UInt16 = 50
    public static let maximumPagesPerRead = 4
    public static let pageItems = 30
    public static let maximumItemsPerRead = 60
    public static let maximumRetainedItems = 600
    public static let maximumTimelineEntries = 4096
    public static let thumbnailMaximumBytes = 8 * 1024 * 1024
    public static let fileMaximumBytes: UInt64 = 20 * 1024 * 1024

    public static func links(in body: String) -> [String] {
        // Strip only the leading Matrix reply fallback, like the desktop.
        let lines = body.components(separatedBy: "\n").drop(while: { $0.hasPrefix("> ") })
        var fence: (Character, Int)?
        let prose = lines.map { line -> String in
            let marker = matches(#"^ {0,3}(`{3,}|~{3,})(.*)$"#, in: line).first
            let run = marker.map { substring(line, $0.range(at: 1)) } ?? ""
            let tail = marker.map { substring(line, $0.range(at: 2)) } ?? ""
            if let open = fence {
                if run.first == open.0, run.count >= open.1,
                   tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fence = nil }
                return ""
            }
            if let char = run.first, !(char == "`" && tail.contains("`")) {
                fence = (char, run.count)
                return ""
            }
            return line
        }.joined(separator: "\n")
        let spans = try! NSRegularExpression(pattern: #"(?<!`)(`+)(?!`)[\s\S]*?(?<!`)\1(?!`)"#)
        let text = spans.stringByReplacingMatches(in: prose, range: NSRange(prose.startIndex..., in: prose),
                                                  withTemplate: " ")
        var found: [String] = []
        for match in matches(#"(?<![a-z0-9_])https?://[^\s<>"'`]+"#, in: text, options: [.caseInsensitive]) {
            var value = trimPunctuation(substring(text, match.range))
            for (open, close) in [("(", ")"), ("[", "]"), ("{", "}")] {
                while value.hasSuffix(close), value.components(separatedBy: open).count < value.components(separatedBy: close).count {
                    value.removeLast()
                    value = trimPunctuation(value)
                }
            }
            guard value.utf16.count <= 2048,
                  !found.contains(where: { $0.utf16.elementsEqual(value.utf16) }),
                  let url = URL(string: value), let host = url.host, !host.isEmpty,
                  !value.contains("\\"), host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { continue }
            // Held links remain in the collection; only refused URLs disappear.
            guard LinkPolicy.decision(for: url) != .refuse else { continue }
            found.append(value)
            if found.count == 5 { break }
        }
        return found
    }

    public static func items(section: SharedCollectionSection, item: ChatItem,
                             latestContentJSON: String?, encrypted: Bool) -> [SharedCollectionItem] {
        guard !item.isLocalEcho, item.delivery == .remote,
              let eventID = item.eventID, eventID.hasPrefix("$"), item.sender.hasPrefix("@"),
              item.timestamp.timeIntervalSince1970.isFinite,
              !item.isRedacted, item.kind != .roomState,
              item.progress == nil,
              let json = latestContentJSON?.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return [] }
        switch item.kind {
        case .placeholder, .dayDivider, .readMarker, .timelineStart, .typing, .loadingEarlier: return []
        default: break
        }
        // latestJson() is content, rather than a full Matrix event. Supporting
        // event envelopes also makes the synthetic projection seam explicit.
        let content = raw["content"] as? [String: Any] ?? raw
        let relation = content["m.relates_to"] as? [String: Any]
        guard relation?["rel_type"] as? String != "m.replace",
              let msgtype = content["msgtype"] as? String else { return [] }
        func row(_ kind: SharedCollectionItem.Kind, index: Int = 0, name: String? = nil,
                 url: String? = nil, media: ChatMedia? = nil,
                 thumbnail: SharedCollectionItem.Thumbnail? = nil) -> SharedCollectionItem {
            SharedCollectionItem(id: index == 0 ? eventID : "\(eventID)#\(index)", eventID: eventID,
                                 sender: item.sender, timestamp: item.timestamp, kind: kind,
                                 name: name, url: url, media: media, thumbnail: thumbnail)
        }
        if section == .links {
            guard ["m.text", "m.notice", "m.emote"].contains(msgtype),
                  let body = content["body"] as? String else { return [] }
            // Internal progress messages are operational notices, not shared
            // links. Ordinary bot notices/emotes are intentionally included.
            guard content["io.atum.progress"] == nil else { return [] }
            return links(in: body).enumerated().map { row(.link, index: $0.offset, url: $0.element) }
        }
        let kind: SharedCollectionItem.Kind
        switch msgtype {
        case "m.image" where section == .media: kind = .image
        case "m.video" where section == .media: kind = .video
        case "m.file" where section == .files: kind = .file
        case "m.audio" where section == .files: kind = .audio
        default: return []
        }
        let file = content["file"] as? [String: Any]
        guard validMXC(file?["url"] ?? (encrypted ? nil : content["url"])), var media = item.media else { return [] }
        let info = content["info"] as? [String: Any] ?? [:]
        let rawName = content["filename"] as? String ?? content["body"] as? String
        let name = rawName.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && value.unicodeScalars.count <= 512 ? trimmed : nil
        }
        media.filename = name
        if let mime = media.mimetype, mime.isEmpty || mime.utf16.count > 255 { media.mimetype = nil }
        var thumbnail: SharedCollectionItem.Thumbnail?
        if kind == .image || kind == .video {
            if let thumbnailFile = info["thumbnail_file"] as? [String: Any] {
                let thumbnailInfo = info["thumbnail_info"] as? [String: Any]
                let declaredSize = (thumbnailInfo?["size"] as? NSNumber)?.uint64Value
                if validMXC(thumbnailFile["url"]), declaredSize.map({ $0 <= UInt64(thumbnailMaximumBytes) }) ?? true,
                   let source = media.thumbnailSourceHandle {
                    thumbnail = .content(source: source)
                }
            } else if file != nil {
                if kind == .image, media.byteSize.map({ $0 <= UInt64(thumbnailMaximumBytes) }) ?? false {
                    thumbnail = .content(source: media.sourceHandle)
                }
            } else if !encrypted {
                if kind == .image { thumbnail = .scaled(source: media.sourceHandle) }
                else if validMXC(info["thumbnail_url"]), let source = media.thumbnailSourceHandle {
                    thumbnail = .scaled(source: source)
                }
            }
        }
        return [row(kind, name: name, media: media, thumbnail: thumbnail)]
    }

    /// SDK timeline order is oldest-to-newest. Reverse events, preserving
    /// link order within each event; sender clock skew must not reorder history.
    public static func newestFirst(_ timelineRows: [[SharedCollectionItem]]) -> [SharedCollectionItem] {
        var seen = Set<String>()
        return timelineRows.reversed().flatMap { $0 }.filter { seen.insert($0.id).inserted }
    }

    private static func validMXC(_ value: Any?) -> Bool {
        guard let value = value as? String else { return false }
        return !matches(#"\Amxc://[^/\s?#]+/[^/\s?#]+\z"#, in: value).isEmpty
    }
    private static func trimPunctuation(_ value: String) -> String {
        var value = value
        while let char = value.last, ".,;:!?'\"*_~".contains(char) { value.removeLast() }
        return value
    }
    private static func substring(_ string: String, _ range: NSRange) -> String {
        Range(range, in: string).map { String(string[$0]) } ?? ""
    }
    private static func matches(_ pattern: String, in text: String,
                                options: NSRegularExpression.Options = []) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern, options: options))?
            .matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
    }
}
