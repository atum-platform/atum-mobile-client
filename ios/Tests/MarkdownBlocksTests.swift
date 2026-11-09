import Foundation
import XCTest
@testable import AtumNativeAPI

/// The blocks the chat lays out for an answer (B17): what an agent writes
/// must keep its structure once Textual is gone.
final class MarkdownBlocksTests: XCTestCase {
    private func blocks(_ markdown: String) -> [MarkdownBlocks.Block] {
        MarkdownBlocks.blocks(MessageMarkup.parse(markdown))
    }

    private func plain(_ text: AttributedString) -> String { String(text.characters) }

    func testATableKeepsItsHeaderRowAndEveryCellInItsColumn() {
        let result = blocks("Bảng giá:\n\n| Gói | Giá | Ghi chú |\n|---|---|---|\n| A | 1 | |\n|  | 2 | rẻ |")
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0].kind, .paragraph)
        guard case let .tableRow(header, isHeader) = result[1].kind else { return XCTFail("no header row: \(result[1].kind)") }
        XCTAssertTrue(isHeader)
        XCTAssertEqual(header.map(plain), ["Gói", "Giá", "Ghi chú"])
        guard case let .tableRow(first, firstIsHeader) = result[2].kind,
              case let .tableRow(second, _) = result[3].kind else { return XCTFail("missing body rows") }
        XCTAssertFalse(firstIsHeader)
        // An empty cell keeps its column: nothing slides left.
        XCTAssertEqual(first.map(plain), ["A", "1", ""])
        XCTAssertEqual(second.map(plain), ["", "2", "rẻ"])
        XCTAssertEqual(result.map(\.id), Array(result.indices), "a block's ID is its place")
    }

    func testNestedListsKeepMarkersDepthAndLaterParagraphs() {
        let result = blocks("- một\n  - hai\n    - ba\n- bốn\n\n  thêm về bốn\n\n1. đầu\n2. sau")
        XCTAssertEqual(result.map(\.kind), [.listItem(marker: "•"), .listItem(marker: "•"), .listItem(marker: "•"),
                                            .listItem(marker: "•"), .continuation,
                                            .listItem(marker: "1."), .listItem(marker: "2.")])
        XCTAssertEqual(result.map(\.depth), [0, 1, 2, 0, 0, 0, 0])
        XCTAssertEqual(result.map { plain($0.text) }, ["một", "hai", "ba", "bốn", "thêm về bốn", "đầu", "sau"])
    }

    func testACodeBlockIsOneBlockWithItsBlankLinesAndNoTrailingNewline() {
        let result = blocks("Chạy:\n\n```swift\nlet a = 1\n\nlet b = 2\n```\n\nXong.")
        XCTAssertEqual(result.map(\.kind), [.paragraph, .code, .paragraph])
        XCTAssertEqual(plain(result[1].text), "let a = 1\n\nlet b = 2")
    }

    func testHeadingsQuotesAndRules() {
        let result = blocks("# Tiêu đề\n\n### Nhỏ\n\n> trích dẫn\n\n---\n\nhết")
        XCTAssertEqual(result.map(\.kind), [.heading(1), .heading(3), .quote, .rule, .paragraph])
        XCTAssertEqual(plain(result[2].text), "trích dẫn")
    }

    func testLinksAreListedWithTheirShownText() {
        let value = MessageMarkup.parse("Xem [trang **Moon**](https://atumplatform.com/moon) và https://pay.payos.vn/web/x")
        let links = MarkdownBlocks.links(in: value)
        XCTAssertEqual(links.map(\.text), ["trang Moon", "https://pay.payos.vn/web/x"])
        XCTAssertEqual(links.map(\.url.absoluteString), ["https://atumplatform.com/moon", "https://pay.payos.vn/web/x"])
        XCTAssertTrue(MarkdownBlocks.links(in: MessageMarkup.parse("không có liên kết")).isEmpty)
    }

    /// B21: a quote of an answer reads as the answer looks, never as its
    /// markdown source (the S1 review's `**Dự án Góc Phố** là… - Tạo lịch…`).
    func testPlainTextForAQuoteDropsTheMarkdown() {
        XCTAssertEqual(MarkdownBlocks.plainText("**bold**\n\n- item"), "bold item")
        XCTAssertEqual(MarkdownBlocks.plainText("**Dự án Góc Phố** là quán cà phê.\n\n- Tạo lịch\n- Gửi _thư_ mời"),
                       "Dự án Góc Phố là quán cà phê. Tạo lịch Gửi thư mời")
        XCTAssertEqual(MarkdownBlocks.plainText("# Tiêu đề\n\n1. một\n2. hai\n\n---\n\n`mã`"), "Tiêu đề một hai mã")
        XCTAssertEqual(MarkdownBlocks.plainText("| Gói | Giá |\n|---|---|\n| A | 1 |"), "Gói Giá A 1")
        XCTAssertEqual(MarkdownBlocks.plainText("xem [trang Moon](https://atumplatform.com/moon)"), "xem trang Moon")
        XCTAssertEqual(MarkdownBlocks.plainText("chỉ là chữ"), "chỉ là chữ")
    }
}
