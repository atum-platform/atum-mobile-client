import Foundation

/// The one gate for every link tap in a chat (plan B17, §4.2 item 6): links
/// in answers, notices and message text, and (from S5) bot buttons. The view
/// asks it before opening anything, and opens allowed links inside the app
/// in `SFSafariViewController` (§4.5), never in the Safari app.
///
/// Purchases are held back on iOS until the server-validated StoreKit path
/// exists (AGENTS.md; plan §0.2: "No PayOS or VietQR until StoreKit is
/// validated"): PayOS and VietQR pages and an app's purchase route never
/// open. The chat shows the held-link line instead (exported copy,
/// `src.matrix.mobile-copy.mobileChatCopy.linkHeld`).
public enum LinkPolicy {
    /// What a tap on a link does.
    public enum Decision: Equatable, Hashable, Sendable {
        /// An ordinary web page: open it in the app.
        case openInApp(URL)
        /// A purchase page or route: never opened on iOS; the held-link line
        /// shows instead.
        case hold
        /// Not a web link (another scheme, no host, unparsable): nothing
        /// happens. Markdown parsing already drops such links
        /// (`MessageMarkup.canOpen`); this is the last line of defence.
        case refuse
    }

    /// Hosts that take payments, matched with their subdomains. PayOS: the
    /// plan's list (§4.2 item 6), the hosts atum-app and atum-platform send
    /// (`pay.payos.vn`, `payos.vn`). VietQR: held until the Moon lane
    /// confirms the hosts (§4.2 item 6 leaves them to it; coordinator
    /// decision 12 records the gap as "held until confirmed"), because §0.2
    /// forbids VietQR on iOS and the plan's list is explicitly incomplete:
    /// holding a page that takes no payment costs nothing, opening one that
    /// does (an `img.vietqr.io` payment QR in a bot's reply) would break the
    /// purchase rule.
    public static let purchaseHosts: Set<String> = ["payos.vn", "vietqr.io", "vietqr.net"]

    /// The decision for a tapped URL, from any link source.
    public static func decision(for url: URL) -> Decision {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = normalizedHost(of: url), !host.isEmpty else { return .refuse }
        return isPurchaseHost(host) ? .hold : .openInApp(url)
    }

    /// The decision for a URL as text (a bot button's target, S5).
    public static func decision(for text: String) -> Decision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return .refuse }
        return decision(for: url)
    }

    /// An app route a bot button opens (S5, `open_app_route`): the app's
    /// purchase route (`purchase_route_id` in the catalog) is held, whatever
    /// URL it would resolve to.
    public static func holdsAppRoute(_ routeID: String, purchaseRouteID: String?) -> Bool {
        guard let purchaseRouteID, !purchaseRouteID.isEmpty else { return false }
        return routeID == purchaseRouteID
    }

    /// Whether `host` (already lowercased, without a trailing dot) is a
    /// purchase host or one of its subdomains.
    public static func isPurchaseHost(_ host: String) -> Bool {
        purchaseHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The host as a browser would resolve it: percent-decoded, lowercased,
    /// with a trailing dot and IPv6 brackets removed. `URLComponents` keeps
    /// user info apart, so `https://payos.vn@example.com` is example.com and
    /// `https://example.com@pay.payos.vn` is pay.payos.vn.
    static func normalizedHost(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              var host = components.percentEncodedHost else { return nil }
        host = host.removingPercentEncoding ?? host
        host = host.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host
    }
}
