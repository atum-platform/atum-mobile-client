import AtumChat
import SwiftUI

/// One "Forward" from the long-press menu: the source event and the name the
/// preview card shows above it (desktop `MatrixForwardDialog` `sourceName`).
struct ForwardPickerRequest: Identifiable, Equatable {
    let id = UUID()
    let eventID: String
    let sourceName: String
}

/// What the picker drives. Live, these call `RoomForwarding`
/// (`LiveAppModel.prepareForward`); the Debug capture supplies fixed data.
struct ForwardPickerSession {
    let preview: ForwardContent
    let targets: @MainActor (String) async throws -> [RoomForwarding.Target]
    let send: @MainActor (String) async throws -> RoomForwarding.Receipt
}

/// Desktop `forward-dialog.tsx`'s states per destination, plus the phone's
/// held state after an ambiguous write (`ForwardFailure.deliveryUnconfirmed`):
/// that row never offers a repeat.
@MainActor
@Observable
final class ForwardPickerModel {
    enum Phase: Equatable { case preparing, ready, unavailable }
    enum SendState: Equatable { case idle, sending, sent, failed, unconfirmed }

    private(set) var phase = Phase.preparing
    private(set) var preview: ForwardContent?
    private(set) var targets = [RoomForwarding.Target]()
    private(set) var loadedTargets = false
    private(set) var states = [String: SendState]()
    var query = ""
    let sourceName: String
    let teamName: String?

    @ObservationIgnored private let prepare: @MainActor () async throws -> ForwardPickerSession
    @ObservationIgnored private var session: ForwardPickerSession?
    @ObservationIgnored private var generation: UInt64 = 0

    init(sourceName: String, teamName: String?,
         prepare: @escaping @MainActor () async throws -> ForwardPickerSession) {
        self.sourceName = sourceName
        self.teamName = teamName
        self.prepare = prepare
    }

    /// Once per presentation, and again when a send says the source changed.
    func start() async {
        generation &+= 1
        let opened = generation
        phase = .preparing
        do {
            let session = try await prepare()
            guard opened == generation, !Task.isCancelled else { return }
            self.session = session
            preview = session.preview
            phase = .ready
        } catch {
            guard opened == generation, !Task.isCancelled else { return }
            session = nil
            phase = .unavailable
        }
    }

    /// The engine's own local search (title and Matrix display name), on
    /// open, on each settled query and on a joined-room change.
    func loadTargets() async {
        guard let session else { return }
        let opened = generation
        let needle = query
        do {
            let found = try await session.targets(needle)
            guard opened == generation, needle == query, !Task.isCancelled else { return }
            targets = found
            loadedTargets = true
        } catch is CancellationError {
            return
        } catch {
            guard opened == generation, !Task.isCancelled else { return }
            phase = .unavailable
        }
    }

    func state(_ roomID: String) -> SendState { states[roomID] ?? .idle }

    func canSend(_ target: RoomForwarding.Target) -> Bool {
        guard phase == .ready, target.refusal == nil else { return false }
        switch state(target.id) {
        case .idle, .failed: return true
        case .sending, .sent, .unconfirmed: return false
        }
    }

    /// One confirmed tap per destination. Success and an ambiguous write
    /// both hold the row: the picker never repeats a write it cannot rule out.
    func send(_ target: RoomForwarding.Target) async {
        guard canSend(target), let session else { return }
        states[target.id] = .sending
        do {
            _ = try await session.send(target.id)
            states[target.id] = .sent
        } catch ForwardFailure.deliveryUnconfirmed {
            states[target.id] = .unconfirmed
        } catch ForwardFailure.sourceChanged {
            // The message changed while the picker was open: a new preview
            // and a new decision, as desktop's dialog keys on the source.
            states[target.id] = .failed
            await start()
            await loadTargets()
        } catch {
            states[target.id] = .failed
        }
    }
}

/// Desktop `MatrixForwardDialog` as a phone sheet: the title, the message
/// card, the search field, the company note, then the destinations with a
/// Send per row. Words: exported `chat-copy` forward keys.
struct ForwardPickerSheet: View {
    @State var model: ForwardPickerModel
    let design: LiveDesign
    /// Joined-room or permission changes: the list is read again.
    let refreshKey: Int
    let loadThumbnail: ((String, Int) async -> Data?)?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var copy: ChatActionsCopy { ChatActionsCopy(design: design) }
    private var kit: AtumKit { design.kit }

    private struct LoadKey: Equatable {
        let phase: ForwardPickerModel.Phase
        let query: String
        let refresh: Int
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(copy.forwardTitle)
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: Text(verbatim: copy.forwardSearch))
        }
        .task { await model.start() }
        .task(id: LoadKey(phase: model.phase, query: model.query, refresh: refreshKey)) {
            guard model.phase == .ready else { return }
            // A settled query, as desktop's filter runs per keystroke on
            // in-memory rows; the phone's search rereads room power.
            if model.loadedTargets { try? await Task.sleep(for: .milliseconds(200)) }
            guard !Task.isCancelled else { return }
            await model.loadTargets()
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(design.color("glassOpaque", scheme: scheme))
        .environment(\.chatLoadMatrixThumbnail, loadThumbnail)
        .accessibilityIdentifier("chat.forward.sheet")
    }

    @ViewBuilder private var content: some View {
        List {
            Section {
                sourceCard
                    .listRowInsets(EdgeInsets(top: kit.space(.s2), leading: kit.space(.s4),
                                              bottom: kit.space(.s2), trailing: kit.space(.s4)))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                if let team = model.teamName {
                    Text(verbatim: copy.forwardTeamOnly(team))
                        .font(kit.font(.caption))
                        .foregroundStyle(kit.color(.ink3, scheme: scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            Section {
                switch model.phase {
                case .preparing:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 112)
                        .listRowBackground(Color.clear)
                case .unavailable:
                    unavailable
                case .ready where !model.loadedTargets:
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 112)
                        .listRowBackground(Color.clear)
                case .ready where model.targets.isEmpty:
                    Text(verbatim: copy.forwardEmpty)
                        .font(kit.font(.callout))
                        .foregroundStyle(kit.color(.ink3, scheme: scheme))
                        .frame(maxWidth: .infinity, minHeight: 112)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("chat.forward.empty")
                case .ready:
                    ForEach(model.targets) { target in
                        targetRow(target)
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Desktop `data-matrix-forward-preview`: a quiet card with the source
    /// name over two lines of the message, or a file line with its size.
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: kit.space(.s1)) {
            Text(verbatim: model.sourceName)
                .font(kit.font(.caption).weight(.semibold))
                .foregroundStyle(kit.color(.ink3, scheme: scheme))
                .lineLimit(1)
            if let preview = model.preview {
                switch preview.kind {
                case .text:
                    Text(verbatim: preview.body)
                        .font(kit.font(.callout))
                        .foregroundStyle(kit.color(.ink, scheme: scheme))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                case .image, .file:
                    HStack(spacing: kit.space(.s2)) {
                        Image(design.symbol(preview.kind == .image ? "FileImage" : "File"))
                            .font(kit.font(.callout))
                            .accessibilityHidden(true)
                        Text(verbatim: preview.filename ?? preview.body)
                            .font(kit.font(.callout))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let size = preview.byteSize {
                            Text(verbatim: "· " + Self.byteCount(size, locale: Locale(identifier: design.locale)))
                                .font(kit.font(.caption))
                                .foregroundStyle(kit.color(.ink3, scheme: scheme))
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    }
                    .foregroundStyle(kit.color(.ink, scheme: scheme))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(kit.space(.s3))
        .background(RoundedRectangle(cornerRadius: kit.radius(.lg), style: .continuous)
            .fill(kit.color(.fillHover, scheme: scheme)))
        .overlay(RoundedRectangle(cornerRadius: kit.radius(.lg), style: .continuous)
            .strokeBorder(kit.color(.line, scheme: scheme), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat.forward.preview")
    }

    private var unavailable: some View {
        VStack(spacing: kit.space(.s3)) {
            Text(verbatim: copy.errorGeneric)
                .font(kit.font(.callout))
                .foregroundStyle(kit.color(.ink2, scheme: scheme))
                .multilineTextAlignment(.center)
            Button(copy.retry) { Task { await model.start() } }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(kit.color(.ink, scheme: scheme))
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .listRowBackground(Color.clear)
    }

    @ViewBuilder private func targetRow(_ target: RoomForwarding.Target) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: kit.space(.s2)))
            : AnyLayout(HStackLayout(spacing: kit.space(.s3)))
        layout {
            HStack(spacing: kit.space(.s3)) {
                ChatFaceView(face: ChatFace(name: target.name, kind: .person, matrixAvatarURI: target.avatarURL,
                                            avatar: nil, sha256: nil, candidates: [], roomID: target.id),
                             size: 36)
                VStack(alignment: .leading, spacing: 2) { // design-lint: allow: desktop forward row name and subtitle sit 2 pt apart
                    Text(verbatim: target.name)
                        .font(kit.font(.bodyStrong))
                        .foregroundStyle(kit.color(.ink, scheme: scheme))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    // Desktop's tooltip on the disabled Send; a phone has no
                    // hover, so the line sits under the name.
                    if target.refusal == .encryptedAttachment {
                        Text(verbatim: copy.forwardEncryptedOnly)
                            .font(kit.font(.caption))
                            .foregroundStyle(kit.color(.ink3, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            sendButton(target)
        }
        .padding(.vertical, kit.space(.s1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.forward.target." + target.id)
    }

    private func sendButton(_ target: RoomForwarding.Target) -> some View {
        let state = model.state(target.id)
        let title = switch state {
        case .sent: copy.sent
        case .failed: copy.retry
        case .idle, .sending, .unconfirmed: copy.forwardSend
        }
        return Button {
            Task { await model.send(target) }
        } label: {
            HStack(spacing: kit.space(.s1)) {
                switch state {
                case .sending: ProgressView().controlSize(.small)
                case .sent: Image(design.symbol("Check")).accessibilityHidden(true)
                case .unconfirmed: Image(design.symbol("AlertCircle")).accessibilityHidden(true)
                case .idle, .failed: Image(design.symbol("Share")).accessibilityHidden(true)
                }
                Text(verbatim: title)
            }
            .font(kit.font(.callout).weight(.semibold))
            .frame(minHeight: 32)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .tint(kit.color(.ink, scheme: scheme))
        .disabled(!model.canSend(target))
        // Desktop's aria-label: "Send to <name>".
        .accessibilityLabel(Text(verbatim: state == .sent ? copy.sent : copy.forwardSendTo(target.name)))
        .accessibilityIdentifier("chat.forward.send." + target.id)
    }

    /// Desktop's compact byte unit (`Intl.NumberFormat` `unit: 'byte'`).
    static func byteCount(_ size: UInt64, locale: Locale) -> String {
        Int64(clamping: size).formatted(.byteCount(style: .file).locale(locale))
    }
}
