import Foundation
import MatrixRustSDK
import Observation

/// One self-verification flow per live Matrix client. Rust owns the request,
/// transcript, emoji and trust writes. This controller owns the user's decision.
@MainActor @Observable
final class MatrixSASVerification {
    struct Emoji: Equatable, Sendable {
        let symbol: String
        let description: String
    }

    struct Invitation: Equatable, Sendable {
        let id: UUID
        let deviceName: String?
    }

    enum Outcome: Equatable, Sendable {
        case matched, mismatch, cancelled, peerCancelled, timedOut, unavailable
    }

    enum State: Equatable, Sendable {
        case idle
        case incoming(Invitation)
        case requested(UUID)
        case accepted(UUID)
        case comparing(UUID, [Emoji])
        case waitingForPeer(UUID)
        case finished(Outcome)
    }

    private(set) var state: State = .idle
    private let userID: String
    private let deviceID: String
    private let timeout: Duration
    private let requireCurrent: @MainActor () throws -> Void
    private let load: @MainActor () async throws -> any SessionVerificationControllerProtocol
    @ObservationIgnored private var native: (any SessionVerificationControllerProtocol)?
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var attempt: UUID?
    @ObservationIgnored private var deadline: ContinuousClock.Instant?
    @ObservationIgnored private var previousRequestCancel: SessionVerificationCancelInfo?
    @ObservationIgnored private var previousSASCancel: SessionVerificationCancelInfo?
    @ObservationIgnored private var sawSASStart = false
    @ObservationIgnored private var actionInFlight = false
    @ObservationIgnored private var deferredCancellation = false
    @ObservationIgnored private var invalidated = false

    init(userID: String, deviceID: String, timeout: Duration = .seconds(120),
         requireCurrent: @escaping @MainActor () throws -> Void,
         load: @escaping @MainActor () async throws -> any SessionVerificationControllerProtocol) {
        self.userID = userID
        self.deviceID = deviceID
        self.timeout = timeout
        self.requireCurrent = requireCurrent
        self.load = load
    }

    /// Attach before the peer initiates. The SDK requires an existing Matrix
    /// cross-signing identity to create this delegate-backed controller.
    func listen() async {
        guard native == nil, !actionInFlight, isCurrent else { return }
        actionInFlight = true
        defer { actionInFlight = false }
        do {
            try await attach()
        } catch {
            if isCurrent { state = .finished(.unavailable) }
        }
    }

    func request() async {
        guard attempt == nil, !actionInFlight, isCurrent, !Task.isCancelled else { return }
        let id = begin()
        state = .requested(id)
        await perform(id) {
            try await attach()
            try requireActive(id)
            guard let native else { throw CancellationError() }
            try await native.requestDeviceVerification()
        }
    }

    func accept(_ id: UUID) async {
        guard case .incoming(let invitation) = state, invitation.id == id,
              let native, !actionInFlight,
              (try? requireActive(id)) != nil else { return }
        state = .accepted(id)
        await perform(id) { try await native.acceptVerificationRequest() }
    }

    /// Pass the ID attached to the seven emoji being compared. A duplicate
    /// tap or an action left over from an older presentation has no authority.
    func compare(_ id: UUID, matches: Bool) async {
        guard case .comparing(let currentID, _) = state, currentID == id,
              !actionInFlight, let native, (try? requireActive(id)) != nil else { return }
        if matches {
            state = .waitingForPeer(id)
            await perform(id) { try await native.approveVerification() }
        } else {
            finish(.mismatch)
            actionInFlight = true
            defer { actionInFlight = false }
            do {
                try await native.declineVerification()
            } catch {
                if isCurrent { try? await native.cancelVerification() }
            }
        }
    }

    /// Keep the ID from the current flow when presenting a cancel action.
    func cancel(_ id: UUID) async {
        guard attempt == id, isCurrent else { return }
        await abort(.cancelled)
    }

    func invalidate() {
        invalidated = true
        native?.setDelegate(delegate: nil)
        events?.cancel()
        events = nil
        native = nil
        finish(.cancelled)
    }

    private var isCurrent: Bool {
        !invalidated && (try? requireCurrent()) != nil
    }

    private func attach() async throws {
        if native != nil { return }
        let controller = try await load()
        try requireCurrent()
        guard !invalidated, !Task.isCancelled else { throw CancellationError() }
        let (stream, continuation) = AsyncStream.makeStream(of: SASDelegate.Event.self)
        controller.setDelegate(delegate: SASDelegate(continuation))
        native = controller
        events = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.receive(event)
            }
        }
    }

    private func begin() -> UUID {
        let id = UUID()
        attempt = id
        previousRequestCancel = native?.requestCancelInfo()
        previousSASCancel = native?.sasCancelInfo()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        self.deadline = deadline
        timer = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard let self, self.attempt == id else { return }
            // This task owns the expiry. Clearing its handle prevents finish
            // from cancelling the task that must send the native cancellation.
            self.timer = nil
            await self.abort(.timedOut)
        }
        return id
    }

    private func requireActive(_ id: UUID) throws {
        guard isCurrent, !Task.isCancelled, attempt == id,
              let deadline, ContinuousClock.now < deadline else { throw CancellationError() }
    }

    private func perform(_ id: UUID, action: () async throws -> Void) async {
        actionInFlight = true
        do {
            try requireActive(id)
            try await action()
            if attempt == id { try requireActive(id) }
        } catch {
            if attempt == id {
                await abort(deadline.map { ContinuousClock.now >= $0 } == true ? .timedOut : .unavailable)
            }
        }
        if deferredCancellation {
            deferredCancellation = false
            if isCurrent { try? await native?.cancelVerification() }
        }
        actionInFlight = false
        // The peer may be ready before requestDeviceVerification returns.
        await startOutgoingSASIfReady(id)
    }

    private func startOutgoingSASIfReady(_ id: UUID) async {
        guard state == .accepted(id), outgoingReady, !actionInFlight, let native else { return }
        outgoingReady = false
        await perform(id) { try await native.startSasVerification() }
    }

    @ObservationIgnored private var outgoingReady = false

    private func receive(_ event: SASDelegate.Event) async {
        guard isCurrent else { invalidate(); return }
        if case .incoming(let sender, let device, let name, let flowID) = event {
            guard attempt == nil, !actionInFlight, let native,
                  sender == userID, device != deviceID, !device.isEmpty, !flowID.isEmpty else { return }
            let id = begin()
            await perform(id) {
                try await native.acknowledgeVerificationRequest(senderId: userID, flowId: flowID)
                try requireActive(id)
                state = .incoming(.init(id: id, deviceName: name))
            }
            return
        }
        guard let id = attempt else { return }
        guard let deadline, ContinuousClock.now < deadline else { await abort(.timedOut); return }
        switch event {
        case .accepted:
            // The pinned Rust delegate reports Ready for both directions.
            // Only the requester starts SAS. A responder waits for peer Start.
            guard state == .requested(id) else { return }
            state = .accepted(id)
            outgoingReady = true
            await startOutgoingSASIfReady(id)
        case .started:
            if state == .requested(id) { state = .accepted(id) }
            guard state == .accepted(id) else { return }
            sawSASStart = true
            outgoingReady = false
        case .emoji(let emoji):
            guard state == .accepted(id), sawSASStart else { return }
            guard emoji.count == 7 else { await abort(.unavailable); return }
            outgoingReady = false
            state = .comparing(id, emoji)
        case .failed:
            await abort(.unavailable)
        case .cancelled:
            let requestCancel = native?.requestCancelInfo()
            let sasCancel = native?.sasCancelInfo()
            let cancellation = requestCancel != previousRequestCancel ? requestCancel
                : sasCancel != previousSASCancel ? sasCancel : nil
            let outcome: Outcome = switch cancellation?.cancelCode {
            case "m.timeout": .timedOut
            case "m.mismatched_sas": .mismatch
            default: .peerCancelled
            }
            finish(outcome)
        case .done:
            guard state == .waitingForPeer(id) else { await abort(.unavailable); return }
            finish(.matched)
        case .incoming:
            break
        }
    }

    private func abort(_ outcome: Outcome) async {
        finish(outcome)
        guard isCurrent else { return }
        if actionInFlight {
            deferredCancellation = true
        } else {
            actionInFlight = true
            defer { actionInFlight = false }
            try? await native?.cancelVerification()
        }
    }

    private func finish(_ outcome: Outcome) {
        timer?.cancel()
        timer = nil
        attempt = nil
        deadline = nil
        outgoingReady = false
        sawSASStart = false
        state = .finished(outcome)
    }
}

private final class SASDelegate: SessionVerificationControllerDelegate {
    enum Event: Sendable {
        case incoming(sender: String, device: String, name: String?, flowID: String)
        case accepted, started, emoji([MatrixSASVerification.Emoji]), failed, cancelled, done
    }

    private let sink: AsyncStream<Event>.Continuation
    init(_ sink: AsyncStream<Event>.Continuation) { self.sink = sink }
    deinit { sink.finish() }

    func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        sink.yield(.incoming(sender: details.senderProfile.userId, device: details.deviceId,
                             name: details.deviceDisplayName, flowID: details.flowId))
    }
    func didAcceptVerificationRequest() { sink.yield(.accepted) }
    func didStartSasVerification() { sink.yield(.started) }
    func didReceiveVerificationData(data: SessionVerificationData) {
        guard case .emojis(let emojis, _) = data else { sink.yield(.failed); return }
        sink.yield(.emoji(emojis.map { .init(symbol: $0.symbol(), description: $0.description()) }))
    }
    func didFail() { sink.yield(.failed) }
    func didCancel() { sink.yield(.cancelled) }
    func didFinish() { sink.yield(.done) }
}
