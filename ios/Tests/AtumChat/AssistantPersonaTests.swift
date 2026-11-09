import XCTest
@testable import AtumChat

final class AssistantPersonaTests: XCTestCase {
    func testTemplateProjectsTwoFieldsAndPreservesUnknownSections() {
        let soul = "# Lan\n\n## Who you are\n\nCalm.\n\n## What you do\n\nPlans trips.\n\n## Rules\n\nNo Fridays.\n"
        let parsed = AssistantPersonaPolicy.parse(soul)
        XCTAssertEqual(parsed.kind, .template)
        XCTAssertEqual(parsed.who, "Calm.")
        XCTAssertEqual(parsed.what, "Plans trips.")
        let rendered = AssistantPersonaPolicy.render(parsed, name: "Lan", who: "Cheerful.", what: "Plans travel.")
        XCTAssertTrue(rendered.contains("## Who you are\n\nCheerful."))
        XCTAssertTrue(rendered.contains("## What you do\n\nPlans travel."))
        XCTAssertTrue(rendered.contains("## Rules\n\nNo Fridays."))
    }

    func testCustomDefinitionStaysOneInstructionsField() {
        let soul = "# Lan\n\nYou are a calm planner.\n\n## Rules\n\nShort answers."
        let parsed = AssistantPersonaPolicy.parse(soul)
        XCTAssertEqual(parsed.kind, .custom)
        XCTAssertEqual(parsed.instructions, "You are a calm planner.\n\n## Rules\n\nShort answers.")
        XCTAssertEqual(AssistantPersonaPolicy.render(parsed, name: "Lan", instructions: "Be kind."),
                       "# Lan\n\nBe kind.")
    }

    func testEmptyDefinitionBecomesTemplateAndCanRemainEmpty() {
        let parsed = AssistantPersonaPolicy.parse("")
        XCTAssertEqual(parsed.kind, .template)
        XCTAssertEqual(AssistantPersonaPolicy.render(parsed, name: "Lan"), "")
        XCTAssertEqual(AssistantPersonaPolicy.render(parsed, name: "Lan", what: "Helps write."),
                       "# Lan\n\n## What you do\n\nHelps write.")
    }

    func testPrimaryBuiltInPersonaIsTheSameTwoFieldsAsAnyAssistant() {
        let soul = """
        # Atum

        You are Atum, the person’s own assistant in the Atum app. If they give you another name, use it from then on and remember it.

        Plans the day and keeps the notes.

        ## Who you are

        Calm.
        """
        let parsed = AssistantPersonaPolicy.parse(soul, primary: true)
        XCTAssertEqual(parsed.kind, .primary)
        XCTAssertEqual(parsed.who, "Calm.")
        XCTAssertEqual(parsed.what, "Plans the day and keeps the notes.")
        XCTAssertEqual(parsed.nameLine,
                       "You are Atum, the person’s own assistant in the Atum app. If they give you another name, use it from then on and remember it.")
        let rendered = AssistantPersonaPolicy.render(
            parsed, name: "Lan", who: "Cheerful.", what: "Plans travel."
        )
        XCTAssertTrue(rendered.hasPrefix(
            "# Lan\n\nYou are Atum, the person’s own assistant in the Atum app. If they give you another name, use it from then on and remember it."
        ))
        XCTAssertTrue(rendered.contains("Plans travel."))
        XCTAssertTrue(rendered.contains("## Who you are\n\nCheerful."))
        XCTAssertFalse(rendered.contains("Plans the day and keeps the notes."))
    }

    func testPrimaryNameLineIsKeptByteForByteWhenNothingElseChanges() {
        let soul = """
        # Atum

        You are Atum, the person’s own assistant in the Atum app. If they want to call you something else, tell them they can change your picture and how you work from your card, and that your name stays Atum.
        """
        let parsed = AssistantPersonaPolicy.parse(soul, primary: true)
        XCTAssertEqual(parsed.kind, .primary)
        XCTAssertEqual(AssistantPersonaPolicy.render(parsed, name: "Atum"), soul)
    }

    func testPrimaryFlagNeverTurnsAHandWrittenPersonaIntoTheTemplate() {
        let soul = "# Lan\n\nYou are a calm planner."
        let parsed = AssistantPersonaPolicy.parse(soul, primary: true)
        XCTAssertEqual(parsed.kind, .custom)
        XCTAssertEqual(parsed.instructions, "You are a calm planner.")
    }
}
