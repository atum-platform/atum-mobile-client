import AtumChat
import Foundation

// Home search's Messages and Files: desktop's company search
// (`apps/desktop/shared/matrix-company-search-query.ts`,
// `electron/matrix/main-company-search.ts`, `src/matrix/company-message-search.ts`),
// as the roster's global search asks it (`roster-global-search.ts`
// `searchCompanies`: 10 per company and tab, companies in id order). Pure
// values only: the app asks the homeserver's `/search` and hands the answer
// here. Nothing here holds authority or does I/O.

public enum CompanySearchTab: String, Sendable, Equatable, Hashable, CaseIterable {
    case messages, files
}

public enum CompanySearchFileType: String, Sendable, Equatable {
    case images, pdfs, documents, other
}

// MARK: Query (desktop `parseMatrixCompanySearchQuery`)

/// The small Team space search language: words, "quoted phrases", and at most
/// one each of `from:me` / `from:@name`, `in:#channel`, `before:YYYY-MM-DD`
/// and `after:YYYY-MM-DD`.
public struct CompanySearchQuery: Equatable, Sendable {
    public struct Term: Equatable, Sendable {
        public let value: String
        public let quoted: Bool
    }

    public enum Problem: String, Sendable, Equatable {
        case duplicateOperator, invalidDate, invalidOperator, invalidRange, unterminatedQuote
    }

    public private(set) var raw: String
    public private(set) var terms: [Term] = []
    public private(set) var from: String?
    public private(set) var inChannel: String?
    public private(set) var before: String?
    public private(set) var after: String?
    public private(set) var problems: [Problem] = []
    /// What `/search` is asked for: the words and phrases, operators left out.
    public private(set) var serverTerm = ""

    public static func parse(_ raw: String) -> CompanySearchQuery {
        var parsed = CompanySearchQuery(raw: raw)
        var seen = Set<String>()
        func problem(_ value: Problem) {
            if !parsed.problems.contains(value) { parsed.problems.append(value) }
        }
        for token in tokens(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if token.quoted {
                if !token.closed { problem(.unterminatedQuote) }
                if !token.value.isEmpty { parsed.terms.append(Term(value: token.value, quoted: true)) }
                continue
            }
            guard let colon = token.value.firstIndex(of: ":") else {
                parsed.terms.append(Term(value: token.value, quoted: false))
                continue
            }
            let name = token.value[..<colon].lowercased()
            guard ["from", "in", "before", "after"].contains(name) else {
                parsed.terms.append(Term(value: token.value, quoted: false))
                continue
            }
            let value = String(token.value[token.value.index(after: colon)...])
            if seen.contains(name) {
                problem(.duplicateOperator)
                continue
            }
            seen.insert(name)
            let valid: Bool
            switch name {
            case "from": valid = value == "me" || isPersonReference(value)
            case "in": valid = isChannelReference(value)
            default: valid = isCalendarDate(value)
            }
            guard valid else {
                problem(name == "before" || name == "after" ? .invalidDate : .invalidOperator)
                continue
            }
            switch name {
            case "from": parsed.from = value
            case "in": parsed.inChannel = value
            case "before": parsed.before = value
            default: parsed.after = value
            }
        }
        if let before = parsed.before, let after = parsed.after, before <= after { problem(.invalidRange) }
        parsed.serverTerm = parsed.terms.map(\.value).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return parsed
    }

    /// Desktop `matrixCompanySearchNeedsLoadedHistory`: an operator-only query
    /// has nothing to send to `/search`.
    public var needsLoadedHistory: Bool { serverTerm.isEmpty }

    /// Desktop `matrixCompanySearchTermMatches`: every word and phrase is in
    /// the text, case and marks folded away.
    public func termsMatch(_ body: String) -> Bool {
        let folded = Self.fold(body)
        return terms.allSatisfy { folded.contains(Self.fold($0.value)) }
    }

    /// Desktop `matrixCompanySearchDateMatches`: calendar dates in the
    /// device's time zone, `before` exclusive and `after` inclusive.
    public func dateMatches(milliseconds: Int64, timeZone: TimeZone = .current) -> Bool {
        let date = Self.calendarDate(milliseconds: milliseconds, timeZone: timeZone)
        return (before.map { date < $0 } ?? true) && (after.map { date >= $0 } ?? true)
    }

    static func calendarDate(milliseconds: Int64, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day],
                                            from: Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000))
        return String(format: "%04ld-%02ld-%02ld", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Desktop's fold: no marks, đ as d, lower case, one space for any run.
    static func fold(_ value: String) -> String {
        let stripped = value.decomposedStringWithCanonicalMapping.unicodeScalars.filter {
            switch $0.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: false
            default: true
            }
        }
        let text = String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "d")
            .lowercased()
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private struct Token { var value: String; var quoted: Bool; var closed: Bool }

    private static func tokens(_ raw: String) -> [Token] {
        var result = [Token]()
        let characters = Array(raw)
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }
            if characters[index] != "\"" {
                let start = index
                while index < characters.count, !characters[index].isWhitespace { index += 1 }
                result.append(Token(value: String(characters[start..<index]), quoted: false, closed: true))
                continue
            }
            index += 1
            var value = ""
            var closed = false
            while index < characters.count {
                let character = characters[index]
                if character == "\"" {
                    index += 1
                    closed = true
                    break
                }
                if character == "\\", index + 1 < characters.count, ["\"", "\\"].contains(characters[index + 1]) {
                    value.append(characters[index + 1])
                    index += 2
                    continue
                }
                value.append(character)
                index += 1
            }
            result.append(Token(value: value, quoted: true, closed: closed))
        }
        return result
    }

    /// `/^@[^\s@:|]+(?:[^\s:|]*)$/u`
    private static func isPersonReference(_ value: String) -> Bool {
        guard value.hasPrefix("@") else { return false }
        let rest = value.dropFirst()
        guard let first = rest.first, first != "@" else { return false }
        return !rest.contains { $0.isWhitespace || $0 == ":" || $0 == "|" }
    }

    /// `/^#[^\s#|]+$/u`
    private static func isChannelReference(_ value: String) -> Bool {
        guard value.hasPrefix("#") else { return false }
        let rest = value.dropFirst()
        return !rest.isEmpty && !rest.contains { $0.isWhitespace || $0 == "#" || $0 == "|" }
    }

    private static func isCalendarDate(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        return check.year == year && check.month == month && check.day == day
    }
}

// MARK: Targets (desktop main `targets`)

/// One company room the search may read: a ready channel (active or archived)
/// or a ready conversation (active or read only).
public struct CompanySearchTarget: Equatable, Sendable {
    public let channelID: String
    public let roomID: String
    public let channelName: String
    public let isConversation: Bool

    public init(channelID: String, roomID: String, channelName: String, isConversation: Bool = false) {
        self.channelID = channelID
        self.roomID = roomID
        self.channelName = channelName
        self.isConversation = isConversation
    }

    /// Desktop main's fallback name for a conversation whose people have no
    /// name or handle. It is a fixed literal there, not a copy key.
    public static let unnamedConversation = "Conversation"

    public static func targets(channels: CompanyChannelDirectory?,
                               conversations: CompanyConversationDirectory?) -> [CompanySearchTarget] {
        let channelRows: [CompanySearchTarget] = (channels?.channels ?? []).compactMap { entry in
            guard entry.room.state == "ready", let roomID = entry.room.roomId,
                  [.active, .archived].contains(entry.channel.state) else { return nil }
            return CompanySearchTarget(channelID: entry.channel.id.rawValue, roomID: roomID,
                                       channelName: entry.channel.displayName)
        }
        let conversationRows: [CompanySearchTarget] = (conversations?.conversations ?? []).compactMap { item in
            guard item.room.state == "ready", let roomID = item.room.roomId,
                  [.active, .readOnly].contains(item.state) else { return nil }
            let names = item.participants
                .map { $0.displayName ?? ($0.handle.map { "@" + $0 } ?? "") }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            let name = String(names.prefix(80))
            return CompanySearchTarget(channelID: item.id.rawValue, roomID: roomID,
                                       channelName: name.isEmpty ? unnamedConversation : name,
                                       isConversation: true)
        }
        return (channelRows + conversationRows).sorted { $0.channelID < $1.channelID }
    }
}

// MARK: Results

public struct CompanySearchResult: Equatable, Sendable, Identifiable {
    public struct File: Equatable, Sendable {
        public let name: String
        public let mimeType: String?
        public let size: Int64?
        public let type: CompanySearchFileType

        public init(name: String, mimeType: String? = nil, size: Int64? = nil, type: CompanySearchFileType) {
            self.name = name
            self.mimeType = mimeType
            self.size = size
            self.type = type
        }
    }

    public let companyID: String
    public let channelID: String
    public let roomID: String
    public let channelName: String
    public let eventID: String
    public let sender: String
    public let snippet: String
    /// Milliseconds since 1970 (`origin_server_ts`).
    public let at: Int64
    public let threadRootID: String?
    public let file: File?
    public let isConversation: Bool

    public init(companyID: String, channelID: String, roomID: String, channelName: String, eventID: String,
                sender: String, snippet: String, at: Int64, threadRootID: String? = nil, file: File? = nil,
                isConversation: Bool = false) {
        self.companyID = companyID
        self.channelID = channelID
        self.roomID = roomID
        self.channelName = channelName
        self.eventID = eventID
        self.sender = sender
        self.snippet = snippet
        self.at = at
        self.threadRootID = threadRootID
        self.file = file
        self.isConversation = isConversation
    }

    public var id: String { eventID }
    /// The row's second line: the file's name, else the message's words.
    public var text: String { file?.name ?? snippet }
}

public enum CompanyMessageSearch {
    /// `searchCompanies` asks each company for ten of each.
    public static let limit = 10
    public static let snippetMaximum = 600

    /// The query `/search` may be asked for, or nil when desktop main would
    /// refuse it (`parseMatrixCompanySearchRequest`): 2…200 characters, no
    /// query problem. A refused company answers nothing.
    public static func query(_ term: String) -> CompanySearchQuery? {
        let text = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.unicodeScalars.count >= 2, text.unicodeScalars.count <= 200 else { return nil }
        let parsed = CompanySearchQuery.parse(text)
        return parsed.problems.isEmpty ? parsed : nil
    }

    /// The rooms one company's search reads: joined, not encrypted (the
    /// server cannot search those), narrowed by `in:#channel`.
    public static func admitted(_ targets: [CompanySearchTarget], query: CompanySearchQuery,
                                isJoined: (String) -> Bool, isEncrypted: (String) -> Bool) -> [CompanySearchTarget] {
        let readable = targets.filter { isJoined($0.roomID) && !isEncrypted($0.roomID) }
        guard let channel = query.inChannel else { return readable }
        let wanted = ChatSearchText.needle(String(channel.dropFirst()))
        return readable.filter { ChatSearchText.needle($0.channelName) == wanted }
    }

    /// Desktop `senderIds`' member rule for `from:@name`: a member whose
    /// localpart, name or raw name folds to the same words.
    public static func memberMatches(userID: String, names: [String], from: String) -> Bool {
        let wanted = ChatSearchText.needle(String(from.dropFirst()))
        let localpart = userID.hasPrefix("@")
            ? String(userID.dropFirst().split(separator: ":", maxSplits: 1).first ?? "") : userID
        return ([localpart] + names).contains { candidate in
            let bare = candidate.hasPrefix("@") ? String(candidate.dropFirst()) : candidate
            return ChatSearchText.needle(bare) == wanted
        }
    }

    /// The `POST /_matrix/client/v3/search` body (matrix-js-sdk
    /// `searchRoomEvents`, as desktop sends it).
    public static func requestBody(query: CompanySearchQuery, tab: CompanySearchTab, roomIDs: [String],
                                   senders: [String]?, limit: Int = limit) throws -> Data {
        var filter: [String: Any] = ["rooms": roomIDs, "types": ["m.room.message"], "limit": limit]
        if let senders { filter["senders"] = senders }
        if tab == .files { filter["contains_url"] = true }
        let body: [String: Any] = ["search_categories": ["room_events": [
            "search_term": query.serverTerm,
            "filter": filter,
            "order_by": "recent",
            "event_context": ["before_limit": 0, "after_limit": 0, "include_profile": false],
        ]]]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// One company's results from a `/search` answer, at most `limit`, in the
    /// server's order. Nil when the answer cannot be trusted (an event from a
    /// room it was not asked about, a malformed id): desktop then refuses the
    /// company's whole page.
    public static func results(responseJSON: Data, companyID: String, tab: CompanySearchTab,
                               query: CompanySearchQuery, targets: [CompanySearchTarget],
                               limit: Int = limit, timeZone: TimeZone = .current) -> [CompanySearchResult]? {
        guard let root = try? JSONSerialization.jsonObject(with: responseJSON) as? [String: Any],
              let categories = root["search_categories"] as? [String: Any],
              let page = categories["room_events"] as? [String: Any] else { return nil }
        let found = (page["results"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["result"] }
        let byRoom = Dictionary(targets.map { ($0.roomID, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var results = [CompanySearchResult]()
        for raw in found {
            if results.count >= limit { break }
            guard let event = raw as? [String: Any],
                  let roomID = event["room_id"] as? String, let target = byRoom[roomID],
                  let eventID = event["event_id"] as? String, isEventID(eventID),
                  let sender = event["sender"] as? String, isUserID(sender),
                  let at = (event["origin_server_ts"] as? NSNumber)?.int64Value,
                  at >= 0, at <= 8_640_000_000_000_000 else { return nil }
            if seen.contains(eventID) { continue }
            let content = event["content"] as? [String: Any]
            let root = threadRoot(content ?? [:])
            // Edits, reactions, replies and malformed relations are not results.
            guard case let .some(threadRootID) = root, threadRootID != eventID else { continue }
            let redacted = ((event["unsigned"] as? [String: Any])?["redacted_because"]) != nil
            guard event["type"] as? String == "m.room.message", !redacted, let content,
                  query.dateMatches(milliseconds: at, timeZone: timeZone) else { continue }
            let file = fileMetadata(content)
            switch tab {
            case .files:
                guard let file, query.termsMatch(file.name) else { continue }
                seen.insert(eventID)
                results.append(CompanySearchResult(
                    companyID: companyID, channelID: target.channelID, roomID: roomID,
                    channelName: target.channelName, eventID: eventID, sender: sender, snippet: file.name,
                    at: at, threadRootID: threadRootID, file: file, isConversation: target.isConversation))
            case .messages:
                guard content["msgtype"] as? String == "m.text", let body = content["body"] as? String,
                      !body.isEmpty, body.utf16.count <= 64 * 1024 else { continue }
                let words = ChatSearchText.markdownWords(body)
                guard query.termsMatch(words), ChatSearchText.matches(words, query: query.serverTerm) else { continue }
                seen.insert(eventID)
                results.append(CompanySearchResult(
                    companyID: companyID, channelID: target.channelID, roomID: roomID,
                    channelName: target.channelName, eventID: eventID, sender: sender,
                    snippet: snippet(words, query: query.serverTerm), at: at, threadRootID: threadRootID,
                    isConversation: target.isConversation))
            }
        }
        return results
    }

    /// Desktop `searchCompanies`: every company's page, companies in id order.
    public static func merged(_ pages: [String: [CompanySearchResult]]) -> [CompanySearchResult] {
        pages.keys.sorted().flatMap { pages[$0] ?? [] }
    }

    /// Desktop `searchSnippet`: a long message is cut to 600 characters
    /// around its first match, with "…" where it was cut.
    public static func snippet(_ body: String, query: String) -> String {
        let characters = Array(body)
        guard characters.count > snippetMaximum else { return body }
        let found = ChatSearchText.needle(query)
            .flatMap { ChatSearchText.occurrences(of: $0, in: body).first?.lowerBound } ?? 0
        let start = max(0, min(found - 160, characters.count - snippetMaximum))
        let end = start + snippetMaximum
        return (start > 0 ? "…" : "") + String(characters[start..<end]) + (end < characters.count ? "…" : "")
    }

    /// `.some(nil)`: not in a thread. `.some(id)`: a thread reply. `nil`: any
    /// other relation, which is never a result.
    static func threadRoot(_ content: [String: Any]) -> String?? {
        guard let relation = content["m.relates_to"] else { return .some(nil) }
        guard let relation = relation as? [String: Any], relation["rel_type"] as? String == "m.thread",
              let root = relation["event_id"] as? String, isEventID(root) else { return nil }
        return .some(root)
    }

    static func fileMetadata(_ content: [String: Any]) -> CompanySearchResult.File? {
        guard let msgtype = content["msgtype"] as? String,
              ["m.file", "m.image", "m.audio", "m.video"].contains(msgtype) else { return nil }
        let name = (content["filename"] as? String) ?? (content["body"] as? String)
        let info = content["info"] as? [String: Any]
        let mimeType = (info?["mimetype"] as? String).flatMap { $0.utf16.count <= 255 ? $0 : nil }
        let size = (info?["size"] as? NSNumber).map(\.int64Value).flatMap { $0 >= 0 ? $0 : nil }
        guard let name, !name.isEmpty, name.unicodeScalars.count <= 512 else { return nil }
        return CompanySearchResult.File(name: name, mimeType: mimeType, size: size,
                                        type: fileType(name: name, mimeType: mimeType, msgtype: msgtype))
    }

    private static let documentMimeTypes: Set<String> = [
        "application/msword", "application/rtf", "application/vnd.apple.keynote",
        "application/vnd.apple.numbers", "application/vnd.apple.pages", "application/vnd.ms-excel",
        "application/vnd.ms-powerpoint", "application/vnd.oasis.opendocument.presentation",
        "application/vnd.oasis.opendocument.spreadsheet", "application/vnd.oasis.opendocument.text",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ]

    private static let documentExtensions: Set<String> = [
        "csv", "doc", "docx", "key", "md", "numbers", "odp", "ods", "odt", "pages", "ppt", "pptx", "rtf",
        "txt", "xls", "xlsx",
    ]

    static func fileType(name: String, mimeType: String?, msgtype: String) -> CompanySearchFileType {
        let mime = mimeType?.lowercased()
        let ext = name.split(separator: ".").count > 1 ? name.split(separator: ".").last.map { $0.lowercased() } : nil
        if msgtype == "m.image" || mime?.hasPrefix("image/") == true { return .images }
        if mime == "application/pdf" || ext == "pdf" { return .pdfs }
        if mime?.hasPrefix("text/") == true || mime.map(documentMimeTypes.contains) == true
            || ext.map(documentExtensions.contains) == true { return .documents }
        return .other
    }

    static func isEventID(_ value: String) -> Bool {
        value.hasPrefix("$") && value.count >= 2 && value.utf8.count <= 512
            && value.unicodeScalars.dropFirst().allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    static func isUserID(_ value: String) -> Bool {
        guard value.hasPrefix("@"), let colon = value.firstIndex(of: ":") else { return false }
        let local = value[value.index(after: value.startIndex)..<colon]
        let server = value[value.index(after: colon)...]
        return !local.isEmpty && local.utf8.count <= 255 && !server.isEmpty && server.utf8.count <= 255
            && local.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) && $0 != ":" }
            && server.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }
}
