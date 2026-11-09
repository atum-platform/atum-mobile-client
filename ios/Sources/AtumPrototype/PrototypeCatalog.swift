import Foundation
import AtumDesign

/// Typed P2 fixtures derived from the approved catalog. Never a live API model.
public struct PrototypeCatalog: Decodable, Sendable {
    public struct Text: Decodable, Sendable {
        public enum Argument: Decodable, Sendable {
            case text(String), number(Int64)
            public init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let number = try? value.decode(Int64.self) { self = .number(number) }
                else { self = .text(try value.decode(String.self)) }
            }
            var copyArgument: AtumCopy.Argument {
                switch self { case let .text(value): .text(value); case let .number(value): .number(value) }
            }
        }
        public let key: String?
        public let literal: String?
        public let arguments: [Argument]?

        public func resolve(using copy: AtumCopy, locale: String) throws -> String {
            if let key { return try copy.text(key, locale: locale, arguments: (arguments ?? []).map(\.copyArgument)) }
            guard let literal else { throw CatalogError.invalidText }
            return literal
        }
    }
    public struct Row: Decodable, Sendable {
        public let label: Text
        public let detail: Text
        public let value: Text
        public let route: String
        public let style: String
    }
    public struct State: Decodable, Identifiable, Sendable {
        public let id: String
        public let studyLabel: String
        public let text: Text
        public let actions: [Row]
    }
    public struct Screen: Decodable, Identifiable, Sendable {
        public let id: String
        public let family: String
        public let kind: String
        public let title: Text
        public let body: Text
        public let rows: [Row]
        public let inputs: [Row]
        public let actions: [Row]
        public let states: [State]
    }
    public enum CatalogError: Error { case missingResource, invalidText, missingScreen(String), missingState(String) }

    public let schemaVersion: Int
    public let approvedDesignCommit: String
    public let sourceSHA256: String
    public let uiCopy: [String: Text]
    public let screens: [Screen]

    public static func load() throws -> PrototypeCatalog {
        guard let url = Bundle.module.url(forResource: "native-catalog", withExtension: "json", subdirectory: "Fixtures") else {
            throw CatalogError.missingResource
        }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    public func screen(_ id: String) throws -> Screen {
        guard let screen = screens.first(where: { $0.id == id }) else { throw CatalogError.missingScreen(id) }
        return screen
    }
    public func state(_ id: String, in screen: String) throws -> State {
        guard let state = try self.screen(screen).states.first(where: { $0.id == id }) else { throw CatalogError.missingState(id) }
        return state
    }
}
