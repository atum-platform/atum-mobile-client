import SwiftUI

/// One person on the Matrix ignore list (`m.ignored_user_list`).
struct IgnoredPerson: Identifiable, Equatable, Sendable {
    let userID: String
    let name: String?
    var id: String { userID }

    /// Their profile name; else the readable part of their address; else the
    /// word for someone unnamed. Never an opaque allocated ID (desktop
    /// `person-name.ts`, ledger AC8).
    func shownName(unnamed: String) -> String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        let local = userID.dropFirst().prefix { $0 != ":" }
        let opaque = local.range(of: #"^(user|agent|app|service|system)-[0-9a-f]{16,}$"#,
                                 options: .regularExpression) != nil
        return opaque || local.isEmpty ? unnamed : "@" + local
    }
}

/// Settings › Account › Privacy › "Người đã ẩn": everyone this account
/// ignores, each with "Bỏ ẩn" (the desktop's moderation words).
struct IgnoredPeopleList: View {
    let design: LiveDesign
    let actions: AccountActions

    @Environment(\.colorScheme) private var scheme
    @State private var people: [IgnoredPerson]?
    @State private var working: String?

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        List {
            Section {
                if let people, people.isEmpty {
                    Text(design.text("src.matrix.moderation-copy.copies.empty"))
                        .foregroundStyle(atum.kitColor(.ink3, scheme: scheme))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("account.ignored.empty")
                } else if let people {
                    ForEach(people) { person in
                        let name = person.shownName(
                            unnamed: design.text("src.matrix.conversation-copy.copies.unnamed"))
                        HStack(spacing: 12) {
                            AtumAvatar(kind: .person, name: name, size: 32)
                            Text(verbatim: name)
                                .foregroundStyle(atum.color(.ink, scheme: scheme))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Button(design.text("src.matrix.moderation-copy.copies.unignore")) {
                                Task { await unignore(person) }
                            }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .tint(atum.color(.ink, scheme: scheme))
                            .disabled(working != nil)
                            .accessibilityIdentifier("account.ignored.unignore." + person.userID)
                        }
                        .frame(minHeight: 52)
                    }
                } else {
                    AtomWait().frame(width: 20, height: 20)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            } footer: {
                Text(design.text("src.matrix.moderation-copy.copies.ignoredHelp"))
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .navigationTitle(design.text("src.matrix.moderation-copy.copies.ignoredPeople"))
        .navigationBarTitleDisplayMode(.inline)
        .task { people = await actions.ignoredPeople?() ?? [] }
        .accessibilityIdentifier("account.ignored")
    }

    private func unignore(_ person: IgnoredPerson) async {
        working = person.userID
        defer { working = nil }
        if await actions.setIgnored?(person.userID, false) == true {
            people?.removeAll { $0.userID == person.userID }
        }
    }
}
