import AtumChat
import AtumDesign
import SwiftUI

struct LegalScreen: View {
    let design: LiveDesign
    let openWebPage: (URL) -> Void

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        List {
            Section {
                webRow("src.matrix.legal-copy.copy.terms",
                       url: URL(string: "https://atumplatform.com/terms")!,
                       identifier: "account.legal.terms")
                webRow("src.matrix.legal-copy.copy.privacy",
                       url: URL(string: "https://atumplatform.com/privacy")!,
                       identifier: "account.legal.privacy")
                NavigationLink {
                    LicencesScreen(design: design)
                } label: {
                    rowLabel(copy("src.matrix.legal-copy.copy.openSourceLicences"),
                             indicator: .chevronRight)
                }
                .accessibilityIdentifier("account.legal.licences-link")
            } footer: {
                Text(copy("src.matrix.legal-copy.copy.seller"))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .navigationTitle(copy("src.matrix.legal-copy.copy.legal"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("account.legal.screen")
    }

    private func webRow(_ key: String, url: URL, identifier: String) -> some View {
        Button { openWebPage(url) } label: {
            rowLabel(copy(key), indicator: .arrowUpRight)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func rowLabel(_ title: String, indicator: AtumGlyph) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
            Spacer()
            Image(atum.symbol(indicator))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func copy(_ key: String) -> String { design.text(key) }
}

struct LicencesScreen: View {
    let design: LiveDesign
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .navigationTitle(design.text("src.matrix.legal-copy.copy.openSourceLicences"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("account.licences.screen")
    }

    private var text: String {
        let attribution = (try? AtumDesign.data(for: "ATTRIBUTION.md"))
            .map { String(decoding: $0, as: UTF8.self) } ?? ""
        let notice = Bundle.main.url(forResource: "NOTICE", withExtension: nil)
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return [attribution, notice].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

