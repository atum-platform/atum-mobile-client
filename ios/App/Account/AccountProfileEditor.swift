import Foundation
import Observation

/// What the inline profile editing decides, apart from drawing it. The header
/// view owns focus, the photo picker and the picture; whether a name or a photo
/// is written, and what the person is told, lives here so it can be tested.
///
/// The rules, in short:
/// - A name nobody changed is never written, however the server spells it (it
///   may be longer than the rule below allows).
/// - A name outside the desktop's rule is refused with the existing error and
///   never cut down to fit.
/// - Return on an empty name asks for one; leaving the field empty restores the
///   saved name.
/// - A failed write keeps what was typed and says so.
/// - Committing is idempotent: Return, the field losing focus and the screen
///   going away may all commit the same edit, and it is written at most once.
@MainActor
@Observable
final class AccountProfileEditor {
    enum NameStatus: Equatable {
        case idle
        case saving
        /// Return on an empty name: "Enter a name."
        case required
        /// The name as typed cannot be saved (over the limit, or a control
        /// character). Nothing was written; the draft stays so it can be fixed.
        case rejected
        /// The server or the network refused the write. The draft stays.
        case failed
    }

    enum PhotoStatus: Equatable {
        case idle
        case uploading
        /// The chosen photo could not be read or opened as an image.
        case unreadable
        /// Still over 2 MB after the phone shrank it.
        case tooLarge
        /// The write did not go through.
        case failed
    }

    /// What ended the edit.
    enum Trigger: Equatable {
        /// Return on the keyboard.
        case submit
        /// The field lost focus.
        case focusLost
        /// The header went away (Back, Close, a pushed page).
        case disappear
    }

    enum Outcome: Equatable {
        /// Nothing to write: the field holds the saved name.
        case unchanged
        case saved
        case failed
        /// Not written. After Return the keyboard should stay up so the name
        /// can be fixed.
        case required
        case rejected
        /// A write is already in flight.
        case busy
    }

    /// What the field shows.
    private(set) var draft: String
    /// The name the profile holds.
    private(set) var savedName: String
    private(set) var nameStatus = NameStatus.idle
    private(set) var photoStatus = PhotoStatus.idle

    init(savedName: String = "") {
        self.savedName = savedName
        draft = savedName
    }

    // MARK: Name

    /// The profile's saved name arrived (the header appeared, or the name
    /// changed under it). It becomes the field's text unless the person is in
    /// the middle of typing or a write is in flight.
    func seed(_ name: String, isEditing: Bool) {
        savedName = name
        guard !isEditing, nameStatus != .saving else { return }
        draft = name
        nameStatus = .idle
    }

    /// The person typed. Typing clears whatever the last attempt said.
    func edit(_ text: String) {
        guard nameStatus != .saving, text != draft else { return }
        draft = text
        nameStatus = .idle
    }

    func commit(_ trigger: Trigger,
                save: @MainActor (String) async -> AccountProfileSaveResult) async -> Outcome {
        guard nameStatus != .saving else { return .busy }

        // The field still holds exactly what the profile holds. Never write it.
        if draft == savedName {
            if draft.isEmpty, trigger == .submit {
                nameStatus = .required
                return .required
            }
            // The blur that follows Return keeps "Enter a name." on screen.
            if nameStatus != .required { nameStatus = .idle }
            return .unchanged
        }

        switch AccountProfileName.validate(draft) {
        case .empty:
            if trigger != .submit, nameStatus != .required {
                // Cleared, then left: the saved name comes back.
                draft = savedName
                nameStatus = .idle
                return .unchanged
            }
            nameStatus = .required
            return .required
        case .invalid:
            nameStatus = .rejected
            return .rejected
        case let .valid(name):
            draft = name
            if name == savedName {
                nameStatus = .idle
                return .unchanged
            }
            nameStatus = .saving
            switch await save(name) {
            case .saved:
                savedName = name
                nameStatus = .idle
                return .saved
            case .failed:
                nameStatus = .failed
                return .failed
            }
        }
    }

    // MARK: Photo

    /// A new photo choice starts clean.
    func photoChoiceStarted() {
        if photoStatus != .uploading { photoStatus = .idle }
    }

    func photoUnreadable() { photoStatus = .unreadable }

    func photoTooLarge() { photoStatus = .tooLarge }

    /// Writes a photo, or removes it with nil. Nil result: a write was already
    /// in flight, so nothing was started.
    func savePhoto(_ photo: AccountProfilePhoto?,
                   save: @MainActor (AccountProfilePhoto?) async -> AccountProfileSaveResult)
        async -> AccountProfileSaveResult? {
        guard photoStatus != .uploading else { return nil }
        photoStatus = .uploading
        let result = await save(photo)
        photoStatus = result == .saved ? .idle : .failed
        return result
    }
}
