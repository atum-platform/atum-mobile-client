import AtumChat
import Foundation
import SwiftUI

struct S6BootWait: View {
    let design: LiveDesign
    var revealAfter: Date?
    @State private var showsMark = false
    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        ZStack {
            atum.color(.ground, scheme: scheme).ignoresSafeArea()
            if showsMark {
                VStack(spacing: 24) {
                    LiveEclipseMark(design: design).frame(width: 76, height: 76)
                    AtomWait()
                        .frame(width: 28, height: 28)
                        .foregroundStyle(atum.color(.muted, scheme: scheme))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(copy("src.matrix.mobile-copy.mobilePhoneCopy.opening"))
                .transition(.opacity)
            }
        }
        .task {
            let deadline = revealAfter?.addingTimeInterval(1)
                ?? Date().addingTimeInterval(1)
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showsMark = true }
        }
        .accessibilityIdentifier("boot.wait")
    }

    private func copy(_ key: String) -> String { design.text(key) }

    init(design: LiveDesign, revealAfter: Date? = nil) {
        self.design = design
        self.revealAfter = revealAfter
    }
}

struct S6WelcomeScreen: View {
    let design: LiveDesign
    let presentation: WelcomePresentation
    let onContinue: () -> Void
    let onOpenLegal: (URL) -> Void

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    LiveEclipseMark(design: design)
                        .frame(width: 112, height: 112)
                        .accessibilityHidden(true)
                    Text(copy("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeTitle"))
                        .font(.system(.largeTitle, weight: .semibold))
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 24)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("welcome.title")
                    Text(copy("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeBody"))
                        .font(.body)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320)
                        .padding(.top, 12)
                    notice
                    Spacer(minLength: 24)
                    Button(action: onContinue) {
                        Group {
                            if presentation == .busy {
                                AtomWait().frame(width: 20, height: 20)
                            } else {
                                Text(copy("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeActionsSignInLabel"))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
                    .disabled(!presentation.acceptsSignInTap)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(presentation == .busy
                        ? copy("src.matrix.mobile-copy.mobilePhoneCopy.signingIn")
                        : copy("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeActionsSignInLabel"))
                    .accessibilityIdentifier("live-sign-in")
                    Text(copy("src.matrix.mobile-device-copy.mobileDeviceCopy.signInCloudConsentText"))
                        .font(.footnote)
                        .foregroundStyle(atum.color(.soft, scheme: scheme))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                        .accessibilityIdentifier("welcome.cloud-consent")
                    Text(legalText)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .tint(atum.color(.ink, scheme: scheme))
                        .padding(.top, 16)
                        .environment(\.openURL, OpenURLAction { url in
                            onOpenLegal(url)
                            return .handled
                        })
                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 24)
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .interactiveDismissDisabled()
        .accessibilityIdentifier("welcome.screen")
    }

    @ViewBuilder private var notice: some View {
        switch presentation {
        case .idle:
            EmptyView()
        case .busy:
            // The disabled primary control owns the busy words. Repeating
            // them here creates a second VoiceOver element for one state.
            EmptyView()
        case .cancelled:
            noticeText(copy("src.matrix.mobile-device-copy.mobileDeviceCopy.signInStatesCancelledText"))
        case .registrationClosed:
            noticeText(copy("src.matrix.mobile-device-copy.mobileDeviceCopy.signInStatesRegistrationClosedText"))
        case .failed:
            noticeText(copy("src.matrix.chat-copy.copies.errorGeneric"))
        case .expired:
            VStack(spacing: 8) {
                Text(copy("desktop.atum.auth.expiredTitle"))
                    .font(.headline)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                Text(copy("desktop.atum.auth.expiredBody"))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
        }
    }

    private func noticeText(_ value: String) -> some View {
        Text(value)
            .font(.footnote)
            .foregroundStyle(atum.color(.soft, scheme: scheme))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 16)
    }

    private var legalText: AttributedString {
        var result = AttributedString(copy("src.matrix.sign-in-copy.copies.legal"))
        replace("{terms}", with: copy("src.matrix.sign-in-copy.copies.terms"),
                url: URL(string: "https://atumplatform.com/terms")!, in: &result)
        replace("{privacy}", with: copy("src.matrix.sign-in-copy.copies.privacy"),
                url: URL(string: "https://atumplatform.com/privacy")!, in: &result)
        result.foregroundColor = atum.color(.soft, scheme: scheme)
        for run in result.runs where run.link != nil {
            result[run.range].foregroundColor = atum.color(.ink, scheme: scheme)
            result[run.range].underlineStyle = nil
        }
        return result
    }

    private func replace(_ placeholder: String, with text: String, url: URL,
                         in value: inout AttributedString) {
        guard let range = value.range(of: placeholder) else { return }
        var replacement = AttributedString(text)
        replacement.link = url
        value.replaceSubrange(range, with: replacement)
    }

    private func copy(_ key: String) -> String { design.text(key) }
}

struct S6StatusScreen: View {
    enum Kind: Equatable {
        case cannotConnect
        case domain(LiveSignInNotice)
    }

    let design: LiveDesign
    let kind: Kind
    let busy: Bool
    let retry: () -> Void
    let signOut: (() -> Void)?

    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            LiveEclipseMark(design: design).frame(width: 76, height: 76)
                .accessibilityHidden(true)
            Text(message)
                .font(.body)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 20)
            Button(action: retry) {
                Group {
                    if busy { AtomWait().frame(width: 20, height: 20) }
                    else { Text(primaryLabel) }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(AtumPrimaryButtonStyle(atum: atum, scheme: scheme))
            .disabled(busy)
            .padding(.top, 32)
            if let signOut {
                Button(copy("desktop.dm.signOut"), action: signOut)
                    .buttonStyle(AtumQuietButtonStyle(atum: atum, scheme: scheme))
                    .padding(.top, 8)
            }
            Spacer().frame(maxHeight: .infinity).layoutPriority(1.3)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(atum.color(.ground, scheme: scheme).ignoresSafeArea())
        .accessibilityIdentifier("status.screen")
    }

    private var message: String {
        if busy {
            return copy("src.matrix.mobile-copy.mobilePhoneCopy.signingIn")
        }
        return switch kind {
        case .cannotConnect:
            copy("src.matrix.sign-in-copy.copies.notConnected")
        case let .domain(notice):
            switch notice {
            case .subjectMismatch:
                copy("src.matrix.mobile-device-copy.mobileDeviceCopy.browserSignInStatesSubjectMismatchText")
            case .cancelled:
                copy("src.matrix.mobile-device-copy.mobileDeviceCopy.signInStatesCancelledText")
            case .failed:
                copy("src.matrix.chat-copy.copies.errorGeneric")
            case .domainUnavailable:
                copy("src.matrix.mobile-device-copy.mobileDeviceCopy.browserSignInStatesDomainUnavailableText")
            }
        }
    }

    private var primaryLabel: String {
        switch kind {
        case .cannotConnect: copy("src.matrix.chat-copy.copies.retry")
        case .domain: copy("src.matrix.mobile-device-copy.mobileDeviceCopy.welcomeActionsSignInLabel")
        }
    }

    private func copy(_ key: String) -> String { design.text(key) }
}

