/// S2's bounded wait for the three Home inputs: Matrix rooms, `/agents`, and
/// `/apps`. The app supplies a monotonic `holdExpired` bit after three seconds;
/// this policy contains no clock and is deterministic in package tests.
public enum HomeReadiness {
    public enum Source: Equatable, Sendable {
        case loading
        case ready
        case offline
        case failed
    }

    public enum Result: Equatable, Sendable {
        case loading
        case ready
        case empty
        case offline
        case error
    }

    public struct Input: Equatable, Sendable {
        public var hasListedRows: Bool
        /// Matrix may have cached rooms before agent classification finishes.
        /// When those rooms exist, `LiveRosterRows` can still list unknown
        /// one-to-one rooms as people after the hold expires.
        public var hasMatrixRooms: Bool
        public var rooms: Source
        public var agents: Source
        public var apps: Source
        public var holdExpired: Bool

        public init(hasListedRows: Bool, hasMatrixRooms: Bool,
                    rooms: Source, agents: Source, apps: Source,
                    holdExpired: Bool) {
            self.hasListedRows = hasListedRows
            self.hasMatrixRooms = hasMatrixRooms
            self.rooms = rooms
            self.agents = agents
            self.apps = apps
            self.holdExpired = holdExpired
        }
    }

    public static func decide(_ input: Input) -> Result {
        // Cached or newly projected rows always paint immediately.
        if input.hasListedRows { return .ready }

        let isWaiting = input.rooms == .loading
            || input.agents == .loading
            || input.apps == .loading
        if isWaiting, !input.holdExpired { return .loading }

        // The room list is the only source whose outage means there is no
        // recoverable Home data at all. Domain classification failures can
        // still yield useful Matrix rows.
        switch input.rooms {
        case .offline: return .offline
        case .failed: return .error
        case .loading, .ready: break
        }

        switch input.agents {
        case .offline where !input.hasMatrixRooms: return .offline
        case .failed where !input.hasMatrixRooms: return .error
        case .loading, .ready, .offline, .failed: break
        }

        // At the hold limit, paint what is known. A later room/domain result
        // replaces this empty/partial projection once, without trapping Home
        // behind an indefinite spinner.
        return input.hasMatrixRooms ? .ready : .empty
    }
}
