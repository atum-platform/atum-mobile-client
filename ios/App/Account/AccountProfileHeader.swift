import AtumChat
import AtumDesign
import AtumNativeAPI
import PhotosUI
import SwiftUI
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
/// "changing names and avatar here should happen inline - like desktop").
/// Tapping the photo picks a new one (or removes it); tapping the name edits it
/// in place and saves on Return, when the field loses focus, or when the screen
/// goes away. The public handle stays read-only. Writes go through
/// `AccountActions`, which use the SDK's own-profile calls; this view never
/// talks to the network itself, and what is written when is decided by
/// `AccountProfileEditor`.
struct AccountProfileHeader: View {
    let design: LiveDesign
    let presentation: AccountPresentation
    let actions: AccountActions
    var identifierPrefix = "account.profile"
    /// What the header sits on, so the photo badge's ring reads as a cut-out.
    var background: AtumColorRole = .ground
    /// Account's own page lists the handle as its own row instead.
    var showsHandle = true
    /// Off for the Settings profile card, which opens Account, where the
    /// name and photo are edited.
    var editable = true
    var avatarSize: CGFloat = 64

    @Environment(\.colorScheme) private var scheme
    @FocusState private var nameFocused: Bool
    @State private var editor = AccountProfileEditor()
    @State private var photoItem: PhotosPickerItem?
    @State private var art: AtumAvatarArt?
    /// The photo chosen here, shown until the saved avatar's thumbnail lands.
    @State private var pendingArt: AtumAvatarArt?

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private var editsName: Bool { editable && actions.saveProfileName != nil }
    private var editsPhoto: Bool { editable && actions.saveProfilePhoto != nil }
    private var hasPhoto: Bool { presentation.avatarURL != nil }
    /// The name the profile holds; empty when there is none (or only the
    /// Matrix ID standing in for one), so the field shows its placeholder
    /// instead of pretending an ID is a name.
    private var savedName: String { presentation.profileName ?? "" }
    /// Desktop's word for someone with no name and no handle ("Atum user").
    private var unnamed: String { design.text("src.matrix.conversation-copy.copies.unnamed") }
    private var shownName: String { presentation.name(unnamed: unnamed) }
    /// The directory @handle under the name. Editing the name shows it while
    /// one is known, since the field may then be empty; otherwise only when it
    /// adds something to the name. Never the Matrix ID.
    private var handleLine: String? {
        guard showsHandle else { return nil }
        return editsName ? presentation.publicHandle : presentation.handleLine(unnamed: unnamed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            identity
            if let status {
                Text(status.text)
                    .font(.footnote)
                    .foregroundStyle(atum.color(status.isError ? .danger : .soft, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifierPrefix + ".status")
            }
        }
        .onAppear { editor.seed(savedName, isEditing: nameFocused) }
        .onChange(of: savedName) { _, name in editor.seed(name, isEditing: nameFocused) }
        .onChange(of: nameFocused) { _, focused in
            if !focused { Task { await commitName(.focusLost) } }
        }
        // Back, Close or a pushed page can end the edit without the field ever
        // losing focus. Committing is idempotent, so this never writes twice.
        .onDisappear { Task { await commitName(.disappear) } }
        .onChange(of: status) { _, status in
            // Errors are said aloud: they appear below a field VoiceOver is not on.
            if let status, status.isError {
                AccessibilityNotification.Announcement(status.text).post()
            }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await choosePhoto(item) }
        }
        .task(id: ThumbnailRequest(uri: presentation.avatarURL, size: avatarSize)) {
            await loadThumbnail()
        }
    }

    /// Photo, name and handle. Read-only, the block is one heading with a
    /// combined label; editable, the name field is the heading and the photo
    /// and the handle stay their own elements.
    @ViewBuilder private var identity: some View {
        let row = HStack(spacing: 14) {
            avatarControl
            VStack(alignment: .leading, spacing: 3) {
                nameControl
                if let handleLine {
                    Text(verbatim: handleLine)
                        .font(.subheadline)
                        .foregroundStyle(editable ? atum.color(.soft, scheme: scheme)
                                                  : atum.kitColor(.ink3, scheme: scheme))
                        .accessibilityIdentifier(identifierPrefix + ".handle")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: editable ? 72 : avatarSize + 8)
        if editsName || editsPhoto {
            row
        } else {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([shownName, handleLine]
                    .compactMap { $0 }.joined(separator: ", "))
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: Photo

    @ViewBuilder private var avatarControl: some View {
        let avatar = avatarImage
        if !editsPhoto {
            avatar
                .accessibilityHidden(true)
        } else if hasPhoto || pendingArt != nil {
            Menu {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label(copy("desktop.atum.account.changePhoto"), image: atum.symbol(.photo))
                }
                Button(role: .destructive) {
                    Task { await savePhoto(nil) }
                } label: {
                    Label(copy("desktop.atum.account.removePhoto"), image: atum.symbol(.trash))
                }
            } label: {
                avatar
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .disabled(editor.photoStatus == .uploading)
            .accessibilityLabel(copy("desktop.atum.account.changePhoto"))
            .accessibilityIdentifier(identifierPrefix + ".photo")
        } else {
            PhotosPicker(selection: $photoItem, matching: .images) {
                avatar
            }
            // In a List row a default-style button claims the whole row, so a
            // tap on the name would open the picker.
            .buttonStyle(.borderless)
            .disabled(editor.photoStatus == .uploading)
            .accessibilityLabel(copy("desktop.atum.account.changePhoto"))
            .accessibilityIdentifier(identifierPrefix + ".photo")
        }
    }

    private var avatarImage: some View {
        AtumAvatar(kind: .person, name: shownName, art: pendingArt ?? art,
                   size: avatarSize)
            .opacity(editor.photoStatus == .uploading ? 0.5 : 1)
            .overlay {
                if editor.photoStatus == .uploading {
                    ProgressView().tint(atum.color(.ink, scheme: scheme))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if editsPhoto, editor.photoStatus != .uploading {
                    Image(atum.symbol(.photo))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .frame(width: 24, height: 24)
                        .background(atum.color(.cell, scheme: scheme), in: Circle())
                        .overlay(Circle().stroke(atum.color(background, scheme: scheme), lineWidth: 2))
                        .offset(x: 4, y: 4)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
    }

    /// The phone re-encodes whatever the library hands over, so there is no
    /// format to get wrong: a photo that cannot be opened is said to be
    /// unreadable, and only a photo still over 2 MB after shrinking is too large.
    private func choosePhoto(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        editor.photoChoiceStarted()
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            editor.photoUnreadable()
            return
        }
        let prepared: AgentAvatarImage
        do {
            prepared = try AssistantAvatarPhoto.prepare(data)
        } catch AssistantAvatarPhoto.Failure.tooLarge {
            editor.photoTooLarge()
            return
        } catch {
            editor.photoUnreadable()
            return
        }
        guard let bytes = Data(base64Encoded: prepared.base64) else {
            editor.photoUnreadable()
            return
        }
        await savePhoto(AccountProfilePhoto(mimeType: prepared.type.rawValue, data: bytes))
    }

    private func savePhoto(_ photo: AccountProfilePhoto?) async {
        guard let save = actions.saveProfilePhoto,
              await editor.savePhoto(photo, save: save) == .saved else { return }
        if let photo {
            pendingArt = await AtumAvatarArt.load(
                data: photo.data, pixelSide: AtumAvatar.thumbnailPixelSide(for: avatarSize))
        } else {
            pendingArt = nil
            art = nil
        }
    }

    private struct ThumbnailRequest: Equatable {
        let uri: String?
        let size: CGFloat
    }

    private func loadThumbnail() async {
        guard let uri = presentation.avatarURL, let load = actions.loadAvatarThumbnail else {
            art = nil
            return
        }
        let side = AtumAvatar.thumbnailPixelSide(for: avatarSize)
        guard let data = await load(uri, side), !Task.isCancelled,
              let loaded = await AtumAvatarArt.load(data: data, pixelSide: side),
              !Task.isCancelled else { return }
        art = loaded
        pendingArt = nil
    }

    // MARK: Name

    @ViewBuilder private var nameControl: some View {
        if editsName {
            HStack(spacing: 6) {
                TextField(copy("src.matrix.profile-copy.copies.displayName"),
                          text: Binding(get: { editor.draft }, set: { editor.edit($0) }),
                          axis: .vertical)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44)
                    .lineLimit(1...3)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($nameFocused)
                    .disabled(editor.nameStatus == .saving)
                    .onSubmit { Task { await commitName(.submit) } }
                    .accessibilityLabel(copy("src.matrix.profile-copy.copies.displayName"))
                    .accessibilityHint(copy("src.matrix.profile-copy.copies.displayNameHint"))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(identifierPrefix + ".name")
                if editor.nameStatus == .saving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else if !nameFocused {
                    Image(atum.symbol(.pencil))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                        .accessibilityHidden(true)
                        .onTapGesture { nameFocused = true }
                }
            }
        } else {
            Text(verbatim: shownName)
                .font(editable ? .headline : .body.weight(.semibold))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .lineLimit(3)
        }
    }

    /// Writes (or declines to write) what the field holds. After Return, a name
    /// that cannot be saved keeps the keyboard up so it can be fixed.
    private func commitName(_ trigger: AccountProfileEditor.Trigger) async {
        guard let save = actions.saveProfileName else { return }
        let outcome = await editor.commit(trigger, save: save)
        if trigger == .submit, outcome == .required || outcome == .rejected {
            nameFocused = true
        }
    }

    // MARK: Status

    private struct Status: Equatable {
        let text: String
        let isError: Bool
    }

    private var status: Status? {
        switch editor.nameStatus {
        case .required:
            return Status(text: AccountSettingsCopy.text(.nameRequired, design: design), isError: true)
        case .rejected, .failed:
            // A name outside the rule gets the same words the desktop uses for
            // a name that could not be saved.
            return Status(text: copy("src.matrix.profile-copy.copies.nameFailed"), isError: true)
        case .idle, .saving:
            break
        }
        switch editor.photoStatus {
        case .uploading:
            return Status(text: copy("desktop.atum.account.photoUploading"), isError: false)
        case .unreadable:
            return Status(text: copy("src.matrix.assistant-card.copy.assistantCardCopies.photoError"),
                          isError: true)
        case .tooLarge:
            return Status(text: copy("desktop.atum.account.photoTooLarge"), isError: true)
        case .failed:
            return Status(text: copy("desktop.atum.account.photoFailed"), isError: true)
        case .idle:
            return nil
        }
    }

    private func copy(_ key: String) -> String {
        design.text(key)
    }
}
