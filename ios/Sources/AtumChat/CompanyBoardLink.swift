import Foundation

/// A company board target named by a first-party board link (desktop
/// `src/matrix/team-space/board-link-target.ts`, `parseCompanyBoardLink`):
/// `https://atumplatform.com/#atum-board/<company>/<board>[/card/<card>]`,
/// lowercase UUIDs only, nothing before or after. Such a link never opens the
/// website: the chat opens Team space → that company → Board (and the card).
public struct CompanyBoardLinkTarget: Equatable, Hashable, Sendable {
    public enum Kind: String, Equatable, Hashable, Sendable {
        case companyBoard = "company_board"
        case companyBoardCard = "company_board_card"
    }

    public let kind: Kind
    public let companyID: String
    public let boardID: String
    public let cardID: String?

    public init(companyID: String, boardID: String, cardID: String? = nil) {
        kind = cardID == nil ? .companyBoard : .companyBoardCard
        self.companyID = companyID
        self.boardID = boardID
        self.cardID = cardID
    }

    private static let uuid = "[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}"
    // Desktop `BOARD_LINK`; `\z` is JavaScript's `$` without the `m` flag (ICU's `$`
    // would also match before a final newline).
    private static let pattern = try! NSRegularExpression(
        pattern: "^https://atumplatform\\.com/#atum-board/(\(uuid))/(\(uuid))(?:/card/(\(uuid)))?\\z")

    /// The target of an exact board link, else nil (a lookalike origin, an
    /// uppercase or malformed id, any extra character).
    public static func parse(_ value: String) -> CompanyBoardLinkTarget? {
        let range = NSRange(value.startIndex..., in: value)
        guard let match = pattern.firstMatch(in: value, range: range),
              match.range == range,
              let company = Range(match.range(at: 1), in: value),
              let board = Range(match.range(at: 2), in: value) else { return nil }
        let card = Range(match.range(at: 3), in: value).map { String(value[$0]) }
        return CompanyBoardLinkTarget(companyID: String(value[company]), boardID: String(value[board]),
                                      cardID: card)
    }

    /// The link this target is named by (desktop `matrix-company-private-cos.ts`, greeting link).
    public var url: String {
        "https://atumplatform.com/#atum-board/\(companyID)/\(boardID)" + (cardID.map { "/card/\($0)" } ?? "")
    }
}

/// The Chief of Staff greeting's two links in a company-private CoS room
/// (desktop `src/matrix/message.ts`, `privateCosGreetingLinks`): the agent pill
/// and the titled board link, parsed only from the exact frozen shape (v1.2
/// `greeting.matrix-content*.json`). The title is the event's own link text.
public struct PrivateCosGreeting: Equatable, Hashable, Sendable {
    public struct AgentPill: Equatable, Hashable, Sendable {
        public let userID: String
        public let label: String
        public let href: String
    }

    public struct BoardLink: Equatable, Hashable, Sendable {
        public let title: String
        public let href: String
        public let target: CompanyBoardLinkTarget
    }

    public let agentPill: AgentPill
    public let boardLink: BoardLink

    /// The pill's fixed label: the frozen claim's `label` literal (desktop
    /// `'@Chief of Staff' as const`). It is the event's own text, matched, never shown on its own.
    public static let agentLabel = "@Chief of Staff"

    private static let matrixUserID = try! NSRegularExpression(pattern: "^@[!-9;-~]{1,255}:[!-~]{1,255}\\z")
    private static let trailingBoardAnchor = try! NSRegularExpression(
        pattern: "<br><br><a href=\"([^\"]+)\">([^<>]{1,160})</a>\\z")

    /// The greeting's links, or nil for anything not in the exact shape. The
    /// caller has already proved the room is this account's company-private
    /// CoS room (the platform's binding), as desktop proves it from room state.
    public static func parse(sender: String, body: String, format: String?,
                             formattedBody: String?) -> PrivateCosGreeting? {
        guard format == "org.matrix.custom.html", let formatted = formattedBody,
              matches(matrixUserID, sender) else { return nil }
        let href = "https://matrix.to/#/\(sender)"
        let anchor = "<a href=\"\(href)\">\(agentLabel)</a>"
        guard formatted.contains(anchor), body.contains(agentLabel) else { return nil }
        let range = NSRange(formatted.startIndex..., in: formatted)
        guard let match = trailingBoardAnchor.firstMatch(in: formatted, range: range),
              let hrefRange = Range(match.range(at: 1), in: formatted),
              let titleRange = Range(match.range(at: 2), in: formatted) else { return nil }
        let boardHref = String(formatted[hrefRange])
        let title = String(formatted[titleRange])
        guard let target = CompanyBoardLinkTarget.parse(boardHref),
              body.hasSuffix("\n\n\(title): \(boardHref)") else { return nil }
        return PrivateCosGreeting(agentPill: AgentPill(userID: sender, label: agentLabel, href: href),
                                  boardLink: BoardLink(title: title, href: boardHref, target: target))
    }

    /// The safe Markdown the bubble shows (desktop `privateCosGreetingMarkdown`):
    /// the body with its first pill label and its trailing "title: url" line
    /// turned into links. The raw URL is never shown.
    public func markdown(body: String) -> String {
        var text = body
        if let pill = text.range(of: agentPill.label) {
            text.replaceSubrange(pill, with: "[\(agentPill.label)](\(agentPill.href))")
        }
        if let board = text.range(of: "\(boardLink.title): \(boardLink.href)") {
            text.replaceSubrange(board, with: "[\(boardLink.title)](\(boardLink.href))")
        }
        return text
    }

    private static func matches(_ expression: NSRegularExpression, _ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }
}
