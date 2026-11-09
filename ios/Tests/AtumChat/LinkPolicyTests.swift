import XCTest
@testable import AtumChat

/// B17 and §4.2 item 6: every link tap goes through one gate; purchase pages
/// and routes never open on iOS.
final class LinkPolicyTests: XCTestCase {
    private func decision(_ text: String) -> LinkPolicy.Decision { LinkPolicy.decision(for: text) }

    func testOrdinaryWebLinksOpenInTheApp() {
        for text in ["https://atumplatform.com", "https://atumplatform.com/moon?x=1#top", "http://example.com/a b",
                     "HTTPS://Example.COM/Path"] {
            guard case let .openInApp(url) = decision(text.replacingOccurrences(of: " ", with: "%20")) else {
                return XCTFail("\(text) should open")
            }
            XCTAssertNotNil(url.host)
        }
    }

    func testPayOSAndVietQRAreHeldWithTheirSubdomains() {
        for text in ["https://pay.payos.vn/web/abc", "https://payos.vn", "https://PAY.PayOS.vn/web/abc",
                     "http://payos.vn./checkout", "https://a.b.payos.vn", "https://img.vietqr.io/image/x.png",
                     "https://vietqr.net", "https://pay%2Epayos.vn/web/abc", "https://example.com@pay.payos.vn/x"] {
            XCTAssertEqual(decision(text), .hold, text)
        }
    }

    func testLookalikesAreNotPurchaseHosts() {
        // Only the host decides: a path, query, user info or a longer host
        // that merely ends in the same letters is an ordinary page.
        for text in ["https://notpayos.vn", "https://payos.vn.example.com", "https://example.com/payos.vn",
                     "https://example.com/?next=https://pay.payos.vn", "https://payos.vn@example.com"] {
            guard case .openInApp = decision(text) else { return XCTFail("\(text) should open") }
        }
    }

    func testAnythingButAWebLinkIsRefused() {
        for text in ["mailto:someone@example.test", "tel:+12025550133", "javascript:alert(1)", "file:///etc/hosts",
                     "atum://open", "https://", "not a url", "", "//payos.vn/x"] {
            XCTAssertEqual(decision(text), .refuse, text)
        }
    }

    func testTheURLAndTextFormsAgree() {
        // Markdown links (answers, notices, people's messages) arrive as URLs,
        // bot buttons (S5) as text: one rule for every source.
        for text in ["https://atumplatform.com/moon", "https://pay.payos.vn/web/x", "mailto:a@b.test"] {
            let url = URL(string: text)
            XCTAssertEqual(url.map(LinkPolicy.decision(for:)), decision(text), text)
        }
    }

    func testOnlyTheAppsPurchaseRouteIsHeld() {
        XCTAssertTrue(LinkPolicy.holdsAppRoute("top-up", purchaseRouteID: "top-up"))
        XCTAssertFalse(LinkPolicy.holdsAppRoute("readings", purchaseRouteID: "top-up"))
        XCTAssertFalse(LinkPolicy.holdsAppRoute("chat", purchaseRouteID: nil))
        XCTAssertFalse(LinkPolicy.holdsAppRoute("chat", purchaseRouteID: ""))
    }
}
