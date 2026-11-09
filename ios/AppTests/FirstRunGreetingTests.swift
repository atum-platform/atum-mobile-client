@testable import AtumMobile
import XCTest

@MainActor
final class FirstRunGreetingTests: XCTestCase {
    func testOnlyUnseenMarkerWithPersistedAssistantNameOffersGreeting() {
        XCTAssertFalse(FirstRunPresentationPolicy.shouldOffer(marker: .unknown,
                                                              persistedAssistantName: "Mây"))
        XCTAssertFalse(FirstRunPresentationPolicy.shouldOffer(marker: .answered,
                                                              persistedAssistantName: "Mây"))
        XCTAssertFalse(FirstRunPresentationPolicy.shouldOffer(marker: .unseen,
                                                              persistedAssistantName: "  "))
        XCTAssertTrue(FirstRunPresentationPolicy.shouldOffer(marker: .unseen,
                                                             persistedAssistantName: "Mây"))
    }

    func testGreetingNameOmitsHandleAndComposerDraftIsPreservedExactly() {
        XCTAssertNil(FirstRunPresentationPolicy.firstName(displayName: "@minh:atum.example",
                                                           userID: "@minh:atum.example"))
        XCTAssertNil(FirstRunPresentationPolicy.firstName(displayName: "minh",
                                                           userID: "@minh:atum.example"))
        XCTAssertEqual(FirstRunPresentationPolicy.firstName(displayName: " Minh ",
                                                             userID: "@owner:atum.example"), "Minh")

        let draft = "  kế hoạch chưa gửi\n"
        XCTAssertTrue(FirstRunDraftPolicy.dismissesUnsolicitedPresentation(draft))
        XCTAssertEqual(FirstRunDraftPolicy.preserved(draft), draft)
    }

    func testFirstRunCopySelectsOnlyCanonicalGreetingKeysAndArguments() {
        var keys = [String]()
        var arguments = [[String]]()
        let copy = FirstRunCopy(resolve: { key, values in
            keys.append(key)
            arguments.append(values)
            return "resolved"
        })

        XCTAssertEqual(copy.greeting(firstName: "Minh", assistantName: "Mây"), "resolved")
        XCTAssertEqual(copy.greeting(firstName: nil, assistantName: "Mây"), "resolved")

        XCTAssertEqual(keys, [
            "shared.matrix-first-run-copy.copies.greeting",
            "shared.matrix-first-run-copy.copies.greeting.firstName=null"
        ])
        XCTAssertEqual(arguments, [["Minh", "Mây"], ["", "Mây"]])
        XCTAssertEqual(Set(FirstRunCopyKey.allCases), [.greeting, .greetingWithoutFirstName])
    }

    func testPinnedGreetingResolvesInAllFiveLocales() throws {
        let design = try LiveDesign()
        for locale in ["en", "vi", "ja", "zh", "zh-Hant"] {
            let copy = FirstRunCopy(design: design, locale: locale)
            let name = "100% Minh"
            let assistantName = "Mây 100%"
            let greeting = copy.greeting(firstName: name, assistantName: assistantName)
            XCTAssertFalse(greeting.isEmpty, locale)
            XCTAssertTrue(greeting.contains(name), "\(locale): \(greeting)")
            XCTAssertTrue(greeting.contains(assistantName), "\(locale): \(greeting)")

            let noFirstName = copy.greeting(firstName: nil, assistantName: assistantName)
            XCTAssertFalse(noFirstName.isEmpty, locale)
            XCTAssertTrue(noFirstName.contains(assistantName), "\(locale): \(noFirstName)")
            XCTAssertFalse(noFirstName.contains(name), "\(locale): \(noFirstName)")
        }
    }

    func testPreferredLanguageNegotiationMapsOntoPinnedLocales() throws {
        let supported: Set<String> = ["en", "vi", "ja", "zh", "zh-Hant"]
        let selected: ([String]) -> String = { languages in
            LiveDesignLocaleSelection.selectedLocale(preferredLanguages: languages,
                                                     supported: supported)
        }

        XCTAssertEqual(selected(["zh-Hans-CN"]), "zh")
        XCTAssertEqual(selected(["zh-CN"]), "zh")
        XCTAssertEqual(selected(["zh"]), "zh")
        XCTAssertEqual(selected(["zh-Hant-TW"]), "zh-Hant")
        XCTAssertEqual(selected(["vi-VN"]), "vi")
        XCTAssertEqual(selected(["ja-JP"]), "ja")
        XCTAssertEqual(selected(["en-US"]), "en")
        XCTAssertEqual(selected(["fr-FR", "ja-JP"]), "en")
        XCTAssertEqual(selected(["fr-FR"]), "en")
        XCTAssertEqual(selected([]), "vi")

        let design = try LiveDesign()
        for language in ["zh-Hans-CN", "zh-CN", "zh-Hant-TW", "vi-VN", "ja-JP", "en-US"] {
            XCTAssertTrue(design.copy.locales.contains(selected([language])),
                          "\(language) negotiated an unsupported locale")
        }
    }
}
