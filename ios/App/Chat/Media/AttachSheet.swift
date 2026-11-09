import AtumChat
import PhotosUI
import SwiftUI

/// FlowPhone3 › Attach: one glass half sheet, recent photos first.
///
/// - A one-row strip of the latest photos: the system's compact photo picker,
///   so it needs no photo-library permission. A tap attaches that photo and
///   closes the sheet.
/// - Under it, 60 pt `surface` circles with `shadow-1`, a light glyph and a
///   `.footnote` label: Photos (the full picker) and Files (the file
///   importer), plus an app's own composer action when the chat has one.
///   The board's Drive and Website destinations need phone flows that do not
///   exist yet (spec F8), so they are not drawn.
/// - When attachments are closed for this chat, its reason replaces both.
struct AttachSheet: View {
    let design: LiveDesign
    let appAction: (label: String, run: () -> Void)?
    let closedReason: String?
    /// App-bot chats take no files; their sheet holds the app's action only.
    let offersFiles: Bool
    let isFull: Bool
    let photo: (PhotosPickerItem) -> Void
    let openPhotos: () -> Void
    let openFiles: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var pick: PhotosPickerItem?

    private var kit: AtumKit { design.kit }

    var body: some View {
        VStack(spacing: 18) {
            if let closedReason {
                Text(verbatim: closedReason)
                    .font(.subheadline)
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("chat.attachments.closed")
            } else if offersFiles {
                PhotosPicker(selection: $pick, matching: .images, preferredItemEncoding: .compatible) {
                    EmptyView()
                }
                .photosPickerStyle(.compact)
                .photosPickerDisabledCapabilities([.selectionActions, .collectionNavigation, .search])
                .photosPickerAccessoryVisibility(.hidden, edges: .all)
                .frame(height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .disabled(isFull)
                .accessibilityIdentifier("chat.attach.recent")
            }
            HStack(alignment: .top, spacing: 24) {
                if closedReason == nil && offersFiles {
                    destination(.photo, ChatCopy.text(design, ChatCopy.Key.photo),
                                id: "chat.attach.photos") { openPhotos() }
                    destination(.folder, design.text("desktop.atum.workspace.launcherFiles"),
                                id: "chat.attach.files") { openFiles() }
                }
                if let appAction {
                    destination(.sparkles, appAction.label, id: "chat.attach.app") { appAction.run() }
                }
            }
            .disabled(isFull && appAction == nil)
        }
        .padding(.top, 22)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .onChange(of: pick) { _, item in
            guard let item else { return }
            pick = nil
            dismiss()
            photo(item)
        }
        .presentationDetents([.height(closedReason == nil && offersFiles ? 236 : 170)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(44)
    }

    private func destination(_ glyph: AtumGlyph, _ label: String, id: String,
                             action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            // The picker or importer can only present once this sheet is gone.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                action()
            }
        } label: {
            VStack(spacing: 6) {
                Image(design.symbol(glyph.rawValue))
                    .font(.system(size: 22))
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                    .frame(width: 60, height: 60)
                    .background(kit.color(.surface, scheme: scheme), in: Circle())
                    .atumKitElevation(.one, in: Circle())
                Text(verbatim: label)
                    .font(.footnote)
                    .foregroundStyle(kit.color(.ink2, scheme: scheme))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(minWidth: 64)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}
