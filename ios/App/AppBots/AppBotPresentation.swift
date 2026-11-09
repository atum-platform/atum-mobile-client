import AtumChat
import AtumNativeAPI
import Foundation
import Observation
import SwiftUI

struct AppBotPresentation: Equatable, Sendable {
    let appID: String
    let slug: String
    let botUserID: String
    let name: String
    let subtitle: String?
    let avatarURL: URL
    let avatarSHA256: String
    let accentHex: String?
    let verification: AppVerificationTier?
    let purchaseRouteID: String
    let transportMode: AppBotDescriptor.TransportMode
    let setupComplete: Bool
    let onboardingCopy: AppOnboardingCopy?
    let composerAction: AppBotComposerAction?

    init(appID: String, slug: String, botUserID: String, name: String,
         subtitle: String?, avatarURL: URL, avatarSHA256: String,
         accentHex: String?, verification: AppVerificationTier?,
         purchaseRouteID: String, transportMode: AppBotDescriptor.TransportMode = .legacyTurn,
         setupComplete: Bool,
         onboardingCopy: AppOnboardingCopy? = nil,
         composerAction: AppBotComposerAction? = nil) {
        self.appID = appID
        self.slug = slug
        self.botUserID = botUserID
        self.name = name
        self.subtitle = subtitle
        self.avatarURL = avatarURL
        self.avatarSHA256 = avatarSHA256
        self.accentHex = accentHex
        self.verification = verification
        self.purchaseRouteID = purchaseRouteID
        self.transportMode = transportMode
        self.setupComplete = setupComplete
        self.onboardingCopy = onboardingCopy
        self.composerAction = composerAction
    }

    init?(app: AppDescriptor, locale: String,
          workspace: AppWorkspaceSnapshot? = nil,
          onboardingCopy: AppOnboardingCopy? = nil) {
        guard let bot = app.bot else { return nil }
        appID = app.appID.rawValue
        slug = app.app
        botUserID = bot.userID.rawValue
        name = app.name.localized(locale: locale, fallback: bot.displayName)
        subtitle = app.subtitle?.localized(locale: locale, fallback: "")
        avatarURL = bot.avatar.url
        avatarSHA256 = bot.avatar.sha256
        accentHex = app.accent
        verification = switch app.verification {
        case .official: .official
        case .verified: .verified
        case nil: nil
        }
        purchaseRouteID = bot.purchaseRouteID
        transportMode = bot.transportMode
        let isSetupComplete = bot.transportMode == .botAPI
            || (bot.consent == .accepted && app.link.state == .linked)
        setupComplete = isSetupComplete
        self.onboardingCopy = bot.transportMode == .botAPI ? nil : onboardingCopy
        composerAction = workspace.flatMap { workspace in
            guard isSetupComplete, workspace.slug == app.app,
                  workspace.appVersionID == app.appVersionID,
                  workspace.supportsLaunch,
                  let route = workspace.routes.first(where: {
                      $0.placements.contains(.composer)
                          && $0.session == .required
                          && AppOnboardingPolicy.allowsComposerRoute(slug: app.app, routeID: $0.id)
                  }), let label = onboardingCopy?.readings else { return nil }
            return AppBotComposerAction(routeID: route.id, label: label)
        }
    }
}

struct AppBotComposerAction: Equatable, Sendable {
    let routeID: String
    let label: String
}

struct AppBotCatalogPresentation: Equatable, Sendable {
    var appsByBotUserID: [String: AppBotPresentation]
    var roomIDBySlug: [String: String]

    static let empty = AppBotCatalogPresentation(appsByBotUserID: [:], roomIDBySlug: [:])
}

enum AppBotRoomOpeningPhase: Equatable, Sendable { case joining, failed }

struct AppBotRoomOpening: Equatable, Sendable {
    let roomID: String
    let app: AppBotPresentation
    var phase: AppBotRoomOpeningPhase
}

enum AppBotContinueKind: Equatable, Sendable {
    case setup
    case route
}

struct AppBotContinueRequest: Identifiable, Equatable, Sendable {
    let app: AppBotPresentation
    let kind: AppBotContinueKind
    var id: String { app.appID + ":" + String(describing: kind) }
}

@MainActor
@Observable
final class AppBotPresenter {
    var continueRequest: AppBotContinueRequest?
    @ObservationIgnored var openApp: @MainActor @Sendable (String) -> Void = { _ in }
    @ObservationIgnored var beginSetup: @MainActor @Sendable (AppBotPresentation) -> Bool = { _ in false }
    @ObservationIgnored var openRoute: @MainActor @Sendable (AppBotPresentation, String) -> Bool = { _, _ in false }
    @ObservationIgnored var openTerms: @MainActor @Sendable (URL) -> Void = { _ in }
    var covers: Bool { continueRequest != nil }

    func dismissAll() { continueRequest = nil }
}

extension EnvironmentValues {
    @Entry var appBotPresentation: AppBotPresentation?
    @Entry var appBotPresenter: AppBotPresenter?
    @Entry var appBotNoticeDisplays: [String: AppBotNoticeDisplay] = [:]
}
