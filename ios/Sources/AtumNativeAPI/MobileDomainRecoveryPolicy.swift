import Foundation

/// Presentation-safe classification for the independent account/domain grant.
/// Matrix remains usable in every state; only a definitive grant failure asks
/// the person to authorize the domain client again.
public enum MobileDomainRecoveryState: Equatable, Sendable {
    case available
    case temporarilyUnavailable
    case reauthenticationRequired
}

public enum MobileDomainRecoveryPolicy {
    public static func state(for error: any Error) -> MobileDomainRecoveryState {
        if let failure = error as? OIDCGrantFailure {
            return switch failure {
            case .storageUnavailable:
                .temporarilyUnavailable
            case .reauthenticationRequired, .refreshInterrupted, .invalidResponse, .invalidIdentity:
                .reauthenticationRequired
            }
        }
        if let failure = error as? OIDCFailure, failure == .subjectMismatch {
            return .reauthenticationRequired
        }
        if let failure = error as? MASHTTPFailure {
            return switch failure {
            case .authenticationRefused:
                .reauthenticationRequired
            case .invalidRequest, .invalidResponse, .responseTooLarge, .redirectRefused,
                 .bodyReplayRefused, .transportUnavailable, .cancelled, .httpStatus:
                .temporarilyUnavailable
            }
        }
        if let failure = error as? NativeDomainClientFailure {
            return switch failure {
            case .authenticationRefused:
                .reauthenticationRequired
            case let .http(http) where http.response.error == .unauthenticated:
                .reauthenticationRequired
            case .invalidRequest, .invalidResponse, .responseTooLarge, .redirectRefused,
                 .transportUnavailable, .cancelled, .http, .assistantName:
                .temporarilyUnavailable
            }
        }
        return .temporarilyUnavailable
    }
}
