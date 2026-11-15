import AVFoundation
import AtumNativeAPI
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What is being shared, as a horizontal strip of tiles: photo and video thumbnails,
/// and quiet tiles naming a file, a link's host or a text's opening.
struct SharePreviewStrip: View {
    let items: [ShareItem]
    let isLoading: Bool
    let progress: Double
    let stagedFile: (ShareItem) -> URL?

    @Environment(\.atumKit) private var kit
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let kit {
            Group {
                if items.isEmpty && isLoading {
                    loading(kit)
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: kit.space(.s2)) {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                SharePreviewTile(item: item, url: stagedFile(item))
                            }
                        }
                        .padding(.vertical, kit.space(.s1))
                    }
                    .scrollIndicators(.hidden)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(SharePendingCopy.text(.items))
                    .accessibilityIdentifier("share.preview")
                }
            }
        }
    }

    private func loading(_ kit: AtumKit) -> some View {
        VStack(alignment: .leading, spacing: kit.space(.s2)) {
            Text(verbatim: SharePendingCopy.text(.loading))
                .font(kit.font(.callout))
                .foregroundStyle(kit.color(.ink2, scheme: scheme))
            ProgressView(value: progress)
                .tint(kit.color(.ink, scheme: scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, kit.space(.s2))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share.loading")
    }
}

struct SharePreviewTile: View {
    let item: ShareItem
    let url: URL?

    @ScaledMetric(relativeTo: .body) private var scaledSide = 72.0
    @Environment(\.atumKit) private var kit
    @Environment(\.colorScheme) private var scheme
    @State private var thumbnail: UIImage?

    /// Tiles grow with Dynamic Type, at most 1.6x (a 115 pt tile at AX5).
    private var side: CGFloat { min(scaledSide, 72 * 1.6) }
    private var isMedia: Bool { item.kind == .image || item.kind == .video }

    var body: some View {
        if let kit {
            let shape = RoundedRectangle(cornerRadius: kit.radius(.md), style: .continuous)
            Group {
                if isMedia { media(kit) } else { described(kit) }
            }
            .background(kit.color(.fillQuiet, scheme: scheme), in: shape)
            .clipShape(shape)
            .overlay { shape.strokeBorder(kit.color(.line, scheme: scheme), lineWidth: 0.5) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SharePreviewText.label(item))
            .accessibilityAddTraits(item.kind == .image ? .isImage : [])
            .task(id: url) {
                guard isMedia, let url else { return }
                let pixels = Int((side * 3).rounded(.up))
                thumbnail = await ShareThumbnail.image(url: url, isVideo: item.kind == .video,
                                                       typeIdentifier: item.typeIdentifier, pixelSide: pixels)
            }
        }
    }

    private func media(_ kit: AtumKit) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
            } else {
                Image(share: item.kind == .video ? .video : .image)
                    .accessibilityHidden(true)
                    .font(kit.font(.title))
                    .foregroundStyle(kit.color(.ink3, scheme: scheme))
                    .frame(width: side, height: side)
            }
            if item.kind == .video, thumbnail != nil {
                Image(share: .video)
                    .accessibilityHidden(true)
                    .font(kit.font(.caption))
                    .foregroundStyle(kit.color(.onInk, scheme: scheme))
                    .padding(kit.space(.s1))
                    .background(kit.color(.scrim, scheme: scheme), in: Capsule())
                    .padding(kit.space(.s1))
            }
        }
        .frame(width: side, height: side)
    }

    private func described(_ kit: AtumKit) -> some View {
        VStack(alignment: .leading, spacing: kit.space(.s1)) {
            Image(share: glyph)
                .accessibilityHidden(true)
                .font(kit.font(.headline))
                .foregroundStyle(kit.color(.ink2, scheme: scheme))
            Text(verbatim: SharePreviewText.detail(item) ?? SharePreviewText.label(item))
                .font(kit.font(.caption))
                .foregroundStyle(kit.color(.ink, scheme: scheme))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(kit.space(.s2))
        .frame(width: side * 2, height: side, alignment: .topLeading)
    }

    private var glyph: SharePickerDesign.Glyph {
        switch item.kind {
        case .file: .file
        case .url: .link
        case .text: .text
        case .image: .image
        case .video: .video
        }
    }
}

/// Small thumbnails of staged copies, made off the main actor and never by decoding
/// a full-size image or video (the extension runs in a tight memory budget).
enum ShareThumbnail {
    static func image(url: URL, isVideo: Bool, typeIdentifier: String?, pixelSide: Int) async -> UIImage? {
        if isVideo { return await video(url: url, typeIdentifier: typeIdentifier, pixelSide: pixelSide) }
        return await Task.detached(priority: .userInitiated) { still(url: url, pixelSide: pixelSide) }.value
    }

    static func still(url: URL, pixelSide: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixelSide,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    static func video(url: URL, typeIdentifier: String?, pixelSide: Int) async -> UIImage? {
        // Staged copies are UUID names without an extension: give AVFoundation the MIME type.
        let mime = typeIdentifier.flatMap { UTType($0)?.preferredMIMEType }
        let asset = AVURLAsset(url: url, options: mime.map { [AVURLAssetOverrideMIMETypeKey: $0] } ?? [:])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixelSide, height: pixelSide)
        guard let frame = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: frame)
    }
}
