import Foundation

/// One prepared local attachment handed across the pure timeline-source seam.
/// Paths are opaque to AtumChat; only the app's SDK adapter reads them.
public struct OutgoingChatAttachment: Identifiable, Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case image(width: UInt64, height: UInt64, isAnimated: Bool)
        case file
    }

    public let id: String
    public let kind: Kind
    public let filePath: String
    public let thumbnailPath: String?
    public let filename: String
    public let mimetype: String
    public let byteSize: UInt64

    public init(id: String, kind: Kind, filePath: String,
                thumbnailPath: String? = nil, filename: String,
                mimetype: String, byteSize: UInt64) {
        self.id = id
        self.kind = kind
        self.filePath = filePath
        self.thumbnailPath = thumbnailPath
        self.filename = filename
        self.mimetype = mimetype
        self.byteSize = byteSize
    }
}
