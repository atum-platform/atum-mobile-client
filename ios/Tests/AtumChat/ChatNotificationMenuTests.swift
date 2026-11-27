import XCTest
@testable import AtumChat

/// S3 UI: the chat info notification menu over `ChatNotificationSettings`,
/// against desktop #155 `MatrixRoomNotificationMenu` (c2099ee6).
final class ChatNotificationMenuTests: XCTestCase {
    private func settings(_ mode: ChatNotificationMode, inherited: Bool,
                          caveat: Bool = false) -> ChatNotificationSettings {
        ChatNotificationSettings(effectiveMode: mode, isInherited: inherited, hasEncryptedMentionCaveat: caveat)
    }

    private func ready(_ snapshot: ChatNotificationSettings) -> ChatNotificationMenuState {
        var state = ChatNotificationMenuState(isAvailable: true)
        state.receive(snapshot)
        return state
    }

    func testOptionsFollowTheDesktopMenuOrderAndChoices() {
        XCTAssertEqual(ChatNotificationMenuOption.allCases, [.restoreDefault, .all, .mentionsAndKeywords, .off])
        XCTAssertEqual(ChatNotificationMenuOption.allCases.map(\.choice),
                       [.restoreDefault, .set(.all), .set(.mentionsAndKeywords), .set(.off)])
        for option in ChatNotificationMenuOption.allCases {
            XCTAssertEqual(ChatNotificationMenuOption(option.choice), option)
        }
    }

    func testLoadingAndUnavailableRowsCannotWrite() {
        var state = ChatNotificationMenuState()
        XCTAssertFalse(state.isEnabled)
        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.selected)
        XCTAssertNil(state.quietLine)
        XCTAssertNil(state.begin(.off))

        state = ChatNotificationMenuState(isAvailable: true)
        XCTAssertTrue(state.isLoading)
        XCTAssertFalse(state.isEnabled)
        XCTAssertNil(state.begin(.off))

        state.receive(settings(.all, inherited: true))
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.isEnabled)
        state.becomeUnavailable()
        XCTAssertFalse(state.isEnabled)
        XCTAssertNil(state.begin(.off))
    }

    func testInheritedAndExplicitAllCheckDifferentOptionsWithTheSameValue() {
        let inherited = ready(settings(.all, inherited: true))
        let explicit = ready(settings(.all, inherited: false))
        XCTAssertEqual(inherited.selected, .restoreDefault)
        XCTAssertEqual(explicit.selected, .all)
        XCTAssertEqual(inherited.value, .modeAll)
        XCTAssertEqual(explicit.value, .modeAll)
        // Restore default names the inherited mode only while it is inherited.
        XCTAssertEqual(inherited.hint(for: .restoreDefault), .modeAll)
        XCTAssertNil(explicit.hint(for: .restoreDefault))
        XCTAssertEqual(ready(settings(.mentionsAndKeywords, inherited: true)).hint(for: .restoreDefault),
                       .modeMentions)
    }

    func testHintsAndQuietLineUseTheDesktopHelpAndEncryptedCaveat() {
        let plain = ready(settings(.mentionsAndKeywords, inherited: false))
        XCTAssertEqual(plain.hint(for: .all), .helpAll)
        XCTAssertEqual(plain.hint(for: .mentionsAndKeywords), .helpMentions)
        XCTAssertEqual(plain.hint(for: .off), .helpOff)
        XCTAssertEqual(plain.quietLine, .helpMentions)

        let encrypted = ready(settings(.mentionsAndKeywords, inherited: false, caveat: true))
        XCTAssertEqual(encrypted.hint(for: .mentionsAndKeywords), .encryptedMentions)
        XCTAssertEqual(encrypted.quietLine, .encryptedMentions)
        XCTAssertEqual(ready(settings(.off, inherited: false, caveat: true)).quietLine, .helpOff)
    }

    func testSelectingTheCurrentChoiceIsANoOpButAnotherWrites() {
        var state = ready(settings(.all, inherited: true))
        XCTAssertFalse(state.shouldWrite(.restoreDefault))
        XCTAssertNil(state.begin(.restoreDefault))
        XCTAssertTrue(state.shouldWrite(.all), "explicit All differs from inherited All")
        XCTAssertNotNil(state.begin(.all))
    }

    func testConfirmedSnapshotStaysVisibleWhileWritingAndUntilSync() throws {
        var state = ready(settings(.all, inherited: true))
        let attempt = try XCTUnwrap(state.begin(.mentionsAndKeywords))
        XCTAssertTrue(state.isWorking)
        XCTAssertFalse(state.isEnabled)
        XCTAssertEqual(state.selected, .restoreDefault)
        XCTAssertNil(state.begin(.off), "one change at a time")

        state.finish(attempt, succeeded: true)
        XCTAssertTrue(state.isWorking, "waits for the synced snapshot")
        XCTAssertEqual(state.selected, .restoreDefault)

        state.receive(settings(.mentionsAndKeywords, inherited: false))
        XCTAssertFalse(state.isWorking)
        XCTAssertEqual(state.selected, .mentionsAndKeywords)
        state.stopWaiting(attempt)
        XCTAssertEqual(state.selected, .mentionsAndKeywords)
    }

    func testAnUnchangedSyncStopsWaitingAfterTheGrace() throws {
        var state = ready(settings(.off, inherited: false))
        let attempt = try XCTUnwrap(state.begin(.all))
        state.stopWaiting(attempt)
        XCTAssertTrue(state.isWorking, "an unfinished write keeps waiting")
        state.finish(attempt, succeeded: true)
        state.stopWaiting(attempt)
        XCTAssertFalse(state.isWorking)
        XCTAssertTrue(state.isEnabled)
    }

    func testAFailureShowsOneLineAndTheSameChoiceCanBeRetried() throws {
        var state = ready(settings(.all, inherited: true))
        let attempt = try XCTUnwrap(state.begin(.off))
        state.finish(attempt, succeeded: false)
        XCTAssertFalse(state.isWorking)
        XCTAssertEqual(state.quietLine, .failed)
        XCTAssertEqual(state.selected, .restoreDefault)

        // The native write landed but legacy retirement failed: Off now reads
        // as selected and can still be chosen again.
        state.receive(settings(.off, inherited: false))
        XCTAssertEqual(state.selected, .off)
        XCTAssertEqual(state.quietLine, .failed)
        XCTAssertTrue(state.shouldWrite(.off))
        let retry = try XCTUnwrap(state.begin(.off))
        XCTAssertFalse(state.hasFailed)
        state.finish(retry, succeeded: true)
        XCTAssertFalse(state.shouldWrite(.off))
    }

    func testStaleAttemptsAreIgnored() throws {
        var state = ready(settings(.all, inherited: false))
        let first = try XCTUnwrap(state.begin(.off))
        state.finish(first, succeeded: false)
        let second = try XCTUnwrap(state.begin(.mentionsAndKeywords))
        state.finish(first, succeeded: true)
        XCTAssertEqual(state.inFlight?.attempt, second)
        XCTAssertEqual(state.inFlight?.isWritten, false)
    }

    func testQuieterLegacyChannelLevelShowsWhileInheritedAndStillWrites() {
        let inherited = settings(.all, inherited: true)
        var state = ready(inherited)
        state.receiveLegacyChannel(.all, for: inherited)
        XCTAssertNil(state.legacyChannel, "only quieter levels narrow the room")

        state.receiveLegacyChannel(.off, for: inherited)
        XCTAssertEqual(state.selected, .off)
        XCTAssertEqual(state.displayedMode, .off)
        XCTAssertEqual(state.value, .modeOff)
        XCTAssertEqual(state.quietLine, .helpOff)
        XCTAssertEqual(state.hint(for: .restoreDefault), .modeAll, "names the Matrix default")
        // Desktop writes the same choice to retire the legacy level.
        XCTAssertTrue(state.shouldWrite(.off))
        XCTAssertTrue(state.shouldWrite(.restoreDefault))

        state.receive(settings(.off, inherited: false))
        XCTAssertNil(state.legacyChannel)
        XCTAssertEqual(state.selected, .off)
        XCTAssertFalse(state.shouldWrite(.off))
    }

    func testLegacyLevelForAnOlderOrExplicitSnapshotIsIgnored() {
        let older = settings(.all, inherited: true)
        var state = ready(older)
        state.receive(settings(.mentionsAndKeywords, inherited: true))
        state.receiveLegacyChannel(.off, for: older)
        XCTAssertNil(state.legacyChannel)

        let explicit = settings(.all, inherited: false)
        state.receive(explicit)
        state.receiveLegacyChannel(.off, for: explicit)
        XCTAssertNil(state.legacyChannel)
        XCTAssertEqual(state.selected, .all)
    }

    func testPendingCopyCoversEveryKeyInEveryPhoneLocale() {
        XCTAssertEqual(Set(ChatNotificationPendingCopy.tables.keys),
                       Set(ChatNotificationCopyKey.allCases.map(\.rawValue)))
        for key in ChatNotificationCopyKey.allCases {
            for locale in ["en", "vi", "ja", "zh", "zh-Hant"] {
                XCTAssertFalse(ChatNotificationPendingCopy.tables[key.rawValue]?[locale]?.isEmpty ?? true,
                               "\(locale) \(key.rawValue)")
            }
        }
        XCTAssertEqual(ChatNotificationPendingCopy.text(.modeMentions, locale: "en"), "Mentions & keywords")
        XCTAssertEqual(ChatNotificationPendingCopy.text(.modeOff, locale: "vi"), "Tắt")
        XCTAssertEqual(ChatNotificationPendingCopy.text(.modeRestoreDefault, locale: "fr"), "Restore default")
    }
}
