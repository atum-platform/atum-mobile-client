import AtumChat
import Foundation
import MatrixRustSDK

/// Shared by the composer and App Group share drain; SDK owns encryption and upload.
enum SDKAttachmentSender {
    static func enqueue(_ attachment: OutgoingChatAttachment, caption: String?, replyTo eventID: String?,
                        timeline: Timeline) throws -> SendAttachmentJoinHandle {
        let source = UploadSource.file(filename: attachment.filePath)
        let parameters = UploadParameters(source: source,
                                          caption: caption,
                                          formattedCaption: nil,
                                          mentions: nil,
                                          inReplyTo: eventID)
        let kind: AttachmentKind
        switch attachment.kind {
        case let .image(width, height, isAnimated):
            let thumbnailSource = attachment.thumbnailPath.map { UploadSource.file(filename: $0) }
            let thumbnailInfo = attachment.thumbnailPath.flatMap { path -> ThumbnailInfo? in
                guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
                else { return nil }
                return ThumbnailInfo(height: nil, width: nil, mimetype: "image/jpeg",
                                     size: size.uint64Value)
            }
            kind = .image(
                imageInfo: ImageInfo(height: height, width: width,
                                     mimetype: attachment.mimetype, size: attachment.byteSize,
                                     thumbnailInfo: thumbnailInfo, thumbnailSource: nil,
                                     blurhash: nil, isAnimated: isAnimated),
                thumbnailSource: thumbnailSource
            )
        case .file:
            kind = .file(fileInfo: FileInfo(mimetype: attachment.mimetype,
                                            size: attachment.byteSize,
                                            thumbnailInfo: nil,
                                            thumbnailSource: nil))
        }
        return try timeline.sendAttachment(params: parameters, attachment: kind)
    }
}
