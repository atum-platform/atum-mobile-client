import AtumNativeAPI
import XCTest
@testable import AtumMobile

/// AS-11: the official app card (desktop `assistant-card/app-card.tsx`), the
/// app row's "Info" (`roster-context-menu.tsx` `RosterAppMenu`) and the panel
/// pages' glyphs and words (`app-bots/panel.tsx`).
@MainActor
final class AppSidePanelStateTests: XCTestCase {
    private func descriptor(description: [String: String]? = ["vi": "Mô tả Moon", "en": "About Moon"],
                            subtitle: [String: String]? = ["vi": "Lắng nghe", "en": "Listens"],
                            verified: Bool = true, availability: String = "available") throws -> AppDescriptor {
        let icon: [String: Any] = ["url": "https://cdn.atumplatform.com/apps/moon.png",
                                   "sha256": String(repeating: "a", count: 64)]
        let app: [String: Any] = [
            "app": "moon", "app_id": "00000000-0000-4000-8000-00000000a001",
            "app_version_id": "00000000-0000-4000-8000-f1d11edf5c5c",
            "name": ["vi": "Moon", "en": "Moon"],
            "subtitle": subtitle.map { $0 as Any } ?? NSNull(),
            "description": description.map { $0 as Any } ?? NSNull(),
            "icon": icon, "accent": NSNull(), "affiliation": "first_party",
            "verified": verified, "verification": "official", "availability": availability,
            "roster_default": true, "roster_order": 0, "supported_modes": ["direct"], "has_surface": true,
            "link": ["mode": "external_account", "state": "linked"],
        ]
        let body = try JSONSerialization.data(withJSONObject: ["profile": "atum.app-catalog/1", "apps": [app]])
        return try NativeAPI.decode(AppCatalogResponse.self, from: body).apps[0]
    }

    func testCardShowsDescriptionElseSubtitleAndOpensOnlyWhenAvailable() throws {
        let card = AppCardPresentation(app: try descriptor(), rowID: "!moon", locale: "vi")
        XCTAssertEqual(card.name, "Moon")
        XCTAssertEqual(card.about, "Mô tả Moon")
        XCTAssertTrue(card.isVerified)
        XCTAssertTrue(card.isAvailable)
        XCTAssertEqual(card.verification, .official)
        XCTAssertEqual(card.rowID, "!moon")

        XCTAssertEqual(AppCardPresentation(app: try descriptor(description: nil), rowID: "!moon",
                                           locale: "en").about, "Listens")
        XCTAssertEqual(AppCardPresentation(app: try descriptor(description: ["vi": " ", "en": " "]),
                                           rowID: "!moon", locale: "en").about, "Listens")
        XCTAssertNil(AppCardPresentation(app: try descriptor(description: nil, subtitle: nil),
                                         rowID: "!moon", locale: "en").about)
        let closed = AppCardPresentation(app: try descriptor(verified: false, availability: "unavailable"),
                                         rowID: "app:00000000-0000-4000-8000-00000000a001", locale: "en")
        XCTAssertFalse(closed.isAvailable)
        XCTAssertFalse(closed.isVerified)
    }

    func testInfoIsOfferedOnAppRowsButNotOnPlaceholders() {
        let chat = HomeRow(id: "!moon", kind: .app, name: "Moon")
        XCTAssertTrue(HomeRowActionPolicy.offersAppInfo(row: chat, hasAction: true))
        XCTAssertFalse(HomeRowActionPolicy.offersAppInfo(row: chat, hasAction: false))
        let notStarted = HomeRow(id: "app:00000000-0000-4000-8000-00000000a001", kind: .app, name: "Moon",
                                 awaitsStart: true)
        XCTAssertTrue(HomeRowActionPolicy.offersAppInfo(row: notStarted, hasAction: true))
        let comingSoon = HomeRow(id: "app:00000000-0000-4000-8000-00000000a002", kind: .app, name: "Andy",
                                 isComingSoon: true)
        XCTAssertFalse(HomeRowActionPolicy.offersAppInfo(row: comingSoon, hasAction: true))
        for kind in [HomeRow.Kind.person, .group, .assistant, .atum, .invitation] {
            XCTAssertFalse(HomeRowActionPolicy.offersAppInfo(row: HomeRow(id: "!x", kind: kind, name: "X"),
                                                             hasAction: true), "\(kind)")
        }
    }

    /// Desktop `appSurfaceGlyph`: the curated name itself first, then its legacy alias.
    func testPageGlyphTriesTheNameThenDesktopsAlias() {
        XCTAssertEqual(AppPanelGlyph.candidates("book-open-text"), ["book-open-text"])
        XCTAssertEqual(AppPanelGlyph.candidates("hearts"), ["hearts", "heart"])
        XCTAssertEqual(AppPanelGlyph.candidates("Message"), ["message", "chat-circle"])
        XCTAssertEqual(AppPanelGlyph.candidates("camera"), ["camera", "image"])
        XCTAssertEqual(AppPanelGlyph.aliases.count, 24)
    }

    /// Every exported key the card and the panel read is in the pinned design
    /// export; every pending key is not (yet), and its desktop table covers the
    /// export's five locales.
    func testCopyKeysAreExportedOrPending() throws {
        let design = try LiveDesign()
        for key in [AppCardCopy.done, AppCardCopy.appCaption, AppCardCopy.openApp, AppCardCopy.verified,
                    AppCardCopy.menuInfo, AppPanelCopy.connect,
                    AppPanelCopy.unavailable, AppPanelCopy.retry, AppPanelCopy.loading] {
            XCTAssertTrue(design.copy.contains(key), key)
        }
        for key in [AppPanelCopy.openIn, AppPanelCopy.noScreens, AppPanelCopy.failed] {
            XCTAssertFalse(design.copy.contains(key), "\(key) is exported now: drop its pending table")
            XCTAssertEqual(Set(AppPanelPendingCopy.tables[key]?.keys.map { $0 } ?? []),
                           ["en", "vi", "ja", "zh", "zh-Hant"], key)
        }
        XCTAssertEqual(AppPanelPendingCopy.tables["src.matrix.app-bots.panel.panelCopy.openIn"]?["en"],
                       "Open in {0}")
    }
}
