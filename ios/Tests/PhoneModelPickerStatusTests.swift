import XCTest
@testable import AtumNativeAPI

/// W4-X2: the picker's settled read lines follow W4-X1's read states only.
final class PhoneModelPickerStatusTests: XCTestCase {
    private struct Offline: Error {}

    func testTheDestinationLineShowsOnlyWhileLoadingOrAfterAFailure() {
        XCTAssertEqual(PhoneModelPickerStatus.destination(.loading),
                       PhoneModelPickerStatus(source: .destination, phase: .loading))
        XCTAssertEqual(PhoneModelPickerStatus.destination(.failed),
                       PhoneModelPickerStatus(source: .destination, phase: .failed))
        XCTAssertNil(PhoneModelPickerStatus.destination(.ready))
        XCTAssertNil(PhoneModelPickerStatus.destination(.unavailable))
        XCTAssertTrue(PhoneModelPickerStatus.destination(.failed)!.offersRetry)
        XCTAssertFalse(PhoneModelPickerStatus.destination(.loading)!.offersRetry)
    }

    func testNoAccountReadDrawsNoProviderLine() {
        XCTAssertEqual(PhoneModelPickerStatus.providers(nil), [])
        // Ready and quiet unavailable sources keep their existing treatment.
        XCTAssertEqual(PhoneModelPickerStatus.providers(
            PhoneSubscriptionAccount(chatGPT: nil, openCodeGo: nil, accountConnections: nil)), [])
    }

    @MainActor
    func testAFailedSourceGetsItsOwnLineAndRetryWhileTheOthersSettleQuietly() async {
        let account = PhoneModelPickerAccount()
        await account.reload(PhoneSubscriptionAccountReads(
            chatGPT: { throw Offline() },
            openCodeGo: { nil },
            accountConnections: { AccountConnections(connections: []) }))
        let lines = PhoneModelPickerStatus.providers(account.value)
        XCTAssertEqual(lines, [PhoneModelPickerStatus(source: .chatGPT, phase: .failed)])
        XCTAssertEqual(lines.map(\.offersRetry), [true])
    }

    @MainActor
    func testEveryAccountSourceCanFailIndependently() async {
        let account = PhoneModelPickerAccount()
        await account.reload(PhoneSubscriptionAccountReads(
            chatGPT: { throw Offline() },
            openCodeGo: { throw Offline() },
            accountConnections: { throw Offline() }))
        XCTAssertEqual(PhoneModelPickerStatus.providers(account.value).map(\.source),
                       [.chatGPT, .openCodeGo, .accountConnections])
        XCTAssertTrue(PhoneModelPickerStatus.providers(account.value).allSatisfy { $0.phase == .failed })
    }

    func testALineDropsItsWordsOnlyWhenASavedRowAlreadyCarriesThem() {
        typealias Row = PhoneModelPickerProjection.Row
        let saved = Row(favoriteID: nil, source: .chatGPTPlan, model: "gpt-6.1", displayName: "GPT-6.1",
                        selected: false, selectable: false, isSubscription: true, unavailable: .failed)
        let go = Row(favoriteID: nil, source: .opencodeGo, model: "glm-5.2", displayName: "GLM 5.2",
                     selected: false, selectable: true, isSubscription: true)
        let failed = PhoneModelPickerStatus(source: .chatGPT, phase: .failed)
        XCTAssertTrue(failed.isShownOnRow(in: [saved, go]))
        XCTAssertFalse(failed.isShownOnRow(in: [go]), "no saved ChatGPT row: the line keeps its words")
        XCTAssertFalse(PhoneModelPickerStatus(source: .chatGPT, phase: .loading).isShownOnRow(in: [saved]),
                       "a row that reads failed does not say loading")
        XCTAssertFalse(PhoneModelPickerStatus(source: .openCodeGo, phase: .failed).isShownOnRow(in: [saved, go]))
        XCTAssertFalse(PhoneModelPickerStatus(source: .destination, phase: .failed).isShownOnRow(in: [saved]))
        XCTAssertFalse(PhoneModelPickerStatus(source: .accountConnections, phase: .failed).isShownOnRow(in: [saved]))
    }
}
