import Foundation

/// The stop-gap account deletion request, as the desktop makes it today
/// (`src/matrix/legal-settings.tsx` `MatrixDeleteAccount`): an email to
/// Atum's privacy mailbox, its subject and body in the person's language and
/// their Atum ID on its own line, handled by hand within 30 days (the Privacy
/// Policy). The native flow (`AccountDeletion.swift`,
/// `atum.account-deletion/1`) replaces it once the platform deploys it.
public struct AccountDeletionEmailRequest: Equatable, Sendable {
    /// Desktop `shared/atum-company.ts` `ATUM_MAILBOXES.privacy`: the only
    /// address this request is ever drafted to.
    public static let privacyMailbox = "privacy@atumplatform.com"

    public let recipient: String
    public let subject: String
    public let body: String

    /// `idLabel` is the exported word for the ID (`src.matrix.copy.copies.userId`,
    /// "Atum ID"); a missing or empty `accountID` leaves the line out, as on
    /// the desktop.
    public init(subject: String, body: String, idLabel: String, accountID: String?) {
        recipient = Self.privacyMailbox
        self.subject = subject
        if let accountID, !accountID.isEmpty {
            self.body = body + "\n\n" + idLabel + ": " + accountID
        } else {
            self.body = body
        }
    }

    /// The same draft as a `mailto:` link, for when no Mail account is set up:
    /// the address, the subject and the body, nothing else. A space is `%20`,
    /// never `+`, for every mail app (desktop `atumMailLink`).
    public var mailtoURL: URL? {
        URL(string: "mailto:" + recipient + "?subject=" + Self.encode(subject) + "&body=" + Self.encode(body))
    }

    /// JavaScript's `encodeURIComponent`: everything but the unreserved marks.
    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
