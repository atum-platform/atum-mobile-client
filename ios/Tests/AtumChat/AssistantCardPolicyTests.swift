import XCTest
@testable import AtumChat

final class AssistantCardPolicyTests: XCTestCase {
    private func capabilities(persona: AssistantPersona.Kind = .template)
        -> AssistantCardCapabilities {
        AssistantCardCapabilities(canMessage: true, persona: persona, hasHome: true,
                                  hasModel: true, hasPet: true, hasSkills: true,
                                  hasRoutines: true)
    }

    func testPrimaryAndOtherAssistantsShowTheSameRows() {
        let primary = AssistantCardLayout.rows(for: .primary, capabilities: capabilities())
        let other = AssistantCardLayout.rows(for: .other, capabilities: capabilities())
        XCTAssertEqual(primary, other)
        XCTAssertEqual(primary, [.photo, .name, .message, .handle, .purpose, .personality,
                                 .home, .model, .pet, .skills, .routines])
    }

    func testWithoutTheRetireRouteNeitherRoleOffersDelete() {
        for role in [AssistantCardRole.primary, .other] {
            XCTAssertFalse(AssistantCardLayout.rows(for: role, capabilities: capabilities())
                .contains(.retire))
        }
    }

    /// AS-4: desktop's "Delete {name}…" ends a non-primary card; the primary
    /// never has it, even where the host can retire.
    func testOnlyANonPrimaryAssistantEndsWithDelete() {
        var retiring = capabilities()
        retiring.canRetire = true
        let other = AssistantCardLayout.rows(for: .other, capabilities: retiring)
        XCTAssertEqual(other.last, .retire)
        XCTAssertEqual(other.filter { $0 == .retire }.count, 1)
        XCTAssertFalse(AssistantCardLayout.rows(for: .primary, capabilities: retiring).contains(.retire))
        XCTAssertTrue(AssistantRetirePolicy.offersDelete(isPrimary: false, canRetire: true))
        XCTAssertFalse(AssistantRetirePolicy.offersDelete(isPrimary: true, canRetire: true))
        XCTAssertFalse(AssistantRetirePolicy.offersDelete(isPrimary: false, canRetire: false))
    }

    func testACustomPersonaIsOneInstructionsFieldOnBothRoles() {
        let expected: [AssistantCardRow] = [.photo, .name, .message, .handle, .instructions,
                                            .home, .model, .pet, .skills, .routines]
        XCTAssertEqual(AssistantCardLayout.rows(for: .primary,
                                                capabilities: capabilities(persona: .custom)),
                       expected)
        XCTAssertEqual(AssistantCardLayout.rows(for: .other,
                                                capabilities: capabilities(persona: .custom)),
                       expected)
    }

    func testRowsOnlyDropCapabilitiesThatTheCardCannotOffer() {
        let rows = AssistantCardLayout.rows(
            for: .other,
            capabilities: AssistantCardCapabilities(canMessage: false, persona: .primary,
                                                    hasHome: false, hasModel: true,
                                                    hasPet: false, hasSkills: true,
                                                    hasRoutines: false)
        )
        XCTAssertEqual(rows, [.photo, .name, .handle, .purpose, .personality, .model, .skills])
    }

    func testLeavingAChangedFieldSavesTheTrimmedDraftOnce() {
        var edit = AssistantCardEdit(saved: "Calm.")
        XCTAssertNil(edit.pendingSave())
        edit.draft = "  Cheerful.  "
        XCTAssertTrue(edit.isDirty)
        XCTAssertEqual(edit.pendingSave(), "Cheerful.")
        edit.accept("Cheerful.")
        XCTAssertFalse(edit.isDirty)
        XCTAssertNil(edit.pendingSave())
    }

    func testRevertPutsBackTheSavedValueAndSavesNothing() {
        var edit = AssistantCardEdit(saved: "Calm.")
        edit.draft = "Cheerful."
        edit.revert()
        XCTAssertEqual(edit.draft, "Calm.")
        XCTAssertFalse(edit.isDirty)
        XCTAssertNil(edit.pendingSave())
    }

    func testAnEmptyNameIsNotSavedButAnEmptyPersonaFieldIs() {
        var name = AssistantCardEdit(saved: "Atum", requirement: .nonEmpty)
        name.draft = "   "
        XCTAssertNil(name.pendingSave())
        XCTAssertTrue(name.isDirty)

        var personality = AssistantCardEdit(saved: "Calm.", requirement: .mayBeEmpty)
        personality.draft = ""
        XCTAssertEqual(personality.pendingSave(), "")
    }

    func testTheCardIsInlineInChatInfoAndPushedFromSettingsWithNoEditScreen() {
        XCTAssertEqual(AssistantCardNavigation.placement(for: .chatInfo), .inlineCard)
        XCTAssertEqual(AssistantCardNavigation.placement(for: .settingsRoster), .pushedCard)
        XCTAssertFalse(AssistantCardNavigation.opensSeparateEditScreen(for: .chatInfo))
        XCTAssertFalse(AssistantCardNavigation.opensSeparateEditScreen(for: .settingsRoster))
    }
}
