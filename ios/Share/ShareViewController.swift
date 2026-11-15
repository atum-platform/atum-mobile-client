import SwiftUI
import UIKit
import AtumNativeAPI

final class ShareViewController: UIViewController {
    private var model: ShareComposerModel?
    private var loading: Task<Void, Never>?
    override func viewDidLoad() {
        super.viewDidLoad()
        // Swipe-down would skip `cancel` and leave staged copies (and a typed caption)
        // behind; Cancel and Done are the two ways out.
        isModalInPresentation = true
        let cancel: () -> Void = { [weak self] in
            self?.loading?.cancel(); self?.model?.cancel()
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        guard let kit = SharePickerDesign.kit(), let queue = try? ShareQueue() else {
            host(SharePickerUnavailable(cancel: cancel)); return
        }
        let model = ShareComposerModel(queue: queue); self.model = model
        host(SharePickerView(model: model, avatars: .appGroup, finish: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }, cancel: cancel).environment(\.atumKit, kit))
        let providers = ShareItemLoader.providers(from: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
        let intent = extensionContext?.intent
        loading = Task { await model.load(providers: providers, intent: intent) }
    }

    private func host(_ root: some View) {
        let host = UIHostingController(rootView: root)
        addChild(host); view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.view.topAnchor.constraint(equalTo: view.topAnchor),
                                     host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                     host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                                     host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
        host.didMove(toParent: self)
    }
}
