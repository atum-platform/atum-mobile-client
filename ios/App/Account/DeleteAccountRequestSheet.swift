import AtumDesign
import AtumNativeAPI
import MessageUI
import SwiftUI

/// Settings › Account › Delete account…, as the desktop asks today
/// (`src/matrix/legal-settings.tsx` `MatrixDeleteAccount`): one question, then
/// a draft to Atum's privacy mailbox with the subject, the body and the
/// person's Atum ID filled in. Mail's own composer when a Mail account is set
/// up, else the `mailto:` link for whichever mail app the person uses; if
/// neither opens, the sheet says where to write instead. Deletion itself is
/// done by hand within 30 days. The native flow (`AccountDeletion.swift`)
/// replaces this once `atum.account-deletion/1` is deployed (plan AC-2b).
struct DeleteAccountRequestSheet: View {
    let design: LiveDesign
    /// The Matrix user ID, carried in the email as the Atum ID (never shown here).
    let accountID: String
    let onDone: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var composing = false
    @State private var failed = false

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.body)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
            if failed {
                AtumNotice(glyph: .mail, title: copy("src.matrix.legal-copy.copy.deleteAccountFailed"),
                           tone: .warning) { EmptyView() }
                    .accessibilityIdentifier("account.delete-account.failed")
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                Button(copy("src.matrix.chat-copy.copies.cancel"), action: onDone)
                    .buttonStyle(.atumSecondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("account.delete-account.cancel")
                Button(confirmLabel, role: .destructive, action: request)
                    .buttonStyle(.atumDestructive)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("account.delete-account.confirm")
            }
        }
        .padding(20)
        .padding(.top, 8)
        .atumDesign(design)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $composing) {
            DeleteAccountMailComposer(draft: draft) { result in
                composing = false
                switch result {
                case .sent, .saved: onDone()
                case .failed: failed = true
                case .cancelled: break
                @unknown default: break
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: failed) { _, failed in
            if failed {
                AccessibilityNotification.Announcement(copy("src.matrix.legal-copy.copy.deleteAccountFailed")).post()
            }
        }
        .accessibilityIdentifier("account.delete-account.sheet")
    }

    /// The email, in the person's language, as the desktop words it.
    private var draft: AccountDeletionEmailRequest {
        AccountDeletionEmailRequest(subject: copy("src.matrix.legal-copy.copy.deleteAccountSubject"),
                                    body: copy("src.matrix.legal-copy.copy.deleteAccountBody"),
                                    idLabel: copy("src.matrix.copy.copies.userId"),
                                    accountID: accountID)
    }

    private func request() {
        failed = false
        if MFMailComposeViewController.canSendMail() {
            composing = true
            return
        }
        guard let url = draft.mailtoURL else { failed = true; return }
        openURL(url) { accepted in
            if accepted { onDone() } else { failed = true }
        }
    }

    // The desktop dialog's own keys are not in the pinned export yet. Each
    // reads its key once the export carries it, and until then the closest
    // exported wording.

    // PENDING-COPY:src.matrix.legal-copy.copy.deleteAccountDialogTitle
    private var title: String {
        pending("src.matrix.legal-copy.copy.deleteAccountDialogTitle",
                else: "src.matrix.mobile-copy.mobilePhoneCopy.deletionTitle")
    }

    // PENDING-COPY:src.matrix.legal-copy.copy.deleteAccountDialogBody
    private var message: String {
        pending("src.matrix.legal-copy.copy.deleteAccountDialogBody",
                else: "src.matrix.legal-copy.copy.deleteAccountTip")
    }

    // PENDING-COPY:src.matrix.legal-copy.copy.deleteAccountConfirm
    private var confirmLabel: String {
        pending("src.matrix.legal-copy.copy.deleteAccountConfirm",
                else: "src.matrix.legal-copy.copy.deleteAccountAction")
    }

    private func pending(_ key: String, else fallback: String) -> String {
        copy(design.copy.contains(key) ? key : fallback)
    }

    private func copy(_ key: String) -> String { design.text(key) }
}

/// Mail's composer with the deletion request filled in. The person can still
/// edit it or not send it; nothing is sent on their behalf.
private struct DeleteAccountMailComposer: UIViewControllerRepresentable {
    let draft: AccountDeletionEmailRequest
    let onFinish: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([draft.recipient])
        composer.setSubject(draft.subject)
        composer.setMessageBody(draft.body, isHTML: false)
        return composer
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult) -> Void
        init(onFinish: @escaping (MFMailComposeResult) -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: (any Error)?) {
            onFinish(result)
        }
    }
}
