import AtumChat
import AtumDesign
import AtumNativeAPI
import SwiftUI
import UIKit

/// What the host gives the agent's desk (W4-E3, atum-desktop PR #51). The
/// host routes are offered only for a roster `runtime: "hermes"` agent; the
/// rest of the desk reads the chat itself.
struct AgentDeskActions {
    /// The agent's Matrix user: only its own files are listed as sent here.
    let agentUserID: String?
    /// A native Hermes agent: a message typed now changes what it is doing
    /// (desktop `matrixAgentDeskSteers`); otherwise new messages wait.
    let steers: Bool
    /// `POST /api/host/desk` `{read: schedule}`; nil without the host route.
    var schedule: (@MainActor () async -> HostAgentDesk.Schedule?)?
    /// `POST /api/host/desk` `{read: files, path?}`; nil without the host route.
    var files: (@MainActor (String?) async -> HostAgentDesk.Files?)?
    /// `POST /api/host/agent-control`; nil without the host route.
    var control: (@MainActor (HostAgentDesk.Control) async -> HostAgentDesk.ControlOutcome)?
}

/// The chat's own state, handed to the panel by the chat screen (the panel's
/// sheet sits outside the chat's environment).
struct AgentDeskChat {
    let rows: [ChatRow]
    let media: ChatMediaAccess
}

/// The desk's words, all from the pinned export (`shared/matrix-agent-desk-copy.ts`).
enum AgentDeskCopy {
    static func key(_ name: String) -> String { "shared.matrix-agent-desk-copy.matrixAgentDeskCopy." + name }

    @MainActor static func text(_ design: LiveDesign, _ name: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key(name), arguments: arguments)
    }

    /// PENDING-COPY: `pauseHint` is not in the pinned export (desktop added it in #51
    /// after the pin). Until a repin carries it, Pause has no hint; no words are invented.
    static let pendingKeys: Set<String> = ["pauseHint"]

    @MainActor static func pendingText(_ design: LiveDesign, _ name: String) -> String? {
        design.copy.contains(key(name)) ? design.text(key(name)) : nil
    }
}

/// The agent's own page in its 1:1 chat's side panel: Now only while it works,
/// Files (what it sent here, then its own files on its computer when the host
/// shares them), and Controls (Pause, this chat's notifications, and behind More
/// its routines and the card's settings). No money, no explanations, no second
/// chat: steering is the composer.
struct AgentDeskPage: View {
    let design: LiveDesign
    let info: ChatInfoPresentation
    let actions: AgentDeskActions
    let chat: AgentDeskChat?
    let setMuted: ((String, Bool) -> Void)?
    /// "All settings": back to the panel's home, the agent's card.
    let allSettings: () -> Void
    let close: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var jobs: [HostAgentDesk.Job]?
    @State private var problem: Problem?
    @State private var muted: Bool
    @State private var moreOpen = false
    @State private var ownPath: String?
    @State private var ownView: HostAgentDesk.Files?
    @State private var saving: LiveMediaFile?
    @State private var savePending: String?

    enum Problem: Equatable { case failed, stopped }

    init(design: LiveDesign, info: ChatInfoPresentation, actions: AgentDeskActions, chat: AgentDeskChat?,
         setMuted: ((String, Bool) -> Void)?, allSettings: @escaping () -> Void, close: @escaping () -> Void) {
        self.design = design
        self.info = info
        self.actions = actions
        self.chat = chat
        self.setMuted = setMuted
        self.allSettings = allSettings
        self.close = close
        _muted = State(initialValue: info.isMuted)
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private func copy(_ name: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        AgentDeskCopy.text(design, name, arguments)
    }

    var body: some View {
        let rows = chat?.rows ?? []
        let now = AgentDeskPolicy.now(rows: rows)
        let sent = AgentDeskPolicy.sentFiles(rows: rows, agentUserID: actions.agentUserID)
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                AgentDeskNow(design: design, now: now, steers: actions.steers)
                if !sent.isEmpty || shownOwnView != nil {
                    filesSection(sent)
                }
                controlsSection
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(copy("desk", [.text(info.title)]))
            .accessibilityIdentifier("desk.page")
        }
        .background(atum.color(.ground, scheme: scheme).opacity(0.001))
        .navigationTitle(info.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                ChatPanelCloseButton(design: design, close: close)
            }
        }
        .onChange(of: info.isMuted) { _, value in muted = value }
        .task { await readSchedule() }
        .task(id: ownPath) { await readOwnFiles(ownPath) }
        .sheet(item: $saving) { file in
            AgentDeskExporter(url: file.url) { saving = nil }
                .ignoresSafeArea()
        }
    }

    // MARK: Files

    /// Desktop shows its own files only while the folder has rows or is a subfolder.
    private var shownOwnView: HostAgentDesk.Files? {
        guard let ownView, !ownView.rows.isEmpty || ownPath != nil else { return nil }
        return ownView
    }

    private func filesSection(_ sent: [ChatItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(copy("files"))
            if !sent.isEmpty {
                AgentDeskGroup(design: design) {
                    ForEach(Array(sent.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { AgentDeskDivider() }
                        sentRow(item)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityHint(copy("sentHere"))
                .accessibilityIdentifier("desk.files.sent")
            }
            if let view = shownOwnView {
                Text(copy("onItsComputer"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .padding(.top, sent.isEmpty ? 0 : 8)
                    .padding(.leading, 4)
                ownFiles(view)
            }
        }
    }

    private func sentRow(_ item: ChatItem) -> some View {
        let name = Self.fileName(item)
        return HStack(spacing: 12) {
            Image(atum.symbol(.file))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(.body).lineLimit(1).truncationMode(.middle)
                Text(verbatim: [item.media?.byteSize.map { Self.size(Int64(clamping: $0)) },
                                Self.when(item.timestamp, locale: design.locale)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
            }
            Spacer(minLength: 8)
            Button(copy("saveShort")) { save(item) }
                .buttonStyle(.atumSecondary)
                .controlSize(.small)
                .disabled(savePending != nil || chat == nil)
                .accessibilityLabel(copy("save", [.text(name)]))
                .accessibilityIdentifier("desk.file.save." + item.id)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk.file." + item.id)
    }

    private func ownFiles(_ view: HostAgentDesk.Files) -> some View {
        AgentDeskGroup(design: design) {
            if ownPath != nil {
                Button { ownPath = HostAgentDesk.parent(of: ownPath) } label: {
                    deskRow(glyph: .chevronLeft, title: copy("back"), chevron: false)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("desk.own.back")
                if !view.rows.isEmpty { AgentDeskDivider() }
            }
            ForEach(Array(view.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { AgentDeskDivider() }
                if row.kind == .folder {
                    Button { ownPath = view.deskPath + "/" + row.name } label: {
                        deskRow(glyph: .folder, title: row.name, chevron: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: row.name))
                    .accessibilityIdentifier("desk.own.folder." + row.name)
                } else {
                    deskRow(glyph: .file, title: row.name,
                            meta: Self.size(row.size) + " · "
                                + Self.when(Date(timeIntervalSince1970: Double(row.modifiedAt) / 1000),
                                            locale: design.locale),
                            chevron: false)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("desk.own.file." + row.name)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk.files.own")
    }

    // MARK: Controls

    private var canControl: Bool { actions.control != nil && !(jobs ?? []).isEmpty }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading(copy("controls"))
            AgentDeskGroup(design: design) {
                if canControl {
                    toggleRow(glyph: .clock, title: copy("pause"), id: "desk.pause",
                              isOn: Binding(get: { HostAgentDesk.isPaused(jobs) },
                                            set: { on in run(on ? .pause : .resume) }))
                        .accessibilityHint(AgentDeskCopy.pendingText(design, "pauseHint") ?? "")
                    AgentDeskDivider()
                }
                toggleRow(glyph: .bell, title: copy("notifications"), id: "desk.notifications",
                          isOn: Binding(get: { !muted }, set: { on in
                              muted = !on
                              setMuted?(info.roomID, !on)
                          }))
                    .disabled(setMuted == nil)
                AgentDeskDivider()
                Button { withAnimation(.easeOut(duration: 0.2)) { moreOpen.toggle() } } label: {
                    deskRow(glyph: .slidersHorizontal, title: copy("moreControls"),
                            chevron: true, chevronOpen: moreOpen)
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(verbatim: ""))
                .accessibilityAddTraits(moreOpen ? .isSelected : [])
                .accessibilityIdentifier("desk.more")
                if moreOpen {
                    moreBody
                }
            }
            if let problem {
                Text(copy(problem == .stopped ? "computerOff" : "controlFailed"))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .padding(.leading, 4)
                    .accessibilityIdentifier("desk.problem")
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk.controls")
    }

    @ViewBuilder private var moreBody: some View {
        if let jobs, !jobs.isEmpty {
            AgentDeskDivider()
            Text(copy("routines"))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(atum.color(.muted, scheme: scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(jobs) { job in
                routineRow(job)
            }
        }
        AgentDeskDivider()
        Button(action: allSettings) {
            deskRow(glyph: .settings, title: copy("allSettings"), chevron: true)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("desk.allSettings")
    }

    private func routineRow(_ job: HostAgentDesk.Job) -> some View {
        let meta: String? = switch HostAgentDesk.routineLine(job) {
        case .nothing: nil
        case .paused: copy("paused")
        case let .next(date): copy("nextRun", [.text(Self.nextRun(date, locale: design.locale))])
        }
        return HStack(spacing: 12) {
            Image(atum.symbol(.clock))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: job.name).font(.body).lineLimit(1)
                if let meta {
                    Text(verbatim: meta).font(.footnote).foregroundStyle(atum.color(.muted, scheme: scheme))
                }
            }
            Spacer(minLength: 8)
            if actions.control != nil, HostAgentDesk.isSwitchable(job) {
                Toggle(isOn: Binding(get: { job.state != .paused },
                                     set: { on in run(on ? .routineOn(job: job.id) : .routineOff(job: job.id)) })) {
                    Text(verbatim: job.name)
                }
                .labelsHidden()
                .accessibilityIdentifier("desk.routine." + job.id)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk.routineRow." + job.id)
    }

    // MARK: Rows

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(atum.color(.ink, scheme: scheme))
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func deskRow(glyph: AtumGlyph, title: String, meta: String? = nil,
                         chevron: Bool, chevronOpen: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(atum.symbol(glyph))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.body).lineLimit(1)
                if let meta {
                    Text(verbatim: meta).font(.footnote).foregroundStyle(atum.color(.muted, scheme: scheme))
                }
            }
            Spacer(minLength: 8)
            if chevron {
                Image(atum.symbol(.chevronRight))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .rotationEffect(.degrees(chevronOpen ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private func toggleRow(glyph: AtumGlyph, title: String, id: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(atum.symbol(glyph))
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                    .accessibilityHidden(true)
                Text(verbatim: title).font(.body)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .accessibilityIdentifier(id)
    }

    // MARK: Reads and controls

    private func readSchedule() async {
        guard let read = actions.schedule, let schedule = await read(), !Task.isCancelled else { return }
        jobs = schedule.jobs
    }

    private func readOwnFiles(_ path: String?) async {
        guard let read = actions.files else { return }
        let view = await read(path)
        guard !Task.isCancelled, path == ownPath else { return }
        // A refusal of the home reads as none; a refused subfolder keeps the last listing.
        if let view { ownView = view } else if path == nil { ownView = nil }
    }

    /// Optimistic: the switch moves at once and rolls back if the host refuses
    /// or changes nothing; a busy reply (the shared cooldown) is retried once.
    private func run(_ control: HostAgentDesk.Control) {
        guard let send = actions.control, let before = jobs else { return }
        problem = nil
        jobs = HostAgentDesk.optimistic(control, before)
        Task { @MainActor in
            var retried = false
            while true {
                let outcome = await send(control)
                switch HostAgentDesk.resolve(outcome, for: control, retried: retried) {
                case .keep: return
                case .rollBack: jobs = before; return
                case .rollBackStopped: jobs = before; problem = .stopped; return
                case .rollBackFailed: jobs = before; problem = .failed; return
                case .retryAfterCooldown:
                    retried = true
                    try? await Task.sleep(for: HostAgentDesk.controlRetryDelay)
                }
            }
        }
    }

    private func save(_ item: ChatItem) {
        guard let media = item.media, let chat else { return }
        savePending = item.id
        Task { @MainActor in
            let file = await chat.media.file(media)
            savePending = nil
            if let file { saving = file } else {
                AccessibilityNotification.Announcement(ChatCopy.text(design, .errorGeneric)).post()
            }
        }
    }

    // MARK: Formatting

    static func fileName(_ item: ChatItem) -> String {
        if let name = item.media?.filename, !name.isEmpty { return name }
        if case let .file(name) = item.kind, !name.isEmpty { return name }
        return item.body
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// A short local time: today's hour, else the day (desktop `relativeWhen`).
    static func when(_ date: Date, locale: String) -> String {
        let style = Calendar.current.isDateInToday(date)
            ? Date.FormatStyle.dateTime.hour().minute()
            : Date.FormatStyle.dateTime.day().month(.abbreviated)
        return date.formatted(style.locale(Locale(identifier: locale)))
    }

    static func nextRun(_ date: Date, locale: String) -> String {
        date.formatted(Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
            .locale(Locale(identifier: locale)))
    }
}

/// Now, only while it works: the working line's head ("Working · 4 min"), the
/// line itself clamped to three lines with Show more, and its checklist. How a
/// message steers or waits is a hint on the head, never a sentence on the panel.
private struct AgentDeskNow: View {
    let design: LiveDesign
    let now: AgentDeskPolicy.Now
    let steers: Bool

    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        if case let .working(since, line, steps) = now {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        AtomWait().frame(width: 16, height: 16).accessibilityHidden(true)
                        Text(verbatim: head(since: since, now: context.date))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                            .accessibilityIdentifier("desk.now.head")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(AgentDeskCopy.text(design, steers ? "steerHint" : "queueHint"))
                    if let line {
                        AgentDeskClamped(design: design, text: line, font: .body)
                            .accessibilityIdentifier("desk.now.line")
                    }
                    if !steps.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(atum.symbol(step.done ? .check : .circle))
                                        .font(.caption)
                                        .foregroundStyle(atum.color(step.done ? .ink : .soft, scheme: scheme))
                                        .accessibilityHidden(true)
                                    AgentDeskClamped(design: design, text: step.text, font: .subheadline)
                                }
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("desk.now.steps")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("desk.now")
        }
    }

    private func head(since: Date?, now: Date) -> String {
        let state = AgentDeskCopy.text(design, "working")
        guard let minutes = AgentDeskPolicy.minutes(since: since, now: now) else { return state }
        return state + " · " + AgentDeskCopy.text(design, "minutes", [.number(Int64(minutes))])
    }
}

/// Agent text clamped to three lines, with Show more / Show less when it overflows.
private struct AgentDeskClamped: View {
    let design: LiveDesign
    let text: String
    let font: Font

    @State private var open = false
    @State private var overflows = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: text)
                .font(font)
                .lineLimit(open ? nil : 3)
                .background {
                    // The full height against the clamped one decides whether More shows.
                    ViewThatFits(in: .vertical) {
                        Text(verbatim: text).font(font).fixedSize(horizontal: false, vertical: true).hidden()
                            .onAppear { overflows = false }
                        Color.clear.onAppear { overflows = true }
                    }
                }
            if overflows || open {
                Button(AgentDeskCopy.text(design, open ? "less" : "more")) { open.toggle() }
                    .font(.footnote)
                    .buttonStyle(.plain)
                    .foregroundStyle(AtumVisualSystem(design: design).color(.ink, scheme: scheme))
            }
        }
    }
}

/// One rounded group of rows on the panel's ground (the panel's other pages' cell).
private struct AgentDeskGroup<Content: View>: View {
    let design: LiveDesign
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) { content }
            .background(AtumVisualSystem(design: design).color(.cell, scheme: scheme),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AgentDeskDivider: View {
    var body: some View { Divider().padding(.leading, 48) }
}

/// Save: the system's export sheet for a copy of the downloaded file (desktop's
/// Save downloads it; on the phone the person chooses where it goes in Files).
private struct AgentDeskExporter: UIViewControllerRepresentable {
    let url: URL
    let done: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done() }
    }
}
