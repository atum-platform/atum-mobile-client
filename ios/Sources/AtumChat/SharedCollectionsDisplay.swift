import Foundation

/// What one Shared section (chat info preview) or its "See all" page shows,
/// decided once so the SwiftUI views and the tests read the same rules
/// (desktop `person-info-panel.tsx` `SharedPreview` / `SharedSectionPage` /
/// `SharedItems`). It never invents a count: empty is claimed only at the
/// room start, and a partial or offline read keeps saying it is one.
@available(macOS 14.0, *)
public struct SharedCollectionsDisplay: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        /// First read, nothing cached yet.
        case loading
        /// The rows to draw; a preview holds at most the section's preview count.
        case items([SharedCollectionItem])
        /// Room start reached and nothing shared: the authoritative empty line.
        case empty
        /// Nothing in the messages read so far, older history still unread.
        case noneRecent
        /// Nothing cached and the read failed.
        case failed
        /// Offline with nothing cached: no empty claim, no read.
        case offlineNothingCached
    }

    /// How Retry recovers: the same reader, or a new scope after a terminal
    /// reader failure (`SharedCollectionsModel.requiresReopen`).
    public enum Retry: Equatable, Sendable { case model, reopenScope }

    public let body: Body
    /// Offline with cached rows (or none): the "showing saved content" line.
    public let showsOffline: Bool
    /// A failed read below rows that are still shown.
    public let showsFailure: Bool
    /// A read in flight below rows that are already shown (page only).
    public let showsReadingMore: Bool
    /// "Load more": the page whenever more can be read; a preview only when
    /// it has nothing to show from the recent read.
    public let showsLoadMore: Bool
    /// The preview's "See all": only above rows. Always false on a page.
    public let showsSeeAll: Bool
    public let retry: Retry

    public init(state: SharedCollectionsModel.State, items: [SharedCollectionItem],
                isReading: Bool, canLoadMore: Bool, requiresReopen: Bool,
                previewCount: Int?) {
        let visible = previewCount.map { Array(items.prefix($0)) } ?? items
        let body: Body
        if !visible.isEmpty {
            body = .items(visible)
        } else {
            switch state {
            case .loading: body = .loading
            case .failed: body = .failed
            case .offline: body = .offlineNothingCached
            case .partial: body = .noneRecent
            case .empty, .ready: body = .empty
            }
        }
        self.body = body
        showsOffline = state == .offline && !visible.isEmpty
        showsFailure = state == .failed && !visible.isEmpty
        let isPage = previewCount == nil
        showsReadingMore = isPage && isReading && !visible.isEmpty
        if isPage {
            showsLoadMore = canLoadMore && !isReading && state != .failed
        } else {
            showsLoadMore = body == .noneRecent && canLoadMore && !isReading
        }
        switch body {
        case .items: showsSeeAll = !isPage
        // A preview with nothing recent offers Load more inline; a second
        // "more" control beside the title would only repeat it.
        case .noneRecent: showsSeeAll = false
        case .loading, .empty, .failed, .offlineNothingCached: showsSeeAll = false
        }
        retry = requiresReopen ? .reopenScope : .model
    }
}

@available(macOS 14.0, *)
extension SharedCollectionsDisplay {
    @MainActor
    public init(model: SharedCollectionsModel, preview: Bool) {
        self.init(state: model.state, items: model.items, isReading: model.isReading,
                  canLoadMore: model.canLoadMore, requiresReopen: model.requiresReopen,
                  previewCount: preview ? model.section.previewCount : nil)
    }
}
