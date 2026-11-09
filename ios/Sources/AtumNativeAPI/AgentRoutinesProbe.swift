import Foundation

public enum AgentRoutinesLoadResult: Equatable, Sendable {
    case value(AgentRoutinesSnapshot)
    case failed
}

/// Drives the agent card's "Lịch tự động" readiness. Every call reaches the
/// server again; the card re-probes each time it appears so an `unknown`
/// legacy state can become `clear` without restarting the app.
///
/// A card can appear again before the previous read returned. Only one read
/// runs at a time, and a result is applied only when it still belongs to the
/// newest, un-cancelled probe, so no stale phase can land after dismiss.
@MainActor
public final class AgentRoutinesProbe {
    public enum Phase: Equatable, Sendable {
        case idle, loading, ready, preparing, legacyPending, failed
    }

    public private(set) var phase: Phase = .idle
    public private(set) var snapshot: AgentRoutinesSnapshot?
    public var routineCount: Int? { snapshot?.routines.count }
    private let read: () async -> AgentRoutinesLoadResult
    private var generation: UInt64 = 0
    private var inFlight: UInt64?

    public init(read: @escaping () async -> AgentRoutinesLoadResult) {
        self.read = read
    }

    /// Returns the new phase, or `nil` when a probe was already running or
    /// its result was cancelled or superseded.
    @discardableResult
    public func probe() async -> Phase? {
        guard inFlight == nil else { return nil }
        generation &+= 1
        let token = generation
        inFlight = token
        phase = .loading
        let result = await read()
        guard token == generation, inFlight == token else { return nil }
        inFlight = nil
        guard !Task.isCancelled else {
            phase = .idle
            return nil
        }
        apply(result)
        return phase
    }

    /// Invalidates an in-flight probe when the card disappears, so its result
    /// cannot land, and frees the slot for the next appearance.
    public func cancel() {
        generation &+= 1
        inFlight = nil
        if phase == .loading { phase = .idle }
    }

    private func apply(_ result: AgentRoutinesLoadResult) {
        switch result {
        case let .value(value):
            snapshot = value
            phase = Self.phase(for: value.legacyState)
        case .failed:
            snapshot = nil
            phase = .failed
        }
    }

    public static func phase(for legacyState: AgentRoutinesSnapshot.LegacyState) -> Phase {
        switch legacyState {
        case .clear: .ready
        case .present: .legacyPending
        case .unknown: .preparing
        }
    }
}
