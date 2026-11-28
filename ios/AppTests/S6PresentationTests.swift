@testable import AtumMobile
import AtumChat
import AtumNativeAPI
import Foundation
import XCTest

final class S6PresentationTests: XCTestCase {
    @MainActor
    func testSignInFailureIsVisibleUnlessThePersonCancels() {
        XCTAssertEqual(LiveAppModel.initialNotice(OIDCFailure.authorizationDenied), .cancelled)
        XCTAssertEqual(LiveAppModel.initialNotice(OIDCFailure.browserUnavailable), .cancelled)
        XCTAssertEqual(LiveAppModel.initialNotice(URLError(.notConnectedToInternet)), .failed)
        XCTAssertEqual(LiveAppModel.initialNotice(OIDCFailure.invalidToken), .failed)
        XCTAssertEqual(LiveSignInNotice.failed.welcomePresentation, .failed)
        XCTAssertEqual(LiveSignInNotice.cancelled.welcomePresentation, .cancelled)
    }

    @MainActor
    func testMessageActionsOverlayCoversTheChat() {
        let presenter = MessageActionsPresenter()
        XCTAssertFalse(presenter.covers)

        let row = ChatRow(item: ChatItem(id: "m1", kind: .message, sender: "@ann:atum.test", body: "Hi"))
        presenter.actionsOverlay = MessageOverlayRequest(row: row, kind: .person, roomTitle: "Ann",
                                                         ownUserID: nil, parsedBody: nil,
                                                         items: [.react, .reply, .copy], sourceFrame: .zero)
        XCTAssertTrue(presenter.covers)

        presenter.actionsOverlay = nil
        XCTAssertFalse(presenter.covers)
    }

    /// Desktop #89 (owner 2026-11-19): one read signal. A settled message
    /// nobody has read says nothing after its time, in words or on its line;
    /// the clock, the failure and the readers' faces keep theirs.
    @MainActor
    func testABubbleSaysReadOnlyThroughItsReadersFaces() throws {
        let copy = ChatCopy(design: try LiveDesign())
        XCTAssertNil(ChatRowText.delivery(.none, kind: .assistant, copy: copy), "no Sent receipt in the label")
        XCTAssertNil(ChatRowText.delivery(.none, kind: .group, copy: copy))
        XCTAssertEqual(ChatRowText.delivery(.sending, kind: .person, copy: copy), copy.text(.pending))
        XCTAssertEqual(ChatRowText.delivery(.failed, kind: .person, copy: copy), copy.text(.notSent))
        XCTAssertEqual(ChatRowText.delivery(.seen(readerCount: 1), kind: .assistant, copy: copy), copy.text(.seen))
        XCTAssertEqual(ChatRowText.delivery(.seen(readerCount: 2), kind: .group, copy: copy),
                       copy.text(.seenBy, .number(2)))

        let item = ChatItem(id: "q", kind: .message, sender: "@me:atum.test", isOwn: true, body: "Hi")
        let settled = Projection.rows([item], context: RoomContext(kind: .person, ownUserID: "@me:atum.test"),
                                      options: .s1)
        XCTAssertEqual(settled.first { $0.id == "q" }?.delivery, DeliveryMark.none,
                       "my newest settled message carries no mark")
        // Polish P7: the line holds only the delivery mark (and, in a flat
        // run, "đã sửa"), so a settled unread message draws no line at all,
        // not an empty one or a lone separator; its time is in the bubble.
        XCTAssertFalse(DeliveryLine.shows(ChatRow(item: item), flat: true))
        XCTAssertFalse(DeliveryLine.shows(ChatRow(item: item, grouping: RowGrouping(showsTime: true)), flat: false),
                       "the run's time sits in the bubble's corner, not in a line under it")
        XCTAssertTrue(BubbleMeta.shows(ChatRow(item: item, grouping: RowGrouping(showsTime: true))))
        XCTAssertFalse(DeliveryLine.shows(ChatRow(item: item, grouping: RowGrouping(showsEdited: true)), flat: false),
                       "a bubble's đã sửa is in its corner")
        XCTAssertTrue(DeliveryLine.shows(ChatRow(item: item, grouping: RowGrouping(showsEdited: true)), flat: true),
                      "a flat run has no bubble: đã sửa stays in its line")
        XCTAssertTrue(DeliveryLine.shows(ChatRow(item: item, delivery: .seen(readerCount: 1)), flat: true),
                      "the faces still show")
        XCTAssertTrue(DeliveryLine.shows(ChatRow(item: item, delivery: .sending), flat: false))
        XCTAssertTrue(DeliveryLine.shows(ChatRow(item: item, delivery: .failed), flat: false))
        // My newest message keeps its clock's place while it sends, so the
        // bubble does not grow when it settles.
        let sending = ChatRow(item: item, delivery: .sending, grouping: RowGrouping(position: .single))
        XCTAssertTrue(BubbleMeta.keepsTimeSlot(sending))
        XCTAssertFalse(BubbleMeta.keepsTimeSlot(ChatRow(item: item, delivery: .sending,
                                                        grouping: RowGrouping(position: .first))), "not inside a run")
    }

    func testRecoveryKeyGroupsOnlyWhileActiveAndRedactsEveryCharacterOtherwise() {
        let key = "SYNTH ETIC RECO VERY KEY1"
        XCTAssertEqual(RecoveryKeyDisplay.value(key, sceneIsActive: true),
                       "SYNT HETI CREC OVER YKEY 1")
        let hidden = RecoveryKeyDisplay.value(key, sceneIsActive: false)
        XCTAssertEqual(hidden, "•••• •••• •••• •••• •••• •")
        XCTAssertFalse(hidden.contains("S"))
        XCTAssertFalse(hidden.contains("1"))
    }

    private func account(_ userID: String, name: String?, handle: String? = nil) -> AccountPresentation {
        AccountPresentation(
            matrixUserID: userID, displayName: name,
            offersHistoryRecovery: false, holdsRecoveryKey: false,
            recoveryKeySavedOnThisPhone: false, signOutInProgress: false,
            signOutFailureToken: 0, version: "1.0", directoryHandle: handle
        )
    }

    /// AC-1: a real directory handle shows as the @handle line under the name.
    func testAccountShowsTheDirectoryHandleUnderTheName() {
        let value = account("@user-0123456789abcdef0123456789abcdef:atum.invalid", name: "Minh", handle: "minh")
        XCTAssertEqual(value.name(unnamed: "Atum user"), "Minh")
        XCTAssertEqual(value.publicHandle, "@minh")
        XCTAssertEqual(value.handleLine(unnamed: "Atum user"), "@minh")
    }

    /// AC-1: no directory handle (or one that is not a handle) means no handle
    /// line and no Public handle row; the Matrix ID's localpart never stands in.
    func testAccountNeverShowsTheMatrixIDAsAHandle() {
        let opaque = "@user-0123456789abcdef0123456789abcdef:atum.invalid"
        for handle in [nil, "", "user-0123456789abcdef0123456789abcdef", "@minh", "Minh", "mi"] as [String?] {
            let value = account(opaque, name: "Minh", handle: handle)
            XCTAssertNil(value.publicHandle, String(describing: handle))
            XCTAssertNil(value.handleLine(unnamed: "Atum user"), String(describing: handle))
        }
        // A readable early ID is not a handle either: the directory may give it to someone else.
        XCTAssertNil(account("@an:atum.invalid", name: "An").publicHandle)
    }

    /// AC-1: with no name, the handle is the name (and is not repeated under
    /// it); with neither, the desktop's word for someone unnamed. Never an ID.
    func testAccountWithNoNameFallsBackToTheHandleThenTheUnnamedWord() {
        let opaque = "@user-0123456789abcdef0123456789abcdef:atum.invalid"
        let named = account(opaque, name: nil, handle: "minh")
        XCTAssertEqual(named.name(unnamed: "Atum user"), "@minh")
        XCTAssertNil(named.handleLine(unnamed: "Atum user"))

        for name in [nil, "", "  ", opaque, "user-0123456789abcdef0123456789abcdef",
                     "\(opaque), \(opaque)"] as [String?] {
            let value = account(opaque, name: name)
            XCTAssertEqual(value.name(unnamed: "Atum user"), "Atum user", String(describing: name))
            XCTAssertNil(value.profileName, String(describing: name))
            XCTAssertNil(value.handleLine(unnamed: "Atum user"))
        }
        // An early readable ID still reads as a name, without the server or an "@".
        XCTAssertEqual(account("@an:atum.invalid", name: nil).name(unnamed: "Atum user"), "an")
        // The SDK's " (@id)" disambiguation suffix is not part of the name.
        XCTAssertEqual(account(opaque, name: "Minh (\(opaque))").name(unnamed: "Atum user"), "Minh")
    }

    func testContextlessStatusEscapeCannotOrphanAnUnsavedRecoveryKey() {
        XCTAssertTrue(StatusRecoverySignOutPolicy.requiresSave(hasRecoveryKey: true,
                                                               saved: false))
        XCTAssertFalse(StatusRecoverySignOutPolicy.authorizesArchive(
            hasRecoveryKey: true, saved: false, confirmedSaved: false
        ))
        XCTAssertTrue(StatusRecoverySignOutPolicy.authorizesArchive(
            hasRecoveryKey: true, saved: false, confirmedSaved: true
        ))
        XCTAssertTrue(StatusRecoverySignOutPolicy.authorizesArchive(
            hasRecoveryKey: true, saved: true, confirmedSaved: false
        ))
        XCTAssertTrue(StatusRecoverySignOutPolicy.authorizesArchive(
            hasRecoveryKey: false, saved: false, confirmedSaved: false
        ))
    }
}
