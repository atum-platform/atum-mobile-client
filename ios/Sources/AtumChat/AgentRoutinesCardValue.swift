import Foundation

/// The value beside "Lịch tự động" on the agent card. The app speaks
/// Vietnamese first, so this is app language copy rather than a device
/// locale; zero routines reads as "Chưa có", never "0 việc".
public enum AgentRoutinesCardValue {
    public static func text(count: Int) -> String {
        guard count > 0 else { return "Chưa có" }
        return "\(count) việc"
    }
}
