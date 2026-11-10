import AtumChat
import Foundation
import Observation

/// What the Shared section needs from one shared-collections scope: the
/// data layer's `LiveSharedCollections`, or the scripted host's synthetic one.
@MainActor
protocol SharedCollectionsScope: AnyObject {
    var sections: [SharedCollectionSection: SharedCollectionsModel] { get }
    /// Closed by this UI or by session teardown; a closed scope is never reused.
    var isClosed: Bool { get }
    func thumbnail(for item: SharedCollectionItem, pixelSide: Int) async -> Data?
    func open(_ item: SharedCollectionItem, senderLabel: String) async throws -> LiveSharedCollections.OpenResult
    func save(_ item: SharedCollectionItem) async throws -> LiveMediaFile
    func mediaAccess(for item: SharedCollectionItem) -> ChatMediaAccess
    func close()
}

/// Opens a fresh scope for the chat the info sheet describes. The host owns
/// the session, room context and names; the section owns the scope's life.
typealias SharedCollectionsOpener = @MainActor () async throws -> any SharedCollectionsScope

extension LiveSharedCollections: SharedCollectionsScope {
    var isClosed: Bool { closed }
}

/// Owns one scope from the sheet's first appearance until the sheet goes
/// away (the hand-off's "retain until dismissal, then close"). It is not
/// tied to the section's own appear/disappear, because "See all" pushes
/// over the section inside the same sheet.
@MainActor
@Observable
final class SharedCollectionsController {
    enum Phase: Equatable { case idle, opening, open, failed }

    private(set) var phase = Phase.idle
    private(set) var scope: (any SharedCollectionsScope)?
    /// Changes when a new scope replaces the old one, so pages restart reads.
    private(set) var generation: UInt64 = 0

    @ObservationIgnored private var opener: SharedCollectionsOpener?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var readTasks: [Task<Void, Never>] = []

    func start(_ opener: @escaping SharedCollectionsOpener) {
        self.opener = opener
        guard phase == .idle else { return }
        reopen()
    }

    func model(_ section: SharedCollectionSection) -> SharedCollectionsModel? {
        scope?.sections[section]
    }

    /// The scope was closed under the sheet (session teardown or account
    /// change): its rows are gone and its handles must be released.
    var scopeClosedElsewhere: Bool {
        phase == .open && (scope?.isClosed ?? true)
    }

    /// A first open, a terminal reader failure (`requiresReopen`) or a scope
    /// closed elsewhere: always a new scope, never the unusable one.
    func reopen() {
        guard let opener, phase != .opening else { return }
        discardScope()
        phase = .opening
        openTask = Task { @MainActor [weak self] in
            do {
                let scope = try await opener()
                guard let self, !Task.isCancelled else {
                    scope.close()
                    return
                }
                self.scope = scope
                self.generation &+= 1
                self.phase = .open
                // The three previews read concurrently, each on its own cursor.
                self.readTasks = SharedCollectionSection.allCases.compactMap { section in
                    scope.sections[section].map { model in Task { @MainActor in await model.loadPreview() } }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed
            }
        }
    }

    /// Retry for one section: the same reader, unless it can only be reopened.
    func retry(_ section: SharedCollectionSection) async {
        guard let model = model(section), !model.requiresReopen else {
            reopen()
            return
        }
        await model.retry()
    }

    func close() {
        discardScope()
        opener = nil
        phase = .idle
    }

    private func discardScope() {
        openTask?.cancel()
        openTask = nil
        for task in readTasks { task.cancel() }
        readTasks = []
        scope?.close()
        scope = nil
    }

    isolated deinit {
        openTask?.cancel()
        for task in readTasks { task.cancel() }
        scope?.close()
    }
}
