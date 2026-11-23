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

    // MARK: Length hint

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
