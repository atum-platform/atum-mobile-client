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
            .sheet(item: $model.preview, onDismiss: {
                model.dismissPreview()
                DriveShareFile.clear()
            }) { preview in
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
                        DriveActivityView(url: preview.url, name: preview.name)
                    }
                }
                .ignoresSafeArea(edges: .bottom)
            }
            // Pictures and PDFs: desktop's gallery as a swipeable preview.
            .sheet(item: $model.gallery, onDismiss: model.dismissGallery) { gallery in
                DriveGalleryView(design: design, model: model, gallery: gallery)
                    .atumDesign(design)
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
    /// Desktop Drive's two places; Recents is where it opens.
    @State private var destination = DriveDestination.recents
    /// Desktop keeps Recents' order for the visit only (`sortChoice`).
    @State private var recentsSort = DriveSort.recent
    @State private var query = ""
    /// Desktop's view and Group By, kept on this iPhone under desktop's keys;
    /// the folder sort is kept too.
    @AppStorage(DriveLayout.storageKey) private var storedLayout = DriveLayout.icons.rawValue
    @AppStorage(DriveGroupBy.storageKey) private var storedGroupBy = DriveGroupBy.none.rawValue
    @AppStorage(DriveSort.storageKey) private var storedSort = DriveSort.name.storedValue

    private var copy: DriveCopy { DriveCopy(design: design) }
    private var locale: Locale { Locale(identifier: design.locale) }
    private var parentID: String { route?.current.itemID ?? DrivePage.rootParentID }
    private var presentation: DriveDirectoryPresentation { model.directory(parentID: parentID) }
    private var showsRecents: Bool { route == nil && destination == .recents }
    private var layout: DriveLayout { DriveLayout.parse(storedLayout) }
    private var groupBy: DriveGroupBy { DriveGroupBy.parse(storedGroupBy) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Recents opens newest first and All files by name; either can be
    /// re-sorted from the view menu.
    private var sort: DriveSort { showsRecents ? recentsSort : DriveSort.parse(storedSort) }

    /// The listing as desktop's Finder draws it: matched, sorted, then grouped.
    private var shownItems: [DriveItem] {
        DriveArrangement.sort(DriveArrangement.filter(presentation.items, query: query, locale: locale),
                              by: sort, locale: locale)
    }

    private func groups(_ items: [DriveItem]) -> [DriveGroup] {
        DriveArrangement.groups(items, by: groupBy, now: Date(), locale: locale,
                                label: { copy.groupLabel($0) })
    }

    var body: some View {
        Group {
            if presentation.items.isEmpty {
                emptyState
            } else {
                let items = shownItems
                switch layout {
                case .list: listBody(items)
                case .icons: gridBody(items)
                }
            }
        }
        .background(atum?.color(.ground, scheme: scheme).ignoresSafeArea())
        // FlowPhone2 › Drive: a large title at the root; a folder keeps its
        // name inline with native back.
        .navigationTitle(Text(verbatim: route?.current.name ?? copy.title))
        .navigationBarTitleDisplayMode(route == nil ? .large : .inline)
        .toolbar {
            if !presentation.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { viewMenu }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(copy.search))
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

    // MARK: List and Icons

    private func listBody(_ items: [DriveItem]) -> some View {
        List {
            if searching {
                Section { scopeLine }.listRowSeparator(.hidden)
            } else {
                if route == nil {
                    Section { destinationPicker }.listRowSeparator(.hidden)
                }
                statusSection
                if route != nil { Section { breadcrumbs } }
            }
            if items.isEmpty {
                Section { noMatches }.listRowSeparator(.hidden)
            }
            ForEach(groups(items)) { group in
                if group.label.isEmpty {
                    ForEach(group.items) { row($0) }
                } else {
                    Section {
                        ForEach(group.items) { row($0) }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("drive.list")
    }

    private func gridBody(_ items: [DriveItem]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if searching {
                    scopeLine
                } else {
                    if route == nil { destinationPicker }
                    statusLines
                    if route != nil { breadcrumbs }
                }
                if items.isEmpty { noMatches }
                ForEach(groups(items)) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        if !group.label.isEmpty {
                            groupHeader(group)
                            Rectangle()
                                .fill(atum?.kitColor(.line, scheme: scheme) ?? Color.secondary.opacity(0.2))
                                .frame(height: 0.5)
                                .accessibilityHidden(true)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140),
                                                     spacing: 8, alignment: .top)],
                                  alignment: .leading, spacing: 18) {
                            ForEach(group.items) { cell($0) }
                        }
                    }
                    .padding(.top, group.label.isEmpty ? 0 : 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("drive.grid")
    }

    private func groupHeader(_ group: DriveGroup) -> some View {
        Text(verbatim: group.label)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(atum?.color(.ink, scheme: scheme) ?? .primary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("drive.group." + group.id)
    }

    private var noMatches: some View {
        Text(copy.searchEmpty)
            .font(.subheadline)
            .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .accessibilityIdentifier("drive.search.empty")
    }

    /// Desktop's scope bar, honestly: the phone searches the listing it has
    /// for this folder, never the whole Drive, so there is one scope and no
    /// "This Drive" choice. Whole-Drive search waits on a platform route.
    private var scopeLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(copy.searchScopeTitle)
                    .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
                Text(verbatim: route?.current.name ?? copy.driveName)
                    .fontWeight(.semibold)
                    .foregroundStyle(atum?.color(.ink, scheme: scheme) ?? .primary)
            }
            .font(.footnote)
            Text(copy.searchFolderOnly)
                .font(.caption)
                .foregroundStyle(atum?.color(.muted, scheme: scheme) ?? .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("drive.search.scope")
    }

    /// Files-style view options behind one "…": the view, the sort (tap the
    /// chosen column again to flip it) and Group By.
    private var viewMenu: some View {
        Menu {
            Section(copy.viewMode) {
                Picker(copy.viewMode, selection: $storedLayout) {
                    Text(copy.gridView).tag(DriveLayout.icons.rawValue)
                    Text(copy.listView).tag(DriveLayout.list.rawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                ForEach(DriveSortKey.allCases, id: \.self) { key in
                    Button { setSort(sort.next(key)) } label: {
                        if sort.key == key {
                            Label(copy.sortLabel(key),
                                  image: design.symbol(sort.ascending ? "ArrowUp" : "ArrowDown"))
                        } else {
                            Text(copy.sortLabel(key))
                        }
                    }
                    .accessibilityIdentifier("drive.sort." + key.rawValue)
                    .accessibilityValue(sort.key == key ? Text(verbatim: sort.ascending ? "↑" : "↓") : Text(""))
                }
            }
            Section {
                Picker(selection: $storedGroupBy) {
                    ForEach(DriveGroupBy.allCases, id: \.self) { choice in
                        Text(copy.groupChoice(choice)).tag(choice.rawValue)
                    }
                } label: {
                    Text(copy.groupTitle)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("drive.group")
            }
        } label: {
            (atum?.barIcon(.moreHorizontal) ?? Image("ph.dots-three"))
                .accessibilityLabel(copy.viewMode)
        }
        .accessibilityIdentifier("drive.viewOptions")
    }

    private func setSort(_ next: DriveSort) {
        if showsRecents { recentsSort = next } else { storedSort = next.storedValue }
    }

    // MARK: Opening

    /// A picture or PDF opens the swipeable preview over the folder's others,
    /// in the order shown; anything else opens as before.
    private func open(_ item: DriveItem) {
        if DriveGalleryPolicy.kind(item) != nil {
            model.openGallery(shownItems, startingAt: item)
        } else {
            Task { await model.open(item) }
        }
    }

    @ViewBuilder private func itemActions(_ item: DriveItem) -> some View {
        Button { Task { await model.share(item) } } label: {
            Label(copy.share, image: design.symbol("Share"))
        }
        .accessibilityIdentifier("drive.share." + item.id)
        Button {
            Task { await model.toggleKeepOffline(item) }
        } label: {
            Label(
                model.keptItemIDs.contains(item.id) ? copy.removeOffline : copy.keepOffline,
                image: atum?.symbol(model.keptItemIDs.contains(item.id) ? .pinOff : .pin) ?? "ph.push-pin"
            )
        }
    }

    @ViewBuilder private func cell(_ item: DriveItem) -> some View {
        if item.kind == .folder, let driveID = route?.driveID ?? model.rootDriveID {
            NavigationLink(value: childRoute(item, driveID: driveID)) {
                DriveGridCell(design: design, copy: copy, model: model, item: item)
            }
            .buttonStyle(.plain)
        } else {
            Button { open(item) } label: {
                DriveGridCell(design: design, copy: copy, model: model, item: item)
            }
            .buttonStyle(.plain)
            .disabled(model.busyItemIDs.contains(item.id))
            .contextMenu {
                // The whole name, which the icon cuts in the middle.
                Section(item.name) { itemActions(item) }
            }
        }
    }

    // MARK: Header rows

    private var destinationPicker: some View {
        Picker(copy.title, selection: $destination) {
            Text(copy.recents).tag(DriveDestination.recents)
            Text(copy.allFiles).tag(DriveDestination.all)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("drive.destination")
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
                if route == nil {
                    // The Drive itself, still empty: what it is for.
                    Image(design.symbol("Folder"))
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(atum?.color(.muted, scheme: scheme) ?? .secondary)
                        .accessibilityHidden(true)
                    Text(copy.emptyRootTitle).font(.headline)
                    Text(copy.emptyRootBody)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
                } else {
                    Text(copy.empty).font(.headline)
                }
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
        if hasStatusLines {
            Section { statusLines }.listRowSeparator(.hidden)
        }
    }

    private var hasStatusLines: Bool {
        if statusMessage != nil || presentation.isTruncated { return true }
        if case .upToDate = DriveStatusLine.decide(connection: model.connection,
                                                   directory: presentation) { return true }
        return false
    }

    @ViewBuilder private var statusLines: some View {
        if statusMessage == nil,
           case let .upToDate(at) = DriveStatusLine.decide(connection: model.connection,
                                                            directory: presentation) {
            Label {
                Text(copy.upToDate(at: at)).font(.footnote)
            } icon: {
                Image(design.symbol("CheckCircle2")).font(.footnote)
            }
            .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
            .accessibilityIdentifier("drive.status")
        } else if let message = statusMessage {
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
        if presentation.isTruncated { truncatedNote }
    }

    private var truncatedNote: some View {
        Text(copy.truncated)
            .font(.footnote)
            .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
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

    private var breadcrumbs: some View {
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

    @ViewBuilder private func row(_ item: DriveItem) -> some View {
        if item.kind == .folder, let driveID = route?.driveID ?? model.rootDriveID {
            NavigationLink(value: childRoute(item, driveID: driveID)) {
                DriveFileRow(design: design, copy: copy, model: model, item: item)
            }
        } else {
            HStack(spacing: 6) {
                Button { open(item) } label: {
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
                        itemActions(item)
                    } label: {
                        (atum?.barIcon(.moreHorizontal) ?? Image("ph.dots-three"))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(copy.more)
                    .accessibilityIdentifier("drive.more." + item.id)
                }
            }
            .contextMenu { itemActions(item) }
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

/// One icon, as desktop's Icons view draws it: the glyph on a quiet plate and
/// the name under it, cut in the middle when long (the context menu shows it
/// whole). Busy and kept-offline marks sit on the plate's corner, where
/// desktop puts its sync badge.
private struct DriveGridCell: View {
    let design: LiveDesign
    let copy: DriveCopy
    @Bindable var model: DriveFeatureModel
    let item: DriveItem

    @Environment(\.atum) private var atum
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 6) {
            Image(design.symbol(DriveFileFamily.of(item).glyphAlias))
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(atum?.color(.soft, scheme: scheme) ?? .secondary)
                .frame(width: 88, height: 76)
                .background(atum?.color(.cell, scheme: scheme) ?? Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(atum?.color(.frame, scheme: scheme) ?? .clear, lineWidth: 0.5))
                .overlay(alignment: .bottomTrailing) { badge.padding(6) }
            Text(verbatim: DriveArrangement.middleTruncated(item.name))
                .font(.footnote)
                .foregroundStyle(atum?.color(.ink, scheme: scheme) ?? .primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.name))
        .accessibilityValue(model.keptItemIDs.contains(item.id) ? Text(copy.keptOffline) : Text(""))
        .accessibilityIdentifier("drive.item." + item.id)
    }

    @ViewBuilder private var badge: some View {
        if model.busyItemIDs.contains(item.id) {
            if let progress = model.transferProgress[item.id] {
                ProgressView(value: progress).progressViewStyle(.circular).controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
        } else if model.keptItemIDs.contains(item.id) {
            Image(atum?.symbol(.pinFilled) ?? "ph.push-pin.fill")
                .font(.caption2)
                .foregroundStyle(atum?.color(.muted, scheme: scheme) ?? .secondary)
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
            Image(design.symbol(DriveFileFamily.of(item).glyphAlias))
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
                            Text(verbatim: DriveTimeFormat.modified(
                                modifiedAt, now: Date(), locale: Locale(identifier: design.locale)))
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

extension DriveFileFamily {
    /// The Phosphor alias for the desktop glyph of the same family
    /// (`file-glyph.tsx`: FileText, FileSpreadsheet, Presentation, FileImage,
    /// FileMusic, Movie, FileZip, File).
    var glyphAlias: String {
        switch self {
        case .folder: "Folder"
        case .document: "FileText"
        case .spreadsheet: "FileSpreadsheet"
        case .presentation: "FileTypePpt"
        case .image: "FileImage"
        case .audio: "FileMusic"
        case .video: "Movie"
        case .archive: "FileZip"
        case .other: "File"
        }
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
    let name: String

    /// Shares the file under its own name, not the cache's key.
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [DriveShareFile.make(from: url, name: name) ?? url],
                                 applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
