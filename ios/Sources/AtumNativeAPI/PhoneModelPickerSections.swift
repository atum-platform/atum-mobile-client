import Foundation
/** Preserve user-visible identity, state and recovery behavior across connection changes. */
/// mobile's picker: "a few defaults/favorites at the top, then the rest divided
/// by providers below. Search bar and filter at the bottom"). The desktop card
/// is built from the same rules, so the two stay the same list. Nothing here
/// knows about SwiftUI, copy or storage: the view gives it rows, the person's
/// stars and what they typed, and draws what comes back.

/// The filter button's choices: favorites only, and one connection at a time.
/// A person who never opens it never has one.
public struct PhoneModelPickerFilter: Equatable, Sendable {
    public var favoritesOnly: Bool
    /// One `Row.connectionID`; nil lists every connection.
    public var connection: String?

    public init(favoritesOnly: Bool = false, connection: String? = nil) {
        self.favoritesOnly = favoritesOnly
        self.connection = connection
    }

    public static let none = PhoneModelPickerFilter()

    public var isActive: Bool { favoritesOnly || connection != nil }
}

public struct PhoneModelPickerSection: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// Atum's line-up and every starred model. Always open.
        case defaults
        /// The connected account subscriptions, after Atum's line-up. Always open.
        case subscriptions
        /// One connection's remaining models, under its own header.
        case connection(String)
    }

    public let kind: Kind
    public let rows: [PhoneModelPickerProjection.Row]

    public init(kind: Kind, rows: [PhoneModelPickerProjection.Row]) {
        self.kind = kind
        self.rows = rows
    }

    /// The current selection is one of these rows.
    public var containsCurrent: Bool { rows.contains(where: \.selected) }

    public var isCollapsible: Bool {
        if case .connection = kind { true } else { false }
    }

    public var id: String {
        switch kind {
        case .defaults: "defaults"
        case .subscriptions: "subscriptions"
        case let .connection(connection): "connection:" + connection
        }
    }
}

public enum PhoneModelPickerSections {
    /// The sections in order: Atum's line-up (in the order the rows came in) and
    /// every other starred model (newest star first), then the connected
    /// subscriptions, then one section per connection holding what is left, in
    /// the order the connections first appear. A model lives in exactly one
    /// section, so starring moves it up and unstarring moves it back. Search and
    /// the filter apply to every section, and a section with nothing left is not
    /// drawn. A star on a model the rows do not list waits for it and is never
    /// dropped.
    ///
    /// `searchText` is what a row also answers to besides its name: its
    /// connection and account words, in the person's language.
    public static func make(rows: [PhoneModelPickerProjection.Row],
                            favorites: [String],
                            query: String,
                            filter: PhoneModelPickerFilter,
                            locale: Locale = .current,
                            searchText: (PhoneModelPickerProjection.Row) -> String = { _ in "" })
        -> [PhoneModelPickerSection] {
        let starred = Set(favorites)
        let terms = normalized(query, locale: locale).split(whereSeparator: \.isWhitespace).map(String.init)

        func isStarred(_ row: PhoneModelPickerProjection.Row) -> Bool {
            row.favoriteID.map(starred.contains) ?? false
        }

        func passes(_ row: PhoneModelPickerProjection.Row) -> Bool {
            if filter.favoritesOnly, !isStarred(row) { return false }
            if let connection = filter.connection, row.connectionID != connection { return false }
            guard !terms.isEmpty else { return true }
            let haystack = normalized(row.displayName + " " + searchText(row), locale: locale)
            return terms.allSatisfy { haystack.contains($0) }
        }

        var byFavorite: [String: PhoneModelPickerProjection.Row] = [:]
        for row in rows {
            if let id = row.favoriteID, byFavorite[id] == nil { byFavorite[id] = row }
        }
        var pinned: [PhoneModelPickerProjection.Row] = []
        var pinnedIDs = Set<String>()
        for id in favorites {
            guard let row = byFavorite[id], row.source != .atum, pinnedIDs.insert(id).inserted else { continue }
            pinned.append(row)
        }
        let defaults = (rows.filter { $0.source == .atum } + pinned).filter(passes)
        let subscriptions = rows.filter(\.isSubscription).filter(passes)

        var order: [String] = []
        var groups: [String: [PhoneModelPickerProjection.Row]] = [:]
        for row in rows where row.source != .atum && !row.isSubscription && !isStarred(row) && passes(row) {
            if groups[row.connectionID] == nil { order.append(row.connectionID) }
            groups[row.connectionID, default: []].append(row)
        }

        var sections: [PhoneModelPickerSection] = []
        if !defaults.isEmpty { sections.append(PhoneModelPickerSection(kind: .defaults, rows: defaults)) }
        if !subscriptions.isEmpty {
            sections.append(PhoneModelPickerSection(kind: .subscriptions, rows: subscriptions))
        }
        for connection in order {
            sections.append(PhoneModelPickerSection(kind: .connection(connection), rows: groups[connection] ?? []))
        }
        return sections
    }

    /// The connections the filter can narrow to: Atum first, then each other
    /// connection in the order its rows first appear.
    public static func connections(in rows: [PhoneModelPickerProjection.Row]) -> [String] {
        var seen = Set<String>()
        var connections: [String] = []
        if let atum = rows.first(where: { $0.source == .atum }) {
            seen.insert(atum.connectionID)
            connections.append(atum.connectionID)
        }
        for row in rows where seen.insert(row.connectionID).inserted {
            connections.append(row.connectionID)
        }
        return connections
    }

    /// Case- and diacritic-insensitive, as a person types it.
    static func normalized(_ value: String, locale: Locale) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }
}

/// Which connection sections are open. A section opens by itself when it holds
/// the current selection, or while a search or a filter is looking at the list
/// (a match hidden in a closed section would be invisible). What a person opens
/// or closes is theirs until the view changes. A section that has held the
/// current selection stays open, so a pick never folds the one they were in.
public struct PhoneModelPickerDisclosure: Equatable, Sendable {
    private var view = ""
    private var overrides: [String: Bool] = [:]
    private var seen = Set<String>()

    public init() {}

    /// `view` names what is on screen (the search text and the filter). A
    /// person's open and close choices last only while it is unchanged.
    public mutating func show(view next: String) {
        guard next != view else { return }
        view = next
        overrides = [:]
    }

    /// Remembers the sections that have held the current selection.
    public mutating func settle(_ sections: [PhoneModelPickerSection]) {
        for section in sections where section.containsCurrent { seen.insert(section.id) }
    }

    public func isOpen(_ section: PhoneModelPickerSection, browsing: Bool) -> Bool {
        guard section.isCollapsible else { return true }
        return overrides[section.id] ?? (browsing || section.containsCurrent || seen.contains(section.id))
    }

    public mutating func toggle(_ section: PhoneModelPickerSection, browsing: Bool) {
        guard section.isCollapsible else { return }
        overrides[section.id] = !isOpen(section, browsing: browsing)
    }
}
