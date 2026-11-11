import AtumChat
import AtumDesign
import AtumNativeAPI
import CryptoKit
import SwiftUI

typealias AssistantRoutineLoadResult = AgentRoutinesLoadResult
enum AssistantRoutineMutationResult {
    case saved(AgentRoutinesSnapshot)
    case conflict(AgentRoutinesSnapshot?)
    case failed
}
enum AssistantRoutineRunsResult { case value(AgentRoutineRunsSnapshot), failed }

struct AssistantRoutineActions {
    let scope: String
    let read: () async -> AssistantRoutineLoadResult
    let create: (AgentRoutineCreate) async -> AssistantRoutineMutationResult
    let update: (AgentRoutineUpdate) async -> AssistantRoutineMutationResult
    let run: (AgentRoutineAction) async -> AssistantRoutineMutationResult
    let delete: (AgentRoutineAction) async -> AssistantRoutineMutationResult
    let runs: (NativeID) async -> AssistantRoutineRunsResult
}

/// Persists only an opaque request UUID under a SHA-256 of the assistant,
/// operation and canonical draft. No title/instruction/schedule text is stored.
struct RoutineRequestLedger {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func key(scope: String, operation: String, fingerprint: String) -> String {
        let bytes = Data("atum.routine-request.v1\u{0}\(scope)\u{0}\(operation)\u{0}\(fingerprint)".utf8)
        return "atum.routine.request." + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    func requestID(for key: String) -> NativeID {
        if let raw = defaults.string(forKey: key), let value = try? NativeID(raw) { return value }
        let value = try! NativeID(UUID().uuidString.lowercased())
        defaults.set(value.rawValue, forKey: key)
        return value
    }

    func clear(_ key: String?) {
        guard let key else { return }
        defaults.removeObject(forKey: key)
    }
}

enum RoutineWallClock {
    static func parts(_ date: Date, timezone: String) -> (hour: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        let value = calendar.dateComponents([.hour, .minute], from: date)
        return (value.hour ?? 0, value.minute ?? 0)
    }
    static func date(hour: Int, minute: Int, timezone: String, now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timezone) ?? .current
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
    }
}

struct AssistantRoutinesView: View {
    let design: LiveDesign
    let assistantName: String
    let actions: AssistantRoutineActions

    @State private var snapshot: AgentRoutinesSnapshot?
    @State private var loading = false
    @State private var failed = false
    @State private var appeared = false
    @State private var toggling: NativeID?
    @State private var listNotice: String?
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private let requestLedger = RoutineRequestLedger()
    /// Desktop `MAX_ROUTINES`: past this, the quota line replaces "+".
    static let maximumRoutines = 64

    var body: some View {
        Group {
            if snapshot == nil, !failed {
                ProgressView { Text(cardCopy.routine(.routineLoading)) }
                    .accessibilityIdentifier("assistant.routines.loading")
            } else if failed, snapshot == nil {
                ContentUnavailableView {
                    Label(cardCopy.routine(.routineLoadFailed, name: assistantName),
                          image: atum.symbol(.alertCircle))
                } actions: {
                    Button(copy(.retry)) { Task { await load() } }
                }
            } else if let snapshot {
                List {
                    if snapshot.legacyState == .unknown {
                        // Desktop says only "Getting ready…" here (`routinePreparing`).
                        ContentUnavailableView {
                            Label(cardCopy.routine(.routinePreparing), image: atum.symbol(.clock))
                        } actions: {
                            Button(copy(.retry)) { Task { await load() } }
                        }
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("assistant.routines.preparing")
                    } else if snapshot.legacyState == .present {
                        ContentUnavailableView {
                            Label(cardCopy.routine(.routineLegacyMoving), image: atum.symbol(.clock))
                        } description: {
                            Text(copy(.routineLegacyPending))
                        }
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("assistant.routines.legacy-pending")
                    } else if snapshot.routines.isEmpty {
                        ContentUnavailableView {
                            Label(copy(.routineEmpty), image: atum.symbol(.clock))
                        } actions: {
                            // Desktop's one suggestion: a routine already
                            // written, for the person to adjust and save.
                            NavigationLink {
                                AssistantRoutineEditor(
                                    design: design, actions: actions, routine: nil,
                                    seedInstruction: cardCopy.polish(.routineSuggestBriefInstruction),
                                    onChanged: apply)
                            } label: {
                                Text(cardCopy.polish(.routineSuggestBrief))
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("assistant.routines.suggest-brief")
                        }
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("assistant.routines.empty")
                    } else {
                        Section {
                            ForEach(snapshot.routines) { routine in
                                if routine.schedule.isReadOnly {
                                    routineRow(routine, isReadOnly: true)
                                        .accessibilityIdentifier("assistant.routine.\(routine.id.rawValue)")
                                } else {
                                    NavigationLink {
                                        AssistantRoutineEditor(design: design, actions: actions, routine: routine,
                                                               onChanged: apply)
                                    } label: {
                                        routineRow(routine)
                                    }
                                    .accessibilityIdentifier("assistant.routine.\(routine.id.rawValue)")
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        pauseButton(routine)
                                    }
                                    .contextMenu { pauseButton(routine) }
                                }
                            }
                        } footer: {
                            VStack(alignment: .leading, spacing: 6) {
                                if let listNotice {
                                    Text(verbatim: listNotice)
                                        .foregroundStyle(atum.color(.danger, scheme: scheme))
                                        .accessibilityIdentifier("assistant.routines.notice")
                                }
                                if snapshot.routines.count >= Self.maximumRoutines {
                                    Text(cardCopy.polish(.routineQuotaReached, [String(Self.maximumRoutines)]))
                                        .accessibilityIdentifier("assistant.routines.quota")
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await load() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(atum.color(.ground, scheme: scheme))
        .navigationTitle(copy(.routines))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let snapshot, snapshot.legacyState == .clear,
               snapshot.routines.count < Self.maximumRoutines, !loading {
                ToolbarItem(placement: .confirmationAction) {
                    NavigationLink {
                        AssistantRoutineEditor(design: design, actions: actions, routine: nil,
                                               onChanged: apply)
                    } label: {
                        atum.barIcon(.plus)
                    }
                    .accessibilityLabel(copy(.addRoutine))
                    .accessibilityIdentifier("assistant.routines.add")
                }
            }
        }
        .task { if snapshot == nil, !loading { await load() } }
        .onAppear {
            if appeared, !loading { Task { await load() } }
            else { appeared = true }
        }
    }

    /// Desktop's row (`routines-panel.tsx:740-790`): the name, the schedule
    /// in words, then the next run (the zone only when it is not this
    /// device's) or "Paused". The raw IANA zone is no longer a caption (D-11).
    private func routineRow(_ routine: AgentRoutine, isReadOnly: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: routine.title).font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: cardCopy.scheduleWords(routine))
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("assistant.routine.\(routine.id.rawValue).schedule")
            HStack(spacing: 6) {
                Text(verbatim: cardCopy.nextWords(routine) ?? copy(.routinePaused))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("assistant.routine.\(routine.id.rawValue).next")
                if toggling == routine.id { ProgressView().controlSize(.mini) }
            }
            if isReadOnly {
                Text(cardCopy.routine(.routineReadOnly))
                    .font(.caption)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .accessibilityIdentifier("assistant.routine.\(routine.id.rawValue).read-only")
            }
        }
        .padding(.vertical, 4)
    }

    @MainActor private func load() async {
        loading = true; failed = false
        let result = await actions.read()
        guard !Task.isCancelled else { return }
        loading = false
        switch result { case let .value(value): apply(value); case .failed: failed = true }
    }
    private func apply(_ value: AgentRoutinesSnapshot) { snapshot = value; failed = false }

    /// Desktop's inline Pause / Resume, as a swipe (and the long-press menu,
    /// so it is reachable without the gesture).
    private func pauseButton(_ routine: AgentRoutine) -> some View {
        Button(routine.enabled ? copy(.routinePause) : copy(.routineResume)) {
            toggle(routine)
        }
        .tint(atum.color(.actionStrong, scheme: scheme))
        .disabled(toggling != nil)
        .accessibilityIdentifier("assistant.routine.\(routine.id.rawValue).toggle")
    }

    /// The same update the editor sends, with only `enabled` flipped. A
    /// conflict shows the routine as it now is and says so.
    private func toggle(_ routine: AgentRoutine) {
        guard toggling == nil, !routine.schedule.isReadOnly else { return }
        let key = requestLedger.key(scope: actions.scope, operation: "toggle",
                                    fingerprint: "\(routine.id.rawValue):\(routine.revision):\(!routine.enabled)")
        let requestID = requestLedger.requestID(for: key)
        toggling = routine.id
        listNotice = nil
        Task { @MainActor in
            defer { toggling = nil }
            let result: AssistantRoutineMutationResult
            do {
                result = await actions.update(try AgentRoutineUpdate(
                    requestId: requestID, routine: routine, title: routine.title,
                    instruction: routine.instruction, schedule: routine.schedule,
                    timezone: routine.timezone, enabled: !routine.enabled,
                    notifications: routine.notifications))
            } catch { result = .failed }
            switch result {
            case let .saved(value):
                requestLedger.clear(key)
                apply(value)
            case let .conflict(latest):
                requestLedger.clear(key)
                if let latest { apply(latest) }
                listNotice = copy(.routineConflict)
            case .failed:
                listNotice = copy(.saveFailed)
            }
        }
    }
    private func copy(_ key: AssistantCardCopyKey,
                      _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key.rawValue, arguments: arguments)
    }
    private var cardCopy: AssistantCardCopy { AssistantCardCopy(design: design) }
}

private struct AssistantRoutineEditor: View {
    let design: LiveDesign
    let actions: AssistantRoutineActions
    let onChanged: (AgentRoutinesSnapshot) -> Void

    @State private var base: AgentRoutine?
    @State private var title: String
    @State private var instruction: String
    @State private var kind: AgentRoutineSchedule.Kind
    @State private var onceDate: Date
    @State private var time: Date
    @State private var wallHour: Int
    @State private var wallMinute: Int
    @State private var weekdays: Set<Int>
    @State private var monthDay: Int
    @State private var timezone: String
    @State private var enabled: Bool
    @State private var notifications: Bool
    @State private var saving = false
    @State private var saveFailed = false
    @State private var conflict = false
    @State private var savedToken: String?
    @State private var pendingSaveID: NativeID?
    @State private var pendingSaveKey: String?
    @State private var running = false
    @State private var runFailed = false
    @State private var runRequestID: NativeID?
    @State private var runRequestKey: String?
    @State private var confirmsDelete = false
    @State private var deleting = false
    @State private var deleteFailed = false
    @State private var deleteRequestID: NativeID?
    @State private var deleteRequestKey: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }
    private let requestLedger = RoutineRequestLedger()

    init(design: LiveDesign, actions: AssistantRoutineActions, routine: AgentRoutine?,
         seedInstruction: String? = nil,
         onChanged: @escaping (AgentRoutinesSnapshot) -> Void) {
        self.design = design; self.actions = actions; self.onChanged = onChanged
        _base = State(initialValue: routine)
        _title = State(initialValue: routine?.title ?? "")
        _instruction = State(initialValue: routine?.instruction ?? seedInstruction ?? "")
        let zoneID = routine?.timezone ?? TimeZone.current.identifier
        let values = Self.values(routine?.schedule, timezone: zoneID)
        _kind = State(initialValue: values.kind)
        _onceDate = State(initialValue: values.onceDate)
        _time = State(initialValue: values.time)
        _wallHour = State(initialValue: values.hour)
        _wallMinute = State(initialValue: values.minute)
        _weekdays = State(initialValue: values.weekdays)
        _monthDay = State(initialValue: values.monthDay)
        _timezone = State(initialValue: zoneID)
        _enabled = State(initialValue: routine?.enabled ?? true)
        _notifications = State(initialValue: routine?.notifications ?? true)
    }

    var body: some View {
        Form {
            Section {
                // Desktop's dialog subtitle, then the name ("Leave empty to
                // use the first words") and the instruction.
                Text(cardCopy.polish(.routineDialogSubtitle))
                    .font(.footnote)
                    .foregroundStyle(atum.color(.muted, scheme: scheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("assistant.routine.subtitle")
                LabeledContent {
                    TextField(cardCopy.polish(.routineNamePlaceholder), text: $title, axis: .vertical)
                        .lineLimit(1...3)
                        .accessibilityIdentifier("assistant.routine.title")
                } label: {
                    Text(copy(.routineTitle))
                }
                .labeledContentStyle(AssistantRoutineStackedLabel())
                LabeledContent {
                    TextField(copy(.purposePlaceholder), text: $instruction, axis: .vertical)
                        .lineLimit(4...12)
                        .accessibilityIdentifier("assistant.routine.instruction")
                } label: {
                    Text(copy(.routineInstruction))
                }
                .labeledContentStyle(AssistantRoutineStackedLabel())
            }
            Section(copy(.routineSchedule)) {
                Picker(copy(.routineSchedule), selection: $kind) {
                    Text(copy(.routineOnce)).tag(AgentRoutineSchedule.Kind.once)
                    Text(copy(.routineDaily)).tag(AgentRoutineSchedule.Kind.daily)
                    Text(copy(.routineWeekly)).tag(AgentRoutineSchedule.Kind.weekly)
                    Text(copy(.routineMonthly)).tag(AgentRoutineSchedule.Kind.monthly)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("assistant.routine.schedule")
                scheduleFields
                NavigationLink {
                    AssistantRoutineTimezonePicker(design: design, timezone: $timezone)
                } label: {
                    LabeledContent(copy(.routineTimezone), value: timezone)
                }
                .accessibilityIdentifier("assistant.routine.timezone")
            }
            Section {
                Toggle(copy(.routineNotifications), isOn: $notifications)
                    .accessibilityIdentifier("assistant.routine.notifications")
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(copy(.routineEnabled))
                        Text(cardCopy.polish(.routineEnabledHint))
                            .font(.footnote)
                            .foregroundStyle(atum.color(.muted, scheme: scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityIdentifier("assistant.routine.enabled")
            }
            Section { status }
            if let base {
                Section {
                    // Desktop: with unsaved changes the same button saves
                    // them first ("Save & run now").
                    Button(canSave ? cardCopy.polish(.routineSaveAndRun) : copy(.routineRunNow)) {
                        if canSave { save(thenRun: true) } else { run(base) }
                    }
                    .disabled(running || saving || deleting)
                    .accessibilityIdentifier("assistant.routine.run")
                    NavigationLink {
                        AssistantRoutineRunsView(design: design, routine: base, actions: actions)
                    } label: {
                        Text(copy(.routineHistory))
                    }
                    .accessibilityIdentifier("assistant.routine.history")
                    Button(copy(.routineDelete, [.text(base.title)]), role: .destructive) {
                        confirmsDelete = true
                    }
                    .disabled(deleting || saving || running)
                    .accessibilityIdentifier("assistant.routine.delete")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(atum.color(.ground, scheme: scheme))
        .navigationTitle(base == nil ? copy(.addRoutine) : copy(.routines))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saving ? copy(.saving) : design.text("src.matrix.chat-copy.copies.save")) { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("assistant.routine.save")
            }
        }
        .confirmationDialog(base.map { copy(.routineDelete, [.text($0.title)]) } ?? copy(.routineDelete, [.text(title)]),
                            isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button(design.text("src.matrix.chat-copy.copies.delete"), role: .destructive) { deleteRoutine() }
            Button(design.text("src.matrix.chat-copy.copies.cancel"), role: .cancel) {}
        } message: { Text(copy(.routineDeleteBody)) }
        .onChange(of: draftToken) { _, _ in
            pendingSaveID = nil; pendingSaveKey = nil
            saveFailed = false; conflict = false; savedToken = nil
        }
        .onChange(of: time) { _, value in
            guard kind != .once else { return }
            let parts = RoutineWallClock.parts(value, timezone: timezone)
            wallHour = parts.hour
            wallMinute = parts.minute
        }
        .onChange(of: timezone) { _, value in
            guard kind != .once else { return }
            time = RoutineWallClock.date(hour: wallHour, minute: wallMinute, timezone: value)
        }
    }

    @ViewBuilder private var scheduleFields: some View {
        switch kind {
        case .once:
            DatePicker(copy(.routineDate), selection: $onceDate,
                       in: Date().addingTimeInterval(-60)..., displayedComponents: [.date, .hourAndMinute])
                .environment(\.timeZone, selectedTimeZone)
                .accessibilityIdentifier("assistant.routine.once")
        case .daily:
            DatePicker(copy(.routineTime), selection: $time, displayedComponents: .hourAndMinute)
                .environment(\.timeZone, selectedTimeZone)
                .accessibilityIdentifier("assistant.routine.time")
        case .weekly:
            DatePicker(copy(.routineTime), selection: $time, displayedComponents: .hourAndMinute)
                .environment(\.timeZone, selectedTimeZone)
            VStack(alignment: .leading, spacing: 8) {
                Text(copy(.routineWeekdays)).font(.footnote)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                    ForEach(1...7, id: \.self) { day in
                        Button(AssistantRoutineWords.weekdayChip(day, locale: design.locale)) {
                            if weekdays.contains(day) { weekdays.remove(day) } else { weekdays.insert(day) }
                        }
                        .buttonStyle(.bordered)
                        .tint(weekdays.contains(day) ? atum.color(.actionStrong, scheme: scheme) : atum.color(.muted, scheme: scheme))
                        .accessibilityAddTraits(weekdays.contains(day) ? .isSelected : [])
                    }
                }
            }
            .accessibilityIdentifier("assistant.routine.weekdays")
        case .monthly:
            DatePicker(copy(.routineTime), selection: $time, displayedComponents: .hourAndMinute)
                .environment(\.timeZone, selectedTimeZone)
            Picker(copy(.routineMonthDay), selection: $monthDay) {
                ForEach(1...28, id: \.self) { Text(verbatim: String($0)).tag($0) }
            }
            .accessibilityIdentifier("assistant.routine.month-day")
        }
    }

    @ViewBuilder private var status: some View {
        if savedToken == draftToken {
            Label(copy(.saved), image: atum.symbol(.checkCircle))
                .accessibilityIdentifier("assistant.routine.saved")
        }
        if conflict {
            VStack(alignment: .leading, spacing: 8) {
                Text(copy(.routineConflict)).foregroundStyle(atum.color(.danger, scheme: scheme))
                HStack {
                    if base != nil {
                        Button(design.text("desktop.atum.browser.reload")) { reloadDraft() }
                    }
                    Button(copy(.retry)) { save() }
                }
            }
            .accessibilityIdentifier("assistant.routine.conflict")
        } else if saveFailed || runFailed || deleteFailed {
            Text(copy(.saveFailed)).foregroundStyle(atum.color(.danger, scheme: scheme))
                .accessibilityIdentifier("assistant.routine.failure")
        }
    }

    private var schedule: AgentRoutineSchedule? {
        return switch kind {
        case .once: .once(runAt: onceDate)
        case .daily: .daily(hour: wallHour, minute: wallMinute)
        case .weekly where !weekdays.isEmpty: .weekly(hour: wallHour, minute: wallMinute, weekdays: weekdays.sorted())
        case .monthly: .monthly(day: monthDay, hour: wallHour, minute: wallMinute)
        default: nil
        }
    }
    private var selectedTimeZone: TimeZone { TimeZone(identifier: timezone) ?? .current }
    /// What the platform stores: the typed name, else the instruction's
    /// first words (desktop `routineTitleFor`).
    private var normalizedTitle: String {
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? AssistantRoutineWords.title(fromInstruction: instruction) : typed
    }
    private var normalizedInstruction: String { instruction.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        guard !saving, !running, !deleting, !normalizedTitle.isEmpty,
              normalizedTitle.unicodeScalars.count <= 120,
              !normalizedInstruction.isEmpty, normalizedInstruction.utf8.count <= 65_536,
              TimeZone(identifier: timezone) != nil, let schedule else { return false }
        if enabled, case let .once(runAt) = schedule, runAt < Date().addingTimeInterval(-30) { return false }
        if let base {
            return normalizedTitle != base.title || normalizedInstruction != base.instruction
                || schedule != base.schedule || timezone != base.timezone || enabled != base.enabled
                || notifications != base.notifications
        }
        return true
    }
    private var draftToken: String {
        let scheduleData = schedule.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        return [normalizedTitle, normalizedInstruction, scheduleData.base64EncodedString(), timezone,
                String(enabled), String(notifications)].joined(separator: "\u{0}")
    }

    private func save(thenRun: Bool = false) {
        guard let schedule else { return }
        let operation = base == nil ? "create" : "update"
        let key = requestLedger.key(scope: actions.scope, operation: operation, fingerprint: draftToken)
        let requestID = pendingSaveID ?? requestLedger.requestID(for: key)
        pendingSaveID = requestID; pendingSaveKey = key
        saving = true; saveFailed = false; conflict = false
        Task { @MainActor in
            let result: AssistantRoutineMutationResult
            do {
                if let base {
                    result = await actions.update(try AgentRoutineUpdate(
                        requestId: requestID, routine: base, title: normalizedTitle,
                        instruction: normalizedInstruction, schedule: schedule, timezone: timezone,
                        enabled: enabled, notifications: notifications))
                } else {
                    result = await actions.create(try AgentRoutineCreate(
                        requestId: requestID, title: normalizedTitle, instruction: normalizedInstruction,
                        schedule: schedule, timezone: timezone, enabled: enabled,
                        notifications: notifications))
                }
            } catch { result = .failed }
            guard !Task.isCancelled else { return }
            saving = false
            switch result {
            case let .saved(snapshot):
                onChanged(snapshot); requestLedger.clear(pendingSaveKey)
                pendingSaveID = nil; pendingSaveKey = nil
                if let current = base, let updated = snapshot.routines.first(where: { $0.id == current.id }) {
                    base = updated; savedToken = draftToken
                    if thenRun { run(updated) }
                } else { dismiss() }
            case let .conflict(latest):
                if let current = base, let updated = latest?.routines.first(where: { $0.id == current.id }) {
                    base = updated
                } else if let latest { onChanged(latest) }
                requestLedger.clear(pendingSaveKey)
                pendingSaveID = nil; pendingSaveKey = nil; conflict = true
            case .failed: saveFailed = true
            }
        }
    }

    private func run(_ routine: AgentRoutine) {
        let key = requestLedger.key(scope: actions.scope, operation: "run",
                                    fingerprint: "\(routine.id.rawValue):\(routine.revision)")
        let id = runRequestID ?? requestLedger.requestID(for: key)
        runRequestID = id; runRequestKey = key
        running = true; runFailed = false
        Task { @MainActor in
            let result = await actions.run(AgentRoutineAction(operation: .run, requestId: id, routine: routine))
            guard !Task.isCancelled else { return }
            running = false
            switch result {
            case let .saved(snapshot):
                onChanged(snapshot); requestLedger.clear(runRequestKey)
                runRequestID = nil; runRequestKey = nil
                base = snapshot.routines.first(where: { $0.id == routine.id }) ?? base
            case let .conflict(latest):
                if let updated = latest?.routines.first(where: { $0.id == routine.id }) { base = updated }
                requestLedger.clear(runRequestKey)
                runRequestID = nil; runRequestKey = nil; conflict = true
            case .failed: runFailed = true
            }
        }
    }

    private func deleteRoutine() {
        guard let routine = base else { return }
        let key = requestLedger.key(scope: actions.scope, operation: "delete",
                                    fingerprint: "\(routine.id.rawValue):\(routine.revision)")
        let id = deleteRequestID ?? requestLedger.requestID(for: key)
        deleteRequestID = id; deleteRequestKey = key
        deleting = true; deleteFailed = false
        Task { @MainActor in
            let result = await actions.delete(AgentRoutineAction(operation: .delete, requestId: id, routine: routine))
            guard !Task.isCancelled else { return }
            deleting = false
            switch result {
            case let .saved(snapshot):
                requestLedger.clear(deleteRequestKey)
                deleteRequestID = nil
                deleteRequestKey = nil
                onChanged(snapshot); dismiss()
            case let .conflict(latest):
                if let updated = latest?.routines.first(where: { $0.id == routine.id }) { base = updated }
                requestLedger.clear(deleteRequestKey)
                deleteRequestID = nil; deleteRequestKey = nil; conflict = true
            case .failed: deleteFailed = true
            }
        }
    }

    private func reloadDraft() {
        guard let base else { return }
        title = base.title; instruction = base.instruction; timezone = base.timezone
        enabled = base.enabled; notifications = base.notifications
        let values = Self.values(base.schedule, timezone: base.timezone)
        kind = values.kind; onceDate = values.onceDate; time = values.time
        wallHour = values.hour; wallMinute = values.minute
        weekdays = values.weekdays; monthDay = values.monthDay
        conflict = false
    }

    private static func values(_ schedule: AgentRoutineSchedule?, timezone: String) ->
        (kind: AgentRoutineSchedule.Kind, onceDate: Date, time: Date, hour: Int, minute: Int,
         weekdays: Set<Int>, monthDay: Int) {
        let fallback = Date().addingTimeInterval(3_600)
        switch schedule {
        case let .once(runAt): return (.once, runAt, runAt, 0, 0, [1, 2, 3, 4, 5], 1)
        case let .daily(hour, minute): return (.daily, fallback, RoutineWallClock.date(hour:hour,minute:minute,timezone:timezone), hour, minute, [1, 2, 3, 4, 5], 1)
        case let .weekly(hour, minute, weekdays): return (.weekly, fallback, RoutineWallClock.date(hour:hour,minute:minute,timezone:timezone), hour, minute, Set(weekdays), 1)
        case let .monthly(day, hour, minute): return (.monthly, fallback, RoutineWallClock.date(hour:hour,minute:minute,timezone:timezone), hour, minute, [1, 2, 3, 4, 5], day)
        case .unsupported, nil:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timezone) ?? .current
            let parts = calendar.dateComponents([.hour, .minute], from: fallback)
            return (.daily, fallback, fallback, parts.hour ?? 0, parts.minute ?? 0, [1, 2, 3, 4, 5], 1)
        }
    }
    private func copy(_ key: AssistantCardCopyKey,
                      _ arguments: [AtumCopy.Argument] = []) -> String {
        design.text(key.rawValue, arguments: arguments)
    }
    private var cardCopy: AssistantCardCopy { AssistantCardCopy(design: design) }
}

/// A form field with its label above it, so a long label and a long
/// placeholder both wrap at the largest text sizes instead of clipping.
private struct AssistantRoutineStackedLabel: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            configuration.label
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            configuration.content
        }
    }
}

private struct AssistantRoutineTimezonePicker: View {
    let design: LiveDesign
    @Binding var timezone: String
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(filtered, id: \.self) { value in
            Button {
                timezone = value; dismiss()
            } label: {
                HStack {
                    Text(verbatim: value)
                    Spacer()
                    if value == timezone { Image(design.symbol("Check")) }
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle(design.text(AssistantCardCopyKey.routineTimezone.rawValue))
        .navigationBarTitleDisplayMode(.inline)
    }
    private var filtered: [String] {
        let values = TimeZone.knownTimeZoneIdentifiers
        guard !query.isEmpty else { return values }
        return values.filter { $0.localizedCaseInsensitiveContains(query) }
    }
}

private struct AssistantRoutineRunsView: View {
    let design: LiveDesign
    let routine: AgentRoutine
    let actions: AssistantRoutineActions
    @State private var snapshot: AgentRoutineRunsSnapshot?
    @State private var failed = false

    var body: some View {
        Group {
            if let snapshot {
                if snapshot.runs.isEmpty {
                    ContentUnavailableView(copy(.routineRunsEmpty), image: design.symbol("History"))
                } else {
                    List(snapshot.runs) { run in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state(run))
                            Text(date(run.scheduledAt)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if failed {
                ContentUnavailableView {
                    Label(copy(.saveFailed), image: design.symbol("AlertCircle"))
                } actions: { Button(copy(.retry)) { Task { await load() } } }
            } else { ProgressView() }
        }
        .navigationTitle(copy(.routineHistory))
        .navigationBarTitleDisplayMode(.inline)
        .task { if snapshot == nil { await load() } }
    }
    @MainActor private func load() async {
        failed = false
        switch await actions.runs(routine.id) {
        case let .value(value): snapshot = value
        case .failed: failed = true
        }
    }
    private func state(_ run: AgentRoutineRun) -> String {
        switch run.outcome {
        case .answered?: copy(.routineCompleted)
        case .stopped?: copy(.routineStopped)
        case .failed?, .uncertain?: copy(.routineFailed)
        case nil where run.state == .skipped: copy(.routineSkipped)
        case nil where run.state == .completed: copy(.routineFailed)
        default: copy(.routineWaiting)
        }
    }
    private func date(_ milliseconds: Int64) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: design.locale)
        formatter.timeZone = TimeZone(identifier: routine.timezone)
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
    private func copy(_ key: AssistantCardCopyKey) -> String { design.text(key.rawValue) }
}
