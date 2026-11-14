import XCTest
@testable import AtumChat

/// PENDING-COPY for Approve on this iPhone: every key in all five locales,
/// the one argument kept, and STYLE.md §15's rules (no "!", no "please").
final class PhoneApprovalPendingCopyTests: XCTestCase {
    func testEveryKeyHasAllFiveLocalesWithTheArgumentKept() {
        for locale in PhoneApprovalPendingCopy.locales {
            let table = PhoneApprovalPendingCopy.tables[locale] ?? [:]
            for key in PhoneApprovalPendingCopy.Key.allCases {
                let value = table[key] ?? ""
                XCTAssertFalse(value.isEmpty, "\(locale) \(key)")
                XCTAssertEqual(value.contains("%1$@"), key == .settingsOn, "\(locale) \(key)")
                XCTAssertFalse(value.contains("!") || value.contains("！"), "\(locale) \(key)")
                XCTAssertFalse(value.lowercased().contains("please"), "\(locale) \(key)")
            }
            XCTAssertFalse((PhoneApprovalPendingCopy.faceIDUsage[locale] ?? "").isEmpty, locale)
        }
    }

    func testLocalesResolveAndTheDateIsFilledIn() {
        XCTAssertEqual(PhoneApprovalPendingCopy.text(.settingsOn, locale: "vi", argument: "14 thg 11"),
                       "Đang bật · từ 14 thg 11")
        XCTAssertEqual(PhoneApprovalPendingCopy.text(.setUpAgain, locale: "zh_TW"), "重新設定")
        XCTAssertEqual(PhoneApprovalPendingCopy.text(.setUpAgain, locale: "zh-Hans"), "重新设置")
        XCTAssertEqual(PhoneApprovalPendingCopy.text(.setUpAgain, locale: "ko"), "Set up again")
        XCTAssertEqual(PhoneApprovalPendingCopy.Key.enrollOffline.exportKey, "desktop.cloud.enrollFailure.offline")
        XCTAssertEqual(PhoneApprovalPendingCopy.Key.settingsTitle.exportKey,
                       "src.matrix.mobile-device-copy.mobileDeviceCopy.approvalSettingsTitle")
    }
}
