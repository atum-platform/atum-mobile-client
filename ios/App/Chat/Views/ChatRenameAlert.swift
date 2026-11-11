import AtumChat
import SwiftUI

/// HC-7: Rename, from the Home long-press and the chat's panel (desktop
/// `MatrixRenameChat`, `m/conversation-menu.tsx`). A person chat, or a group
/// you may not name, gets your own private name (`io.atum.title`, "Only you
/// see this name."). A group whose power levels let you name it is renamed
/// for everyone in it (`m.room.name`, never empty).
struct ChatRenameRequest: Identifiable, Equatable {
    let roomID: String
    /// The name the chat goes by now; the field starts from it.
    let current: String
    /// Renames the group for everyone (desktop `shared`).
    let shared: Bool
    var id: String { roomID }
}

struct ChatRenameActions {
    /// What Rename edits for this chat; nil when the chat can't be renamed.
    let request: (String) async -> ChatRenameRequest?
    /// Saves the name; true once the homeserver took it.
    let save: (ChatRenameRequest, String) async -> Bool
}

private struct ChatRenameAlertModifier: ViewModifier {
    @Binding var request: ChatRenameRequest?
    let design: LiveDesign
    let save: (ChatRenameRequest, String) async -> Bool

    @State private var name = ""
    @State private var failed = false
    @State private var saving = false

    private var copy: ChatCopy { ChatCopy(design: design) }

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { request != nil }, set: { if !$0, !saving { request = nil } }),
                   presenting: request) { request in
                TextField(copy.text(.renameLabel), text: $name)
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("chat.rename.field")
                Button(copy.text(.cancel), role: .cancel) { self.request = nil }
                Button(copy.text(.save)) { commit(request) }
                    .disabled(!ChatPrivateTitle.canSave(name, shared: request.shared))
                    .accessibilityIdentifier("chat.rename.save")
            } message: { request in
                // PENDING-COPY: desktop `chat-copy.ts` `renameGroupHelp` (a
                // group named for everyone) is not exported; no line rather
                // than "Only you see this name.", which would be untrue.
                if !request.shared { Text(copy.text(.renameHelp)) }
            }
            .alert(copy.text(.errorGeneric), isPresented: $failed) {
                Button(copy.text(.dismiss), role: .cancel) {}
            }
            .onChange(of: request) { _, request in
                if let request { name = request.current }
            }
    }

    /// PENDING-COPY: desktop `renameGroupTitle` is not exported; a shared
    /// rename reads the menu's own "Rename" until it is.
    private var title: String {
        request?.shared == true ? copy.text(.rename) : copy.text(.renameTitle)
    }

    private func commit(_ request: ChatRenameRequest) {
        let value = name
        saving = true
        Task {
            let saved = await save(request, value)
            saving = false
            self.request = nil
            if !saved { failed = true }
        }
    }
}

extension View {
    /// The Rename alert for `request`, saved through `save`.
    func chatRenameAlert(_ request: Binding<ChatRenameRequest?>, design: LiveDesign,
                         save: @escaping (ChatRenameRequest, String) async -> Bool) -> some View {
        modifier(ChatRenameAlertModifier(request: request, design: design, save: save))
    }
}
