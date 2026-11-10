#if DEBUG
import Foundation

/// Synthetic shared photos, files and links for the scripted chat host
/// (`-AtumScriptedShared <mode>`) and the package tests. Synthetic identities
/// and example domains only; no network, no SDK.
public enum ScriptedSharedCollections {
    public static let flag = "-AtumScriptedShared"

    public enum Mode: String, CaseIterable, Sendable {
        /// 36 photos/videos (more than one page), 8 files, 7 links; history ends.
        case ready
        /// Room start reached with nothing shared.
        case empty
        /// A few recent rows, older history never reached; links have none yet.
        case partial
        /// The first history read fails once in every section; Retry recovers.
        case failed
        /// Offline: a cached subset (no links), no history read.
        case offline
    }

    /// The mode a launch asks for: `-AtumScriptedShared` alone means `ready`.
    public static func mode(arguments: [String]) -> Mode? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        guard index + 1 < arguments.count else { return .ready }
        return Mode(rawValue: arguments[index + 1]) ?? .ready
    }

    /// The whole synthetic history of a section in a mode, newest first.
    public static func history(_ section: SharedCollectionSection, mode: Mode) -> [SharedCollectionItem] {
        let count: Int = switch (mode, section) {
        case (.empty, _): 0
        case (.partial, .media): 4
        case (.partial, .files): 2
        case (.partial, .links): 0
        case (.offline, .media): 3
        case (.offline, .files): 1
        case (.offline, .links): 0
        case (_, .media): 36
        case (_, .files): 8
        case (_, .links): 7
        }
        return items(section, count: count)
    }

    static let senders = [ScriptedCast.minhAnh, ScriptedCast.me, ScriptedCast.quan, ScriptedCast.hoa]
    static let newest = Date(timeIntervalSince1970: 1_793_000_000)

    public static func items(_ section: SharedCollectionSection, count: Int) -> [SharedCollectionItem] {
        (0..<count).map { index in
            let eventID = "$shared-\(section.rawValue)-\(index + 1)"
            let sender = senders[index % senders.count]
            let timestamp = newest.addingTimeInterval(-Double(index) * 5_400)
            switch section {
            case .media:
                let isVideo = index % 9 == 4
                let name = isVideo ? "video-\(index + 1).mp4" : "anh-\(index + 1).png"
                let handle = "scripted:shared-\(isVideo ? "video" : "photo")-\(index + 1)"
                let media = ChatMedia(sourceHandle: handle, thumbnailSourceHandle: handle + "-thumbnail",
                                      mimetype: isVideo ? "video/mp4" : "image/png", filename: name,
                                      byteSize: UInt64(180_000 + index * 7_000),
                                      nativeKind: isVideo ? .video : .image)
                return SharedCollectionItem(id: eventID, eventID: eventID, sender: sender, timestamp: timestamp,
                                            kind: isVideo ? .video : .image, name: name, url: nil, media: media,
                                            thumbnail: .content(source: handle + "-thumbnail"))
            case .files:
                let files: [(String, String, SharedCollectionItem.Kind)] = [
                    ("bao-cao-quy-3.pdf", "application/pdf", .file),
                    ("ke-hoach-du-an.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", .file),
                    ("ngan-sach.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", .file),
                    ("ghi-am-cuoc-hop.m4a", "audio/mp4", .audio),
                ]
                let (base, mimetype, kind) = files[index % files.count]
                let name = index < files.count ? base : "\(index + 1)-" + base
                let media = ChatMedia(sourceHandle: "scripted:shared-file-\(index + 1)", mimetype: mimetype,
                                      filename: name, byteSize: UInt64(48_000 + index * 310_000),
                                      nativeKind: kind == .audio ? .audio : nil)
                return SharedCollectionItem(id: eventID, eventID: eventID, sender: sender, timestamp: timestamp,
                                            kind: kind, name: name, url: nil, media: media, thumbnail: nil)
            case .links:
                let urls = ["https://example.com/lich-hop", "https://www.example.org/bao-cao/quy-3",
                            "https://docs.example.net/ke-hoach?tab=2", "https://example.com/tin-tuc/ra-mat",
                            "https://example.org/huong-dan", "https://www.example.net/thiet-ke",
                            "https://example.com/khao-sat"]
                let url = urls[index % urls.count] + (index < urls.count ? "" : "/\(index + 1)")
                return SharedCollectionItem(id: eventID, eventID: eventID, sender: sender, timestamp: timestamp,
                                            kind: .link, name: nil, url: url, media: nil, thumbnail: nil)
            }
        }
    }
}

/// One section's synthetic reader: `start` returns the cached first window,
/// each `paginate` reveals five more rows until the history ends.
@available(macOS 14.0, *)
@MainActor
public final class ScriptedSharedCollectionSource: SharedCollectionSource {
    public let updates: AsyncStream<SharedCollectionSnapshot>
    private let continuation: AsyncStream<SharedCollectionSnapshot>.Continuation
    private let mode: ScriptedSharedCollections.Mode
    private let history: [SharedCollectionItem]
    private var revealed: Int
    private var sequence: UInt64 = 0
    private var failsNextRead: Bool
    public private(set) var paginateCount = 0
    public private(set) var isClosed = false

    public init(section: SharedCollectionSection, mode: ScriptedSharedCollections.Mode) {
        let stream = AsyncStream.makeStream(of: SharedCollectionSnapshot.self)
        updates = stream.stream
        continuation = stream.continuation
        self.mode = mode
        history = ScriptedSharedCollections.history(section, mode: mode)
        switch mode {
        case .ready: revealed = min(5, history.count)
        case .empty, .failed: revealed = 0
        case .partial, .offline: revealed = history.count
        }
        failsNextRead = mode == .failed
    }

    public func start() async throws -> SharedCollectionSnapshot { snapshot() }

    public func paginate(events: UInt16) async throws -> SharedCollectionSnapshot {
        paginateCount += 1
        if failsNextRead {
            failsNextRead = false
            throw SharedCollectionFailure.unavailable
        }
        // A partial room keeps older history the reader never reaches.
        if mode != .partial { revealed = min(history.count, revealed + 5) }
        return snapshot()
    }

    public func close() {
        isClosed = true
        continuation.finish()
    }

    private func snapshot() -> SharedCollectionSnapshot {
        sequence += 1
        let reachedStart: Bool = switch mode {
        case .partial, .offline: false
        case .ready, .empty: revealed == history.count
        case .failed: revealed == history.count && revealed > 0
        }
        return SharedCollectionSnapshot(items: Array(history.prefix(revealed)), reachedStart: reachedStart,
                                        sequence: sequence)
    }
}
#endif
