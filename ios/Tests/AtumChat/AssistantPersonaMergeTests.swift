import XCTest
@testable import AtumChat

/// Desktop PR #95 parity: headings round-trip inside a field, edits merge by
/// field, and the quiet length hint (`matrix-assistant-persona.test.ts`,
/// `assistant-card.test.tsx` at desktop `46f5a518`).
final class AssistantPersonaMergeTests: XCTestCase {
    private let template = "# Lan\n\n## Who you are\n\nĐiềm tĩnh.\n\n## What you do\n\nLo lịch họp."
    private let sampleCustom =
        "# Sample Agent\n\nYou are Sample Agent, a personal assistant for the example user.\n\n## Working style\n\n- Keep the thread.\n- Be direct.\n"
    private let sampleWithPersonality =
        "# Sample Agent\n\nYou are Sample Agent, a personal assistant for the example user.\n\n## Working style\n\n- Keep the thread.\n\n## Who you are\n\nWarm, exact, and candid.\n\n## Memory\n\nRemember durable decisions.\n"
    private let primaryLine =
        "You are Lan, the person’s own assistant in the Atum app. If they give you another name, use it from then on and remember it."

    // MARK: Custom persona (desktop's two fields)

    func testCustomTextWithoutPersonalityRoundTripsByteForByte() {
        let parsed = AssistantPersonaPolicy.parse(sampleCustom)
        XCTAssertEqual(parsed.kind, .custom)
        XCTAssertEqual(parsed.heading, "Sample Agent")
        XCTAssertEqual(parsed.who, "")
        XCTAssertEqual(parsed.instructions,
                       "You are Sample Agent, a personal assistant for the example user.\n\n## Working style\n\n- Keep the thread.\n- Be direct.")
        let composed = AssistantPersonaPolicy.render(parsed, name: "Sample Agent")
        XCTAssertEqual(composed, sampleCustom)
        XCTAssertEqual(AssistantPersonaPolicy.render(AssistantPersonaPolicy.parse(composed), name: "Sample Agent"),
                       sampleCustom)
    }

    func testCustomPersonalityIsKeptOutOfTheMainField() {
        let parsed = AssistantPersonaPolicy.parse(sampleWithPersonality)
        XCTAssertEqual(parsed.kind, .custom)
        XCTAssertEqual(parsed.who, "Warm, exact, and candid.")
        XCTAssertEqual(parsed.instructions,
                       "You are Sample Agent, a personal assistant for the example user.\n\n## Working style\n\n- Keep the thread.\n\n## Memory\n\nRemember durable decisions.")
        XCTAssertEqual(AssistantPersonaPolicy.render(parsed, name: "Sample Agent"), sampleWithPersonality)
    }

    func testChangingOnlyACustomPersonalityKeepsEveryOtherByte() {
        let next = AssistantPersonaPolicy.render(AssistantPersonaPolicy.parse(sampleWithPersonality),
                                                 name: "Sample Agent", who: "Calm under pressure.")
        XCTAssertEqual(next, sampleWithPersonality.replacingOccurrences(of: "Warm, exact, and candid.",
                                                                        with: "Calm under pressure."))
    }

    func testAddedCustomPersonalitySurvivesReplacingTheMainField() {
        let withPersonality = AssistantPersonaPolicy.render(AssistantPersonaPolicy.parse(sampleCustom),
                                                            name: "Sample Agent",
                                                            who: "Warm, exact, and candid.")
        XCTAssertEqual(withPersonality, sampleCustom + "\n## Who you are\n\nWarm, exact, and candid.")
        let replaced = AssistantPersonaPolicy.render(
            AssistantPersonaPolicy.parse(withPersonality), name: "Sample Agent",
            instructions: "A new hand-written brief.\n\n## Boundaries\n\nAsk before sending.")
        XCTAssertEqual(replaced,
                       "# Sample Agent\n\nA new hand-written brief.\n\n## Boundaries\n\nAsk before sending.\n\n## Who you are\n\nWarm, exact, and candid.")
    }

    // MARK: Headings round-trip

    func testMultilineHeadingsRoundTripInBothFields() {
        let main = "Paragraph one.\n\n## Rules\n\nAsk before sending.\n\n## Who you are\n\nRoles for the team."
        let who = "Be warm.\n\n## Voice\n\nUse short sentences.\n\n## What you do\n\nA heading inside personality."
        let cases: [(soul: String, primary: Bool, field: AssistantPersonaField)] = [
            (template, false, .what),
            (sampleWithPersonality, false, .instructions),
            ("# Lan\n\n" + primaryLine, true, .what),
        ]
        for item in cases {
            let parsed = AssistantPersonaPolicy.parse(item.soul, primary: item.primary)
            let stored = AssistantPersonaPolicy.render(
                parsed, name: "Lan", who: who,
                what: item.field == .what ? main : nil,
                instructions: item.field == .instructions ? main : nil)
            let reread = AssistantPersonaPolicy.parse(stored, primary: item.primary)
            XCTAssertEqual(AssistantPersonaMerge.value(reread, item.field), main, "\(item.field)")
            XCTAssertEqual(reread.who, who, "\(item.field)")
            XCTAssertEqual(reread.kind, parsed.kind, "\(item.field)")
            let revised = AssistantPersonaPolicy.render(reread, name: "Lan", who: "Keep it brief.")
            XCTAssertEqual(AssistantPersonaMerge.value(
                AssistantPersonaPolicy.parse(revised, primary: item.primary), item.field), main,
                "\(item.field)")
        }
    }

    func testTheMarkerKeepsTheHeadingLevelAndStaysOutOfTheField() {
        let stored = AssistantPersonaPolicy.render(AssistantPersonaPolicy.parse(template), name: "Lan",
                                                   what: "Lo lịch họp.\n\n## Rules\n\nNo Fridays.")
        XCTAssertTrue(stored.contains("## What you do\n\nLo lịch họp.\n\n<!-- atum:persona-heading -->\n## Rules\n\nNo Fridays."))
        XCTAssertEqual(AssistantPersonaPolicy.parse(stored).what, "Lo lịch họp.\n\n## Rules\n\nNo Fridays.")
    }

    // MARK: Field-level merge

    func testAnEditToOneFieldIsRenderedOnTheLatestOtherField() {
        // Another device changed "What you do" after the personality edit began.
        let latest = template.replacingOccurrences(of: "Lo lịch họp.", with: "Viết báo cáo.")
        let outcome = AssistantPersonaMerge.prepare(field: .who, before: "Điềm tĩnh.", after: "Vui vẻ.",
                                                    soul: latest, name: "Lan", primary: false)
        guard case let .write(soul) = outcome else { return XCTFail("\(outcome)") }
        let parsed = AssistantPersonaPolicy.parse(soul)
        XCTAssertEqual(parsed.who, "Vui vẻ.")
        XCTAssertEqual(parsed.what, "Viết báo cáo.")
    }

    func testAnEditToAFieldThatChangedElsewhereIsAConflict() {
        let latest = template.replacingOccurrences(of: "Lo lịch họp.", with: "Viết báo cáo.")
        XCTAssertEqual(AssistantPersonaMerge.prepare(field: .what, before: "Lo lịch họp.",
                                                     after: "Lo lịch họp và email.",
                                                     soul: latest, name: "Lan", primary: false),
                       .elsewhere)
    }

    func testAnEditTheLatestAlreadyHasWritesNothing() {
        XCTAssertEqual(AssistantPersonaMerge.prepare(field: .what, before: "Cũ.", after: " Lo lịch họp. ",
                                                     soul: template, name: "Lan", primary: false),
                       .unchanged)
    }

    func testAPersonaThatChangedShapeIsAConflictForTheMainField() {
        XCTAssertEqual(AssistantPersonaMerge.prepare(field: .what, before: "Lo lịch họp.", after: "Mới.",
                                                     soul: sampleCustom, name: "Lan", primary: false),
                       .elsewhere)
        XCTAssertEqual(AssistantPersonaMerge.visibleField(AssistantPersonaPolicy.parse(sampleCustom), .what),
                       .instructions)
        XCTAssertEqual(AssistantPersonaMerge.visibleField(AssistantPersonaPolicy.parse(template), .who), .who)
    }

    func testACustomMainEditKeepsTheLatestPersonality() {
        let latest = sampleWithPersonality.replacingOccurrences(of: "Warm, exact, and candid.",
                                                                with: "Calm.")
        let before = AssistantPersonaPolicy.parse(sampleWithPersonality).instructions
        let outcome = AssistantPersonaMerge.prepare(field: .instructions, before: before, after: "Be brief.",
                                                    soul: latest, name: "Sample Agent", primary: false)
        guard case let .write(soul) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(soul, "# Sample Agent\n\nBe brief.\n\n## Who you are\n\nCalm.\n\n")
    }

    // MARK: Review fixes (fences, repeated sections, queued saves)

    private let fencedExample =
        "# Sample Agent\n\nYou write personas for others. For example:\n\n```markdown\n## Who you are\n\nA cheerful guide.\n```\n\nKeep examples short.\n"

    func testAHeadingInsideAFenceIsNotASection() {
        let parsed = AssistantPersonaPolicy.parse(fencedExample)
        XCTAssertEqual(parsed.kind, .custom)
        XCTAssertEqual(parsed.who, "")
        XCTAssertEqual(parsed.instructions,
                       "You write personas for others. For example:\n\n```markdown\n## Who you are\n\nA cheerful guide.\n```\n\nKeep examples short.")
        XCTAssertEqual(AssistantPersonaPolicy.render(parsed, name: "Sample Agent"), fencedExample)
        // Editing the personality keeps the example and its closing fence.
        let next = AssistantPersonaPolicy.render(parsed, name: "Sample Agent", who: "Calm.")
        XCTAssertEqual(next, fencedExample + "\n## Who you are\n\nCalm.")
        let reread = AssistantPersonaPolicy.parse(next)
        XCTAssertEqual(reread.who, "Calm.")
        XCTAssertEqual(reread.instructions, parsed.instructions)
        // Editing the main field round-trips the fenced example inside it.
        let main = reread.instructions + "\n\nOne more rule."
        let rewritten = AssistantPersonaPolicy.render(reread, name: "Sample Agent", instructions: main)
        let again = AssistantPersonaPolicy.parse(rewritten)
        XCTAssertEqual(again.instructions, main)
        XCTAssertEqual(again.who, "Calm.")
    }

    func testFenceRangesFollowCommonMark() {
        let text = "a\n~~~~\n## x\n~~~\n## y\n~~~~\n## z\n```\n## open"
        let ns = text as NSString
        let ranges = AssistantPersonaPolicy.fencedRanges(text)
        func fenced(_ needle: String) -> Bool {
            let at = ns.range(of: needle).location
            return ranges.contains { NSLocationInRange(at, $0) }
        }
        XCTAssertTrue(fenced("## x"))
        XCTAssertTrue(fenced("## y")) // a shorter closer does not close
        XCTAssertFalse(fenced("## z"))
        XCTAssertTrue(fenced("## open")) // unclosed runs to the end
    }

    private let twoPersonalities =
        "# Sample Agent\n\nYou help with mail.\n\n## Who you are\n\nWarm.\n\n## Notes\n\nNo Fridays.\n\n## Who you are\n\nA second, older personality.\n"

    func testASecondPersonalitySectionSurvivesEitherEdit() {
        let parsed = AssistantPersonaPolicy.parse(twoPersonalities)
        XCTAssertEqual(parsed.kind, .custom)
        XCTAssertEqual(parsed.who, "Warm.")
        let who = AssistantPersonaPolicy.render(parsed, name: "Sample Agent", who: "Calm.")
        XCTAssertEqual(who, twoPersonalities.replacingOccurrences(of: "Warm.", with: "Calm."))
        let cleared = AssistantPersonaPolicy.render(parsed, name: "Sample Agent", who: "")
        XCTAssertTrue(cleared.contains("## Who you are\n\nA second, older personality.\n"))
        XCTAssertFalse(cleared.contains("Warm."))
        for changedWho in [nil, "Calm."] as [String?] {
            let main = AssistantPersonaPolicy.render(parsed, name: "Sample Agent", who: changedWho,
                                                     instructions: "Be brief.")
            XCTAssertTrue(main.contains("## Who you are\n\nA second, older personality.\n"), main)
            XCTAssertTrue(main.contains("## Who you are\n\n\(changedWho ?? "Warm.")"), main)
            XCTAssertEqual(AssistantPersonaPolicy.parse(main).instructions, "Be brief.")
        }
    }

    func testARepeatedTemplateSectionIsKeptOnEdit() {
        let soul = template + "\n\n## Who you are\n\nExtra."
        let next = AssistantPersonaPolicy.render(AssistantPersonaPolicy.parse(soul), name: "Lan",
                                                 who: "Vui vẻ.")
        XCTAssertEqual(next, soul.replacingOccurrences(of: "Điềm tĩnh.", with: "Vui vẻ."))
    }

    func testAnEarlierSaveKeepsANewerDraftAndAdvancesTheBaseline() {
        // Purpose A → B is sent; the person types C before B is confirmed.
        var edit = AssistantCardEdit(saved: "A")
        edit.draft = "B"
        let submitted = edit.pendingSave()!
        edit.draft = "C"
        edit.settle("B", submitted: submitted)
        XCTAssertEqual(edit.saved, "B")
        XCTAssertEqual(edit.draft, "C")
        XCTAssertEqual(edit.pendingSave(), "C")
        // The queued write merges C on B, not as another device's edit.
        guard case .write = AssistantPersonaMerge.prepare(
            field: .what, before: edit.saved, after: "C",
            soul: template.replacingOccurrences(of: "Lo lịch họp.", with: "B"),
            name: "Lan", primary: false) else { return XCTFail() }
        // With no newer draft the field simply takes the confirmed value.
        var settled = AssistantCardEdit(saved: "A")
        settled.draft = " B "
        settled.settle("B", submitted: "B")
        XCTAssertEqual(settled.draft, "B")
        XCTAssertFalse(settled.isDirty)
    }

    func testAQueuedSaveDoesNotClearAnotherFieldsFailure() {
        var band = AssistantCardSaveBand<String, String>()
        band.begin("what")
        band.failed("what", note: "failed")
        band.begin("who")
        XCTAssertEqual(band.note, "failed")
        XCTAssertEqual(band.retryField, "what")
        band.settled("who", note: "saved")
        XCTAssertEqual(band.note, "failed")
        XCTAssertEqual(band.retryField, "what")
        // Retrying it clears it; its success then shows.
        band.begin("what")
        XCTAssertNil(band.note)
        band.settled("what", note: "saved")
        XCTAssertEqual(band.note, "saved")
        XCTAssertNil(band.retryField)
        // A discarded edit leaves nothing to retry.
        band.failed("who", note: "failed")
        band.discard("who")
        XCTAssertNil(band.retryField)
        XCTAssertNil(band.note)
        // Two failures: Retry targets the latest, then the earlier one returns.
        band.failed("what", note: "failed")
        band.failed("name", note: "refused")
        XCTAssertEqual(band.retryField, "name")
        band.begin("name")
        band.settled("name", note: "saved")
        XCTAssertEqual(band.retryField, "what")
        XCTAssertEqual(band.note, "failed")
    }

    // MARK: Length hint

    func testALeadingBOMIsNotCounted() {
        let limit = AssistantPersonaPolicy.contextFileMaxChars
        XCTAssertFalse(AssistantPersonaPolicy.exceedsContextBudget("\u{FEFF}" + String(repeating: "a", count: limit)))
        XCTAssertTrue(AssistantPersonaPolicy.exceedsContextBudget("\u{FEFF}" + String(repeating: "a", count: limit + 1)))
        // Only a leading BOM is the file's encoding mark.
        XCTAssertTrue(AssistantPersonaPolicy.exceedsContextBudget(String(repeating: "a", count: limit) + "\u{FEFF}"))
    }

    func testTheLengthHintCountsCodePointsAfterNormalizingNewlines() {
        let limit = AssistantPersonaPolicy.contextFileMaxChars
        XCTAssertEqual(limit, 20_000)
        XCTAssertFalse(AssistantPersonaPolicy.exceedsContextBudget(String(repeating: "a", count: limit)))
        XCTAssertTrue(AssistantPersonaPolicy.exceedsContextBudget(String(repeating: "a", count: limit + 1)))
        // 10,000 CRLF lines are 19,999 code points once read as LF and trimmed.
        XCTAssertFalse(AssistantPersonaPolicy.exceedsContextBudget(String(repeating: "a\r\n", count: 10_000)))
        // Surrogate pairs count once: 10,001 emoji are 20,002 UTF-16 units.
        XCTAssertFalse(AssistantPersonaPolicy.exceedsContextBudget(String(repeating: "🙂", count: 10_001)))
        XCTAssertTrue(AssistantPersonaPolicy.exceedsContextBudget(String(repeating: "🙂", count: limit + 1)))
        XCTAssertFalse(AssistantPersonaPolicy.exceedsContextBudget("   " + String(repeating: "a", count: limit) + "\n\n"))
    }
}
