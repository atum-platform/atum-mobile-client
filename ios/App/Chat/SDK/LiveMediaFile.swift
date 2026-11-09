import Foundation
import MatrixRustSDK

/// A temporary SDK media file kept alive for as long as Quick Look or the
/// share sheet owns this value. Releasing the SDK handle may remove its file.
final class LiveMediaFile: Identifiable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    private let handle: MediaFileHandle?

    init(handle: MediaFileHandle) throws {
        self.handle = handle
        url = URL(fileURLWithPath: try handle.path())
    }

    init(scriptedURL: URL) {
        handle = nil
        url = scriptedURL
    }
}
