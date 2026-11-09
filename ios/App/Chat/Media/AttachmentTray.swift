import AtumChat
import AtumDesign
import SwiftUI
import UIKit

struct AttachmentTray: View {
    let state: ChatMediaComposerState
    let design: LiveDesign
    @Environment(\.chatMediaPresenter) private var presenter
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if !state.items.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        tile(item, number: index + 1)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.trailing)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(copy(.attachmentsTitle))
            .accessibilityIdentifier(AccessibilityID.mediaTray)
        }
    }

    @ViewBuilder private func tile(_ item: StagedChatAttachment, number: Int) -> some View {
        switch item.hint {
        case .photo:
            PhotoAttachmentTile(item: item, number: number, design: design,
                                remove: { state.remove(id: item.id) },
                                preview: { preview(item) })
        case .file:
            FileAttachmentTile(item: item, design: design,
                               remove: { state.remove(id: item.id) },
                               preview: { preview(item) })
        }
    }

    private func preview(_ item: StagedChatAttachment) {
        guard let outgoing = item.outgoing else { return }
        presenter?.quickLookFile = LiveMediaFile(scriptedURL: URL(fileURLWithPath: outgoing.filePath))
    }

    private func copy(_ key: ChatCopyKey, _ arguments: [AtumCopy.Argument] = []) -> String {
        ChatCopy.text(design, key, arguments)
    }
}

private struct PhotoAttachmentTile: View {
    let item: StagedChatAttachment
    let number: Int
    let design: LiveDesign
    let remove: () -> Void
    let preview: () -> Void
    @ScaledMetric(relativeTo: .body) private var scaledSize = 64.0
    @Environment(\.colorScheme) private var scheme

    private var size: CGFloat { min(96, scaledSize) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: preview) {
                Group {
                    if let outgoing = item.outgoing,
                       let image = UIImage(contentsOfFile: outgoing.filePath) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        ZStack {
                            design.color("cell", scheme: scheme)
                            Image(design.symbol("Photo"))
                                .font(.body)
                                .foregroundStyle(design.color("muted", scheme: scheme))
                        }
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(item.outgoing == nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(copy(.mediaPhotoNumber, [.number(Int64(number))]))
            .accessibilityHint(copy(.mediaPreviewHint))
            .accessibilityIdentifier(AccessibilityID.mediaAttachment(id: item.id))

            removeButton(label: copy(.mediaRemovePhoto, [.number(Int64(number))]))
        }
        .frame(width: size, height: size)
    }

    private func removeButton(label: String) -> some View {
        Button(action: remove) {
            Image(design.symbol("X"))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(design.color("onInk", scheme: scheme))
                .frame(width: 24, height: 24)
                .background(design.color("ink", scheme: scheme).opacity(0.85), in: Circle())
                .frame(width: 44, height: 44, alignment: .topTrailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(AccessibilityID.mediaRemove(id: item.id))
    }

    private func copy(_ key: ChatCopyKey, _ arguments: [AtumCopy.Argument] = []) -> String {
        ChatCopy.text(design, key, arguments)
    }
}

private struct FileAttachmentTile: View {
    let item: StagedChatAttachment
    let design: LiveDesign
    let remove: () -> Void
    let preview: () -> Void
    @ScaledMetric(relativeTo: .body) private var scaledHeight = 64.0
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var height: CGFloat { min(96, scaledHeight) }
    private var width: CGFloat { min(240, 168 * height / 64) }
    private var exactHeight: CGFloat? { dynamicTypeSize.isAccessibilitySize ? nil : height }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: preview) {
                HStack(spacing: 8) {
                    let kind = MediaKind(mimetype: item.outgoing?.mimetype,
                                         filename: item.displayName)
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(design.color("bubble", scheme: scheme))
                        if item.outgoing == nil {
                            AtomWait().frame(width: 18, height: 18)
                        } else {
                            Image(design.symbol(kind.glyphAlias)).font(.body)
                        }
                    }
                    .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.displayName)
                            .font(.footnote)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .truncationMode(.middle)
                        Text(copy(kind.copyKey))
                            .font(.caption)
                            .foregroundStyle(design.color("soft", scheme: scheme))
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(width: width, height: exactHeight)
                .frame(minHeight: height)
                .background(design.color("cell", scheme: scheme),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(item.outgoing == nil)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(copy(.file) + ": " + item.displayName)
            .accessibilityHint(copy(.mediaPreviewHint))
            .accessibilityIdentifier(AccessibilityID.mediaAttachment(id: item.id))

            Button(action: remove) {
                Image(design.symbol("X"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(design.color("onInk", scheme: scheme))
                    .frame(width: 24, height: 24)
                    .background(design.color("ink", scheme: scheme).opacity(0.85), in: Circle())
                    .frame(width: 44, height: 44, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copy(.removeFile, [.text(item.displayName)]))
            .accessibilityIdentifier(AccessibilityID.mediaRemove(id: item.id))
        }
        .frame(width: width, height: exactHeight)
        .frame(minHeight: height)
    }

    private func copy(_ key: ChatCopyKey, _ arguments: [AtumCopy.Argument] = []) -> String {
        ChatCopy.text(design, key, arguments)
    }
}
