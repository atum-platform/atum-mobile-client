import AtumChat
import AtumDesign
import ImageIO
import Photos
import QuickLook
import SwiftUI
import UIKit

/// The panel's Shared section (desktop `person-info-panel.tsx`, after the
/// Conversation group): photos and videos, files and links, each with its
/// newest few (6/3/3) and "See all", which pushes `ChatPanelPolicy.Page.shared`
/// on the panel's own path (pages of 30). `ChatPanelHost` owns the scope so
/// the pages share it and it closes with the panel. People and group chats
/// only; a company channel has its own panel.
struct SharedCollectionsSection: View {
    let design: LiveDesign
    let info: ChatInfoPresentation
    let open: SharedCollectionsOpener?
    let controller: SharedCollectionsController
    let seeAll: (ChatPanelPolicy.SharedSection) -> Void

    @State private var presenter = SharedCollectionsPresenter()
    @Namespace private var namespace

    static func applies(to info: ChatInfoPresentation) -> Bool {
        guard info.company == nil else { return false }
        switch info.kind {
        case .person, .group: return true
        case .assistant, .app: return false
        }
    }

    var body: some View {
        if let open, Self.applies(to: info) {
            let context = SharedCollectionsContext(design: design, info: info, controller: controller,
                                                   namespace: namespace)
            VStack(alignment: .leading, spacing: 24) {
                ForEach(SharedCollectionSection.allCases, id: \.self) { section in
                    SharedPreviewBlock(context: context, section: section, presenter: presenter) {
                        seeAll(ChatPanelPolicy.SharedSection(section))
                    }
                }
            }
            .padding(.top, 24)
            .onAppear { controller.start(open) }
            .onChange(of: controller.scopeClosedElsewhere) { _, closed in
                guard closed else { return }
                // Session teardown closed the scope: release its viewers and
                // handles, then read again on a new scope.
                presenter.dismissAll()
                controller.reopen()
            }
            .sharedCollectionsPresentations(presenter, context: context)
        }
    }
}

extension ChatPanelPolicy.SharedSection {
    init(_ section: SharedCollectionSection) {
        switch section {
        case .media: self = .media
        case .files: self = .files
        case .links: self = .links
        }
    }

    var collection: SharedCollectionSection {
        switch self {
        case .media: .media
        case .files: .files
        case .links: .links
        }
    }
}

/// Everything a Shared view reads, made once per render.
@MainActor
struct SharedCollectionsContext {
    let design: LiveDesign
    let info: ChatInfoPresentation
    let controller: SharedCollectionsController
    let namespace: Namespace.ID

    var copy: SharedCollectionsCopy { SharedCollectionsCopy(design: design) }
    var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    var locale: Locale { Locale(identifier: design.locale) }

    /// The sheet's own names for people; never a raw Matrix ID. A sender the
    /// sheet does not know is unnamed rather than guessed.
    func senderLabel(_ userID: String) -> String {
        if let member = info.members.first(where: { $0.userID == userID }) {
            return member.isCurrentUser ? copy.you : member.name
        }
        if case .person = info.kind, info.members.contains(where: \.isCurrentUser) {
            return info.title
        }
        return ""
    }

    func date(_ value: Date) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    /// The scope's phases fold into the same display rules as a model's.
    func display(_ section: SharedCollectionSection, preview: Bool) -> SharedCollectionsDisplay {
        let previewCount = preview ? section.previewCount : nil
        switch controller.phase {
        case .open where !controller.scopeClosedElsewhere:
            if let model = controller.model(section) {
                return SharedCollectionsDisplay(model: model, preview: preview)
            }
            fallthrough
        case .idle, .opening, .open:
            return SharedCollectionsDisplay(state: .loading, items: [], isReading: true, canLoadMore: false,
                                            requiresReopen: false, previewCount: previewCount)
        case .failed:
            return SharedCollectionsDisplay(state: .failed, items: [], isReading: false, canLoadMore: false,
                                            requiresReopen: true, previewCount: previewCount)
        }
    }

    func retry(_ section: SharedCollectionSection, _ display: SharedCollectionsDisplay) {
        if display.retry == .reopenScope || controller.phase != .open {
            controller.reopen()
        } else {
            Task { await controller.retry(section) }
        }
    }

    func loadMore(_ section: SharedCollectionSection) {
        guard let model = controller.model(section) else { return }
        Task { await model.loadMore() }
    }
}

// MARK: - Preview and page

private struct SharedPreviewBlock: View {
    let context: SharedCollectionsContext
    let section: SharedCollectionSection
    let presenter: SharedCollectionsPresenter
    let seeAll: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let display = context.display(section, preview: true)
        VStack(alignment: .leading, spacing: 8) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
            layout {
                Text(context.copy.title(section))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(context.atum.color(.soft, scheme: scheme))
                    .accessibilityAddTraits(.isHeader)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                if display.showsSeeAll {
                    Button(action: seeAll) {
                        Text(context.copy.seeAll)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(context.atum.color(.ink, scheme: scheme))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(context.copy.seeAllLabel(section))
                    .accessibilityHint(context.copy.hasOwnSeeAllLabel(section) ? "" : context.copy.title(section))
                    .accessibilityIdentifier("info.shared-\(section.rawValue).see-all")
                }
            }
            .frame(minHeight: 44)
            .padding(.leading, 32)
            .padding(.trailing, 16)
            SharedCollectionBody(context: context, section: section, display: display,
                                 presenter: presenter, isPage: false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("info.shared-\(section.rawValue)")
    }
}

/// "See all": the whole section, newest first, one bounded page at a time,
/// pushed inside the panel (`ChatPanelHost`).
struct SharedCollectionPage: View {
    let design: LiveDesign
    let info: ChatInfoPresentation
    let controller: SharedCollectionsController
    let section: SharedCollectionSection
    let close: () -> Void

    @State private var presenter = SharedCollectionsPresenter()
    @Namespace private var namespace
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let context = SharedCollectionsContext(design: design, info: info, controller: controller,
                                               namespace: namespace)
        let display = context.display(section, preview: false)
        ScrollView {
            SharedCollectionBody(context: context, section: section, display: display,
                                 presenter: presenter, isPage: true)
                .padding(.vertical, 16)
        }
        .background(context.atum.color(.ground, scheme: scheme).opacity(0.001))
        .navigationTitle(context.copy.title(section))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ChatPanelCloseButton(design: design, close: close)
            }
        }
        .task(id: controller.generation) {
            await controller.model(section)?.seeAll()
        }
        .onChange(of: controller.scopeClosedElsewhere) { _, closed in
            if closed { presenter.dismissAll() }
        }
        .sharedCollectionsPresentations(presenter, context: context)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("info.shared-page.\(section.rawValue)")
    }
}

/// One section's rows and honest status lines, shared by preview and page.
private struct SharedCollectionBody: View {
    let context: SharedCollectionsContext
    let section: SharedCollectionSection
    let display: SharedCollectionsDisplay
    let presenter: SharedCollectionsPresenter
    let isPage: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch display.body {
            case .loading:
                loading
            case let .items(items):
                if section == .media {
                    SharedMediaGrid(context: context, items: items, presenter: presenter, isPage: isPage)
                } else {
                    SharedRowList(context: context, section: section, items: items, presenter: presenter)
                }
            case .empty:
                statusText(context.copy.empty(section), id: "empty")
            case .noneRecent:
                if let line = context.copy.noneRecent { statusText(line, id: "none-recent") }
            case .failed:
                failure
            case .offlineNothingCached:
                offline
            }
            if display.showsOffline { offline }
            if display.showsFailure { failure }
            if display.showsReadingMore {
                HStack(spacing: 8) {
                    AtomWait().frame(width: 16, height: 16).accessibilityHidden(true)
                    Text(context.copy.loading)
                }
                .font(.footnote)
                .foregroundStyle(context.atum.color(.soft, scheme: scheme))
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityElement(children: .combine)
            }
            if display.showsLoadMore {
                Button { context.loadMore(section) } label: {
                    Text(context.copy.loadMore)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(context.atum.color(.ink, scheme: scheme))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(context.atum.color(.cell, scheme: scheme),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("info.shared-\(section.rawValue).load-more")
            }
        }
    }

    @ViewBuilder private var loading: some View {
        if section == .media {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(context.atum.color(.cell, scheme: scheme))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(context.copy.loading)
            .accessibilityIdentifier("info.shared-\(section.rawValue).loading")
        } else {
            statusText(context.copy.loading, id: "loading")
        }
    }

    private func statusText(_ text: String, id: String) -> some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(context.atum.color(.soft, scheme: scheme))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 32)
            .accessibilityIdentifier("info.shared-\(section.rawValue).\(id)")
    }

    /// Desktop: "Couldn’t load this." with a Try again button.
    private var failure: some View {
        HStack(spacing: 8) {
            Text(verbatim: context.copy.failed)
                .font(.footnote)
                .foregroundStyle(context.atum.color(.soft, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { context.retry(section, display) } label: {
                Text(verbatim: context.copy.tryAgain)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(context.atum.color(.ink, scheme: scheme))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("info.shared-\(section.rawValue).retry")
        }
        .padding(.leading, 32)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("info.shared-\(section.rawValue).failed")
    }

    private var offline: some View {
        HStack(spacing: 8) {
            Image(context.atum.symbol(.cloudOff)).accessibilityHidden(true)
            Text(verbatim: context.copy.offline).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(context.atum.color(.soft, scheme: scheme))
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 32)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("info.shared-\(section.rawValue).offline")
    }
}

// MARK: - Photos and videos

private struct SharedMediaGrid: View {
    let context: SharedCollectionsContext
    let items: [SharedCollectionItem]
    let presenter: SharedCollectionsPresenter
    let isPage: Bool

    var body: some View {
        let columns = isPage
            ? [GridItem(.adaptive(minimum: 96), spacing: 2)]
            : Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)
        LazyVGrid(columns: columns, spacing: isPage ? 2 : 4) {
            ForEach(items) { item in
                SharedMediaTile(context: context, item: item, presenter: presenter)
            }
        }
        .padding(.horizontal, isPage ? 2 : 16)
    }
}

private struct SharedMediaTile: View {
    let context: SharedCollectionsContext
    let item: SharedCollectionItem
    let presenter: SharedCollectionsPresenter

    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?

    private struct Load: Equatable {
        let item: SharedCollectionItem
        let generation: UInt64
    }

    var body: some View {
        Button { presenter.open(item, context: context) } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .background(context.atum.color(.cell, scheme: scheme))
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                    } else {
                        Image(context.design.symbol(item.kind == .video ? "Movie" : "Photo"))
                            .font(.title3)
                            .foregroundStyle(context.atum.color(.muted, scheme: scheme))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .video, image != nil {
                        Image(context.design.symbol("Movie"))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(context.atum.color(.viewerInk, scheme: .dark))
                            .padding(5)
                            .background(context.atum.color(.mediaScrim, scheme: .dark), in: Circle())
                            .padding(6)
                    }
                }
                .overlay {
                    if presenter.busyItemID == item.id {
                        ZStack {
                            context.atum.color(.mediaScrim, scheme: .dark)
                            AtomWait().frame(width: 24, height: 24)
                                .foregroundStyle(context.atum.color(.viewerInk, scheme: .dark))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: image != nil)
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: item.id, in: context.namespace)
        .contextMenu { actions }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityHint(item.kind == .video ? context.copy.openFileHint : context.copy.openPhotoHint)
        .accessibilityAddTraits([.isImage, .isButton])
        .accessibilityActions { actions }
        .accessibilityIdentifier("info.shared-media.\(item.id)")
        .task(id: Load(item: item, generation: context.controller.generation)) { await load() }
    }

    @ViewBuilder private var actions: some View {
        Button { presenter.saveToPhotos(item, context: context) } label: {
            Label { Text(verbatim: context.copy.save) } icon: { Image(context.design.symbol("ArrowDown")) }
        }
        Button { presenter.share(item, context: context) } label: {
            Label { Text(verbatim: context.copy.share) } icon: { Image(context.design.symbol("Share")) }
        }
    }

    private var label: String {
        [item.kind == .video ? context.copy.video : context.copy.photo,
         item.name ?? "", context.date(item.timestamp), context.senderLabel(item.sender)]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The scope returns nil while its four thumbnail slots are busy: try a
    /// few more times, then keep the kind glyph.
    private func load() async {
        image = nil
        guard item.thumbnail != nil, let scope = context.controller.scope else { return }
        let side = Int((128 * displayScale).rounded())
        for attempt in 0..<6 {
            if let data = await scope.thumbnail(for: item, pixelSide: side) {
                guard !Task.isCancelled else { return }
                image = Self.decode(data, pixelSide: side)
                return
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(150 * (attempt + 1)))
            guard !Task.isCancelled else { return }
        }
    }

    private static func decode(_ data: Data, pixelSide: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSide,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

// MARK: - Files and links

private struct SharedRowList: View {
    let context: SharedCollectionsContext
    let section: SharedCollectionSection
    let items: [SharedCollectionItem]
    let presenter: SharedCollectionsPresenter

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                Group {
                    if section == .files {
                        SharedFileRow(context: context, item: item, presenter: presenter)
                    } else {
                        SharedLinkRow(context: context, item: item, presenter: presenter)
                    }
                }
                if item.id != items.last?.id {
                    Divider().padding(.leading, 68)
                }
            }
        }
        .background(context.atum.color(.cell, scheme: scheme),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
    }
}

private struct SharedRowTile: View {
    let context: SharedCollectionsContext
    let glyph: String
    var busy = false

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(context.atum.color(.ground, scheme: scheme))
            if busy {
                AtomWait().frame(width: 20, height: 20)
            } else {
                Image(context.design.symbol(glyph)).font(.title3)
            }
        }
        .foregroundStyle(context.atum.color(.ink, scheme: scheme))
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

private struct SharedFileRow: View {
    let context: SharedCollectionsContext
    let item: SharedCollectionItem
    let presenter: SharedCollectionsPresenter

    @Environment(\.colorScheme) private var scheme

    private var name: String { item.name ?? context.copy.kind(item.media, name: nil) }
    private var kind: String { context.copy.kind(item.media, name: item.name) }
    private var glyph: String {
        (item.media?.presentationKind(fallbackFilename: item.name) ?? MediaKind(mimetype: nil, filename: item.name))
            .glyphAlias
    }

    var body: some View {
        HStack(spacing: 0) {
            Button { presenter.open(item, context: context) } label: {
                HStack(spacing: 12) {
                    SharedRowTile(context: context, glyph: glyph, busy: presenter.busyItemID == item.id)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: name)
                            .font(.body)
                            .foregroundStyle(context.atum.color(.ink, scheme: scheme))
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Text(verbatim: [kind, context.date(item.timestamp)].joined(separator: " · "))
                            .font(.footnote)
                            .foregroundStyle(context.atum.color(.soft, scheme: scheme))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([name, kind, context.date(item.timestamp), context.senderLabel(item.sender)]
                .filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityHint(context.copy.openFileHint)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("info.shared-file.\(item.id)")

            Button { presenter.share(item, context: context) } label: {
                Image(context.design.symbol("Share"))
                    .foregroundStyle(context.atum.color(.ink, scheme: scheme))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .accessibilityLabel(context.copy.share)
            .accessibilityIdentifier("info.shared-file.\(item.id).share")
        }
    }
}

private struct SharedLinkRow: View {
    let context: SharedCollectionsContext
    let item: SharedCollectionItem
    let presenter: SharedCollectionsPresenter

    @Environment(\.colorScheme) private var scheme

    private var url: String { item.url ?? "" }
    private var host: String {
        guard let host = URL(string: url)?.host(), !host.isEmpty else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        Button { presenter.open(item, context: context) } label: {
            HStack(spacing: 12) {
                SharedRowTile(context: context, glyph: "Link")
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: host)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(context.atum.color(.ink, scheme: scheme))
                        .lineLimit(1)
                    Text(verbatim: url)
                        .font(.footnote)
                        .foregroundStyle(context.atum.color(.soft, scheme: scheme))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(context.copy.openLink(url))
        .accessibilityValue([context.date(item.timestamp), context.senderLabel(item.sender)]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAddTraits(.isLink)
        .accessibilityIdentifier("info.shared-link.\(item.id)")
    }
}

// MARK: - Opening, saving and sharing

/// One screen's viewers. The preview and each page own their own, so a
/// covered screen never presents.
@MainActor
@Observable
final class SharedCollectionsPresenter {
    struct Viewer: Identifiable {
        let request: MediaViewerRequest
        let access: ChatMediaAccess
        var id: String { request.id }
    }

    struct ShareItem: Identifiable {
        let file: LiveMediaFile
        var id: UUID { file.id }
    }

    var viewer: Viewer?
    /// Retained while QuickLook shows its URL (the hand-off's handle rule).
    var quickLook: LiveMediaFile?
    var shareItem: ShareItem?
    var page: ChatLinkRouter.Page?
    var showsHeld = false
    var showsError = false
    private(set) var busyItemID: String?
    private(set) var savedToken: UInt64 = 0

    @ObservationIgnored private var task: Task<Void, Never>?

    func open(_ item: SharedCollectionItem, context: SharedCollectionsContext) {
        run(item, context: context) { [weak self] scope in
            let result = try await scope.open(item, senderLabel: context.senderLabel(item.sender))
            guard let self, !Task.isCancelled else { return }
            switch result {
            case let .image(request):
                self.viewer = Viewer(request: request, access: scope.mediaAccess(for: item))
            case let .file(file):
                self.quickLook = file
            case let .link(decision):
                switch decision {
                case let .openInApp(url): self.page = ChatLinkRouter.Page(url: url)
                case .hold: self.showsHeld = true
                case .refuse: break
                }
            }
        }
    }

    func share(_ item: SharedCollectionItem, context: SharedCollectionsContext) {
        run(item, context: context) { [weak self] scope in
            let file = try await scope.save(item)
            guard let self, !Task.isCancelled else { return }
            self.shareItem = ShareItem(file: file)
        }
    }

    /// Photos and videos to the library, add-only (Info.plist's
    /// NSPhotoLibraryAddUsageDescription). The file handle is held until the
    /// library has copied it.
    func saveToPhotos(_ item: SharedCollectionItem, context: SharedCollectionsContext) {
        let saved = context.copy.saved
        run(item, context: context) { [weak self] scope in
            let file = try await scope.save(item)
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { throw SharedCollectionFailure.unavailable }
            let url = file.url
            let type: PHAssetResourceType = item.kind == .video ? .video : .photo
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: type, fileURL: url, options: nil)
            }
            withExtendedLifetime(file) {}
            guard let self else { return }
            self.savedToken &+= 1
            AccessibilityNotification.Announcement(saved).post()
        }
    }

    func dismissAll() {
        task?.cancel()
        task = nil
        busyItemID = nil
        viewer = nil
        quickLook = nil
        shareItem = nil
        page = nil
        showsHeld = false
        showsError = false
    }

    private func run(_ item: SharedCollectionItem, context: SharedCollectionsContext,
                     _ work: @escaping @MainActor (any SharedCollectionsScope) async throws -> Void) {
        guard busyItemID == nil, let scope = context.controller.scope else { return }
        busyItemID = item.id
        task = Task { @MainActor [weak self] in
            do {
                try await work(scope)
            } catch {
                if !Task.isCancelled { self?.showsError = true }
            }
            self?.busyItemID = nil
        }
    }
}

private struct SharedCollectionsPresentations: ViewModifier {
    @Bindable var presenter: SharedCollectionsPresenter
    let context: SharedCollectionsContext

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $presenter.viewer) { viewer in
                MediaViewer(request: viewer.request, design: context.design, access: viewer.access,
                            namespace: context.namespace) {
                    presenter.viewer = nil
                }
            }
            .fullScreenCover(item: $presenter.page) { page in
                SafariView(url: page.url).ignoresSafeArea()
            }
            .quickLookPreview(Binding(
                get: { presenter.quickLook?.url },
                set: { if $0 == nil { presenter.quickLook = nil } }
            ))
            .sheet(item: $presenter.shareItem) { item in
                SharedActivityView(url: item.file.url)
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
            .alert(context.copy.linkHeld, isPresented: $presenter.showsHeld) {
                Button(context.copy.dismiss, role: .cancel) {}
            }
            .alert(context.copy.error, isPresented: $presenter.showsError) {
                Button(context.copy.dismiss, role: .cancel) {}
            }
            .sensoryFeedback(.success, trigger: presenter.savedToken)
    }
}

extension View {
    fileprivate func sharedCollectionsPresentations(_ presenter: SharedCollectionsPresenter,
                                                    context: SharedCollectionsContext) -> some View {
        modifier(SharedCollectionsPresentations(presenter: presenter, context: context))
    }
}

private struct SharedActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
