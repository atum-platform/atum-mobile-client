#if DEBUG
import AtumChat
import AtumNativeAPI
import Foundation

/// Debug only: `-AtumScriptedAppPanel <pages|empty|failed|connect>` gives a
/// scripted app chat's side panel (AS-11) a synthetic Moon catalog entry and
/// manifest, decoded by the real wire types and run through the real
/// `AppPanelPagesPolicy`. The route names and glyphs are desktop's playground
/// fixture (`matrix/playground/app-look-fixtures.ts`). A page's launch is
/// recorded for the UI probe and answers "could not open": no network, no
/// Safari.
@MainActor
enum ScriptedAppPanel {
    enum Mode: String {
        case pages, empty, failed, connect
    }

    static func mode(arguments: [String] = ProcessInfo.processInfo.arguments) -> Mode? {
        guard let index = arguments.firstIndex(of: AtumLaunchArguments.scriptedAppPanelFlag) else { return nil }
        guard index + 1 < arguments.count else { return .pages }
        return Mode(rawValue: arguments[index + 1]) ?? .pages
    }

    static func actions(isAppChat: Bool,
                        arguments: [String] = ProcessInfo.processInfo.arguments) -> AppPanelActions? {
        guard isAppChat, let mode = mode(arguments: arguments) else { return nil }
        let app = descriptor(linked: mode != .connect)
        let manifest: AppWorkspaceSnapshot? = switch mode {
        case .pages, .connect: Self.workspace(pages: true)
        case .empty: Self.workspace(pages: false)
        case .failed: nil
        }
        return AppPanelActions(
            current: { failed in
                AppPanelPagesPolicy.state(app: app, workspace: manifest, readFailed: failed)
            },
            refresh: {
                UITestProbe.append("refresh", to: "app-panel.txt")
                return manifest != nil
            },
            launch: { routeID in
                UITestProbe.append("launch \(routeID)", to: "app-panel.txt")
                try? await Task.sleep(for: .milliseconds(400))
                return nil
            }
        )
    }

    private static func descriptor(linked: Bool) -> AppDescriptor {
        let icon: [String: Any] = ["url": "https://scripted.atum.test/moon.png",
                                   "sha256": String(repeating: "a", count: 64)]
        let entry: [String: Any] = [
            "app": "moon",
            "app_id": ScriptedCast.moonAppID,
            "app_version_id": version,
            "name": ["vi": "Moon", "en": "Moon"],
            "subtitle": ["vi": "Lắng nghe và cùng bạn nhìn lại hôm nay.",
                         "en": "Listens, and looks back on today with you."],
            "description": NSNull(),
            "icon": icon,
            "accent": "#2c8078",
            "affiliation": "first_party",
            "verified": true,
            "verification": "official",
            "availability": "available",
            "roster_default": true,
            "roster_order": 0,
            "supported_modes": ["direct"],
            "matrix_room_context": "addressed_only",
            "has_surface": true,
            "link": ["mode": "external_account", "state": linked ? "linked" : "unlinked"],
            "bot": [
                "v": 1,
                "user_id": "@app-moon:atumplatform.com",
                "handle": "moon_bot",
                "display_name": "Moon",
                "avatar": icon,
                "device_generation": 1,
                "device": ["device_id": "MOON.1",
                           "ed25519": String(repeating: "A", count: 43),
                           "curve25519": String(repeating: "B", count: 43)],
                "state": "active",
                "groups": true,
                "consent": "accepted",
                "disclosure_version": 3,
                "open_route_id": "chat",
                "open_shared_memory": false,
                "purchase_route_id": "top-up",
            ] as [String: Any],
        ]
        return decode(AppCatalogResponse.self, ["profile": AppCatalogResponse.profile, "apps": [entry]]).apps[0]
    }

    private static let version = "00000000-0000-4000-8000-00000000b0a1"

    private static func workspace(pages: Bool) -> AppWorkspaceSnapshot {
        func route(_ id: String, _ en: String, _ vi: String, _ icon: String) -> [String: Any] {
            ["id": id, "label": ["vi": vi, "en": en], "icon": icon, "path": "/" + id,
             "placements": ["menu"], "session": "required"]
        }
        let routes = [route("chat", "Chat", "Trò chuyện", "message")] + (pages ? [
            route("library", "Library", "Thư viện", "books"),
            route("readings", "Readings", "Luận Giải", "book-2"),
            route("match", "Match", "Nhân Duyên", "hearts"),
            route("tarot", "Tarot", "Tarot", "cards"),
        ] : [])
        var object: [String: Any] = [
            "profile": "atum.app-workspace/1",
            "descriptor": ["app": "moon", "app_version_id": version],
            "manifest": [
                "profile": "atum.remote-app-manifest/1",
                "app": ["slug": "moon", "app_version_id": version],
                "launch": ["profile": "atum.app-launch/1", "path": "/atum/launch"],
                "routes": routes,
            ] as [String: Any],
            "web_origin": "https://moon.atumplatform.com",
            "network_origins": [Any](),
        ]
        if pages {
            object["app_panel"] = [
                "profile": AppPanelContract.profile,
                "pages": [
                    ["route_id": "readings", "glyph": "book-open-text"],
                    ["route_id": "library", "glyph": "books"],
                    ["route_id": "match", "glyph": "heart"],
                    ["route_id": "tarot", "glyph": "cards"],
                ],
            ] as [String: Any]
        }
        return decode(AppWorkspaceSnapshot.self, object)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ object: Any) -> T {
        do {
            return try NativeAPI.decode(type, from: JSONSerialization.data(withJSONObject: object))
        } catch {
            preconditionFailure("scripted app panel: \(T.self) does not decode: \(error)")
        }
    }
}
#endif
