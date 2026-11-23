import Foundation

/// One assistant's card, as the phone draws it: the same rows for every
/// assistant, the primary included. The primary is not a different card; its
/// differences are the face the roster gives it (`isPrimary`) and that it is
/// never retired. Every other assistant ends with desktop's "Delete {name}…"
/// row where the host can reach the retire route (AS-4, plan D3).
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
    /// Desktop's "Delete {name}…" (`assistant-card.tsx:445-461`): last, and
    /// only for a non-primary assistant (`AssistantRetirePolicy`).
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
    /// The host can reach the platform's retire route.
    public var canRetire: Bool

    public init(canMessage: Bool, persona: AssistantPersona.Kind, hasHome: Bool,
                hasModel: Bool, hasPet: Bool, hasSkills: Bool, hasRoutines: Bool,
                canRetire: Bool = false) {
        self.canMessage = canMessage
        self.persona = persona
        self.hasHome = hasHome
        self.hasModel = hasModel
        self.hasPet = hasPet
        self.hasSkills = hasSkills
        self.hasRoutines = hasRoutines
        self.canRetire = canRetire
    }
}

public enum AssistantCardLayout {
    /// Desktop's Pet row exists only where there is a Store to choose a pet
    /// in (`assistant-card.tsx:737-752`, `store = Boolean(snapshot.apps)`).
    public static func showsPet(storeAvailable: Bool) -> Bool { storeAvailable }

    /// Desktop's Skills row exists only when the assistant has skills
    /// (`assistant-card.tsx:754-758`, `SkillsRow` returns null at zero).
    public static func showsSkills(count: Int) -> Bool { count > 0 }

    /// The card's row order. `role` decides one thing only: the primary never
    /// gets the retire row. Every other row is the same for both roles.
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
            // Desktop `PersonaFields`: a hand-written persona uses the same
            // two fields, its text (less `Who you are`) and the personality.
            rows.append(.instructions)
            rows.append(.personality)
        }
        if capabilities.hasHome { rows.append(.home) }
        if capabilities.hasModel { rows.append(.model) }
        if capabilities.hasPet { rows.append(.pet) }
        if capabilities.hasSkills { rows.append(.skills) }
        if capabilities.hasRoutines { rows.append(.routines) }
        if AssistantRetirePolicy.offersDelete(isPrimary: role == .primary,
                                              canRetire: capabilities.canRetire) {
            rows.append(.retire)
        }
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

    /// The platform confirmed `latest` for the save that sent `submitted`.
    /// The baseline always advances (even while the field is being typed
    /// in), so a later save is not mistaken for another device's edit. The
    /// draft takes `latest` only if the person has not typed past what was
    /// sent; a newer draft is kept for the next write.
    public mutating func settle(_ latest: String, submitted: String) {
        saved = latest
        if normalized(draft) == normalized(submitted) { draft = latest }
    }

    /// The person typed past `submitted` after that save was sent.
    public func hasNewerDraft(than submitted: String) -> Bool {
        normalized(draft) != normalized(submitted)
    }

    /// An explicit Retry over another device's change: the latest value
    /// becomes the baseline, so the draft is written over it.
    public mutating func rebase(_ latest: String) {
        saved = latest
    }

    /// Esc / Cancel / an external change not being edited.
    public mutating func revert() {
        draft = saved
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The card's one note band, with each failure tied to the field that
/// failed. A save of another field never clears it; only retrying,
/// resolving or discarding that field's edit does. The band shows the
/// latest failure (and Retry targets that field); with none, the latest
/// outcome (Saved, or a conflict line that offers no Retry).
public struct AssistantCardSaveBand<Field: Hashable & Sendable, Note: Equatable & Sendable>: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public let field: Field
        public let note: Note
        /// Saves of this field wait for an explicit Retry (a newer draft
        /// met another device's change to the same field).
        public let held: Bool
    }

    public private(set) var failures: [Failure] = []
    private var outcome: Note?

    public init() {}

    public var note: Note? { failures.last?.note ?? outcome }
    public var retryField: Field? { failures.last?.field }

    /// A save of `field` starts: its own failure (if any) is being retried.
    public mutating func begin(_ field: Field) {
        failures.removeAll { $0.field == field }
        outcome = nil
    }

    /// `field` settled without needing Retry (saved, nothing to write, or
    /// changed elsewhere). Another field's failure stays in front.
    public mutating func settled(_ field: Field, note: Note?) {
        failures.removeAll { $0.field == field }
        outcome = note
    }

    public mutating func failed(_ field: Field, note: Note, held: Bool = false) {
        failures.removeAll { $0.field == field }
        failures.append(Failure(field: field, note: note, held: held))
        outcome = nil
    }

    /// Automatic saves (leaving the field, a queued save) skip this field
    /// until the person presses Retry or discards the draft.
    public func isHeld(_ field: Field) -> Bool {
        failures.contains { $0.field == field && $0.held }
    }

    /// The person discarded `field`'s edit: nothing is left to retry there.
    public mutating func discard(_ field: Field) {
        failures.removeAll { $0.field == field }
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
