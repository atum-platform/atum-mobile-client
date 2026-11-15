import ImageIO
import PDFKit
import SwiftUI
import UIKit
import AtumNativeAPI
import AtumDrive

/// Desktop Drive's Gallery view (atum-desktop #44) in iPhone form: the item
/// large, its name and facts under it, and the folder's pictures and PDFs in a
/// strip along the bottom. Swipe or tap the strip to move; Share hands the
/// file to the iOS share sheet. A page downloads its file when it is shown,
/// and the next one is fetched ahead. The shown page's file is held in the
/// cache, and a page's file is checked again each time it is shown, since
/// the cache may have evicted it meanwhile.
struct DriveGalleryView: View {
    let design: LiveDesign
    @Bindable var model: DriveFeatureModel
    let gallery: DriveGallery

    @State private var selection: String
    @State private var files = [String: DriveGalleryFile]()
    /// The one file staged under its own name while the share sheet is open.
    @State private var sharing: DriveStagedShare?
    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    init(design: LiveDesign, model: DriveFeatureModel, gallery: DriveGallery) {
        self.design = design
        self.model = model
        self.gallery = gallery
        _selection = State(initialValue: gallery.startID)
    }

    private var copy: DriveCopy { DriveCopy(design: design) }
    private var index: Int { gallery.items.firstIndex { $0.id == selection } ?? 0 }
    private var selected: DriveItem? { gallery.items.indices.contains(index) ? gallery.items[index] : nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $selection) {
                    ForEach(gallery.items) { item in
                        DriveGalleryPage(design: design, copy: copy, model: model, item: item,
                                         file: files[item.id]) { redownload in
                            files[item.id] = nil
                            Task {
                                if redownload {
                                    files[item.id] = await model.retryGalleryPage(item)
                                } else {
                                    await load(item, revalidate: true)
                                }
                            }
                        }
                        .tag(item.id)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .accessibilityIdentifier("drive.gallery.pages")
                if let selected { caption(selected) }
                strip
            }
            .background(atum?.color(.ground, scheme: scheme).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { model.gallery = nil }
                        .accessibilityLabel(copy.close)
                        .accessibilityIdentifier("drive.gallery.close")
                }
                ToolbarItem(placement: .primaryAction) { shareButton }
            }
        }
        .accessibilityIdentifier("drive.gallery")
        .sheet(item: $sharing, onDismiss: {
            if let sharing { DriveShareFile.discard(sharing.url) }
            sharing = nil
        }) { staged in
            DriveShareSheet(url: staged.url)
                .ignoresSafeArea(edges: .bottom)
        }
        .task(id: selection) {
            guard let selected else { return }
            // Hold the shown page before fetching the next, so the prefetch
            // can't evict it; then check its file is still there.
            await model.holdGalleryPage(selected)
            await load(selected, revalidate: true)
            // The next page is usually the next one shown.
            if gallery.items.indices.contains(index + 1) {
                await load(gallery.items[index + 1], revalidate: false)
            }
        }
    }

    /// A page's file, from the cache or downloaded. `revalidate` (the page is
    /// being shown) re-resolves a file the cache has since evicted, instead
    /// of handing a missing URL to the page.
    private func load(_ item: DriveItem, revalidate: Bool) async {
        if case let .ready(url, _) = files[item.id] {
            if !revalidate || FileManager.default.fileExists(atPath: url.path) { return }
            files[item.id] = nil
        }
        let file = await model.galleryFile(for: item)
        // A page left before its download finished tries again when shown.
        if case .failed(nil) = file, Task.isCancelled { return }
        files[item.id] = file
    }

    /// Stages the shown file under its own name only when Share is tapped,
    /// and removes it when the sheet closes: one named file at a time.
    private func share(_ item: DriveItem, from url: URL) {
        Task {
            guard let staged = await Task.detached(operation: {
                DriveShareFile.make(from: url, name: item.name)
            }).value else { return }
            sharing = DriveStagedShare(url: staged)
        }
    }

    @ViewBuilder private var shareButton: some View {
        if let selected, case let .ready(url, _) = files[selected.id] {
            Button { share(selected, from: url) } label: { design.barIcon("Share") }
                .accessibilityLabel(copy.share)
                .accessibilityIdentifier("drive.gallery.share")
        } else {
            Button {} label: { design.barIcon("Share") }
                .disabled(true)
                .accessibilityLabel(copy.share)
                .accessibilityIdentifier("drive.gallery.share")
        }
    }

    /// Desktop's caption: the name, then kind · size · modified.
    private func caption(_ item: DriveItem) -> some View {
        VStack(spacing: 2) {
            Text(verbatim: item.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(atum?.color(.ink, scheme: scheme) ?? .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: facts(item))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(atum?.color(.muted, scheme: scheme) ?? .secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("drive.gallery.caption")
    }

    private func facts(_ item: DriveItem) -> String {
        var parts = [copy.itemKind(DriveKindFamily.of(item)),
                     ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file)]
        if let modifiedAt = item.modifiedAt {
            parts.append(DriveTimeFormat.modified(modifiedAt, now: Date(),
                                                  locale: Locale(identifier: design.locale)))
        }
        return parts.joined(separator: " · ")
    }

    private var strip: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(gallery.items) { item in
                        Button { selection = item.id } label: {
                            Image(design.symbol(DriveFileFamily.of(item).glyphAlias))
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
                                .frame(width: 52, height: 52)
                                .background(
                                    item.id == selection
                                        ? atum?.kitColor(.fillSelected, scheme: scheme) ?? Color.secondary.opacity(0.15)
                                        : .clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .accessibilityLabel(Text(verbatim: item.name))
                        .accessibilityAddTraits(item.id == selection ? .isSelected : [])
                        .accessibilityIdentifier("drive.gallery.strip." + item.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(height: 64)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(atum?.kitColor(.line, scheme: scheme) ?? Color.secondary.opacity(0.2))
                    .frame(height: 0.5)
            }
            .onChange(of: selection, initial: true) { _, id in
                withAnimation { reader.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct DriveGalleryPage: View {
    let design: LiveDesign
    let copy: DriveCopy
    @Bindable var model: DriveFeatureModel
    let item: DriveItem
    let file: DriveGalleryFile?
    /// Load the page again; `true` drops this iPhone's copy and downloads it
    /// again (a file that would not render).
    let retry: (_ redownload: Bool) -> Void

    /// What the page draws once it has a file.
    private enum Rendered {
        case image(UIImage)
        case pdf(PDFDocument)
        case failed(DriveGalleryRenderFailure)
    }

    @State private var rendered: (url: URL, value: Rendered)?
    @State private var zoomScale = 1.0
    @State private var controlsVisible = true
    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            if case .ready(_, true) = file {
                Text(copy.stale)
                    .font(.footnote)
                    .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
                    .padding(.vertical, 6)
            }
            ZStack {
                switch file {
                case nil:
                    waiting
                case let .failed(notice):
                    failure(notice.map { copy.notice($0) } ?? copy.previewError) { retry(false) }
                case let .ready(url, _):
                    if let rendered, rendered.url == url {
                        switch rendered.value {
                        case let .pdf(document):
                            DrivePDFView(document: document)
                                .accessibilityLabel(Text(verbatim: item.name))
                                .accessibilityIdentifier("drive.gallery.pdf")
                        case let .image(image):
                            ZoomableMediaImage(image: image, zoomScale: $zoomScale,
                                               controlsVisible: $controlsVisible,
                                               pansOnlyWhenZoomed: true)
                                .accessibilityElement()
                                .accessibilityLabel(Text(verbatim: item.name))
                                .accessibilityAddTraits(.isImage)
                                .accessibilityIdentifier("drive.gallery.image")
                        case let .failed(failure):
                            self.failure(failure == .unsupported ? copy.previewUnavailable : copy.previewError,
                                         retry: failure.allowsRetry ? { retry(true) } : nil)
                        }
                    } else {
                        waiting
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: readyURL) { await render() }
    }

    /// Decodes the picture or opens the PDF off the main actor, then shows it
    /// or says why it can't. A file the cache evicted since it was resolved
    /// waits: the gallery resolves it again when the page is shown.
    private func render() async {
        // No file (loading, failed, or about to load again): forget what was drawn.
        guard let url = readyURL else { rendered = nil; return }
        guard let kind = DriveGalleryPolicy.kind(item) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let value: Rendered
        switch kind {
        case .image:
            let image = await Task.detached(priority: .userInitiated) { Self.decoded(url) }.value
            if let image { value = .image(image) }
            else { value = .failed(DriveGalleryRenderFailure.image(decoded: false)!) }
        case .pdf:
            let opened = await Task.detached(priority: .userInitiated) {
                DriveOpenedPDF(document: PDFDocument(url: url))
            }.value
            let document = opened.document
            if let failure = DriveGalleryRenderFailure.pdf(opened: document != nil,
                                                           locked: document?.isLocked ?? false,
                                                           pageCount: document?.pageCount ?? 0) {
                value = .failed(failure)
            } else {
                value = .pdf(document!)
            }
        }
        guard !Task.isCancelled, url == readyURL else { return }
        rendered = (url, value)
    }

    @ViewBuilder private func failure(_ message: String, retry: (() -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(design.symbol(DriveFileFamily.of(item).glyphAlias))
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(atum?.color(.muted, scheme: scheme) ?? .secondary)
                .accessibilityHidden(true)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
            if let retry {
                Button(copy.retry, action: retry)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(32)
        .accessibilityIdentifier("drive.gallery.failed")
    }

    /// The picture at screen-friendly size, decoded off the main actor (as
    /// the chat media viewer bounds its decode). Nil when the bytes don't decode.
    nonisolated private static func decoded(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4_096,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private var readyURL: URL? {
        if case let .ready(url, _) = file { return url }
        return nil
    }

    @ViewBuilder private var waiting: some View {
        VStack(spacing: 10) {
            if let progress = model.transferProgress[item.id] {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
            } else {
                AtomWait().frame(width: 28, height: 28)
            }
            Text(copy.previewLoading)
                .font(.footnote)
                .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("drive.gallery.loading")
    }
}

/// A PDF opened off the main actor, handed back to it to attach. PDFKit's
/// document is not `Sendable`; it is created on one task and only used on
/// the main actor afterwards.
private struct DriveOpenedPDF: @unchecked Sendable {
    let document: PDFDocument?
}

/// A Drive PDF, paged vertically and zoomable (PDFKit). The document is
/// opened before it gets here, off the main thread.
private struct DrivePDFView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = document
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

/// The file staged for the share sheet.
struct DriveStagedShare: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The iOS share sheet for one staged file.
private struct DriveShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A Drive file under its own name for the share sheet: the cache keeps files
/// under opaque keys. A hard link (or a copy across volumes) in a temporary
/// folder, made only when Share is tapped and removed when the sheet closes,
/// so at most one named file exists at a time.
enum DriveShareFile {
    nonisolated private static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("drive-share", isDirectory: true)
    }

    nonisolated static func make(from url: URL, name: String) -> URL? {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = folder.appendingPathComponent(name, isDirectory: false)
        guard destination.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
        else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do { try FileManager.default.linkItem(at: url, to: destination) }
            catch { try FileManager.default.copyItem(at: url, to: destination) }
            return destination
        } catch {
            return nil
        }
    }

    /// Removes one staged file and its folder (the share sheet closed).
    nonisolated static func discard(_ staged: URL) {
        let folder = staged.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent() == root.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    nonisolated static func clear() {
        try? FileManager.default.removeItem(at: root)
    }
}
