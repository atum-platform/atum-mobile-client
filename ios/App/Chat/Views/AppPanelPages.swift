import AtumChat
import AtumDesign
import AtumNativeAPI
import SwiftUI
import UIKit

/// An app chat's side panel pages (AS-11): desktop `matrix/app-bots/panel.tsx`
/// `AppBotPanel`. Its home is the app's identity (the panel header) and then one
/// column of page capsules centred on the panel; a page pushes inside the panel
/// under Atum's bar. Where desktop shows the page in an embedded app view, the
/// phone opens the page's signed launch in Safari over the panel, and closing
/// Safari returns to the pages (desktop's Back at a page's root).
struct AppPanelActions {
    /// The panel's state from what the phone holds now; no read. The flag says
    /// the last read failed.
    let current: @MainActor (Bool) -> AppPanelPagesPolicy.State
    /// Reads the app's manifest again; false when the read failed.
    let refresh: @MainActor () async -> Bool
    /// One page's signed launch URL; nil when it could not be opened.
    let launch: @MainActor (String) async -> URL?
}

/// The panel's words. The app-copy keys are in the pinned export; desktop's
/// `panelCopy` table in `panel.tsx` is not (PENDING-COPY, `AppPanelPendingCopy`).
enum AppPanelCopy {
    static let connect = "src.matrix.app-copy.matrixAppCopy.connect"
    static let unavailable = "src.matrix.app-copy.matrixAppCopy.unavailable"
    static let retry = "src.matrix.app-copy.matrixAppCopy.retry"
    static let loading = "src.matrix.app-copy.matrixAppCopy.loading"
    // PENDING-COPY: src.matrix.app-bots.panel.panelCopy.openIn
    static let openIn = "src.matrix.app-bots.panel.panelCopy.openIn"
    // PENDING-COPY: src.matrix.app-bots.panel.panelCopy.noScreens
    static let noScreens = "src.matrix.app-bots.panel.panelCopy.noScreens"
    // PENDING-COPY: src.matrix.app-bots.panel.panelCopy.failed
    static let failed = "src.matrix.app-bots.panel.panelCopy.failed"

    /// The export first, so the next repin replaces a pending value with no
    /// wording change; then the desktop's own table.
    @MainActor
    static func text(_ design: LiveDesign, _ key: String, _ argument: String? = nil) -> String {
        if design.copy.contains(key) {
            let arguments: [AtumCopy.Argument] = argument.map { [AtumCopy.Argument.text($0)] } ?? []
            return design.text(key, arguments: arguments)
        }
        let table = AppPanelPendingCopy.tables[key]
        let value = table?[design.locale] ?? table?["en"] ?? key
        return argument.map { value.replacingOccurrences(of: "{0}", with: $0) } ?? value
    }
}

// Verbatim from atum-desktop 583ae946 `apps/desktop/src/matrix/app-bots/panel.tsx:41-92`
// (`panelCopy`). PENDING-COPY: none of these keys is in the pinned design export yet
// (listed in docs/ports/app-side-panel-pages.md). `{0}` is the app's name. Never hand-edit.
enum AppPanelPendingCopy {
    static let tables: [String: [String: String]] = [
        "src.matrix.app-bots.panel.panelCopy.openIn": [
            "en": "Open in {0}",
            "vi": "Mở trong {0}",
            "ja": "{0} で開く",
            "zh": "在 {0} 中打开",
            "zh-Hant": "在 {0} 中開啟",
        ],
        "src.matrix.app-bots.panel.panelCopy.noScreens": [
            "en": "This app has no screens yet.",
            "vi": "Ứng dụng này chưa có màn hình nào.",
            "ja": "このアプリにはまだ画面がありません。",
            "zh": "此应用还没有任何界面。",
            "zh-Hant": "此應用程式還沒有任何畫面。",
        ],
        "src.matrix.app-bots.panel.panelCopy.failed": [
            "en": "Couldn’t open this page.",
            "vi": "Không mở được trang này.",
            "ja": "このページを開けませんでした。",
            "zh": "无法打开此页面。",
            "zh-Hant": "無法開啟此頁面。",
        ],
    ]
}

/// A page's glyph: desktop `lib/atum-app-surface-icons.ts` maps a manifest or
/// declared name to a curated Phosphor name (legacy aliases first resolved).
/// The phone draws it when its asset catalog carries that Phosphor symbol,
/// otherwise the globe.
enum AppPanelGlyph {
    /// Desktop `APP_SURFACE_ALIASES`, verbatim.
    static let aliases: [String: String] = [
        "app": "app-window", "book": "book", "calendar": "calendar-blank", "camera": "image",
        "chat": "chat-circle", "checklist": "list-checks", "file": "file-text",
        "folder": "folder-simple", "home": "house", "library": "folder-simple",
        "profile": "user", "search": "magnifying-glass", "settings": "gear", "shop": "package",
        "sparkles": "sparkle", "starmap": "graph", "tool": "wrench", "wallet": "credit-card",
        "message": "chat-circle", "book-2": "book-open-text", "hearts": "heart",
        "clock-search": "clock", "coin": "coins", "report": "chart-line-up",
    ]

    /// The Phosphor names to try, best first: the name itself, then its alias.
    static func candidates(_ value: String) -> [String] {
        let name = value.lowercased()
        return [name] + (aliases[name].map { [$0] } ?? [])
    }

    @MainActor
    static func asset(_ value: String, design: LiveDesign) -> String {
        for name in candidates(value) where UIImage(named: "ph." + name) != nil {
            return "ph." + name
        }
        return design.symbol(AtumGlyph.globe.rawValue)
    }
}

/// The panel home's pages: one column of capsules, centred, at most 288 pt wide
/// (desktop `.app-panel-page-list`, `min(100%, 18rem)`).
struct AppPanelPagesSection: View {
    let design: LiveDesign
    let appName: String
    let actions: AppPanelActions
    let open: (ChatPanelPolicy.Page) -> Void
    /// The connect card lives in the chat: Connect closes the panel.
    let backToChat: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var readFailed = false
    @State private var attempt = 0
    /// Bumped after each read so the state is computed again.
    @State private var revision = 0

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        let _ = revision
        let state = actions.current(readFailed)
        VStack(spacing: 8) {
            content(state)
        }
        .frame(maxWidth: 288)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppPanelCopy.text(design, AppPanelCopy.openIn, appName))
        .accessibilityIdentifier("info.app.pages")
        .task(id: attempt) {
            let read = await actions.refresh()
            guard !Task.isCancelled else { return }
            readFailed = !read
            revision &+= 1
        }
    }

    @ViewBuilder private func content(_ state: AppPanelPagesPolicy.State) -> some View {
        switch state {
        case .connect:
            Button(action: backToChat) {
                Text(design.text(AppPanelCopy.connect)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.atumPrimary)
            .accessibilityIdentifier("info.app.connect")
        case let .unavailable(retry):
            if retry {
                AtumNotice(glyph: .info, title: design.text(AppPanelCopy.unavailable)) {
                    Button(design.text(AppPanelCopy.retry)) {
                        readFailed = false
                        attempt &+= 1
                    }
                    .buttonStyle(.atumPlain)
                    .accessibilityIdentifier("info.app.retry")
                }
                // Its own container: the section's `info.app.pages` id would
                // otherwise replace this one on the notice's text.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("info.app.unavailable")
            } else {
                AtumNotice(glyph: .info, title: design.text(AppPanelCopy.unavailable))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("info.app.unavailable")
            }
        case .loading:
            VStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { _ in
                    Capsule()
                        .fill(atum.kitColor(.fillQuiet, scheme: scheme))
                        .frame(height: 44)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(design.text(AppPanelCopy.loading))
            .accessibilityIdentifier("info.app.loading")
        case .empty:
            Text(AppPanelCopy.text(design, AppPanelCopy.noScreens))
                .font(.callout)
                .foregroundStyle(atum.kitColor(.ink3, scheme: scheme))
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("info.app.empty")
        case let .pages(pages):
            ForEach(pages) { page in
                pageButton(page)
            }
        }
    }

    /// A Kit capsule: the glyph at the start and the name centred, so names of
    /// any length read as one centred stack (desktop `.app-panel-page`).
    private func pageButton(_ page: AppPanelPagesPolicy.Page) -> some View {
        Button {
            open(.appPage(routeID: page.id))
        } label: {
            HStack(spacing: 8) {
                Image(AppPanelGlyph.asset(page.glyph, design: design))
                    .foregroundStyle(atum.kitColor(.ink2, scheme: scheme))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(verbatim: page.label.localized(locale: design.locale))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                Color.clear.frame(width: 20, height: 1)
            }
        }
        .buttonStyle(.atumSecondary)
        .disabled(!page.opens)
        .accessibilityIdentifier("info.app.page." + page.id)
    }
}

/// One app page, pushed inside the panel: Atum's bar names the page, and the
/// page itself opens in Safari over the panel. Closing Safari returns to the
/// app's pages; a page that could not be opened says so and offers Retry.
struct AppPanelPageView: View {
    let design: LiveDesign
    let actions: AppPanelActions
    let routeID: String
    let close: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var failed = false
    @State private var attempt = 0
    /// The attempt whose launch already ran: Safari covering the panel and
    /// uncovering it again must not ask for a second signed launch.
    @State private var launchedAttempt: Int?
    @State private var presented: AppContentPage?

    private var title: String {
        guard case let .pages(pages) = actions.current(false),
              let page = pages.first(where: { $0.id == routeID }) else { return "" }
        return page.label.localized(locale: design.locale)
    }

    var body: some View {
        Group {
            if failed {
                AtumNotice(glyph: .alertCircle, title: AppPanelCopy.text(design, AppPanelCopy.failed)) {
                    Button(design.text(AppPanelCopy.retry)) {
                        failed = false
                        attempt &+= 1
                    }
                    .buttonStyle(.atumPlain)
                    .accessibilityIdentifier("info.app.page.retry")
                }
                .padding(.horizontal, 16)
                .accessibilityIdentifier("info.app.page.failed")
            } else {
                ProgressView()
                    .accessibilityLabel(design.text(AppPanelCopy.loading))
                    .accessibilityIdentifier("info.app.page.opening")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AtumVisualSystem(design: design).color(.ground, scheme: scheme).opacity(0.001))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ChatPanelCloseButton(design: design, close: close)
            }
        }
        .task(id: attempt) {
            guard launchedAttempt != attempt else { return }
            launchedAttempt = attempt
            let url = await actions.launch(routeID)
            guard !Task.isCancelled else { return }
            if let url {
                presented = AppContentPage(url: url)
            } else {
                failed = true
            }
        }
        .fullScreenCover(item: $presented, onDismiss: { dismiss() }) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
    }
}
