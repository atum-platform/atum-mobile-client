import Foundation
import Observation

// Dictation into the composer draft (owner direction 2026-10-24: the mic is
// dictation, not a voice message). `ComposerDictation` is the state machine
// the composer reads; the recognizer behind it is a seam (`DictationEngine`)
// so the machine is unit-tested without audio. The live engine is
// `SpeechDictationEngine` (Speech + AVAudioEngine).

/// Whether the device may listen and recognise speech.
enum DictationAvailability: Equatable, Sendable {
    case ready
    /// The person refused, or restricted, the microphone or speech access.
    case denied
    /// No recogniser for the language, or the engine would not start.
    case unavailable
}

enum DictationUpdate: Equatable, Sendable {
    /// The whole transcript so far (cumulative, as Speech reports it).
    case transcript(String)
    /// The recognition ended: after `finish()`, by itself, or on a failure.
    case ended(failed: Bool)
}

/// The recogniser seam. Implementations call `onUpdate` on the main actor and
/// never after `cancel()` has returned.
@MainActor
protocol DictationEngine: AnyObject {
    func authorize() async -> DictationAvailability
    func begin(onUpdate: @escaping @MainActor (DictationUpdate) -> Void) throws
    /// Ends the audio and lets the last words arrive, then `.ended`.
    func finish()
    /// Tears down at once; nothing is delivered afterwards.
    func cancel()
}

/// Appends a cumulative transcript to the draft that was there when
/// dictation started. When the person edits the draft meanwhile, what they
/// typed becomes the new base and only words spoken afterwards are added.
struct DictationDraftMerge: Equatable {
    private var base: String
    private var applied: String?
    private var consumed = 0
    private var seen = 0

    init(base: String) { self.base = base }

    mutating func merged(current: String, transcript: String) -> String {
        // Anything other than what was last written (or, before the first
        // partial, the draft dictation started from) is the person typing.
        if current != (applied ?? base) {
            base = current
            consumed = seen
        }
        seen = transcript.count
        let spoken = String(transcript.dropFirst(min(consumed, transcript.count)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result: String
        if spoken.isEmpty {
            result = base
        } else if base.isEmpty || base.last?.isWhitespace == true {
            result = base + spoken
        } else {
            result = base + " " + spoken
        }
        applied = result
        return result
    }
}

@MainActor
@Observable
final class ComposerDictation {
    enum State: Equatable {
        case idle
        /// Asking for microphone and speech access.
        case requesting
        case recording
        /// Audio ended, the last words are still arriving.
        case finishing
    }

    enum Refusal: Equatable {
        case permissionDenied
        case unavailable
    }

    private(set) var state = State.idle
    private(set) var refusal: Refusal?

    var isRecording: Bool { state == .recording }
    var isActive: Bool { state != .idle }

    @ObservationIgnored private let engine: any DictationEngine
    @ObservationIgnored private var heardSpeech = false
    @ObservationIgnored private var merge = DictationDraftMerge(base: "")
    /// Bumped by every start and cancel so a late authorisation answer or
    /// recogniser callback from an older run is ignored.
    @ObservationIgnored private var generation: UInt64 = 0

    init(engine: any DictationEngine) { self.engine = engine }

    /// Tap on the mic: starts, or stops and keeps the recognised words.
    func toggle(draft: @escaping @MainActor () -> String,
                setDraft: @escaping @MainActor (String) -> Void) {
        switch state {
        case .idle: start(draft: draft, setDraft: setDraft)
        case .recording: finish()
        case .requesting, .finishing: break
        }
    }

    /// Stops listening; words still in flight are added to the draft.
    func finish() {
        guard state == .recording else { return }
        state = .finishing
        engine.finish()
    }

    /// Stops at once and drops anything in flight (send, leaving the chat,
    /// entering edit mode).
    func cancel() {
        guard state != .idle else { return }
        generation &+= 1
        engine.cancel()
        state = .idle
    }

    func clearRefusal() { refusal = nil }

    private func start(draft: @escaping @MainActor () -> String,
                       setDraft: @escaping @MainActor (String) -> Void) {
        refusal = nil
        generation &+= 1
        let run = generation
        state = .requesting
        Task { @MainActor [self] in
            let availability = await engine.authorize()
            guard run == generation, state == .requesting else { return }
            switch availability {
            case .denied: return fail(.permissionDenied)
            case .unavailable: return fail(.unavailable)
            case .ready: break
            }
            merge = DictationDraftMerge(base: draft())
            heardSpeech = false
            do {
                try engine.begin { [weak self] update in
                    guard let self, run == self.generation else { return }
                    switch update {
                    case let .transcript(text):
                        self.heardSpeech = self.heardSpeech || !text.isEmpty
                        setDraft(self.merge.merged(current: draft(), transcript: text))
                    case let .ended(failed):
                        // A failure after tap-to-stop, or after words were heard,
                        // is just the end ("no speech", "cancelled").
                        if failed, self.state == .recording, !self.heardSpeech { self.refusal = .unavailable }
                        self.state = .idle
                    }
                }
                state = .recording
            } catch {
                fail(.unavailable)
            }
        }
    }

    private func fail(_ value: Refusal) {
        generation &+= 1
        state = .idle
        refusal = value
    }
}
