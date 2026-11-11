import AtumDesign
import AtumNativeAPI
import SwiftUI

/// What an official app's card shows (AS-11; desktop
/// `matrix/assistant-card/app-card.tsx` `AppCard`): its face, its name with the
/// verified mark, "An Atum app", the way to open it while it is available, and
/// its catalog description (else its subtitle). Read only.
struct AppCardPresentation: Identifiable, Equatable {
    let rowID: String
    let appID: String
    let name: String
    /// The catalog's `verified`: the check after the name.
    let isVerified: Bool
    let verification: AppVerificationTier?
    /// Desktop shows "Open {app}" only for an available app.
    let isAvailable: Bool
    let about: String?
    let avatar: LiveProductAvatar?
    let matrixAvatarURI: String?
    let avatarSHA256: String?
    let avatarCandidates: [LiveProductRemoteArt]

    var id: String { rowID }

    init(rowID: String, appID: String, name: String, isVerified: Bool,
         verification: AppVerificationTier?, isAvailable: Bool, about: String?,
         avatar: LiveProductAvatar? = nil, matrixAvatarURI: String? = nil,
         avatarSHA256: String? = nil, avatarCandidates: [LiveProductRemoteArt] = []) {
        self.rowID = rowID
        self.appID = appID
        self.name = name
        self.isVerified = isVerified
        self.verification = verification
        self.isAvailable = isAvailable
        self.about = about
        self.avatar = avatar
        self.matrixAvatarURI = matrixAvatarURI
        self.avatarSHA256 = avatarSHA256
        self.avatarCandidates = avatarCandidates
    }

    /// Desktop: `appLocalizedCopy(app.name, locale, app.app)`, and the about is
    /// `description || subtitle`.
    init(app: AppDescriptor, rowID: String, locale: String,
         avatar: LiveProductAvatar? = nil, matrixAvatarURI: String? = nil,
         avatarSHA256: String? = nil, avatarCandidates: [LiveProductRemoteArt] = []) {
        self.init(rowID: rowID, appID: app.appID.rawValue,
                  name: app.name.localized(locale: locale, fallback: app.app),
                  isVerified: app.verified,
                  verification: ChatInfoAppTier.presentation(LiveRosterRows.productVerification(for: app)),
                  isAvailable: app.availability == .available,
                  about: LiveRosterRows.appDescriptionOrSubtitle(app, locale: locale),
                  avatar: avatar, matrixAvatarURI: matrixAvatarURI,
                  avatarSHA256: avatarSHA256, avatarCandidates: avatarCandidates)
    }

    /// The face, drawn by the panel's own avatar (an app squircle).
    var avatarInfo: ChatInfoPresentation {
        ChatInfoPresentation(roomID: rowID, title: name, kind: .app(verification),
                             avatar: avatar, matrixAvatarURI: matrixAvatarURI,
                             avatarSHA256: avatarSHA256, avatarCandidates: avatarCandidates)
    }
}

/// The card's words, all in the pinned export (desktop `assistant-card/copy.ts`).
enum AppCardCopy {
    private static let prefix = "src.matrix.assistant-card.copy.assistantCardCopies."
    static let done = prefix + "done"
    static let appCaption = prefix + "appCaption"
    static let openApp = prefix + "openApp"
    static let verified = prefix + "verified"
    static let menuInfo = prefix + "menuInfo"
}

struct AppCardSheet: View {
    let design: LiveDesign
    let card: AppCardPresentation
    let loadMatrixThumbnail: ((String, Int) async -> Data?)?
    /// Desktop `selectApp`: closes the card and opens the app's chat.
    let open: () -> Void
    let close: () -> Void

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    header
                    if let about = card.about {
                        Text(verbatim: about)
                            .font(.body)
                            .foregroundStyle(atum.color(.soft, scheme: scheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(atum.color(.cell, scheme: scheme),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .padding(.horizontal, 16)
                            .padding(.top, 24)
                            .accessibilityIdentifier("app.card.about")
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 32)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(design.text(AppCardCopy.done), action: close)
                        .accessibilityIdentifier("app.card.done")
                }
            }
        }
        .atumDesign(visual: atum)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("app.card")
    }

    private var header: some View {
        VStack(spacing: 8) {
            ChatInfoAvatar(info: card.avatarInfo, size: 88, loadMatrixThumbnail: loadMatrixThumbnail)
                .accessibilityHidden(true)
            HStack(spacing: 6) {
                Text(verbatim: card.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                if card.isVerified {
                    Image(atum.symbol(.checkCircle))
                        .foregroundStyle(atum.color(.actionStrong, scheme: scheme))
                        .accessibilityLabel(design.text(AppCardCopy.verified))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("app.card.name")
            Text(design.text(AppCardCopy.appCaption))
                .font(.subheadline)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
            if card.isAvailable {
                Button(action: open) {
                    Label(design.text(AppCardCopy.openApp, arguments: [.text(card.name)]),
                          image: atum.symbol(.arrowUpRight))
                }
                .buttonStyle(.atumSecondary)
                .padding(.top, 8)
                .accessibilityIdentifier("app.card.open")
            }
        }
        .padding(.horizontal, 24)
    }
}
