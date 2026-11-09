import Foundation

/// The visible classification for a media file.  This deliberately names
/// exported glyph aliases and copy keys, rather than platform symbols or
/// translated words, so the pure chat core remains independent of SwiftUI and
/// of the Matrix SDK.
public enum MediaKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case pdf
    case document
    case spreadsheet
    case presentation
    case archive
    case video
    case audio
    case image
    case other

    /// S4's exported glyph alias. The app resolves this through the committed
    /// design bundle; it must never substitute a raw SF Symbol name.
    public var glyphAlias: String {
        switch self {
        case .pdf: "FileTypePdf"
        case .document: "FileText"
        case .spreadsheet: "FileSpreadsheet"
        case .presentation: "FileTypePpt"
        case .archive: "FileZip"
        case .video: "Movie"
        case .audio: "FileMusic"
        case .image: "FileImage"
        case .other: "File"
        }
    }

    /// The copy key for S4's kind word. File sizes are intentionally never a
    /// presentation fact.
    public var copyKey: ChatCopyKey {
        switch self {
        case .pdf: .mediaKindPDF
        case .document: .mediaKindDocument
        case .spreadsheet: .mediaKindSpreadsheet
        case .presentation: .mediaKindPresentation
        case .archive: .mediaKindArchive
        case .video: .mediaKindVideo
        case .audio: .mediaKindAudio
        case .image: .photo
        case .other: .file
        }
    }

    /// S4 classifies from a declared MIME type before consulting the filename.
    /// MIME parameters and case are transport details, not separate kinds.
    public init(mimetype: String?, filename: String?) {
        if let mimetype = Self.normalizedMimetype(mimetype), let kind = Self.kind(forMimetype: mimetype) {
            self = kind
        } else {
            self = Self.kind(forExtension: Self.fileExtension(filename)) ?? .other
        }
    }

    /// SVG is a file row even when Matrix carries it as `m.image`: homeservers
    /// do not reliably thumbnail it. Other image media use the image
    /// presentation. This retains the MIME fact that `MediaKind` deliberately
    /// normalizes away for its file-card classification.
    public static func usesImagePresentation(mimetype: String?, filename: String?) -> Bool {
        guard Self(mimetype: mimetype, filename: filename) == .image else { return false }
        return normalizedMimetype(mimetype) != "image/svg+xml"
    }

    private static func normalizedMimetype(_ value: String?) -> String? {
        guard let value else { return nil }
        let mediaType = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType?.isEmpty == false ? mediaType : nil
    }

    private static func fileExtension(_ filename: String?) -> String? {
        guard let filename else { return nil }
        let name = filename.split(separator: "?", maxSplits: 1).first.map(String.init) ?? filename
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    private static func kind(forMimetype value: String) -> MediaKind? {
        if value == "application/pdf" { return .pdf }

        if value.contains("msword") || value.contains("wordprocessingml") ||
            ["application/rtf", "application/x-rtf", "text/rtf", "text/plain", "text/markdown"].contains(value) {
            return .document
        }

        if value.contains("ms-excel") || value.contains("spreadsheetml") || value == "text/csv" {
            return .spreadsheet
        }

        if value.contains("ms-powerpoint") || value.contains("presentationml") {
            return .presentation
        }

        if ["application/zip", "application/x-zip-compressed", "application/x-7z-compressed",
            "application/x-rar-compressed", "application/vnd.rar", "application/gzip",
            "application/x-gzip", "application/x-tar"].contains(value) {
            return .archive
        }

        if value.hasPrefix("video/") { return .video }
        if value.hasPrefix("audio/") { return .audio }
        if value.hasPrefix("image/") { return .image }
        return nil
    }

    private static func kind(forExtension value: String?) -> MediaKind? {
        guard let value else { return nil }
        return switch value {
        case "pdf": .pdf
        case "doc", "docx", "pages", "rtf", "txt", "md": .document
        case "xls", "xlsx", "csv", "numbers": .spreadsheet
        case "ppt", "pptx", "key": .presentation
        case "zip", "7z", "rar", "gz", "tar": .archive
        default: nil
        }
    }
}

/// Whether a picked attachment is a processed library photo or an exact file.
/// The picker/importer reports readability and byte length before an item can
/// enter the tray, so upload refusal is deterministic and has no UI imports.
public enum MediaAttachmentKind: Equatable, Hashable, Sendable {
    case photo
    case file
}

public struct MediaAttachmentCandidate: Equatable, Hashable, Sendable {
    public var kind: MediaAttachmentKind
    /// Nil means the importer could not establish a readable length.
    public var byteSize: UInt64?
    public var isReadable: Bool

    public init(kind: MediaAttachmentKind, byteSize: UInt64?, isReadable: Bool = true) {
        self.kind = kind
        self.byteSize = byteSize
        self.isReadable = isReadable
    }
}

/// The one S4 refusal line, expressed as a copy fact. The view resolves the
/// copy key and its argument; it never learns the homeserver byte limit.
public enum MediaAttachmentRefusal: Equatable, Hashable, Sendable {
    case tooMany(limit: Int)
    case tooLargePhoto
    case tooLargeFile
    case tooLargeSome(count: Int)
    case unreadable

    public var copyKey: ChatCopyKey {
        switch self {
        case .tooMany: .mediaTooMany
        case .tooLargePhoto: .mediaTooLargePhoto
        case .tooLargeFile: .mediaTooLargeFile
        case .tooLargeSome: .mediaTooLargeSome
        case .unreadable: .mediaUnreadable
        }
    }

    public var numberArgument: Int? {
        switch self {
        case let .tooMany(limit): limit
        case let .tooLargeSome(count): count
        case .tooLargePhoto, .tooLargeFile, .unreadable: nil
        }
    }
}

public struct MediaAttachmentDecision: Equatable, Sendable {
    /// Indices into the input batch, in picker order, that the caller stages.
    public var acceptedIndices: [Int]
    /// S4 allows exactly one refusal line, resolved by its prescribed priority.
    public var refusal: MediaAttachmentRefusal?

    public init(acceptedIndices: [Int], refusal: MediaAttachmentRefusal?) {
        self.acceptedIndices = acceptedIndices
        self.refusal = refusal
    }
}

/// Pure S4 attachment admission. It enforces the ten-item tray, uses the
/// server's advertised max-upload size when available (20 MiB only when that
/// read fails), and keeps a valid subset in source order.
public enum MediaAttachmentPolicy {
    public static let maximumItems = 10
    public static let fallbackUploadLimit: UInt64 = 20 * 1024 * 1024

    public static func decide(stagedCount: Int, candidates: [MediaAttachmentCandidate],
                              uploadLimit: UInt64?) -> MediaAttachmentDecision {
        let slots = max(0, maximumItems - max(0, stagedCount))
        let considered = Array(candidates.prefix(slots))
        let limit = uploadLimit ?? fallbackUploadLimit

        var accepted = [Int]()
        var tooLarge = [MediaAttachmentCandidate]()
        var hasUnreadable = false

        for (index, candidate) in considered.enumerated() {
            guard candidate.isReadable, let byteSize = candidate.byteSize, byteSize > 0 else {
                hasUnreadable = true
                continue
            }
            guard byteSize <= limit else {
                tooLarge.append(candidate)
                continue
            }
            accepted.append(index)
        }

        // The UI reports a cap first. Entries beyond the available slots are
        // deliberately not inspected: they were never admitted to this pick.
        if candidates.count > slots {
            return MediaAttachmentDecision(acceptedIndices: accepted,
                                           refusal: .tooMany(limit: maximumItems))
        }

        if tooLarge.count > 1 {
            return MediaAttachmentDecision(acceptedIndices: accepted,
                                           refusal: .tooLargeSome(count: tooLarge.count))
        }
        if let only = tooLarge.first {
            return MediaAttachmentDecision(acceptedIndices: accepted,
                                           refusal: only.kind == .photo ? .tooLargePhoto : .tooLargeFile)
        }
        if hasUnreadable {
            return MediaAttachmentDecision(acceptedIndices: accepted, refusal: .unreadable)
        }
        return MediaAttachmentDecision(acceptedIndices: accepted, refusal: nil)
    }
}
