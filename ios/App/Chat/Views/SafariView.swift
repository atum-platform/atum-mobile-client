import AtumChat
import Observation
import SafariServices
import SwiftUI

/// Every link tap in a chat lands here (B17, §4.2 item 6, §4.5): `LinkPolicy`
/// decides; allowed pages open in `SFSafariViewController` inside the app;
/// purchase pages show the held-link line ("Liên kết này chưa mở được trên
/// iPhone.", exported copy) instead; anything else does nothing.
@MainActor
@Observable
final class ChatLinkRouter {
    struct Page: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    var presented: Page?
    var showsHeld = false

    @ObservationIgnored private weak var routedStore: LiveConversationStore?
    @ObservationIgnored private var routedActions = ChatActions.none

    /// The row actions with link taps routed here, made once per store: a new
    /// value on every render would re-render every row that reads it from the
    /// environment. `base` is the store's actions as the screen wraps them
    /// (the reaction tick, `ChatHaptics.actions(of:)`, itself made once per
    /// store); it is used only when the store changes.
    func actions(for store: LiveConversationStore, base: ChatActions) -> ChatActions {
        if routedStore !== store {
            var actions = base
            actions.openLink = { [weak self] url in self?.open(url) }
            routedStore = store
            routedActions = actions
        }
        return routedActions
    }

    func open(_ text: String) {
        switch LinkPolicy.decision(for: text) {
        case let .openInApp(url): presented = Page(url: url)
        case .hold: showsHeld = true
        case .refuse: break
        }
    }
}

/// `SFSafariViewController` for SwiftUI: content links and app routes stay in
/// the app, never in a web view Atum controls and never in the Safari app.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
