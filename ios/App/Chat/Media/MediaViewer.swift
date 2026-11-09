import AtumChat
import AtumDesign
import ImageIO
import SwiftUI
import UIKit

struct MediaViewer: View {
    let request: MediaViewerRequest
    let design: LiveDesign
    let access: ChatMediaAccess
    let namespace: Namespace.ID
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var imageData: Data?
    @State private var shareFile: LiveMediaFile?
    @State private var ownedShareDirectory: URL?
    @State private var failed = false
    @State private var controlsVisible = true
    @State private var zoomScale = 1.0

    var body: some View {
        NavigationStack {
            ZStack {
                design.color("viewerGround", scheme: .dark).ignoresSafeArea()
                content
                if failed, imageData != nil || request.initialImageData != nil {
                    failureOverlay
                }
                if controlsVisible { details }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar(controlsVisible ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { close() }
                        .accessibilityLabel(copy(.dismiss))
                }
                ToolbarItem(placement: .primaryAction) {
                    if let shareFile {
                        ShareLink(item: shareFile.url) {
                            design.barIcon("Share")
                                .foregroundStyle(design.color("viewerInk", scheme: .dark))
                        }
                        .accessibilityLabel(copy(.mediaShare))
                        .accessibilityIdentifier(AccessibilityID.mediaShare)
                    } else {
                        Button {} label: {
                            design.barIcon("Share")
                                .foregroundStyle(design.color("viewerInk", scheme: .dark))
                        }
                            .disabled(true)
                            .opacity(0.4)
                            .accessibilityLabel(copy(.mediaShare))
                            .accessibilityIdentifier(AccessibilityID.mediaShare)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(design.color("viewerInk", scheme: .dark))
        .navigationTransition(.zoom(sourceID: request.rowID, in: namespace))
        .statusBarHidden(!controlsVisible)
        .interactiveDismissDisabled(zoomScale > 1.001)
        .accessibilityIdentifier(AccessibilityID.mediaViewer)
        .accessibilityAction(.escape) { close() }
        .task(id: request.id) { await load() }
        .onDisappear { removeOwnedShareFile() }
    }

    @ViewBuilder private var content: some View {
        if let data = imageData ?? request.initialImageData,
           let image = Self.decodedImage(data, animated: request.media.isAnimated && !reduceMotion) {
            ZoomableMediaImage(image: image, zoomScale: $zoomScale,
                               controlsVisible: $controlsVisible)
                .ignoresSafeArea()
                .simultaneousGesture(
                    DragGesture().onEnded { value in
                        if zoomScale <= 1.001, value.translation.height > 120,
                           abs(value.translation.width) < value.translation.height { close() }
                    }
                )
                .accessibilityElement()
                .accessibilityLabel(photoLabel)
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier(AccessibilityID.mediaViewerPhoto)
        } else if failed {
            VStack(spacing: 12) {
                Text(copy(.mediaOriginalFailed))
                    .font(.footnote)
                    .foregroundStyle(design.color("viewerInk", scheme: .dark))
                Button(copy(.retry)) {
                    failed = false
                    Task { await load() }
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(design.color("viewerInk", scheme: .dark))
                .frame(minHeight: 44)
            }
        } else {
            AtomWait()
                .frame(width: 32, height: 32)
                .foregroundStyle(design.color("viewerInk", scheme: .dark))
                .accessibilityHidden(true)
        }
    }

    private var details: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: request.sender).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(request.timestamp.formatted(Date.FormatStyle(date: .omitted, time: .shortened)
                        .locale(Locale(identifier: design.locale))))
                        .font(.footnote)
                        .opacity(0.7)
                }
                if !request.caption.isEmpty {
                    ScrollView {
                        Text(verbatim: request.caption)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .containerRelativeFrame(.vertical) { length, _ in length * 0.35 }
                }
            }
            .foregroundStyle(design.color("viewerInk", scheme: .dark))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .padding(.top, 48)
            .background(
                LinearGradient(colors: [.clear, design.color("mediaScrim", scheme: .dark)],
                               startPoint: .top, endPoint: .bottom)
            )
        }
        .allowsHitTesting(false)
    }

    private var failureOverlay: some View {
        VStack(spacing: 8) {
            Spacer()
            Text(copy(.mediaOriginalFailed))
                .font(.footnote)
            Button(copy(.retry)) {
                failed = false
                Task { await load() }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(design.color("viewerInk", scheme: .dark))
            .frame(minHeight: 44)
            Spacer().frame(height: 150)
        }
        .foregroundStyle(design.color("viewerInk", scheme: .dark))
    }

    private func load() async {
        if let local = request.localFileURL,
           let data = try? Data(contentsOf: local, options: [.mappedIfSafe]) {
            imageData = data
            if let retained = await Self.retainedShareFile(data: data, sourceURL: local) {
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: retained.directory)
                    return
                }
                removeOwnedShareFile()
                ownedShareDirectory = retained.directory
                shareFile = LiveMediaFile(scriptedURL: retained.file)
                return
            }
        }

        if let mediaFile = await access.file(request.media), !Task.isCancelled {
            shareFile = mediaFile
            if let data = try? Data(contentsOf: mediaFile.url, options: [.mappedIfSafe]) {
                imageData = data
                failed = false
                return
            }
        }
        guard !Task.isCancelled else { return }
        if let data = await access.content(request.media), !Task.isCancelled {
            imageData = data
            failed = false
            return
        }
        if !Task.isCancelled { failed = imageData == nil }
    }

    private var photoLabel: String {
        [request.sender,
         request.timestamp.formatted(Date.FormatStyle(date: .omitted, time: .shortened)
            .locale(Locale(identifier: design.locale))),
         copy(.photo), request.caption].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func close() {
        dismiss()
    }

    private func removeOwnedShareFile() {
        guard let ownedShareDirectory else { return }
        try? FileManager.default.removeItem(at: ownedShareDirectory)
        self.ownedShareDirectory = nil
    }

    static func retainedShareFile(data: Data, sourceURL: URL) async
        -> (file: URL, directory: URL)? {
        await Task.detached(priority: .utility) {
            let directory = AttachmentPreparer.viewerShareFolder
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let fallback = sourceURL.pathExtension.isEmpty ? "photo" : "photo." + sourceURL.pathExtension
                let name = sourceURL.lastPathComponent.isEmpty ? fallback : sourceURL.lastPathComponent
                let file = directory.appendingPathComponent(name)
                try data.write(to: file, options: [.atomic])
                return (file, directory)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                return nil
            }
        }.value
    }

    private func copy(_ key: ChatCopyKey) -> String { ChatCopy.text(design, key) }

    private static func decodedImage(_ data: Data, animated: Bool) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard animated, count > 1, animatedDecodeIsBounded(source: source, count: count) else {
            return thumbnail(source: source, maximumPixelSize: 4_096)
        }
        var frames = [UIImage]()
        var duration = 0.0
        for index in 0..<count {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary) else { continue }
            frames.append(UIImage(cgImage: image))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let frameDuration = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            duration += max(frameDuration, 0.02)
        }
        guard !frames.isEmpty else { return nil }
        return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
    }

    private static func thumbnail(source: CGImageSource, maximumPixelSize: Int) -> UIImage? {
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// `UIImage.animatedImage` retains decoded frames. Keep that allocation
    /// below roughly 96 MiB; oversized animations still show their first
    /// frame instead of risking a process-killing decode.
    private static func animatedDecodeIsBounded(source: CGImageSource, count: Int) -> Bool {
        guard count <= 500,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.uint64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.uint64Value else {
            return false
        }
        let (framePixels, firstOverflow) = width.multipliedReportingOverflow(by: height)
        let (totalPixels, secondOverflow) = framePixels.multipliedReportingOverflow(by: UInt64(count))
        return !firstOverflow && !secondOverflow && totalPixels <= 24_000_000
    }
}

private struct ZoomableMediaImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomScale: Double
    @Binding var controlsVisible: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        scroll.backgroundColor = .clear
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false

        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.imageView = view
        scroll.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator,
                                                           action: #selector(Coordinator.singleTap)))
        let double = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        scroll.gestureRecognizers?.first(where: { ($0 as? UITapGestureRecognizer)?.numberOfTapsRequired == 1 })?
            .require(toFail: double)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.imageView?.image !== image {
            scroll.setZoomScale(1, animated: false)
        }
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: ZoomableMediaImage
        weak var imageView: UIImageView?

        init(parent: ZoomableMediaImage) { self.parent = parent }

        func viewForZooming(in _: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            parent.zoomScale = scrollView.zoomScale
        }

        @objc func singleTap() { parent.controlsVisible.toggle() }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? UIScrollView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
                return
            }
            let point = recognizer.location(in: imageView)
            let target: CGFloat = 2.5
            let size = CGSize(width: scroll.bounds.width / target,
                              height: scroll.bounds.height / target)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2,
                                   y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
        }
    }
}
