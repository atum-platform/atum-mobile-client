import XCTest
@testable import AtumChat

/// AS-3/AS-5: an assistant's handle as desktop's `handle-rules.ts` reads it.
final class AgentHandleRulesTests: XCTestCase {
    func testANameSuggestsItsOwnHandle() {
        XCTAssertEqual(AgentHandleRules.suggested(forName: "Tiếp thị"), "tiep_thi_bot")
        XCTAssertEqual(AgentHandleRules.suggested(forName: "Trợ lý Đức"), "tro_ly_duc_bot")
        XCTAssertEqual(AgentHandleRules.suggested(forName: "  Alfred  "), "alfred_bot")
        XCTAssertEqual(AgentHandleRules.suggested(forName: "007 Bond"), "bond_bot")
        XCTAssertEqual(AgentHandleRules.suggested(forName: "小助手"), "")
        XCTAssertEqual(AgentHandleRules.suggested(forName: ""), "")
        XCTAssertEqual(AgentHandleRules.suggested(forName: nil), "")
    }

    func testTypingReadsAsAStemWithoutTheFixedEnding() {
        XCTAssertEqual(AgentHandleRules.typedStem("@Bếp Trưởng_bot"), "bep_truong")
        XCTAssertEqual(AgentHandleRules.typedStem("tro_ly_botanic"), "tro_ly_botanic")
        XCTAssertEqual(AgentHandleRules.typedStem("lan___"), "lan")
        XCTAssertEqual(AgentHandleRules.typedStem("a b"), "a_b")
        XCTAssertEqual(AgentHandleRules.typedStem(String(repeating: "x", count: 40)).count,
                       AgentHandleRules.stemMaximum)
        XCTAssertEqual(AgentHandleRules.stem(ofHandle: "tiep_thi_bot"), "tiep_thi")
        XCTAssertEqual(AgentHandleRules.handle(fromStem: "lan"), "lan_bot")
        XCTAssertEqual(AgentHandleRules.handle(fromStem: ""), "")
    }

    func testLocalProblemsAreTheGrammarAndTheBotEnding() {
        XCTAssertEqual(AgentHandleRules.localProblem("ab_bot"), nil)
        XCTAssertEqual(AgentHandleRules.localProblem("ab"), .invalid)
        XCTAssertEqual(AgentHandleRules.localProblem("1lan_bot"), .invalid)
        XCTAssertEqual(AgentHandleRules.localProblem("Lan_bot"), .invalid)
        XCTAssertEqual(AgentHandleRules.localProblem("alfred"), .botRequired)
        XCTAssertEqual(AgentHandleRules.checkProblem(nil), nil)
        XCTAssertEqual(AgentHandleRules.checkProblem("alias_reserved"), .reserved)
        XCTAssertEqual(AgentHandleRules.checkProblem("alias_unavailable"), .unavailable)
        XCTAssertEqual(AgentHandleRules.checkProblem("alias_bot_suffix_required"), .botRequired)
        XCTAssertEqual(AgentHandleRules.checkProblem("something_new"), .unavailable)
    }

    func testCandidatesTryTheChosenStemThenTheNameThenTheFallback() {
        let groups = AgentHandleRules.candidates(name: "Tiếp thị", chosenStem: "marketing",
                                                 random: { 0 })
        XCTAssertEqual(groups.map { $0.first }, ["marketing_bot", "tiep_thi_bot", "tro_thu_bot"])
        XCTAssertEqual(groups[0], ["marketing_bot", "marketing10_bot", "marketing100_bot",
                                   "marketing1000_bot"])
        for handle in groups.flatMap({ $0 }) {
            XCTAssertNil(AgentHandleRules.localProblem(handle), handle)
        }
        // A name with no Latin letters still gets the fallback.
        XCTAssertEqual(AgentHandleRules.candidates(name: "小助手", random: { 0 }).map { $0.first },
                       ["tro_thu_bot"])
        // The same stem is never tried twice.
        XCTAssertEqual(AgentHandleRules.candidates(name: "Lan", chosenStem: "lan", random: { 0 }).count, 2)
    }

    func testNumbersKeepTheHandleWithinThirtyTwoAndSeparateADigit() {
        XCTAssertEqual(AgentHandleRules.numbered(stem: "lan", random: { 0 }), "lan10_bot")
        XCTAssertEqual(AgentHandleRules.numbered(stem: "agent7", random: { 0 }), "agent7_10_bot")
        let long = String(repeating: "a", count: AgentHandleRules.stemMaximum)
        for handle in AgentHandleRules.candidates(name: nil, chosenStem: long, random: { 0.999 })[0] {
            XCTAssertLessThanOrEqual(handle.count, 32, handle)
            XCTAssertTrue(handle.hasSuffix("_bot"))
        }
    }
}

/// AS-6: desktop's routine sentences and next-run line.
final class AssistantRoutineWordsTests: XCTestCase {
    private func resolve(_ locale: String) -> AssistantRoutineWords.Resolve {
        { AssistantRoutinePolishCopy.text($0, locale: locale, arguments: $1) }
    }

    func testScheduleSentencesFollowDesktop() {
        let zone = "Asia/Ho_Chi_Minh"
        XCTAssertEqual(AssistantRoutineWords.schedule(.daily(hour: 8, minute: 5), timezone: zone,
                                                      locale: "en", resolve: resolve("en")),
                       "Every day at 8:05")
        XCTAssertEqual(AssistantRoutineWords.schedule(.weekly(hour: 9, minute: 30, weekdays: [1, 3, 5]),
                                                      timezone: zone, locale: "en", resolve: resolve("en")),
                       "Mon, Wed, Fri at 9:30")
        XCTAssertEqual(AssistantRoutineWords.schedule(.weekly(hour: 9, minute: 30, weekdays: [1, 3]),
                                                      timezone: zone, locale: "vi", resolve: resolve("vi")),
                       "Thứ 2, 4 lúc 9:30")
        XCTAssertEqual(AssistantRoutineWords.schedule(.weekly(hour: 7, minute: 0, weekdays: [7]),
                                                      timezone: zone, locale: "vi", resolve: resolve("vi")),
                       "Chủ nhật lúc 7:00")
        XCTAssertEqual(AssistantRoutineWords.schedule(.weekly(hour: 7, minute: 0, weekdays: [1, 2]),
                                                      timezone: zone, locale: "ja", resolve: resolve("ja")),
                       "月・火 7:00")
        XCTAssertEqual(AssistantRoutineWords.schedule(.monthly(day: 15, hour: 17, minute: 30),
                                                      timezone: zone, locale: "en", resolve: resolve("en")),
                       "Monthly on day 15 at 17:30")
        XCTAssertEqual(AssistantRoutineWords.schedule(.other, timezone: zone, locale: "zh", resolve: resolve("zh")),
                       "其他计划")
        let once = ISO8601DateFormatter().date(from: "2026-10-21T01:00:00Z")!
        XCTAssertEqual(AssistantRoutineWords.schedule(.once(once), timezone: zone, locale: "vi",
                                                      resolve: resolve("vi")),
                       "Một lần, 21/10 8:00")
    }

    func testNextRunSaysTodayTomorrowOrTheDateAndTheZoneOnlyWhenItDiffers() {
        let zone = "Asia/Ho_Chi_Minh"
        let device = TimeZone(identifier: zone)!
        let now = ISO8601DateFormatter().date(from: "2026-11-11T01:00:00Z")! // 08:00 local
        let today = now.addingTimeInterval(3 * 3_600)
        let tomorrow = now.addingTimeInterval(24 * 3_600)
        XCTAssertEqual(AssistantRoutineWords.next(at: today, enabled: true, timezone: zone, deviceTimeZone: device,
                                                  now: now, locale: "en", resolve: resolve("en")),
                       "Next run: today 11:00")
        XCTAssertEqual(AssistantRoutineWords.next(at: tomorrow, enabled: true, timezone: zone, deviceTimeZone: device,
                                                  now: now, locale: "vi", resolve: resolve("vi")),
                       "Lần tới: ngày mai 8:00")
        XCTAssertEqual(AssistantRoutineWords.next(at: now.addingTimeInterval(5 * 86_400), enabled: true,
                                                  timezone: zone, deviceTimeZone: device, now: now,
                                                  locale: "vi", resolve: resolve("vi")),
                       "Lần tới: 16/11 8:00")
        // Asia/Saigon is the same clock: no zone name.
        XCTAssertEqual(AssistantRoutineWords.next(at: today, enabled: true, timezone: "Asia/Saigon",
                                                  deviceTimeZone: device, now: now, locale: "en",
                                                  resolve: resolve("en")),
                       "Next run: today 11:00")
        let other = AssistantRoutineWords.next(at: today, enabled: true, timezone: "Europe/Paris",
                                               deviceTimeZone: device, now: now, locale: "en",
                                               resolve: resolve("en"))
        XCTAssertEqual(other, "Next run: today 5:00 (Europe/Paris)")
        XCTAssertNil(AssistantRoutineWords.next(at: today, enabled: false, timezone: zone, deviceTimeZone: device,
                                                now: now, locale: "en", resolve: resolve("en")))
        XCTAssertNil(AssistantRoutineWords.next(at: nil, enabled: true, timezone: zone, deviceTimeZone: device,
                                                now: now, locale: "en", resolve: resolve("en")))
    }

    func testAnEmptyNameUsesTheInstructionsFirstWords() {
        XCTAssertEqual(AssistantRoutineWords.title(fromInstruction: "Summarise what matters today. Then send it."),
                       "Summarise what matters today.")
        XCTAssertEqual(AssistantRoutineWords.title(fromInstruction: "one two three four five six seven eight nine"),
                       "one two three four five six seven eight")
        XCTAssertEqual(AssistantRoutineWords.title(fromInstruction: "  Tóm   tắt\nhôm nay  "), "Tóm tắt hôm nay")
        XCTAssertEqual(AssistantRoutineWords.title(fromInstruction: String(repeating: "x", count: 200)).count, 120)
    }

    func testEveryPolishWordIsWrittenInEveryLocale() {
        let vietnamese = CharacterSet(charactersIn: "ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ")
        for locale in AssistantRoutinePolishCopy.locales {
            for key in AssistantRoutinePolishCopy.Key.allCases {
                let value = AssistantRoutinePolishCopy.text(key, locale: locale, arguments: ["1", "2"])
                XCTAssertNotEqual(value, key.rawValue, "\(locale) \(key)")
                XCTAssertFalse(value.contains("%1$@") || value.contains("%2$@"), "\(locale) \(key)")
                if locale != "vi" {
                    XCTAssertNil(value.lowercased().rangeOfCharacter(from: vietnamese), "\(locale): \(value)")
                }
                if ["ja", "zh", "zh-Hant"].contains(locale) {
                    XCTAssertNil(value.rangeOfCharacter(from: .init(charactersIn: "abcdefghijklmnopqrstuvwxyz")),
                                 "\(locale): \(value)")
                }
            }
        }
        XCTAssertEqual(AssistantRoutinePolishCopy.text(.routineQuotaReached, locale: "en", arguments: ["64"]),
                       "You have 64 routines. Delete one to add another.")
        XCTAssertEqual(AssistantRoutinePolishCopy.Key.routineSaveAndRun.exportKey,
                       "src.matrix.assistant-card.copy.assistantCardCopies.routineSaveAndRun")
    }

    func testWeekdayChipsAreDesktopsWords() {
        XCTAssertEqual(AssistantRoutineWords.weekdayChip(1, locale: "en"), "Mon")
        XCTAssertEqual(AssistantRoutineWords.weekdayChip(7, locale: "vi"), "CN")
        XCTAssertEqual(AssistantRoutineWords.weekdayChip(3, locale: "zh-Hant"), "週三")
        XCTAssertEqual(AssistantRoutineWords.weekdayList([6, 7], locale: "zh"), "周六、周日")
        XCTAssertEqual(AssistantRoutineWords.clock(hour: 17, minute: 0), "17:00")
    }
}

/// AS-4: desktop's delete wording and who may be deleted.
final class AssistantShellPendingCopyTests: XCTestCase {
    func testEveryRetireWordIsDesktopsInEveryLocale() {
        for locale in AssistantShellPendingCopy.locales {
            for key in AssistantShellPendingCopy.Key.allCases {
                let value = AssistantShellPendingCopy.text(key, locale: locale, name: "Mai")
                XCTAssertNotEqual(value, key.rawValue, "\(locale) \(key)")
                XCTAssertFalse(value.contains("%1$@"), "\(locale) \(key)")
            }
        }
        XCTAssertEqual(AssistantShellPendingCopy.text(.agentRetireTitle, locale: "en", name: "Mai"),
                       "Delete Mai permanently?")
        XCTAssertEqual(AssistantShellPendingCopy.text(.agentRetireBody, locale: "vi", name: "Mai")
            .components(separatedBy: "Mai").count - 1, 2)
        XCTAssertEqual(AssistantShellPendingCopy.text(.agentRetireConfirm, locale: "ja"), "削除")
        XCTAssertEqual(AssistantShellPendingCopy.Key.agentRetireBody.exportKey,
                       "desktop.matrixShell.agentRetireBody")
    }
}

/// AS-3: the sheet refuses only what the platform certainly refuses.
final class AssistantNameCheckTests: XCTestCase {
    func testTheSheetRefusesEmptyLongReservedDuplicateAndCheckMarkNames() {
        XCTAssertEqual(AssistantNameCheck.problem("   ", others: []), .empty)
        XCTAssertEqual(AssistantNameCheck.problem(String(repeating: "a", count: 41), others: []), .tooLong)
        XCTAssertNil(AssistantNameCheck.problem(String(repeating: "a", count: 40), others: []))
        XCTAssertEqual(AssistantNameCheck.problem("Moon", others: []), .reserved)
        XCTAssertEqual(AssistantNameCheck.problem("ATUM Bot", others: []), .reserved)
        XCTAssertEqual(AssistantNameCheck.problem("Lan ✓", others: []), .checkMark)
        XCTAssertEqual(AssistantNameCheck.problem(" lan ", others: ["Lan"]), .duplicate)
        XCTAssertEqual(AssistantNameCheck.problem("Thu  Hà", others: ["thu hà"]), .duplicate)
        // "Bến" is an ordinary Vietnamese name, not Ben.
        XCTAssertNil(AssistantNameCheck.problem("Bến", others: []))
        XCTAssertNil(AssistantNameCheck.problem("Tiếp thị", others: ["Lan"]))
        XCTAssertEqual(AssistantNameCheck.normalized("  Thu \n Hà "), "Thu Hà")
    }

    func testTheTwoAnswersBecomeDesktopsPersona() {
        XCTAssertNil(AssistantCreatePersona.soul(name: "Lan", who: " ", job: ""))
        XCTAssertEqual(AssistantCreatePersona.soul(name: " Lan ", who: "Warm.", job: "Plans posts."),
                       "# Lan\n\n## Who you are\n\nWarm.\n\n## What you do\n\nPlans posts.")
        XCTAssertEqual(AssistantCreatePersona.soul(name: "Lan", who: "", job: "Plans posts."),
                       "# Lan\n\n## What you do\n\nPlans posts.")
        // The phone's own persona parser reads it back as the two fields.
        let parsed = AssistantPersonaPolicy.parse(
            AssistantCreatePersona.soul(name: "Lan", who: "Warm.", job: "Plans posts.")!)
        XCTAssertEqual(parsed.who, "Warm.")
        XCTAssertEqual(parsed.what, "Plans posts.")
    }
}
