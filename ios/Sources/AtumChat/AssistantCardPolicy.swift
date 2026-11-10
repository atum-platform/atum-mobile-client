import Foundation

/// One assistant's card, as the phone draws it: the same rows for every
/// assistant, the primary included. The primary is not a different card; its
/// only difference is the face the roster gives it (`isPrimary`), and it never
/// offers retirement on the phone.
public enum AssistantCardRow: String, CaseIterable, Hashable, Sendable {
    case photo
    case name
    case message
    case handle
    case purpose
    case personality
    case instructions
    case home
    case model
    case pet
    case skills
    case routines
    /// Kept in the vocabulary so "no retire for the primary" is an explicit
    /// decision, not an omission. The phone never draws it for either role.
    case retire
}

public enum AssistantCardRole: String, Sendable {
    case primary
    case other
}

public struct AssistantCardCapabilities: Equatable, Sendable {
    public var canMessage: Bool
    public var persona: AssistantPersona.Kind
    public var hasHome: Bool
    public var hasModel: Bool
    public var hasPet: Bool
    public var hasSkills: Bool
    public var hasRoutines: Bool

    public init(canMessage: Bool, persona: AssistantPersona.Kind, hasHome: Bool,
                hasModel: Bool, hasPet: Bool, hasSkills: Bool, hasRoutines: Bool) {
        self.canMessage = canMessage
        self.persona = persona
        self.hasHome = hasHome
        self.hasModel = hasModel
        self.hasPet = hasPet
        self.hasSkills = hasSkills
        self.hasRoutines = hasRoutines
    }
}

public enum AssistantCardLayout {
    /// Desktop's Pet row exists only where there is a Store to choose a pet
    /// in (`assistant-card.tsx:737-752`, `store = Boolean(snapshot.apps)`).
    public static func showsPet(storeAvailable: Bool) -> Bool { storeAvailable }

    /// Desktop's Skills row exists only when the assistant has skills
    /// (`assistant-card.tsx:754-758`, `SkillsRow` returns null at zero).
    public static func showsSkills(count: Int) -> Bool { count > 0 }

    /// The card's row order. `role` is deliberately not a branch: the primary
    /// shows the same rows as every other assistant, and neither has a retire
    /// row on the phone. Callers pass it so that parity is part of the API and
    /// of the test, not a comment.
    public static func rows(for role: AssistantCardRole,
                            capabilities: AssistantCardCapabilities) -> [AssistantCardRow] {
        var rows: [AssistantCardRow] = [.photo, .name]
        if capabilities.canMessage { rows.append(.message) }
        rows.append(.handle)
        switch capabilities.persona {
        case .template, .primary:
            rows.append(.purpose)
            rows.append(.personality)
        case .custom:
            rows.append(.instructions)
        }
        if capabilities.hasHome { rows.append(.home) }
        if capabilities.hasModel { rows.append(.model) }
        if capabilities.hasPet { rows.append(.pet) }
        if capabilities.hasSkills { rows.append(.skills) }
        if capabilities.hasRoutines { rows.append(.routines) }
        return rows
    }
}

/// One text field's in-place edit: the value it was opened with, the draft a
/// person is typing, and the one rule that decides whether leaving saves.
/// Saving accepts the value only after the platform confirms it; a refusal or
/// a conflict keeps the draft and its saved value, so a retry sends the same
/// words and a revert always goes back to what the platform last returned.
public struct AssistantCardEdit: Equatable, Sendable {
    public enum Requirement: Equatable, Sendable {
        case nonEmpty
        case mayBeEmpty
    }

    public let requirement: Requirement
    public private(set) var saved: String
    public var draft: String

    public init(saved: String, requirement: Requirement = .mayBeEmpty) {
        self.requirement = requirement
        self.saved = saved
        self.draft = saved
    }

    public var isDirty: Bool {
        normalized(draft) != normalized(saved)
    }

    /// What leaving the field saves, or nil when there is nothing to write.
    /// A name may not be emptied; persona fields may be cleared on purpose.
    public func pendingSave() -> String? {
        let value = normalized(draft)
        guard isDirty else { return nil }
        guard requirement == .mayBeEmpty || !value.isEmpty else { return nil }
        return value
    }

    /// The platform's answer becomes the new saved value and the draft.
    public mutating func accept(_ value: String) {
        saved = value
        draft = value
    }

    /// Esc / Cancel / an external change not being edited.
    public mutating func revert() {
        draft = saved
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Where the card is opened from. Both entries land on the same card; the
/// chat's info sheet draws it in place and Settings pushes it. There is no
/// separate "Edit assistant" destination.
public enum AssistantCardEntry: String, Sendable {
    case chatInfo
    case settingsRoster
}

public enum AssistantCardPlacement: Equatable, Sendable {
    case inlineCard
    case pushedCard
}

public enum AssistantCardNavigation {
    public static func placement(for entry: AssistantCardEntry) -> AssistantCardPlacement {
        switch entry {
        case .chatInfo: .inlineCard
        case .settingsRoster: .pushedCard
        }
    }

    /// The one screen is the card itself. Kept as a named answer so a later
    /// entry point cannot quietly grow an "edit" step again.
    public static func opensSeparateEditScreen(for entry: AssistantCardEntry) -> Bool {
        switch entry {
        case .chatInfo, .settingsRoster: false
        }
    }
}
