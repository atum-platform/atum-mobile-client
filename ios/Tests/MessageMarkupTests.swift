import Foundation
import XCTest
@testable import AtumNativeAPI

final class MessageMarkupTests: XCTestCase {
    func testEncryptedBodyNeverSchedulesRemoteImages() {
        let value = MessageMarkup.parse("Text ![private image](https://tracker.example/image.png) and ![local](file:///private/image).")
        XCTAssertTrue(value.runs.allSatisfy { $0.imageURL == nil })
        XCTAssertTrue(String(value.characters).contains("private image"))
        XCTAssertTrue(String(value.characters).contains("local"))
    }
    func testExplicitWebLinksSurviveAndOtherSchemesArePlainText() {
        let value = MessageMarkup.parse("[Web](https://example.com/path) [HTTP](http://example.com) [File](file:///private) [Run](javascript:alert) [Mail](mailto:test@example.com)")
        let links = value.runs.compactMap(\.link)
        XCTAssertEqual(Set(links.map { $0.scheme! }), ["https", "http"])
        XCTAssertEqual(links.count, 2)
        XCTAssertTrue(String(value.characters).contains("Run"))
        XCTAssertFalse(MessageMarkup.canOpen(URL(string: "https:relative")!))
    }
    func testMarkdownStructureAndUnicodeSurvivePrivacyPass() {
        let value = MessageMarkup.parse("# Kế hoạch 🌗\n\n- 日本語\n- 繁體中文\n\n```swift\nlet reply = 1\n```\n\n> A quoted reply")
        XCTAssertTrue(value.runs.contains { $0.presentationIntent != nil })
        XCTAssertTrue(String(value.characters).contains("Kế hoạch 🌗"))
        XCTAssertTrue(String(value.characters).contains("let reply = 1"))
        XCTAssertTrue(String(value.characters).contains("繁體中文"))
    }

    func testBareWebAddressesBecomeLinksButCodeMailAndExistingLinksDoNot() {
        let value = MessageMarkup.parse("Xem tại https://atumplatform.com/moon. Thanh toán: https://pay.payos.vn/web/x\n\n" +
                                        "`https://in.code.test` mail a@b.test [Web](https://example.com)")
        let links = value.runs.compactMap(\.link).map(\.absoluteString)
        XCTAssertEqual(links, ["https://atumplatform.com/moon", "https://pay.payos.vn/web/x", "https://example.com"])
        XCTAssertTrue(String(value.characters).contains("https://in.code.test"))
    }

    func testBotAPIHTMLRendersOnlyAfterItsDedicatedSafeParser() {
        let value = MessageMarkup.parseBotAPIHTML(
            "Choose <strong>one</strong>, <em>carefully</em>, then " +
                "<a href=\"https://moon.example/r#today\">open</a>.",
            fallback: "fallback"
        )
        XCTAssertEqual(String(value.characters), "Choose one, carefully, then open.")
        XCTAssertTrue(value.runs.contains {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        })
        XCTAssertTrue(value.runs.contains {
            $0.inlinePresentationIntent?.contains(.emphasized) == true
        })
        XCTAssertEqual(value.runs.compactMap(\.link).map(\.absoluteString),
                       ["https://moon.example/r#today"])

        let refused = MessageMarkup.parseBotAPIHTML(
            "<img src=\"https://tracker.example/private.png\">",
            fallback: "Safe fallback"
        )
        XCTAssertEqual(String(refused.characters), "Safe fallback")
        XCTAssertTrue(refused.runs.allSatisfy { $0.imageURL == nil })
    }

    func testBotAPIPlainBodyDoesNotInventMarkdown() {
        let value = MessageMarkup.parsePlain("*literal* https://atumplatform.com")
        XCTAssertEqual(String(value.characters), "*literal* https://atumplatform.com")
        XCTAssertFalse(value.runs.contains { $0.inlinePresentationIntent != nil })
        XCTAssertEqual(value.runs.compactMap(\.link).map(\.absoluteString),
                       ["https://atumplatform.com"])
    }
}
