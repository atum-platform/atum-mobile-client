import Foundation
import XCTest
@testable import AtumDrive
@testable import AtumNativeAPI

/// The phone's port of desktop Drive's Finder arrangement (atum-desktop
/// `drive-finder.test.ts`, `drive-groups.test.ts`): sort, group, search,
/// stored choices and the swipeable preview's items.
final class DriveArrangementTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!
    /// 2027-06-14 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_812_974_400)

    private func file(_ name: String, size: Int64 = 1, modified: Date? = nil,
                      mime: String? = nil) throws -> DriveItem {
        try DriveItem(
            id: "storage$space!" + name, name: name, kind: .file, etag: "e", size: size,
            webDavURL: URL(string: "https://drive.atum.test/dav/spaces/storage$space/x")!,
            modifiedAt: modified, mimeType: mime
        )
    }

    private func folder(_ name: String, modified: Date? = nil) throws -> DriveItem {
        try DriveItem(id: "storage$space!" + name, name: name, kind: .folder, etag: "e",
                      size: 4_096, webDavURL: nil, modifiedAt: modified)
    }

    private func days(_ count: Double) -> Date { now.addingTimeInterval(-count * 86_400) }

    // MARK: Sort

    func testNamesSortAsAPersonReadsThemWithFoldersMixedIn() throws {
        let items = [try file("Report 10.pdf"), try folder("photos"), try file("report 2.pdf"),
                     try file("Ảnh.png"), try file("Budget.xlsx")]
        XCTAssertEqual(DriveArrangement.sort(items, by: .name, locale: en).map(\.name),
                       ["Ảnh.png", "Budget.xlsx", "photos", "report 2.pdf", "Report 10.pdf"])
        XCTAssertEqual(DriveArrangement.sort(items, by: DriveSort(key: .name, ascending: false),
                                             locale: en).map(\.name),
                       ["Report 10.pdf", "report 2.pdf", "photos", "Budget.xlsx", "Ảnh.png"])
    }

    func testSizeSortsFoldersBelowTheSmallestFileAndBreaksTiesByName() throws {
        let items = [try file("b.bin", size: 10), try folder("Folder"), try file("a.bin", size: 10),
                     try file("big.bin", size: 900), try file("empty.txt", size: 0)]
        XCTAssertEqual(DriveArrangement.sort(items, by: DriveSort(key: .size, ascending: false),
                                             locale: en).map(\.name),
                       ["big.bin", "a.bin", "b.bin", "empty.txt", "Folder"])
        XCTAssertEqual(DriveArrangement.sort(items, by: DriveSort(key: .size, ascending: true),
                                             locale: en).map(\.name),
                       ["Folder", "empty.txt", "a.bin", "b.bin", "big.bin"])
    }

    func testModifiedSortsNewestFirstWithUndatedOldest() throws {
        let items = [try file("old", modified: days(9)), try file("undated"),
                     try file("new", modified: days(1)), try folder("mid", modified: days(3))]
        XCTAssertEqual(DriveArrangement.sort(items, by: .recent, locale: en).map(\.name),
                       ["new", "mid", "old", "undated"])
        XCTAssertEqual(DriveArrangement.sort(items, by: DriveSort(key: .modified, ascending: true),
                                             locale: en).map(\.name),
                       ["undated", "old", "mid", "new"])
    }

    func testNextSortFlipsTheSameColumnAndStartsANewOneWhereFinderDoes() {
        XCTAssertEqual(DriveSort.name.next(.name), DriveSort(key: .name, ascending: false))
        XCTAssertEqual(DriveSort.name.next(.modified), DriveSort(key: .modified, ascending: false))
        XCTAssertEqual(DriveSort.name.next(.size), DriveSort(key: .size, ascending: false))
        XCTAssertEqual(DriveSort.recent.next(.name), .name)
        XCTAssertEqual(DriveSort.recent.next(.modified), DriveSort(key: .modified, ascending: true))
    }

    // MARK: Stored choices

    func testStoredChoicesParseOrFallBackToDesktopsDefaults() {
        XCTAssertEqual(DriveLayout.parse(nil), .icons)
        XCTAssertEqual(DriveLayout.parse("list"), .list)
        XCTAssertEqual(DriveLayout.parse("column"), .icons, "a desktop-only view opens as Icons")
        XCTAssertEqual(DriveGroupBy.parse("modified"), .modified)
        XCTAssertEqual(DriveGroupBy.parse("tags"), DriveGroupBy.none)
        XCTAssertEqual(DriveSort.parse("size.desc"), DriveSort(key: .size, ascending: false))
        XCTAssertEqual(DriveSort.parse(DriveSort.recent.storedValue), .recent)
        XCTAssertEqual(DriveSort.parse("kind.asc"), .name)
        XCTAssertEqual(DriveSort.parse("name"), .name)
        XCTAssertEqual([DriveLayout.storageKey, DriveGroupBy.storageKey],
                       ["io.atum.drive.layout", "io.atum.drive.group"], "desktop's keys")
    }

    // MARK: Group By

    private func label(_ key: DriveGroupKey) -> String {
        switch key {
        case .all: ""
        case let .kind(family): ["folder": "Folders", "image": "Images", "pdf": "PDF Documents",
                                 "document": "Documents", "text": "Text Documents",
                                 "spreadsheet": "Spreadsheets", "movie": "Movies",
                                 "other": "Other"][family.rawValue] ?? family.rawValue
        case let .size(band): band.rawValue
        case let .period(period): period.rawValue
        case .month, .year: key.dateLabel(locale: en, timeZone: utc) ?? "?"
        case .undated: "Other"
        }
    }

    func testKindGroupsSortByNameWithOtherLastAndKeepTheSortInside() throws {
        let items = DriveArrangement.sort([
            try file("z.png"), try file("notes.md"), try file("a.HEIC"), try file("plan.pdf"),
            try file("README"), try folder("Work"), try file("clip.mov"), try file("data.json"),
        ], by: .name, locale: en)
        let groups = DriveArrangement.groups(items, by: .kind, now: now, timeZone: utc,
                                             locale: en, label: label)
        XCTAssertEqual(groups.map(\.label),
                       ["code", "Folders", "Images", "Movies", "PDF Documents", "Text Documents", "Other"])
        XCTAssertEqual(groups.first { $0.label == "Images" }?.items.map(\.name), ["a.HEIC", "z.png"])
        XCTAssertEqual(groups.last?.items.map(\.name), ["README"])
    }

    func testSizeGroupsRunLargestFirstThenEmptyThenFolders() throws {
        let items = [try folder("Folder"), try file("tiny", size: 99_999), try file("zero", size: 0),
                     try file("huge", size: 1_000_000_000), try file("mid", size: 10_000_000),
                     try file("mb", size: 1_000_000), try file("kb", size: 100_000),
                     try file("big", size: 100_000_000)]
        let groups = DriveArrangement.groups(items, by: .size, now: now, timeZone: utc,
                                             locale: en, label: label)
        XCTAssertEqual(groups.map(\.label),
                       ["gb", "hundredsMb", "tensMb", "mb", "hundredsKb", "small", "empty", "folders"])
    }

    func testDateGroupsAreTodayYesterdayWeeksMonthsThenYears() throws {
        let items = [
            try file("today", modified: now.addingTimeInterval(-3_600)),
            try file("future", modified: now.addingTimeInterval(86_400)),
            try file("yesterday", modified: days(1)),
            try file("week", modified: days(7)),
            try file("month", modified: days(30)),
            try file("february", modified: Date(timeIntervalSince1970: 1_802_000_000)),
            try file("january", modified: Date(timeIntervalSince1970: 1_799_000_000)),
            try file("lastYear", modified: Date(timeIntervalSince1970: 1_790_000_000)),
            try file("long ago", modified: Date(timeIntervalSince1970: 1_700_000_000)),
            try file("undated"),
        ]
        let groups = DriveArrangement.groups(items, by: .modified, now: now, timeZone: utc,
                                             locale: en, label: label)
        XCTAssertEqual(groups.map(\.label),
                       ["today", "yesterday", "week", "month", "February", "January", "2026", "2023", "Other"])
        XCTAssertEqual(groups.first?.items.map(\.name), ["today", "future"])
    }

    func testMonthAndYearNamesFollowTheLocale() {
        let vi = Locale(identifier: "vi")
        XCTAssertEqual(DriveGroupKey.month(11).dateLabel(locale: en, timeZone: utc), "November")
        XCTAssertEqual(DriveGroupKey.month(11).dateLabel(locale: vi, timeZone: utc)?.lowercased(), "tháng 11")
        XCTAssertEqual(DriveGroupKey.year(2025).dateLabel(locale: en, timeZone: utc), "2025")
        XCTAssertNil(DriveGroupKey.period(.today).dateLabel(locale: en))
    }

    func testDatesAreGregorianWhateverTheDeviceCalendar() throws {
        XCTAssertEqual(DriveArrangement.gregorian(utc).identifier, .gregorian)
        XCTAssertEqual(DriveArrangement.gregorian(utc).timeZone, utc)
        let items = [try file("2026", modified: Date(timeIntervalSince1970: 1_790_000_000)),
                     try file("2023", modified: Date(timeIntervalSince1970: 1_700_000_000))]
        let groups = DriveArrangement.groups(items, by: .modified, now: now, timeZone: utc,
                                             locale: Locale(identifier: "ja_JP@calendar=japanese"),
                                             label: label)
        XCTAssertEqual(groups.map(\.key), [.year(2026), .year(2023)], "Gregorian years, newest first")
        // A Japanese-calendar device still reads the Gregorian year, as desktop's Intl does.
        let ja = Locale(identifier: "ja_JP@calendar=japanese")
        XCTAssertEqual(DriveGroupKey.year(2025).dateLabel(locale: ja, timeZone: utc), "2025年")
        XCTAssertEqual(DriveGroupKey.month(11).dateLabel(locale: ja, timeZone: utc), "11月")
    }

    func testNoGroupingIsOneUnlabelledGroupAndNothingIsNoGroups() throws {
        let items = [try file("a"), try file("b")]
        let groups = DriveArrangement.groups(items, by: .none, now: now, locale: en, label: label)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.label, "")
        XCTAssertEqual(groups.first?.items, items)
        XCTAssertTrue(DriveArrangement.groups([], by: .kind, now: now, locale: en, label: label).isEmpty)
    }

    func testKindFamiliesFoldDesktopsExtensionTable() {
        let expected: [String: DriveKindFamily] = [
            "a.PDF": .pdf, "a.docx": .document, "a.md": .text, "a.log": .text,
            "a.json": .code, "a.swift": .code, "a.csv": .spreadsheet, "a.key": .presentation,
            "a.webp": .image, "a.mkv": .movie, "a.flac": .music, "a.7z": .archive,
            "a.heif": .other, "README": .other, ".env": .other,
        ]
        for (name, family) in expected { XCTAssertEqual(DriveKindFamily.of(name: name), family, name) }
    }

    // MARK: Search

    func testSearchMatchesNamesContainingTheQueryIgnoringCase() throws {
        let items = [try file("Báo cáo Q3.pdf"), try file("Budget.xlsx"), try folder("Photos")]
        let vi = Locale(identifier: "vi")
        XCTAssertEqual(DriveArrangement.filter(items, query: "  BÁO ", locale: vi).map(\.name),
                       ["Báo cáo Q3.pdf"])
        XCTAssertEqual(DriveArrangement.filter(items, query: "o", locale: vi).count, 2)
        XCTAssertEqual(DriveArrangement.filter(items, query: "   ", locale: vi), items)
        XCTAssertTrue(DriveArrangement.filter(items, query: "zzz", locale: vi).isEmpty)
    }

    // MARK: Names

    func testLongNamesAreCutInTheMiddleKeepingTheType() {
        XCTAssertEqual(DriveArrangement.middleTruncated("Short.pdf"), "Short.pdf")
        let cut = DriveArrangement.middleTruncated("Quarterly board meeting notes 2026.docx")
        XCTAssertEqual(cut, "Quarterly b…2026.docx", "spaces at the cut are dropped")
        XCTAssertLessThanOrEqual(cut.count, DriveArrangement.iconLabelLength)
        XCTAssertEqual(DriveArrangement.middleTruncated("Ảnh 👨‍👩‍👧 kỷ niệm của cả gia đình.jpg", max: 12),
                       "Ảnh 👨‍👩‍👧…h.jpg", "a family emoji is one character")
    }

    // MARK: Gallery

    func testTheGalleryFollowsTheGroupedOrderOnScreen() throws {
        // Name A to Z puts a.pdf first, but Kind draws Images above PDF Documents.
        let sorted = DriveArrangement.sort([try file("z.jpg"), try file("a.pdf"), try file("m.png")],
                                           by: .name, locale: en)
        XCTAssertEqual(DriveGalleryPolicy.items(sorted).map(\.name), ["a.pdf", "m.png", "z.jpg"])
        let groups = DriveArrangement.groups(sorted, by: .kind, now: now, timeZone: utc,
                                             locale: en, label: label)
        XCTAssertEqual(DriveGalleryPolicy.items(in: groups).map(\.name), ["m.png", "z.jpg", "a.pdf"])
    }

    func testRenderFailuresSayWhatWentWrongAndWhetherRetryHelps() {
        XCTAssertNil(DriveGalleryRenderFailure.image(decoded: true))
        XCTAssertEqual(DriveGalleryRenderFailure.image(decoded: false), .unreadable)
        XCTAssertNil(DriveGalleryRenderFailure.pdf(opened: true, locked: false, pageCount: 3))
        XCTAssertEqual(DriveGalleryRenderFailure.pdf(opened: false, locked: false, pageCount: 0), .unreadable)
        XCTAssertEqual(DriveGalleryRenderFailure.pdf(opened: true, locked: true, pageCount: 2), .unsupported)
        XCTAssertEqual(DriveGalleryRenderFailure.pdf(opened: true, locked: false, pageCount: 0), .unreadable)
        XCTAssertTrue(DriveGalleryRenderFailure.unreadable.allowsRetry)
        XCTAssertFalse(DriveGalleryRenderFailure.unsupported.allowsRetry)
    }

    func testTheGalleryHoldsPicturesAndPDFsInTheShownOrder() throws {
        let shown = [try file("b.png"), try folder("Folder"), try file("c.pdf"), try file("d.svg"),
                     try file("e.txt"), try file("scan", mime: "application/pdf"),
                     try file("f.HEIC"), try file("g.webp")]
        XCTAssertEqual(DriveGalleryPolicy.items(shown).map(\.name), ["b.png", "c.pdf", "scan", "f.HEIC"])
        XCTAssertEqual(DriveGalleryPolicy.kind(try file("c.pdf")), .pdf)
        XCTAssertEqual(DriveGalleryPolicy.kind(try file("b.png")), .image)
        XCTAssertNil(DriveGalleryPolicy.kind(try file("d.svg")), "active content stays out")
    }
}
