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
/// and the next one is fetched ahead.
struct DriveGalleryView: View {
    let design: LiveDesign
    @Bindable var model: DriveFeatureModel
    let gallery: DriveGallery

    @State private var selection: String
    @State private var files = [String: DriveGalleryFile]()
    /// Each ready file under its own name, for the share sheet.
    @State private var shares = [String: URL]()
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
                                         file: files[item.id]) {
                            files[item.id] = nil
                            Task { await load(item) }
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
        .onDisappear { DriveShareFile.clear() }
        .task(id: selection) {
            guard let selected else { return }
            await load(selected)
            // The next page is usually the next one shown.
            if gallery.items.indices.contains(index + 1) { await load(gallery.items[index + 1]) }
        }
    }

    private func load(_ item: DriveItem) async {
        if case .ready = files[item.id] { return }
        let file = await model.galleryFile(for: item)
        // A page left before its download finished tries again when shown.
        if case .failed(nil) = file, Task.isCancelled { return }
        if case let .ready(url, _) = file {
            shares[item.id] = await Task.detached { DriveShareFile.make(from: url, name: item.name) }.value
        }
        files[item.id] = file
    }

    @ViewBuilder private var shareButton: some View {
        if let selected, case let .ready(url, _) = files[selected.id] {
            ShareLink(item: shares[selected.id] ?? url) {
                design.barIcon("Share")
            }
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
    let retry: () -> Void

    @State private var image: UIImage?
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
                    VStack(spacing: 12) {
                        Image(design.symbol(DriveFileFamily.of(item).glyphAlias))
                            .font(.system(size: 48, weight: .light))
                            .foregroundStyle(atum?.color(.muted, scheme: scheme) ?? .secondary)
                            .accessibilityHidden(true)
                        Text(notice.map { copy.notice($0) } ?? copy.previewError)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
                        Button(copy.retry, action: retry)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                    }
                    .padding(32)
                    .accessibilityIdentifier("drive.gallery.failed")
                case let .ready(url, _):
                    switch DriveGalleryPolicy.kind(item) {
                    case .pdf:
                        DrivePDFView(url: url)
                            .accessibilityLabel(Text(verbatim: item.name))
                            .accessibilityIdentifier("drive.gallery.pdf")
                    default:
                        if let image {
                            ZoomableMediaImage(image: image, zoomScale: $zoomScale,
                                               controlsVisible: $controlsVisible,
                                               pansOnlyWhenZoomed: true)
                                .accessibilityElement()
                                .accessibilityLabel(Text(verbatim: item.name))
                                .accessibilityAddTraits(.isImage)
                                .accessibilityIdentifier("drive.gallery.image")
                        } else {
                            waiting
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: readyURL) {
            guard let readyURL, DriveGalleryPolicy.kind(item) == .image else { return }
            image = await Task.detached(priority: .userInitiated) {
                Self.decoded(readyURL)
            }.value
        }
    }

    /// The picture at screen-friendly size, decoded off the main actor (as
    /// the chat media viewer bounds its decode).
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

/// A Drive PDF, paged vertically and zoomable (PDFKit).
private struct DrivePDFView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

/// A Drive file under its own name for the share sheet: the cache keeps files
/// under opaque keys. A hard link (or a copy across volumes) in a temporary
/// folder that the gallery or the share sheet clears when it closes.
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

    nonisolated static func clear() {
        try? FileManager.default.removeItem(at: root)
    }
}
