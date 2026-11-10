import AtumChat
import AtumDesign
import CoreGraphics
import ImageIO
import SwiftUI
import UIKit

struct MediaImageContent: View {
    let row: ChatRow
    let width: CGFloat
    let height: CGFloat
    let fill: Color
    let shape: AnyShape
    let roomTitle: String
    let kind: RoomKind

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatMediaAccess) private var access
    @Environment(\.chatMediaPresenter) private var presenter
    @Environment(\.chatActions) private var actions
    @Environment(\.chatLocalMediaFiles) private var localMediaFiles
    @Environment(\.chatMediaRetryGeneration) private var reconnectGeneration
    @Environment(\.chatMediaNamespace) private var namespace
    @Environment(\.chatReducesMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var phase = MediaImagePhase.loading
    @State private var retryGeneration = 0
    @State private var activeLoadID: LoadID?

    private var loadID: LoadID {
        LoadID(rowID: row.id, media: row.item.media, localFileURL: localMediaFiles[row.id],
               width: Int(width * 3), height: Int(height * 3), retry: retryGeneration,
               reconnect: reconnectGeneration)
    }

    /// A row may be reused while its event/media changes. Until the task for the
    /// new identity starts, show loading rather than a prior event's result.
    private var presentationPhase: MediaImagePhase {
        activeLoadID == loadID ? phase : .loading
    }

    var body: some View {
        ZStack {
            shape.fill(fill)
            switch presentationPhase {
            case .loading:
                placeholder("Photo")
            case let .loaded(data):
                if let image = Self.image(data: data, width: width, height: height) {
                    image.resizable().scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                        .transition(.opacity)
                } else {
                    placeholder("Refresh")
                }
            case .failed:
                placeholder("Refresh")
            }
            if row.item.isOwn, case .sending = row.item.delivery {
                fill.opacity(0.35)
                MediaUploadRing(delivery: row.item.delivery) { actions.deleteSend(row.id) }
                    .frame(width: 44, height: 44)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { tapped() }
        .onChange(of: loadID) { _, _ in
            activeLoadID = nil
            phase = .loading
        }
        .task(id: loadID) {
            let identity = loadID
            activeLoadID = identity
            phase = .loading
            await load(identity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: presentationPhase.isLoaded)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(presentationPhase == .failed ? "" : copy(.mediaOpenPhotoHint))
        .accessibilityAddTraits([.isImage, .isButton])
        .accessibilityIdentifier(AccessibilityID.mediaImage(id: row.id))
        .modifier(MediaTransitionSource(id: row.id, namespace: namespace))
    }

    @ViewBuilder private func placeholder(_ glyph: String) -> some View {
        Image(theme?.design.symbol(glyph) ?? (glyph == "Refresh" ? "ph.arrow-clockwise" : "ph.image"))
            .font(.title2)
            .foregroundStyle(theme?.color(glyph == "Refresh" ? "ink" : "muted", scheme) ?? .secondary)
    }

    private func tapped() {
        if presentationPhase == .failed {
            phase = .loading
            retryGeneration &+= 1
            return
        }
        guard let media = row.item.media, let theme else { return }
        let data: Data? = if case let .loaded(value) = presentationPhase { value } else { nil }
        presenter?.viewer = MediaViewerRequest(
            rowID: row.id,
            media: media,
            sender: ChatRowText.senderName(row, roomTitle: roomTitle, copy: theme.copy),
            timestamp: row.item.timestamp,
            caption: row.item.body,
            localFileURL: localMediaFiles[row.id],
            initialImageData: data
        )
    }

    private func load(_ identity: LoadID) async {
        if let local = identity.localFileURL,
           let data = try? Data(contentsOf: local, options: [.mappedIfSafe]) {
            guard isCurrent(identity) else { return }
            phase = .loaded(data)
            return
        }
        guard let media = identity.media else {
            guard isCurrent(identity) else { return }
            phase = .failed
            return
        }
        let key = [media.thumbnailSourceHandle ?? media.sourceHandle,
                   String(identity.width), String(identity.height)].joined(separator: "|")
        if let cached = await ChatMediaMemoryCache.shared.value(for: key) {
            guard isCurrent(identity) else { return }
            phase = .loaded(cached)
            return
        }
        guard let data = await access.thumbnail(media, identity.width, identity.height) else {
            if isCurrent(identity) { phase = .failed }
            return
        }
        await ChatMediaMemoryCache.shared.insert(data, for: key)
        guard isCurrent(identity) else { return }
        phase = .loaded(data)
    }

    private func isCurrent(_ identity: LoadID) -> Bool {
        !Task.isCancelled && activeLoadID == identity
    }

    private var accessibilityLabel: String {
        guard let theme else { return "" }
        let speech = ChatRowText.speech(row, kind: kind, roomTitle: roomTitle, theme: theme)
        var parts = [speech.sender, speech.time, speech.body].compactMap { $0 }
        if !row.item.body.isEmpty { parts.append(row.item.body) }
        parts += [speech.edited, speech.delivery, speech.noAnswer].compactMap { $0 }
        if presentationPhase == .failed { parts.append(copy(.mediaLoadFailed)) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private func copy(_ key: ChatCopyKey) -> String {
        guard let theme else { return "" }
        return ChatCopy.text(theme.design, key)
    }

    private static func image(data: Data, width: CGFloat, height: CGFloat) -> Image? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(width, height)),
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return Image(uiImage: UIImage(cgImage: image))
    }

    private struct LoadID: Equatable {
        let rowID: String
        let media: ChatMedia?
        let localFileURL: URL?
        let width: Int
        let height: Int
        let retry: Int
        let reconnect: UInt64
    }
}

private struct MediaTransitionSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    @ViewBuilder func body(content: Content) -> some View {
        if let namespace { content.matchedTransitionSource(id: id, in: namespace) }
        else { content }
    }
}

private enum MediaImagePhase: Equatable {
    case loading
    case loaded(Data)
    case failed

    var isLoaded: Bool { if case .loaded = self { true } else { false } }
}

struct MediaFileContent: View {
    let row: ChatRow
    let fill: Color
    let tileFill: Color
    let shape: AnyShape
    let roomTitle: String
    let roomKind: RoomKind
    var answerStyle = false

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatMediaAccess) private var access
    @Environment(\.chatMediaPresenter) private var presenter
    @Environment(\.chatActions) private var actions
    @Environment(\.chatLocalMediaFiles) private var localMediaFiles
    @Environment(\.chatMediaRetryGeneration) private var reconnectGeneration
    @Environment(\.colorScheme) private var scheme
    @State private var state = FileDownloadState.idle
    @State private var activeFileID: FileLoadID?
    @State private var activeDownloadID: UUID?
    @State private var downloadTask: Task<Void, Never>?

    private var fileLoadID: FileLoadID {
        FileLoadID(rowID: row.id, media: row.item.media, localFileURL: localMediaFiles[row.id])
    }

    /// Do not render a reused row's former download result while its new
    /// identity is waiting for a user action or a fresh download.
    private var presentationState: FileDownloadState {
        activeFileID == fileLoadID ? state : .idle
    }

    private var mediaKind: MediaKind {
        row.item.media?.presentationKind(fallbackFilename: row.item.fileName) ?? MediaKind(mimetype: nil, filename: row.item.fileName)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tileFill)
                switch presentationState {
                case .loading:
                    AtomWait().frame(width: 20, height: 20)
                case .failed:
                    glyph("Refresh")
                case .idle:
                    if row.item.isOwn, case .sending = row.item.delivery {
                        MediaUploadRing(delivery: row.item.delivery, style: .file) {
                            actions.deleteSend(row.id)
                        }
                            .frame(width: 40, height: 40)
                    } else {
                        glyph(mediaKind.glyphAlias)
                    }
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: displayName)
                    .font(.body)
                    .lineLimit(3)
                    .truncationMode(.middle)
                Text(presentationState == .failed ? copy(.mediaLoadFailed) : copy(mediaKind.copyKey))
                    .font(.footnote)
                    .foregroundStyle(theme?.color("soft", scheme) ?? .secondary)
                    .lineLimit(presentationState == .failed ? 2 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: answerStyle ? 320 : 264, alignment: .leading)
        .background(fill, in: shape)
        .contentShape(shape)
        .onTapGesture { open() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(presentationState == .loading ? "" : copy(.mediaOpenFileHint))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(AccessibilityID.mediaFile(id: row.id))
        .onChange(of: fileLoadID) { _, _ in
            cancelDownload()
            state = .idle
        }
        .onChange(of: reconnectGeneration) { _, _ in
            if presentationState == .failed { download(openWhenReady: false) }
        }
        .onDisappear { cancelDownload() }
    }

    @ViewBuilder private func glyph(_ alias: String) -> some View {
        Image(theme?.design.symbol(alias) ?? "ph.file")
            .font(.title3)
            .foregroundStyle(theme?.color("ink", scheme) ?? .primary)
    }

    private func open() {
        guard presentationState != .loading, row.item.media != nil else { return }
        if let local = localMediaFiles[row.id], FileManager.default.fileExists(atPath: local.path) {
            presenter?.quickLookFile = LiveMediaFile(scriptedURL: local)
            return
        }
        download(openWhenReady: true)
    }

    private func download(openWhenReady: Bool) {
        guard presentationState != .loading, let media = row.item.media else { return }
        cancelDownload()
        let identity = fileLoadID
        let downloadID = UUID()
        activeFileID = identity
        activeDownloadID = downloadID
        state = .loading
        downloadTask = Task { @MainActor in
            let file = await access.file(media)
            guard isActiveDownload(downloadID, for: identity) else { return }
            guard let file else {
                state = .failed
                downloadTask = nil
                return
            }
            state = .idle
            downloadTask = nil
            if openWhenReady { presenter?.quickLookFile = file }
        }
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        activeDownloadID = nil
        activeFileID = nil
    }

    private func isActiveDownload(_ downloadID: UUID, for identity: FileLoadID) -> Bool {
        !Task.isCancelled && activeDownloadID == downloadID && activeFileID == identity
    }

    private var displayName: String {
        let value = row.item.media?.filename ?? row.item.fileName
        return value.isEmpty ? copy(.file) : value
    }

    private var accessibilityLabel: String {
        guard let theme else { return "" }
        let speech = ChatRowText.speech(row, kind: roomKind, roomTitle: roomTitle, theme: theme)
        var parts = [speech.sender, speech.time, speech.body].compactMap { $0 }
        parts.append(copy(mediaKind.copyKey))
        if !row.item.body.isEmpty { parts.append(row.item.body) }
        parts += [speech.edited, speech.delivery, speech.noAnswer].compactMap { $0 }
        if presentationState == .failed { parts.append(copy(.mediaLoadFailed)) }
        return parts.joined(separator: ", ")
    }

    private func copy(_ key: ChatCopyKey) -> String {
        guard let theme else { return "" }
        return ChatCopy.text(theme.design, key)
    }
}

private struct FileLoadID: Equatable {
    let rowID: String
    let media: ChatMedia?
    let localFileURL: URL?
}

private enum FileDownloadState { case idle, loading, failed }

struct MediaUploadRing: View {
    enum Style { case photo, file }
    let delivery: ChatDelivery
    var style: Style = .photo
    let cancel: () -> Void
    @Environment(\.chatTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chatReducesMotion) private var reduceMotion

    var body: some View {
        Button(action: cancel) {
            ZStack {
                Circle().stroke(trackColor, lineWidth: 3)
                if let progress = delivery.uploadProgress {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(strokeColor,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: progress)
                }
                Image(theme?.design.symbol("X") ?? "ph.x")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(strokeColor)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copy(.mediaCancelUpload))
        .accessibilityValue(progressValue)
    }

    private var strokeColor: Color {
        switch style {
        case .photo: theme?.color("viewerInk", scheme) ?? .white
        case .file: theme?.color("ink", scheme) ?? .primary
        }
    }

    private var trackColor: Color {
        switch style {
        case .photo: strokeColor.opacity(0.3)
        case .file: theme?.color("frame", scheme) ?? .gray.opacity(0.4)
        }
    }

    private var progressValue: String {
        guard let progress = delivery.uploadProgress else { return "" }
        return copy(.mediaUploadProgress, [.number(Int64((progress * 100).rounded()))])
    }

    private func copy(_ key: ChatCopyKey, _ arguments: [AtumCopy.Argument] = []) -> String {
        guard let theme else { return "" }
        return ChatCopy.text(theme.design, key, arguments)
    }
}

private extension ChatItem {
    var fileName: String {
        guard case let .file(name) = kind else { return "" }
        return name
    }
}
