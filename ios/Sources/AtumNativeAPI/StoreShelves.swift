import Foundation

/// Desktop Store search (`matrix/store/discover-view.tsx:60-72`): accent- and
/// đ-insensitive, case-insensitive, whitespace-collapsed substring match.
public enum StoreSearch {
    public static func normalized(_ value: String) -> String {
        value.decomposedStringWithCanonicalMapping
            .unicodeScalars
            .filter { !CharacterSet.nonBaseCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .lowercased()
            .replacingOccurrences(of: "đ", with: "d")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// An empty query matches everything; otherwise the joined fields must
    /// contain the normalized query.
    public static func matches(_ query: String, fields: [String]) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return true }
        return normalized(fields.joined(separator: " ")).contains(needle)
    }
}

/// Desktop `STORE_GLYPH_ICON` (`matrix/store/store-card.tsx:24-90`): the
/// catalog names each item's glyph as an emoji, and the tile draws its own
/// Phosphor Light counterpart. An emoji without one falls back to the kind's
/// glyph, never to the emoji itself. Values are phone glyph aliases
/// (`ios/Vendor/AtumKitIcons/phosphor-map.json`).
public enum StoreGlyphs {
    static let emoji: [String: String] = [
        "🛍": "StoreShoppingBag", "🛒": "StoreShoppingCart",
        "🔎": "StoreMagnifyingGlass", "🔍": "StoreMagnifyingGlass",
        "🔷": "StoreDiamond", "✦": "StoreSparkle",
        "✒": "StorePenNib", "✍": "StorePenNib", "📝": "StoreNotePencil",
        "🧭": "StoreCompass", "🗓": "StoreCalendarBlank", "📊": "StoreChartBar",
        "📈": "StoreTrendUp", "📄": "StoreFileText", "📑": "StoreFiles",
        "🗂": "StoreFolders", "🏷": "StoreTag", "🎓": "StoreGraduationCap",
        "🧑‍🏫": "StoreChalkboardTeacher", "🌐": "StoreGlobe", "🧾": "StoreReceipt",
        "🥗": "StoreBowlFood", "🍲": "StoreCookingPot", "🥚": "StoreEgg",
        "😂": "StoreSmiley", "🗣": "StoreUserSound", "📣": "StoreMegaphone",
        "🖼": "StoreImage", "📸": "StoreCamera", "🖥": "StoreDesktop",
        "🔄": "StoreArrowsClockwise", "📥": "StoreTrayArrowDown", "🎧": "StoreHeadphones",
        "🎨": "StorePalette", "🎬": "StoreFilmSlate", "🏃": "StorePersonSimpleRun",
        "🏋": "StoreBarbell", "👾": "StoreGameController", "💡": "StoreLightbulb",
        "💰": "StoreMoney", "💵": "StoreMoney", "💼": "StoreBriefcase",
        "📌": "StorePushPin", "📍": "StoreMapPin", "📒": "StoreNotebook",
        "📖": "StoreBookOpen", "🧩": "StorePuzzlePiece", "⚡": "StoreLightning",
        "🐾": "StorePawPrint",
    ]

    /// Desktop `STORE_KIND_ICON`: skill Sparkles, agent Robot, pet PawPrint.
    public static func kindAlias(_ kind: StoreCatalogItem.Kind) -> String {
        switch kind {
        case .skill: "StoreSparkle"
        case .agent: "StoreRobot"
        case .pet: "StorePawPrint"
        }
    }

    /// Variation selectors and text/emoji presentation marks never change
    /// which glyph is meant (desktop `storeGlyphIcon`).
    public static func alias(glyph: String, kind: StoreCatalogItem.Kind) -> String {
        let key = String(String.UnicodeScalarView(glyph.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.filter { $0.value != 0xFE0E && $0.value != 0xFE0F }))
        return emoji[key] ?? kindAlias(kind)
    }

    /// Every alias this map can return, for the asset presence test.
    public static var allAliases: Set<String> {
        Set(emoji.values).union([StoreCatalogItem.Kind.skill, .agent, .pet].map(kindAlias))
    }
}
