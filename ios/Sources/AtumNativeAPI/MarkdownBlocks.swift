import Foundation

/// Splits a parsed message (`MessageMarkup.parse`) into the blocks the chat
/// lays out with plain text views (B17): paragraphs, headings, list items,
/// code blocks, quotes, rules and table rows, by Foundation's presentation
/// intents. Pure: no layout, no UI framework.
public enum MarkdownBlocks {
    public struct Block: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case paragraph
            case heading(Int)
            /// The first block of a list item, with its marker ("•", "1.").
            case listItem(marker: String)
            /// A later paragraph of the same list item.
            case continuation
            case code
            case quote
            case rule
            /// One table row: a cell per column, in column order, empty where
            /// the markdown has none. The header row has `isHeader`.
            case tableRow(cells: [AttributedString], isHeader: Bool)
        }

        /// The block's place in the message.
        public let id: Int
        public let kind: Kind
        /// The block's text, without presentation intents. Empty for rules and
        /// table rows (their text is in the cells).
        public let text: AttributedString
        /// List nesting: 0 for a top-level item.
        public let depth: Int

        public init(id: Int, kind: Kind, text: AttributedString, depth: Int) {
            self.id = id
            self.kind = kind
            self.text = text
            self.depth = depth
        }
    }

    /// A message's words without its markdown, one line (B21: a quote of an
    /// answer reads as the answer looks, never as its source): every block's
    /// text, table cells included, joined by single spaces; list markers,
    /// rules and emphasis marks are dropped. "**Dự án** là…\n- Tạo lịch"
    /// reads "Dự án là… Tạo lịch".
    public static func plainText(_ markdown: String) -> String {
        let pieces = blocks(MessageMarkup.parse(markdown)).flatMap { block -> [String] in
            switch block.kind {
            case let .tableRow(cells, _): cells.map { String($0.characters) }
            case .rule: []
            default: [String(block.text.characters)]
            }
        }
        return pieces
            .flatMap { $0.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) }
            .joined(separator: " ")
    }

    public static func blocks(_ value: AttributedString) -> [Block] {
        var blocks: [Block] = []
        var markedItems = Set<Int>()
        // Table rows by the row intent's identity: where the row's block is
        // and its cells so far.
        var tableRows: [Int: (index: Int, cells: [AttributedString], isHeader: Bool)] = [:]
        for (intent, range) in value.runs[\.presentationIntent] {
            var text = AttributedString(value[range])
            text.presentationIntent = nil
            let components = intent?.components ?? []
            let id = blocks.count
            if components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) {
                blocks.append(Block(id: id, kind: .code, text: trimmingTrailingNewlines(text), depth: 0))
                continue
            }
            if components.contains(where: { $0.kind == .thematicBreak }) {
                blocks.append(Block(id: id, kind: .rule, text: AttributedString(), depth: 0))
                continue
            }
            if let row = components.first(where: { isTableRow($0.kind) }) {
                // Header cells are `.tableHeaderRow`, body cells `.tableRow`;
                // an empty cell has no run at all, so cells go by column.
                let columns = components.lazy.compactMap { component -> Int? in
                    if case let .table(columns) = component.kind { return columns.count }
                    return nil
                }.first ?? 0
                let column = components.lazy.compactMap { component -> Int? in
                    if case let .tableCell(index) = component.kind { return index }
                    return nil
                }.first ?? 0
                var entry = tableRows[row.identity]
                    ?? (index: blocks.count, cells: [], isHeader: row.kind == .tableHeaderRow)
                let width = max(columns, column + 1, entry.cells.count)
                if entry.cells.count < width {
                    entry.cells.append(contentsOf: repeatElement(AttributedString(), count: width - entry.cells.count))
                }
                entry.cells[column] = text
                let block = Block(id: entry.index, kind: .tableRow(cells: entry.cells, isHeader: entry.isHeader),
                                  text: AttributedString(), depth: 0)
                if tableRows[row.identity] == nil {
                    blocks.append(block)
                } else {
                    blocks[entry.index] = block
                }
                tableRows[row.identity] = entry
                continue
            }
            if let header = components.first(where: { if case .header = $0.kind { true } else { false } }),
               case let .header(level) = header.kind {
                blocks.append(Block(id: id, kind: .heading(level), text: text, depth: 0))
                continue
            }
            // Components run from the innermost outwards: the first list item
            // is this paragraph's own, the first list its own list.
            if let item = components.first(where: { if case .listItem = $0.kind { true } else { false } }),
               case let .listItem(ordinal) = item.kind {
                let lists = components.filter {
                    switch $0.kind {
                    case .orderedList, .unorderedList: true
                    default: false
                    }
                }
                let depth = max(0, lists.count - 1)
                if markedItems.insert(item.identity).inserted {
                    let ordered = lists.first.map { $0.kind == .orderedList } ?? false
                    blocks.append(Block(id: id, kind: .listItem(marker: ordered ? "\(ordinal)." : "•"), text: text,
                                        depth: depth))
                } else {
                    blocks.append(Block(id: id, kind: .continuation, text: text, depth: depth))
                }
                continue
            }
            if components.contains(where: { $0.kind == .blockQuote }) {
                blocks.append(Block(id: id, kind: .quote, text: text, depth: 0))
                continue
            }
            blocks.append(Block(id: id, kind: .paragraph, text: text, depth: 0))
        }
        return blocks
    }

    /// Every link in the message, in order, with the text it is shown as
    /// (VoiceOver reaches links inside a combined bubble through these).
    public static func links(in value: AttributedString) -> [(text: String, url: URL)] {
        // Runs over the link alone: a link styled in parts is one range.
        value.runs[\.link].compactMap { link, range in
            guard let link else { return nil }
            let text = String(value[range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            return (text.isEmpty ? link.absoluteString : text, link)
        }
    }

    private static func isTableRow(_ kind: PresentationIntent.Kind) -> Bool {
        switch kind {
        case .tableRow, .tableHeaderRow: true
        default: false
        }
    }

    private static func trimmingTrailingNewlines(_ text: AttributedString) -> AttributedString {
        var text = text
        while let last = text.characters.last, last.isNewline {
            text.removeSubrange(text.characters.index(before: text.endIndex)..<text.endIndex)
        }
        return text
    }
}
