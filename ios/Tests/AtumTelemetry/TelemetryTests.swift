import XCTest
import AtumTelemetry

final class TelemetryConsentTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AtumTelemetryTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshInstallReportsBothByDefault() {
        let consent = TelemetryConsent(defaults: defaults)

        XCTAssertTrue(consent.crashReportsEnabled)
        XCTAssertTrue(consent.usageDataEnabled)
    }

    func testTurningCrashReportsOffPersistsAcrossLaunches() {
        TelemetryConsent(defaults: defaults).setCrashReportsEnabled(false)

        let relaunched = TelemetryConsent(defaults: defaults)

        XCTAssertFalse(relaunched.crashReportsEnabled)
        XCTAssertTrue(relaunched.usageDataEnabled, "each switch is independent")
    }

    func testTurningUsageDataOffPersistsAcrossLaunches() {
        TelemetryConsent(defaults: defaults).setUsageDataEnabled(false)

        let relaunched = TelemetryConsent(defaults: defaults)

        XCTAssertFalse(relaunched.usageDataEnabled)
        XCTAssertTrue(relaunched.crashReportsEnabled, "each switch is independent")
    }

    func testTurningASwitchBackOnPersistsTheOptIn() {
        let consent = TelemetryConsent(defaults: defaults)
        consent.setCrashReportsEnabled(false)
        consent.setCrashReportsEnabled(true)
        consent.setUsageDataEnabled(false)
        consent.setUsageDataEnabled(true)

        let relaunched = TelemetryConsent(defaults: defaults)

        XCTAssertTrue(relaunched.crashReportsEnabled)
        XCTAssertTrue(relaunched.usageDataEnabled)
    }

    func testDamagedOrForeignValueDoesNotBecomeASilentOptOut() {
        defaults.set("not a boolean", forKey: TelemetryConsent.crashReportsKey)
        defaults.set(1, forKey: TelemetryConsent.usageDataKey)

        let consent = TelemetryConsent(defaults: defaults)

        XCTAssertTrue(consent.crashReportsEnabled)
        XCTAssertTrue(consent.usageDataEnabled)
    }

    func testAnalyticsIDIsStableHashedAndNeverTheRawInstallation() {
        let installation = TelemetryInstallation.loadOrCreate(in: defaults)
        let diagnostic = TelemetryInstallation.analyticsID(for: installation)

        XCTAssertEqual(TelemetryInstallation.loadOrCreate(in: defaults), installation)
        XCTAssertEqual(diagnostic, TelemetryInstallation.analyticsID(for: installation))
        XCTAssertEqual(diagnostic.count, 32)
        XCTAssertNotNil(diagnostic.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        XCTAssertNotEqual(diagnostic, installation.uuidString.lowercased())
        XCTAssertFalse(diagnostic.contains(installation.uuidString.prefix(8)))
    }

    func testFirstMessageIsClaimedOnceAndStaysClaimed() {
        let first = TelemetryFirstEventStore(defaults: defaults)

        XCTAssertFalse(first.hasClaimedFirstMessageSent)
        XCTAssertTrue(first.claimFirstMessageSent())
        XCTAssertTrue(first.hasClaimedFirstMessageSent)
        XCTAssertFalse(first.claimFirstMessageSent())
        XCTAssertFalse(TelemetryFirstEventStore(defaults: defaults).claimFirstMessageSent())
    }
}

final class TelemetryPayloadTests: XCTestCase {
    private let context = TelemetryContext(appVersion: "1.0.0", buildNumber: "42",
                                           osVersion: "26.0.1", environment: "production")
    private let diagnosticID = String(repeating: "a", count: 32)

    private func object(from data: Data?) throws -> [String: Any] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testPayloadContainsOnlyAllowlistedKeysAndAnonymousBuildFacts() throws {
        let body = try object(from: PostHogPayload.capture(
            apiKey: "phc_test_project_key", event: .appOpened,
            distinctID: diagnosticID, context: context,
            timestamp: Date(timeIntervalSince1970: 0)
        ))

        XCTAssertEqual(Set(body.keys), ["api_key", "event", "distinct_id", "timestamp", "properties"])
        XCTAssertEqual(body["event"] as? String, "app_opened")
        XCTAssertEqual(body["distinct_id"] as? String, diagnosticID)

        let properties = try XCTUnwrap(body["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), [
            "$geoip_disable", "$ip", "$lib", "schema_version", "app_version",
            "build_number", "os_version", "environment",
        ])
        XCTAssertEqual(properties["$geoip_disable"] as? Bool, true)
        XCTAssertTrue(properties["$ip"] is NSNull, "an explicit null keeps the capture from storing an IP")
        XCTAssertEqual(properties["$lib"] as? String, "atum-mobile")
        XCTAssertEqual(properties["app_version"] as? String, "1.0.0")
        XCTAssertEqual(properties["build_number"] as? String, "42")
        XCTAssertEqual(properties["os_version"] as? String, "26.0.1")
        XCTAssertEqual(properties["environment"] as? String, "production")
    }

    func testSignInPayloadCarriesOnlyTheClosedOutcome() throws {
        let body = try object(from: PostHogPayload.capture(
            apiKey: "phc_test_project_key", event: .signInFinished(.completed),
            distinctID: diagnosticID, context: context
        ))
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])

        XCTAssertEqual(properties["outcome"] as? String, "completed")
        XCTAssertNil(properties["account"])
        XCTAssertNil(properties["email"])
        XCTAssertNil(properties["message"])
        XCTAssertNil(properties["room"])
    }

    func testUnsafeContextValuesAreScrubbedBeforeTheyReachTheWire() throws {
        let unsafe = TelemetryContext(
            appVersion: "/home/example/Projects/Atum 1.0",
            buildNumber: "42 (alice@example.com)",
            osVersion: "26.0 alice",
            environment: "Production\n/home/example"
        )
        let body = try object(from: PostHogPayload.capture(
            apiKey: "phc_test_project_key", event: .firstMessageSent,
            distinctID: diagnosticID, context: unsafe
        ))
        let properties = try XCTUnwrap(body["properties"] as? [String: Any])

        XCTAssertEqual(properties["app_version"] as? String, "unknown")
        XCTAssertEqual(properties["build_number"] as? String, "unknown")
        XCTAssertEqual(properties["os_version"] as? String, "unknown")
        XCTAssertEqual(properties["environment"] as? String, "development")
        let encoded = String(decoding: try XCTUnwrap(PostHogPayload.capture(
            apiKey: "phc_test_project_key", event: .appOpened,
            distinctID: diagnosticID, context: unsafe
        )), as: UTF8.self)
        XCTAssertFalse(encoded.contains("alice"))
        XCTAssertFalse(encoded.contains("example.com"))
    }

    func testOnlyARealAnonymousIDAndAPIKeyProduceAPayload() {
        XCTAssertNil(PostHogPayload.capture(apiKey: "", event: .appOpened,
                                            distinctID: diagnosticID, context: context))
        XCTAssertNil(PostHogPayload.capture(apiKey: "phc_test_project_key", event: .appOpened,
                                            distinctID: UUID().uuidString.lowercased(), context: context))
        XCTAssertNil(PostHogPayload.capture(apiKey: "phc_test_project_key", event: .appOpened,
                                            distinctID: diagnosticID.uppercased(), context: context))
        XCTAssertNil(PostHogPayload.capture(apiKey: "phc_test_project_key", event: .appOpened,
                                            distinctID: "@alice:example.invalid", context: context))
    }

    func testEventNamesAreTheThreeAuditedNames() {
        XCTAssertEqual(TelemetryEvent.allowedNames,
                       ["app_opened", "signin_finished", "first_message_sent"])
        XCTAssertEqual(TelemetryEvent.appOpened.name, "app_opened")
        XCTAssertEqual(TelemetryEvent.signInFinished(.failed).name, "signin_finished")
        XCTAssertEqual(TelemetryEvent.firstMessageSent.name, "first_message_sent")
        XCTAssertNil(TelemetryEvent.appOpened.signInOutcome)
        XCTAssertEqual(TelemetryEvent.signInFinished(.cancelled).signInOutcome, .cancelled)
    }

    func testSourcePathsKeepOnlyTheFileName() {
        XCTAssertEqual(TelemetrySanitizer.fileName("/home/example/Projects/Atum/App/Foo.swift"), "Foo.swift")
        XCTAssertEqual(TelemetrySanitizer.fileName("file:///private/var/containers/App/Foo.swift"), "Foo.swift")
        XCTAssertEqual(TelemetrySanitizer.fileName(""), "unknown")
        XCTAssertEqual(TelemetrySanitizer.fileName("/"), "unknown")
    }
}


final class CrashEventScrubberTests: XCTestCase {
    func testContentAndIdentityFieldsAreRemoved() {
        let event = ScrubbableCrashEvent(
            message: "alice@example.com said something private",
            hasUser: true, hasRequest: true, breadcrumbCount: 4, extraKeyCount: 2,
            transaction: "private-room",
            tags: ["account": "alice", "room": "!secret"],
            exceptions: [
                .init(type: "NSException", value: "body with alice",
                      mechanism: .init(type: "mach", hasData: true),
                      frames: [.init(fileName: "/home/example/project/Foo.swift",
                                     package: "/home/example/project",
                                     contextLine: "let secret = user.message")])
            ],
            threads: [
                .init(name: "alice-main", frames: [
                    .init(fileName: "/home/example/project/Bar.swift",
                          package: "/home/example/project", contextLine: "token")
                ])
            ],
            debugImages: [.init(codeFile: "/home/example/project/Atum")]
        )

        let clean = CrashEventScrubber.scrub(event)

        XCTAssertNil(clean.message)
        XCTAssertFalse(clean.hasUser)
        XCTAssertFalse(clean.hasRequest)
        XCTAssertEqual(clean.breadcrumbCount, 0)
        XCTAssertEqual(clean.extraKeyCount, 0)
        XCTAssertNil(clean.transaction)
        XCTAssertTrue(clean.tags.isEmpty)
        XCTAssertEqual(clean.exceptions.first?.value, "NSException")
        XCTAssertEqual(clean.exceptions.first?.mechanism?.type, "mach")
        XCTAssertFalse(clean.exceptions.first?.mechanism?.hasData ?? true)
        XCTAssertEqual(clean.exceptions.first?.frames?.first?.fileName, "Foo.swift")
        XCTAssertNil(clean.exceptions.first?.frames?.first?.package)
        XCTAssertNil(clean.exceptions.first?.frames?.first?.contextLine)
        XCTAssertNil(clean.threads.first?.name)
        XCTAssertEqual(clean.threads.first?.frames?.first?.fileName, "Bar.swift")
        XCTAssertNil(clean.threads.first?.frames?.first?.package)
        XCTAssertEqual(clean.debugImages.first?.codeFile, "Atum")
    }

    func testScrubIsIdempotentAndKeepsSafeValues() {
        let clean = ScrubbableCrashEvent(
            exceptions: [.init(type: "SIGSEGV", value: "SIGSEGV",
                               mechanism: .init(type: "signal", hasData: false),
                               frames: [.init(fileName: "Atum", package: nil, contextLine: nil)])],
            threads: [.init(name: nil, frames: [.init(fileName: "libsystem_kernel.dylib")])],
            debugImages: [.init(codeFile: "Atum")]
        )

        XCTAssertEqual(CrashEventScrubber.scrub(clean), clean)
    }

    func testUnsafePathsBecomeUnknownInsteadOfLeaking() {
        let clean = CrashEventScrubber.scrub(ScrubbableCrashEvent(
            exceptions: [.init(type: "Error", value: "Error",
                               frames: [.init(fileName: "/", package: nil, contextLine: nil)])],
            debugImages: [.init(codeFile: String(repeating: "a", count: 200))]
        ))

        XCTAssertEqual(clean.exceptions.first?.frames?.first?.fileName, "unknown")
        XCTAssertEqual(clean.debugImages.first?.codeFile, "unknown")
    }
}
