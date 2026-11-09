import AVFoundation
import Foundation
import Speech

// The live recogniser: `SFSpeechRecognizer` for the app's language, fed by an
// `AVAudioEngine` microphone tap. On-device when the language supports it, the
// server otherwise. Audio starts only when the person taps the mic and stops
// on a second tap, send, leaving the chat, leaving the foreground, or a system
// event (call, route loss, media-services reset).
//
// The engine owns one lifecycle and talks to three ports (audio session,
// microphone capture, recogniser) so the transaction (`begin` either fully
// starts or leaves nothing active) and the single `.ended` are unit-tested
// without audio hardware. The live ports sit under the engine.

// MARK: Ports

/// What the audio session tells the engine.
enum DictationSessionEvent: Equatable, Sendable {
    /// Another app or a call took the audio.
    case interruptionBegan
    /// The microphone in use went away (headset unplugged).
    case inputLost
    /// `mediaserverd` restarted: every audio object is dead.
    case mediaServicesReset
}

@MainActor
protocol DictationAudioSession: AnyObject {
    /// Configures the session for recording and activates it.
    func activate() throws
    /// Releases the session and tells other audio it may resume.
    func deactivate()
    func observe(_ handler: @escaping @MainActor (DictationSessionEvent) -> Void)
    func stopObserving()
}

/// The microphone feeding a recognition request.
@MainActor
protocol DictationCapture: AnyObject {
    /// Called after the session is active: the input format is only valid then.
    func start(feeding request: SFSpeechAudioBufferRecognitionRequest) throws
    /// Stops the microphone. Idempotent.
    func stop()
    /// Set before `start`. Called when the hardware changed under a running
    /// capture (sample rate or channel count): the capture has already
    /// stopped delivering audio and the owner must end the run.
    var onConfigurationChange: (@MainActor () -> Void)? { get set }
}

protocol DictationRecognitionTask: AnyObject {
    func cancel()
}

@MainActor
protocol DictationRecognizing: AnyObject {
    /// Configures `request` for this recogniser and starts a task. Updates
    /// arrive on the main actor.
    func start(request: SFSpeechAudioBufferRecognitionRequest,
               onUpdate: @escaping @MainActor (DictationUpdate) -> Void) -> any DictationRecognitionTask
}

enum DictationStartError: Error {
    case noRecognizer
    case noInput
}

// MARK: Session policy

/// The slice of `AVAudioSession` the policy touches, so the configuration is
/// asserted without a device.
protocol AudioSessionPort {
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws
}

extension AVAudioSession: AudioSessionPort {}

/// Speech capture needs the microphone only: `.record`, no options (ducking
/// is not allowed with `.record`, and nothing is playing that needs it).
/// `.notifyOthersOnDeactivation` is valid only when deactivating.
enum DictationSessionPolicy {
    static let category = AVAudioSession.Category.record
    static let mode = AVAudioSession.Mode.measurement
    static let activationOptions: AVAudioSession.CategoryOptions = []
    static let deactivationOptions = AVAudioSession.SetActiveOptions.notifyOthersOnDeactivation

    static func activate(on port: some AudioSessionPort) throws {
        try port.setCategory(category, mode: mode, options: activationOptions)
        try port.setActive(true, options: [])
    }

    static func deactivate(on port: some AudioSessionPort) {
        try? port.setActive(false, options: deactivationOptions)
    }

    /// A zero-rate or zero-channel input format (no microphone, mid route
    /// change) makes `installTap` raise an Objective-C exception.
    static func isUsableInput(sampleRate: Double, channelCount: AVAudioChannelCount) -> Bool {
        sampleRate > 0 && channelCount > 0
    }
}

// MARK: Engine

@MainActor
final class SpeechDictationEngine: DictationEngine {
    /// After the microphone stops the recogniser should deliver its final
    /// result; if it never does, the run ends anyway.
    static let defaultFinishGrace = Duration.seconds(2)

    private let session: any DictationAudioSession
    private let makeCapture: () -> any DictationCapture
    private let finishGrace: Duration
    private let localeIdentifier: String
    private var recognizer: (any DictationRecognizing)?
    private let recognizerIsPreset: Bool

    private var capture: (any DictationCapture)?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: (any DictationRecognitionTask)?
    private var sink: (@MainActor (DictationUpdate) -> Void)?
    private var fallback: Task<Void, Never>?
    private var sessionHeld = false
    /// Bumped by every begin and cancel so a late callback is ignored.
    private var run: UInt64 = 0

    init(localeIdentifier: String) {
        self.localeIdentifier = localeIdentifier
        self.session = SystemDictationAudioSession()
        self.makeCapture = { MicrophoneCapture() }
        self.finishGrace = Self.defaultFinishGrace
        self.recognizerIsPreset = false
    }

    /// Tests: ports are given, authorisation is not asked.
    init(session: any DictationAudioSession,
         makeCapture: @escaping () -> any DictationCapture,
         recognizer: any DictationRecognizing,
         finishGrace: Duration = SpeechDictationEngine.defaultFinishGrace) {
        self.localeIdentifier = ""
        self.session = session
        self.makeCapture = makeCapture
        self.recognizer = recognizer
        self.recognizerIsPreset = true
        self.finishGrace = finishGrace
    }

    func authorize() async -> DictationAvailability {
        if recognizerIsPreset { return .ready }
        guard let candidate = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
                ?? SFSpeechRecognizer(),
              candidate.isAvailable else { return .unavailable }
        let speech = await Self.requestSpeechAccess()
        guard speech == .authorized else { return .denied }
        guard await Self.requestMicrophoneAccess() else { return .denied }
        recognizer = SystemDictationRecognizer(candidate)
        return .ready
    }

    /// Transactional: it either returns with the session active, the
    /// microphone running and the recogniser listening, or throws with the
    /// session released and nothing left running.
    func begin(onUpdate: @escaping @MainActor (DictationUpdate) -> Void) throws {
        guard let recognizer else { throw DictationStartError.noRecognizer }
        teardown()
        run &+= 1
        let token = run
        do {
            // Held before activating: `activate()` can throw after the
            // category was set, and the catch must still release.
            sessionHeld = true
            try session.activate()
            session.observe { [weak self] event in self?.handle(event, run: token) }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            let capture = makeCapture()
            self.capture = capture
            capture.onConfigurationChange = { [weak self] in self?.handleConfigurationChange(run: token) }
            try capture.start(feeding: request)

            self.request = request
            self.sink = onUpdate
            task = recognizer.start(request: request) { [weak self] update in
                self?.receive(update, run: token)
            }
        } catch {
            teardown()
            throw error
        }
    }

    func finish() {
        guard sink != nil, fallback == nil else { return }
        stopCapture()
        request?.endAudio()
        // The task stays alive: it delivers the last words and then ends by
        // itself. If it never does, end the run after the grace period.
        let token = run
        fallback = Task { @MainActor [weak self, finishGrace] in
            try? await Task.sleep(for: finishGrace)
            guard !Task.isCancelled else { return }
            self?.end(failed: false, run: token)
        }
    }

    func cancel() {
        run &+= 1
        teardown()
    }

    // MARK: Lifecycle

    private func receive(_ update: DictationUpdate, run token: UInt64) {
        guard token == run, let sink else { return }
        switch update {
        case .transcript: sink(update)
        case let .ended(failed): end(failed: failed, run: token)
        }
    }

    private func handle(_ event: DictationSessionEvent, run token: UInt64) {
        guard token == run, sink != nil else { return }
        switch event {
        case .interruptionBegan, .inputLost: finish()
        case .mediaServicesReset: end(failed: true, run: token)
        }
    }

    /// A silent capture must not look like a live one: stop it, give words in
    /// flight the grace period, then end through the usual single path.
    private func handleConfigurationChange(run token: UInt64) {
        guard token == run, sink != nil else { return }
        finish()
    }

    /// The one place `.ended` is delivered: the sink is taken first, so a
    /// second cause (the grace timer after the final result) finds none.
    private func end(failed: Bool, run token: UInt64) {
        guard token == run, let delivered = sink else { return }
        teardown()
        delivered(.ended(failed: failed))
    }

    private func stopCapture() {
        capture?.stop()
        capture = nil
        session.stopObserving()
        if sessionHeld {
            sessionHeld = false
            session.deactivate()
        }
    }

    private func teardown() {
        fallback?.cancel()
        fallback = nil
        sink = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        stopCapture()
    }

    // MARK: Authorisation

    private nonisolated static func requestSpeechAccess() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private nonisolated static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }
}

// MARK: Live ports

@MainActor
final class SystemDictationAudioSession: DictationAudioSession {
    private let port: AVAudioSession
    private var tokens = [any NSObjectProtocol]()

    init(port: AVAudioSession = .sharedInstance()) { self.port = port }

    func activate() throws {
        try DictationSessionPolicy.activate(on: port)
    }

    func deactivate() {
        DictationSessionPolicy.deactivate(on: port)
    }

    func observe(_ handler: @escaping @MainActor (DictationSessionEvent) -> Void) {
        stopObserving()
        let center = NotificationCenter.default
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification,
                                              object: port, queue: .main) { note in
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
            Task { @MainActor in
                if raw == AVAudioSession.InterruptionType.began.rawValue { handler(.interruptionBegan) }
            }
        }
        let route = center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                       object: port, queue: .main) { note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
            Task { @MainActor in
                let lost = raw == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
                if lost, AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty { handler(.inputLost) }
            }
        }
        let reset = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                       object: port, queue: .main) { _ in
            Task { @MainActor in handler(.mediaServicesReset) }
        }
        tokens = [interruption, route, reset]
    }

    func stopObserving() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }
}

/// The audio tap runs on a background thread, so the tap closure is made in a
/// `nonisolated` helper (a closure made inside a main-actor method would be
/// main-actor isolated and trap off the main thread under Swift 6).
@MainActor
final class MicrophoneCapture: DictationCapture {
    private var engine: AVAudioEngine?
    private var configurationObserver: (any NSObjectProtocol)?
    var onConfigurationChange: (@MainActor () -> Void)?

    func start(feeding request: SFSpeechAudioBufferRecognitionRequest) throws {
        let engine = AVAudioEngine()
        // Read after the session is active; before that the format can be
        // stale or empty.
        let format = engine.inputNode.outputFormat(forBus: 0)
        guard DictationSessionPolicy.isUsableInput(sampleRate: format.sampleRate,
                                                   channelCount: format.channelCount) else {
            throw DictationStartError.noInput
        }
        Self.installTap(on: engine.inputNode, format: format, request: request)
        engine.prepare()
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        // Posted (on an arbitrary thread) after the engine stopped itself
        // because the input hardware changed format.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.onConfigurationChange?() }
        }
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    private nonisolated static func installTap(on node: AVAudioInputNode, format: AVAudioFormat,
                                               request: SFSpeechAudioBufferRecognitionRequest) {
        let sink = RequestBox(request)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.request.append(buffer)
        }
    }
}

@MainActor
final class SystemDictationRecognizer: DictationRecognizing {
    private let recognizer: SFSpeechRecognizer

    init(_ recognizer: SFSpeechRecognizer) { self.recognizer = recognizer }

    func start(request: SFSpeechAudioBufferRecognitionRequest,
               onUpdate: @escaping @MainActor (DictationUpdate) -> Void) -> any DictationRecognitionTask {
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        return Self.recognize(with: recognizer, request: request, onUpdate: onUpdate)
    }

    private nonisolated static func recognize(
        with recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        onUpdate: @escaping @MainActor (DictationUpdate) -> Void
    ) -> any DictationRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in
                if let text { onUpdate(.transcript(text)) }
                if final || failed { onUpdate(.ended(failed: failed && !final)) }
            }
        }
    }
}

extension SFSpeechRecognitionTask: DictationRecognitionTask {}

/// `SFSpeechAudioBufferRecognitionRequest.append(_:)` is documented as safe
/// from the audio thread; the box only carries the reference across.
private final class RequestBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
}
