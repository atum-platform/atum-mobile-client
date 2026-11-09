@testable import AtumMobile
import XCTest

/// The inline name and photo editing at the top of Settings: what is written,
/// when, and what the person is told. The view only draws this state.
@MainActor
final class AccountProfileEditorTests: XCTestCase {
    private final class Recorder {
        var names = [String]()
        var photos = [AccountProfilePhoto?]()
        var result = AccountProfileSaveResult.saved
    }

    private func nameSaver(_ recorder: Recorder) -> @MainActor (String) async -> AccountProfileSaveResult {
        { name in
            recorder.names.append(name)
            return recorder.result
        }
    }

    private func photoSaver(_ recorder: Recorder)
        -> @MainActor (AccountProfilePhoto?) async -> AccountProfileSaveResult {
        { photo in
            recorder.photos.append(photo)
            return recorder.result
        }
    }

    private func scalars(_ count: Int) -> String {
        String(repeating: "ạ", count: count)
    }

    /// `XCTAssertEqual` cannot await, so the commit is awaited here.
    private func expectCommit(_ editor: AccountProfileEditor,
                              _ trigger: AccountProfileEditor.Trigger,
                              _ recorder: Recorder,
                              _ expected: AccountProfileEditor.Outcome,
                              file: StaticString = #filePath, line: UInt = #line) async {
        let outcome = await editor.commit(trigger, save: nameSaver(recorder))
        XCTAssertEqual(outcome, expected, file: file, line: line)
    }

    // MARK: Unchanged names are never written

    func testAnUntouchedNameNeverWritesWhateverEndsTheEdit() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        for trigger in [AccountProfileEditor.Trigger.focusLost, .submit, .disappear] {
            await expectCommit(editor, trigger, recorder, .unchanged)
        }
        XCTAssertEqual(recorder.names, [])
        XCTAssertEqual(editor.nameStatus, .idle)
        XCTAssertEqual(editor.draft, "Minh")
    }

    func testALongServerNameIsNeitherCutNorRewrittenWhenLeftAlone() async {
        // The server may hold a name longer than the desktop's rule (it
        // accepts up to 128 characters when reading). Focusing the field and
        // leaving it must not touch it.
        let long = scalars(80)
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: long)
        editor.seed(long, isEditing: false)

        XCTAssertEqual(editor.draft.unicodeScalars.count, 80)
        await expectCommit(editor, .focusLost, recorder, .unchanged)
        await expectCommit(editor, .disappear, recorder, .unchanged)
        XCTAssertEqual(recorder.names, [])
        XCTAssertEqual(editor.draft.unicodeScalars.count, 80, "the field was shortened")
        XCTAssertEqual(editor.nameStatus, .idle)
    }

    func testReturnOnTheUntouchedNameAsksForNothing() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        await expectCommit(editor, .submit, recorder, .unchanged)
        XCTAssertEqual(recorder.names, [])
        XCTAssertEqual(editor.nameStatus, .idle)
    }

    func testTypingAndRestoringTheSavedNameWritesNothing() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        editor.edit("Minhh")
        editor.edit("Minh")
        await expectCommit(editor, .focusLost, recorder, .unchanged)
        XCTAssertEqual(recorder.names, [])
    }

    // MARK: Names outside the rule are refused, never cut down

    func testAnOverLimitNameIsRejectedWithNothingWrittenAndNothingCut() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        let tooLong = scalars(AccountProfileName.maximumLength + 1)
        editor.edit(tooLong)

        for trigger in [AccountProfileEditor.Trigger.submit, .focusLost, .disappear] {
            await expectCommit(editor, trigger, recorder, .rejected)
            XCTAssertEqual(editor.nameStatus, .rejected)
            XCTAssertEqual(editor.draft, tooLong, "the typed name was shortened")
        }
        XCTAssertEqual(recorder.names, [])
        XCTAssertEqual(editor.savedName, "Minh")
    }

    func testEditingALongServerNameIsHeldToTheRuleToo() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: scalars(80))
        editor.edit(scalars(79))
        await expectCommit(editor, .focusLost, recorder, .rejected)
        XCTAssertEqual(recorder.names, [])

        editor.edit(scalars(64))
        await expectCommit(editor, .focusLost, recorder, .saved)
        XCTAssertEqual(recorder.names, [scalars(64)])
    }

    func testANameAtTheLimitSaves() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        editor.edit(scalars(AccountProfileName.maximumLength))
        await expectCommit(editor, .submit, recorder, .saved)
        XCTAssertEqual(recorder.names.count, 1)
    }

    func testAControlCharacterIsRejected() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        editor.edit("Mi\u{0007}nh")
        await expectCommit(editor, .focusLost, recorder, .rejected)
        XCTAssertEqual(recorder.names, [])
    }

    func testTypingClearsAMessageAboutTheLastAttempt() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        editor.edit(scalars(65))
        _ = await editor.commit(.focusLost, save: nameSaver(recorder))
        XCTAssertEqual(editor.nameStatus, .rejected)
        editor.edit(scalars(60))
        XCTAssertEqual(editor.nameStatus, .idle)
    }

    // MARK: Empty names

    func testReturnOnAnEmptiedNameAsksForOneAndKeepsTheFieldEmpty() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        editor.edit("   ")
        await expectCommit(editor, .submit, recorder, .required)
        XCTAssertEqual(editor.nameStatus, .required)
        XCTAssertEqual(editor.draft, "   ")
        XCTAssertEqual(recorder.names, [])
    }

    func testLeavingAnEmptiedNameRestoresTheSavedOne() async {
        let recorder = Recorder()
        for trigger in [AccountProfileEditor.Trigger.focusLost, .disappear] {
            let editor = AccountProfileEditor(savedName: "Minh")
            editor.edit("")
            await expectCommit(editor, trigger, recorder, .unchanged)
            XCTAssertEqual(editor.draft, "Minh")
            XCTAssertEqual(editor.nameStatus, .idle)
        }
        XCTAssertEqual(recorder.names, [])
    }

    func testTheBlurThatFollowsReturnKeepsTheRequestForAName() async {
        // Return resigns the field, so a focus-lost commit arrives right after.
        // It must not undo the "Enter a name." the person was just shown.
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        editor.edit("")
        _ = await editor.commit(.submit, save: nameSaver(recorder))
        await expectCommit(editor, .focusLost, recorder, .required)
        XCTAssertEqual(editor.nameStatus, .required)
        XCTAssertEqual(editor.draft, "")
        XCTAssertEqual(recorder.names, [])
    }

    func testReturnOnANameTheProfileNeverHadAsksForOne() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "")
        await expectCommit(editor, .submit, recorder, .required)
        // The blur that follows Return leaves the request standing.
        await expectCommit(editor, .focusLost, recorder, .unchanged)
        XCTAssertEqual(editor.nameStatus, .required)
        editor.edit("Binh")
        XCTAssertEqual(editor.nameStatus, .idle)
        XCTAssertEqual(recorder.names, [])
    }

    // MARK: Saving

    func testANameIsTrimmedAndCollapsedBeforeItIsWritten() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        editor.edit("  Binh \n  Nguyen  ")
        await expectCommit(editor, .focusLost, recorder, .saved)
        XCTAssertEqual(recorder.names, ["Binh Nguyen"])
        XCTAssertEqual(editor.draft, "Binh Nguyen")
        XCTAssertEqual(editor.savedName, "Binh Nguyen")
        XCTAssertEqual(editor.nameStatus, .idle)
    }

    func testAFailedWriteKeepsWhatWasTypedAndSaysSo() async {
        let recorder = Recorder()
        recorder.result = .failed
        let editor = AccountProfileEditor(savedName: "Minh")
        editor.edit("Binh")
        await expectCommit(editor, .focusLost, recorder, .failed)
        XCTAssertEqual(editor.nameStatus, .failed)
        XCTAssertEqual(editor.draft, "Binh")
        XCTAssertEqual(editor.savedName, "Minh")

        // Trying again is just committing again.
        recorder.result = .saved
        await expectCommit(editor, .submit, recorder, .saved)
        XCTAssertEqual(recorder.names, ["Binh", "Binh"])
        XCTAssertEqual(editor.savedName, "Binh")
    }

    // MARK: Leaving the screen

    func testLeavingTheScreenSavesAnEditThatNeverLostFocus() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        editor.edit("Binh")
        await expectCommit(editor, .disappear, recorder, .saved)
        XCTAssertEqual(recorder.names, ["Binh"])
    }

    func testReturnThenBlurThenLeavingWritesOnce() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        editor.edit("Binh")
        await expectCommit(editor, .submit, recorder, .saved)
        await expectCommit(editor, .focusLost, recorder, .unchanged)
        await expectCommit(editor, .disappear, recorder, .unchanged)
        XCTAssertEqual(recorder.names, ["Binh"])
    }

    func testACommitWhileAnotherIsInFlightWritesNothingMore() async {
        let recorder = Recorder()
        var release: CheckedContinuation<Void, Never>?
        let slow: @MainActor (String) async -> AccountProfileSaveResult = { name in
            recorder.names.append(name)
            await withCheckedContinuation { release = $0 }
            return .saved
        }
        let editor = AccountProfileEditor(savedName: "Minh")
        editor.edit("Binh")

        let first = Task { await editor.commit(.focusLost, save: slow) }
        for _ in 0..<20 where editor.nameStatus != .saving { await Task.yield() }
        XCTAssertEqual(editor.nameStatus, .saving)

        let second = await editor.commit(.disappear, save: slow)
        XCTAssertEqual(second, .busy)
        editor.edit("Other")
        XCTAssertEqual(editor.draft, "Binh", "the field is locked while the name is being saved")

        release?.resume()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .saved)
        XCTAssertEqual(recorder.names, ["Binh"])
        XCTAssertEqual(editor.nameStatus, .idle)
    }

    // MARK: Seeding

    func testTheSavedNameFillsTheFieldUnlessThePersonIsTyping() {
        let editor = AccountProfileEditor()
        editor.seed("An", isEditing: false)
        XCTAssertEqual(editor.draft, "An")

        editor.edit("Binh")
        editor.seed("Cuong", isEditing: true)
        XCTAssertEqual(editor.draft, "Binh")
        XCTAssertEqual(editor.savedName, "Cuong")

        editor.seed("Dung", isEditing: false)
        XCTAssertEqual(editor.draft, "Dung")
        XCTAssertEqual(editor.nameStatus, .idle)
    }

    // MARK: Photo

    func testRemovingThePhotoWritesNil() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        let result = await editor.savePhoto(nil, save: photoSaver(recorder))
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(recorder.photos.count, 1)
        XCTAssertNil(recorder.photos[0])
        XCTAssertEqual(editor.photoStatus, .idle)
    }

    func testAPhotoIsWrittenAsPrepared() async {
        let recorder = Recorder()
        let editor = AccountProfileEditor(savedName: "Minh")
        let photo = AccountProfilePhoto(mimeType: "image/jpeg", data: Data([1, 2, 3]))
        let result = await editor.savePhoto(photo, save: photoSaver(recorder))
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(recorder.photos.first ?? nil, photo)
    }

    func testAFailedPhotoWriteIsReported() async {
        let recorder = Recorder()
        recorder.result = .failed
        let editor = AccountProfileEditor(savedName: "Minh")
        let result = await editor.savePhoto(nil, save: photoSaver(recorder))
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(editor.photoStatus, .failed)
    }

    func testAPhotoThatCannotBeReadIsNotCalledTheWrongFormat() {
        let editor = AccountProfileEditor(savedName: "Minh")
        editor.photoUnreadable()
        XCTAssertEqual(editor.photoStatus, .unreadable)
        editor.photoTooLarge()
        XCTAssertEqual(editor.photoStatus, .tooLarge)
        editor.photoChoiceStarted()
        XCTAssertEqual(editor.photoStatus, .idle)
    }

    func testASecondPhotoWriteWhileOneIsInFlightStartsNothing() async {
        let recorder = Recorder()
        var release: CheckedContinuation<Void, Never>?
        let slow: @MainActor (AccountProfilePhoto?) async -> AccountProfileSaveResult = { photo in
            recorder.photos.append(photo)
            await withCheckedContinuation { release = $0 }
            return .saved
        }
        let editor = AccountProfileEditor(savedName: "Minh")
        let first = Task { await editor.savePhoto(nil, save: slow) }
        for _ in 0..<20 where editor.photoStatus != .uploading { await Task.yield() }
        XCTAssertEqual(editor.photoStatus, .uploading)

        let second = await editor.savePhoto(nil, save: slow)
        XCTAssertNil(second)
        release?.resume()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .saved)
        XCTAssertEqual(recorder.photos.count, 1)
    }

    // MARK: The rule itself

    func testTheNameRuleIsTheDesktops() {
        XCTAssertEqual(AccountProfileName.validate("  Minh  "), .valid("Minh"))
        XCTAssertEqual(AccountProfileName.validate("An Example"), .valid("An Example"))
        XCTAssertEqual(AccountProfileName.validate("Mi\nnh"), .valid("Mi nh"))
        XCTAssertEqual(AccountProfileName.validate("   "), .empty)
        XCTAssertEqual(AccountProfileName.validate(""), .empty)
        XCTAssertEqual(AccountProfileName.validate(scalars(64)), .valid(scalars(64)))
        XCTAssertEqual(AccountProfileName.validate(scalars(65)), .invalid)
        XCTAssertEqual(AccountProfileName.validate("Mi\u{0000}nh"), .invalid)
        // Length counts Unicode scalars, as the desktop counts code points: 33
        // letters written as a base and a combining dot are 66 scalars.
        XCTAssertEqual(AccountProfileName.validate(String(repeating: "a\u{0323}", count: 33)), .invalid)
        XCTAssertEqual(AccountProfileName.validate(String(repeating: "a\u{0323}", count: 32)),
                       .valid(String(repeating: "a\u{0323}", count: 32)))
    }
}
