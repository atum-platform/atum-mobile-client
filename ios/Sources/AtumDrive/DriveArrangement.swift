import Foundation
import AtumNativeAPI

// The phone's port of desktop Drive's Finder arrangement (atum-desktop PRs
// #43–#45: `drive-finder.ts` and `drive-groups.ts`). It is pure: the app
// supplies the words, the locale and the clock. See docs/ports/drive-revamp.md.

/// Desktop's Icons and List views (`MatrixDriveLayout`). Columns and Gallery
/// are Finder shapes the phone draws differently: folders push, and an image
/// or PDF opens the swipeable preview.
public enum DriveLayout: String, CaseIterable, Sendable {
    case icons = "icon"
    case list

    /// The same key desktop keeps the view under (`io.atum.drive.layout`).
    public static let storageKey = "io.atum.drive.layout"

    /// A stored view, or Icons (as desktop and Finder open) for anything else.
    public static func parse(_ value: String?) -> DriveLayout {
        value.flatMap(DriveLayout.init(rawValue:)) ?? .icons
    }
}

/// Desktop's list columns: Name, Modified, Size.
public enum DriveSortKey: String, CaseIterable, Sendable {
    case name, modified, size
}

/// One sort: a column and its direction (`MatrixDriveSort`).
public struct DriveSort: Equatable, Hashable, Sendable {
    public var key: DriveSortKey
    public var ascending: Bool

    public init(key: DriveSortKey, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// `DRIVE_NAME_ORDER`: All files and every folder open by name.
    public static let name = DriveSort(key: .name, ascending: true)
    /// `DRIVE_RECENT_ORDER`: Recents opens newest first.
    public static let recent = DriveSort(key: .modified, ascending: false)

    /// The phone remembers the folder sort; Recents keeps desktop's
    /// per-visit order.
    public static let storageKey = "io.atum.drive.sort"

    /// `nextDriveSort`: the same column flips; a new one starts where Finder
    /// starts it (names A to Z, dates and sizes largest first).
    public func next(_ key: DriveSortKey) -> DriveSort {
        if key == self.key { return DriveSort(key: key, ascending: !ascending) }
        return DriveSort(key: key, ascending: key == .name)
    }

    /// "name.asc", "modified.desc", …
    public var storedValue: String { key.rawValue + (ascending ? ".asc" : ".desc") }

    public static func parse(_ value: String?, default fallback: DriveSort = .name) -> DriveSort {
        guard let parts = value?.split(separator: "."), parts.count == 2,
              let key = DriveSortKey(rawValue: String(parts[0])),
              parts[1] == "asc" || parts[1] == "desc" else { return fallback }
        return DriveSort(key: key, ascending: parts[1] == "asc")
    }
}

/// Finder's Group By choices desktop has data for (`MatrixDriveGroupBy`).
public enum DriveGroupBy: String, CaseIterable, Sendable {
    case none, kind, modified, size

    /// Desktop's key (`io.atum.drive.group`).
    public static let storageKey = "io.atum.drive.group"

    /// A stored grouping, or none (Finder's default) for anything else.
    public static func parse(_ value: String?) -> DriveGroupBy {
        value.flatMap(DriveGroupBy.init(rawValue:)) ?? .none
    }
}

/// Finder's broad kinds (`DriveKindFamily`): a JPEG, a PNG and a HEIC photo are
/// all Images. Desktop's `consumerFileKind` extension table, folded as
/// `drive-groups.ts` folds it.
public enum DriveKindFamily: String, CaseIterable, Sendable {
    case folder, image, pdf, document, text, spreadsheet, presentation
    case movie, music, archive, code, other

    public static func of(_ item: DriveItem) -> DriveKindFamily {
        item.kind == .folder ? .folder : of(name: item.name)
    }

    public static func of(name: String) -> DriveKindFamily {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return .other }
        return byExtension[name[name.index(after: dot)...].lowercased()] ?? .other
    }

    private static let byExtension: [String: DriveKindFamily] = {
        let table: [(DriveKindFamily, [String])] = [
            (.archive, ["7z", "gz", "rar", "tar", "tgz", "zip"]),
            (.music, ["aac", "flac", "m4a", "mp3", "ogg", "wav"]),
            // Desktop's `code` and `data` kinds are both Code.
            (.code, ["c", "cpp", "cs", "css", "go", "h", "html", "htm", "java", "js", "jsx", "kt",
                     "mjs", "php", "py", "rb", "rs", "scss", "sh", "sql", "swift", "ts", "tsx",
                     "xml", "json", "toml", "yaml", "yml"]),
            (.spreadsheet, ["csv", "numbers", "ods", "xls", "xlsx"]),
            (.document, ["doc", "docx", "odt", "pages", "rtf"]),
            (.image, ["bmp", "gif", "heic", "jpeg", "jpg", "png", "svg", "tiff", "webp"]),
            // Desktop's `markdown` and `text` kinds are both Text Documents.
            (.text, ["markdown", "md", "log", "txt"]),
            (.pdf, ["pdf"]),
            (.presentation, ["key", "odp", "ppt", "pptx"]),
            (.movie, ["avi", "m4v", "mkv", "mov", "mp4", "webm"]),
        ]
        var map = [String: DriveKindFamily]()
        for (family, extensions) in table { for ext in extensions { map[ext] = family } }
        return map
    }()
}

/// Desktop's size groups, largest first, then empty files, then folders.
public enum DriveSizeBand: String, CaseIterable, Sendable {
    case gb, hundredsMb, tensMb, mb, hundredsKb, small, empty, folders

    private static let floors: [(DriveSizeBand, Int64)] = [
        (.gb, 1_000_000_000), (.hundredsMb, 100_000_000), (.tensMb, 10_000_000),
        (.mb, 1_000_000), (.hundredsKb, 100_000), (.small, 1),
    ]

    public static func of(_ item: DriveItem) -> DriveSizeBand {
        guard item.kind == .file else { return .folders }
        return floors.first { item.size >= $0.1 }?.0 ?? .empty
    }
}

/// Desktop's named date groups; older dates group by month this year, then by year.
public enum DriveDatePeriod: String, CaseIterable, Sendable {
    case today, yesterday, week, month
}

/// What a group gathers. The app turns each into words.
public enum DriveGroupKey: Hashable, Sendable {
    case all
    case kind(DriveKindFamily)
    case size(DriveSizeBand)
    case period(DriveDatePeriod)
    /// A month of the current year, 1…12.
    case month(Int)
    case year(Int)
    /// Phone-only: the listing may omit a modified time; those items close the list.
    case undated

    public var id: String {
        switch self {
        case .all: "all"
        case let .kind(family): "kind:" + family.rawValue
        case let .size(band): "size:" + band.rawValue
        case let .period(period): period.rawValue
        case let .month(month): "month:\(month)"
        case let .year(year): "year:\(year)"
        case .undated: "undated"
        }
    }

    /// A month's or a year's name as `Intl.DateTimeFormat` writes it
    /// (`{ month: 'long' }`, `{ year: 'numeric' }`), in the Gregorian
    /// calendar as desktop's are; nil for the named groups.
    public func dateLabel(locale: Locale, timeZone: TimeZone = .current) -> String? {
        var components = DateComponents()
        let template: String
        switch self {
        case let .month(month):
            components.year = 2_001
            components.month = month
            components.day = 1
            template = "LLLL"
        case let .year(year):
            components.year = year
            components.month = 6
            components.day = 1
            template = "y"
        default:
            return nil
        }
        // The locale's words without its calendar preference: a
        // `@calendar=japanese` locale would otherwise write "西暦2025年".
        var parts = Locale.components(fromIdentifier: locale.identifier)
        parts.removeValue(forKey: "calendar")
        let plain = Locale(identifier: Locale.identifier(fromComponents: parts))
        var calendar = DriveArrangement.gregorian(timeZone)
        calendar.locale = plain
        guard let date = calendar.date(from: components) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = plain
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

public struct DriveGroup: Identifiable, Equatable, Sendable {
    public let key: DriveGroupKey
    /// Empty for the single group of an ungrouped listing.
    public let label: String
    public let items: [DriveItem]

    public var id: String { key.id }
}

public enum DriveArrangement {
    /// Desktop cuts an icon's name at 22 characters (`ICON_LABEL_LENGTH`).
    public static let iconLabelLength = 22

    /// Desktop's dates are Gregorian in the local time zone (JavaScript
    /// `Date`), whatever calendar the device uses: a Japanese-calendar
    /// iPhone still groups by 2025, not by an era year.
    public static func gregorian(_ timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// `sortDriveRows`: names as a person reads them ("Report 2" before
    /// "Report 10", case and accents aside), folders mixed in. A folder has no
    /// size of its own and sorts below the smallest file. Ties keep the
    /// listing's order, as desktop's stable sort does. An item without a
    /// modified time counts as the oldest.
    public static func sort(_ items: [DriveItem], by sort: DriveSort, locale: Locale) -> [DriveItem] {
        items.enumerated().sorted { left, right in
            let a = left.element, b = right.element
            if sort.key == .modified {
                let l = a.modifiedAt ?? .distantPast, r = b.modifiedAt ?? .distantPast
                if l != r { return sort.ascending ? l < r : l > r }
            }
            if sort.key == .size {
                let l = a.kind == .folder ? -1 : a.size
                let r = b.kind == .folder ? -1 : b.size
                if l != r { return sort.ascending ? l < r : l > r }
            }
            let order = compareNames(a.name, b.name, locale: locale)
            if order != .orderedSame {
                // Only the Name column flips the names; the others break ties A to Z.
                let ascending = sort.key == .name ? sort.ascending : true
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return left.offset < right.offset
        }.map(\.element)
    }

    /// Desktop's local search: the names that contain the query, ignoring case.
    /// An empty query keeps everything.
    public static func filter(_ items: [DriveItem], query: String, locale: Locale) -> [DriveItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: locale)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.name.lowercased(with: locale).contains(needle) }
    }

    /// `groupDriveRows`: split items, already in their sort order, into
    /// Finder's groups; each group keeps that order. Kinds sort by their name
    /// with Other last; sizes and dates by rank. Ungrouped is one unlabelled group.
    public static func groups(_ items: [DriveItem], by groupBy: DriveGroupBy, now: Date,
                              timeZone: TimeZone = .current, locale: Locale,
                              label: (DriveGroupKey) -> String) -> [DriveGroup] {
        guard !items.isEmpty else { return [] }
        let calendar = gregorian(timeZone)
        guard groupBy != .none else { return [DriveGroup(key: .all, label: "", items: items)] }

        var order = [DriveGroupKey]()
        var members = [DriveGroupKey: [DriveItem]]()
        var ranks = [DriveGroupKey: Int]()
        for item in items {
            let (key, rank) = place(item, by: groupBy, now: now, calendar: calendar)
            if members[key] == nil { order.append(key); ranks[key] = rank }
            members[key, default: []].append(item)
        }
        let labels = Dictionary(uniqueKeysWithValues: order.map { ($0, label($0)) })
        let sorted = order.enumerated().sorted { left, right in
            let l = ranks[left.element]!, r = ranks[right.element]!
            if l != r { return l < r }
            if groupBy == .kind {
                let names = compareNames(labels[left.element]!, labels[right.element]!, locale: locale)
                if names != .orderedSame { return names == .orderedAscending }
            }
            return left.offset < right.offset
        }.map(\.element)
        return sorted.map { DriveGroup(key: $0, label: labels[$0]!, items: members[$0]!) }
    }

    /// `middleTruncateDriveName`: Finder cuts a long name in the middle, so
    /// its start and its type both stay readable.
    public static func middleTruncated(_ name: String, max: Int = iconLabelLength) -> String {
        let characters = Array(name)
        guard characters.count > max, max > 2 else { return name }
        let head = Int((Double(max - 1) / 2).rounded(.up))
        let tail = (max - 1) / 2
        let start = String(characters.prefix(head)).replacingOccurrences(
            of: "\\s+$", with: "", options: .regularExpression)
        let end = String(characters.suffix(tail)).replacingOccurrences(
            of: "^\\s+", with: "", options: .regularExpression)
        return start + "…" + end
    }

    private static func compareNames(_ a: String, _ b: String, locale: Locale) -> ComparisonResult {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive],
                  range: nil, locale: locale)
    }

    private static func place(_ item: DriveItem, by groupBy: DriveGroupBy, now: Date,
                              calendar: Calendar) -> (DriveGroupKey, Int) {
        switch groupBy {
        case .none:
            return (.all, 0)
        case .kind:
            let family = DriveKindFamily.of(item)
            return (.kind(family), family == .other ? 1 : 0)
        case .size:
            let band = DriveSizeBand.of(item)
            return (.size(band), DriveSizeBand.allCases.firstIndex(of: band)!)
        case .modified:
            guard let at = item.modifiedAt else { return (.undated, 100_000) }
            return dateGroup(at, now: now, calendar: calendar)
        }
    }

    /// Today, Yesterday, the previous 7 and 30 days, then each month of this
    /// year and each earlier year. A time ahead of the clock counts as now.
    private static func dateGroup(_ at: Date, now: Date, calendar: Calendar) -> (DriveGroupKey, Int) {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: min(at, now))
        let daysAgo = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        let periods: [DriveDatePeriod] = [.today, .yesterday, .week, .month]
        let period: DriveDatePeriod? = daysAgo <= 0 ? .today : daysAgo == 1 ? .yesterday
            : daysAgo <= 7 ? .week : daysAgo <= 30 ? .month : nil
        if let period { return (.period(period), periods.firstIndex(of: period)!) }
        let year = calendar.component(.year, from: at)
        let thisYear = calendar.component(.year, from: now)
        if year == thisYear {
            let month = calendar.component(.month, from: at)
            return (.month(month), 100 + (12 - month))
        }
        return (.year(year), 1_000 + (thisYear - year))
    }
}

/// What the phone's swipeable preview shows: pictures and PDFs, in the order
/// the folder lists them. Anything QuickLook must not render (active content,
/// `DrivePreviewPolicy`) stays out.
public enum DriveGalleryPolicy {
    public enum Kind: Equatable, Sendable { case image, pdf }

    private static let images: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp",
    ]

    public static func kind(_ item: DriveItem) -> Kind? {
        guard item.kind == .file, DrivePreviewPolicy.allowsQuickLook(item) else { return nil }
        let ext = (item.name as NSString).pathExtension.lowercased()
        let mime = item.mimeType?.lowercased()
        if ext == "pdf" || (ext.isEmpty && mime == "application/pdf") { return .pdf }
        if images.contains(ext) || (ext.isEmpty && mime?.hasPrefix("image/") == true) { return .image }
        return nil
    }

    public static func items(_ shown: [DriveItem]) -> [DriveItem] {
        shown.filter { kind($0) != nil }
    }

    /// The gallery's pages in the order the screen draws them: group by
    /// group, each in its sort order.
    public static func items(in groups: [DriveGroup]) -> [DriveItem] {
        items(groups.flatMap(\.items))
    }
}

/// Why a gallery page that has its file still can't draw it.
public enum DriveGalleryRenderFailure: Equatable, Sendable {
    /// The bytes don't decode (a damaged or partial file): say so and offer
    /// Retry, which downloads it again.
    case unreadable
    /// A PDF that opens but can't be shown here (password-protected): say a
    /// preview isn't available; Share still works. Retry would not help.
    case unsupported

    public var allowsRetry: Bool { self == .unreadable }

    public static func image(decoded: Bool) -> DriveGalleryRenderFailure? {
        decoded ? nil : .unreadable
    }

    public static func pdf(opened: Bool, locked: Bool, pageCount: Int) -> DriveGalleryRenderFailure? {
        guard opened else { return .unreadable }
        if locked { return .unsupported }
        return pageCount > 0 ? nil : .unreadable
    }
}
