import Foundation

public struct LinkPreview: Equatable, Sendable {
    public let url: URL
    public let host: String
    public let siteName: String?
    public let title: String?
    public let description: String?
    public let image: Data?

    public static let maximumImageBytes = 4_000_000

    /// Parsed Open Graph metadata returned by the homeserver. A remote image
    /// URL can never be handed back to the view.
    public struct Metadata: Equatable, Sendable {
        public let imageURI: String?
        private let siteName: String?
        private let title: String?
        private let description: String?

        public init?(json: String) {
            guard json.utf8.count <= 65_536,
                  let values = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            else { return nil }
            if let uri = values["og:image"] as? String, ForwardContent.isMediaURI(uri) {
                imageURI = uri
            } else {
                imageURI = nil
            }
            siteName = Self.text(values["og:site_name"], limit: 100)
            title = Self.text(values["og:title"], limit: 300)
            description = Self.text(values["og:description"], limit: 600)
        }

        public func card(url: URL, image: Data?) -> LinkPreview? {
            let picture = image.flatMap { (1...LinkPreview.maximumImageBytes).contains($0.count) ? $0 : nil }
            guard let host = LinkPolicy.normalizedHost(of: url), title != nil || picture != nil else { return nil }
            let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return LinkPreview(url: url, host: name, siteName: siteName?.lowercased() == name ? nil : siteName,
                               title: title, description: description == title ? nil : description, image: picture)
        }

        private static func text(_ value: Any?, limit: Int) -> String? {
            guard let text = value as? String else { return nil }
            let clean = text.replacingOccurrences(
                of: #"[\p{Cc}\u200B-\u200F\u202A-\u202E\u2066-\u2069]"#, with: " ", options: .regularExpression
            ).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !clean.isEmpty else { return nil }
            return clean.count <= limit ? clean : String(clean.prefix(limit - 1)) + "…"
        }
    }
}

extension LinkPolicy {
    /// First link eligible to leave the device as an authenticated homeserver
    /// preview. File links, invite bearer URLs and first-party routes stay local.
    public static func firstPreviewURL(in body: String) -> URL? {
        guard body.utf8.count <= 65_536 else { return nil }
        let text = body.replacingOccurrences(of: #"!\[[^\]\n]*\]\([^\n]*?\)"#, with: " ", options: .regularExpression)
        for link in SharedCollectionsPolicy.links(in: text) {
            guard var components = URLComponents(string: link), let url = components.url,
                  case .openInApp = decision(for: url),
                  components.user == nil, components.password == nil,
                  let host = normalizedHost(of: url), host.contains("."), host != "matrix.to",
                  components.path.split(separator: "/").first != "j"
            else { continue }
            if host == "atumplatform.com", let fragment = components.fragment,
               fragment.hasPrefix("atum-store/") || fragment.hasPrefix("atum-app/") { continue }
            components.fragment = nil
            return components.url
        }
        return nil
    }
}
