#if DEBUG
import AtumChat
import AtumNativeAPI
import SwiftUI

/// Debug only (plan §2.10): `-AtumScripted <chat scenario>` opens the chat
/// on a `ScriptedTimelineSource` instead of signing in. The real store, core,
/// pipeline, transcript and rows run unchanged (`attach(source:)`); only the
/// timeline is synthetic. The chat is pushed on an empty root, as from Home,
/// so it has the system back button. Release builds compile none of this,
/// and the owner never passes launch arguments.
///
/// `-AtumScriptedStartAt <seconds since 1970>` holds the open until that wall
/// time, so a UI test knows the scenario's clock exactly (the simulator and
/// the test share the Mac's clock; app launch takes a few seconds).
///
/// `-AtumScriptedConnectionGlyph` shows B30's glyph, as when sync is offline
/// (no sync runs here); the live root sets it from the session's lifecycle.
struct ScriptedChatHost: View {
    let script: ScriptedScript

    @State private var store: LiveConversationStore
    @State private var path: [String]
    @State private var infoPinned = false
    @State private var infoMuted = false
    @State private var scriptedDefinition: AgentDefinitionSnapshot
    @State private var scriptedModels: ManagedModelSnapshot
    @State private var scriptedModelDestinations: ManagedModelDestinationSnapshot
    @State private var scriptedPresentation: AgentPresentationSnapshot
    @State private var scriptedRoutines: AgentRoutinesSnapshot
    @State private var scriptedOpeningPhase: AppBotRoomOpeningPhase?
    @Environment(\.colorScheme) private var scheme
    private let design: LiveDesign

    init(script: ScriptedScript) {
        self.script = script
        let design = try! LiveDesign()
        self.design = design
        let info = ConversationRoomInfo(roomID: script.name, title: script.title, context: script.context,
                                        knownNames: script.names,
                                        catalogBotUserIDs: [ScriptedCast.moon, ScriptedCast.andy],
                                        languageCode: design.locale,
                                        roomIsEncrypted: false)
        let store = LiveConversationStore(info: info, history: .onScroll)
        // The scripted cast stands in for the room's joined members, so the
        // composer's `@` picker has people to offer.
        if ComposerRules.offersMentions(kind: script.context.kind) {
            store.setMentionCandidates(MentionRules.candidates(
                members: script.names.map { (userID: $0.key, displayName: $0.value) },
                ownUserID: script.context.ownUserID))
        }
        _store = State(initialValue: store)
        _path = State(initialValue: [script.name])
        _scriptedDefinition = State(initialValue: Self.definition(name: script.title))
        _scriptedModels = State(initialValue: Self.models())
        _scriptedModelDestinations = State(initialValue: Self.modelDestinations())
        _scriptedPresentation = State(initialValue: Self.presentation())
        _scriptedRoutines = State(initialValue: Self.routines())
        let joining = script.name == ScriptedScenario.botMoonRoomJoin.rawValue
            || script.name == ScriptedScenario.botMoonRoomJoinFails.rawValue
        _scriptedOpeningPhase = State(initialValue: joining ? .joining : nil)
    }

    /// As Home would show the chat: the scripted assistant is the default
    /// agent, Atum (the eclipse). A catalog bot's avatar is a remote image,
    /// which a scripted run does not fetch, so bots and people show their
    /// monogram here.
    static func avatar(for script: ScriptedScript) -> LiveProductAvatar? {
        script.context.kind == .assistant ? .eclipse : nil
    }

    static let connectionGlyphFlag = "-AtumScriptedConnectionGlyph"
    /// Shows a group chat as a team space channel (flat runs) for captures.
    static let teamChannelFlag = "-AtumScriptedTeamChannel"
    private static let isTeamChannel = ProcessInfo.processInfo.arguments.contains(teamChannelFlag)
    private static let showsConnectionGlyph = ProcessInfo.processInfo.arguments.contains(connectionGlyphFlag)
    private static let pinsAreFull = ProcessInfo.processInfo.arguments
        .contains(AtumLaunchArguments.scriptedPinsFullFlag)

    private static let startAt: Date? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AtumScriptedStartAt"), index + 1 < arguments.count,
              let seconds = TimeInterval(arguments[index + 1]) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }()

    var body: some View {
        NavigationStack(path: $path) {
            design.color("ground", scheme: scheme)
                .ignoresSafeArea()
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: String.self) { _ in
                    if let phase = scriptedOpeningPhase, let app = scriptedAppBot {
                        AppBotRoomOpeningView(
                            opening: AppBotRoomOpening(roomID: script.name, app: app, phase: phase),
                            design: design,
                            retry: { scriptedOpeningPhase = .joining }
                        )
                    } else {
                        ChatScreen(
                            store: store, design: design, avatar: Self.avatar(for: script),
                            info: chatInfo,
                            teamSpaceChat: Self.isTeamChannel,
                            infoActions: ChatInfoActions(
                                setPinned: { _, value in infoPinned = value },
                                setMuted: { _, value in infoMuted = value },
                                deleteAppRoom: { _ in path = [] },
                                assistantDefinition: script.context.kind == .assistant
                                    ? AssistantDefinitionActions(
                                        read: { .value(scriptedDefinition) },
                                        save: { _, definition in
                                            scriptedDefinition = Self.definition(
                                                name: script.title,
                                                soul: definition.soul,
                                                revision: Int(scriptedDefinition.definitionRevision + 1)
                                            )
                                            return .saved(scriptedDefinition)
                                        },
                                        rename: { snapshot, name in
                                            scriptedDefinition = Self.definition(
                                                name: name,
                                                soul: snapshot.definition?.soul,
                                                revision: Int(snapshot.definitionRevision + 1)
                                            )
                                            return .renamed(scriptedDefinition)
                                        }
                                    ) : nil,
                                assistantModels: script.context.kind == .assistant
                                    ? AssistantModelActions(
                                        matrixAccountID: script.context.ownUserID,
                                        read: { .value(scriptedModels) },
                                        save: { _, model, effort, _ in
                                            scriptedModels = Self.models(model: model, effort: effort,
                                                                          revision: Int(scriptedModels.revision + 1))
                                            UITestProbe.append(
                                                "saved \(model) \(scriptedModels.revision) \(effort.rawValue)",
                                                to: "model-choice.txt"
                                            )
                                            return .saved(scriptedModels)
                                        }
                                    ) : nil,
                                assistantModelDestinations: script.context.kind == .assistant
                                    ? AssistantModelDestinationActions(
                                        matrixAccountID: script.context.ownUserID,
                                        read: {
                                            .value(AssistantModelDestinationValue(
                                                snapshot: scriptedModelDestinations,
                                                cloudEligibleAliases: Set(ManagedModelLineup.servedAliases)
                                            ))
                                        },
                                        save: { _, destination, model, _ in
                                            scriptedModelDestinations = Self.modelDestinations(
                                                destination: destination,
                                                model: model,
                                                revision: Int(scriptedModelDestinations.revision + 1)
                                            )
                                            return .saved(scriptedModelDestinations)
                                        }
                                    ) : nil,
                                assistantPresentation: script.context.kind == .assistant
                                    ? AssistantPresentationActions(
                                        read: { .value(scriptedPresentation) },
                                        save: { _, title, mark in
                                            scriptedPresentation = Self.presentation(
                                                title: title, mark: mark,
                                                revision: scriptedPresentation.identityRevision + 1
                                            )
                                            return .saved(scriptedPresentation)
                                        }
                                    ) : nil,
                                assistantRoutines: script.context.kind == .assistant
                                    ? AssistantRoutineActions(
                                        scope: "14600000-0000-4000-8000-0000000000a2",
                                        read: { .value(scriptedRoutines) },
                                        create: { value in
                                            let row = Self.routine(
                                                id: "22800000-0000-4000-8000-000000000005",
                                                title: value.title, instruction: value.instruction,
                                                schedule: value.schedule, timezone: value.timezone,
                                                enabled: value.enabled, notifications: value.notifications,
                                                revision: 1
                                            )
                                            scriptedRoutines = Self.routines(rows: scriptedRoutines.routines + [row])
                                            return .saved(scriptedRoutines)
                                        },
                                        update: { value in
                                            let row = Self.routine(
                                                id: value.routineId.rawValue, title: value.title,
                                                instruction: value.instruction, schedule: value.schedule,
                                                timezone: value.timezone, enabled: value.enabled,
                                                notifications: value.notifications,
                                                revision: value.expectedRevision + 1
                                            )
                                            scriptedRoutines = Self.routines(rows: scriptedRoutines.routines.map {
                                                $0.id == value.routineId ? row : $0
                                            })
                                            return .saved(scriptedRoutines)
                                        },
                                        run: { _ in .saved(scriptedRoutines) },
                                        delete: { value in
                                            scriptedRoutines = Self.routines(rows: scriptedRoutines.routines.filter {
                                                $0.id != value.routineId
                                            })
                                            return .saved(scriptedRoutines)
                                        },
                                        runs: { id in .value(Self.runs(id)) }
                                    ) : nil
                            ),
                            appBot: scriptedAppBot,
                            appBotCatalog: scriptedAppBotCatalog,
                            mediaAccess: ScriptedMediaAccess.access
                        )
                    }
                }
        }
        .atumDesign(design)
        .environment(\.showsConnectionGlyph, Self.showsConnectionGlyph)
        .foregroundStyle(design.color("ink", scheme: scheme))
        .tint(design.color("ink", scheme: scheme))
        .task {
            if let startAt = Self.startAt, startAt > Date() {
                try? await Task.sleep(for: .seconds(startAt.timeIntervalSinceNow))
            }
            guard let scripted = AtumScriptedLaunch.makeChatSource() else { return }
            seedWave2State()
            if script.name == ScriptedScenario.botMoonRoomJoin.rawValue {
                try? await Task.sleep(for: .seconds(3))
                scriptedOpeningPhase = nil
            } else if script.name == ScriptedScenario.botMoonRoomJoinFails.rawValue {
                try? await Task.sleep(for: .seconds(3))
                scriptedOpeningPhase = .failed
            }
            let source: any ChatTimelineSource = UITestProbe.folder != nil || UITestProbe.lateDetails
                ? ScriptedSourceProbe(inner: scripted, lateDetails: UITestProbe.lateDetails)
                : scripted
            UITestProbe.append("source-start", to: "clock.txt")
            await store.attach(source: source)
        }
    }

    private func seedWave2State() {
        if script.name == ScriptedScenario.chatMediaSend.rawValue,
           store.mediaComposer.items.isEmpty {
            store.mediaComposer.restore(ScriptedMediaAccess.stagedAttachments())
            store.draft = "Chú thích cho ảnh đầu tiên"
        } else if script.name == ScriptedScenario.chatMediaRefusal.rawValue {
            let arguments = ProcessInfo.processInfo.arguments
            let value = arguments.firstIndex(of: AtumLaunchArguments.scriptedMediaRefusalFlag).flatMap { index in
                index + 1 < arguments.count ? arguments[index + 1] : nil
            }
            let refusal: MediaAttachmentRefusal = switch value {
            case "tooLargeFile": .tooLargeFile
            case "tooLargeSome": .tooLargeSome(count: 2)
            case "unreadable": .unreadable
            default: .tooMany(limit: MediaAttachmentPolicy.maximumItems)
            }
            store.mediaComposer.showScriptedRefusal(refusal)
        }
    }

    private var scriptedAppBot: AppBotPresentation? {
        guard script.context.kind == .appBot else { return nil }
        let fallback: String? = if ProcessInfo.processInfo.arguments
            .contains(AtumLaunchArguments.scriptedMissingAccentFlag) {
            nil
        } else if script.name == ScriptedScenario.botAccentFallback.rawValue {
            "#6a4bbc"
        } else {
            "#D8612F"
        }
        return AppBotPresentation(
            appID: ScriptedCast.moonAppID,
            slug: "moon",
            botUserID: ScriptedCast.moon,
            name: "Moon",
            subtitle: "Lắng nghe và cùng bạn nhìn lại hôm nay.",
            avatarURL: URL(string: "https://example.test/moon.png")!,
            avatarSHA256: String(repeating: "0", count: 64),
            accentHex: fallback,
            verification: .official,
            purchaseRouteID: "purchase",
            setupComplete: false
        )
    }

    private var scriptedAppBotCatalog: AppBotCatalogPresentation {
        guard let app = scriptedAppBot else { return .empty }
        return AppBotCatalogPresentation(appsByBotUserID: [app.botUserID: app],
                                         roomIDBySlug: [app.slug: script.name])
    }

    private var chatInfo: ChatInfoPresentation {
        let kind: ChatInfoPresentation.Kind = switch script.context.kind {
        case .assistant: .assistant
        case .appBot: .app(.official)
        case .person: .person
        case .group: .group(memberCount: scriptedMembers.count)
        }
        return ChatInfoPresentation(
            roomID: script.name, title: script.title,
            subtitle: script.context.kind == .assistant ? scriptedPresentation.title : nil,
            kind: kind,
            avatar: scriptedAppBot.map { .photo(url: $0.avatarURL, fallback: $0.name) }
                ?? Self.avatar(for: script),
            avatarSHA256: scriptedAppBot?.avatarSHA256,
            accent: scriptedAppBot?.brandAccentColor,
            isPinned: infoPinned,
            isMuted: infoMuted, roomIsEncrypted: store.roomIsEncrypted != false,
            pinLimitReached: !infoPinned && Self.pinsAreFull,
            members: scriptedMembers,
            isPrimaryAssistant: script.context.kind == .assistant,
            botHandle: script.context.kind == .assistant ? "atum" : nil
        )
    }

    private var scriptedMembers: [ChatInfoMember] {
        guard script.context.kind == .group else { return [] }
        let userIDs = [ScriptedCast.me, ScriptedCast.huy, ScriptedCast.lan, ScriptedCast.quan]
        return userIDs.map { userID in
            ChatInfoMember(userID: userID,
                           name: userID == ScriptedCast.me
                               ? "Minh"
                               : script.names[userID] ?? userID,
                           matrixAvatarURI: nil,
                           isAssistant: false,
                           isCurrentUser: userID == ScriptedCast.me)
        }
    }

    private static func definition(name: String,
                                   soul: String? = nil,
                                   revision: Int = 1) -> AgentDefinitionSnapshot {
        let value: [String: Any] = [
            "assistant": [
                "id": "14600000-0000-4000-8000-0000000000a2",
                "identity_id": "14600000-0000-4000-8000-0000000000a3",
                "principal": "14600000-0000-4000-8000-0000000000a1",
                "display_name": name,
                "slug": NSNull(),
                "avatar": "",
                "avatar_url": NSNull(),
                "is_default": false,
                "lifecycle_revision": 1,
                "identity_revision": 1,
                "definition_revision": revision,
                "status": "active",
            ],
            "definition": [
                "schema_version": 1,
                "soul": soul ?? "# \(name)\n\n## Who you are\n\nCalm.\n\n## What you do\n\nPlans and writes.",
                "model_alias": "binh-minh",
                "reasoning": NSNull(),
                "skills": [],
            ],
            "definition_revision": revision,
            "identity_revision": 1,
        ]
        let data = try! JSONSerialization.data(withJSONObject: value)
        return try! NativeAPI.decode(AgentDefinitionSnapshot.self, from: data)
    }

    private static func models(model: String = ManagedModelLineup.defaultAlias,
                               effort: ManagedModelEffort = .medium,
                               revision: Int = 1) -> ManagedModelSnapshot {
        let digest = String(repeating: "a", count: 64)
        func offer(_ alias: String, _ name: String) -> [String: Any] {
            [
                "alias": alias, "displayName": name,
                "providerModel": "provider/\(alias)",
                "contextBudget": 120_000, "outputBudget": 16_384,
                "efforts": ["low", "medium", "high"], "defaultEffort": "medium",
                "cost": ["currency": "USD", "inputPerMtok": "1.00",
                         "outputPerMtok": "2.00", "maxTurnMicroProtons": 10_000_000],
                "eligibility": ["state": "ready"],
                "inputModalities": ["text", "image"], "supportsTools": true,
            ]
        }
        let value: [String: Any] = [
            "profile": "atum.model-choice/1.1",
            "agentPrincipal": "14600000-0000-4000-8000-0000000000a1",
            "revision": revision, "source": "saved",
            "policyVersion": "2026-10-17.1", "policyDigest": digest,
            "choice": ["v": 2, "source": "atum", "model": model, "effort": effort.rawValue],
            "models": [
                offer(ManagedModelLineup.defaultAlias, "Nguyệt Thực 1.3"),
                offer(ManagedModelLineup.hardAlias, "Nhật Thực 1.1"),
            ],
            "runtimes": [["runtime": "cloud"]],
            "grant": [
                "profile": "atum.model-grant/1", "state": "active", "alias": model,
                "model": model, "effort": effort.rawValue, "policyDigest": digest,
                "contextBudget": 120_000, "outputBudget": 16_384,
                "maxTurnMicroProtons": 10_000_000,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: value)
        return try! NativeAPI.decode(ManagedModelSnapshot.self, from: data)
    }

    private static func modelDestinations(
        destination changed: ManagedModelDestinationID? = nil,
        model changedModel: String? = nil,
        revision: Int = 3
    ) -> ManagedModelDestinationSnapshot {
        var choices: [[String: Any]] = [
            ["destination": "cloud", "source": "atum",
             "model": ManagedModelLineup.defaultAlias, "effort": "medium"],
            ["destination": "mac:mini-b", "source": "atum",
             "model": ManagedModelLineup.hardAlias, "effort": "medium"],
            ["destination": "mac:book-a", "source": "own_key:openrouter",
             "model": "openai/gpt-6.1-sol", "effort": "high"],
        ]
        if let changed, let changedModel {
            if let index = choices.firstIndex(where: { ($0["destination"] as? String) == changed.rawValue }) {
                choices[index]["source"] = "atum"
                choices[index]["model"] = changedModel
                choices[index]["effort"] = "medium"
            } else {
                choices.append(["destination": changed.rawValue, "source": "atum",
                                "model": changedModel, "effort": "medium"])
            }
        }
        let value: [String: Any] = [
            "profile": "atum.model-choice/1.3",
            "agentPrincipal": "14600000-0000-4000-8000-0000000000a1",
            "revision": revision,
            "policyDigest": String(repeating: "a", count: 64),
            "recommended": ["source": "atum", "model": ManagedModelLineup.defaultAlias,
                            "effort": "medium"],
            "choices": choices,
            "dailyCap": ["dailyProtons": 200_000, "timeZone": "Asia/Ho_Chi_Minh",
                         "warningPercent": 80, "counts": "atum_billed_only"],
            "spend": ["day": "2026-10-20", "usedProtons": 42_000,
                      "state": "normal", "notice": "none"],
        ]
        let data = try! JSONSerialization.data(withJSONObject: value)
        return try! NativeAPI.decode(ManagedModelDestinationSnapshot.self, from: data)
    }

    private static func presentation(title: String? = nil,
                                     mark: AgentMark = AgentMark(shape: .spark, color: .violet),
                                     revision: Int64 = 1) -> AgentPresentationSnapshot {
        let value: [String: Any] = [
            "profile": "atum.agent-presentation/1",
            "assistant_id": "14600000-0000-4000-8000-0000000000a2",
            "assistant_principal": "14600000-0000-4000-8000-0000000000a1",
            "title": title ?? NSNull(),
            "mark": ["shape": mark.shape.rawValue, "color": mark.color.rawValue],
            "default_mark": ["shape": "circle", "color": "blue"],
            "avatar_url": NSNull(),
            "identity_revision": revision,
        ]
        let data = try! JSONSerialization.data(withJSONObject: value)
        return try! NativeAPI.decode(AgentPresentationSnapshot.self, from: data)
    }

    private static func routine(
        id: String = "22800000-0000-4000-8000-000000000003",
        title: String = "Morning brief",
        instruction: String = "Summarize my priorities.",
        schedule: AgentRoutineSchedule = .daily(hour: 8, minute: 30),
        timezone: String = "Asia/Ho_Chi_Minh",
        enabled: Bool = true,
        notifications: Bool = true,
        revision: Int64 = 1
    ) -> AgentRoutine {
        let scheduleObject = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(schedule))
        let value: [String: Any] = [
            "id": id, "title": title, "instruction": instruction,
            "schedule": scheduleObject, "timezone": timezone, "enabled": enabled,
            "notifications": notifications, "revision": revision,
            "nextRunAt": enabled ? Int64(Date().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000) : NSNull(),
            "lastRun": NSNull(),
        ]
        let data = try! JSONSerialization.data(withJSONObject: value)
        return try! NativeAPI.decode(AgentRoutine.self, from: data)
    }

    private static func routines(rows: [AgentRoutine] = [routine()]) -> AgentRoutinesSnapshot {
        let values = rows.map { try! JSONSerialization.jsonObject(with: JSONEncoder().encode(EncodableRoutine($0))) }
        let value: [String: Any] = [
            "profile": "atum.agent-routines/1",
            "assistantId": "14600000-0000-4000-8000-0000000000a2",
            "assistantPrincipal": "14600000-0000-4000-8000-0000000000a1",
            "serverTime": Int64(Date().timeIntervalSince1970 * 1_000),
            "legacyState": "clear",
            "routines": values,
        ]
        let data = try! JSONSerialization.data(withJSONObject: value)
        return try! NativeAPI.decode(AgentRoutinesSnapshot.self, from: data)
    }

    private static func runs(_ routineID: NativeID) -> AgentRoutineRunsSnapshot {
        let value: [String: Any] = [
            "profile": "atum.agent-routine-runs/1", "routineId": routineID.rawValue,
            "runs": [[
                "occurrenceId": "22800000-0000-4000-8000-000000000004",
                "scheduledAt": Int64(Date().addingTimeInterval(-3_600).timeIntervalSince1970 * 1_000),
                "state": "completed", "outcome": "answered",
            ]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: value)
        return try! NativeAPI.decode(AgentRoutineRunsSnapshot.self, from: data)
    }
}

private struct EncodableRoutine: Encodable {
    let value: AgentRoutine
    init(_ value: AgentRoutine) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(value.id, forKey: .id); try c.encode(value.title, forKey: .title)
        try c.encode(value.instruction, forKey: .instruction); try c.encode(value.schedule, forKey: .schedule)
        try c.encode(value.timezone, forKey: .timezone); try c.encode(value.enabled, forKey: .enabled)
        try c.encode(value.notifications, forKey: .notifications); try c.encode(value.revision, forKey: .revision)
        try c.encodeIfPresent(value.nextRunAt, forKey: .nextRunAt)
        if value.nextRunAt == nil { try c.encodeNil(forKey: .nextRunAt) }
        try c.encodeNil(forKey: .lastRun)
    }
    enum Keys: String, CodingKey { case id, title, instruction, schedule, timezone, enabled, notifications, revision, nextRunAt, lastRun }
}

/// Debug only: what the app did that the screen cannot show, for the UI
/// tests (receipts, how each hold of the row being read landed). Written
/// only with `-AtumUITestProbeDir <folder on the Mac>`, which a UI test
/// passes (the simulator shares the Mac's file system); one line per event,
/// wall-clock seconds first.
enum UITestProbe {
    static let folder: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-AtumUITestProbeDir"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }()

    /// `-AtumScriptedLateDetails`: the quotes of each older page arrive
    /// late, as the SDK delivers them (`ScriptedSourceProbe`).
    static let lateDetails = ProcessInfo.processInfo.arguments.contains("-AtumScriptedLateDetails")

    static func append(_ line: String, to name: String) {
        guard let folder else { return }
        let data = Data((String(format: "%.3f ", Date().timeIntervalSince1970) + line + "\n").utf8)
        let file = folder.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }
}

/// Debug only: the scripted source as the UI tests need it.
/// - Every receipt the store sends goes to `receipts.txt` (scripted rooms
///   have no server, so nothing on screen shows it; B13).
/// - With `-AtumScriptedLateDetails`, the quotes in each older page arrive
///   the way the SDK delivers a page's reply details: pending first, ready
///   0.8 s later in `set` diffs, with a reaction landing on the page's
///   newest message at the same moment. Those rows sit above the row being
///   read and change height (B4, B5, G-scroll check 4).
actor ScriptedSourceProbe: ChatTimelineSource {
    nonisolated let outputs: AsyncStream<ChatTimelineOutput>
    private let continuation: AsyncStream<ChatTimelineOutput>.Continuation
    private let inner: any ChatTimelineSource
    private let lateDetails: Bool
    /// The items as the store has them, for the indices of later `set`s.
    private var buffer = TimelineBuffer()
    /// The reply details the store holds per item (a `set` without an entry
    /// would clear them).
    private var details: [String: ChatReplyDetails] = [:]
    private var relay: Task<Void, Never>?

    init(inner: any ChatTimelineSource, lateDetails: Bool) {
        self.inner = inner
        self.lateDetails = lateDetails
        (outputs, continuation) = AsyncStream.makeStream(of: ChatTimelineOutput.self)
    }

    func start() async {
        if relay == nil {
            relay = Task {
                for await output in inner.outputs { forward(output) }
                continuation.finish()
            }
        }
        await inner.start()
    }

    func stop() async {
        await inner.stop()
    }

    func send(text: String, replyTo eventID: String?) async throws { try await inner.send(text: text, replyTo: eventID) }
    /// The mention payload a send carries, written for the UI tests to read
    /// (`m.mentions.user_ids` and whether the pill HTML rode along).
    func send(text: String, replyTo eventID: String?, mentions: OutgoingMentions) async throws {
        UITestProbe.append("send mentions=\(mentions.userIDs.joined(separator: ",")) html=\(mentions.formattedHTML != nil)",
                           to: "chat-actions.txt")
        try await inner.send(text: text, replyTo: eventID, mentions: mentions)
    }
    func send(attachment: OutgoingChatAttachment, caption: String?, replyTo eventID: String?) async throws {
        try await inner.send(attachment: attachment, caption: caption, replyTo: eventID)
    }
    func edit(_ item: ChatEventRef, text: String) async throws { try await inner.edit(item, text: text) }
    func redact(_ item: ChatEventRef) async throws { try await inner.redact(item) }
    func toggleReaction(_ item: ChatEventRef, key: String) async throws { try await inner.toggleReaction(item, key: key) }
    func isSendQueueEnabled() async -> Bool { await inner.isSendQueueEnabled() }
    func enableSendQueue() async { await inner.enableSendQueue() }
    func retrySend(_ item: ChatEventRef) async throws { try await inner.retrySend(item) }
    func abortSend(_ item: ChatEventRef) async throws { try await inner.abortSend(item) }
    func paginateBackwards(numEvents: UInt16) async throws -> Bool { try await inner.paginateBackwards(numEvents: numEvents) }
    func fetchReplyDetails(eventID: String) async { await inner.fetchReplyDetails(eventID: eventID) }

    func sendReceipt(_ receipt: ChatReceipt) async throws {
        switch receipt {
        case .readPublic: UITestProbe.append("receipt readPublic", to: "receipts.txt")
        case .readPrivate: UITestProbe.append("receipt readPrivate", to: "receipts.txt")
        case .fullyRead: UITestProbe.append("receipt fullyRead", to: "receipts.txt")
        }
        try await inner.sendReceipt(receipt)
    }

    private func forward(_ output: ChatTimelineOutput) {
        guard lateDetails, case var .batch(batch) = output, batch.diffs.contains(where: Self.addsAtFront) else {
            return emit(output)
        }
        var late: [String: ChatReplyDetails] = [:]
        for (id, detail) in batch.replyDetails {
            guard case .ready = detail.state else { continue }
            late[id] = detail
            batch.replyDetails[id] = ChatReplyDetails(eventID: detail.eventID, state: .pending)
        }
        emit(.batch(batch))
        // The page's newest message: the one just above the row being read.
        let added = Set(batch.diffs.flatMap(\.carriedItems).filter { $0.kind.isEventContent }.map(\.id))
        let newest = buffer.items.last { added.contains($0.id) }?.id
        guard !late.isEmpty || newest != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            resolve(late, reactingTo: newest)
        }
    }

    /// The SDK's later `set`s: the same items, their quotes now ready, the
    /// newest one with a 👍 from the room's agent.
    private func resolve(_ late: [String: ChatReplyDetails], reactingTo newest: String?) {
        var diffs: [ChatDiff] = []
        var replyDetails: [String: ChatReplyDetails] = [:]
        for (index, item) in buffer.items.enumerated() where late[item.id] != nil || item.id == newest {
            var item = item
            if item.id == newest {
                item.reactions.append(ChatReaction(key: "👍", senderIDs: [ScriptedCast.atum]))
            }
            if let detail = late[item.id] ?? details[item.id] { replyDetails[item.id] = detail }
            diffs.append(.set(index: index, item: item))
        }
        guard !diffs.isEmpty else { return }
        emit(.batch(ChatTimelineBatch(diffs: diffs, replyDetails: replyDetails)))
    }

    private func emit(_ output: ChatTimelineOutput) {
        if case let .batch(batch) = output {
            _ = try? buffer.apply(batch.diffs)
            for item in batch.diffs.flatMap(\.carriedItems) { details[item.id] = batch.replyDetails[item.id] }
        }
        continuation.yield(output)
    }

    private static func addsAtFront(_ diff: ChatDiff) -> Bool {
        switch diff {
        case .pushFront: true
        case let .insert(index, _): index == 0
        default: false
        }
    }
}
#endif
