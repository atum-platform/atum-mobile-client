import QuickLook
import SwiftUI
import UIKit
import AtumNativeAPI
import AtumDrive

struct DriveBreadcrumb: Hashable {
    let itemID: String
    let name: String
}

struct DriveFolderRoute: Hashable {
    let driveID: String
    let path: [DriveBreadcrumb]

    var current: DriveBreadcrumb { path.last! }
}

struct DriveScreen: View {
    let design: LiveDesign
    @Bindable var router: Router
    @Bindable var model: DriveFeatureModel

    var body: some View {
        DriveDirectoryView(design: design, router: router, model: model, route: nil)
            .navigationDestination(for: DriveFolderRoute.self) { route in
                DriveDirectoryView(design: design, router: router, model: model, route: route)
            }
            .sheet(item: $model.preview, onDismiss: model.dismissPreview) { preview in
                Group {
                    switch preview.presentation {
                    case .quickLook:
                        VStack(spacing: 0) {
                            if preview.isStale {
                                Text(DriveCopy(design: design).stale)
                                    .font(.footnote)
                                    .frame(maxWidth: .infinity)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                            }
                            DriveQuickLook(url: preview.url, name: preview.name)
                    }
                    case .export:
                        DriveActivityView(url: preview.url)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
            }
            .alert(
                DriveCopy(design: design).failed,
                isPresented: Binding(
                    get: { model.notice != nil },
                    set: { if !$0 { model.notice = nil } }
                ),
                presenting: model.notice
            ) { _ in
                Button(DriveCopy(design: design).dismiss, role: .cancel) { model.notice = nil }
            } message: { notice in
                Text(DriveCopy(design: design).notice(notice))
            }
    }
}

private struct DriveDirectoryView: View {
    let design: LiveDesign
    @Bindable var router: Router
    @Bindable var model: DriveFeatureModel
    let route: DriveFolderRoute?

    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    private var copy: DriveCopy { DriveCopy(design: design) }
    private var parentID: String { route?.current.itemID ?? DrivePage.rootParentID }
    private var presentation: DriveDirectoryPresentation { model.directory(parentID: parentID) }

    var body: some View {
        Group {
            if presentation.items.isEmpty {
                emptyState
            } else {
                List {
                    statusSection
                    if route != nil { breadcrumbSection }
                    ForEach(presentation.items) { item in row(item) }
                }
                .listStyle(.plain)
            }
        }
        .background(atum?.color(.ground, scheme: scheme).ignoresSafeArea())
        // FlowPhone2 › Drive: a large title at the root; a folder keeps its
        // name inline with native back.
        .navigationTitle(Text(verbatim: route?.current.name ?? copy.title))
        .navigationBarTitleDisplayMode(route == nil ? .large : .inline)
        .refreshable { await refresh() }
        .task(id: parentID) {
            if route == nil { await model.start() }
            else {
                await model.load(parentID: parentID,
                                 driveID: route?.driveID ?? model.rootDriveID)
            }
        }
        .accessibilityIdentifier("drive.directory." + parentID)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 14) {
            switch DrivePresentationPolicy.emptyState(
                connection: model.connection,
                directory: presentation.condition
            ) {
            case .loading:
                AtomWait().frame(width: 28, height: 28)
                    .accessibilityLabel(copy.refreshing)
                Text(copy.refreshing)
            case .connect:
                Image(atum?.symbol(.folder) ?? "ph.folder-simple")
                    .font(.system(size: 42))
                Text(copy.connectTitle).font(.headline)
                Text(copy.connectBody).font(.subheadline).multilineTextAlignment(.center)
                Button(copy.connect) { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .disabled(model.connection == .connecting)
            case .signInAgain:
                stateMessage(copy.signInProblem, action: copy.signInAgain)
            case .provisioning:
                AtomWait().frame(width: 28, height: 28)
                    .accessibilityLabel(copy.provisioning)
                Text(copy.provisioning).multilineTextAlignment(.center)
            case .denied:
                stateMessage(copy.denied, action: copy.retry)
            case .offline:
                stateMessage(copy.offline, action: copy.retry)
            case .unavailable:
                stateMessage(copy.unavailable, action: copy.retry)
            case .empty:
                Text(copy.empty).font(.headline)
            }
        }
        .foregroundStyle(atum?.color(.ink, scheme: scheme) ?? .primary)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func stateMessage(_ message: String, action: String) -> some View {
        Text(message).font(.subheadline).multilineTextAlignment(.center)
        Button(action) { Task { await refresh() } }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
    }

    @ViewBuilder private var statusSection: some View {
        if statusMessage != nil || presentation.isTruncated {
            Section {
                if let message = statusMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(atum?.symbol(.alertCircle) ?? "ph.warning-circle")
                        Text(message).font(.footnote)
                        Spacer(minLength: 8)
                        if model.connection == .disconnected
                            || model.connection == .reauthenticationRequired {
                            Button(model.connection == .reauthenticationRequired
                                   ? copy.signInAgain : copy.connect) {
                                Task { await model.connect() }
                            }
                            .font(.footnote.weight(.semibold))
                        }
                    }
                    .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
                }
                if presentation.isTruncated {
                    Text(copy.truncated)
                        .font(.footnote)
                        .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
                }
            }
        }
    }

    private var statusMessage: String? {
        switch DrivePresentationPolicy.connectionCopy(
            connection: model.connection,
            hasItems: !presentation.items.isEmpty,
            directory: presentation.condition
        ) {
        case .none: nil
        case .refreshing: copy.refreshing
        case .provisioning: copy.provisioning
        case .denied: copy.denied
        case .signInAgain: copy.signInProblem
        case .offline: copy.offline
        case .unavailable: copy.unavailable
        case .stale: copy.stale
        }
    }

    private var breadcrumbSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    Button(copy.title) { router.drivePath = NavigationPath() }
                    if let route {
                        ForEach(Array(route.path.enumerated()), id: \.offset) { index, crumb in
                            Image(atum?.symbol(.chevronRight) ?? "ph.caret-right")
                                .font(.caption2)
                                .foregroundStyle(atum?.color(.muted, scheme: scheme) ?? .secondary)
                            Button(crumb.name) { pop(to: index, route: route) }
                        }
                    }
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    @ViewBuilder private func row(_ item: DriveItem) -> some View {
        if item.kind == .folder, let driveID = route?.driveID ?? model.rootDriveID {
            NavigationLink(value: childRoute(item, driveID: driveID)) {
                DriveFileRow(design: design, copy: copy, model: model, item: item)
            }
        } else {
            HStack(spacing: 6) {
                Button { Task { await model.open(item) } } label: {
                    DriveFileRow(design: design, copy: copy, model: model, item: item)
                }
                .buttonStyle(.plain)
                .disabled(model.busyItemIDs.contains(item.id))
                if model.busyItemIDs.contains(item.id) {
                    Button { model.cancelTransfer(itemID: item.id) } label: {
                        Image(atum?.symbol(.close) ?? "ph.x")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copy.cancel)
                } else {
                    Menu {
                        Button {
                            Task { await model.toggleKeepOffline(item) }
                        } label: {
                            Label(
                                model.keptItemIDs.contains(item.id)
                                    ? copy.removeOffline : copy.keepOffline,
                                image: atum?.symbol(
                                    model.keptItemIDs.contains(item.id) ? .pinOff : .pin
                                ) ?? "ph.push-pin"
                            )
                        }
                    } label: {
                        (atum?.barIcon(.moreHorizontal) ?? Image("ph.dots-three"))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(copy.more)
                }
            }
            .contextMenu {
                Button {
                    Task { await model.toggleKeepOffline(item) }
                } label: {
                    Label(
                        model.keptItemIDs.contains(item.id) ? copy.removeOffline : copy.keepOffline,
                        image: atum?.symbol(
                            model.keptItemIDs.contains(item.id) ? .pinOff : .pin
                        ) ?? "pin"
                    )
                }
            }
        }
    }

    private func childRoute(_ item: DriveItem, driveID: String) -> DriveFolderRoute {
        DriveFolderRoute(
            driveID: driveID,
            path: (route?.path ?? []) + [DriveBreadcrumb(itemID: item.id, name: item.name)]
        )
    }

    private func pop(to index: Int, route: DriveFolderRoute) {
        let routes = route.path.indices.map { offset in
            DriveFolderRoute(driveID: route.driveID,
                             path: Array(route.path.prefix(offset + 1)))
        }
        router.drivePath = NavigationPath(Array(routes.prefix(index + 1)))
    }

    private func refresh() async {
        if model.connection == .ready {
            await model.load(parentID: parentID,
                             driveID: route?.driveID ?? model.rootDriveID)
        } else {
            await model.connect()
        }
    }
}

private struct DriveFileRow: View {
    let design: LiveDesign
    let copy: DriveCopy
    @Bindable var model: DriveFeatureModel
    let item: DriveItem

    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            Image(atum?.symbol(item.kind == .folder ? .folder : .fileText)
                  ?? (item.kind == .folder ? "folder" : "doc.text"))
                .font(.title3)
                .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.name)
                    .font(.body)
                    .foregroundStyle(atum?.color(.ink, scheme: scheme) ?? .primary)
                    .lineLimit(2)
                if item.kind == .file {
                    HStack(spacing: 6) {
                        Text(verbatim: ByteCountFormatter.string(
                            fromByteCount: item.size,
                            countStyle: .file
                        ))
                        if let modifiedAt = item.modifiedAt {
                            Text(verbatim: modifiedAt.formatted(date: .abbreviated, time: .omitted))
                        }
                        if model.keptItemIDs.contains(item.id) {
                            Label(copy.keptOffline,
                                  image: atum?.symbol(.pinFilled) ?? "ph.push-pin.fill")
                                .labelStyle(.iconOnly)
                                .accessibilityLabel(copy.keptOffline)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(atum?.color(.muted, scheme: scheme) ?? .secondary)
                }
            }
            Spacer(minLength: 8)
            if model.busyItemIDs.contains(item.id) {
                if let progress = model.transferProgress[item.id] {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .accessibilityLabel(Text(verbatim: item.name))
                        .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text(verbatim: item.name))
                }
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityIdentifier("drive.item." + item.id)
    }
}

private struct DriveQuickLook: UIViewControllerRepresentable {
    let url: URL
    let name: String

    func makeCoordinator() -> Coordinator { Coordinator(url: url, name: name) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let item: Item
        init(url: URL, name: String) { item = Item(url: url, name: name) }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> any QLPreviewItem { item }
    }

    final class Item: NSObject, QLPreviewItem {
        let url: URL
        let name: String
        init(url: URL, name: String) { self.url = url; self.name = name }
        var previewItemURL: URL? { url }
        var previewItemTitle: String? { name }
    }
}

private struct DriveActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
