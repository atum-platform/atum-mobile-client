import AtumNativeAPI
import Foundation
import Intents
import Observation

@MainActor @Observable
final class ShareComposerModel {
    enum Phase: Equatable { case loading, ready, queuing, queued, failed }
    /// The queue's per-share recipient bound (ShareQueue validates the same twenty).
    static let maximumSelection = 20
    private(set) var recentChats = [ShareChat]()
    /// The eligible Share Suggestion room the intent named, if any (preselected at load).
    private(set) var suggestedChatID: String?
    var search = ""
    var selection = Set<String>()
    var caption = ""
    private(set) var phase: Phase = .loading
    private(set) var progress: Double = 0
    private(set) var error: String?
    private(set) var items = [ShareItem]()
    var chats: [ShareChat] {
        search.isEmpty ? recentChats : recentChats.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    var canSend: Bool {
        !cancelled && phase == .ready && !selection.isEmpty && selection.count <= Self.maximumSelection && !items.isEmpty
            && selection.isSubset(of: Set(recentChats.map(\.id))) && caption.utf8.count <= ShareQueue.maximumTextBytes
    }
    @ObservationIgnored private let queue: ShareQueue
    @ObservationIgnored private let account: () throws -> ShareAccount
    @ObservationIgnored private var identity: ShareAccount?
    @ObservationIgnored private var jobID: UUID?
    @ObservationIgnored private var cancelled = false
    init(queue: ShareQueue, account: @escaping () throws -> ShareAccount = {
        try MatrixSessionReader.notificationReader().shareAccount()
    }) { self.queue = queue; self.account = account }

    func load(providers: [NSItemProvider], intent: INIntent?) async {
        guard jobID == nil, !cancelled else { return }
        do {
            let current = try account()
            guard let directory = try queue.readDirectory(), directory.account == current else { throw ShareQueueFailure.accountChanged }
            identity = current; recentChats = directory.chats
            selection = ShareSuggestions.preselection(intent: intent, chats: recentChats)
            suggestedChatID = selection.first
            let id = try queue.begin(); jobID = id
            items = try await ShareItemLoader(queue: queue).load(providers, jobID: id) { progress = $0 }
            guard !cancelled else { try? queue.remove(id); return }
            phase = .ready
        } catch {
            if let jobID { try? queue.remove(jobID) }; jobID = nil
            self.error = SharePendingCopy.text(.failed); phase = .failed
        }
    }
    var isAtSelectionLimit: Bool { selection.count >= Self.maximumSelection }
    /// Choosing chats may overlap a slow file copy; sending still waits for ready.
    /// Only chats in the current account's eligible snapshot can be chosen.
    func toggle(_ chat: ShareChat) {
        guard phase == .ready || phase == .loading, !cancelled,
              recentChats.contains(where: { $0.id == chat.id }) else { return }
        if selection.contains(chat.id) { selection.remove(chat.id) }
        else if selection.count < Self.maximumSelection { selection.insert(chat.id) }
    }
    /// The staged copy of a loaded attachment, for the preview strip's thumbnail only.
    func stagedFile(for item: ShareItem) -> URL? {
        guard let jobID, phase != .queued, !cancelled else { return nil }
        return try? queue.fileURL(item, jobID: jobID)
    }
    /// Success means durable intake, never network delivery. The owner controls dismissal.
    func send() {
        guard canSend, let jobID, let identity else { return }
        phase = .queuing; error = nil
        do {
            try queue.commit(ShareJob(id: jobID, account: identity, items: items,
                                      caption: caption, rooms: selection.sorted()), currentAccount: account)
            phase = .queued; progress = 1
        } catch { self.error = SharePendingCopy.text(.failed); phase = .ready }
    }
    func cancel() {
        cancelled = true
        if phase != .queued, let jobID { try? queue.remove(jobID) }
    }
}
