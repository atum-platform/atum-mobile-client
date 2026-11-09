import Foundation

/// How a person starts a chat with a catalog app bot from the Store or the
/// roster when no room exists yet. Everything here reads catalog and status
/// data; no app is named. A new app that publishes a bot works without code.
public enum AppStartPolicy {
    /// What a Store or roster row offers for one app.
    public enum Action: Equatable, Sendable {
        /// A joined canonical room exists: open it.
        case open(roomID: String)
        /// No room yet and the bot can take one: run the disclosure flow.
        case startChat
        /// A Bot API app needs no legacy disclosure or connection gate: find
        /// or create its ordinary Matrix DM directly.
        case startDirect
        /// Nothing the phone can do (no bot, coming soon, paused, a disclosure
        /// the phone has no reader for).
        case none
    }

    /// How the chat is entered once the person agrees to the disclosure.
    public enum Mode: Equatable, Sendable {
        /// The bot declared guest chat: consent only, no provider account.
        case guest
        /// Everyone else: consent, then the provider account link.
        case linked
    }

    public static func action(for app: AppDescriptor, existingRoomID: String?) -> Action {
        if let existingRoomID { return .open(roomID: existingRoomID) }
        guard app.effectiveRosterState == .available,
              app.availability == .available,
              let bot = app.bot, bot.isStartable else { return .none }
        if bot.transportMode == .botAPI {
            return app.supportedModes.contains(.direct) ? .startDirect : .none
        }
        guard AppOnboardingPolicy.supports(disclosureVersion: bot.disclosureVersion, for: app.app)
        else { return .none }
        // A bot that advertises guest chat without the v2 turn profile is an
        // incoherent producer: refuse rather than guess a mode.
        return !bot.guestEnabled || bot.supportsGuestChat ? .startChat : .none
    }

    /// An available app with a running published bot whose disclosure the
    /// phone can show. `link.mode == .none` is fine: a guest bot needs no link.
    public static func canStartChat(_ app: AppDescriptor) -> Bool {
        switch action(for: app, existingRoomID: nil) {
        case .startChat, .startDirect: true
        case .open, .none: false
        }
    }

    /// The entry mode for an app given the platform status, or nil when the
    /// status says the app cannot be started now (a guest bot on a platform
    /// without the guest projection is honestly unavailable).
    public static func mode(for app: AppDescriptor, status: AppBotSetupStatus) -> Mode? {
        guard let bot = app.bot else { return nil }
        guard bot.transportMode == .legacyTurn else { return nil }
        guard bot.guestEnabled else { return .linked }
        guard bot.supportsGuestChat, let guest = status.guest, guest.enabled else { return nil }
        switch guest.state {
        case .startRequired, .ready: return .guest
        case .linked: return .linked
        case .unsupported, .unavailable: return nil
        }
    }

    /// A guest chat stands only on current consent to this disclosure and a
    /// `ready` guest state with no linked account.
    public static func guestReady(_ status: AppBotSetupStatus, disclosureVersion: Int64) -> Bool {
        status.guest?.enabled == true
            && status.guest?.state == .ready
            && status.consent.state == .accepted
            && status.consent.disclosureVersion == disclosureVersion
            && status.link.state != .linked
    }
}

/// Bot API room entry has no platform setup seam: it resolves or creates the
/// ordinary Matrix direct room and therefore cannot call consent, Connect or
/// `/bot/start` by construction.
public enum AppBotDirectStart {
    @MainActor
    public static func run(app: AppDescriptor, chats: some AppBotChatPort) async throws -> String {
        guard app.effectiveRosterState == .available,
              app.availability == .available,
              app.supportedModes.contains(.direct),
              let bot = app.bot, bot.isStartable, bot.transportMode == .botAPI else {
            throw AppStartFailure.unavailable
        }
        let appID = app.appID.rawValue
        let botUserID = bot.userID.rawValue
        if let existing = await chats.existingChat(appID: appID, botUserID: botUserID) {
            return existing
        }
        guard let created = await chats.createChat(appID: appID, botUserID: botUserID),
              await chats.open(roomID: created) else { throw AppStartFailure.noChat }
        return created
    }
}

/// The platform reads and writes a start needs.
@MainActor
public protocol AppStartBackend {
    func appBotStatus(slug: String) async throws -> AppBotSetupStatus
    func acceptAppBotConsent(slug: String,
                             value: AppBotConsentRequest) async throws -> AppBotSetupStatus
    /// The platform's canonical-room arbitration. A backend without it answers
    /// `.routeAbsent` and the start falls back to local resolution.
    func startAppBot(slug: String, value: AppBotStartRequest) async throws -> AppBotStartResult
}

extension AppStartBackend {
    public func startAppBot(slug: String, value: AppBotStartRequest) async throws -> AppBotStartResult {
        .routeAbsent
    }
}

/// The Matrix side of a start. The phone creates nothing on its own: this port
/// finds the person's one chat with the bot or makes it, once.
@MainActor
public protocol AppBotChatPort {
    /// The person's joined chat with this bot (accepting the bot's own
    /// invitation when that is all there is), or nil when there is none.
    func existingChat(appID: String, botUserID: String) async -> String?
    /// Creates the chat. Called at most once per bot and session by a flow;
    /// nil when Matrix refused. A port also remembers a room it made so a
    /// retry reuses it instead of making a second one.
    func createChat(appID: String, botUserID: String) async -> String?

    // The steps of the platform's canonical-room arbitration. A port that does
    // not implement them cannot take part and the start uses the two calls above.

    /// A joined, plain, one-to-one chat with the bot this phone already holds
    /// (including a room it made earlier), offered to the platform for adoption.
    func verifiedChat(appID: String, botUserID: String) async -> String?
    /// Makes a plain, unencrypted, invite-only direct room and invites the bot.
    /// It writes no records: the platform may name another room as the winner.
    func createPlainChat(botUserID: String) async -> String?
    /// The bot-chat marker and account pointer for a room that won.
    func writeChatRecords(roomID: String, appID: String, botUserID: String) async
    /// Leaves a room this device made and lost.
    func leave(roomID: String) async
    /// Joins the room (a no-op when joined) and waits for it to show.
    func open(roomID: String) async -> Bool
}

extension AppBotChatPort {
    public func verifiedChat(appID: String, botUserID: String) async -> String? { nil }
    public func createPlainChat(botUserID: String) async -> String? { nil }
    public func writeChatRecords(roomID: String, appID: String, botUserID: String) async {}
    public func leave(roomID: String) async {}
    public func open(roomID: String) async -> Bool { false }
}

public enum AppStartFailure: Error, Equatable, Sendable {
    /// The app or bot cannot take this start (not a guest app, not running).
    case unavailable
    /// The platform did not report a ready guest state after consent.
    case guestNotReady
    /// No chat could be found or created.
    case noChat
    /// The platform says this app's bot cannot take a chat now.
    case platformUnavailable(AppBotStartAnswer.Reason)
}

/// One room per person and bot, decided by the platform. The device asks; if
/// told to create, it makes a plain direct room and asks again naming it; the
/// answer may name a different room, and then this device leaves its own.
public enum AppBotRoomArbitration {
    /// Nil when the platform has no such route (fall back to local resolution).
    @MainActor
    public static func resolve(
        app: AppDescriptor, bot: AppBotDescriptor, requestID: UUID,
        backend: some AppStartBackend, chats: some AppBotChatPort,
        retryDelays: [Duration],
        sleep: @Sendable (Duration) async throws -> Void
    ) async throws -> String? {
        let appID = app.appID.rawValue
        let botUserID = bot.userID.rawValue
        let adopt = await chats.verifiedChat(appID: appID, botUserID: botUserID)
        let first = try AppBotStartRequest(requestID: requestID,
                                           appVersion: app.appVersionID.rawValue, roomID: adopt)

        func call(_ request: AppBotStartRequest) async throws -> AppBotStartResult {
            var delays = retryDelays[...]
            while true {
                do { return try await backend.startAppBot(slug: app.app, value: request) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    // The same request ID goes again: the platform treats a repeat as
                    // the same attempt. Only a transient failure is retried.
                    guard isTransient(error), let delay = delays.popFirst() else { throw error }
                    try await sleep(delay)
                }
            }
        }
        /// The answer must be about this app's bot; anything else fails closed.
        func requireBot(_ answered: String) throws {
            guard answered == botUserID else { throw AppStartFailure.unavailable }
        }
        func open(_ roomID: String) async throws -> String {
            guard await chats.open(roomID: roomID) else { throw AppStartFailure.noChat }
            return roomID
        }

        switch try await call(first) {
        case .routeAbsent, .answer(.notFound):
            return nil
        case let .answer(.unavailable(reason)):
            throw AppStartFailure.platformUnavailable(reason)
        case let .answer(.ready(roomID, answered)):
            try requireBot(answered)
            return try await open(roomID)
        case let .answer(.create(answered)):
            try requireBot(answered)
            guard let mine = await chats.createPlainChat(botUserID: answered) else {
                throw AppStartFailure.noChat
            }
            switch try await call(first.naming(roomID: mine)) {
            case .routeAbsent, .answer(.notFound):
                // The route went away between the two calls: keep what was made.
                await chats.writeChatRecords(roomID: mine, appID: appID, botUserID: botUserID)
                return mine
            case let .answer(.ready(winner, answered)):
                try requireBot(answered)
                if winner == mine {
                    await chats.writeChatRecords(roomID: mine, appID: appID, botUserID: botUserID)
                    return mine
                }
                // Another device's room won: leave this one and open the winner.
                await chats.leave(roomID: mine)
                return try await open(winner)
            case let .answer(.unavailable(reason)):
                await chats.leave(roomID: mine)
                throw AppStartFailure.platformUnavailable(reason)
            case .answer(.create):
                throw AppStartFailure.noChat
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let failure = error as? NativeDomainClientFailure else { return false }
        switch failure {
        case .transportUnavailable: return true
        case let .http(http): return http.response.error == .unavailable
        default: return false
        }
    }
}

/// The guest start: accept the disclosure, confirm the platform says the guest
/// chat is ready, then find or create the DM with the bot. No provider account.
public enum AppGuestStart {
    /// `retryDelays` are the pauses between status reads after consent; the
    /// first read is immediate.
    @MainActor
    public static func run(
        app: AppDescriptor,
        consent: AppBotConsentRequest,
        backend: some AppStartBackend,
        chats: some AppBotChatPort,
        retryDelays: [Duration] = [.seconds(1), .seconds(2)],
        requestID: UUID = UUID(),
        startRetryDelays: [Duration] = [.milliseconds(500), .seconds(2)],
        sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws -> String {
        guard let bot = app.bot, bot.isStartable, bot.supportsGuestChat else {
            throw AppStartFailure.unavailable
        }
        let accepted = try await backend.acceptAppBotConsent(slug: app.app, value: consent)
        var status = accepted
        var delays = retryDelays[...]
        while !AppStartPolicy.guestReady(status, disclosureVersion: consent.disclosureVersion) {
            guard let delay = delays.popFirst() else { throw AppStartFailure.guestNotReady }
            try await sleep(delay)
            status = try await backend.appBotStatus(slug: app.app)
        }
        // The platform decides which room is the person's one chat with this bot.
        // `requestID` is this attempt's: reused across its retries, fresh for the
        // next attempt. An older Shell without the route falls back to local
        // resolution below.
        if let arbitrated = try await AppBotRoomArbitration.resolve(
            app: app, bot: bot, requestID: requestID, backend: backend, chats: chats,
            retryDelays: startRetryDelays, sleep: sleep
        ) { return arbitrated }
        let appID = app.appID.rawValue
        if let existing = await chats.existingChat(appID: appID, botUserID: bot.userID.rawValue) {
            return existing
        }
        guard let created = await chats.createChat(appID: appID, botUserID: bot.userID.rawValue) else {
            throw AppStartFailure.noChat
        }
        return created
    }
}

/// Where an onboarding attempt stands before the person has agreed. Starting
/// from a roster row or the Store only *shows* the disclosure; nothing is
/// accepted and no provider link starts until the person presses Start. A
/// retry after a failure that happened before that press goes back to the
/// disclosure, never forward.
public struct AppOnboardingGate: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case loading, consent, continuing, failed }

    public private(set) var phase: Phase = .loading
    /// True once the person pressed Start, or the entry itself was that press
    /// (the chat notice's own button).
    public private(set) var consentStarted: Bool

    public init(automaticallyContinue: Bool) { consentStarted = automaticallyContinue }

    /// The first status read succeeded. True when the flow goes straight on to
    /// the disclosure acceptance (only after an explicit start).
    public mutating func statusLoaded() -> Bool {
        phase = consentStarted ? .continuing : .consent
        return consentStarted
    }

    /// The person pressed Start on the disclosure.
    public mutating func startPressed() -> Bool {
        guard phase == .consent else { return false }
        consentStarted = true
        phase = .continuing
        return true
    }

    public mutating func failed() { phase = .failed }

    /// The gate for a Retry. It continues by itself only if the person had
    /// already pressed Start.
    public func retried() -> AppOnboardingGate {
        AppOnboardingGate(automaticallyContinue: consentStarted)
    }
}

/// Writes the two records that name a bot chat for every device of the person.
@MainActor
public protocol AppBotChatWriter {
    func writeMarker(roomID: String, content: String) async throws
    func writePointer(content: String) async throws
}

/// The records of a new bot chat, written before anything is sent into it.
/// This narrows, but does not close, the window in which another device could
/// make a second room: only the platform's canonical-room arbitration closes it.
public enum AppBotChatRecipe {
    public static let attempts = 3

    public struct Outcome: Equatable, Sendable {
        public var markerWritten = false
        public var pointerWritten = false
        public var markerAttempts = 0
        public var pointerAttempts = 0
    }

    /// Each record gets up to `attempts` tries with a pause between them. A
    /// record that still fails is logged (a closed code, never an ID) and does
    /// not block the chat: the room works, it just may not be recognised by
    /// another device.
    @MainActor
    public static func finalize(
        roomID: String, appID: String, botUserID: String,
        writer: some AppBotChatWriter,
        backoff: [Duration] = [.milliseconds(300), .milliseconds(900)],
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        log: (String) -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        if let marker = MobileAppBotRoomPolicy.markerContentJSON(appID: appID, botUserID: botUserID) {
            for attempt in 0..<attempts {
                outcome.markerAttempts += 1
                do {
                    try await writer.writeMarker(roomID: roomID, content: marker)
                    outcome.markerWritten = true
                    break
                } catch is CancellationError { return outcome } catch {
                    if attempt + 1 < attempts, backoff.indices.contains(attempt) {
                        try? await sleep(backoff[attempt])
                    }
                }
            }
        }
        if !outcome.markerWritten { log("marker_write_failed") }
        if let pointer = MobileAppBotRoomPolicy.pointerContentJSON(roomID: roomID, botUserID: botUserID) {
            for attempt in 0..<attempts {
                outcome.pointerAttempts += 1
                do {
                    try await writer.writePointer(content: pointer)
                    outcome.pointerWritten = true
                    break
                } catch is CancellationError { return outcome } catch {
                    if attempt + 1 < attempts, backoff.indices.contains(attempt) {
                        try? await sleep(backoff[attempt])
                    }
                }
            }
        }
        if !outcome.pointerWritten { log("pointer_write_failed") }
        return outcome
    }
}

/// Finds the person's existing chat with a bot before one is created: the best
/// local choice, else the room the account pointer names even when it has not
/// reached this phone's room list yet.
public enum AppBotChatResolver {
    @MainActor
    public static func resolve(
        localChoice: MobileAppBotChatChoice?,
        pointerRoomID: String?,
        join: (String) async -> Bool,
        appears: (String) async -> Bool
    ) async -> String? {
        if let localChoice {
            if localChoice.action == .join, !(await join(localChoice.roomID)) { return nil }
            return localChoice.roomID
        }
        // A room another device made and named: join it (a no-op when already
        // joined) and wait for it to show. A room that cannot be joined, such as
        // one the person left, is not reused and a new chat is made.
        guard let pointerRoomID,
              await join(pointerRoomID), await appears(pointerRoomID) else { return nil }
        return pointerRoomID
    }
}

extension NativeDomainClient: AppStartBackend {}
