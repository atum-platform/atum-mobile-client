@testable import AtumMobile
import AtumDesign
import Foundation
import XCTest

/// Wave 3 AC-8: Settings › Your devices and the recovery status.
final class AccountDevicesTests: XCTestCase {
    private let devicesJSON = Data(#"""
    {"devices":[
      {"device_id":"PHONE","display_name":"Atum iPhone","last_seen_ip":"203.0.113.9","last_seen_ts":1762800000000},
      {"device_id":"OLDMAC","display_name":"MacBook Pro","last_seen_ip":"203.0.113.7","last_seen_ts":1762700000000},
      {"device_id":"NEWMAC","display_name":"  Studio  ","last_seen_ts":1762790000000},
      {"device_id":"NONAME"},
      {"device_id":"SELFNAMED","display_name":"SELFNAMED","last_seen_ts":1762600000000},
      {"device_id":"MXID","display_name":"@an:atum.invalid"}
    ]}
    """#.utf8)

    func testListLeavesThisPhoneOutAndSortsByLastActive() throws {
        let devices = try XCTUnwrap(AccountDeviceList.parse(devicesJSON, currentDeviceID: "PHONE"))
        XCTAssertEqual(devices.map(\.id), ["NEWMAC", "OLDMAC", "SELFNAMED", "MXID", "NONAME"])
        XCTAssertFalse(devices.contains { $0.id == "PHONE" })
        XCTAssertEqual(devices[0].lastSeen, Date(timeIntervalSince1970: 1_762_790_000))
    }

    /// A row shows the name the device gave itself, never an ID: an empty
    /// name, the device ID or a Matrix ID read as "Another device".
    func testNamesNeverExposeAnIdentifier() throws {
        let devices = try XCTUnwrap(AccountDeviceList.parse(devicesJSON, currentDeviceID: "PHONE"))
        let names = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.name) })
        XCTAssertEqual(names["NEWMAC"], "Studio")
        XCTAssertEqual(names["OLDMAC"], "MacBook Pro")
        XCTAssertEqual(names["NONAME"], .some(nil))
        XCTAssertEqual(names["SELFNAMED"], .some(nil))
        XCTAssertEqual(names["MXID"], .some(nil))
    }

    func testAnUnreadableAnswerIsAFailedReadNotAnEmptyList() {
        XCTAssertNil(AccountDeviceList.parse(Data("{}".utf8), currentDeviceID: "PHONE"))
        XCTAssertNil(AccountDeviceList.parse(Data("not json".utf8), currentDeviceID: "PHONE"))
        XCTAssertEqual(AccountDeviceList.parse(Data(#"{"devices":[]}"#.utf8), currentDeviceID: "PHONE"), [])
    }

    /// Desktop `seenAgo`: minutes within the hour, hours within the day, then days.
    func testLastActiveUsesDesktopUnits() {
        let now = Date(timeIntervalSince1970: 1_762_800_000)
        XCTAssertEqual(AccountDeviceSeen.ago(now.addingTimeInterval(-25 * 60), now: now, locale: "en"),
                       "25 minutes ago")
        XCTAssertEqual(AccountDeviceSeen.ago(now.addingTimeInterval(-2 * 3_600), now: now, locale: "en"),
                       "2 hours ago")
        XCTAssertEqual(AccountDeviceSeen.ago(now.addingTimeInterval(-3 * 86_400), now: now, locale: "en"),
                       "3 days ago")
        XCTAssertEqual(AccountDeviceSeen.ago(now.addingTimeInterval(-86_400), now: now, locale: "en"),
                       "yesterday")
        XCTAssertFalse(AccountDeviceSeen.ago(now.addingTimeInterval(-2 * 3_600), now: now, locale: "vi")
            .contains("hours"))
    }

    /// Only an HTTPS page for exactly the device-delete action and that device
    /// is opened; the server's page then asks the person to confirm.
    func testSignOutPageIsExactlyTheServersConfirmationPage() {
        let good = "https://account.atum.invalid/account/?action=org.matrix.device_delete&device_id=OLDMAC"
        XCTAssertEqual(AccountDeviceSignOut.validatedURL(good, deviceID: "OLDMAC")?.absoluteString, good)
        XCTAssertNil(AccountDeviceSignOut.validatedURL(good, deviceID: "NEWMAC"))
        XCTAssertNil(AccountDeviceSignOut.validatedURL(nil, deviceID: "OLDMAC"))
        XCTAssertNil(AccountDeviceSignOut.validatedURL(
            "http://account.atum.invalid/?action=org.matrix.device_delete&device_id=OLDMAC", deviceID: "OLDMAC"))
        XCTAssertNil(AccountDeviceSignOut.validatedURL(
            "https://account.atum.invalid/?action=org.matrix.devices_list&device_id=OLDMAC", deviceID: "OLDMAC"))
        var withCredentials = URLComponents(string: good)!
        withCredentials.user = "user"
        withCredentials.password = "pass"
        XCTAssertNil(AccountDeviceSignOut.validatedURL(withCredentials.string, deviceID: "OLDMAC"))
    }

    func testRecoveryStatusFollowsDesktopRecoveryRow() {
        XCTAssertEqual(AccountRecoveryStatus(recovery: .ready, holdsRecoveryKey: false), .on)
        XCTAssertEqual(AccountRecoveryStatus(recovery: .available, holdsRecoveryKey: false), .on)
        XCTAssertEqual(AccountRecoveryStatus(recovery: .unavailable, holdsRecoveryKey: false), .off)
        XCTAssertEqual(AccountRecoveryStatus(recovery: .unknown, holdsRecoveryKey: false), .unknown)
        XCTAssertEqual(AccountRecoveryStatus(recovery: nil, holdsRecoveryKey: false), .unknown)
        XCTAssertEqual(AccountRecoveryStatus(recovery: .unavailable, holdsRecoveryKey: true), .on)
    }

    /// Every word the devices and recovery rows use is exported desktop copy,
    /// in all five locales, with no Mac-only wording among them.
    func testDeviceAndRecoveryWordsAreExportedInEveryLocale() throws {
        let copy = try AtumCopy()
        for locale in copy.locales {
            for key in SecurityCopyKey.all {
                let arguments: [AtumCopy.Argument] = key == SecurityCopyKey.seen ? [.text("2")] : []
                let text = try copy.text(key, locale: locale, arguments: arguments)
                XCTAssertFalse(text.isEmpty, "\(locale) \(key)")
                if locale == "en" { XCTAssertFalse(text.contains("Mac"), key) }
            }
            XCTAssertFalse(try copy.text("desktop.atum.protons.checking", locale: locale).isEmpty)
        }
    }
}
