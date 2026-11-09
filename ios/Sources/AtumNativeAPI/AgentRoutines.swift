import Foundation

public enum AgentRoutineSchedule: Equatable, Sendable, Codable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case once, daily, weekly, monthly
        public var id: String { rawValue }
    }

    case once(runAt: Date)
    case daily(hour: Int, minute: Int)
    case weekly(hour: Int, minute: Int, weekdays: [Int])
    case monthly(day: Int, hour: Int, minute: Int)
    /// A kind this build does not understand (`interval` today). The row stays
    /// visible and read-only so one newer row never hides the whole snapshot.
    case unsupported(kind: String)

    public var kind: Kind? {
        switch self {
        case .once: .once
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .unsupported: nil
        }
    }

    public var isReadOnly: Bool {
        if case .unsupported = self { return true }
        return false
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        let kind = try c.string("kind", minimum: 1, maximum: 64)
        switch kind {
        case "once":
            try c.closed(["kind", "runAt"])
            let raw = try c.string("runAt", minimum: 1, maximum: 40)
            guard let date = Self.date(raw) else { throw ContractViolation.invalidValue }
            self = .once(runAt: date)
        case "daily":
            try c.closed(["kind", "hour", "minute"])
            self = .daily(hour: try Self.part(c, "hour", maximum: 23),
                          minute: try Self.part(c, "minute", maximum: 59))
        case "weekly":
            try c.closed(["kind", "hour", "minute", "weekdays"])
            let wireWeekdays: [WireInteger] = try c.value("weekdays")
            let weekdays = wireWeekdays.map { Int($0.value) }
            guard (1...7).contains(weekdays.count), Set(weekdays).count == weekdays.count,
                  weekdays.allSatisfy({ (1...7).contains($0) }) else {
                throw ContractViolation.invalidValue
            }
            self = .weekly(hour: try Self.part(c, "hour", maximum: 23),
                           minute: try Self.part(c, "minute", maximum: 59),
                           weekdays: weekdays.sorted())
        case "monthly":
            try c.closed(["kind", "day", "hour", "minute"])
            self = .monthly(day: try Self.part(c, "day", minimum: 1, maximum: 28),
                            hour: try Self.part(c, "hour", maximum: 23),
                            minute: try Self.part(c, "minute", maximum: 59))
        default:
            let kind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !kind.isEmpty else { throw ContractViolation.invalidValue }
            self = .unsupported(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Field.self)
        switch self {
        case let .once(runAt):
            try c.encode(Kind.once.rawValue, forKey: Field("kind"))
            try c.encode(Self.string(runAt), forKey: Field("runAt"))
        case let .daily(hour, minute):
            try Self.validate(hour: hour, minute: minute)
            try c.encode(Kind.daily.rawValue, forKey: Field("kind"))
            try c.encode(hour, forKey: Field("hour")); try c.encode(minute, forKey: Field("minute"))
        case let .weekly(hour, minute, weekdays):
            try Self.validate(hour: hour, minute: minute)
            guard (1...7).contains(weekdays.count), Set(weekdays).count == weekdays.count,
                  weekdays.allSatisfy({ (1...7).contains($0) }) else { throw ContractViolation.invalidValue }
            try c.encode(Kind.weekly.rawValue, forKey: Field("kind"))
            try c.encode(hour, forKey: Field("hour")); try c.encode(minute, forKey: Field("minute"))
            try c.encode(weekdays.sorted(), forKey: Field("weekdays"))
        case let .monthly(day, hour, minute):
            try Self.validate(hour: hour, minute: minute)
            guard (1...28).contains(day) else { throw ContractViolation.invalidValue }
            try c.encode(Kind.monthly.rawValue, forKey: Field("kind"))
            try c.encode(day, forKey: Field("day")); try c.encode(hour, forKey: Field("hour"))
            try c.encode(minute, forKey: Field("minute"))
        case .unsupported:
            throw ContractViolation.invalidValue
        }
    }

    private static func part(_ c: KeyedDecodingContainer<Field>, _ key: String,
                             minimum: Int64 = 0, maximum: Int64) throws -> Int {
        let value = try c.integer(key, minimum: minimum)
        guard value <= maximum else { throw ContractViolation.invalidValue }
        return Int(value)
    }
    private static func validate(hour: Int, minute: Int) throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else { throw ContractViolation.invalidValue }
    }
    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    private static func string(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: value)
    }
}

public struct AgentRoutineRun: Decodable, Equatable, Sendable, Identifiable {
    public enum State: String, Decodable, Sendable { case claimed, dispatched, skipped, completed }
    public enum Outcome: String, Decodable, Sendable { case answered, stopped, failed, uncertain }
    public let occurrenceID: NativeID
    public let scheduledAt: Int64
    public let state: State
    public let outcome: Outcome?
    public let skipReason, publishedEvent: String?
    public var id: String { occurrenceID.rawValue }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["occurrenceId", "scheduledAt", "state", "outcome", "skipReason", "publishedEvent"])
        occurrenceID = try c.value("occurrenceId")
        scheduledAt = try c.integer("scheduledAt")
        state = try c.value("state")
        outcome = try c.optional("outcome")
        skipReason = try c.optional("skipReason")
        publishedEvent = try c.optional("publishedEvent")
        if let skipReason { _ = try checkedString(skipReason, minimum: 1, maximum: 64,
                                                  pattern: "[a-z][a-z0-9_]*") }
        if let publishedEvent { _ = try checkedString(publishedEvent, minimum: 2, maximum: 1_024,
                                                       pattern: "[$][!-~]+") }
        guard (state == .completed) == (outcome != nil),
              (state == .skipped) == (skipReason != nil),
              publishedEvent == nil || state == .completed else { throw ContractViolation.invariant }
    }
}

public struct AgentRoutine: Decodable, Equatable, Sendable, Identifiable {
    public let id: NativeID
    public let title, instruction: String
    public let schedule: AgentRoutineSchedule
    public let timezone: String
    public let enabled, notifications: Bool
    public let revision: Int64
    public let nextRunAt: Int64?
    public let lastRun: AgentRoutineRun?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["id", "title", "instruction", "schedule", "timezone", "enabled",
                      "notifications", "revision", "nextRunAt", "lastRun"])
        id = try c.value("id")
        title = try c.string("title", minimum: 1, maximum: 120)
        instruction = try c.string("instruction", minimum: 1, maximum: 20_000)
        schedule = try c.value("schedule")
        timezone = try c.string("timezone", minimum: 1, maximum: 64)
        enabled = try c.value("enabled"); notifications = try c.value("notifications")
        revision = try c.integer("revision", minimum: 1)
        nextRunAt = try c.nullableInteger("nextRunAt")
        lastRun = try c.nullable("lastRun")
        guard title == title.trimmingCharacters(in: .whitespacesAndNewlines),
              instruction == instruction.trimmingCharacters(in: .whitespacesAndNewlines),
              instruction.utf8.count <= 65_536,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !instruction.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 11 || $0.value == 12 || $0.value == 127 }),
              TimeZone(identifier: timezone) != nil else { throw ContractViolation.invalidValue }
    }
}

public struct AgentRoutinesSnapshot: Decodable, Equatable, Sendable {
    public enum LegacyState: String, Decodable, Sendable { case unknown, clear, present }
    public let assistantID, assistantPrincipal: NativeID
    public let serverTime: Int64
    public let legacyState: LegacyState
    public let routines: [AgentRoutine]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["profile", "assistantId", "assistantPrincipal", "serverTime", "legacyState", "routines"])
        guard try c.value("profile", as: String.self) == "atum.agent-routines/1" else {
            throw ContractViolation.invalidValue
        }
        assistantID = try c.value("assistantId"); assistantPrincipal = try c.value("assistantPrincipal")
        serverTime = try c.integer("serverTime"); legacyState = try c.value("legacyState")
        routines = try c.value("routines")
        guard routines.count <= 64, Set(routines.map(\.id)).count == routines.count else {
            throw ContractViolation.invalidValue
        }
    }

    public init(assistantID: NativeID, assistantPrincipal: NativeID, serverTime: Int64,
                legacyState: LegacyState, routines: [AgentRoutine]) throws {
        guard (0...NativeAPI.maximumInteger).contains(serverTime), routines.count <= 64,
              Set(routines.map(\.id)).count == routines.count else { throw ContractViolation.invalidValue }
        self.assistantID = assistantID; self.assistantPrincipal = assistantPrincipal
        self.serverTime = serverTime; self.legacyState = legacyState; self.routines = routines
    }
}

public struct AgentRoutineRunsSnapshot: Decodable, Equatable, Sendable {
    public let routineID: NativeID
    public let runs: [AgentRoutineRun]
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        try c.closed(["profile", "routineId", "runs"])
        guard try c.value("profile", as: String.self) == "atum.agent-routine-runs/1" else {
            throw ContractViolation.invalidValue
        }
        routineID = try c.value("routineId"); runs = try c.value("runs")
        guard runs.count <= 20, Set(runs.map(\.occurrenceID)).count == runs.count else {
            throw ContractViolation.invalidValue
        }
    }
}

public struct AgentRoutineCreate: Encodable, Equatable, Sendable {
    public let requestId: NativeID
    public let title, instruction: String
    public let schedule: AgentRoutineSchedule
    public let timezone: String
    public let enabled, notifications: Bool
    public init(requestId: NativeID, title: String, instruction: String,
                schedule: AgentRoutineSchedule, timezone: String,
                enabled: Bool, notifications: Bool) throws {
        self.requestId = requestId
        self.title = try Self.title(title); self.instruction = try Self.instruction(instruction)
        _ = try JSONEncoder().encode(schedule)
        self.schedule = schedule; self.timezone = try Self.timezone(timezone)
        self.enabled = enabled; self.notifications = notifications
    }
    enum CodingKeys: String, CodingKey { case operation, requestId, title, instruction, schedule, timezone, enabled, notifications }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("create", forKey: .operation); try c.encode(requestId, forKey: .requestId)
        try c.encode(title, forKey: .title); try c.encode(instruction, forKey: .instruction)
        try c.encode(schedule, forKey: .schedule); try c.encode(timezone, forKey: .timezone)
        try c.encode(enabled, forKey: .enabled); try c.encode(notifications, forKey: .notifications)
    }
    fileprivate static func title(_ value: String) throws -> String {
        let value = value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= 120,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ContractViolation.invalidValue
        }
        return value
    }
    fileprivate static func instruction(_ value: String) throws -> String {
        let value = value.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= 20_000, value.utf8.count <= 65_536,
              !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 11 || $0.value == 12 || $0.value == 127 })
        else { throw ContractViolation.invalidValue }
        return value
    }
    fileprivate static func timezone(_ value: String) throws -> String {
        guard value.unicodeScalars.count <= 64, TimeZone(identifier: value) != nil else {
            throw ContractViolation.invalidValue
        }
        return value
    }
}

public struct AgentRoutineUpdate: Encodable, Equatable, Sendable {
    public let requestId, routineId: NativeID
    public let expectedRevision: Int64
    public let title, instruction: String
    public let schedule: AgentRoutineSchedule
    public let timezone: String
    public let enabled, notifications: Bool
    public init(requestId: NativeID, routine: AgentRoutine, title: String, instruction: String,
                schedule: AgentRoutineSchedule, timezone: String, enabled: Bool,
                notifications: Bool) throws {
        self.requestId = requestId; routineId = routine.id; expectedRevision = routine.revision
        self.title = try AgentRoutineCreate.title(title)
        self.instruction = try AgentRoutineCreate.instruction(instruction)
        _ = try JSONEncoder().encode(schedule)
        self.schedule = schedule; self.timezone = try AgentRoutineCreate.timezone(timezone)
        self.enabled = enabled; self.notifications = notifications
    }
    enum CodingKeys: String, CodingKey { case operation, requestId, routineId, expectedRevision, title, instruction, schedule, timezone, enabled, notifications }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("update", forKey: .operation); try c.encode(requestId, forKey: .requestId)
        try c.encode(routineId, forKey: .routineId); try c.encode(expectedRevision, forKey: .expectedRevision)
        try c.encode(title, forKey: .title); try c.encode(instruction, forKey: .instruction)
        try c.encode(schedule, forKey: .schedule); try c.encode(timezone, forKey: .timezone)
        try c.encode(enabled, forKey: .enabled); try c.encode(notifications, forKey: .notifications)
    }
}

public struct AgentRoutineAction: Encodable, Equatable, Sendable {
    public enum Operation: String, Encodable, Sendable { case run, delete }
    public let operation: Operation
    public let requestId, routineId: NativeID
    public let expectedRevision: Int64
    public init(operation: Operation, requestId: NativeID, routine: AgentRoutine) {
        self.operation = operation; self.requestId = requestId
        routineId = routine.id; expectedRevision = routine.revision
    }
}

public enum AgentRoutineMutationResult: Decodable, Equatable, Sendable {
    case routine(AgentRoutine)
    case deleted(id: NativeID, revision: Int64)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Field.self)
        let profile: String = try c.value("profile")
        guard profile == "atum.agent-routines/1" else { throw ContractViolation.invalidValue }
        if c.contains(Field("routine")) {
            try c.closed(["profile", "routine"])
            self = .routine(try c.value("routine"))
        } else {
            try c.closed(["profile", "outcome", "routineId", "revision"])
            guard try c.value("outcome", as: String.self) == "deleted" else {
                throw ContractViolation.invalidValue
            }
            self = .deleted(id: try c.value("routineId"),
                            revision: try c.integer("revision", minimum: 1))
        }
    }
}
