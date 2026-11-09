import AtumChat
import AtumNativeAPI
import SwiftUI

/// B21: what a reply answers, with a 2 pt rule. Drawn only where the
/// projection set `showsQuote` (desktop's rule: no quote under an agent's
/// answer that sits directly below its question). Pending details show no
/// words; unavailable or failed details show one quiet line. Tapping scrolls
/// to the original when it is loaded.
struct QuoteView: View {
    let row: ChatRow
    let roomTitle: String

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatRowInteractions) private var interactions
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The quote's own element, in answers and bubbles alike (the B21 U
    /// checks find it under its row). Outside the rows' `row.<displayId>`
    /// namespace (plan §2.10): a quote is part of a row, never a row.
    static let quoteID = "quote"

    var body: some View {
        if let theme {
            Button {
                if let eventID = row.item.replyTo { interactions.showOriginal(eventID) }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(quiet(theme).opacity(0.6))
                        .frame(width: 2)
                    VStack(alignment: .leading, spacing: 2) {
                        content(theme)
                    }
                    .frame(minHeight: 18, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(theme.copy.text(.quoteJump))
            .accessibilityIdentifier(Self.quoteID)
        }
    }

    @ViewBuilder private func content(_ theme: ChatTheme) -> some View {
        let muted = quiet(theme)
        switch row.replyDetails?.state {
        case let .ready(sender, senderName, preview):
            Text(verbatim: name(sender: sender, senderName: senderName, theme: theme))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(muted)
                .lineLimit(1)
            // Two lines of the original; at the accessibility text sizes the
            // whole of it, so large text never cuts a short quote short.
            Text(verbatim: text(preview, sender: sender, theme: theme))
                .font(.footnote)
                .foregroundStyle(muted)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
        case .unavailable?, .error?:
            Text(theme.copy.text(.quoteUnavailable))
                .font(.footnote)
                .foregroundStyle(muted)
        case .pending?, nil:
            EmptyView()
        }
    }

    /// Inside your own ink bubble the quote reads in `on-bubble-own`, dimmed;
    /// everywhere else in the chat's quiet ink.
    private func quiet(_ theme: ChatTheme) -> Color {
        row.item.isOwn ? theme.design.kit.color(.onBubbleOwn, scheme: scheme).opacity(0.72)
                       : theme.quiet(scheme)
    }

    private func name(sender: String, senderName: String?, theme: ChatTheme) -> String {
        if let senderName, !senderName.isEmpty { return senderName }
        return sender == ownSender ? theme.copy.text(.you) : roomTitle
    }

    @Environment(\.chatOwnUserID) private var ownSender

    /// The original's words as its row shows them: mine literally (B6),
    /// everyone else's (answers, people) without their markdown, as the
    /// rows render it.
    private func text(_ preview: ReplyPreview, sender: String, theme: ChatTheme) -> String {
        switch preview {
        case let .text(body):
            sender == ownSender
                ? body.split(whereSeparator: \.isNewline).joined(separator: " ")
                : QuotePlainText.text(body)
        case .image: theme.copy.text(.photo)
        case let .file(name): name.isEmpty ? theme.copy.text(.file) : name
        case let .placeholder(reason): ChatRowText.placeholder(reason, copy: theme.copy)
        case .unsupported: theme.copy.text(.unsupported)
        }
    }
}

/// `MarkdownBlocks.plainText`, parsed once per body: a quote re-renders with
/// its row, and the original can be a long answer.
@MainActor
enum QuotePlainText {
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 200
        return cache
    }()

    static func text(_ body: String) -> String {
        if let hit = cache.object(forKey: body as NSString) { return hit as String }
        let plain = MarkdownBlocks.plainText(body)
        cache.setObject(plain as NSString, forKey: body as NSString)
        return plain
    }
}
