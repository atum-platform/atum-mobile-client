import AtumChat
import AtumDesign
import AtumNativeAPI
import SwiftUI

/// An `m.notice` (B17): one quiet, centred, muted line showing the latest
/// edit, with no action. A catalog bot's two-line notice ("vi line, newline,
/// en line") shows the line in the app's language (§4.2 item 3). S5 adds the
/// bot's buttons here (WS7). Superseded working lines never reach this view:
/// the projection hides them.
struct NoticeRow: View {
    let row: ChatRow
    let kind: RoomKind
    let parsedBody: AttributedString?

    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.atum) private var atum
    @Environment(\.appBotNoticeDisplays) private var appBotNotices
    @Environment(\.appBotPresenter) private var appBotPresenter
    @Environment(\.chatReducesMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var actionTapGeneration = 0

    var body: some View {
        if let theme {
            VStack(spacing: 8) {
                if let display = appBotNotices[row.id] {
                    Text(authenticatedLine(display, theme: theme))
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.quiet(scheme))
                        .frame(maxWidth: .infinity)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .frame(minHeight: dynamicTypeSize.isAccessibilitySize ? nil : 40)
                        .accessibilityIdentifier(row.accessibilityID)
                    if display.message.code == .needsSetup,
                       let termsURL = display.app.onboardingCopy?.termsURL {
                        Button(ChatCopy.text(theme.design,
                                             "src.matrix.sign-in-copy.copies.terms")) {
                            appBotPresenter?.openTerms(termsURL)
                        }
                        .buttonStyle(.plain)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.design.color("actionStrong", scheme: scheme))
                        .accessibilityIdentifier("app.onboarding.terms.\(row.id)")
                    }
                    if let action = display.action, let atum {
                        Button(actionLabel(action, display: display, theme: theme)) {
                            actionTapGeneration &+= 1
                            perform(action, display: display)
                        }
                        .buttonStyle(AppAccentButtonStyle(app: display.app, atum: atum,
                                                         scheme: scheme, size: .compact))
                        .accessibilityIdentifier(AccessibilityID.noticeAction(id: row.id))
                        .transition(.opacity)
                    }
                } else {
                    let line = MobileAppBotRoomPolicy.noticeLine(
                        body: row.item.body,
                        senderIsCatalogBot: kind == .appBot && !row.item.isOwn,
                        isNotice: true,
                        languageCode: theme.design.locale
                    )
                    NativeRichText(bodyText: line,
                                   parsed: line == row.item.body ? parsedBody : nil,
                                   font: .footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(theme.quiet(scheme))
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier(row.accessibilityID)
                }
            }
            .padding(.horizontal, 24)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2),
                       value: appBotNotices[row.id]?.action)
            .sensoryFeedback(.impact(weight: .light), trigger: actionTapGeneration)
        }
    }

    private func authenticatedLine(_ display: AppBotNoticeDisplay, theme: ChatTheme) -> String {
        if display.message.code == .needsSetup, let onboarding = display.app.onboardingCopy {
            return onboarding.consent
        }
        let arguments: [AtumCopy.Argument] = display.message.code.usesAppArgument
            ? [.text(display.app.name)] : []
        return ChatCopy.text(theme.design, display.message.code.copyKey, arguments)
    }

    private func actionLabel(_ action: AppBotMessage.Action,
                             display: AppBotNoticeDisplay,
                             theme: ChatTheme) -> String {
        switch action {
        case .openSetup where display.message.code == .needsIntake:
            ChatCopy.text(theme.design, .appBotFillIn)
        case .openSetup:
            ChatCopy.text(theme.design, .appBotStart)
        case .openBotDM, .openAppRoute:
            ChatCopy.text(theme.design, .appBotOpen, [.text(display.app.name)])
        }
    }

    private func perform(_ action: AppBotMessage.Action, display: AppBotNoticeDisplay) {
        switch action {
        case .openSetup:
            if appBotPresenter?.beginSetup(display.app) != true {
                appBotPresenter?.continueRequest = AppBotContinueRequest(app: display.app, kind: .setup)
            }
        case let .openAppRoute(_, routeID):
            if appBotPresenter?.openRoute(display.app, routeID) != true {
                appBotPresenter?.continueRequest = AppBotContinueRequest(app: display.app, kind: .route)
            }
        case let .openBotDM(app):
            appBotPresenter?.openApp(app)
        }
    }
}
