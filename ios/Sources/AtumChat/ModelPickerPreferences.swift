import Foundation

/// Phone-local presentation state for the model picker. Favorites grant no
/// authority and never leave this device. The storage scope keeps one Matrix
/// account and one exact server-authored destination independent from every
/// other account and Mac.
public struct ModelPickerPreferences: Equatable, Sendable {
    public static let maximumFavorites = 200

    public let favorites: [String]

    public init(favorites: [String] = []) {
        var seen = Set<String>()
        var bounded: [String] = []
        bounded.reserveCapacity(min(favorites.count, Self.maximumFavorites))
        for favorite in favorites where Self.validFavoriteID(favorite) && seen.insert(favorite).inserted {
            bounded.append(favorite)
            if bounded.count == Self.maximumFavorites { break }
        }
        self.favorites = bounded
    }

    public func toggling(_ favoriteID: String) -> ModelPickerPreferences {
        guard Self.validFavoriteID(favoriteID) else { return self }
        if favorites.contains(favoriteID) {
            return ModelPickerPreferences(favorites: favorites.filter { $0 != favoriteID })
        }
        return ModelPickerPreferences(favorites: [favoriteID] + favorites)
    }

    /// Returns visible favorites without rewriting storage. A temporarily
    /// unavailable route therefore keeps its star for a later catalog read.
    public func visible(in availableFavoriteIDs: Set<String>) -> [String] {
        favorites.filter(availableFavoriteIDs.contains)
    }

    fileprivate static func validFavoriteID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 4_096 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

/// A bounded UserDefaults codec. Invalid scopes, malformed JSON, duplicate
/// entries, unknown fields, and oversized payloads all read as empty.
public struct ModelPickerPreferencesStore {
    private static let version = 1
    private static let maximumBytes = 1_000_000
    private static let keyPrefix = "atum.phone-model-picker.v1."

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func read(matrixAccountID: String, destinationID: String) -> ModelPickerPreferences {
        guard let key = Self.key(matrixAccountID: matrixAccountID, destinationID: destinationID),
              let data = defaults.data(forKey: key), data.count <= Self.maximumBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["version", "favorites"],
              root["version"] as? Int == Self.version,
              let values = root["favorites"] as? [String],
              values.count <= ModelPickerPreferences.maximumFavorites,
              Set(values).count == values.count,
              values.allSatisfy(ModelPickerPreferences.validFavoriteID) else {
            return ModelPickerPreferences()
        }
        return ModelPickerPreferences(favorites: values)
    }

    public func write(_ preferences: ModelPickerPreferences,
                      matrixAccountID: String,
                      destinationID: String) {
        guard let key = Self.key(matrixAccountID: matrixAccountID, destinationID: destinationID),
              let data = try? JSONSerialization.data(withJSONObject: [
                  "version": Self.version,
                  "favorites": preferences.favorites
              ], options: [.sortedKeys]),
              data.count <= Self.maximumBytes else { return }
        defaults.set(data, forKey: key)
    }

    private static func key(matrixAccountID: String, destinationID: String) -> String? {
        guard validMatrixAccountID(matrixAccountID), validDestinationID(destinationID) else { return nil }
        let scope = matrixAccountID + "\u{0}" + destinationID
        let encoded = Data(scope.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return keyPrefix + encoded
    }

    private static func validMatrixAccountID(_ value: String) -> Bool {
        value.first == "@" && value.count <= 1_024
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
            }
    }

    private static func validDestinationID(_ value: String) -> Bool {
        if value == "cloud" { return true }
        return value.range(of: #"\Amac:[A-Za-z0-9_-]{1,128}\z"#,
                           options: .regularExpression) != nil
    }
}
