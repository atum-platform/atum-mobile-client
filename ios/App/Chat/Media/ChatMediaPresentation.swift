import AtumChat
import Foundation
import Observation
import SwiftUI

struct ChatMediaAccess: Sendable {
    var thumbnail: @MainActor @Sendable (_ media: ChatMedia, _ pixelWidth: Int, _ pixelHeight: Int) async -> Data?
    var content: @MainActor @Sendable (_ media: ChatMedia) async -> Data?
    var file: @MainActor @Sendable (_ media: ChatMedia) async -> LiveMediaFile?
    var uploadLimit: @MainActor @Sendable () async -> UInt64

    init(
        thumbnail: @escaping @MainActor @Sendable (ChatMedia, Int, Int) async -> Data? = { _, _, _ in nil },
        content: @escaping @MainActor @Sendable (ChatMedia) async -> Data? = { _ in nil },
        file: @escaping @MainActor @Sendable (ChatMedia) async -> LiveMediaFile? = { _ in nil },
        uploadLimit: @escaping @MainActor @Sendable () async -> UInt64 = { MediaAttachmentPolicy.fallbackUploadLimit }
    ) {
        self.thumbnail = thumbnail
        self.content = content
        self.file = file
        self.uploadLimit = uploadLimit
    }
}

struct MediaViewerRequest: Identifiable, Equatable {
    let rowID: String
    let media: ChatMedia
    let sender: String
    let timestamp: Date
    let caption: String
    let localFileURL: URL?
    let initialImageData: Data?

    var id: String { rowID }

    static func == (left: MediaViewerRequest, right: MediaViewerRequest) -> Bool {
        left.rowID == right.rowID && left.media == right.media
            && left.sender == right.sender && left.timestamp == right.timestamp
            && left.caption == right.caption && left.localFileURL == right.localFileURL
            && left.initialImageData == right.initialImageData
    }
}

@MainActor
@Observable
final class ChatMediaPresenter {
    var viewer: MediaViewerRequest?
    var quickLookFile: LiveMediaFile?
    var photoPickerPresented = false
    var fileImporterPresented = false

    var covers: Bool {
        viewer != nil || quickLookFile != nil || photoPickerPresented || fileImporterPresented
    }

    func dismissAll() {
        viewer = nil
        quickLookFile = nil
        photoPickerPresented = false
        fileImporterPresented = false
    }
}

actor ChatMediaMemoryCache {
    static let shared = ChatMediaMemoryCache()
    private var values = [String: Data]()
    private var order = [String]()
    private var totalBytes = 0
    private let maximumEntries: Int
    private let maximumBytes: Int

    init(maximumEntries: Int = 128, maximumBytes: Int = 32 * 1024 * 1024) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
    }

    func value(for key: String) -> Data? { values[key] }

    func insert(_ data: Data, for key: String) {
        if let previous = values[key] {
            totalBytes -= previous.count
        } else {
            order.append(key)
        }
        values[key] = data
        totalBytes += data.count
        while order.count > maximumEntries || totalBytes > maximumBytes {
            guard let evicted = order.first else { break }
            order.removeFirst()
            if let value = values.removeValue(forKey: evicted) { totalBytes -= value.count }
        }
    }
}

extension EnvironmentValues {
    @Entry var chatMediaAccess = ChatMediaAccess()
    /// Why files cannot be attached in this chat, or nil when they can. A company DM or
    /// group DM has no protected-file audience yet, so its `+` shows the reason and no
    /// photo or file choice.
    @Entry var chatAttachmentsClosedReason: String? = nil
    @Entry var chatMediaPresenter: ChatMediaPresenter?
    @Entry var chatLocalMediaFiles: [String: URL] = [:]
    @Entry var chatMediaRetryGeneration: UInt64 = 0
    @Entry var chatMediaNamespace: Namespace.ID?
}
