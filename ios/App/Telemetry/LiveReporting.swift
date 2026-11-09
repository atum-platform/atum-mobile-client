import Foundation
import Observation
import AtumTelemetry

#if canImport(Sentry)
import Sentry
#endif

/// Build-time reporting configuration. Every value is optional: an empty DSN or
/// PostHog key disables that channel and never stops the app from launching.
struct LiveReportingConfiguration {
    let sentryDSN: String
    let postHogKey: String
    let postHogURL: URL?
    let environment: String
    let appVersion: String
    let buildNumber: String
    let osVersion: String

    init(bundle: Bundle = .main) {
        func value(_ key: String) -> String {
            let raw = (bundle.object(forInfoDictionaryKey: key) as? String) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // An unexpanded build setting is not a configuration value.
            return trimmed.hasPrefix("$(") ? "" : trimmed
        }

        sentryDSN = value("AtumSentryDSN")
        postHogKey = value("AtumPostHogKey")
        let host = value("AtumPostHogHost").isEmpty ? "https://us.i.posthog.com" : value("AtumPostHogHost")
        postHogURL = LiveReportingConfiguration.captureURL(host: host)
        let configuredEnvironment = value("AtumReportingEnvironment")
        if configuredEnvironment.isEmpty {
            #if DEBUG
            environment = "development"
            #else
            environment = "production"
            #endif
        } else {
            environment = configuredEnvironment
        }
        appVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unknown"
        buildNumber = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }

    private static func captureURL(host: String) -> URL? {
        guard var components = URLComponents(string: host),
              components.scheme == "https",
              let hostName = components.host, !hostName.isEmpty else {
            return nil
        }
        var path = components.path
        if !path.hasSuffix("/") { path += "/" }
        components.path = path + "capture/"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }
}

/// The switch is read by Sentry's `beforeSend`, which can run on a crash
/// thread. The lock keeps the opt-out effective for events already queued,
/// including the SDK's flush during `close()`.
private final class CrashReportingGate: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true

    var isAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowed
    }

    func setAllowed(_ value: Bool) {
        lock.lock()
        allowed = value
        lock.unlock()
    }
}

/// The app's one reporting coordinator. Crash reports go to Sentry and the
/// three audited product events go to PostHog through a plain URLSession.
/// Both channels default ON, persist their own switch, and are independent.
@MainActor
@Observable
final class LiveReporting {
    static let shared = LiveReporting()

    private(set) var crashReportsEnabled: Bool
    private(set) var usageDataEnabled: Bool

    private let configuration: LiveReportingConfiguration
    private let consent: TelemetryConsent
    private let firstEvents: TelemetryFirstEventStore
    private let defaults: UserDefaults
    private var started = false
    private var sentryStarted = false
    private let crashGate = CrashReportingGate()
    private var diagnosticID: String?
    private var uploadSession: URLSession?

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        configuration = LiveReportingConfiguration(bundle: bundle)
        consent = TelemetryConsent(defaults: defaults)
        firstEvents = TelemetryFirstEventStore(defaults: defaults)
        self.defaults = defaults
        crashReportsEnabled = consent.crashReportsEnabled
        usageDataEnabled = consent.usageDataEnabled
    }

    /// Called once from the app's launch. A configured crash reporter starts
    /// before the first scene; app_opened is the one launch event.
    func start() {
        guard !started else { return }
        started = true
        if crashReportsEnabled {
            startCrashReports()
        }
        if usageDataEnabled {
            capture(.appOpened)
        }
    }

    func setCrashReportsEnabled(_ enabled: Bool) {
        consent.setCrashReportsEnabled(enabled)
        crashReportsEnabled = enabled
        crashGate.setAllowed(enabled)
        if enabled {
            startCrashReports()
        } else {
            stopCrashReports()
        }
    }

    func setUsageDataEnabled(_ enabled: Bool) {
        consent.setUsageDataEnabled(enabled)
        usageDataEnabled = enabled
        if enabled {
            ensureUploadSession()
        } else {
            // Stop in-flight captures now; bytes already delivered cannot be
            // recalled, which Settings states.
            uploadSession?.invalidateAndCancel()
            uploadSession = nil
        }
    }

    func signInCompleted() { capture(.signInFinished(.completed)) }
    func signInFailed() { capture(.signInFinished(.failed)) }
    func signInCancelled() { capture(.signInFinished(.cancelled)) }

    /// Every accepted send calls this; only the first one per installation is
    /// reported. A disabled switch does not consume the marker.
    func messageSent() {
        guard usageDataEnabled,
              configuration.postHogURL != nil,
              TelemetrySanitizer.apiKey(configuration.postHogKey) != nil,
              !firstEvents.hasClaimedFirstMessageSent,
              ensureUploadSession() else { return }
        // The one-time marker is claimed only after the capture request exists,
        // not before: a body that cannot be built must not consume the real
        // first message.
        guard capture(.firstMessageSent) else { return }
        firstEvents.claimFirstMessageSent()
    }

    @discardableResult
    private func capture(_ event: TelemetryEvent) -> Bool {
        guard usageDataEnabled,
              let key = TelemetrySanitizer.apiKey(configuration.postHogKey),
              let url = configuration.postHogURL,
              let diagnosticID = diagnosticIDForSending(),
              let body = PostHogPayload.capture(apiKey: key, event: event,
                                                 distinctID: diagnosticID,
                                                 context: context) else {
            return false
        }
        ensureUploadSession()
        guard let session = uploadSession else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("AtumMobile/\(TelemetrySanitizer.version(context.appVersion))",
                         forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request).resume()
        return true
    }

    private var context: TelemetryContext {
        TelemetryContext(appVersion: configuration.appVersion,
                         buildNumber: configuration.buildNumber,
                         osVersion: configuration.osVersion,
                         environment: configuration.environment)
    }

    private func diagnosticIDForSending() -> String? {
        if let diagnosticID { return diagnosticID }
        let installation = TelemetryInstallation.loadOrCreate(in: defaults)
        let value = TelemetryInstallation.analyticsID(for: installation)
        diagnosticID = value
        return value
    }

    @discardableResult
    private func ensureUploadSession() -> Bool {
        guard usageDataEnabled else { return false }
        if uploadSession != nil { return true }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        uploadSession = URLSession(configuration: configuration)
        return true
    }

    private func startCrashReports() {
        #if canImport(Sentry)
        guard !configuration.sentryDSN.isEmpty, !sentryStarted else { return }
        crashGate.setAllowed(true)
        // Copy build values out of this @MainActor instance before installing
        // Sentry's callbacks. The configure closure, beforeSend and
        // beforeBreadcrumb are @Sendable because the SDK invokes them from a
        // background queue; capturing self or an actor-isolated member here
        // would make Swift 6 insert a main-actor check on that queue.
        let dsn = configuration.sentryDSN
        let environment = TelemetrySanitizer.environment(configuration.environment)
        let version = TelemetrySanitizer.version(configuration.appVersion)
        let release = "atum-mobile@\(version)"
            + "+\(TelemetrySanitizer.build(configuration.buildNumber))"
        let dist = TelemetrySanitizer.build(configuration.buildNumber)
        let gate = crashGate
        SentrySDK.start { @Sendable options in
            options.dsn = dsn
            options.environment = environment
            options.releaseName = release
            options.dist = dist
            options.sendDefaultPii = false
            options.attachStacktrace = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableUserInteractionTracing = false
            options.enableAppHangTracking = false
            options.enableSwizzling = false
            options.beforeBreadcrumb = { @Sendable _ in nil }
            options.beforeSend = { @Sendable event in
                gate.isAllowed ? LiveReporting.scrub(event) : nil
            }
        }
        sentryStarted = true
        #endif
    }

    private func stopCrashReports() {
        #if canImport(Sentry)
        guard sentryStarted else { return }
        SentrySDK.close()
        sentryStarted = false
        #endif
    }

    #if canImport(Sentry)
    /// Crash events keep only their type, mechanism type and shipped code
    /// frames. The rule set lives in AtumTelemetry as a plain-value function;
    /// this method is only the Sentry adapter in and out of that shape.
    nonisolated private static func scrub(_ event: Event) -> Event? {
        let snapshot = ScrubbableCrashEvent(
            message: event.message?.formatted,
            hasUser: event.user != nil,
            hasRequest: event.request != nil,
            breadcrumbCount: event.breadcrumbs?.count ?? 0,
            extraKeyCount: event.extra?.count ?? 0,
            transaction: event.transaction,
            tags: event.tags ?? [:],
            exceptions: (event.exceptions ?? []).map { exception in
                ScrubbableCrashEvent.Exception(
                    type: exception.type,
                    value: exception.value,
                    mechanism: exception.mechanism.map {
                        ScrubbableCrashEvent.Mechanism(type: $0.type,
                                                       hasData: $0.data?.isEmpty == false)
                    },
                    frames: exception.stacktrace?.frames.map(plain)
                )
            },
            threads: (event.threads ?? []).map { thread in
                ScrubbableCrashEvent.Thread(name: thread.name,
                                            frames: thread.stacktrace?.frames.map(plain))
            },
            debugImages: (event.debugMeta ?? []).map {
                ScrubbableCrashEvent.DebugImage(codeFile: $0.codeFile)
            }
        )
        let clean = CrashEventScrubber.scrub(snapshot)

        event.message = clean.message.map { SentryMessage(formatted: $0) }
        if !clean.hasUser { event.user = nil }
        if !clean.hasRequest { event.request = nil }
        if clean.breadcrumbCount == 0 { event.breadcrumbs = nil }
        if clean.extraKeyCount == 0 { event.extra = nil }
        event.transaction = clean.transaction
        event.tags = clean.tags.isEmpty ? nil : clean.tags
        event.exceptions = event.exceptions?.enumerated().map { index, exception in
            guard index < clean.exceptions.count else { return exception }
            let cleanException = clean.exceptions[index]
            exception.value = cleanException.value
            exception.mechanism?.data = cleanException.mechanism?.hasData == true
                ? exception.mechanism?.data : nil
            apply(cleanException.frames, to: exception.stacktrace)
            return exception
        }
        event.threads = event.threads?.enumerated().map { index, thread in
            guard index < clean.threads.count else { return thread }
            let cleanThread = clean.threads[index]
            thread.name = cleanThread.name
            apply(cleanThread.frames, to: thread.stacktrace)
            return thread
        }
        if let images = event.debugMeta {
            event.debugMeta = images.enumerated().map { index, image in
                if index < clean.debugImages.count {
                    image.codeFile = clean.debugImages[index].codeFile
                }
                return image
            }
        }
        return event
    }

    nonisolated private static func plain(_ frame: Frame) -> ScrubbableCrashEvent.Frame {
        ScrubbableCrashEvent.Frame(fileName: frame.fileName, package: frame.package,
                                   contextLine: frame.contextLine)
    }

    nonisolated private static func apply(_ cleanFrames: [ScrubbableCrashEvent.Frame]?,
                                         to stacktrace: SentryStacktrace?) {
        guard let cleanFrames, let stacktrace else { return }
        stacktrace.frames = zip(stacktrace.frames, cleanFrames).map { frame, cleanFrame in
            frame.fileName = cleanFrame.fileName
            frame.package = cleanFrame.package
            frame.contextLine = cleanFrame.contextLine
            return frame
        }
    }
    #endif
}
