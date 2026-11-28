import Foundation
import XCTest
@testable import AtumNativeAPI

/// W4-Y2: what the composer chip, the assistant card and the picker show when
/// a Work (Mac plan) model answers, and that showing it never writes.
@available(macOS 14.0, *)
@MainActor final class PhoneWorkPickerFaceTests: XCTestCase {
    private let agent = try! NativeID("7ad4a8b3-58fa-40b9-9f68-d595bbff618e")
    private let opus = WorkModelSelection(plan: .claude, model: "claude-opus-5-5")!
    private let luna = WorkModelSelection(plan: .codex, model: "gpt-6-luna")!

    func testFaceNamesTheCatalogModelNotTheLineup() {
        let reported = [PhoneModelPickerProjection.WorkPlanHandoff(
            plan: .claude, models: [.init(id: "claude-opus-5-5", displayName: "Claude Opus 5.5")])]
        let face = PhoneModelPickerProjection.workFace(opus, reported: reported)
        XCTAssertEqual(face?.name, "Claude Opus 5.5")
        XCTAssertEqual(face?.plan, .claude)
        XCTAssertNotEqual(face?.name, ManagedModelLineup.productName(for: ManagedModelLineup.defaultAlias))
        XCTAssertNil(PhoneModelPickerProjection.workFace(nil, reported: reported))
    }

    func testFaceWithoutACatalogUsesReadableWordsForTheID() {
        // Desktop `matrixModelDisplayName`: an id-only entry is still words.
        XCTAssertEqual(PhoneModelPickerProjection.workFace(luna, reported: [])?.name, "GPT-6 Luna")
        let idOnly = [PhoneModelPickerProjection.WorkPlanHandoff(
            plan: .codex, models: [.init(id: "gpt-6-luna", displayName: "gpt-6-luna")])]
        XCTAssertEqual(PhoneModelPickerProjection.workFace(luna, reported: idOnly)?.name, "GPT-6 Luna")
    }

    func testCloudRowsYieldWhileAWorkModelAnswers() {
        let atum = PhoneModelPickerProjection.Row(favoriteID: "atum", source: .atum,
                                                  model: ManagedModelLineup.defaultAlias,
                                                  displayName: "Nguyệt Thực 1.3", selected: true, selectable: true)
        let yielded = PhoneModelPickerProjection.yieldingToWork([atum], answering: opus)
        XCTAssertEqual(yielded.map(\.selected), [false])
        XCTAssertEqual(yielded.map(\.selectable), [true], "an explicit cloud pick stays possible")
        XCTAssertEqual(PhoneModelPickerProjection.yieldingToWork([atum], answering: nil), [atum])
    }

    func testOpeningReadsOnlyAndNamesTheSavedPlanModel() async {
        var reads = 0
        var writes = 0
        let account = await account([opus, luna])
        let picker = PhoneModelPickerWorkSelection(agentPrincipal: agent, calls: WorkSelectionCalls(
            read: { _, _ in
                reads += 1
                return try NativeAPI.decode(WorkModelSelectionSnapshot.self, from: Data(
                    #"{"revision":6,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}"#.utf8))
            },
            write: { _, _, _, _ in
                writes += 1
                return .conflict
            }), account: account, isCurrent: { true })
        await picker.reload()
        await picker.reload()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(writes, 0, "opening or refreshing the picker never writes")
        XCTAssertEqual(PhoneModelPickerProjection.answeringWork(picker.value), opus)
        XCTAssertEqual(picker.rows.filter(\.selected).map(\.id), [opus])
        XCTAssertEqual(picker.rows.first { $0.id == opus }?.displayName, "Claude Opus 5.5")
        XCTAssertEqual(Set(picker.rows.filter(\.selectable).map(\.id)), [opus, luna])
    }

    func testAPickWritesOnlyTheWorkSelectionAndBecomesCurrent() async {
        var written: [(WorkModelSelection, Int64)] = []
        var saved = try! NativeAPI.decode(WorkModelSelectionSnapshot.self,
                                          from: Data(#"{"revision":3,"selection":null}"#.utf8))
        let account = await account([opus, luna])
        let picker = PhoneModelPickerWorkSelection(agentPrincipal: agent, calls: WorkSelectionCalls(
            read: { _, _ in saved },
            write: { _, selection, revision, _ in
                written.append((selection, revision))
                saved = try NativeAPI.decode(WorkModelSelectionSnapshot.self, from: Data("""
                    {"revision":\(revision + 1),"selection":{"provider":"atum-work","plan":"\(selection.plan.rawValue)",\
                    "model":"\(selection.model)"}}
                    """.utf8))
                return .saved(saved)
            }), account: account, isCurrent: { true })
        await picker.reload()
        XCTAssertNil(PhoneModelPickerProjection.answeringWork(picker.value))
        await picker.save(luna)
        XCTAssertEqual(written.map(\.0), [luna])
        XCTAssertEqual(written.map(\.1), [3])
        XCTAssertEqual(picker.value?.readySnapshot?.selection, luna)
        XCTAssertEqual(picker.rows.filter(\.selected).map(\.id), [luna])
    }

    func testARetiredPickerNamesNothing() async {
        let account = await account([opus])
        let picker = PhoneModelPickerWorkSelection(agentPrincipal: agent, calls: WorkSelectionCalls(
            read: { _, _ in
                try NativeAPI.decode(WorkModelSelectionSnapshot.self, from: Data(
                    #"{"revision":6,"selection":{"provider":"atum-work","plan":"claude","model":"claude-opus-5-5"}}"#.utf8))
            },
            write: { _, _, _, _ in .conflict }), account: account, isCurrent: { true })
        await picker.reload()
        picker.retire()
        XCTAssertNil(PhoneModelPickerProjection.answeringWork(picker.value))
        XCTAssertTrue(picker.rows.isEmpty)
    }

    private func account(_ choices: [WorkModelSelection]) async -> PhoneModelPickerAccount {
        let names = ["claude-opus-5-5": "Claude Opus 5.5", "gpt-6-luna": "GPT-6 Luna"]
        let mac = AccountConnectionDevice(deviceServiceID: "mac", displayName: "Mac", stale: true, observedAt: 1)
        let registry = AccountConnections(connections: Dictionary(grouping: choices, by: \.plan).map { plan, choices in
            AccountConnection(id: plan.rawValue, kind: .plan, status: .connected, devices: [mac],
                              models: choices.map { .init(id: $0.model, displayName: names[$0.model] ?? $0.model) })
        })
        let account = PhoneModelPickerAccount()
        await account.reload(.init(chatGPT: { nil }, openCodeGo: { nil }, accountConnections: { registry }))
        return account
    }
}
