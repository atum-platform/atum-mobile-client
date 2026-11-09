import Foundation

/// The timing points of the Debug probe log (plan §2.10, D2). Frozen in S0:
/// every lane marks its own points through `ProbeLog.mark`; a new point is a
/// contract change for the coordinator. Durations are computed afterwards
/// from the records' `uptimeMs`, matched by `id`.
public enum ProbePoint: String, CaseIterable, Sendable {
    /// Send tapped. `id`: a per-tap ID the store also gives the echo.
    case sendTapped = "send.tap"
    /// The sent message's row is first in a published snapshot (tap-to-row).
    case sendRowShown = "send.row"
    /// The first typing row after a send (tap-to-first-dots).
    case typingShown = "typing.shown"
    /// "Đã xem" first shown under a sent message (tap-to-Seen, S1b).
    case seenShown = "seen.shown"
    /// One item's identity: fields `uniqueId`, `eventOrTransactionId`,
    /// `phase` (`local`, `remote`, `edit`). The S0 `uniqueId` probe (§2.3
    /// rule 2).
    case itemIdentity = "item.identity"
    /// The app's physical memory footprint: field `bytes`, plus `label`
    /// (G-scroll check 10).
    case memoryFootprint = "memory.footprint"
    /// A chat opened (`id`: room fingerprint, never the raw room ID).
    case chatOpened = "chat.open"
    /// The first snapshot of an opened chat was published.
    case firstSnapshot = "chat.first_snapshot"
    /// The first non-empty Home roster frame after process launch.
    case homeFirstFrame = "launch.home_first_frame"
    /// One SDK batch around a send: fields `ops` (`ChatDiff.probeShape`),
    /// `before` (buffer length before the batch) and `change` (the
    /// `SnapshotChange` it produced). Confirms the SDK's ordering of remote
    /// items and pending local echoes (S0 part B, with `item.identity`).
    case timelineBatch = "timeline.batch"
}

/// One JSON line of the probe log. Content-free: IDs and numbers only, never
/// message text, names or tokens.
public struct ProbeRecord: Codable, Equatable, Sendable {
    public var point: String
    /// `ProcessInfo.systemUptime` in milliseconds: monotonic, for durations.
    public var uptimeMs: Double
    /// Wall-clock time, ISO 8601 with fractional seconds, for reading.
    public var wall: String
    public var id: String?
    public var fields: [String: String]

    public init(point: String, uptimeMs: Double, wall: String, id: String?, fields: [String: String]) {
        self.point = point
        self.uptimeMs = uptimeMs
        self.wall = wall
        self.id = id
        self.fields = fields
    }

    /// One line, keys sorted, no trailing newline.
    public func jsonLine() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let line = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return line
    }
}

/// Where probe records go. The app installs a file sink in Debug builds only
/// (`ios/App/Debug/ProbeLog.swift`); with no sink, `mark` does nothing.
public protocol ProbeSink: Sendable {
    func write(_ record: ProbeRecord)
}

public enum ProbeLog {
    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var sink: (any ProbeSink)?

        var current: (any ProbeSink)? {
            lock.lock(); defer { lock.unlock() }
            return sink
        }

        func set(_ value: (any ProbeSink)?) {
            lock.lock(); defer { lock.unlock() }
            sink = value
        }
    }

    private static let slot = Slot()

    /// Installs (or, with nil, removes) the sink. Release builds never call
    /// this, so every `mark` there is a no-op.
    public static func install(_ sink: (any ProbeSink)?) {
        slot.set(sink)
    }

    public static var isEnabled: Bool { slot.current != nil }

    public static func mark(_ point: ProbePoint, id: String? = nil, fields: [String: String] = [:]) {
        guard let sink = slot.current else { return }
        sink.write(record(point, id: id, fields: fields,
                          uptime: ProcessInfo.processInfo.systemUptime, now: Date()))
    }

    /// The record `mark` writes, with the clock injected (tests).
    public static func record(_ point: ProbePoint, id: String?, fields: [String: String],
                              uptime: TimeInterval, now: Date) -> ProbeRecord {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ProbeRecord(point: point.rawValue, uptimeMs: (uptime * 1000).rounded(),
                           wall: formatter.string(from: now), id: id, fields: fields)
    }
}
