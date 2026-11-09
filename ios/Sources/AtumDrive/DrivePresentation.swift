import AtumNativeAPI

public enum DriveEmptyStateKind: Equatable, Sendable {
    case loading
    case connect
    case signInAgain
    case provisioning
    case denied
    case offline
    case unavailable
    case empty
}

public enum DriveConnectionCopyKey: Equatable, Sendable {
    case none
    case refreshing
    case provisioning
    case denied
    case signInAgain
    case offline
    case unavailable
    case stale
}

public enum DrivePresentationPolicy {
    public static func emptyState(connection: DriveConnectionState,
                                  directory: DriveDirectoryCondition) -> DriveEmptyStateKind {
        switch connection {
        case .idle, .connecting: .loading
        case .disconnected: .connect
        case .reauthenticationRequired: .signInAgain
        case .provisioning: .provisioning
        case .denied: .denied
        case .offline: .offline
        case .serviceUnavailable, .rateLimited, .timedOut, .secureConnectionFailed,
             .storageUnavailable, .failed: .unavailable
        case .ready:
            switch directory {
            case .loading: .loading
            case .needsConnection: .signInAgain
            case .denied: .denied
            case .offline: .offline
            case .failed: .unavailable
            case .fresh, .stale: .empty
            }
        }
    }

    public static func connectionCopy(connection: DriveConnectionState,
                                      hasItems: Bool,
                                      directory: DriveDirectoryCondition) -> DriveConnectionCopyKey {
        switch connection {
        case .connecting: .refreshing
        case .provisioning: .provisioning
        case .denied: .denied
        case .reauthenticationRequired: .signInAgain
        case .offline: hasItems ? .stale : .offline
        case .serviceUnavailable, .rateLimited, .timedOut, .secureConnectionFailed,
             .storageUnavailable, .failed: .unavailable
        case .disconnected: hasItems ? .stale : .none
        case .idle: .none
        case .ready: directory == .stale ? .stale : .none
        }
    }
}

public enum DriveExitReason: Equatable, Sendable {
    case signOut
    case signInAgain
    case forcedSessionEnd
}

public enum DriveAccessFailurePolicy {
    public static func state(for failure: OIDCGrantFailure) -> LiveDriveAccessState {
        failure == .storageUnavailable ? .serviceUnavailable : .reauthenticationRequired
    }
}
