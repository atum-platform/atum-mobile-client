import XCTest
@testable import AtumChat

final class ModelPickerPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ModelPickerPreferencesStore!

    override func setUp() {
        super.setUp()
        suiteName = "ModelPickerPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = ModelPickerPreferencesStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFavoritesAreUniqueBoundedAndToggleMostRecentFirst() {
        let values = (0..<205).map { "model-\($0)" } + ["model-2", "model-3"]
        var preferences = ModelPickerPreferences(favorites: values)
        XCTAssertEqual(preferences.favorites.count, 200)
        XCTAssertEqual(Set(preferences.favorites).count, 200)
        XCTAssertEqual(preferences.favorites.first, "model-0")

        preferences = preferences.toggling("model-2")
        XCTAssertFalse(preferences.favorites.contains("model-2"))
        preferences = preferences.toggling("model-2")
        XCTAssertEqual(preferences.favorites.first, "model-2")
        XCTAssertEqual(preferences.favorites.count, 200)
    }

    func testStorageSeparatesMatrixAccountsAndExactDestinations() {
        store.write(ModelPickerPreferences(favorites: ["nguyet-thuc"]),
                    matrixAccountID: "@an:atum.test", destinationID: "cloud")
        store.write(ModelPickerPreferences(favorites: ["nhat-thuc"]),
                    matrixAccountID: "@an:atum.test", destinationID: "mac:mini-a")
        store.write(ModelPickerPreferences(favorites: ["other-model"]),
                    matrixAccountID: "@other:atum.test", destinationID: "mac:mini-a")

        XCTAssertEqual(store.read(matrixAccountID: "@an:atum.test", destinationID: "cloud").favorites,
                       ["nguyet-thuc"])
        XCTAssertEqual(store.read(matrixAccountID: "@an:atum.test", destinationID: "mac:mini-a").favorites,
                       ["nhat-thuc"])
        XCTAssertEqual(store.read(matrixAccountID: "@other:atum.test", destinationID: "mac:mini-a").favorites,
                       ["other-model"])
        XCTAssertEqual(store.read(matrixAccountID: "@an:atum.test", destinationID: "mac:mini-b").favorites, [])
    }

    func testUnavailableFavoritesStayStoredWhileVisibleListIsFiltered() {
        let preferences = ModelPickerPreferences(favorites: ["temporarily-offline", "nguyet-thuc"])
        store.write(preferences, matrixAccountID: "@an:atum.test", destinationID: "mac:mini-a")

        let loaded = store.read(matrixAccountID: "@an:atum.test", destinationID: "mac:mini-a")
        XCTAssertEqual(loaded.visible(in: ["nguyet-thuc"]), ["nguyet-thuc"])
        XCTAssertEqual(loaded.favorites, ["temporarily-offline", "nguyet-thuc"])
        XCTAssertEqual(store.read(matrixAccountID: "@an:atum.test", destinationID: "mac:mini-a").favorites,
                       ["temporarily-offline", "nguyet-thuc"])
    }

    func testCorruptDuplicateAndOversizedStorageFailClosed() throws {
        func storageKey(after writing: ModelPickerPreferences) throws -> String {
            store.write(writing, matrixAccountID: "@an:atum.test", destinationID: "cloud")
            return try XCTUnwrap(defaults.dictionaryRepresentation().keys.first {
                $0.hasPrefix("atum.phone-model-picker.v1.")
            })
        }

        let key = try storageKey(after: ModelPickerPreferences(favorites: ["seed"]))
        defaults.set(Data("not-json".utf8), forKey: key)
        XCTAssertEqual(store.read(matrixAccountID: "@an:atum.test", destinationID: "cloud").favorites, [])

        defaults.set(try JSONSerialization.data(withJSONObject: [
            "version": 1, "favorites": ["same", "same"]
        ]), forKey: key)
        XCTAssertEqual(store.read(matrixAccountID: "@an:atum.test", destinationID: "cloud").favorites, [])

        defaults.set(try JSONSerialization.data(withJSONObject: [
            "version": 1, "favorites": (0...200).map { "model-\($0)" }
        ]), forKey: key)
        XCTAssertEqual(store.read(matrixAccountID: "@an:atum.test", destinationID: "cloud").favorites, [])

        defaults.set(try JSONSerialization.data(withJSONObject: [
            "version": 1, "favorites": ["ok"], "future": true
        ]), forKey: key)
        XCTAssertEqual(store.read(matrixAccountID: "@an:atum.test", destinationID: "cloud").favorites, [])

        defaults.set(Data(repeating: 0x20, count: 1_000_001), forKey: key)
        XCTAssertEqual(store.read(matrixAccountID: "@an:atum.test", destinationID: "cloud").favorites, [])
    }

    func testInvalidAccountDestinationAndFavoriteIdentitiesFailClosed() {
        store.write(ModelPickerPreferences(favorites: ["nguyet-thuc"]),
                    matrixAccountID: "not-matrix", destinationID: "cloud")
        store.write(ModelPickerPreferences(favorites: ["nguyet-thuc"]),
                    matrixAccountID: "@an:atum.test", destinationID: "mac:bad/value")
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains {
            $0.hasPrefix("atum.phone-model-picker.v1.")
        })
        XCTAssertEqual(ModelPickerPreferences(favorites: [" ok ", "bad\nvalue", "good"]).favorites, ["good"])
    }
}
