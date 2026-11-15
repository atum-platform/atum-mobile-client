@testable import AtumMobile
import XCTest

/// Drive's share staging (review finding 4): a named file exists only while
/// the share sheet needs it, and only one per Share.
final class DriveShareFileTests: XCTestCase {
    private var source: URL!

    override func setUpWithError() throws {
        source = FileManager.default.temporaryDirectory
            .appendingPathComponent("drive-share-source-" + UUID().uuidString)
        try Data("scan".utf8).write(to: source)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: source)
        DriveShareFile.clear()
        super.tearDown()
    }

    func testStagingNamesTheFileAndDiscardRemovesIt() throws {
        let staged = try XCTUnwrap(DriveShareFile.make(from: source, name: "Hợp đồng 2026.pdf"))
        XCTAssertEqual(staged.lastPathComponent, "Hợp đồng 2026.pdf")
        XCTAssertEqual(try Data(contentsOf: staged), Data("scan".utf8))
        DriveShareFile.discard(staged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the cached file stays")
    }

    func testDiscardTouchesOnlyStagedFiles() throws {
        DriveShareFile.discard(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testAMissingSourceStagesNothingAndClearEmptiesTheFolder() throws {
        XCTAssertNil(DriveShareFile.make(from: source.appendingPathExtension("gone"), name: "x.pdf"))
        let one = try XCTUnwrap(DriveShareFile.make(from: source, name: "a.jpg"))
        let two = try XCTUnwrap(DriveShareFile.make(from: source, name: "a.jpg"))
        XCTAssertNotEqual(one, two)
        DriveShareFile.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: one.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: two.path))
    }

    func testThePageFailureWordsExistInEveryLocale() {
        for key in ["preview.error", "preview.unavailable", "preview.loading"] {
            let locales = Set(DrivePendingCopy.desktop[key].map { Array($0.keys) } ?? [])
            XCTAssertEqual(locales, ["en", "vi", "ja", "zh", "zh-Hant"], key)
        }
    }
}
