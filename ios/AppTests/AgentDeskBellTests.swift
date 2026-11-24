import AtumChat
import AtumDesign
import Darwin
import os
import SwiftUI
import UIKit
import XCTest
@testable import AtumMobile
@testable import AtumNativeAPI

/// W4-E3: the agent's desk (desktop #51) and Home's bell (desktop #48) take
/// every word from the pinned export, in every locale, with no pending table.
final class AgentDeskBellTests: XCTestCase {
    private let deskKeys = ["desk", "working", "waiting", "minutes", "steerHint", "queueHint", "files", "sentHere",
                            "save", "saveShort", "more", "less", "onItsComputer", "back", "controls",
                            "notifications", "moreControls", "routines", "paused", "nextRun", "allSettings",
                            "pause", "pauseHint", "controlFailed", "computerOff"]

    private func arguments(_ name: String) -> [AtumCopy.Argument] {
        switch name {
        case "desk", "save", "nextRun": [.text("X")]
        case "minutes": [.number(4)]
        default: []
        }
    }

    func testEveryDeskWordIsInThePinForEveryLocale() throws {
        let pin = try AtumCopy()
        let keys = deskKeys.map { (AgentDeskCopy.key($0), arguments($0)) } + [(AgentDeskCopy.refresh, [])]
        for (key, arguments) in keys {
            XCTAssertTrue(pin.contains(key), key)
            for locale in pin.locales {
                let value = try pin.text(key, locale: locale, arguments: arguments)
                XCTAssertFalse(value.isEmpty, "\(key) \(locale)")
            }
        }
        XCTAssertEqual(try pin.text(AgentDeskCopy.key("minutes"), locale: "en", arguments: [.number(4)]), "4 min")
        XCTAssertEqual(try pin.text(AgentDeskCopy.key("desk"), locale: "vi", arguments: [.text("Luna")]),
                       "Bàn làm việc của Luna")
    }

    func testEveryBellWordIsInThePinForEveryLocale() throws {
        let pin = try AtumCopy()
        let keys = [AttentionBellPolicy.notificationsKey, AttentionBellPolicy.nothingKey,
                    AttentionBellPolicy.prefixKey] + AttentionBellPolicy.Kind.allCases.map(AttentionBellPolicy.labelKey)
        for key in keys {
            XCTAssertTrue(pin.contains(key), key)
            for locale in pin.locales { XCTAssertFalse(try pin.text(key, locale: locale).isEmpty, "\(key) \(locale)") }
        }
        XCTAssertEqual(try pin.text(AttentionBellPolicy.countKey, locale: "vi", arguments: [.number(2)]), "2 việc cần bạn")
        XCTAssertEqual(try pin.text(AttentionBellPolicy.labelKey(.protons), locale: "en"), "Out of Protons")
    }

    func testTheDeskNamesASentFileByItsOwnNameAndTimesShortly() {
        let item = ChatItem(id: "f", kind: .file(name: "plan.pdf"), body: "plan.pdf",
                            media: ChatMedia(sourceHandle: "mxc://f", filename: "Q4 plan.pdf"))
        XCTAssertEqual(AgentDeskPage.fileName(item), "Q4 plan.pdf")
        XCTAssertEqual(AgentDeskPage.fileName(ChatItem(id: "g", kind: .file(name: "a.txt"), body: "x")), "a.txt")
        XCTAssertFalse(AgentDeskPage.when(Date(), locale: "vi").isEmpty)
        XCTAssertFalse(AgentDeskPage.nextRun(Date(), locale: "en").isEmpty)
    }

    @MainActor
    func testChecklistExposesCompletionAsAnAccessibilityValue() async throws {
        let restoreAccessibility = try enableAccessibilityAutomation()
        defer { restoreAccessibility() }
        let design = try LiveDesign()
        let steps = [WorkingLineText.Step(text: "Find sources", done: true),
                     WorkingLineText.Step(text: "Write summary", done: false)]
        let now = AgentDeskNow(design: design, now: .working(since: nil, line: "Working on it", steps: steps), steers: true)
        let host = UIHostingController(rootView: now)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        window.layoutIfNeeded()
        host.view.layoutIfNeeded()

        await until({ self.accessibilityElement(in: host.view, labeled: steps[0].text) != nil }, "checklist is missing")
        let percent = FloatingPointFormatStyle<Double>.Percent().locale(Locale(identifier: design.locale))
        for step in steps {
            let row = try XCTUnwrap(accessibilityElement(in: host.view, labeled: step.text))
            XCTAssertEqual(row.accessibilityValue, (step.done ? 1.0 : 0.0).formatted(percent))
            XCTAssertFalse(row.accessibilityTraits.contains(.selected))
        }
        let line = try XCTUnwrap(accessibilityElement(in: host.view, labeled: "Working on it"))
        XCTAssertTrue((line.accessibilityValue ?? "").isEmpty)
    }

    /// Enable the rendered UIKit accessibility tree inside this unit test process.
    private func enableAccessibilityAutomation() throws -> () -> Void {
        let simulatorRoot = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let library = try XCTUnwrap(dlopen(simulatorRoot + "/usr/lib/libAccessibility.dylib", RTLD_LAZY | RTLD_LOCAL))
        guard let get = dlsym(library, "_AXSAutomationEnabled"), let set = dlsym(library, "_AXSSetAutomationEnabled") else {
            dlclose(library)
            throw XCTSkip("This runtime does not expose accessibility automation to the test host")
        }
        let initial = unsafeBitCast(get, to: (@convention(c) () -> Int32).self)()
        let setEnabled = unsafeBitCast(set, to: (@convention(c) (Int32) -> Void).self)
        setEnabled(1)
        return {
            setEnabled(initial)
            dlclose(library)
        }
    }

    @MainActor
    private func accessibilityElement(in root: NSObject, labeled label: String) -> NSObject? {
        if root.isAccessibilityElement, root.accessibilityLabel == label { return root }
        let children: [Any]
        if let elements = root.accessibilityElements {
            children = elements
        } else {
            let count = root.accessibilityElementCount()
            children = count > 0 && count != NSNotFound
                ? (0..<count).compactMap { root.accessibilityElement(at: $0) }
                : (root as? UIView)?.subviews ?? []
        }
        for case let child as NSObject in children {
            if let element = accessibilityElement(in: child, labeled: label) { return element }
        }
        return nil
    }

    // MARK: The desk's host state (r2 review)

    @MainActor
    private final class Host {
        var files: [String: [HostAgentDesk.FilesOutcome]] = [:]
        var fileReads: [String?] = []
        var controls: [HostAgentDesk.Control] = []
        var outcomes: [HostAgentDesk.ControlOutcome] = []
        var gate: CheckedContinuation<Void, Never>?
        var holdControls = false
        var scheduleReads = 0
        var busyScheduleReads = 0
        var schedule = HostAgentDesk.Schedule(jobs: [
            .init(id: "a", name: "A", state: .scheduled), .init(id: "b", name: "B", state: .scheduled)])

        func actions() -> AgentDeskActions {
            AgentDeskActions(
                agentUserID: "@luna:atum.test", steers: true,
                schedule: { [self] in
                    scheduleReads += 1
                    if busyScheduleReads > 0 {
                        busyScheduleReads -= 1
                        throw HostAgentDesk.ReadBusy()
                    }
                    return schedule
                },
                files: { [self] path in
                    fileReads.append(path)
                    let key = path ?? ""
                    guard var queue = files[key], !queue.isEmpty else { return .failed }
                    let next = queue.removeFirst()
                    files[key] = queue
                    return next
                },
                control: { [self] control in
                    controls.append(control)
                    if holdControls { await withCheckedContinuation { gate = $0 } }
                    return outcomes.isEmpty ? .changed(1) : outcomes.removeFirst()
                })
        }
    }

    private static func listing(_ path: String, _ names: [String]) -> HostAgentDesk.Files {
        let parts = path.split(separator: "/").map(String.init)
        return HostAgentDesk.Files(root: parts[0] == "work" ? .work : .home,
                                   path: parts.dropFirst().joined(separator: "/"),
                                   rows: names.map { .init(name: $0, kind: .folder) })
    }

    @MainActor
    private func until(_ condition: @MainActor () -> Bool, _ message: String) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), message)
    }

    @MainActor
    func testAFolderOpenedInsideTheReadCooldownWaitsAndShowsOnlyWhenListed() async {
        let host = Host()
        host.files = ["": [.listed(Self.listing("home", ["reports"]))],
                      "home/reports": [.busy, .listed(Self.listing("home/reports", ["q3"]))]]
        let model = AgentDeskModel(actions: host.actions(), readRetryDelay: .milliseconds(80))
        model.appear()
        await until({ model.ownView != nil }, "home never listed")
        model.open("home/reports")
        await until({ host.fileReads.count == 2 }, "the folder was not asked for")
        // Busy: the home listing stays, with its own path, until the folder's own arrives.
        XCTAssertNil(model.ownPath)
        XCTAssertEqual(model.ownView?.deskPath, "home")
        // A second tap while it waits does not restart it inside the cooldown.
        model.open("home/reports")
        await until({ model.ownPath == "home/reports" }, "the busy folder was never asked again")
        XCTAssertEqual(model.ownView?.rows.map(\.name), ["q3"])
        XCTAssertEqual(host.fileReads, [nil, "home/reports", "home/reports"])
        // Back is the confirmed home listing, with no read inside the cooldown.
        model.back()
        XCTAssertNil(model.ownPath)
        XCTAssertEqual(model.ownView?.deskPath, "home")
        XCTAssertEqual(host.fileReads.count, 3)
    }

    @MainActor
    func testARefusedFolderCanBeOpenedAgain() async {
        let host = Host()
        host.files = ["": [.listed(Self.listing("home", ["reports"]))],
                      "home/reports": [.failed, .listed(Self.listing("home/reports", ["q3"]))]]
        let model = AgentDeskModel(actions: host.actions(), readRetryDelay: .milliseconds(10))
        model.appear()
        await until({ model.ownView != nil }, "home never listed")
        model.open("home/reports")
        await until({ host.fileReads.count == 2 && model.ownTarget == nil }, "the refusal did not settle")
        XCTAssertEqual(model.ownView?.deskPath, "home", "a refused folder keeps the shown one")
        model.open("home/reports")
        await until({ model.ownPath == "home/reports" }, "the same folder never opened again")
    }

    @MainActor
    func testForwardNavigationRefetchesAPreviouslyOpenedFolder() async {
        let host = Host()
        let reports = "home/reports"
        host.files = ["": [.listed(Self.listing("home", ["reports"]))],
                      reports: [.listed(Self.listing(reports, ["q3"])), .listed(Self.listing(reports, ["q4"]))]]
        let model = AgentDeskModel(actions: host.actions())
        model.appear()
        await until({ model.ownView != nil }, "home never listed")
        model.open(reports)
        await until({ model.ownView?.rows.map(\.name) == ["q3"] }, "the first listing never arrived")

        model.back()
        XCTAssertNil(model.ownPath)
        XCTAssertEqual(model.ownView?.deskPath, "home")
        model.open(reports)
        await until({ model.ownView?.rows.map(\.name) == ["q4"] }, "the refreshed listing never arrived")
        XCTAssertEqual(host.fileReads, [nil, reports, reports])
    }

    @MainActor
    func testControlsReachTheHostOneAtATimeAndUndoOnlyTheirOwnChange() async {
        let host = Host()
        host.holdControls = true
        host.outcomes = [.failed]
        let model = AgentDeskModel(actions: host.actions(), controlRetryDelay: .milliseconds(10))
        model.appear()
        await until({ model.jobs != nil }, "no schedule")
        model.run(.routineOff(job: "a"))
        XCTAssertTrue(model.controlPending)
        XCTAssertEqual(model.jobs?.map(\.state), [.paused, .scheduled])
        // B waits for A: no second control is sent while one settles.
        model.run(.routineOff(job: "b"))
        model.run(.pause)
        await until({ host.gate != nil }, "A was not sent")
        XCTAssertEqual(host.controls, [.routineOff(job: "a")])
        XCTAssertEqual(model.jobs?.map(\.state), [.paused, .scheduled])
        // A fails ambiguously, and the host's schedule confirms its original state.
        host.gate?.resume()
        await until({ !model.controlPending }, "A never settled")
        XCTAssertEqual(model.problem, .failed)
        XCTAssertEqual(model.jobs?.map(\.state), [.scheduled, .scheduled])
        XCTAssertEqual(host.scheduleReads, 2)
    }

    @MainActor
    func testAmbiguousControlFailureRetriesABusyScheduleAndUsesHostState() async {
        let host = Host()
        host.outcomes = [.failed]
        let model = AgentDeskModel(actions: host.actions().fenced(by: { true }), readRetryDelay: .milliseconds(10))
        model.appear()
        await until({ model.jobs != nil }, "no schedule")

        host.schedule = HostAgentDesk.Schedule(jobs: [
            .init(id: "a", name: "A", state: .paused), .init(id: "b", name: "B", state: .scheduled)])
        host.busyScheduleReads = 1
        model.run(.routineOff(job: "a"))
        await until({ !model.controlPending }, "the schedule never reconciled")

        XCTAssertEqual(host.scheduleReads, 3)
        XCTAssertEqual(host.controls, [.routineOff(job: "a")])
        XCTAssertEqual(model.jobs, host.schedule.jobs)
    }

    @MainActor
    func testFailedPauseKeepsControlsDisabledUntilAManualRefreshConfirmsTheSchedule() async {
        let host = Host()
        host.outcomes = [.failed]
        let model = AgentDeskModel(actions: host.actions(), readRetryDelay: .milliseconds(200))
        model.appear()
        defer { model.disappear() }
        await until({ model.canControl }, "the initial schedule did not load")

        host.schedule = HostAgentDesk.Schedule(jobs: [
            .init(id: "a", name: "A", state: .paused, pausedReason: "owner_pause"),
            .init(id: "b", name: "B", state: .paused, pausedReason: "owner_pause")])
        host.busyScheduleReads = 2
        model.run(.pause)
        await until({ host.scheduleReads >= 2 }, "the failed Pause never reconciled")
        XCTAssertTrue(model.controlsDisabled)
        XCTAssertTrue(HostAgentDesk.isPaused(model.jobs), "the busy read must not restore the pre-Pause values")

        await until({ model.canRefreshSchedule }, "refresh was not offered after the retry")
        XCTAssertEqual(host.scheduleReads, 3)
        XCTAssertFalse(model.controlPending)
        XCTAssertTrue(model.controlsDisabled)
        model.run(.resume)
        model.refreshSchedule()
        model.refreshSchedule()
        XCTAssertTrue(model.controlsDisabled)
        XCTAssertFalse(model.canRefreshSchedule)

        await until({ !model.controlsDisabled }, "the confirmed schedule did not restore the switches")
        XCTAssertEqual(model.jobs, host.schedule.jobs)
        XCTAssertFalse(model.canRefreshSchedule)
        XCTAssertEqual(host.scheduleReads, 4)
        XCTAssertEqual(host.controls, [.pause])
        XCTAssertNil(model.problem, "the confirmed schedule replaces the earlier failure")
    }

    @MainActor
    func testFailedEntryReadOffersRefresh() async {
        let host = Host()
        host.busyScheduleReads = 2
        let model = AgentDeskModel(actions: host.actions(), readRetryDelay: .milliseconds(50))
        model.appear()
        defer { model.disappear() }
        await until({ model.canRefreshSchedule }, "refresh was not offered after the entry read failed")
        XCTAssertFalse(model.canControl)
        XCTAssertEqual(host.scheduleReads, 2)

        model.refreshSchedule()
        await until({ model.canControl && !model.controlsDisabled }, "refresh did not load the schedule")
        XCTAssertEqual(model.jobs, host.schedule.jobs)
        XCTAssertFalse(model.canRefreshSchedule)
    }

    @MainActor
    func testReopeningDuringTheScheduleCooldownRestoresControls() async throws {
        DeskScheduleProtocol.setReplies([
            (200, Self.scheduleReply(.scheduled)), (429, Data()), (429, Data()), (200, Self.scheduleReply(.paused)),
        ])
        let client = NativeDomainClient(testAuthorization: { _ in "desk-fixture" },
                                        protocolClasses: [DeskScheduleProtocol.self])
        let agent = try NativeID("01234567-89ab-4def-8123-456789abcdef")
        let current: NativeDomainClient.DeskSendCheck = { true }
        let host = Host()
        host.outcomes = [.failed]
        var actions = host.actions()
        let read = AgentDeskActions.liveSchedule(client: client, agent: agent, current: current)
        var startedReads = 0
        var completedReads = 0
        actions.schedule = {
            startedReads += 1
            defer { completedReads += 1 }
            return try await read()
        }
        actions = actions.fenced(by: current)

        let desk = AgentDeskModel(actions: actions, readRetryDelay: .seconds(1))
        desk.appear()
        await until({ desk.canControl }, "the initial schedule did not load")
        desk.run(.routineOff(job: "a"))
        await until({ completedReads == 2 && desk.controlPending }, "the failed control never reached a busy read")
        desk.disappear()

        let reopened = AgentDeskModel(actions: actions, readRetryDelay: .milliseconds(30))
        reopened.appear()
        defer { reopened.disappear() }
        await until({ reopened.canControl }, "the reopened desk did not recover from its busy read")
        XCTAssertEqual(reopened.jobs?.map(\.state), [.paused])
        XCTAssertFalse(reopened.controlsDisabled)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(startedReads, 4, "the closed desk sent another request after its retry delay")
        XCTAssertEqual(host.controls, [.routineOff(job: "a")])
    }

    private static func scheduleReply(_ state: HostAgentDesk.Job.State) -> Data {
        Data(#"""
        {"read":"schedule","observedAt":1,"truncated":false,"jobs":[
         {"id":"a","name":"A","kind":"cron","display":"0 8 * * *","timezone":null,
          "state":"\#(state.rawValue)","nextRunAt":null,"lastRunAt":null,"lastStatus":null,
          "expr":null,"minutes":null,"runAt":null}]}
        """#.utf8)
    }

    @MainActor
    func testTheDelayedRetryIsNeverSentAfterTheDeskCloses() async {
        let host = Host()
        host.outcomes = [.busy, .changed(1)]
        let model = AgentDeskModel(actions: host.actions(), controlRetryDelay: .milliseconds(150))
        model.appear()
        await until({ model.jobs != nil }, "no schedule")
        model.run(.pause)
        await until({ host.controls.count == 1 }, "Pause was not sent")
        model.disappear()
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(host.controls, [.pause], "the retry was sent after the desk closed")
        XCTAssertFalse(model.controlPending)
    }

    @MainActor
    func testNoHostCallIsSentOnceTheAccountOrAgentChanged() async {
        let host = Host()
        host.files = ["": [.listed(Self.listing("home", []))]]
        var current = false
        let actions = host.actions().fenced(by: { current })
        // Not current: nothing reaches the host at all.
        let refusedSchedule = try? await actions.schedule?()
        let refusedFiles = await actions.files?(nil)
        let refusedControl = await actions.control?(.pause)
        XCTAssertNil(refusedSchedule)
        XCTAssertEqual(refusedFiles, .cancelled)
        XCTAssertEqual(refusedControl, .cancelled)
        XCTAssertEqual(host.scheduleReads, 0)
        XCTAssertEqual(host.fileReads, [])
        XCTAssertEqual(host.controls, [])
        // Current: sent; a change while it was on its way drops the reply.
        current = true
        host.holdControls = true
        let pending = Task { @MainActor in await actions.control?(.pause) }
        await until({ host.gate != nil }, "not sent while current")
        current = false
        host.gate?.resume()
        let dropped = await pending.value
        XCTAssertEqual(dropped, .cancelled)
        XCTAssertEqual(host.controls, [.pause])
    }
}

/// Only the test client's session uses this protocol. It feeds real HTTP status codes to `NativeDomainClient`.
private final class DeskScheduleProtocol: URLProtocol, @unchecked Sendable {
    private static let replies = OSAllocatedUnfairLock(initialState: [(Int, Data)]())

    static func setReplies(_ replies: [(Int, Data)]) {
        Self.replies.withLock { $0 = replies }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, url.path == HostAgentDesk.deskPath,
              let reply = Self.replies.withLock({ $0.isEmpty ? nil : $0.removeFirst() }),
              let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
