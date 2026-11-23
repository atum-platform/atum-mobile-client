import AtumChat
import AtumDesign
import AtumNativeAPI
import XCTest
@testable import AtumMobile

/// W4-E3: the agent's desk (desktop #51) and Home's bell (desktop #48) take
/// every word from the pinned export, in every locale, with no pending table.
final class AgentDeskBellTests: XCTestCase {
    private let deskKeys = ["desk", "working", "waiting", "minutes", "steerHint", "queueHint", "files", "sentHere",
                            "save", "saveShort", "more", "less", "onItsComputer", "back", "controls",
                            "notifications", "moreControls", "routines", "paused", "nextRun", "allSettings",
                            "pause", "controlFailed", "computerOff"]

    private func arguments(_ name: String) -> [AtumCopy.Argument] {
        switch name {
        case "desk", "save", "nextRun": [.text("X")]
        case "minutes": [.number(4)]
        default: []
        }
    }

    func testEveryDeskWordIsInThePinForEveryLocale() throws {
        let pin = try AtumCopy()
        for name in deskKeys {
            let key = AgentDeskCopy.key(name)
            XCTAssertTrue(pin.contains(key), key)
            for locale in pin.locales {
                let value = try pin.text(key, locale: locale, arguments: arguments(name))
                XCTAssertFalse(value.isEmpty, "\(key) \(locale)")
            }
        }
        // Pending: when a repin carries it, move it into `deskKeys` and drop the guard.
        for name in AgentDeskCopy.pendingKeys {
            XCTAssertFalse(pin.contains(AgentDeskCopy.key(name)), "\(name) is exported now: stop treating it as pending")
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
        var schedule = HostAgentDesk.Schedule(jobs: [
            .init(id: "a", name: "A", state: .scheduled), .init(id: "b", name: "B", state: .scheduled)])

        func actions() -> AgentDeskActions {
            AgentDeskActions(
                agentUserID: "@luna:atum.test", steers: true,
                schedule: { [self] in scheduleReads += 1; return schedule },
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
        // A fails ambiguously: it is undone, and the host's own schedule is read again.
        host.gate?.resume()
        await until({ !model.controlPending }, "A never settled")
        XCTAssertEqual(model.problem, .failed)
        XCTAssertEqual(model.jobs?.map(\.state), [.scheduled, .scheduled])
        XCTAssertEqual(host.scheduleReads, 2)
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
        let refusedSchedule = await actions.schedule?()
        let refusedFiles = await actions.files?(nil)
        let refusedControl = await actions.control?(.pause)
        XCTAssertNil(refusedSchedule)
        XCTAssertEqual(refusedFiles, .failed)
        XCTAssertEqual(refusedControl, .failed)
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
        XCTAssertEqual(dropped, .failed)
        XCTAssertEqual(host.controls, [.pause])
    }
}
