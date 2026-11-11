import Foundation
import XCTest
@testable import AtumChat

/// Desktop `board-link-target.ts`, `message.ts` `privateCosGreetingLinks` and
/// `private-cos-greeting.ts`, against the vendored frozen v1.2 greeting fixtures.
final class CompanyBoardLinkTests: XCTestCase {
    private let company = "00000000-0000-4000-8000-540eb3b6436f"
    private let board = "00000000-0000-4000-8000-7b0cac15d6b0"
    private let card = "00000000-0000-4000-8000-ed2914fe0e5a"

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/contracts/provider/company-private-cos/v1.2/fixtures/\(name)")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func greeting(_ content: [String: Any], sender: String = "@private-cos:atum.example") -> PrivateCosGreeting? {
        PrivateCosGreeting.parse(sender: sender, body: content["body"] as? String ?? "",
                                 format: content["format"] as? String,
                                 formattedBody: content["formatted_body"] as? String)
    }

    // MARK: Board links (markdown-host.test.tsx)

    func testBoardAndCardLinksParseToTheirTargets() {
        let boardURL = "https://atumplatform.com/#atum-board/\(company)/\(board)"
        XCTAssertEqual(CompanyBoardLinkTarget.parse(boardURL),
                       CompanyBoardLinkTarget(companyID: company, boardID: board))
        XCTAssertEqual(CompanyBoardLinkTarget.parse(boardURL)?.kind, .companyBoard)
        let cardURL = boardURL + "/card/\(card)"
        let target = CompanyBoardLinkTarget.parse(cardURL)
        XCTAssertEqual(target, CompanyBoardLinkTarget(companyID: company, boardID: board, cardID: card))
        XCTAssertEqual(target?.kind, .companyBoardCard)
        XCTAssertEqual(target?.url, cardURL)
    }

    func testLookalikesAndMalformedLinksAreOrdinaryWebLinks() {
        let tail = "#atum-board/\(company)/\(board)"
        for text in ["https://atumplatform.com.evil.test/\(tail)", "http://atumplatform.com/\(tail)",
                     "https://www.atumplatform.com/\(tail)", "https://atumplatform.com/x\(tail)",
                     "https://atumplatform.com/\(tail)/", "https://atumplatform.com/\(tail)\n",
                     "https://atumplatform.com/\(tail.uppercased())", " https://atumplatform.com/\(tail)",
                     "https://atumplatform.com/\(tail)/card/", "https://atumplatform.com/\(tail)/card/\(card)/x",
                     "https://atumplatform.com/#atum-board/\(company)", "https://atumplatform.com/#atum-store/x"] {
            XCTAssertNil(CompanyBoardLinkTarget.parse(text), text)
        }
    }

    // MARK: Greeting (message.test.ts:92-125, private-cos-greeting.test.tsx)

    func testFrozenBoardGreetingProjectsPillAndTitledLink() throws {
        let content = try fixture("greeting.matrix-content.json")
        let parsed = try XCTUnwrap(greeting(content))
        XCTAssertEqual(parsed.agentPill.userID, "@private-cos:atum.example")
        XCTAssertEqual(parsed.agentPill.label, "@Chief of Staff")
        XCTAssertEqual(parsed.agentPill.href, "https://matrix.to/#/@private-cos:atum.example")
        XCTAssertEqual(parsed.boardLink.title, "Open company board")
        XCTAssertEqual(parsed.boardLink.target.kind, .companyBoard)
        XCTAssertNil(parsed.boardLink.target.cardID)
        let markdown = parsed.markdown(body: content["body"] as? String ?? "")
        XCTAssertTrue(markdown.contains("[@Chief of Staff](https://matrix.to/#/@private-cos:atum.example)"))
        XCTAssertTrue(markdown.hasSuffix("\n\n[Open company board](\(parsed.boardLink.href))"))
    }

    func testFrozenCardGreetingKeepsTheEventsOwnTitle() throws {
        let content = try fixture("greeting.matrix-content.card.json")
        let parsed = try XCTUnwrap(greeting(content))
        XCTAssertEqual(parsed.boardLink.title, "How to use your company space")
        XCTAssertEqual(parsed.boardLink.target.kind, .companyBoardCard)
        XCTAssertEqual(parsed.boardLink.target.cardID, "37700000-0000-4000-8000-000000000003")
    }

    func testRenderedGreetingNeverShowsTheRawURL() throws {
        for name in ["greeting.matrix-content.json", "greeting.matrix-content.card.json"] {
            let content = try fixture(name)
            let parsed = try XCTUnwrap(greeting(content))
            var item = ChatItem(id: "$greeting", kind: .message, sender: "@private-cos:atum.example",
                                body: content["body"] as? String ?? "", privateCosGreeting: parsed)
            let rendered = try AttributedString(markdown: item.markdownBody,
                                                options: .init(interpretedSyntax: .full))
            let text = String(rendered.characters)
            XCTAssertFalse(text.contains("https://"), name)
            XCTAssertFalse(text.contains("<a"), name)
            XCTAssertTrue(text.contains("@Chief of Staff"), name)
            let links = rendered.runs.compactMap(\.link).map(\.absoluteString)
            XCTAssertEqual(links, ["https://matrix.to/#/@private-cos:atum.example", parsed.boardLink.href], name)
            // Copy keeps the body as sent.
            XCTAssertEqual(item.body, content["body"] as? String)
            item.privateCosGreeting = nil
            XCTAssertEqual(item.markdownBody, item.body)
        }
    }

    func testAnyDepartureFromTheFrozenShapeIsAnOrdinaryMessage() throws {
        let content = try fixture("greeting.matrix-content.json")
        let body = content["body"] as? String ?? ""
        let formatted = content["formatted_body"] as? String ?? ""
        XCTAssertNil(PrivateCosGreeting.parse(sender: "@private-cos:atum.example", body: body,
                                              format: nil, formattedBody: formatted))
        XCTAssertNil(PrivateCosGreeting.parse(sender: "@private-cos:atum.example", body: body,
                                              format: "org.matrix.custom.html", formattedBody: nil))
        // The pill must name the sender itself.
        XCTAssertNil(greeting(content, sender: "@someone-else:atum.example"))
        XCTAssertNil(greeting(content, sender: "private-cos"))
        // The plain body must end with the same "title: url" line.
        XCTAssertNil(PrivateCosGreeting.parse(sender: "@private-cos:atum.example", body: body + " ",
                                              format: "org.matrix.custom.html", formattedBody: formatted))
        XCTAssertNil(PrivateCosGreeting.parse(sender: "@private-cos:atum.example",
                                              body: body.replacingOccurrences(of: "Open company board:", with: "Board:"),
                                              format: "org.matrix.custom.html", formattedBody: formatted))
        // The board anchor must close the HTML and target an exact board link.
        XCTAssertNil(PrivateCosGreeting.parse(sender: "@private-cos:atum.example", body: body,
                                              format: "org.matrix.custom.html", formattedBody: formatted + "\n"))
        let lookalike = formatted.replacingOccurrences(of: "https://atumplatform.com/", with: "https://atumplatform.co/")
        XCTAssertNil(PrivateCosGreeting.parse(sender: "@private-cos:atum.example",
                                              body: body.replacingOccurrences(of: "https://atumplatform.com/",
                                                                              with: "https://atumplatform.co/"),
                                              format: "org.matrix.custom.html", formattedBody: lookalike))
        // No pill anchor, no greeting.
        XCTAssertNil(PrivateCosGreeting.parse(sender: "@private-cos:atum.example", body: body,
                                              format: "org.matrix.custom.html",
                                              formattedBody: formatted.replacingOccurrences(of: "matrix.to", with: "matrix.example")))
    }
}
