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

/// Pending English values from desktop's matrix-status-line-copy.ts. The
/// supplied lookup reads the current language from the pinned export.
public enum TurnStatusPendingCopy {
    public static func text(_ status: ChatProgressPresentation,
                            exported: (String, Int?) -> String?) -> String {
        if let value = exported(status.exportKey, status.minutes) { return value }
        switch status {
        case .toolActivity(.web): return "Looking it up on the web…"
        case .toolActivity(.read): return "Reading…"
        case .toolActivity(.write): return "Editing files…"
        case .toolActivity(.run): return "Running a task…"
        case .toolActivity(.delegate): return "Getting a helper on it…"
        case .toolActivity(.look): return "Looking at the image…"
        case .toolActivity(.draw): return "Drawing…"
        case let .heartbeat(minutes): return "Still working · \(minutes) min"
        case .approvalWait: return "Waiting for your OK…"
        case .videoConsentRequired: return "Waiting for you to allow video…"
        }
    }
}
