import XCTest
@testable import AtumChat

/// The routine words the pin does not carry yet come from desktop's own
/// five-locale tables, so no locale reads another language (D-5).
final class AssistantCardPendingCopyTests: XCTestCase {
    func testTheRoutineCountSpeaksTheAppLanguage() {
        XCTAssertEqual(AssistantRoutinePendingCopy.count(0, locale: "en"), "No routines")
        XCTAssertEqual(AssistantRoutinePendingCopy.count(1, locale: "en"), "1 routine")
        XCTAssertEqual(AssistantRoutinePendingCopy.count(3, locale: "en"), "3 routines")
        XCTAssertEqual(AssistantRoutinePendingCopy.count(0, locale: "vi"), "Chưa có")
        XCTAssertEqual(AssistantRoutinePendingCopy.count(-1, locale: "vi"), "Chưa có")
        XCTAssertEqual(AssistantRoutinePendingCopy.count(64, locale: "vi"), "64 việc")
        XCTAssertEqual(AssistantRoutinePendingCopy.count(2, locale: "ja"), "2件")
        XCTAssertEqual(AssistantRoutinePendingCopy.count(0, locale: "zh"), "还没有")
        XCTAssertEqual(AssistantRoutinePendingCopy.count(2, locale: "zh-Hant"), "2 項")
    }

    func testNoNonVietnameseLocaleShowsVietnamese() {
        let vietnamese = CharacterSet(charactersIn: "ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ")
        for locale in AssistantRoutinePendingCopy.locales where locale != "vi" {
            var values = AssistantRoutinePendingCopy.Key.allCases.map {
                AssistantRoutinePendingCopy.text($0, locale: locale, name: "Atum")
            }
            values += [0, 1, 5].map { AssistantRoutinePendingCopy.count($0, locale: locale) }
            for value in values {
                XCTAssertNil(value.lowercased().rangeOfCharacter(from: vietnamese), "\(locale): \(value)")
            }
        }
    }

    func testJapaneseAndChineseHaveNoEnglishWords() {
        for locale in ["ja", "zh", "zh-Hant"] {
            var values = AssistantRoutinePendingCopy.Key.allCases.map {
                AssistantRoutinePendingCopy.text($0, locale: locale, name: "")
            }
            values += [0, 3].map { AssistantRoutinePendingCopy.count($0, locale: locale) }
            for value in values {
                XCTAssertNil(value.rangeOfCharacter(from: .init(charactersIn: "abcdefghijklmnopqrstuvwxyz")),
                             "\(locale): \(value)")
            }
        }
    }

    func testEveryLocaleHasEveryKeyAndFillsTheName() {
        for locale in AssistantRoutinePendingCopy.locales {
            for key in AssistantRoutinePendingCopy.Key.allCases {
                let value = AssistantRoutinePendingCopy.text(key, locale: locale, name: "Mai")
                XCTAssertNotEqual(value, key.rawValue, "\(locale) \(key) fell through")
                XCTAssertFalse(value.contains("%1$@"), "\(locale) \(key) kept its placeholder")
            }
        }
        XCTAssertEqual(AssistantRoutinePendingCopy.text(.routineLoadFailed, locale: "en", name: "Mai"),
                       "Couldn’t load Mai’s routines.")
        XCTAssertEqual(AssistantRoutinePendingCopy.text(.routineReadOnly, locale: "vi"), "Chỉ xem")
    }

    func testSkillNamesReadLikeDesktop() {
        XCTAssertEqual(AssistantSkillLabel.label("google-calendar"), "Google calendar")
        XCTAssertEqual(AssistantSkillLabel.label("web_search"), "Web search")
        XCTAssertEqual(AssistantSkillLabel.label("  deep--research__notes "), "Deep research notes")
        XCTAssertEqual(AssistantSkillLabel.label("Already Nice"), "Already Nice")
        XCTAssertEqual(AssistantSkillLabel.label("---"), "---")
    }

    func testCardRowsShowPetOnlyWithAStoreAndSkillsOnlyWhenThereAreAny() {
        XCTAssertTrue(AssistantCardLayout.showsPet(storeAvailable: true))
        XCTAssertFalse(AssistantCardLayout.showsPet(storeAvailable: false))
        XCTAssertFalse(AssistantCardLayout.showsSkills(count: 0))
        XCTAssertTrue(AssistantCardLayout.showsSkills(count: 3))
    }
}

/// D-8: the "where it lives" words the pin lacks are desktop's own, in every
/// locale, so Japanese and Chinese never read English and only Vietnamese
/// reads Vietnamese.
final class AgentHomePendingCopyTests: XCTestCase {
    private let vietnamese = CharacterSet(charactersIn: "ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ")

    func testEveryKeyIsWrittenInEveryLocale() {
        for locale in AgentHomePendingCopy.locales {
            for key in AgentHomePendingCopy.Key.allCases {
                let value = AgentHomePendingCopy.text(key, locale: locale, argument: "X")
                XCTAssertFalse(value.isEmpty, "\(locale) \(key)")
                XCTAssertNotEqual(value, key.rawValue, "\(locale) \(key) fell through")
                XCTAssertFalse(value.contains("%1$@"), "\(locale) \(key) kept its placeholder")
                if locale != "vi" {
                    XCTAssertNil(value.lowercased().rangeOfCharacter(from: vietnamese), "\(locale) \(key): \(value)")
                }
                if ["ja", "zh", "zh-Hant"].contains(locale) {
                    XCTAssertNotEqual(value, AgentHomePendingCopy.text(key, locale: "en", argument: "X"),
                                      "\(locale) \(key) is English")
                }
            }
        }
    }

    func testTheValuesAreDesktops() {
        XCTAssertEqual(AgentHomePendingCopy.text(.finding, locale: "en"), "Finding where it lives…")
        XCTAssertEqual(AgentHomePendingCopy.text(.retryRead, locale: "ja"), "もう一度試す")
        XCTAssertEqual(AgentHomePendingCopy.text(.lastCheckpoint, locale: "zh", argument: "10:00"), "上次检查点：10:00")
        XCTAssertEqual(AgentHomePendingCopy.text(.unnamedMac, locale: "zh-Hant"), "另一部 Mac")
        XCTAssertNil(AgentHomePendingCopy.exportKey(.unnamedMac))
        XCTAssertEqual(AgentHomePendingCopy.exportKey(.refusalCatalogStale),
                       "src.matrix.agent-home-copy.words.refusals.catalog_stale")
    }
}
