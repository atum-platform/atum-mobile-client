import AtumChat
import AtumNativeAPI
import Foundation
import MatrixRustSDK
import UniformTypeIdentifiers

/// A single prepared upload at a time; original queue files survive until every destination is accepted.
@MainActor
final class ShareQueueDelivery {
    private var timeline: Timeline?
    private var attachment: OutgoingChatAttachment?
    private let preparer: AttachmentPreparer
    init(jobID: UUID) {
        // Separate from the composer's launch-cleaned temporary folder. Never share a path between recipients.
        preparer = AttachmentPreparer(folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("atum-share-upload-" + jobID.uuidString))
    }
    func prepare(job: ShareJob, delivery: ShareJob.Delivery, queue: ShareQueue,
                 session: LiveMatrixSession, eligible: Bool) async throws {
        await clean()
        try session.runtime.requireCurrent()
        guard eligible, ShareAccount(userID: session.runtime.ticket.session.userID,
                                     generation: session.runtime.ticket.generation) == job.account else { throw ShareQueueFailure.accountChanged }
        let room = try session.room(id: delivery.roomID)
        let info = try await room.roomInfo()
        guard info.membership == .joined else { throw ShareQueueFailure.invalid }
        let item = job.items[delivery.itemIndex]
        if item.file != nil {
            let url = try queue.fileURL(item, jobID: job.id)
            let limit = await session.maximumMediaUploadSize() ?? AttachmentPreparer.fallbackUploadLimit
            if item.kind == .image {
                attachment = try await preparer.preparePhoto(data: Data(contentsOf: url, options: .mappedIfSafe),
                                                            suggestedFilename: item.filename,
                                                            type: item.typeIdentifier.flatMap(UTType.init), uploadLimit: limit)
            } else {
                attachment = try await preparer.prepareFile(url: url, uploadLimit: limit,
                                                           suggestedFilename: item.filename,
                                                           type: item.typeIdentifier.flatMap(UTType.init))
            }
        }
        timeline = try await room.timelineWithConfiguration(configuration: SDKTimelineSource.configuration)
        try session.runtime.requireCurrent()
    }
    func send(job: ShareJob, delivery: ShareJob.Delivery, session: LiveMatrixSession,
              eligible: Bool) async throws {
        defer { timeline = nil; attachment = nil }
        try session.runtime.requireCurrent()
        guard eligible, let timeline else { throw ShareQueueFailure.accountChanged }
        let caption = delivery.itemIndex == 0 && !job.caption.isEmpty ? job.caption : nil
        let room = try session.room(id: delivery.roomID)
        room.enableSendQueue(enable: true)
        if let attachment {
            let handle = try SDKAttachmentSender.enqueue(attachment, caption: caption, replyTo: nil, timeline: timeline)
            try await handle.join()
            await preparer.remove(attachment)
        } else {
            guard let text = job.items[delivery.itemIndex].text else { throw ShareQueueFailure.invalid }
            let body = [text, caption].compactMap { $0 }.joined(separator: "\n\n")
            _ = try await timeline.send(msg: SDKTimelineSource.plainText(body))
        }
        await OutgoingShareSuggestions.shared.sent(roomID: delivery.roomID)
    }
    func clean() async {
        if let attachment { await preparer.remove(attachment) }
        attachment = nil; timeline = nil
    }
}
