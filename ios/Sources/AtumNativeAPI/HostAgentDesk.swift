import Foundation

/// The agent's desk reads and controls on the Shell's host routes, as desktop
/// sends them (atum-desktop PR #51, `electron/matrix/device/host-desk.ts` and
/// `host-agent-control.ts`; platform `apps/shell/src/lib/host-desk.ts`).
///
/// - `POST /api/host/desk` `{agent, read, path?}`: one read-only, owner-scoped
///   view of a native Hermes agent's cloud home (its schedule, or one folder of
///   its files). Listing only, never file contents.
/// - `POST /api/host/agent-control` `{agent, action, job?}`: Pause / Resume
///   (native cron pause, resume with no catch-up) and one routine on or off.
///
/// The owner comes only from the bearer (the phone's native domain grant, the
/// same admission desktop's host Stop uses). Every reply is checked against
/// the contract exactly; anything off it is refused, never repaired.
public enum HostAgentDesk {
    public static let deskPath = "/api/host/desk"
    public static let controlPath = "/api/host/agent-control"
    public static let bridgeHeader = "X-Atum-Host-Bridge-Contract"
    public static let bridgeVersion = "atum.s2.host-bridge/1.0.0"
    public static let maximumDeskBytes = 64 * 1024
    /// The Shell's shared cooldown answers a quick second control with 429;
    /// desktop retries once after this (`MATRIX_AGENT_CONTROL_RETRY_MS`).
    public static let controlRetryDelay: Duration = .milliseconds(10_500)
    public static let pausedReasonMaximum = 160

    /// What a desk read asks for. Desktop's UI reads only these two.
    public enum Read: Equatable, Sendable {
        case schedule
        /// `nil` is the agent's home; otherwise `home[/…]` or `work[/…]`.
        case files(path: String?)
    }

    /// `home[/…]` or `work[/…]`, NFC, no `.`/`..`, no control characters, no
    /// backslash, at most 2048 scalars (desktop `MatrixHostDeskPathSchema`).
    public static func isValidPath(_ path: String) -> Bool {
        guard path.unicodeScalars.count <= 2048, path == path.precomposedStringWithCanonicalMapping,
              !path.hasPrefix("/"), !hasControlOrBackslash(path) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let root = parts.first, root == "home" || root == "work" else { return false }
        return parts.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The folder above `path`, as desktop's Back computes it: a top-level
    /// folder's parent is the agent's home (nil).
    public static func parent(of path: String?) -> String? {
        guard let path else { return nil }
        let parent = path.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
        return parent.contains("/") ? parent : nil
    }

    static func hasControlOrBackslash(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0 == "\\" }
    }

    /// The exact request body, keys sorted.
    public static func deskBody(agent: NativeID, read: Read) throws -> Data {
        var body: [String: String] = ["agent": agent.rawValue]
        switch read {
        case .schedule:
            body["read"] = "schedule"
        case let .files(path):
            body["read"] = "files"
            if let path {
                guard isValidPath(path) else { throw ContractViolation.invalidValue }
                body["path"] = path
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(body)
    }

    // MARK: Schedule

    public struct Job: Decodable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Decodable, Sendable { case cron, interval, once }
        public enum State: String, Decodable, Sendable { case scheduled, paused, running, completed, error }

        public let id: String
        public let name: String
        public let kind: Kind
        public let display: String
        public var state: State
        public let nextRunAt: Date?
        /// Native `paused_reason`: `owner_pause`, `owner_routine_off` or an
        /// operator's note; nil whenever the value is off the platform's rule
        /// (a quiet extra on one row never costs the whole read).
        public let pausedReason: String?

        public init(id: String, name: String, kind: Kind = .cron, display: String = "",
                    state: State, nextRunAt: Date? = nil, pausedReason: String? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
            self.display = display
            self.state = state
            self.nextRunAt = nextRunAt
            self.pausedReason = pausedReason
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["id", "name", "kind", "display", "timezone", "state", "nextRunAt", "lastRunAt",
                          "lastStatus", "expr", "minutes", "runAt", "pausedReason"])
            id = try c.value("id")
            name = try c.value("name")
            kind = try c.value("kind")
            display = try c.value("display")
            let _: String? = try c.nullable("timezone")
            state = try c.value("state")
            nextRunAt = try HostAgentDesk.date(c, "nextRunAt")
            _ = try HostAgentDesk.date(c, "lastRunAt")
            if let status: String = try c.nullable("lastStatus"), !["ok", "error"].contains(status) {
                throw ContractViolation.invalidValue
            }
            let _: String? = try c.nullable("expr")
            if let minutes: Double = try c.nullable("minutes"), !(minutes > 0) { throw ContractViolation.invalidValue }
            _ = try HostAgentDesk.date(c, "runAt")
            pausedReason = HostAgentDesk.pausedReason(c.lossyNullable("pausedReason", as: String.self))
        }
    }

    public struct Schedule: Decodable, Equatable, Sendable {
        public var jobs: [Job]
        public let truncated: Bool

        public init(jobs: [Job], truncated: Bool = false) {
            self.jobs = jobs
            self.truncated = truncated
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["read", "observedAt", "jobs", "truncated"])
            guard try c.value("read", as: String.self) == "schedule" else { throw ContractViolation.invalidValue }
            _ = try c.integer("observedAt")
            jobs = try c.value("jobs")
            guard jobs.count <= 32 else { throw ContractViolation.invalidValue }
            truncated = try c.value("truncated")
        }
    }

    // MARK: Files

    public struct FileRow: Decodable, Equatable, Identifiable, Sendable {
        public enum Kind: String, Decodable, Sendable { case file, folder, link }
        public let name: String
        public let kind: Kind
        public let size: Int64
        /// Milliseconds since 1970.
        public let modifiedAt: Int64
        public var id: String { kind.rawValue + ":" + name }

        public init(name: String, kind: Kind, size: Int64 = 0, modifiedAt: Int64 = 0) {
            self.name = name
            self.kind = kind
            self.size = size
            self.modifiedAt = modifiedAt
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["name", "kind", "size", "modifiedAt"])
            name = try c.value("name")
            guard !name.isEmpty, name != ".", name != "..",
                  !name.unicodeScalars.contains(where: { $0 == "/" || $0 == "\\" || $0.value == 0 }) else {
                throw ContractViolation.invalidValue
            }
            kind = try c.value("kind")
            size = try c.integer("size")
            modifiedAt = try c.integer("modifiedAt")
        }
    }

    public struct Files: Decodable, Equatable, Sendable {
        public enum Root: String, Decodable, Sendable { case home, work }
        public let root: Root
        /// Relative to `root`; empty at the root itself.
        public let path: String
        public let rows: [FileRow]
        public let truncated: Bool

        public init(root: Root, path: String = "", rows: [FileRow], truncated: Bool = false) {
            self.root = root
            self.path = path
            self.rows = rows
            self.truncated = truncated
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["read", "root", "path", "rows", "truncated"])
            guard try c.value("read", as: String.self) == "files" else { throw ContractViolation.invalidValue }
            root = try c.value("root")
            path = try c.value("path")
            guard path.unicodeScalars.count <= 2048, path == path.precomposedStringWithCanonicalMapping,
                  !path.hasPrefix("/"), !HostAgentDesk.hasControlOrBackslash(path),
                  !path.split(separator: "/", omittingEmptySubsequences: false)
                      .contains(where: { $0 == "." || $0 == ".." }) else { throw ContractViolation.invalidValue }
            rows = try c.value("rows")
            guard rows.count <= 200 else { throw ContractViolation.invalidValue }
            truncated = try c.value("truncated")
        }

        /// The full desk path of this listing (`home`, `work/reports`).
        public var deskPath: String { path.isEmpty ? root.rawValue : root.rawValue + "/" + path }

        /// The reply must be the folder that was asked for (desktop's check).
        public func answers(_ requested: String?) -> Bool {
            let parts = (requested ?? "home").split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            return root.rawValue == parts.first && path == parts.dropFirst().joined(separator: "/")
        }
    }

    public static func schedule(_ data: Data) throws -> Schedule {
        guard data.count <= maximumDeskBytes else { throw ContractViolation.invalidValue }
        return try NativeAPI.decode(Schedule.self, from: data)
    }

    public static func files(_ data: Data, for path: String?) throws -> Files {
        guard data.count <= maximumDeskBytes else { throw ContractViolation.invalidValue }
        let files = try NativeAPI.decode(Files.self, from: data)
        guard files.answers(path) else { throw ContractViolation.invariant }
        return files
    }

    // MARK: Controls

    public enum Control: Equatable, Sendable {
        case pause
        case resume
        case routineOn(job: String)
        case routineOff(job: String)

        public var action: String {
            switch self {
            case .pause: "pause"
            case .resume: "resume"
            case .routineOn: "routine_on"
            case .routineOff: "routine_off"
            }
        }

        public func body(agent: NativeID) throws -> Data {
            var body = ["agent": agent.rawValue, "action": action]
            switch self {
            case let .routineOn(job), let .routineOff(job):
                guard (1...512).contains(job.unicodeScalars.count) else { throw ContractViolation.invalidValue }
                body["job"] = job
            case .pause, .resume: break
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(body)
        }
    }

    public struct ControlReply: Decodable, Equatable, Sendable {
        public let action: String
        public let changed: Int64

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Field.self)
            try c.closed(["action", "changed"])
            action = try c.value("action")
            guard ["pause", "resume", "routine_on", "routine_off"].contains(action) else {
                throw ContractViolation.invalidValue
            }
            changed = try c.integer("changed")
        }
    }

    /// Only the same action's `{action, changed}` is a reply.
    public static func controlReply(_ data: Data, for control: Control) throws -> ControlReply {
        guard data.count <= 4096 else { throw ContractViolation.invalidValue }
        let reply = try NativeAPI.decode(ControlReply.self, from: data)
        guard reply.action == control.action else { throw ContractViolation.invariant }
        return reply
    }

    /// How a control ended, in the words the desk has for it.
    public enum ControlOutcome: Equatable, Sendable {
        case changed(Int64)
        /// 409: its runtime is stopped; nothing was changed.
        case stopped
        /// 429: the shared cooldown.
        case busy
        case failed
    }

    // MARK: Helpers

    static func pausedReason(_ value: String?) -> String? {
        guard let value, value.unicodeScalars.count <= pausedReasonMaximum,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        return value
    }

    private static func date(_ c: KeyedDecodingContainer<Field>, _ key: String) throws -> Date? {
        guard let raw: String = try c.nullable(key) else { return nil }
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = precise.date(from: raw) ?? plain.date(from: raw) else { throw ContractViolation.invalidValue }
        return date
    }
}

// MARK: - The desk's schedule rules (desktop `agent-desk.tsx` `useAgentSchedule`)

extension HostAgentDesk {
    static let live: Set<Job.State> = [.scheduled, .running]

    /// Paused when it has routines and none of them can start on its own.
    public static func isPaused(_ jobs: [Job]?) -> Bool {
        guard let jobs else { return false }
        return jobs.contains { $0.state == .paused } && !jobs.contains { live.contains($0.state) }
    }

    /// A routine row's switch exists only for a live or paused routine.
    public static func isSwitchable(_ job: Job) -> Bool {
        live.contains(job.state) || job.state == .paused
    }

    /// The quiet line under a routine's name. A routine switched off on its own
    /// switch says nothing more; every other paused one keeps "Paused".
    public enum RoutineLine: Equatable, Sendable {
        case nothing
        case paused
        case next(Date)
    }

    public static func routineLine(_ job: Job) -> RoutineLine {
        if job.state == .paused {
            return job.pausedReason == "owner_routine_off" ? .nothing : .paused
        }
        return job.nextRunAt.map(RoutineLine.next) ?? .nothing
    }

    /// The switch moves at once; the host's answer may roll it back.
    public static func optimistic(_ control: Control, _ jobs: [Job]) -> [Job] {
        jobs.map { job in
            var job = job
            switch control {
            case .pause:
                if live.contains(job.state) { job.state = .paused }
            case .resume:
                if job.state == .paused { job.state = .scheduled }
            case let .routineOn(id):
                if job.id == id, job.state == .paused { job.state = .scheduled }
            case let .routineOff(id):
                if job.id == id, live.contains(job.state) { job.state = .paused }
            }
            return job
        }
    }

    /// What the desk does with a control's outcome. A resume or routine-on that
    /// changed nothing is no change (its routines were turned off one by one).
    public enum ControlResolution: Equatable, Sendable {
        case keep
        case rollBack
        case rollBackStopped
        case rollBackFailed
        case retryAfterCooldown
    }

    public static func resolve(_ outcome: ControlOutcome, for control: Control, retried: Bool) -> ControlResolution {
        switch outcome {
        case let .changed(count):
            return count == 0 && control != .pause ? .rollBack : .keep
        case .busy:
            return retried ? .rollBackFailed : .retryAfterCooldown
        case .stopped:
            return .rollBackStopped
        case .failed:
            return .rollBackFailed
        }
    }
}
