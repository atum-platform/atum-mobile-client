import Foundation

/// The agent's desk (atum-desktop PR #51, `src/matrix/agent-desk-model.ts`):
/// what the side panel's own page says about the agent of this 1:1 chat, read
/// only from what the chat already shows. Presentation only: nothing here is
/// execution authority, and Now never disagrees with the chat, because it
/// reads the chat's own working footer.
public enum AgentDeskPolicy {
    /// Now: free (the desk says nothing at all), working with the working
    /// line's own words, or waiting while the native turn waits on the owner
    /// (its progress marker in phase `waiting`, e.g. an approval). Desktop's
    /// open asks and On your device come from signals the phone's panel does
    /// not receive; they are not guessed here.
    public enum Now: Equatable, Sendable {
        case free
        case working(since: Date?, line: String?, steps: [WorkingLineText.Step])
        case waiting(since: Date?, line: String?)
    }

    /// How many sent files the desk's Files section shows (`MATRIX_AGENT_DESK_FILES_MAX`).
    public static let sentFilesMaximum = 4

    /// Working while the chat shows its working footer (typing or a live
    /// working line). Its words are the transcript's own (`WorkingLineRow`):
    /// a coded status reads through `exported`, the same lookup the chat uses.
    /// Since: the question it answers, i.e. the newest own message before the
    /// footer, else unknown (the head then says only the state).
    public static func now(rows: [ChatRow], exported: (String, Int?) -> String? = { _, _ in nil }) -> Now {
        guard let footer = rows.last(where: { if case .typing = $0.item.kind { true } else { false } }) else {
            return .free
        }
        let progress = footer.item.progress
        let asked = rows.last(where: { $0.item.isOwn && $0.item.kind.isEventContent })?.item.timestamp
        // A heartbeat says only that it is still at it (desktop drops its words).
        let parts: (current: String?, steps: [WorkingLineText.Step]) = progress?.kind == "heartbeat" ? (nil, [])
            : lineParts(WorkingLineText(body: footer.item.body, presentation: progress?.presentation,
                                        exported: exported))
        if progress?.phase == .waiting {
            return .waiting(since: asked, line: parts.current)
        }
        return .working(since: asked, line: parts.current, steps: parts.steps)
    }

    /// Desktop `matrixProgressLineParts`: a native Hermes todo list has only
    /// marked lines; then every line is a step and there is no headline.
    static func lineParts(_ text: WorkingLineText) -> (current: String?, steps: [WorkingLineText.Step]) {
        guard let current = text.current, let first = current.unicodeScalars.first,
              "✓✔•◦".unicodeScalars.contains(first) else { return (text.current, text.steps) }
        let done = first == "✓" || first == "✔"
        let step = current.replacingOccurrences(of: "^[✓✔•◦]\\s*", with: "", options: .regularExpression)
        return (nil, [WorkingLineText.Step(text: step, done: done)] + text.steps)
    }

    /// Whole minutes since `since`, or nil under one (desktop `matrixAgentDeskMinutes`).
    public static func minutes(since: Date?, now: Date) -> Int? {
        guard let since else { return nil }
        let elapsed = now.timeIntervalSince(since)
        guard elapsed.isFinite, elapsed >= 60 else { return nil }
        return Int(elapsed / 60)
    }

    /// The files the agent itself sent in this chat, newest first: only the
    /// agent's own, live, delivered file or image events with media; never the
    /// owner's, a stranger's, a deleted or an undecryptable one
    /// (desktop `matrixAgentDeskSentFiles`).
    public static func sentFiles(rows: [ChatRow], agentUserID: String?) -> [ChatItem] {
        guard let agentUserID, !agentUserID.isEmpty else { return [] }
        var files: [ChatItem] = []
        for row in rows.reversed() where files.count < sentFilesMaximum {
            let item = row.item
            guard item.sender == agentUserID, !item.isOwn, !item.isLocalEcho, item.media != nil else { continue }
            switch item.kind {
            case .file, .image: files.append(item)
            default: continue
            }
        }
        return files
    }
}

/// The bell in Home's header (atum-desktop PR #48, `attention-indicator.tsx`
/// over `agent-attention.ts`): quiet while nothing needs the person, a small
/// badge while something does; it opens a short list, each item acting from
/// its own row. Only the causes the phone itself knows are listed; desktop's
/// Mac-only ones (disk, unlock, runtime update, this Mac's sign-in) never are.
public enum AttentionBellPolicy {
    /// In desktop's `ORDER`.
    public enum Kind: String, CaseIterable, Sendable {
        /// The native domain grant needs a new sign-in (`sign_in`).
        case signIn = "sign_in"
        /// A fresh wallet read with nothing left to spend (`protons`).
        case protons
    }

    public enum Tone: Equatable, Sendable { case warn, danger }

    public struct Input: Equatable, Sendable {
        public var signInRequired: Bool
        /// Spendable micro-Protons from a fresh read only; nil when unknown.
        public var freshSpendable: Int64?

        public init(signInRequired: Bool = false, freshSpendable: Int64? = nil) {
            self.signInRequired = signInRequired
            self.freshSpendable = freshSpendable
        }
    }

    public static func items(_ input: Input) -> [Kind] {
        Kind.allCases.filter { kind in
            switch kind {
            case .signIn: input.signInRequired
            case .protons: input.freshSpendable.map { $0 <= 0 } ?? false
            }
        }
    }

    /// Danger only for data or keys at risk; neither phone cause is.
    public static func tone(_ items: [Kind]) -> Tone? { items.isEmpty ? nil : .warn }

    /// The export key for one item's label (`copies.items.<kind>`).
    public static func labelKey(_ kind: Kind) -> String {
        "src.matrix.attention-copy.copies.items." + kind.rawValue
    }

    public static let notificationsKey = "src.matrix.attention-copy.copies.notifications"
    public static let nothingKey = "src.matrix.attention-copy.copies.nothing"
    public static let countKey = "src.matrix.attention-copy.copies.count"
    public static let prefixKey = "src.matrix.attention-copy.copies.a11yPrefix"
}
