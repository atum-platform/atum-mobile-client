import XCTest
@testable import AtumDrive

final class DriveStageACopyTests: XCTestCase {
    func testExportedFragmentHasEveryKeyInEveryLocale() throws {
        let copy = try DriveStageACopy()
        XCTAssertEqual(DriveStageACopy.sourceRevision,
                       "2bc7ea5170510a53d2b6608d7304e61fadc539ca")
        for locale in DriveStageACopy.locales {
            for key in DriveStageACopy.keys {
                XCTAssertFalse(try copy.text(key, locale: locale).isEmpty)
            }
        }
        XCTAssertEqual(try copy.text("keepOffline", locale: "zh-Hant"),
                       "保留供離線使用")
    }

    func testUnknownKeyOrLocaleFailsClosed() throws {
        let copy = try DriveStageACopy()
        XCTAssertThrowsError(try copy.text("unknown", locale: "en"))
        XCTAssertThrowsError(try copy.text("keepOffline", locale: "fr"))
    }
}
