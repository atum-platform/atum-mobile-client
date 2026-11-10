import Foundation

/// HC-4: what an empty chat shows (desktop `app.tsx` `Conversation` empty
/// state and `greeting.tsx`). An assistant's chat opens on the assistant's
/// face, the time of day's greeting, one line of invitation and three
/// starters that fill the composer without sending. A person's or a group's
/// chat says "No messages yet."
public enum EmptyChatPolicy {
    public enum Content: Equatable, Sendable {
        case assistantGreeting
        case noMessages
    }

    public enum Period: Equatable, Sendable { case morning, afternoon, evening }

    public static func content(for kind: RoomKind) -> Content {
        kind == .assistant ? .assistantGreeting : .noMessages
    }

    /// Desktop `greetingFor`: morning from 5, afternoon from noon, evening
    /// from 6 pm (and through the night).
    public static func period(hour: Int) -> Period {
        if hour >= 5 && hour < 12 { return .morning }
        return hour >= 12 && hour < 18 ? .afternoon : .evening
    }

    public static func greetingKey(_ period: Period) -> ChatCopyKey {
        switch period {
        case .morning: .greetingMorning
        case .afternoon: .greetingAfternoon
        case .evening: .greetingEvening
        }
    }

    /// One starter chip: what it says, and what it puts in the composer.
    public struct Starter: Equatable, Sendable {
        public let label: ChatCopyKey
        public let text: ChatCopyKey
    }

    /// The exported starters, in desktop order (`chat-copy.ts` `starters`).
    public static let starters: [Starter] = [
        Starter(label: .starter0Label, text: .starter0Text),
        Starter(label: .starter1Label, text: .starter1Text),
        Starter(label: .starter2Label, text: .starter2Text),
    ]
}
