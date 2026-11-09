import Foundation

public struct DriveStageACopy: Sendable {
    public static let sourceRevision = "2bc7ea5170510a53d2b6608d7304e61fadc539ca"
    public static let keyPrefix = "src.matrix.mobile-copy.mobilePhoneCopy.drive."
    public static let keys: Set<String> = [
        "changed", "connectBody", "downloadFailed", "keepOffline", "keptOffline",
        "lowDisk", "needsConnection", "removeOffline", "storageUnavailable",
    ]
    public static let locales: Set<String> = ["en", "vi", "ja", "zh", "zh-Hant"]

    private struct Source: Decodable {
        let repository, revision, prefix: String
    }
    private struct Payload: Decodable {
        let schemaVersion: Int
        let source: Source
        let locales: [String: [String: String]]
    }

    private let values: [String: [String: String]]

    public init() throws {
        guard let url = Bundle.module.url(forResource: "DriveStageACopy", withExtension: "json")
        else { throw CopyError.invalid }
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        guard payload.schemaVersion == 1,
              payload.source.repository == "atum-platform/atum-app",
              payload.source.revision == Self.sourceRevision,
              payload.source.prefix == Self.keyPrefix,
              Set(payload.locales.keys) == Self.locales,
              payload.locales.values.allSatisfy({ Set($0.keys) == Self.keys }) else {
            throw CopyError.invalid
        }
        values = payload.locales
    }

    public func text(_ key: String, locale: String) throws -> String {
        guard Self.keys.contains(key), let value = values[locale]?[key], !value.isEmpty else {
            throw CopyError.invalid
        }
        return value
    }

    public enum CopyError: Error, Equatable { case invalid }
}
