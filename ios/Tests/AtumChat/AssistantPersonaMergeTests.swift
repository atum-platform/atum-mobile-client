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
        // The text's final newline is kept (byte fidelity).
        XCTAssertEqual(withPersonality, sampleCustom + "\n## Who you are\n\nWarm, exact, and candid.\n")
        let replaced = AssistantPersonaPolicy.render(
            AssistantPersonaPolicy.parse(withPersonality), name: "Sample Agent",
            instructions: "A new hand-written brief.\n\n## Boundaries\n\nAsk before sending.")
        XCTAssertEqual(replaced,
                       "# Sample Agent\n\nA new hand-written brief.\n\n## Boundaries\n\nAsk before sending.\n\n## Who you are\n\nWarm, exact, and candid.\n")
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
        XCTAssertEqual(soul, "# Sample Agent\n\nBe brief.\n\n## Who you are\n\nCalm.\n")
    }

    // MARK: Round-trip guard (review r2: findings 2, 3, 4)

    private let fencedExample =
        "# Sample Agent\n\nYou write personas for others. For example:\n\n```markdown\n## Who you are\n\nA cheerful guide.\n```\n\nKeep examples short.\n"

    func testATemplateTitleInsideAFenceIsReadOnly() {
        // Desktop reads the fenced title as a section; a fence-aware read
        // does not. The phone offers no per-field edit and writes nothing.
        let parsed = AssistantPersonaPolicy.parse(fencedExample)
        XCTAssertTrue(parsed.isAmbiguous)
        XCTAssertEqual(AssistantPersonaMerge.prepare(field: .who, before: parsed.who, after: "Calm.",
                                                     soul: fencedExample, name: "Sample Agent",
                                                     primary: false), .unsafe)
        XCTAssertEqual(AssistantPersonaMerge.prepare(field: .instructions, before: parsed.instructions,
                                                     after: "Be brief.", soul: fencedExample,
                                                     name: "Sample Agent", primary: false), .unsafe)
        // A non-template heading in a fence reads the same either way.
        XCTAssertFalse(AssistantPersonaPolicy.parse(
            fencedExample.replacingOccurrences(of: "## Who you are", with: "## Example")).isAmbiguous)
    }

    func testAnOpenFenceInPersonalityDoesNotAbsorbPurpose() {
        let outcome = AssistantPersonaMerge.prepare(field: .who, before: "Điềm tĩnh.",
                                                    after: "```\nexample", soul: template,
                                                    name: "Lan", primary: false)
        XCTAssertEqual(outcome, .unsafe)
        // The same text already on the server is read-only, not re-split.
        let stored = "# Lan\n\n## Who you are\n\n```\nexample\n\n## What you do\n\nLo lịch họp."
        XCTAssertTrue(AssistantPersonaPolicy.parse(stored).isAmbiguous)
        XCTAssertEqual(AssistantPersonaMerge.prepare(field: .what, before: "Lo lịch họp.", after: "Mới.",
                                                     soul: stored, name: "Lan", primary: false), .unsafe)
    }

    func testAFencedTemplateTitleTypedInAFieldRoundTripsOnBothParsers() {
        // Desktop's marker keeps it inside the field for both readings, so
        // the phone and desktop agree about what the save wrote.
        let what = "Lo lịch họp.\n\n```\n## Who you are\n\nAn example.\n```"
        guard case let .write(soul) = AssistantPersonaMerge.prepare(
            field: .what, before: "Lo lịch họp.", after: what, soul: template,
            name: "Lan", primary: false) else { return XCTFail() }
        let reread = AssistantPersonaPolicy.parse(soul)
        XCTAssertFalse(reread.isAmbiguous)
        XCTAssertEqual(reread.what, what)
        XCTAssertEqual(reread.who, "Điềm tĩnh.")
    }

    func testFenceRangesFollowCommonMark() {
        let text = "a\n~~~~\n## x\n~~~\n## y\n~~~~\n## z\n```\n## open"
        let ns = text as NSString
        let fences = AssistantPersonaPolicy.fences(text)
        func fenced(_ needle: String) -> Bool {
            let at = ns.range(of: needle).location
            return fences.ranges.contains { NSLocationInRange(at, $0) }
        }
        XCTAssertTrue(fenced("## x"))
        XCTAssertTrue(fenced("## y")) // a shorter closer does not close
        XCTAssertFalse(fenced("## z"))
        XCTAssertTrue(fenced("## open")) // unclosed runs to the end
        XCTAssertTrue(fences.unclosed)
        XCTAssertFalse(AssistantPersonaPolicy.fences("```\ncode\n```\n").unclosed)
    }

    private let twoPersonalities =
        "# Sample Agent\n\nYou help with mail.\n\n## Who you are\n\nWarm.\n\n## Notes\n\nNo Fridays.\n\n## Who you are\n\nA second, older personality.\n"

    func testClearingTheFirstOfTwoPersonalitiesDoesNotPromoteTheHiddenOne() {
        let parsed = AssistantPersonaPolicy.parse(twoPersonalities)
        XCTAssertEqual(parsed.kind, .custom)
        XCTAssertTrue(parsed.isAmbiguous)
        XCTAssertEqual(AssistantPersonaMerge.prepare(field: .who, before: "Warm.", after: "",
                                                     soul: twoPersonalities, name: "Sample Agent",
                                                     primary: false), .unsafe)
        XCTAssertTrue(AssistantPersonaPolicy.parse(template + "\n\n## What you do\n\nExtra.").isAmbiguous)
    }

    func testAWriteThatWouldNotReadBackIsRefused() {
        // A main field that starts with its own `# ` line would become the
        // persona's heading on the next read.
        let soul = "You help with mail.\n"
        XCTAssertFalse(AssistantPersonaPolicy.parse(soul).isAmbiguous)
        XCTAssertEqual(AssistantPersonaMerge.prepare(field: .instructions, before: "You help with mail.",
                                                     after: "# Title\n\nBody.", soul: soul,
                                                     name: "Sample Agent", primary: false), .unsafe)
    }

    // MARK: Drafts and the band (review r1 #1, #4; r2 #1, #6)

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
        guard case .write = AssistantPersonaMerge.prepare(
            field: .what, before: edit.saved, after: "C",
            soul: template.replacingOccurrences(of: "Lo lịch họp.", with: "B"),
            name: "Lan", primary: false) else { return XCTFail() }
        var settled = AssistantCardEdit(saved: "A")
        settled.draft = " B "
        settled.settle("B", submitted: "B")
        XCTAssertEqual(settled.draft, "B")
        XCTAssertFalse(settled.isDirty)
    }

    func testASameFieldConflictKeepsANewerDraftUntilRetry() {
        // A → B sent, C typed, the server already says D.
        var edit = AssistantCardEdit(saved: "A")
        edit.draft = "B"
        let submitted = edit.pendingSave()!
        edit.draft = "C"
        let latest = template.replacingOccurrences(of: "Lo lịch họp.", with: "D")
        XCTAssertEqual(AssistantPersonaMerge.prepare(field: .what, before: edit.saved, after: submitted,
                                                     soul: latest, name: "Lan", primary: false),
                       .elsewhere)
        XCTAssertTrue(edit.hasNewerDraft(than: submitted))
        var band = AssistantCardSaveBand<String, String>()
        band.begin("what")
        band.failed("what", note: "conflict", held: true)
        // Leaving the field again does not write C over D…
        XCTAssertTrue(band.isHeld("what"))
        XCTAssertEqual(edit.draft, "C")
        XCTAssertEqual(AssistantPersonaMerge.prepare(field: .what, before: edit.saved, after: "C",
                                                     soul: latest, name: "Lan", primary: false),
                       .elsewhere)
        // …only Retry does, on D.
        edit.rebase("D")
        band.begin("what")
        XCTAssertFalse(band.isHeld("what"))
        guard case let .write(soul) = AssistantPersonaMerge.prepare(
            field: .what, before: edit.saved, after: edit.pendingSave()!,
            soul: latest, name: "Lan", primary: false) else { return XCTFail() }
        XCTAssertEqual(AssistantPersonaPolicy.parse(soul).what, "C")
        // No newer draft: the latest simply shows.
        var plain = AssistantCardEdit(saved: "A")
        plain.draft = "B"
        XCTAssertFalse(plain.hasNewerDraft(than: "B"))
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
        band.begin("what")
        XCTAssertNil(band.note)
        band.settled("what", note: "saved")
        XCTAssertEqual(band.note, "saved")
        XCTAssertNil(band.retryField)
        band.failed("who", note: "failed")
        band.discard("who")
        XCTAssertNil(band.retryField)
        XCTAssertNil(band.note)
    }

    func testARefusedRenameKeepsAnotherFieldsRetry() {
        // The card shows a name refusal with the name field and settles the
        // name in the band, so Purpose's Retry stays visible.
        var band = AssistantCardSaveBand<String, String>()
        band.failed("what", note: "failed")
        band.begin("name")
        band.settled("name", note: nil)
        XCTAssertEqual(band.retryField, "what")
        XCTAssertEqual(band.note, "failed")
    }

    // MARK: Byte fidelity (review r2 #5)

    /// A replaced field keeps the separator after it exactly (its trailing
    /// spaces and line ending); every other slice is untouched.
    func testAnEditKeepsCRLFTrailingSpacesAndTheFinalNewline() {
        let crlf = "# Lan\r\n\r\n## Who you are\r\n\r\nĐiềm tĩnh.  \r\n\r\n## What you do\r\n\r\nLo lịch họp.  \r\n"
        let who = AssistantPersonaPolicy.render(AssistantPersonaPolicy.parse(crlf), name: "Lan", who: "Vui vẻ.")
        XCTAssertEqual(who, crlf.replacingOccurrences(of: "Điềm tĩnh.", with: "Vui vẻ."))
        let what = AssistantPersonaPolicy.render(AssistantPersonaPolicy.parse(crlf), name: "Lan", what: "Mới.")
        XCTAssertEqual(what, "# Lan\r\n\r\n## Who you are\r\n\r\nĐiềm tĩnh.  \r\n\r\n## What you do\r\n\r\nMới.  \r\n")
        // A new section uses the text's own line ending.
        let added = AssistantPersonaPolicy.render(AssistantPersonaPolicy.parse("# Lan\r\n\r\n## Who you are\r\n\r\nA.\r\n"),
                                                  name: "Lan", what: "B.")
        XCTAssertEqual(added, "# Lan\r\n\r\n## Who you are\r\n\r\nA.\r\n\r\n## What you do\r\n\r\nB.\r\n")
    }

    func testAPrimaryEditKeepsItsLastSectionVerbatim() {
        let soul = "# Lan\n\n" + primaryLine + "\n\nHelp with mail.\n\n## Who you are\n\nWarm.  \n\n## Memory\n\nKeep notes.  \n"
        let next = AssistantPersonaPolicy.render(AssistantPersonaPolicy.parse(soul, primary: true),
                                                 name: "Lan", what: "Help with mail and calendar.")
        XCTAssertEqual(next, soul.replacingOccurrences(of: "Help with mail.", with: "Help with mail and calendar."))
        let who = AssistantPersonaPolicy.render(AssistantPersonaPolicy.parse(soul, primary: true),
                                                name: "Lan", who: "Calm.")
        XCTAssertEqual(who, soul.replacingOccurrences(of: "Warm.", with: "Calm."))
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
