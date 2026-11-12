import Foundation

/// Reads the committed desktop String Catalog. The UI never owns translations.
public struct AtumCopy {
    public enum Argument: Equatable, Sendable {
        case text(String)
        case number(Int64)
    }

    public enum CopyError: Error, Equatable {
        case unsupportedLocale(String)
        case missingKey(String)
        case invalidArguments(String)
        case invalidFormat(String)
    }

    private struct Unit: Decodable { let value: String }
    private struct Variant: Decodable { let stringUnit: Unit }
    private struct Variations: Decodable { let plural: [String: Variant] }
    private struct Substitution: Decodable { let argNum: Int; let variations: Variations }
    private struct Localization: Decodable {
        let stringUnit: Unit
        let substitutions: [String: Substitution]?
    }
    private struct Entry: Decodable { let localizations: [String: Localization] }
    private struct Catalog: Decodable { let sourceLanguage: String; let strings: [String: Entry] }
    private struct Parameter: Decodable { let kind: String; let nullable: Bool }
    private struct Exact: Decodable {
        let argumentIndex: Int
        let value: Int64
        let key: String
        let alternatives: [Exact]?
    }
    private struct Contract: Decodable {
        let schemaVersion: Int
        let parameters: [String: [Parameter]]
        let exactValues: [String: Exact]
        let arrayLengths: [String: [String: Int]]
    }

    private let catalog: Catalog
    private let contract: Contract
    public let locales: Set<String>

    public init() throws {
        try self.init(catalogData: AtumDesign.data(for: "Localizable.xcstrings"),
                      contractData: AtumDesign.data(for: "copy-contract.json"),
                      locales: Set(AtumDesign.manifest().locales))
    }

    public init(catalogData: Data, contractData: Data, locales: Set<String>) throws {
        let decoder = JSONDecoder()
        catalog = try decoder.decode(Catalog.self, from: catalogData)
        contract = try decoder.decode(Contract.self, from: contractData)
        guard contract.schemaVersion == AtumDesign.supportedSchemaVersion else {
            throw AtumDesign.ResourceError.unsupportedSchema(contract.schemaVersion)
        }
        self.locales = locales
    }

    public func contains(_ key: String) -> Bool { catalog.strings[key] != nil }

    /// The argument kinds (`"string"` or `"number"`) the export declares for a
    /// key, in order, or nil when the key has no contract entry.
    public func parameterKinds(_ key: String) -> [String]? { contract.parameters[key]?.map(\.kind) }

    public func text(_ key: String, locale: String, arguments: [Argument] = []) throws -> String {
        guard locales.contains(locale) else { throw CopyError.unsupportedLocale(locale) }
        guard catalog.strings[key] != nil, let parameters = contract.parameters[key] else {
            throw CopyError.missingKey(key)
        }
        guard parameters.count == arguments.count else { throw CopyError.invalidArguments(key) }
        for (parameter, argument) in zip(parameters, arguments) {
            switch (parameter.kind, argument) {
            case ("string", .text), ("number", .number): break
            default: throw CopyError.invalidArguments(key)
            }
        }
        var selected = key
        if let exact = contract.exactValues[key] {
            for branch in [exact] + (exact.alternatives ?? []) {
                guard arguments.indices.contains(branch.argumentIndex - 1) else {
                    throw CopyError.invalidArguments(key)
                }
                if arguments[branch.argumentIndex - 1] == .number(branch.value) {
                    selected = branch.key
                    break
                }
            }
        }
        guard let localization = catalog.strings[selected]?.localizations[locale] else {
            throw CopyError.missingKey(selected)
        }
        // Plain source strings are literal, even when they contain '%' or '%@'.
        guard !parameters.isEmpty else { return localization.stringUnit.value }
        var format = localization.stringUnit.value
        for (name, substitution) in localization.substitutions ?? [:] {
            guard arguments.indices.contains(substitution.argNum - 1),
                  case let .number(count) = arguments[substitution.argNum - 1] else {
                throw CopyError.invalidArguments(key)
            }
            // The producer emits one/other only and explicit exact-value branches.
            // CLDR ja/zh/vi have no 'one'; exact branches preserve source count=1.
            let category = count == 1 && locale == "en" ? "one" : "other"
            guard let variation = substitution.variations.plural[category] else {
                throw CopyError.invalidFormat(key)
            }
            format = format.replacingOccurrences(of: "%#@\(name)@", with: variation.stringUnit.value)
        }
        guard !format.contains("%#@") else { throw CopyError.invalidFormat(key) }
        let values: [CVarArg] = arguments.map { argument in
            switch argument {
            case let .text(value): return value as NSString
            case let .number(value): return value
            }
        }
        // The source interpolates plain numbers; do not add locale grouping.
        return String(format: format, arguments: values)
    }

    public func arrayLength(_ key: String, locale: String) throws -> Int {
        guard locales.contains(locale) else { throw CopyError.unsupportedLocale(locale) }
        guard let length = contract.arrayLengths[locale]?[key] else { throw CopyError.missingKey(key) }
        return length
    }
}
