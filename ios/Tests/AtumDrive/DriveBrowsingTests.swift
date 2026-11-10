import Foundation
import XCTest
@testable import AtumDrive
@testable import AtumNativeAPI

final class DriveBrowsingTests: XCTestCase {
    private func file(_ name: String, id: String? = nil, modified: Date? = nil) throws -> DriveItem {
        try DriveItem(
            id: id ?? "storage$space!" + name, name: name, kind: .file, etag: "e", size: 1,
            webDavURL: URL(string: "https://drive.atum.test/dav/spaces/storage$space/\(name)")!,
            modifiedAt: modified
        )
    }

    private func folder(_ name: String, modified: Date? = nil) throws -> DriveItem {
        try DriveItem(id: "storage$space!" + name, name: name, kind: .folder, etag: "e",
                      size: 0, webDavURL: nil, modifiedAt: modified)
    }

    func testFamiliesFollowTheDesktopExtensionTable() {
        let expected: [String: DriveFileFamily] = [
            "Plan.docx": .document, "Report.PDF": .document, "notes.md": .document,
            "Budget.xlsx": .spreadsheet, "export.csv": .spreadsheet, "Q3.numbers": .spreadsheet,
            "Pitch.pptx": .presentation, "Talk.key": .presentation,
            "IMG_0001.HEIC": .image, "logo.svg": .image, "scan.tiff": .image,
            "memo.m4a": .audio, "song.flac": .audio,
            "clip.mov": .video, "film.webm": .video,
            "backup.zip": .archive, "src.tgz": .archive,
            "README": .other, ".env": .other, "data.bin": .other,
        ]
        for (name, family) in expected {
            XCTAssertEqual(DriveFileFamily.of(name: name), family, name)
        }
    }

    func testAFolderIsAFolderWhateverItsName() throws {
        XCTAssertEqual(DriveFileFamily.of(try folder("Photos.zip")), .folder)
        XCTAssertEqual(DriveFileFamily.of(try file("Photos.zip")), .archive)
    }

    func testRecentsAreNewestFirstThenByNameWithUndatedLast() throws {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let items = [
            try file("b.txt", modified: day),
            try file("old.txt", modified: day.addingTimeInterval(-86_400)),
            try file("undated.txt"),
            try file("a.txt", modified: day),
            try folder("Newest", modified: day.addingTimeInterval(60)),
        ]
        XCTAssertEqual(DriveRecents.order(items).map(\.name),
                       ["Newest", "a.txt", "b.txt", "old.txt", "undated.txt"])
        XCTAssertEqual(DriveRecents.tiles(items).map(\.name),
                       ["Newest", "a.txt", "b.txt", "old.txt"])
        XCTAssertEqual(DriveRecents.tiles(Array(items.prefix(2))).count, 2)
    }

    func testTimesReadTheClockTodayAndTheDateBefore() {
        let utc = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_US")
        // 2027-01-14 14:32 UTC.
        let at = Date(timeIntervalSince1970: 1_799_937_120)
        let sameDay = at.addingTimeInterval(3_600)
        let nextWeek = at.addingTimeInterval(7 * 86_400)

        let today = DriveTimeFormat.syncTime(at, now: sameDay, locale: locale, timeZone: utc)
        XCTAssertTrue(today.contains("2:32"), today)
        XCTAssertFalse(today.contains("2027"), today)

        let before = DriveTimeFormat.syncTime(at, now: nextWeek, locale: locale, timeZone: utc)
        XCTAssertTrue(before.contains("2027") && before.contains("2:32"), before)

        XCTAssertFalse(DriveTimeFormat.modified(at, now: sameDay, locale: locale, timeZone: utc)
            .contains("2027"))
        let modified = DriveTimeFormat.modified(at, now: nextWeek, locale: locale, timeZone: utc)
        XCTAssertTrue(modified.contains("2027") && !modified.contains("2:32"), modified)
    }

    func testStatusLineOnlyForAFreshListingOfAReadyDrive() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = DriveDirectoryPresentation(condition: .fresh, refreshedAt: at)
        XCTAssertEqual(DriveStatusLine.decide(connection: .ready, directory: fresh), .upToDate(at))
        XCTAssertEqual(DriveStatusLine.decide(connection: .offline, directory: fresh), .none)
        XCTAssertEqual(DriveStatusLine.decide(
            connection: .ready,
            directory: DriveDirectoryPresentation(condition: .stale, refreshedAt: at)), .none)
        XCTAssertEqual(DriveStatusLine.decide(
            connection: .ready,
            directory: DriveDirectoryPresentation(condition: .fresh)), .none)
    }
}
