import Foundation

/// The authenticated, display-safe portion of an `io.atum.app_bot` notice.
///
/// This parser deliberately accepts the exact desktop wire shape only.  The
/// caller provides the facts that come from the trusted room/catalog boundary;
/// the raw Matrix event supplies a second sender check so an applied edit from
/// another member cannot acquire an app action.
public struct AppBotMessage: Equatable, Hashable, Sendable {
    /// The full desktop notice vocabulary.  Copy is intentionally not part of
    /// this type: the app maps these stable facts to its exported phone copy.
    public enum Code: String, CaseIterable, Equatable, Hashable, Sendable {
        case needsIntake = "needs_intake"
        case unsupportedContent = "unsupported_content"
        case messageTooLong = "message_too_long"
        case cannotRead = "cannot_read"
        case unverifiedSender = "unverified_sender"
        case needsSetup = "needs_setup"
        case linkPending = "link_pending"
        case allowanceExhausted = "allowance_exhausted"
        case busy
        case rateLimited = "rate_limited"
        case appUnavailable = "app_unavailable"
        case appTimeout = "app_timeout"
        case outcomeUnknown = "outcome_unknown"
        case missedWhileOffline = "missed_while_offline"
        case sentBeforeLink = "sent_before_link"
        case andyGroupDeclined = "andy_group_declined"
        case joined
        case nowGroup = "now_group"
        case andyLeaving = "andy_leaving"
    }

    /// Every allowed button action.  `app` is the catalog action identifier
    /// (currently `moon` or `andy`), never a Matrix user or room ID.
    public enum Action: Equatable, Hashable, Sendable {
        case openSetup(app: String)
        case openBotDM(app: String)
        case openAppRoute(app: String, routeID: String)

        /// The action family used by the newest-notice-wins projection.
        public enum Kind: String, Equatable, Hashable, Sendable {
            case openSetup = "open_setup"
            case openBotDM = "open_bot_dm"
            case openAppRoute = "open_app_route"
        }

        public var kind: Kind {
            switch self {
            case .openSetup: .openSetup
            case .openBotDM: .openBotDM
            case .openAppRoute: .openAppRoute
            }
        }

        public var app: String {
            switch self {
            case let .openSetup(app), let .openBotDM(app), let .openAppRoute(app, _): app
            }
        }
    }

    /// Facts supplied by the app layer, rather than trusted from JSON.
    public struct Authorization: Equatable, Hashable, Sendable {
        public var expectedCatalogAppID: String
        public var expectedCatalogAppSlug: String
        public var expectedCatalogBotUserID: String
        public var itemSender: String
        public var roomIsEncrypted: Bool

        public init(expectedCatalogAppID: String, expectedCatalogAppSlug: String,
                    expectedCatalogBotUserID: String, itemSender: String,
                    roomIsEncrypted: Bool) {
            self.expectedCatalogAppID = expectedCatalogAppID
            self.expectedCatalogAppSlug = expectedCatalogAppSlug
            self.expectedCatalogBotUserID = expectedCatalogBotUserID
            self.itemSender = itemSender
            self.roomIsEncrypted = roomIsEncrypted
        }
    }

    public var code: Code
    public var action: Action?

    public init(code: Code, action: Action?) {
        self.code = code
        self.action = action
    }

    /// Parses `LazyTimelineItemProvider.latestJson()`.  `latestJson` is an
    /// event envelope, not a message-content fragment: its own `sender` must
    /// agree with the catalog bot.  For an `m.replace`, only
    /// `content.m.new_content` is inspected; an edit without replacement
    /// content is not allowed to fall back to its old metadata.
    public static func parse(latestJSON: String, authorization: Authorization) -> AppBotMessage? {
        guard !authorization.roomIsEncrypted,
              !authorization.expectedCatalogAppID.isEmpty,
              !authorization.expectedCatalogAppSlug.isEmpty,
              !authorization.expectedCatalogBotUserID.isEmpty,
              authorization.itemSender == authorization.expectedCatalogBotUserID,
              let data = latestJSON.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(event) = envelope,
              event["sender"]?.string == authorization.expectedCatalogBotUserID,
              case let .object(originalContent)? = event["content"] else {
            return nil
        }

        let content: [String: JSONValue]
        if case let .object(relation)? = originalContent["m.relates_to"],
           relation["rel_type"]?.string == "m.replace" {
            guard case let .object(editedContent)? = originalContent["m.new_content"] else { return nil }
            content = editedContent
        } else {
            content = originalContent
        }

        guard case let .object(metadata)? = content["io.atum.app_bot"],
              sameKeys(metadata, ["action", "app_id", "code", "kind", "turn_id", "v"]),
              metadata["v"]?.integer == 1,
              metadata["app_id"]?.string == authorization.expectedCatalogAppID,
              metadata["kind"]?.string == "notice",
              metadata["turn_id"]?.isNull == true,
              let codeText = metadata["code"]?.string,
              let code = Code(rawValue: codeText) else {
            return nil
        }
        let parsedAction = parseAction(metadata["action"], expectedCatalogAppSlug: authorization.expectedCatalogAppSlug)
        guard parsedAction.isValid else { return nil }
        return AppBotMessage(code: code, action: parsedAction.action)
    }

    private static func parseAction(_ value: JSONValue?, expectedCatalogAppSlug: String) -> (isValid: Bool, action: Action?) {
        guard let value else { return (false, nil) }
        if value.isNull { return (true, nil) }
        guard case let .object(action) = value,
              let kind = action["kind"]?.string,
              let app = action["app"]?.string,
              app == expectedCatalogAppSlug else { return (false, nil) }

        switch kind {
        case "open_setup" where sameKeys(action, ["app", "kind"]):
            return (true, .openSetup(app: app))
        case "open_bot_dm" where sameKeys(action, ["app", "kind"]):
            return (true, .openBotDM(app: app))
        case "open_app_route":
            guard sameKeys(action, ["app", "kind", "route_id"]),
                  let routeID = action["route_id"]?.string,
                  isRouteID(routeID) else { return (false, nil) }
            return (true, .openAppRoute(app: app, routeID: routeID))
        default:
            return (false, nil)
        }
    }

    private static func sameKeys(_ object: [String: JSONValue], _ expected: [String]) -> Bool {
        object.keys.sorted() == expected.sorted()
    }

    private static func isRouteID(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              (first.value >= 97 && first.value <= 122),
              value.utf8.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 97 && $0.value <= 122) || ($0.value >= 48 && $0.value <= 57) || $0 == "_" || $0 == "-"
        }
    }
}

/// The display-safe `io.atum.bot_api/1` projection for one message. Catalog
/// transport mode is intentionally absent: only exact per-message metadata
/// from the catalog bot can enable Bot API formatting or photo presentation.
public struct BotAPIMessage: Equatable, Hashable, Sendable {
    public struct URLButton: Equatable, Hashable, Sendable {
        public var label: String
        public var url: URL

        public init(label: String, url: URL) {
            self.label = label
            self.url = url
        }
    }

    public struct Photo: Equatable, Hashable, Sendable {
        public var fileReference: String
        public var width: Int
        public var height: Int
        public var mimeType: String
        public var caption: String?

        public init(fileReference: String, width: Int, height: Int,
                    mimeType: String, caption: String?) {
            self.fileReference = fileReference
            self.width = width
            self.height = height
            self.mimeType = mimeType
            self.caption = caption
        }
    }

    public struct Authorization: Equatable, Hashable, Sendable {
        public var expectedCatalogBotUserID: String
        public var itemSender: String
        public var roomIsEncrypted: Bool

        public init(expectedCatalogBotUserID: String, itemSender: String,
                    roomIsEncrypted: Bool) {
            self.expectedCatalogBotUserID = expectedCatalogBotUserID
            self.itemSender = itemSender
            self.roomIsEncrypted = roomIsEncrypted
        }
    }

    public var botID: String
    public var publicMessageID: Int
    /// Telegram-style row layout, but URL-only. An invalid keyboard is nil
    /// while the rest of the authenticated message remains usable.
    public var keyboard: [[URLButton]]?
    public var photo: Photo?
    public var fallbackText: String?
    public var formattedBody: String?

    public init(botID: String, publicMessageID: Int, keyboard: [[URLButton]]? = nil,
                photo: Photo? = nil,
                fallbackText: String? = nil, formattedBody: String? = nil) {
        self.botID = botID
        self.publicMessageID = publicMessageID
        self.keyboard = keyboard
        self.photo = photo
        self.fallbackText = fallbackText
        self.formattedBody = formattedBody
    }

    public static func parse(latestJSON: String, authorization: Authorization) -> BotAPIMessage? {
        guard !authorization.roomIsEncrypted,
              !authorization.expectedCatalogBotUserID.isEmpty,
              authorization.itemSender == authorization.expectedCatalogBotUserID,
              let data = latestJSON.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(event) = envelope,
              event["sender"]?.string == authorization.expectedCatalogBotUserID,
              case let .object(originalContent)? = event["content"] else { return nil }

        let content: [String: JSONValue]
        if case let .object(relation)? = originalContent["m.relates_to"],
           relation["rel_type"]?.string == "m.replace" {
            guard case let .object(editedContent)? = originalContent["m.new_content"] else { return nil }
            content = editedContent
        } else {
            content = originalContent
        }

        guard case let .object(metadata)? = content["io.atum.bot_api"],
              onlyKeys(metadata, ["version", "bot_id", "public_message_id", "keyboard", "photo", "fallback_text"]),
              metadata["version"]?.string == "io.atum.bot_api/1",
              let botID = metadata["bot_id"]?.string,
              botID.range(of: "^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$",
                          options: .regularExpression) != nil,
              let publicMessageID = metadata["public_message_id"]?.integer,
              publicMessageID > 0 else { return nil }

        // A keyboard is optional presentation. Future, malformed or callback
        // shapes remove only these buttons; they never discard the message,
        // formatted body or photo.
        let parsedKeyboard = parseKeyboard(metadata["keyboard"])

        let parsedPhoto: Photo?
        if let value = metadata["photo"] {
            guard case let .object(object) = value,
                  onlyKeys(object, ["file_ref", "width", "height", "mime_type", "caption"]),
                  let fileReference = object["file_ref"]?.string,
                  fileReference.range(of: "^mref_[A-Za-z0-9_-]{16,192}$",
                                      options: .regularExpression) != nil,
                  let width = object["width"]?.integer, (1...65_535).contains(width),
                  let height = object["height"]?.integer, (1...65_535).contains(height),
                  let mimeType = object["mime_type"]?.string,
                  ["image/jpeg", "image/png", "image/webp"].contains(mimeType) else { return nil }
            let caption = object["caption"]?.string
            guard caption == nil || caption!.utf16.count <= 1_024 else { return nil }
            parsedPhoto = Photo(fileReference: fileReference, width: width, height: height,
                                mimeType: mimeType, caption: caption)
        } else {
            parsedPhoto = nil
        }

        let fallbackText = metadata["fallback_text"]?.string
        guard fallbackText == nil || (1...4_096).contains(fallbackText!.utf16.count) else { return nil }

        let formattedBody: String?
        if content["format"]?.string == "org.matrix.custom.html" {
            guard let value = content["formatted_body"]?.string,
                  (1...16_384).contains(value.utf16.count) else { return nil }
            formattedBody = value
        } else {
            formattedBody = nil
        }
        return BotAPIMessage(botID: botID.lowercased(), publicMessageID: publicMessageID,
                             keyboard: parsedKeyboard,
                             photo: parsedPhoto, fallbackText: fallbackText,
                             formattedBody: formattedBody)
    }

    private static func parseKeyboard(_ value: JSONValue?) -> [[URLButton]]? {
        guard let value else { return nil }
        guard case let .array(rows) = value, (1...8).contains(rows.count) else { return nil }
        var keyboard = [[URLButton]]()
        for rowValue in rows {
            guard case let .array(values) = rowValue, (1...4).contains(values.count) else { return nil }
            var row = [URLButton]()
            for value in values {
                guard case let .object(button) = value,
                      onlyKeys(button, ["label", "kind", "url"]),
                      let label = button["label"]?.string,
                      (1...64).contains(label.utf16.count),
                      button["kind"]?.string == "url",
                      let text = button["url"]?.string,
                      let url = URL(string: text),
                      url.scheme?.lowercased() == "https", url.host != nil,
                      url.user == nil, url.password == nil else { return nil }
                row.append(URLButton(label: label, url: url))
            }
            keyboard.append(row)
        }
        return keyboard
    }

    private static func onlyKeys(_ object: [String: JSONValue], _ allowed: [String]) -> Bool {
        Set(object.keys).isSubset(of: Set(allowed))
    }
}

private enum JSONValue: Decodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value") }
    }

    var string: String? {
        guard case let .string(value) = self else { return nil }
        return value
    }

    var integer: Int? {
        guard case let .integer(value) = self else { return nil }
        return value
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
