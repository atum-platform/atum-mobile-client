import AtumChat
import Foundation

struct AppBotNoticeDisplay: Equatable, Sendable {
    let app: AppBotPresentation
    let message: AppBotMessage
    let action: AppBotMessage.Action?
}

struct AppBotNoticeProjectionInput: Equatable, Sendable {
    let rows: [ChatRow]
    let catalog: AppBotCatalogPresentation
    let roomID: String
    let roomIsEncrypted: Bool?
}

enum AppBotNoticeProjection {
    /// Parse and project outside the main actor. Input rows are immutable
    /// values, so a later snapshot simply replaces this result by row ID.
    static func displays(_ input: AppBotNoticeProjectionInput) -> [String: AppBotNoticeDisplay] {
        var parsedByID = [String: (app: AppBotPresentation, message: AppBotMessage)]()
        for row in input.rows {
            guard case .notice = row.item.kind,
                  let raw = row.item.appBotMeta,
                  let app = input.catalog.appsByBotUserID[row.item.sender],
                  app.transportMode == .legacyTurn else { continue }
            let authorization = AppBotMessage.Authorization(
                expectedCatalogAppID: app.appID,
                expectedCatalogAppSlug: app.slug,
                expectedCatalogBotUserID: app.botUserID,
                itemSender: row.item.sender,
                roomIsEncrypted: input.roomIsEncrypted != false
            )
            guard let message = AppBotMessage.parse(latestJSON: raw, authorization: authorization) else { continue }
            parsedByID[row.id] = (app, message)
        }

        var visibleActions = [String: AppBotMessage.Action]()
        let orderedRows = input.rows.sorted { left, right in
            if left.item.timestamp != right.item.timestamp {
                return left.item.timestamp < right.item.timestamp
            }
            return left.id < right.id
        }
        let byApp = Dictionary(grouping: orderedRows.compactMap { row -> AppBotNoticeButtons.Notice? in
            guard let parsed = parsedByID[row.id] else { return nil }
            return AppBotNoticeButtons.Notice(id: row.id, message: parsed.message)
        }) { notice in
            parsedByID[notice.id]?.app.slug ?? ""
        }
        for (slug, notices) in byApp where !slug.isEmpty {
            guard let app = notices.first.flatMap({ parsedByID[$0.id]?.app }) else { continue }
            let context = AppBotNoticeButtons.Context(
                currentRoomID: input.roomID,
                botIsSetUp: app.setupComplete,
                purchaseRouteID: app.purchaseRouteID,
                botRoomIDByApp: input.catalog.roomIDBySlug
            )
            visibleActions.merge(AppBotNoticeButtons.actions(for: notices, context: context)) {
                _, latest in latest
            }
        }

        var output = [String: AppBotNoticeDisplay]()
        for (id, value) in parsedByID {
            output[id] = AppBotNoticeDisplay(app: value.app, message: value.message,
                                             action: visibleActions[id])
        }
        return output
    }
}

extension AppBotMessage.Code {
    var copyKey: ChatCopyKey {
        switch self {
        case .needsSetup: .appBotNoticeNeedsSetup
        case .needsIntake: .appBotNoticeNeedsIntake
        case .allowanceExhausted: .appBotNoticeAllowanceExhausted
        case .unverifiedSender: .appBotNoticeUnverifiedSender
        case .linkPending: .appBotNoticeLinkPending
        case .busy: .appBotNoticeBusy
        case .rateLimited: .appBotNoticeRateLimited
        case .appUnavailable: .appBotNoticeUnavailable
        case .appTimeout: .appBotNoticeTimeout
        case .outcomeUnknown: .appBotNoticeOutcomeUnknown
        case .missedWhileOffline: .appBotNoticeMissedOffline
        case .sentBeforeLink: .appBotNoticeSentBeforeLink
        case .unsupportedContent: .appBotNoticeUnsupported
        case .messageTooLong: .appBotNoticeTooLong
        case .cannotRead: .appBotNoticeCannotRead
        case .andyGroupDeclined: .appBotNoticeAndyGroupDeclined
        case .joined: .appBotNoticeJoined
        case .nowGroup: .appBotNoticeNowGroup
        case .andyLeaving: .appBotNoticeAndyLeaving
        }
    }

    var usesAppArgument: Bool {
        switch self {
        case .rateLimited, .andyGroupDeclined, .nowGroup, .andyLeaving: false
        default: true
        }
    }
}
