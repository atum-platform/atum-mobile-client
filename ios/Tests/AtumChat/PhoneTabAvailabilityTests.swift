import AtumChat
import XCTest

final class PhoneTabAvailabilityTests: XCTestCase {
    func testChatsAreAlwaysAvailable() {
        XCTAssertEqual(PhoneTabAvailability.none.state(for: .chats), .available)
        XCTAssertEqual(PhoneTabAvailability(drive: false, teamSpace: false).state(for: .chats), .available)
    }

    func testUnavailableFeaturesKeepAComingSoonTab() {
        let availability = PhoneTabAvailability(drive: false, teamSpace: false)
        XCTAssertEqual(availability.state(for: .drive), .comingSoon)
        XCTAssertEqual(availability.state(for: .teamSpace), .comingSoon)
    }

    func testEachFeatureMapsItsOwnAvailability() {
        let driveOnly = PhoneTabAvailability(drive: true, teamSpace: false)
        XCTAssertEqual(driveOnly.state(for: .drive), .available)
        XCTAssertEqual(driveOnly.state(for: .teamSpace), .comingSoon)

        let teamOnly = PhoneTabAvailability(drive: false, teamSpace: true)
        XCTAssertEqual(teamOnly.state(for: .drive), .comingSoon)
        XCTAssertEqual(teamOnly.state(for: .teamSpace), .available)

        XCTAssertEqual(PhoneTabAvailability(drive: true, teamSpace: true).state(for: .teamSpace), .available)
    }
}

final class AvatarFacePolicyTests: XCTestCase {
    func testImageWinsAndNeverFallsBackToMonogram() {
        XCTAssertEqual(AvatarFacePolicy.face(hasImage: true, name: "Moon"), .image)
    }

    func testMonogramIsTheOnlyFallbackWithoutAnImage() {
        XCTAssertEqual(AvatarFacePolicy.face(hasImage: false, name: "Moon"), .monogram("M"))
        XCTAssertEqual(AvatarFacePolicy.face(hasImage: false, name: "@ban:atum.test"), .monogram("B"))
        XCTAssertEqual(AvatarFacePolicy.face(hasImage: false, name: "  "), .monogram("?"))
    }
}
