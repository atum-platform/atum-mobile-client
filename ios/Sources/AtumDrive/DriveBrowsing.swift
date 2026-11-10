import Foundation
import AtumNativeAPI

/// What a file is to the person who owns it, as the desktop draws it
/// (atum-app `src/matrix/file-glyph.tsx` at 050ede8edf5): a document, a sheet,
/// slides, a photo, a sound, a film or an archive, by its extension alone.
/// Shapes, not lettering: a PDF is a document, never a "PDF" stamp.
public enum DriveFileFamily: String, CaseIterable, Sendable {
    case folder
    case document
    case spreadsheet
    case presentation
    case image
    case audio
    case video
    case archive
    case other

    public static func of(_ item: DriveItem) -> DriveFileFamily {
        item.kind == .folder ? .folder : of(name: item.name)
    }

    public static func of(name: String) -> DriveFileFamily {
        guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return .other }
        let ext = name[name.index(after: dot)...].lowercased()
        return extensions.first { $0.1.contains(ext) }?.0 ?? .other
    }

    private static let extensions: [(DriveFileFamily, Set<String>)] = [
        (.document, ["doc", "docx", "odt", "rtf", "pages", "pdf", "txt", "md", "markdown", "text"]),
        (.spreadsheet, ["xls", "xlsx", "ods", "numbers", "csv", "tsv"]),
        (.presentation, ["ppt", "pptx", "odp", "key"]),
        (.image, ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg"]),
        (.audio, ["mp3", "m4a", "wav", "aac", "flac", "ogg", "aif", "aiff"]),
        (.video, ["mp4", "mov", "m4v", "avi", "mkv", "webm"]),
        (.archive, ["zip", "rar", "7z", "tar", "gz", "tgz"]),
    ]
}

/// The desktop Drive's two places (`MatrixDriveDestination`): Recents, the
/// default, and All files.
public enum DriveDestination: String, CaseIterable, Identifiable, Sendable {
    case recents
    case all

    public var id: String { rawValue }
}

/// Desktop `recentDriveRows`: there is no activity feed yet, so recency is the
/// item's modified time, newest first, then the name. An item without a time
/// goes last.
public enum DriveRecents {
    /// Desktop draws the four newest as large tiles above the list.
    public static let tileCount = 4

    public static func order(_ items: [DriveItem]) -> [DriveItem] {
        items.sorted { left, right in
            switch (left.modifiedAt, right.modifiedAt) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
        }
    }

    public static func tiles(_ items: [DriveItem]) -> [DriveItem] {
        Array(order(items).prefix(tileCount))
    }
}

/// Desktop's Drive times (`formatDriveSyncTime`, `formatModified`): the time
/// today, the date (and for a sync, the time) before today.
public enum DriveTimeFormat {
    /// "Up to date · 14:32": when this listing last came from the server.
    public static func syncTime(_ at: Date, now: Date, locale: Locale,
                                timeZone: TimeZone = .current) -> String {
        formatter(locale: locale, timeZone: timeZone,
                  date: sameDay(at, now, timeZone: timeZone) ? .none : .medium,
                  time: .short).string(from: at)
    }

    /// A file's modified time as Finder lists it.
    public static func modified(_ at: Date, now: Date, locale: Locale,
                                timeZone: TimeZone = .current) -> String {
        let today = sameDay(at, now, timeZone: timeZone)
        return formatter(locale: locale, timeZone: timeZone,
                         date: today ? .none : .medium,
                         time: today ? .short : .none).string(from: at)
    }

    private static func sameDay(_ a: Date, _ b: Date, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.isDate(a, inSameDayAs: b)
    }

    private static func formatter(locale: Locale, timeZone: TimeZone,
                                  date: DateFormatter.Style,
                                  time: DateFormatter.Style) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = date
        formatter.timeStyle = time
        return formatter
    }
}

/// The quiet status line over a listing (desktop `driveStatus`): "Up to date"
/// with when the listing last came from the server, only while nothing else
/// needs saying.
public enum DriveStatusLine: Equatable, Sendable {
    case none
    case upToDate(Date)

    public static func decide(connection: DriveConnectionState,
                              directory: DriveDirectoryPresentation) -> DriveStatusLine {
        guard connection == .ready, directory.condition == .fresh,
              let at = directory.refreshedAt else { return .none }
        return .upToDate(at)
    }
}
