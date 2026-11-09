import AtumChat
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class ChatMediaComposerState {
    private(set) var items = [StagedChatAttachment]()
    private(set) var refusal: MediaAttachmentRefusal?
    private(set) var uploadLimit = MediaAttachmentPolicy.fallbackUploadLimit
    private var refusalGeneration: UInt64 = 0

    var isPreparing: Bool { items.contains { $0.outgoing == nil } }
    var isFull: Bool { items.count >= MediaAttachmentPolicy.maximumItems }
    var canSend: Bool { !items.isEmpty && !isPreparing }

    func setUploadLimit(_ value: UInt64) {
        uploadLimit = value > 0 ? value : MediaAttachmentPolicy.fallbackUploadLimit
    }

    /// Starts one picker/importer batch. Refusals produced by that batch then
    /// compete by S4 priority until the next explicit user action.
    func beginSelection() { clearRefusal() }

    @discardableResult
    func reserve(_ hint: StagedChatAttachment.Hint, name: String) -> String? {
        guard !isFull else {
            show(.tooMany(limit: MediaAttachmentPolicy.maximumItems))
            return nil
        }
        let id = UUID().uuidString.lowercased()
        items.append(StagedChatAttachment(id: id, hint: hint, displayName: name, state: .preparing))
        return id
    }

    func finishPhoto(id: String, data: Data, filename: String?, type: UTType?) async {
        do {
            let outgoing = try await AttachmentPreparer.shared.preparePhoto(
                data: data, suggestedFilename: filename, type: type, uploadLimit: uploadLimit
            )
            complete(id: id, outgoing: outgoing)
        } catch let failure as AttachmentPreparationFailure {
            fail(id: id, failure: failure)
        } catch {
            fail(id: id, failure: .unreadable)
        }
    }

    func finishFile(id: String, url: URL) async {
        do {
            let outgoing = try await AttachmentPreparer.shared.prepareFile(url: url, uploadLimit: uploadLimit)
            complete(id: id, outgoing: outgoing)
        } catch let failure as AttachmentPreparationFailure {
            fail(id: id, failure: failure)
        } catch {
            fail(id: id, failure: .unreadable)
        }
    }

    func remove(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: index)
        clearRefusal()
        if let outgoing = removed.outgoing { Task { await AttachmentPreparer.shared.remove(outgoing) } }
    }

    func takeReadyAttachments() -> [OutgoingChatAttachment]? {
        guard canSend else { return nil }
        let values = items.compactMap(\.outgoing)
        guard values.count == items.count else { return nil }
        items = []
        clearRefusal()
        return values
    }

    func restore(_ values: [OutgoingChatAttachment]) {
        guard !values.isEmpty else { return }
        let existing = Set(items.map(\.id))
        let restored = values.filter { !existing.contains($0.id) }.map { value in
            let hint: StagedChatAttachment.Hint = switch value.kind {
            case .image: .photo
            case .file: .file
            }
            return StagedChatAttachment(id: value.id,
                                        hint: hint,
                                        displayName: value.filename,
                                        state: .ready(value))
        }
        items = Array((restored + items).prefix(MediaAttachmentPolicy.maximumItems))
    }

    func discardAll() {
        let outgoing = items.compactMap(\.outgoing)
        items = []
        clearRefusal()
        for value in outgoing {
            Task { await AttachmentPreparer.shared.remove(value) }
        }
    }

    func showTooMany() { show(.tooMany(limit: MediaAttachmentPolicy.maximumItems)) }

    #if DEBUG
    func showScriptedRefusal(_ value: MediaAttachmentRefusal) { show(value) }
    #endif

    func draftDidChange() { clearRefusal() }

    private func complete(id: String, outgoing: OutgoingChatAttachment) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            Task { await AttachmentPreparer.shared.remove(outgoing) }
            return
        }
        items[index].state = .ready(outgoing)
    }

    private func fail(id: String, failure: AttachmentPreparationFailure) {
        items.removeAll { $0.id == id }
        let next: MediaAttachmentRefusal = switch failure {
        case .tooLargePhoto: .tooLargePhoto
        case .tooLargeFile: .tooLargeFile
        case .unreadable: .unreadable
        }
        if case .tooLargePhoto = next, let current = refusal, current.isTooLarge {
            show(.tooLargeSome(count: current.tooLargeCount + 1))
        } else if case .tooLargeFile = next, let current = refusal, current.isTooLarge {
            show(.tooLargeSome(count: current.tooLargeCount + 1))
        } else {
            show(next)
        }
    }

    private func show(_ value: MediaAttachmentRefusal) {
        if let refusal, refusal.priority > value.priority { return }
        refusal = value
        refusalGeneration &+= 1
        let generation = refusalGeneration
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, generation == self.refusalGeneration else { return }
            self.refusal = nil
        }
    }

    private func clearRefusal() {
        guard refusal != nil else { return }
        refusalGeneration &+= 1
        refusal = nil
    }
}

private extension MediaAttachmentRefusal {
    var priority: Int {
        switch self {
        case .tooMany: 3
        case .tooLargePhoto, .tooLargeFile, .tooLargeSome: 2
        case .unreadable: 1
        }
    }
    var isTooLarge: Bool {
        switch self {
        case .tooLargePhoto, .tooLargeFile, .tooLargeSome: true
        default: false
        }
    }
    var tooLargeCount: Int {
        switch self {
        case let .tooLargeSome(count): count
        case .tooLargePhoto, .tooLargeFile: 1
        default: 0
        }
    }
}
