import Foundation

/// Which model row an assistant's card offers.
///
/// Placement (`Lives on · Model · Move`) is offered only when the platform has
/// advertised it for this assistant. In every other settled state the card keeps
/// the model-destination editor that predates placement, so a platform or client
/// that cannot move an assistant never leaves the owner without a way to pick a
/// model. While the first read is out the row just waits.
///
/// One exception keeps the sheet: an assistant that lives on a Mac the platform
/// cannot use right now (`AgentHomeSnapshot.waitsForHomeMac`) advertises no move,
/// but the owner can still wait for that Mac, move to the cloud knowingly, or
/// cancel a move, so the sheet stays reachable and says so.
public enum AgentHomeCardRoute: Equatable, Sendable {
    /// What the card knows about the placement summary.
    public enum Read: Equatable, Sendable {
        case pending
        case answered(AgentHomeMoveCapability, waitingForHome: Bool = false)
        /// The platform has no placement for this assistant (or does not allow it).
        case unavailable
        case failed
    }

    case waiting
    case placement
    case legacyEditor

    public init(_ read: Read) {
        switch read {
        case .pending: self = .waiting
        case let .answered(capability, waitingForHome):
            switch capability {
            case .available: self = .placement
            case .unavailable(.platformNotReady) where waitingForHome: self = .placement
            case .unavailable: self = .legacyEditor
            }
        case .unavailable, .failed: self = .legacyEditor
        }
    }
}
