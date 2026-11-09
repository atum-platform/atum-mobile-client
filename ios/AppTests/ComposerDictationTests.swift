import AVFoundation
@testable import AtumMobile
import Speech
import XCTest

@MainActor
private final class FakeDictationEngine: DictationEngine {
    var availability = DictationAvailability.ready
    var beginError: (any Error)?
    private(set) var began = 0
    private(set) var finished = 0
    private(set) var cancelled = 0
    private var sink: (@MainActor (DictationUpdate) -> Void)?

    func authorize() async -> DictationAvailability { availability }

    func begin(onUpdate: @escaping @MainActor (DictationUpdate) -> Void) throws {
        if let beginError { throw beginError }
        began += 1
        sink = onUpdate
    }

    func finish() { finished += 1 }
    func cancel() { cancelled += 1 }

    func say(_ transcript: String) { sink?(.transcript(transcript)) }
    func end(failed: Bool = false) { sink?(.ended(failed: failed)) }
}

@MainActor
final class ComposerDictationTests: XCTestCase {
    private struct Boom: Error {}

    private var draft = ""

    private func start(_ dictation: ComposerDictation) async {
        dictation.toggle(draft: { [unowned self] in draft }, setDraft: { [unowned self] in draft = $0 })
        // The authorisation answer arrives on the next main-actor turns.
        for _ in 0..<20 where dictation.state == .requesting { await Task.yield() }
    }

    func testStartAppendsPartialsToTheDraftThenStopKeepsThem() async {
        let engine = FakeDictationEngine()
        let dictation = ComposerDictation(engine: engine)
        draft = "Chào"
        await start(dictation)
        XCTAssertEqual(dictation.state, .recording)
        XCTAssertTrue(dictation.isRecording)

        engine.say("xin")
        XCTAssertEqual(draft, "Chào xin")
        engine.say("xin chào bạn")
        XCTAssertEqual(draft, "Chào xin chào bạn", "partials are cumulative, not appended twice")

        dictation.finish()
        XCTAssertEqual(dictation.state, .finishing)
        XCTAssertEqual(engine.finished, 1)
        engine.say("xin chào bạn nhé")
        XCTAssertEqual(draft, "Chào xin chào bạn nhé", "the last words still arrive after the tap")
        engine.end()
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertNil(dictation.refusal)
    }

    func testSecondTapStopsLikeFinish() async {
        let engine = FakeDictationEngine()
        let dictation = ComposerDictation(engine: engine)
        await start(dictation)
        dictation.toggle(draft: { "" }, setDraft: { _ in })
        XCTAssertEqual(dictation.state, .finishing)
        XCTAssertEqual(engine.finished, 1)
    }

    func testAnEmptyDraftTakesTheSpokenWordsAsTheyAre() async {
        let engine = FakeDictationEngine()
        let dictation = ComposerDictation(engine: engine)
        await start(dictation)
        engine.say("hello")
        XCTAssertEqual(draft, "hello")
    }

    func testCancelDropsLateWordsAndLeavesTheDraftAlone() async {
        let engine = FakeDictationEngine()
        let dictation = ComposerDictation(engine: engine)
        draft = "a"
        await start(dictation)
        engine.say("b")
        XCTAssertEqual(draft, "a b")
        dictation.cancel()
        draft = ""            // the send cleared it
        engine.say("b c")     // a callback that was already in flight
        engine.end()
        XCTAssertEqual(draft, "")
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertEqual(engine.cancelled, 1)
    }

    func testDeniedPermissionRefusesAndLeavesTheDraftUnchanged() async {
        let engine = FakeDictationEngine()
        engine.availability = .denied
        let dictation = ComposerDictation(engine: engine)
        draft = "keep me"
        await start(dictation)
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertEqual(dictation.refusal, .permissionDenied)
        XCTAssertEqual(draft, "keep me")
        XCTAssertEqual(engine.began, 0)

        dictation.clearRefusal()
        XCTAssertNil(dictation.refusal)
    }

    func testNoRecogniserAndEngineStartFailureAreUnavailable() async {
        let engine = FakeDictationEngine()
        engine.availability = .unavailable
        let dictation = ComposerDictation(engine: engine)
        await start(dictation)
        XCTAssertEqual(dictation.refusal, .unavailable)

        engine.availability = .ready
        engine.beginError = Boom()
        await start(dictation)
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertEqual(dictation.refusal, .unavailable)
        XCTAssertEqual(draft, "")
    }

    func testAFailureBeforeAnyWordsIsAnUnavailableRefusalButAfterWordsItIsJustTheEnd() async {
        let engine = FakeDictationEngine()
        let dictation = ComposerDictation(engine: engine)
        await start(dictation)
        engine.end(failed: true)
        XCTAssertEqual(dictation.state, .idle)
        XCTAssertEqual(dictation.refusal, .unavailable)

        dictation.clearRefusal()
        await start(dictation)
        engine.say("đã nghe")
        engine.end(failed: true)
        XCTAssertNil(dictation.refusal)
        XCTAssertEqual(draft, "đã nghe")
    }

    func testTypingWhileListeningBecomesTheNewBase() {
        var merge = DictationDraftMerge(base: "một")
        XCTAssertEqual(merge.merged(current: "một", transcript: "hai"), "một hai")
        // The person types over the draft; the words spoken so far are not repeated.
        XCTAssertEqual(merge.merged(current: "một hai ba", transcript: "hai bốn"), "một hai ba bốn")
    }

    func testMergeDoesNotDoubleSpaceAfterWhitespace() {
        var merge = DictationDraftMerge(base: "dòng\n")
        XCTAssertEqual(merge.merged(current: "dòng\n", transcript: "mới"), "dòng\nmới")
    }

    func testTypingBeforeTheFirstPartialIsKept() {
        var merge = DictationDraftMerge(base: "a")
        // The person types before the recogniser has said anything.
        XCTAssertEqual(merge.merged(current: "ab", transcript: "xin"), "ab xin")
    }

    func testTypingBeforeTheFirstPartialIsKeptThroughTheMachine() async {
        let engine = FakeDictationEngine()
        let dictation = ComposerDictation(engine: engine)
        draft = "a"
        await start(dictation)
        draft = "a typed"
        engine.say("xin")
        XCTAssertEqual(draft, "a typed xin")
        engine.say("xin chào")
        XCTAssertEqual(draft, "a typed xin chào")
    }

    func testARevisedPartialReplacesWhatItRevisesInsteadOfRepeatingIt() {
        var merge = DictationDraftMerge(base: "Chào")
        XCTAssertEqual(merge.merged(current: "Chào", transcript: "sin"), "Chào sin")
        XCTAssertEqual(merge.merged(current: "Chào sin", transcript: "xin chào"), "Chào xin chào")
    }
}

// MARK: Engine lifecycle (fake ports)

@MainActor
private final class FakeSession: DictationAudioSession {
    var activateError: (any Error)?
    private(set) var activations = 0
    private(set) var deactivations = 0
    private(set) var observing = false
    private var handler: (@MainActor (DictationSessionEvent) -> Void)?

    func activate() throws {
        activations += 1
        if let activateError { throw activateError }
    }
    func deactivate() { deactivations += 1 }
    func observe(_ handler: @escaping @MainActor (DictationSessionEvent) -> Void) {
        observing = true
        self.handler = handler
    }
    func stopObserving() {
        observing = false
        handler = nil
    }
    func post(_ event: DictationSessionEvent) { handler?(event) }
}

@MainActor
private final class FakeCapture: DictationCapture {
    var startError: (any Error)?
    private(set) var starts = 0
    private(set) var stops = 0
    var onConfigurationChange: (@MainActor () -> Void)?
    func changeConfiguration() { onConfigurationChange?() }
    func start(feeding request: SFSpeechAudioBufferRecognitionRequest) throws {
        starts += 1
        if let startError { throw startError }
    }
    func stop() { stops += 1 }
}

private final class FakeTask: DictationRecognitionTask {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

@MainActor
private final class FakeRecognizer: DictationRecognizing {
    private(set) var task = FakeTask()
    private(set) var started = 0
    private var sink: (@MainActor (DictationUpdate) -> Void)?
    func start(request: SFSpeechAudioBufferRecognitionRequest,
               onUpdate: @escaping @MainActor (DictationUpdate) -> Void) -> any DictationRecognitionTask {
        started += 1
        sink = onUpdate
        task = FakeTask()
        return task
    }
    func emit(_ update: DictationUpdate) { sink?(update) }
}

private final class RecordingPort: AudioSessionPort, @unchecked Sendable {
    struct Category: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
    }
    var categories = [Category]()
    var activations = [(Bool, AVAudioSession.SetActiveOptions)]()
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {
        categories.append(Category(category: category, mode: mode, options: options))
    }
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        activations.append((active, options))
    }
}

@MainActor
final class SpeechDictationEngineTests: XCTestCase {
    private struct Boom: Error {}

    private struct Rig {
        let engine: SpeechDictationEngine
        let session: FakeSession
        let capture: FakeCapture
        let recognizer: FakeRecognizer
    }

    private var updates = [DictationUpdate]()

    private func rig(grace: Duration = .seconds(30)) -> Rig {
        let session = FakeSession()
        let capture = FakeCapture()
        let recognizer = FakeRecognizer()
        let engine = SpeechDictationEngine(session: session, makeCapture: { capture },
                                           recognizer: recognizer, finishGrace: grace)
        updates = []
        return Rig(engine: engine, session: session, capture: capture, recognizer: recognizer)
    }

    private func begin(_ rig: Rig) throws {
        try rig.engine.begin { [unowned self] in updates.append($0) }
    }

    private var endedCount: Int {
        updates.filter { if case .ended = $0 { true } else { false } }.count
    }

    // Session configuration

    func testSessionIsRecordMeasurementWithNoOptionsAndNotifiesOnlyOnDeactivation() throws {
        let port = RecordingPort()
        try DictationSessionPolicy.activate(on: port)
        DictationSessionPolicy.deactivate(on: port)
        XCTAssertEqual(port.categories, [.init(category: .record, mode: .measurement, options: [])],
                       "ducking is not valid with .record")
        XCTAssertEqual(port.activations.map(\.0), [true, false])
        XCTAssertEqual(port.activations[0].1, [], "notifyOthersOnDeactivation is a deactivation option")
        XCTAssertEqual(port.activations[1].1, .notifyOthersOnDeactivation)
    }

    func testAnInputFormatWithoutRateOrChannelsIsRejected() {
        XCTAssertFalse(DictationSessionPolicy.isUsableInput(sampleRate: 0, channelCount: 1))
        XCTAssertFalse(DictationSessionPolicy.isUsableInput(sampleRate: 48_000, channelCount: 0))
        XCTAssertTrue(DictationSessionPolicy.isUsableInput(sampleRate: 48_000, channelCount: 1))
    }

    // Transactional begin

    func testBeginStartsSessionCaptureAndRecognition() throws {
        let rig = rig()
        try begin(rig)
        XCTAssertEqual(rig.session.activations, 1)
        XCTAssertTrue(rig.session.observing)
        XCTAssertEqual(rig.capture.starts, 1)
        XCTAssertEqual(rig.recognizer.started, 1)
        XCTAssertEqual(rig.session.deactivations, 0)
    }

    func testActivationFailureReleasesTheSession() {
        let rig = rig()
        rig.session.activateError = Boom()
        XCTAssertThrowsError(try begin(rig))
        XCTAssertEqual(rig.session.deactivations, 1)
        XCTAssertFalse(rig.session.observing)
        XCTAssertEqual(rig.capture.starts, 0)
        XCTAssertEqual(rig.recognizer.started, 0)
    }

    func testCaptureFailureAfterActivationDeactivatesAndStopsObserving() {
        let rig = rig()
        rig.capture.startError = Boom()
        XCTAssertThrowsError(try begin(rig))
        XCTAssertEqual(rig.session.deactivations, 1, "no leaked active session")
        XCTAssertFalse(rig.session.observing)
        XCTAssertEqual(rig.capture.stops, 1)
        XCTAssertEqual(rig.recognizer.started, 0)
        XCTAssertEqual(endedCount, 0, "begin throws; it does not also report ended")
    }

    // One .ended

    func testInterruptionStopsCaptureReleasesTheSessionAndEndsOnce() async throws {
        let rig = rig(grace: .milliseconds(20))
        try begin(rig)
        rig.recognizer.emit(.transcript("xin"))
        rig.session.post(.interruptionBegan)
        XCTAssertEqual(rig.capture.stops, 1)
        XCTAssertEqual(rig.session.deactivations, 1, "released promptly after capture stops")
        XCTAssertFalse(rig.session.observing)
        // The recogniser delivers its final result, then the grace timer fires.
        rig.recognizer.emit(.transcript("xin chào"))
        rig.recognizer.emit(.ended(failed: false))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(endedCount, 1)
        XCTAssertEqual(updates.first, .transcript("xin"))
    }

    func testRouteLossEndsOnceEvenIfTheRecogniserNeverAnswers() async throws {
        let rig = rig(grace: .milliseconds(20))
        try begin(rig)
        rig.session.post(.inputLost)
        XCTAssertEqual(endedCount, 0, "words in flight get the grace period")
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(endedCount, 1)
        XCTAssertEqual(rig.recognizer.task.cancelled, true)
        XCTAssertEqual(rig.session.deactivations, 1)
    }

    func testCaptureConfigurationChangeEndsOnceAndReleasesTheSession() async throws {
        let rig = rig(grace: .milliseconds(20))
        try begin(rig)
        rig.recognizer.emit(.transcript("xin"))
        rig.capture.changeConfiguration()
        XCTAssertEqual(rig.capture.stops, 1)
        XCTAssertEqual(rig.session.deactivations, 1)
        XCTAssertFalse(rig.session.observing)
        rig.capture.changeConfiguration()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(endedCount, 1)
        XCTAssertEqual(rig.session.deactivations, 1)
        XCTAssertTrue(rig.recognizer.task.cancelled)
    }

    func testMediaServicesResetEndsAtOnceAsAFailure() throws {
        let rig = rig()
        try begin(rig)
        rig.session.post(.mediaServicesReset)
        XCTAssertEqual(updates, [.ended(failed: true)])
        XCTAssertEqual(rig.session.deactivations, 1)
        XCTAssertTrue(rig.recognizer.task.cancelled)
        rig.session.post(.mediaServicesReset)
        rig.recognizer.emit(.ended(failed: true))
        XCTAssertEqual(endedCount, 1, "a late callback does not end it twice")
    }

    func testCancelDeliversNothingAndLateCallbacksAreDropped() throws {
        let rig = rig()
        try begin(rig)
        rig.engine.cancel()
        rig.recognizer.emit(.transcript("muộn"))
        rig.recognizer.emit(.ended(failed: false))
        XCTAssertTrue(updates.isEmpty)
        XCTAssertEqual(rig.capture.stops, 1)
        XCTAssertEqual(rig.session.deactivations, 1)
        XCTAssertTrue(rig.recognizer.task.cancelled)
    }

    func testFinishThenTheFinalResultEndsOnceAndTheGraceTimerStaysQuiet() async throws {
        let rig = rig(grace: .milliseconds(20))
        try begin(rig)
        rig.engine.finish()
        rig.engine.finish()
        XCTAssertEqual(rig.capture.stops, 1, "finish is idempotent")
        rig.recognizer.emit(.transcript("xong"))
        rig.recognizer.emit(.ended(failed: false))
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(updates, [.transcript("xong"), .ended(failed: false)])
    }
}
