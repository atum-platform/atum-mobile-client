import XCTest
@testable import AtumChat

/// B19 (Proof: T): one case per kind and per undecryptable-cause group.
/// Every kind becomes a row; nothing vanishes and no bubble is empty.
final class ContentRulesTests: XCTestCase {
    private func row(_ fact: ContentFact, edited: Bool = false) -> RowContent {
        ContentRules.content(fact, isEdited: edited)
    }

    func testTextAndEmoteShowAsTextAndKeepTheEditedFlag() {
        XCTAssertEqual(row(.text(body: "*hi*"), edited: true), RowContent(kind: .message, body: "*hi*", isEdited: true))
        XCTAssertEqual(row(.emote(body: "waves")), RowContent(kind: .message, body: "waves", isEdited: false))
    }

    func testANoticeIsTheQuietLine() {
        XCTAssertEqual(row(.notice(body: "Đang làm…")).kind, .notice)
        XCTAssertEqual(row(.notice(body: "Đang làm…")).body, "Đang làm…")
    }

    func testAnImageIsABoxSizedFromItsInfoWithItsCaption() {
        XCTAssertEqual(row(.image(caption: "beach", width: 1200, height: 800)),
                       RowContent(kind: .image(width: 1200, height: 800), body: "beach", isEdited: false))
        XCTAssertEqual(row(.image(caption: nil, width: nil, height: nil)),
                       RowContent(kind: .image(width: nil, height: nil), body: "", isEdited: false),
                       "no info: the row still exists")
    }

    func testFilesVideosAndAudioAreFileRowsWithTheirName() {
        for fact in [ContentFact.file(name: "a.pdf", caption: nil), .video(name: "a.pdf", caption: nil),
                     .audio(name: "a.pdf", caption: nil)] {
            XCTAssertEqual(row(fact).kind, .file(name: "a.pdf"))
        }
        XCTAssertEqual(row(.video(name: "v.mp4", caption: "look")).body, "look")
    }

    func testLocationShowsItsDescriptionElseItsBody() {
        XCTAssertEqual(row(.location(description: "Hồ Gươm", body: "geo:21,105")).body, "Hồ Gươm")
        XCTAssertEqual(row(.location(description: nil, body: "geo:21,105")).body, "geo:21,105")
    }

    func testAnEmptyLocationDescriptionDoesNotHideTheLocationBody() {
        for description in ["", " ", "\n\t"] {
            XCTAssertEqual(row(.location(description: description, body: "geo:21,105")),
                           RowContent(kind: .message, body: "geo:21,105", isEdited: false))
        }
    }

    func testLocationUsesTheSDKCoordinatesWhenThereIsNoReadableFallback() {
        let location = row(.location(description: " ", body: "", geoURI: "geo:21,105"))
        XCTAssertEqual(location.kind, .message)
        XCTAssertEqual(location.body, "geo:21,105")
    }

    func testFallbackBodiesShowAsTextAndAnEmptyOneIsTheGenericPlaceholder() {
        for fact in [ContentFact.gallery(body: "3 photos"), .otherMessageType(body: "custom"),
                     .sticker(body: "cat"), .poll(question: "Lunch?")] {
            XCTAssertEqual(row(fact).kind, .message, "\(fact)")
        }
        for fact in [ContentFact.gallery(body: ""), .otherMessageType(body: ""), .sticker(body: ""),
                     .poll(question: ""), .location(description: nil, body: "")] {
            XCTAssertEqual(row(fact).kind, .placeholder(.unsupported), "\(fact)")
        }
        XCTAssertTrue(row(.poll(question: "Lunch?"), edited: true).isEdited)
    }

    func testRedactedIsTheDeletedPlaceholder() {
        XCTAssertEqual(row(.redacted), RowContent(kind: .placeholder(.redacted), body: "", isEdited: false))
    }

    func testBodylessKindsAreTheGenericPlaceholder() {
        for fact in [ContentFact.customMessageLike, .liveLocation, .parseFailure] {
            XCTAssertEqual(row(fact).kind, .placeholder(.unsupported), "\(fact)")
        }
    }

    func testRoomStateIsTheHiddenKind() {
        XCTAssertEqual(row(.roomState).kind, .roomState)
    }

    func testOldHistoryCausesShowTheOldHistoryPlaceholder() {
        for cause in [UndecryptableCause.sentBeforeWeJoined, .historicalMessageAndBackupIsDisabled,
                      .historicalMessageAndDeviceIsUnverified] {
            XCTAssertEqual(row(.undecryptable(cause)).kind, .placeholder(.undecryptableOldHistory), "\(cause)")
        }
    }

    func testEveryOtherCauseShowsTheGenericUndecryptablePlaceholder() {
        let oldHistory: Set<UndecryptableCause> = [.sentBeforeWeJoined, .historicalMessageAndBackupIsDisabled,
                                                   .historicalMessageAndDeviceIsUnverified]
        for cause in UndecryptableCause.allCases where !oldHistory.contains(cause) {
            XCTAssertEqual(ContentRules.placeholderReason(cause), .undecryptable, "\(cause)")
        }
    }
}
