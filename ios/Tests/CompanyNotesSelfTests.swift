import Foundation
import XCTest
@testable import AtumNativeAPI

/// The phone finds and makes the same per-company notes room the desktop does
/// (atum-app `shared/matrix-notes-self.ts`, `src/matrix/notes-self.ts`).
final class CompanyNotesSelfTests: XCTestCase {
    private let owner = "@me:atumplatform.com"
    private let company = "a1000000-0000-4000-8000-000000000001"
    private let other = "a1000000-0000-4000-8000-000000000002"

    private func content(_ company: String?, type: String = CompanyNotesSelf.roomType) -> String {
        var object: [String: Any] = ["type": type, "room_version": "11"]
        if let company { object[CompanyNotesSelf.companyKey] = company }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    private func candidate(_ roomID: String, company: String?, creator: String? = nil, at: Int64? = 10,
                           members: UInt64 = 1, others: [String] = [], joined: Bool = true,
                           type: String = CompanyNotesSelf.roomType) -> CompanyNotesSelf.Candidate {
        .init(roomID: roomID, createContentJSON: content(company, type: type), creatorUserID: creator ?? owner,
              createdAtMilliseconds: at, isJoined: joined, activeMemberCount: members, otherMemberUserIDs: others)
    }

    func testKeysMatchTheDesktop() {
        XCTAssertEqual(CompanyNotesSelf.roomType, "com.atum.notes.self")
        XCTAssertEqual(CompanyNotesSelf.companyKey, "com.atum.notes_self.company_id")
        XCTAssertEqual(CompanyNotesSelf.accountDataType(companyID: company), "com.atum.notes_self." + company)
        XCTAssertTrue(CompanyNotesSelf.isCompanyID(company))
        XCTAssertFalse(CompanyNotesSelf.isCompanyID("A1000000-0000-4000-8000-000000000001"))
    }

    func testEarliestOwnedRoomOfThisCompanyWins() {
        let rooms = [
            candidate("!later:hs", company: company, at: 30),
            candidate("!earliest:hs", company: company, at: 20),
            candidate("!other-company:hs", company: other, at: 1),
            candidate("!personal:hs", company: nil, at: 1),
            candidate("!stranger:hs", company: company, creator: "@someone:hs", at: 1),
            candidate("!left:hs", company: company, at: 1, joined: false),
            candidate("!wrong-type:hs", company: company, at: 1, type: "io.atum.agent_task.v1"),
            candidate("!shared:hs", company: company, at: 5, members: 2, others: ["@friend:hs"]),
        ]
        let inspection = CompanyNotesSelf.inspect(rooms, ownerUserID: owner, companyID: company)
        XCTAssertEqual(inspection.winner, "!earliest:hs")
        XCTAssertEqual(inspection.quarantined, ["!shared:hs"])
        XCTAssertEqual(CompanyNotesSelf.inspect(rooms, ownerUserID: owner, companyID: other).winner,
                       "!other-company:hs")
        // A tie on the create time falls to the room ID, as on the desktop.
        let tie = [candidate("!b:hs", company: company, at: 7), candidate("!a:hs", company: company, at: 7)]
        XCTAssertEqual(CompanyNotesSelf.inspect(tie, ownerUserID: owner, companyID: company).winner, "!a:hs")
    }

    func testPointerIsReadExactlyAndUnknownDataIsReadOnly() {
        XCTAssertEqual(CompanyNotesSelf.readPointer(json: nil), .absent)
        XCTAssertEqual(CompanyNotesSelf.readPointer(json: #"{"version":1,"room_id":"!n:hs"}"#), .known(roomID: "!n:hs"))
        XCTAssertEqual(CompanyNotesSelf.readPointer(json: #"{"version":2,"room_id":"!n:hs"}"#), .readonly)
        XCTAssertEqual(CompanyNotesSelf.readPointer(json: #"{"version":1,"room_id":"!n:hs","x":1}"#), .readonly)
        XCTAssertEqual(CompanyNotesSelf.readPointer(json: #"{"version":true,"room_id":"!n:hs"}"#), .readonly)
        XCTAssertEqual(CompanyNotesSelf.readPointer(json: #"{"version":1,"room_id":"n"}"#), .readonly)
        let json = CompanyNotesSelf.pointerJSON(roomID: "!n:hs")
        XCTAssertEqual(CompanyNotesSelf.readPointer(json: json), .known(roomID: "!n:hs"))
    }

    func testOpenNeverCreatesWhileAnotherDeviceRoomMayExist() {
        let none = CompanyNotesSelf.Inspection(winner: nil, quarantined: [])
        let found = CompanyNotesSelf.Inspection(winner: "!n:hs", quarantined: [])
        XCTAssertEqual(CompanyNotesSelf.openDecision(inspection: found, pointer: .readonly, initialSyncComplete: false),
                       .open(roomID: "!n:hs"))
        XCTAssertEqual(CompanyNotesSelf.openDecision(inspection: none, pointer: .absent, initialSyncComplete: true),
                       .create)
        XCTAssertEqual(CompanyNotesSelf.openDecision(inspection: none, pointer: .absent, initialSyncComplete: false),
                       .refuse)
        XCTAssertEqual(CompanyNotesSelf.openDecision(inspection: none, pointer: .known(roomID: "!desk:hs"),
                                                     initialSyncComplete: true), .wait)
        XCTAssertEqual(CompanyNotesSelf.openDecision(inspection: none, pointer: .readonly, initialSyncComplete: true),
                       .refuse)
        let shared = CompanyNotesSelf.Inspection(winner: nil, quarantined: ["!desk:hs"])
        XCTAssertEqual(CompanyNotesSelf.openDecision(inspection: shared, pointer: .known(roomID: "!desk:hs"),
                                                     initialSyncComplete: true), .create)
    }

    func testCreateBodyIsTheDesktopRecipe() throws {
        let data = try XCTUnwrap(CompanyNotesSelf.createRoomBody(companyID: company))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["preset"] as? String, "private_chat")
        XCTAssertEqual(body["creation_content"] as? [String: String],
                       ["type": "com.atum.notes.self", "com.atum.notes_self.company_id": company])
        XCTAssertNil(body["invite"])
        let state = try XCTUnwrap(body["initial_state"] as? [[String: Any]])
        XCTAssertEqual(state.compactMap { $0["type"] as? String },
                       ["m.room.history_visibility", "m.room.guest_access"])
        XCTAssertNil(CompanyNotesSelf.createRoomBody(companyID: "not-a-company"))
        XCTAssertEqual(CompanyNotesSelf.createdRoomID(responseJSON: Data(#"{"room_id":"!new:hs"}"#.utf8)), "!new:hs")
        XCTAssertEqual(CompanyNotesSelf.companyID(createContentJSON: content(company)), company)
        XCTAssertNil(CompanyNotesSelf.companyID(createContentJSON: content(nil)))
    }

    // MARK: Chief of Staff row state

    private func view(_ file: String) throws -> CompanyPrivateCosView {
        let directory = try XCTUnwrap(Bundle.module.url(forResource: "company-private-cos", withExtension: nil))
        return try NativeAPI.decode(CompanyPrivateCosView.self,
                                    from: Data(contentsOf: directory.appendingPathComponent(file)))
    }

    func testChiefOfStaffRowStatesMatchTheDesktop() throws {
        typealias P = CompanyPrivateCosRowProjection
        XCTAssertEqual(P.status(state: nil, discovery: nil), .settingUp)
        XCTAssertEqual(P.status(state: nil, discovery: .checking), .settingUp)
        XCTAssertEqual(P.status(state: nil, discovery: .notAvailable), .notAvailable)
        let uncreated = CompanyPrivateCosState(view: try view("v1-lazy-first-open.uncreated.response.json"))
        XCTAssertTrue(uncreated.isUncreated)
        XCTAssertEqual(P.status(state: uncreated, discovery: nil), .settingUp)
        var preparing = CompanyPrivateCosState(view: try view("v1-lazy-first-open.preparing.response.json"))
        XCTAssertEqual(P.status(state: preparing, discovery: nil), .settingUp)
        preparing.failed(CompanyAPIError.refused(.conflict, reason: "budget_exhausted", retryAfter: nil))
        XCTAssertEqual(P.status(state: preparing, discovery: nil), .paused)
        XCTAssertTrue(P.status(state: preparing, discovery: nil).offersRetry)
        preparing.failed(CompanyAPIError.unavailable)
        XCTAssertEqual(P.status(state: preparing, discovery: nil), .notAvailable)
        preparing.loading = true
        XCTAssertEqual(P.status(state: preparing, discovery: nil), .settingUp)
        XCTAssertTrue(P.endsScope(CompanyAPIError.refused(.denied, reason: nil, retryAfter: nil)))
        XCTAssertFalse(P.endsScope(CompanyAPIError.transport))
    }

    func testEnsureRequestKeepsOnlyKnownLocales() throws {
        let id = try NativeID("a7000000-0000-4000-8000-000000000001")
        let data = try JSONEncoder().encode(CompanyPrivateCosEnsureRequest(requestId: id, trigger: .firstCompanyVisit,
                                                                           locale: "vi"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: AnyHashable])
        XCTAssertEqual(body, ["schemaVersion": 1, "requestId": id.rawValue, "action": "ensure",
                              "trigger": "first_company_visit", "locale": "vi"])
        XCTAssertNil(CompanyPrivateCosEnsureRequest(requestId: id, trigger: .dmOpen, locale: "fr").locale)
    }
}
