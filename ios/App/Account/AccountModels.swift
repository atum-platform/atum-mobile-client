import Foundation

enum AccountNotificationState: Equatable, Sendable {
    case unknown
    case notDetermined
    case on
    case off
}

enum RecoveryKeyLoadResult: Sendable {
    case value(String)
    case unavailable
}

enum RecoveryRestoreResult: Equatable, Sendable {
    case restored
    case rejected
    case failed
}

/// One assistant in Settings > Assistants, taken from the same roster rows Home
/// draws (so its name and photo are Home's), plus the one-line title it was
/// given and whether its chat has reached this phone.
struct AccountAssistantSummary: Identifiable, Hashable, Sendable {
    let roomID: String
    let name: String
    let title: String?
    /// The photo Home draws: the assistant's Matrix avatar (`mxc://`), else a
    /// hosted HTTPS photo with its checksum. Both nil shows the monogram.
    var matrixAvatarURL: String? = nil
    var avatarURL: URL? = nil
    var avatarSHA256: String? = nil
    /// Atum's own default assistant, drawn with the eclipse face as on Home.
    var isAtum = false
    /// The account's default assistant from the roster metadata. The card is
    /// the same one as every other assistant's; the flag only selects its face
    /// and the name privileges.
    var isPrimary = false
    /// The platform's assistant slug when the roster carries one, for the
    /// card's bot-handle line.
    var botHandle: String? = nil
    /// False while the assistant's chat has not reached this phone yet: it is
    /// listed as being prepared, and there is no card to open.
    var isReady = true

    var id: String { roomID }
}

/// How this phone is connected, as This iPhone says it: the same story the
/// desktop tells on its This Mac page (connected, offline, not connected).
enum AccountConnectionState: Equatable, Sendable {
    case connecting
    case ready
    case offline
    case error
}

/// The outcome of one inline profile write. Validation happens before any
/// write, so a failure here is the server or the network refusing it.
enum AccountProfileSaveResult: Equatable, Sendable {
    case saved
    case failed
}

/// A profile photo already squared and re-encoded for the Matrix media
/// repository (JPEG, at most 2 MiB, no source metadata).
struct AccountProfilePhoto: Equatable, Sendable {
    let mimeType: String
    let data: Data
}

struct AccountPresentation: Equatable {
    let matrixUserID: String
    let displayName: String?
    /// The person's own Matrix avatar (`mxc://`), drawn through the SDK media
    /// cache; nil shows their initial.
    var avatarURL: String?
    var offersHistoryRecovery: Bool
    var holdsRecoveryKey: Bool
    var recoveryKeySavedOnThisPhone: Bool
    var signOutInProgress: Bool
    var signOutFailureToken: UInt64
    let version: String
    var assistants: [AccountAssistantSummary]
    var settingsCapabilities: AccountSettingsCapabilities
    /// The platform names another person as Founder, so the existing Contact
    /// Atum row can open the canonical Founder chat instead of staying inert.
    var founderContactAvailable: Bool
    var founderContactTitle: String
    /// The phone's own connection, for the This iPhone rows.
    var connection: AccountConnectionState

    init(matrixUserID: String,
         displayName: String?,
         offersHistoryRecovery: Bool,
         holdsRecoveryKey: Bool,
         recoveryKeySavedOnThisPhone: Bool,
         signOutInProgress: Bool,
         signOutFailureToken: UInt64,
         version: String,
         assistants: [AccountAssistantSummary] = [],
         settingsCapabilities: AccountSettingsCapabilities = .phone,
         founderContactAvailable: Bool = false,
         founderContactTitle: String = "Contact us",
         avatarURL: String? = nil,
         connection: AccountConnectionState = .ready) {
        self.matrixUserID = matrixUserID
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.offersHistoryRecovery = offersHistoryRecovery
        self.holdsRecoveryKey = holdsRecoveryKey
        self.recoveryKeySavedOnThisPhone = recoveryKeySavedOnThisPhone
        self.signOutInProgress = signOutInProgress
        self.signOutFailureToken = signOutFailureToken
        self.version = version
        self.assistants = assistants
        self.settingsCapabilities = settingsCapabilities
        self.founderContactAvailable = founderContactAvailable
        self.founderContactTitle = founderContactTitle
        self.connection = connection
    }

    var localHandle: String {
        let first = matrixUserID.split(separator: ":", maxSplits: 1).first.map(String.init) ?? matrixUserID
        return first.hasPrefix("@") ? first : "@" + first
    }

    var name: String {
        let value = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? localHandle : value
    }

    var showsHandle: Bool { name != localHandle }
}

struct AccountActions {
    var readNotificationState: @MainActor @Sendable () async -> AccountNotificationState
    var requestNotifications: @MainActor @Sendable () async -> AccountNotificationState
    var openNotificationSettings: @MainActor () -> Void
    var openAppSettings: @MainActor () -> Void
    var loadRecoveryKey: @MainActor @Sendable () async -> RecoveryKeyLoadResult
    var markRecoveryKeySaved: @MainActor () -> Void
    var restoreMessages: @MainActor @Sendable (String) async -> RecoveryRestoreResult
    var signOut: @MainActor @Sendable (_ confirmedRecoverySaved: Bool) async -> Bool
    var openWebPage: @MainActor (URL) -> Void
    /// The person's own Matrix profile (display name and avatar), written with
    /// the SDK's account calls exactly as the desktop's profile editor does.
    /// Nil hides the inline editing affordances; the profile is then read-only.
    var saveProfileName: (@MainActor (String) async -> AccountProfileSaveResult)? = nil
    var saveProfilePhoto: (@MainActor (AccountProfilePhoto?) async -> AccountProfileSaveResult)? = nil
    var loadAvatarThumbnail: (@MainActor (String, Int) async -> Data?)? = nil
    /// Matrix ignore list (`m.ignored_user_list`): Privacy's "Ignored people",
    /// where a person is unignored. Nil hides the row.
    var ignoredPeople: (@MainActor () async -> [IgnoredPerson]?)? = nil
    var setIgnored: (@MainActor (String, Bool) async -> Bool)? = nil
}

/// The desktop's display-name rule (`matrixProfileDisplayName`,
/// `MATRIX_PROFILE_NAME_MAX`), applied before any write: whitespace runs become
/// one space and the ends are trimmed; the result must not be empty, must not
/// exceed 64 characters (Unicode scalars, as the desktop counts) and must not
/// hold control characters. A name outside the rule is refused, never cut down:
/// shortening it would write a name nobody typed.
enum AccountProfileName {
    static let maximumLength = 64

    enum Validation: Equatable {
        case valid(String)
        case empty
        /// Over the limit or holding a control character.
        case invalid
    }

    static func validate(_ value: String) -> Validation {
        let name = value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if name.isEmpty { return .empty }
        if name.unicodeScalars.count > maximumLength
            || name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return .invalid
        }
        return .valid(name)
    }
}
