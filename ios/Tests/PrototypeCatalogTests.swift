import XCTest
import AtumDesign
import AtumPrototype

final class PrototypeCatalogTests: XCTestCase {
    func testEveryReachableStringResolvesUsingPinnedSourceInEveryLocale() throws {
        let catalog = try PrototypeCatalog.load()
        let copy = try AtumCopy()
        func verify(_ value: PrototypeCatalog.Text) throws {
            XCTAssertNotEqual(value.key?.hasPrefix("proposal."), true)
            for locale in copy.locales { _ = try value.resolve(using: copy, locale: locale) }
        }
        for value in catalog.uiCopy.values { try verify(value) }
        for screen in catalog.screens {
            try verify(screen.title); try verify(screen.body)
            for row in screen.rows + screen.inputs + screen.actions + screen.states.flatMap(\.actions) {
                try verify(row.label); try verify(row.detail); try verify(row.value)
                if !row.route.isEmpty { XCTAssertEqual(try catalog.screen(row.route).id, row.route) }
            }
            for state in screen.states { try verify(state.text) }
        }
    }

    func testFormatterArgumentsSurviveMigrationWithoutCoercion() throws {
        let catalog = try PrototypeCatalog.load()
        let copy = try AtumCopy()
        let saveFile = try catalog.screen("message-menu").rows.first { $0.label.key?.hasSuffix("saveFile") == true }!
        XCTAssertEqual(try saveFile.label.resolve(using: copy, locale: "vi"),
                       try copy.text(saveFile.label.key!, locale: "vi", arguments: [.text("demo.pdf")]))
        let result = try catalog.screen("chat-search").rows[0].label
        XCTAssertEqual(try result.resolve(using: copy, locale: "ja"),
                       try copy.text(result.key!, locale: "ja", arguments: [.number(1), .number(3)]))
    }

    func testDomainOutcomesRemainDistinctAndUnknownRoutesFail() throws {
        let catalog = try PrototypeCatalog.load()
        let copy = try AtumCopy()
        for locale in copy.locales {
            let owner = try catalog.state("blocked-owner", in: "deletion").text.resolve(using: copy, locale: locale)
            let payout = try catalog.state("blocked-payout", in: "deletion").text.resolve(using: copy, locale: locale)
            let reconciliation = try catalog.state("reconciliation", in: "deletion").text.resolve(using: copy, locale: locale)
            XCTAssertEqual(Set([owner, payout, reconciliation]).count, 3)
            XCTAssertNotEqual(try catalog.state("not-answered", in: "outcome").text.resolve(using: copy, locale: locale),
                              try catalog.state("send-failed", in: "outcome").text.resolve(using: copy, locale: locale))
        }
        XCTAssertThrowsError(try catalog.screen("not-a-route"))
        XCTAssertThrowsError(try catalog.state("complete", in: "deletion"))
    }
}
