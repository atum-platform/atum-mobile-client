@testable import AtumMobile
import XCTest

/// Settings > Assistants lists what Home lists, plus any assistant still being
/// prepared, and nothing else.
final class AccountAssistantRosterTests: XCTestCase {
    private func assistant(_ id: String, _ title: String, agent: String,
                           avatar: LiveProductAvatar? = nil, matrix: String? = nil,
                           sha: String? = nil, awaiting: Bool = false,
                           appBot: Bool = false, primary: Bool = false) -> LiveProductRoom {
        LiveProductRoom(
            id: id, kind: .agent, title: title, avatar: avatar, matrixAvatarURL: matrix,
            avatarSHA256: sha,
            assistant: LiveProductAssistantMetadata(id: agent, isDefault: primary, order: 0),
            canOpen: !awaiting, isAwaitingRoom: awaiting, isAppBotRoom: appBot
        )
    }

    func testReadyAssistantsKeepHomesOrderAndHomesFace() throws {
        let photo = try XCTUnwrap(URL(string: "https://photos.atum.invalid/mai.png"))
        let rooms = [
            assistant("!mai:atum.invalid", "Mai", agent: "a-mai", avatar: .photo(url: photo, fallback: "M"),
                      sha: String(repeating: "a", count: 64)),
            assistant("!atum:atum.invalid", "Atum", agent: "a-atum", avatar: .eclipse,
                      primary: true),
            assistant("!bao:atum.invalid", "Bảo", agent: "a-bao", matrix: "mxc://atum.invalid/bao"),
        ]
        // Home draws the primary assistant first; the roster order is Home's.
        let result = AccountAssistantRoster.summaries(
            readyRoomIDs: ["!atum:atum.invalid", "!mai:atum.invalid", "!bao:atum.invalid"],
            rooms: rooms, titles: ["a-mai": "Writes with you", "a-atum": "Your first assistant"]
        )

        XCTAssertEqual(result.map(\.name), ["Atum", "Mai", "Bảo"])
        XCTAssertEqual(result.map(\.isReady), [true, true, true])
        XCTAssertEqual(result.map(\.isAtum), [true, false, false])
        XCTAssertEqual(result.map(\.isPrimary), [true, false, false])
        XCTAssertEqual(result.map(\.title), ["Your first assistant", "Writes with you", nil])
        XCTAssertEqual(result[1].avatarURL, photo)
        XCTAssertEqual(result[1].avatarSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(result[2].matrixAvatarURL, "mxc://atum.invalid/bao")
        XCTAssertEqual(result.map(\.roomID),
                       ["!atum:atum.invalid", "!mai:atum.invalid", "!bao:atum.invalid"])
    }

    func testAnAssistantWhoseChatHasNotArrivedIsListedAfterTheReadyOnesAndCannotBeOpened() {
        let rooms = [
            assistant("agent:a-new", "Lan", agent: "a-new", awaiting: true),
            assistant("!mai:atum.invalid", "Mai", agent: "a-mai"),
        ]
        let result = AccountAssistantRoster.summaries(
            readyRoomIDs: ["!mai:atum.invalid"], rooms: rooms, titles: [:]
        )
        XCTAssertEqual(result.map(\.name), ["Mai", "Lan"])
        XCTAssertEqual(result.map(\.isReady), [true, false])
    }

    func testAppBotsPeopleAndUnknownRoomsAreNeverListed() {
        let rooms = [
            assistant("agent:moon", "Moon", agent: "moon", awaiting: true, appBot: true),
            LiveProductRoom(id: "!friend:atum.invalid", kind: .people, title: "Friend"),
            assistant("!mai:atum.invalid", "Mai", agent: "a-mai"),
        ]
        let result = AccountAssistantRoster.summaries(
            readyRoomIDs: ["!mai:atum.invalid", "!gone:atum.invalid"], rooms: rooms, titles: [:]
        )
        XCTAssertEqual(result.map(\.name), ["Mai"])
    }

    func testARoomListedTwiceAppearsOnce() {
        let rooms = [assistant("!mai:atum.invalid", "Mai", agent: "a-mai"),
                     assistant("!mai:atum.invalid", "Mai again", agent: "a-mai")]
        let result = AccountAssistantRoster.summaries(
            readyRoomIDs: ["!mai:atum.invalid", "!mai:atum.invalid"], rooms: rooms, titles: [:]
        )
        XCTAssertEqual(result.map(\.name), ["Mai"])
    }

    func testNoAssistantsIsAnEmptyListSoThePageSaysItIsBeingPrepared() {
        XCTAssertEqual(AccountAssistantRoster.summaries(readyRoomIDs: [], rooms: [], titles: [:]), [])
    }
}

// MARK: Home row

/// Needs `HomeScreen.swift`, so the host harness cuts the file here and the
/// Xcode test target runs this class.
final class AccountAssistantHomeRowTests: XCTestCase {
    func testTheRowSettingsDrawsIsTheRowHomeWouldDraw() throws {
        let photo = try XCTUnwrap(URL(string: "https://photos.atum.invalid/mai.png"))
        let summary = AccountAssistantSummary(
            roomID: "!mai:atum.invalid", name: "Mai", title: nil, matrixAvatarURL: "mxc://atum.invalid/mai",
            avatarURL: photo, avatarSHA256: "00", isAtum: false, isReady: true
        )
        let row = summary.homeRow
        XCTAssertEqual(row.roomID, "!mai:atum.invalid")
        XCTAssertEqual(row.name, "Mai")
        XCTAssertEqual(row.kind, .assistant)
        XCTAssertEqual(row.matrixAvatarURL, "mxc://atum.invalid/mai")
        XCTAssertEqual(row.avatarURL, photo)
        var atum = summary
        atum.isAtum = true
        XCTAssertEqual(atum.homeRow.kind, .atum)
    }
}
