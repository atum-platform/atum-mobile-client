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
    var schedule: (@MainActor () async throws -> HostAgentDesk.Schedule?)?
    /// `POST /api/host/desk` `{read: files, path?}`; nil without the host route.
    /// A busy outcome is the Shell's 10 s read admission, asked again later.
    var files: (@MainActor (String?) async -> HostAgentDesk.FilesOutcome)?
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
    static let refresh = "desktop.common.refresh"

    static func key(_ name: String) -> String { "shared.matrix-agent-desk-copy.matrixAgentDeskCopy." + name }

    @MainActor static func text(_ design: LiveDesign, _ name: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key(name), arguments: arguments)
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
    @State private var model: AgentDeskModel
    @State private var muted: Bool
    @State private var moreOpen = false
    @State private var saving: LiveMediaFile?
    @State private var savePending: String?
    @State private var saveFailed = false

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
        _model = State(initialValue: AgentDeskModel(actions: actions))
    }

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private func copy(_ name: String, _ arguments: [AtumCopy.Argument] = []) -> String {
        AgentDeskCopy.text(design, name, arguments)
    }

    var body: some View {
        let rows = chat?.rows ?? []
        // The transcript's own status lookup (`WorkingLineRow.swift:18`).
        let now = AgentDeskPolicy.now(rows: rows) { key, minutes in
            guard design.copy.contains(key) else { return nil }
            return design.text(key, arguments: minutes.map { [.number(Int64($0))] } ?? [])
        }
        let sent = AgentDeskPolicy.sentFiles(rows: rows, agentUserID: actions.agentUserID)
        // One system inset-grouped list (UX polish P2, audit issue 6): Now,
        // then Files and Controls as the list's own sections, with the
        // system's headers, footers and row highlights.
        List {
            if Self.isWorking(now) {
                Section {
                    AgentDeskNow(design: design, now: now, steers: actions.steers)
                        .padding(.vertical, kit.space(.s1))
                }
                .listRowBackground(rowBackground)
            }
            if !sent.isEmpty {
                sentSection(sent)
            }
            if let view = model.shownOwnView {
                ownSection(view, sentIsEmpty: sent.isEmpty)
            }
            controlsSection
            if moreOpen {
                moreSections
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .contentMargins(.horizontal, kit.space(.s4), for: .scrollContent)
        .scrollContentBackground(.hidden)
        .accessibilityLabel(copy("desk", [.text(info.title)]))
        .accessibilityIdentifier("desk.page")
        .background(atum.color(.ground, scheme: scheme).opacity(0.001))
        .navigationTitle(info.title)
        .navigationBarTitleDisplayMode(.inline)
        // A page pushed inside the panel: the system Back only (P6 rule).
        .onChange(of: info.isMuted) { _, value in muted = value }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .sheet(item: $saving) { file in
            AgentDeskExporter(url: file.url) { saving = nil }
                .ignoresSafeArea()
        }
        // The Shared Collections pattern (`SharedCollectionsSection.swift:771`).
        .alert(ChatCopy.text(design, .errorGeneric), isPresented: $saveFailed) {
            Button(ChatCopy.text(design, .dismiss), role: .cancel) {}
        }
    }

    private var kit: AtumKit { design.kit }
    private var rowBackground: Color { atum.color(.cell, scheme: scheme) }

    /// Now shows only while the agent works or waits.
    static func isWorking(_ now: AgentDeskPolicy.Now) -> Bool {
        if case .free = now { return false }
        return true
    }

    // MARK: Files

    /// What the agent sent in this chat, under "Files".
    private func sentSection(_ sent: [ChatItem]) -> some View {
        Section {
            ForEach(sent, id: \.id) { item in
                sentRow(item)
            }
        } header: {
            Text(copy("files"))
                .accessibilityHint(copy("sentHere"))
                .accessibilityIdentifier("desk.files.sent")
        }
        .listRowBackground(rowBackground)
    }

    /// The agent's own files on its computer, when the host shares them. With
    /// nothing sent here, this group heads the files as "Files" and says
    /// where they are in its footer.
    private func ownSection(_ view: HostAgentDesk.Files, sentIsEmpty: Bool) -> some View {
        Section {
            ownFiles(view)
        } header: {
            Text(copy(sentIsEmpty ? "files" : "onItsComputer"))
                .accessibilityIdentifier("desk.files.own")
        } footer: {
            if sentIsEmpty {
                Text(copy("onItsComputer"))
            }
        }
        .listRowBackground(rowBackground)
    }

    private func sentRow(_ item: ChatItem) -> some View {
        let name = Self.fileName(item)
        return HStack(spacing: kit.space(.s3)) {
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
            Spacer(minLength: kit.space(.s2))
            Button(copy("saveShort")) { save(item) }
                .buttonStyle(.atumSecondary)
                .controlSize(.small)
                .disabled(savePending != nil || chat == nil)
                .accessibilityLabel(copy("save", [.text(name)]))
                .accessibilityIdentifier("desk.file.save." + item.id)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk.file." + item.id)
    }

    @ViewBuilder private func ownFiles(_ view: HostAgentDesk.Files) -> some View {
        if model.ownPath != nil {
            Button { model.back() } label: {
                deskRow(glyph: .chevronLeft, title: copy("back"), chevron: false)
            }
            .accessibilityIdentifier("desk.own.back")
        }
        ForEach(view.rows, id: \.id) { row in
            if row.kind == .folder {
                Button { model.open(view.deskPath + "/" + row.name) } label: {
                    deskRow(glyph: .folder, title: row.name, chevron: true)
                }
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

    // MARK: Controls

    /// Pause, this chat's notifications and More. A failed control and the
    /// schedule's Refresh sit under the group, in its footer.
    private var controlsSection: some View {
        Section {
            if model.canControl {
                toggleRow(glyph: .clock, title: copy("pause"), id: "desk.pause",
                          isOn: Binding(get: { HostAgentDesk.isPaused(model.jobs) },
                                        set: { on in model.run(on ? .pause : .resume) }))
                    .disabled(model.controlsDisabled)
                    .accessibilityHint(AgentDeskCopy.text(design, "pauseHint"))
            }
            toggleRow(glyph: .bell, title: copy("notifications"), id: "desk.notifications",
                      isOn: Binding(get: { !muted }, set: { on in
                          muted = !on
                          setMuted?(info.roomID, !on)
                      }))
                .disabled(setMuted == nil)
            Button { withMotion(.standard) { moreOpen.toggle() } } label: {
                deskRow(glyph: .slidersHorizontal, title: copy("moreControls"),
                        chevron: true, chevronOpen: moreOpen)
            }
            .accessibilityValue(Text(verbatim: ""))
            .accessibilityAddTraits(moreOpen ? .isSelected : [])
            .accessibilityIdentifier("desk.more")
        } header: {
            Text(copy("controls"))
                .accessibilityIdentifier("desk.controls")
        } footer: {
            if model.problem != nil || model.canRefreshSchedule {
                VStack(alignment: .leading, spacing: kit.space(.s2)) {
                    if let problem = model.problem {
                        Text(copy(problem == .stopped ? "computerOff" : "controlFailed"))
                            .accessibilityIdentifier("desk.problem")
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    if model.canRefreshSchedule {
                        Button(design.text(AgentDeskCopy.refresh)) { model.refreshSchedule() }
                            .buttonStyle(.atumSecondary)
                            .controlSize(.small)
                            .accessibilityIdentifier("desk.schedule.refresh")
                    }
                }
            }
        }
        .listRowBackground(rowBackground)
    }

    /// Behind More: its routines, then the card's settings.
    @ViewBuilder private var moreSections: some View {
        if let jobs = model.jobs, !jobs.isEmpty {
            Section {
                ForEach(jobs) { job in
                    routineRow(job)
                }
            } header: {
                Text(copy("routines"))
            }
            .listRowBackground(rowBackground)
        }
        Section {
            Button(action: allSettings) {
                deskRow(glyph: .settings, title: copy("allSettings"), chevron: true)
            }
            .accessibilityIdentifier("desk.allSettings")
        }
        .listRowBackground(rowBackground)
    }

    private func routineRow(_ job: HostAgentDesk.Job) -> some View {
        let meta: String? = switch HostAgentDesk.routineLine(job) {
        case .nothing: nil
        case .paused: copy("paused")
        case let .next(date): copy("nextRun", [.text(Self.nextRun(date, locale: design.locale))])
        }
        return HStack(spacing: kit.space(.s3)) {
            Image(atum.symbol(.clock))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: job.name).font(.body).lineLimit(1)
                if let meta {
                    Text(verbatim: meta).font(.footnote).foregroundStyle(atum.color(.muted, scheme: scheme))
                }
            }
            Spacer(minLength: kit.space(.s2))
            if actions.control != nil, HostAgentDesk.isSwitchable(job) {
                Toggle(isOn: Binding(get: { job.state != .paused },
                                     set: { on in model.run(on ? .routineOn(job: job.id) : .routineOff(job: job.id)) })) {
                    Text(verbatim: job.name)
                }
                .labelsHidden()
                .tint(atum.color(.actionStrong, scheme: scheme))
                .disabled(model.controlsDisabled)
                .accessibilityIdentifier("desk.routine." + job.id)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("desk.routineRow." + job.id)
    }

    // MARK: Rows

    private func deskRow(glyph: AtumGlyph, title: String, meta: String? = nil,
                         chevron: Bool, chevronOpen: Bool = false) -> some View {
        HStack(spacing: kit.space(.s3)) {
            Image(atum.symbol(glyph))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.body).lineLimit(1)
                    .foregroundStyle(atum.color(.ink, scheme: scheme))
                if let meta {
                    Text(verbatim: meta).font(.footnote).foregroundStyle(atum.color(.muted, scheme: scheme))
                }
            }
            Spacer(minLength: kit.space(.s2))
            if chevron {
                Image(atum.symbol(.chevronRight))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .rotationEffect(.degrees(chevronOpen ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func toggleRow(glyph: AtumGlyph, title: String, id: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: kit.space(.s3)) {
                Image(atum.symbol(glyph))
                    .accessibilityHidden(true)
                Text(verbatim: title).font(.body)
            }
            .foregroundStyle(atum.color(.ink, scheme: scheme))
        }
        .tint(atum.color(.actionStrong, scheme: scheme))
        .accessibilityIdentifier(id)
    }
    // MARK: Reads and controls

    private func save(_ item: ChatItem) {
        guard let media = item.media, let chat else { return }
        savePending = item.id
        Task { @MainActor in
            let file = await chat.media.file(media)
            savePending = nil
            if let file { saving = file } else { saveFailed = true }
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
struct AgentDeskNow: View {
    let design: LiveDesign
    let now: AgentDeskPolicy.Now
    let steers: Bool

    @Environment(\.colorScheme) private var scheme

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        switch now {
        case .free:
            EmptyView()
        case let .working(since, line, steps):
            block(state: "working", since: since, line: line, steps: steps, waiting: false)
        case let .waiting(since, line):
            block(state: "waiting", since: since, line: line, steps: [], waiting: true)
        }
    }

    private func block(state: String, since: Date?, line: String?, steps: [WorkingLineText.Step],
                       waiting: Bool) -> some View {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Group {
                            // Waiting is still, as desktop's dot; working turns.
                            if waiting {
                                Circle().fill(design.kit.color(.warn, scheme: scheme)).frame(width: 8, height: 8)
                            } else {
                                AtomWait()
                            }
                        }
                        .frame(width: 16, height: 16).accessibilityHidden(true)
                        Text(verbatim: head(state: state, since: since, now: context.date))
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                            .accessibilityIdentifier("desk.now.head")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityHint(AgentDeskCopy.text(design, steers ? "steerHint" : "queueHint"))
                    if let line {
                        AgentDeskClamped(design: design, text: line, font: .body, id: "desk.now.line")
                    }
                    if !steps.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(atum.symbol(step.done ? .check : .circle))
                                        .font(.caption)
                                        .foregroundStyle(atum.color(step.done ? .ink : .soft, scheme: scheme))
                                        .accessibilityHidden(true)
                                    // VoiceOver hears whether each step is done (the check is drawn only).
                                    AgentDeskClamped(design: design, text: step.text, font: .subheadline,
                                                     done: step.done, id: "desk.now.step.\(index)")
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

    private func head(state name: String, since: Date?, now: Date) -> String {
        let state = AgentDeskCopy.text(design, name)
        guard let minutes = AgentDeskPolicy.minutes(since: since, now: now) else { return state }
        return state + " · " + AgentDeskCopy.text(design, "minutes", [.number(Int64(minutes))])
    }
}

/// Agent text clamped to three lines, with Show more / Show less when it overflows.
private struct AgentDeskClamped: View {
    let design: LiveDesign
    let text: String
    let font: Font
    /// A checklist step: its completion is spoken as an accessibility value.
    var done: Bool?
    let id: String

    @State private var open = false
    @State private var overflows = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // The desk pin has no completion labels. Speak the localized progress value.
        let completion = done.map { done in
            let progress = done ? 1.0 : 0.0
            return progress.formatted(.percent.locale(Locale(identifier: design.locale)))
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: text)
                .font(font)
                .lineLimit(open ? nil : 3)
                .accessibilityValue(Text(verbatim: completion ?? ""), isEnabled: completion != nil)
                .accessibilityIdentifier(id)
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

/// Save: the system's export sheet for a copy of the downloaded file (desktop's
/// Save downloads it; on the phone the person chooses where it goes in Files).
private struct AgentDeskExporter: UIViewControllerRepresentable {
    let url: URL
    let done: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        #if DEBUG
        UITestProbe.append("save picker " + url.lastPathComponent, to: "agent-desk.txt")
        #endif
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
