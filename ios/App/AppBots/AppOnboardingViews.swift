import AtumDesign
import AtumNativeAPI
import SwiftUI

struct AppOnboardingPresentation: Identifiable, Equatable {
    enum Phase: Equatable {
        case loading
        case consent
        case authenticating
        case connecting
        case intake([AppIntakeStatus.FieldSpec])
        case failed
    }

    let id: UUID
    let app: AppBotPresentation
    let disclosureVersion: Int64
    let locale: AppBotConsentLocale
    let copy: AppOnboardingCopy
    var phase: Phase
    var values: [String: String] = [:]
    var fieldErrors: Set<String> = []
    var formFailed = false
}

struct AppContentPage: Identifiable, Equatable {
    let id = UUID()
    let url: URL
}

struct AppOnboardingSheet: View {
    let presentation: AppOnboardingPresentation
    let design: LiveDesign
    let start: () -> Void
    let retry: () -> Void
    let update: (String, String) -> Void
    let submit: () -> Void
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.atum) private var atum
    @State private var termsPage: AppContentPage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    AppBotAvatar(app: presentation.app, size: 64)
                    Text(verbatim: presentation.app.name)
                        .font(.title3.weight(.semibold))
                    content
                }
                .frame(maxWidth: 440)
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
            .background(design.color("ground", scheme: scheme).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if canDismiss {
                        Button(action: dismiss) {
                            (atum?.barIcon(.close) ?? Image("ph.x"))
                        }
                        .accessibilityLabel(copy("src.matrix.chat-copy.copies.dismiss"))
                    }
                }
            }
        }
        .interactiveDismissDisabled(!canDismiss)
        .fullScreenCover(item: $termsPage) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
        .accessibilityIdentifier("app.onboarding.sheet")
    }

    private var canDismiss: Bool {
        switch presentation.phase {
        case .authenticating, .connecting: false
        default: true
        }
    }

    @ViewBuilder private var content: some View {
        switch presentation.phase {
        case .loading:
            ProgressView().accessibilityLabel(copy("desktop.dm.intake.loading"))
        case .consent:
            Text(verbatim: presentation.copy.consent)
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let termsURL = presentation.copy.termsURL {
                Button(copy("src.matrix.sign-in-copy.copies.terms")) {
                    termsPage = AppContentPage(url: termsURL)
                }
                .buttonStyle(.plain)
                .foregroundStyle(design.color("actionStrong", scheme: scheme))
            }
            if let atum {
                Button(copy("shared.matrix-app-chat-copy.matrixAppChatCopy.startBot"), action: start)
                    .buttonStyle(AppAccentButtonStyle(app: presentation.app, atum: atum,
                                                      scheme: scheme, size: .large))
                    .accessibilityIdentifier("app.onboarding.start")
            }
        case .authenticating:
            ProgressView()
            Text(copy("src.matrix.mobile-copy.mobilePhoneCopy.opening"))
                .foregroundStyle(design.color("soft", scheme: scheme))
        case .connecting:
            ProgressView()
            Text(verbatim: presentation.copy.connecting)
                .foregroundStyle(design.color("soft", scheme: scheme))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("app.onboarding.connecting")
        case let .intake(fields):
            intake(fields)
        case .failed:
            Text(verbatim: presentation.copy.failure)
                .foregroundStyle(design.color("danger", scheme: scheme))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("app.onboarding.failure")
            Button(copy("src.matrix.chat-copy.copies.retry"), action: retry)
                .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private func intake(_ fields: [AppIntakeStatus.FieldSpec]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(copy("desktop.dm.intake.title", [.text(presentation.app.name)]))
                .font(.headline)
            Text(copy("desktop.dm.intake.description"))
                .font(.subheadline)
                .foregroundStyle(design.color("soft", scheme: scheme))
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 6) {
                    let label = presentation.copy.fieldLabels[field.name]
                        ?? AppOnboardingCopy.readableName(field.name)
                    Text(verbatim: label).font(.subheadline.weight(.medium))
                    if field.kind == .select, let options = field.options {
                        Picker(label, selection: valueBinding(field.name)) {
                            Text(copy("desktop.dm.intake.choose")).tag("")
                            ForEach(options, id: \.value) { option in
                                Text(verbatim: presentation.copy.genderLabels[option.value]
                                     ?? option.label).tag(option.value)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        TextField(label, text: valueBinding(field.name))
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(field.kind == .date || field.kind == .time
                                          ? .numbersAndPunctuation : .default)
                    }
                    if field.name == "birth_time", let helper = presentation.copy.birthTimeHelper {
                        Text(verbatim: helper)
                            .font(.caption)
                            .foregroundStyle(design.color("soft", scheme: scheme))
                    }
                    if presentation.fieldErrors.contains(field.name) {
                        Text(copy("desktop.dm.intake.required"))
                            .font(.caption)
                            .foregroundStyle(design.color("danger", scheme: scheme))
                            .accessibilityIdentifier("app.onboarding.field-error.\(field.name)")
                    }
                }
            }
            if presentation.formFailed {
                Text(copy("desktop.dm.intake.submitFailed"))
                    .font(.footnote)
                    .foregroundStyle(design.color("danger", scheme: scheme))
            }
            if let atum {
                Button(copy("desktop.dm.intake.submit"), action: submit)
                    .buttonStyle(AppAccentButtonStyle(app: presentation.app, atum: atum,
                                                      scheme: scheme, size: .large))
                    .accessibilityIdentifier("app.onboarding.intake.submit")
            }
        }
    }

    private func valueBinding(_ name: String) -> Binding<String> {
        Binding(get: { presentation.values[name] ?? "" },
                set: { update(name, $0) })
    }

    private func copy(_ key: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key, arguments: arguments)
    }
}
