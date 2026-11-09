import XCTest
@testable import AtumNativeAPI

final class AgentHomePlacementCopyTests: XCTestCase {
    func testEveryWordIsSaidInEveryLanguage() {
        XCTAssertEqual(Set(AgentHomePlacementCopy.locales), ["en", "vi", "ja", "zh", "zh-Hant"])

        for locale in AgentHomePlacementCopy.locales {
            for key in AgentHomePlacementCopy.Key.allCases {
                let text = AgentHomePlacementCopy.text(key, locale: locale, name: "Mac mini")
                XCTAssertGreaterThan(text.count, 8, "\(locale) \(key)")
                // A name goes where the text has a place for it, and no template marker is ever left behind.
                XCTAssertFalse(text.contains("%1$@"), "\(locale) \(key)")
                XCTAssertFalse(text.contains("_"), "\(locale) \(key): words, not codes")
            }
        }
    }

    func testTheMacsNameIsPutWhereTheTextHasAPlaceForIt() {
        for locale in AgentHomePlacementCopy.locales {
            XCTAssertTrue(AgentHomePlacementCopy.text(.waitingForHome, locale: locale, name: "Mac mini").contains("Mac mini"), locale)
            XCTAssertTrue(AgentHomePlacementCopy.text(.waitingForMac, locale: locale, name: "Mac mini").contains("Mac mini"), locale)
            // These talk about "this Mac" / "that Mac": the row names it.
            XCTAssertFalse(AgentHomePlacementCopy.text(.openAtumOnMac, locale: locale, name: "Mac mini").contains("Mac mini"), locale)
        }
    }

    func testASetUpMacIsToldWhatToDoNotJustThatModelsAreMissing() {
        XCTAssertEqual(AgentHomePlacementCopy.text(.openAtumOnMac, locale: "en"), "Open Atum on this Mac to set it up")
        XCTAssertEqual(AgentHomePlacementCopy.text(.openAtumOnMac, locale: "vi"), "Mở Atum trên máy Mac này để thiết lập")
        XCTAssertEqual(AgentHomePlacementCopy.text(.openAtumOnMac, locale: "ja"), "この Mac で Atum を開いて設定してください")
        XCTAssertEqual(AgentHomePlacementCopy.text(.openAtumOnMac, locale: "zh"), "请在这台 Mac 上打开 Atum 完成设置")
        XCTAssertEqual(AgentHomePlacementCopy.text(.openAtumOnMac, locale: "zh-Hant"), "請在這部 Mac 上開啟 Atum 完成設定")
    }

    func testALocaleItDoesNotKnowIsEnglishAndTheTraditionalTagIsMatchedWhateverItsCase() {
        let english = AgentHomePlacementCopy.text(.openAtumOnMac, locale: "en")
        XCTAssertEqual(AgentHomePlacementCopy.text(.openAtumOnMac, locale: "de"), english)
        XCTAssertEqual(AgentHomePlacementCopy.text(.openAtumOnMac, locale: "zh-hant"),
                       AgentHomePlacementCopy.text(.openAtumOnMac, locale: "zh-Hant"))
    }
}
