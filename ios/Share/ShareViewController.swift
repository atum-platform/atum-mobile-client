import SwiftUI
import UIKit
import AtumNativeAPI

final class ShareViewController: UIViewController {
    private var model: ShareComposerModel?
    private var loading: Task<Void, Never>?
    override func viewDidLoad() {
        super.viewDidLoad()
        do {
            let model = ShareComposerModel(queue: try ShareQueue()); self.model = model
            let host = UIHostingController(rootView: SharePlaceholderView(model: model, finish: { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil)
            }, cancel: { [weak self] in
                self?.loading?.cancel(); model.cancel()
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            }))
            addChild(host); view.addSubview(host.view)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([host.view.topAnchor.constraint(equalTo: view.topAnchor),
                                         host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                                         host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                                         host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)])
            host.didMove(toParent: self)
            let providers = ShareItemLoader.providers(from: extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            let intent = extensionContext?.intent
            loading = Task { await model.load(providers: providers, intent: intent) }
        } catch {
            let label = UILabel(); label.text = SharePendingCopy.text(.failed); label.numberOfLines = 0
            label.frame = view.bounds; label.autoresizingMask = [.flexibleWidth, .flexibleHeight]; view.addSubview(label)
        }
    }
}

/// Intentionally plain. The picker worker owns visual design; model semantics stay here.
private struct SharePlaceholderView: View {
    @Bindable var model: ShareComposerModel
    let finish: () -> Void
    let cancel: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                if model.phase == .queued {
                    Text(SharePendingCopy.text(.queued))
                    Button(SharePendingCopy.text(.done), action: finish)
                } else {
                    Text(SharePendingCopy.text(.queueHelp))
                    TextField(SharePendingCopy.text(.search), text: $model.search)
                    ForEach(model.chats) { chat in
                        Button { model.toggle(chat) } label: {
                            HStack { Text(chat.name); Spacer(); if model.selection.contains(chat.id) { Image(systemName: "checkmark") } }
                        }
                    }
                    if model.recentChats.isEmpty { Text(SharePendingCopy.text(.empty)) }
                    TextField(SharePendingCopy.text(.caption), text: $model.caption, axis: .vertical)
                    if model.phase == .loading { ProgressView(SharePendingCopy.text(.loading), value: model.progress) }
                    if let error = model.error { Text(error) }
                    Button(SharePendingCopy.text(.send)) { model.send() }.disabled(!model.canSend)
                }
            }
            .navigationTitle(SharePendingCopy.text(.title))
            .toolbar { if model.phase != .queued { Button(SharePendingCopy.text(.cancel), action: cancel) } }
        }
    }
}
