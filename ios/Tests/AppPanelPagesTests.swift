import Foundation
import XCTest
@testable import AtumNativeAPI

/// AS-11: an app chat's side panel pages (desktop `matrix/app-bots/panel.tsx`,
/// `shared/app-panel.ts`).
final class AppPanelPagesTests: XCTestCase {
    private let version = "00000000-0000-4000-8000-088a99dcb870"

    private func route(_ id: String, _ en: String, icon: String = "book",
                       placements: String = #"["menu"]"#, session: String = "required") -> String {
        #"{"id":"\#(id)","label":{"vi":"vi-\#(en)","en":"\#(en)"},"icon":"\#(icon)","path":"/\#(id)","placements":\#(placements),"session":"\#(session)"}"#
    }

    private func workspace(routes: [String], panel: String? = nil, launch: String = #"{"profile":"atum.app-launch/1","path":"/atum/launch"}"#,
                           version: String? = nil) throws -> AppWorkspaceSnapshot {
        let v = version ?? self.version
        let sibling = panel.map { #","app_panel":\#($0)"# } ?? ""
        let data = Data("""
        {"profile":"atum.app-workspace/1","descriptor":{"app":"moon","app_version_id":"\(v)"},
         "manifest":{"profile":"atum.remote-app-manifest/1","app":{"slug":"moon","app_version_id":"\(v)"},
          "launch":\(launch),"routes":[\(routes.joined(separator: ","))]},
         "web_origin":"https://moon.atumplatform.com","network_origins":[]\(sibling)}
        """.utf8)
        return try NativeAPI.decode(AppWorkspaceSnapshot.self, from: data)
    }

    private func app(link: String = "linked", mode: String = "external_account", availability: String = "available",
                     state: String = "active", consent: String = "accepted", transport: String? = nil) throws -> AppDescriptor {
        let device = state == "active"
            ? #"{"device_id":"MOON.1","ed25519":"\#(String(repeating: "A", count: 43))","curve25519":"\#(String(repeating: "B", count: 43))"}"#
            : "null"
        let transportField = transport.map { #","transport_mode":"\#($0)""# } ?? ""
        let data = Data("""
        {"profile":"\(AppCatalogResponse.profile)","apps":[{
         "app":"moon","app_id":"00000000-0000-4000-8000-00000000a001","app_version_id":"\(version)",
         "name":{"vi":"Moon","en":"Moon"},"subtitle":{"vi":"Lắng nghe","en":"Listens"},
         "description":{"vi":"Mô tả","en":"About Moon"},"icon":null,"accent":null,"affiliation":"first_party",
         "verified":true,"verification":"official","availability":"\(availability)","roster_default":true,
         "roster_order":0,"supported_modes":["direct"],"matrix_room_context":"addressed_only","has_surface":true,
         "link":{"mode":"\(mode)","state":"\(link)"},
         "bot":{"v":1,"user_id":"@app-moon:atumplatform.com","handle":"moon_bot","display_name":"Moon",
          "avatar":{"url":"https://moon.atumplatform.com/a.png","sha256":"\(String(repeating: "a", count: 64))"},
          "device_generation":1,"device":\(device),"state":"\(state)","groups":true,"consent":"\(consent)",
          "disclosure_version":3,"open_route_id":"chat","open_shared_memory":false,
          "purchase_route_id":"top-up"\(transportField)}}]}
        """.utf8)
        return try NativeAPI.decode(AppCatalogResponse.self, from: data).apps[0]
    }

    private var moonRoutes: [String] {
        [route("chat", "Chat", icon: "message"), route("library", "Library", icon: "books"),
         route("readings", "Readings", icon: "book-2"), route("match", "Match", icon: "hearts"),
         route("top-up", "Top up", icon: "coin", placements: #"["composer"]"#)]
    }

    func testWorkspaceKeepsRouteLabelsIconsAndTheDeclaredPanel() throws {
        let value = try workspace(routes: moonRoutes, panel: """
        {"profile":"atum.app-panel/1","default_page":"readings","pages":[
          {"route_id":"readings","glyph":"book-open-text","tag":{"vi":"Mới","en":"New"}},
          {"route_id":"library","glyph":"books"}]}
        """)
        XCTAssertEqual(value.routes.first { $0.id == "readings" }?.label.localized(locale: "vi"), "vi-Readings")
        XCTAssertEqual(value.routes.first { $0.id == "readings" }?.label.localized(locale: "ja"), "Readings")
        XCTAssertEqual(value.routes.first { $0.id == "library" }?.icon, "books")
        XCTAssertEqual(value.panel?.pages.map(\.routeID), ["readings", "library"])
        XCTAssertEqual(value.panel?.pages.map(\.glyph), ["book-open-text", "books"])
        XCTAssertEqual(value.panel?.defaultPage, "readings")
    }

    /// Desktop `decodeAppPanel`: an invalid declaration is dropped, never the manifest.
    func testInvalidPanelIsDroppedAndTheManifestStands() throws {
        for panel in [
            #"{"profile":"atum.app-panel/2","pages":[{"route_id":"library","glyph":"books"}]}"#,
            #"{"profile":"atum.app-panel/1","pages":[]}"#,
            #"{"profile":"atum.app-panel/1","pages":[{"route_id":"top-up","glyph":"coins"}]}"#,
            #"{"profile":"atum.app-panel/1","pages":[{"route_id":"nope","glyph":"coins"}]}"#,
            #"{"profile":"atum.app-panel/1","pages":[{"route_id":"library","glyph":"books"},{"route_id":"library","glyph":"books"}]}"#,
            #"{"profile":"atum.app-panel/1","default_page":"match","pages":[{"route_id":"library","glyph":"books"}]}"#,
            #"{"profile":"atum.app-panel/1","pages":[{"route_id":"library","glyph":"Books!"}]}"#,
            #"{"profile":"atum.app-panel/1","pages":[{"route_id":"library","glyph":"books","extra":1}]}"#,
            #"{"profile":"atum.app-panel/1","pages":[{"route_id":"library","glyph":"books","tag":{"vi":"quá dài để làm nhãn","en":"x"}}]}"#,
            #""not an object""#,
        ] {
            let value = try workspace(routes: moonRoutes, panel: panel)
            XCTAssertNil(value.panel, panel)
            XCTAssertEqual(value.routes.count, 5, panel)
        }
        XCTAssertNil(try workspace(routes: moonRoutes).panel)
    }

    func testPagesFollowTheDeclarationAndNeverRepeatTheChat() throws {
        let declared = try workspace(routes: moonRoutes, panel: """
        {"profile":"atum.app-panel/1","pages":[{"route_id":"match","glyph":"heart"},
          {"route_id":"chat","glyph":"chat-circle"},{"route_id":"readings","glyph":"book-open-text"}]}
        """)
        let pages = AppPanelPagesPolicy.pages(declared, app: try app())
        XCTAssertEqual(pages.map(\.id), ["match", "readings"])
        XCTAssertEqual(pages.map(\.glyph), ["heart", "book-open-text"])

        // Without a declaration: the menu routes, in manifest order, with their icons.
        let menu = AppPanelPagesPolicy.pages(try workspace(routes: moonRoutes), app: try app())
        XCTAssertEqual(menu.map(\.id), ["library", "readings", "match"])
        XCTAssertEqual(menu.map(\.glyph), ["books", "book-2", "hearts"])
    }

    /// The phone opens only what `atum.mobile-native-api/1.3` admits for launch,
    /// with the account's session; every other declared page is shown, closed.
    func testOnlyAdmittedLaunchRoutesOpen() throws {
        let value = try workspace(routes: moonRoutes)
        let pages = AppPanelPagesPolicy.pages(value, app: try app())
        XCTAssertEqual(pages.filter(\.opens).map(\.id), ["readings"])
        XCTAssertTrue(AppPanelPagesPolicy.pages(value, app: try app(consent: "required")).allSatisfy { !$0.opens })
        let noLaunch = try workspace(routes: moonRoutes.map { $0.replacingOccurrences(of: "required", with: "none") },
                                     launch: "null")
        XCTAssertTrue(AppPanelPagesPolicy.pages(noLaunch, app: try app()).allSatisfy { !$0.opens })
    }

    /// Desktop's order of checks: connect, unavailable, loading, empty, pages.
    func testStateFollowsDesktopOrder() throws {
        let moon = try app()
        let value = try workspace(routes: moonRoutes)
        XCTAssertEqual(AppPanelPagesPolicy.state(app: try app(link: "unlinked"), workspace: value, readFailed: false),
                       .connect)
        XCTAssertEqual(AppPanelPagesPolicy.state(app: try app(link: "never_linked", mode: "none"), workspace: nil,
                                                 readFailed: false), .loading)
        XCTAssertEqual(AppPanelPagesPolicy.state(app: try app(link: "unlinked", transport: "bot_api"),
                                                 workspace: nil, readFailed: false), .loading)
        XCTAssertEqual(AppPanelPagesPolicy.state(app: try app(state: "paused"), workspace: value, readFailed: false),
                       .unavailable(retry: false))
        XCTAssertEqual(AppPanelPagesPolicy.state(app: try app(availability: "unavailable"), workspace: value,
                                                 readFailed: false), .unavailable(retry: false))
        XCTAssertEqual(AppPanelPagesPolicy.state(app: moon, workspace: nil, readFailed: true),
                       .unavailable(retry: true))
        XCTAssertEqual(AppPanelPagesPolicy.state(app: moon, workspace: nil, readFailed: false), .loading)
        // A failed refresh keeps the pages already read.
        guard case let .pages(pages) = AppPanelPagesPolicy.state(app: moon, workspace: value, readFailed: true) else {
            return XCTFail("a failed refresh dropped the pages")
        }
        XCTAssertEqual(pages.map(\.id), ["library", "readings", "match"])
        XCTAssertEqual(AppPanelPagesPolicy.state(app: moon, workspace: try workspace(routes: [moonRoutes[0]]),
                                                 readFailed: false), .empty)
        // A manifest for another version of the app is a failed read.
        let other = try workspace(routes: moonRoutes, version: "00000000-0000-4000-8000-0000000000ff")
        XCTAssertEqual(AppPanelPagesPolicy.state(app: moon, workspace: other, readFailed: false),
                       .unavailable(retry: true))
    }
}
