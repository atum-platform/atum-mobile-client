import AtumNativeAPI
import Foundation

/// What the picker lists. Without a search: Recent (the Share Suggestion chat first,
/// then the most recent chats) and then every other chat in Home's recency order,
/// each chat once. While searching: the model's matches only.
struct SharePickerSections: Equatable {
    static let recentCount = 5

    var recent: [ShareChat]
    var chats: [ShareChat]
    var isSearching: Bool

    var isEmpty: Bool { recent.isEmpty && chats.isEmpty }

    static func make(all: [ShareChat], matches: [ShareChat], search: String,
                     suggested: String?) -> SharePickerSections {
        guard search.isEmpty else { return SharePickerSections(recent: [], chats: matches, isSearching: true) }
        var recent = [ShareChat]()
        if let suggested, let chat = all.first(where: { $0.id == suggested }) { recent.append(chat) }
        for chat in all where recent.count < recentCount && !recent.contains(where: { $0.id == chat.id }) {
            recent.append(chat)
        }
        let shown = Set(recent.map(\.id))
        return SharePickerSections(recent: recent, chats: all.filter { !shown.contains($0.id) }, isSearching: false)
    }
}

/// The preview strip's words for one shared item, also its VoiceOver label.
enum SharePreviewText {
    static func label(_ item: ShareItem, bundle: Bundle = .main) -> String {
        switch item.kind {
        case .image: SharePickerCopy.text(.photo, bundle: bundle)
        case .video: SharePickerCopy.text(.video, bundle: bundle)
        case .file: [SharePickerCopy.text(.file, bundle: bundle), detail(item)].compactMap { $0 }.joined(separator: ", ")
        case .url: [SharePendingCopy.text(.link), detail(item)].compactMap { $0 }.joined(separator: ", ")
        case .text: [SharePendingCopy.text(.text), detail(item)].compactMap { $0 }.joined(separator: ", ")
        }
    }

    /// A file's name, a link's host (else the bounded link text), or a text's opening.
    static func detail(_ item: ShareItem) -> String? {
        switch item.kind {
        case .image, .video: return nil
        case .file: return item.filename.flatMap { $0.isEmpty ? nil : $0 }
        case .url:
            guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return URL(string: text)?.host(percentEncoded: false) ?? String(text.prefix(80))
        case .text:
            guard let text = item.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.count > 80 ? String(line.prefix(79)) + "…" : line
        }
    }
}
