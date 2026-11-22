import Foundation

/// The status descriptor carries categories and a bounded elapsed time.
public enum ChatProgressPresentation: Equatable, Hashable, Sendable {
    public enum Activity: String, CaseIterable, Hashable, Sendable {
        case web, read, write, run, delegate, look, draw
    }

    case toolActivity(Activity)
    case heartbeat(minutes: Int)
    case approvalWait
    case videoConsentRequired

    private static let prefix = "shared.matrix-status-line-copy."

    public var exportKey: String {
        let suffix: String
        switch self {
        case let .toolActivity(activity): suffix = "matrixToolActivityCopy." + activity.rawValue
        case .heartbeat: suffix = "matrixProgressCopy.heartbeat"
        case .approvalWait: suffix = "matrixApprovalWaitCopy"
        case .videoConsentRequired: suffix = "matrixVideoConsentWaitCopy"
        }
        return Self.prefix + suffix
    }

    public var minutes: Int? {
        if case let .heartbeat(minutes) = self { return minutes }
        return nil
    }
}

/// The supplied lookup reads the current language from the pinned export.
/// Video consent still uses the desktop English line until the key is exported.
public enum TurnStatusPendingCopy {
    public static func text(_ status: ChatProgressPresentation,
                            exported: (String, Int?) -> String?) -> String? {
        if let value = exported(status.exportKey, status.minutes) { return value }
        guard status == .videoConsentRequired else { return nil }
        return "Waiting for you to allow video…"
    }
}
