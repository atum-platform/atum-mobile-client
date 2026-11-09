#if DEBUG
import AtumChat
import Darwin
import Foundation

/// Debug-only probe log sink (plan §2.10, the D2 timing mechanism). Appends
/// one JSON line per `ProbeLog.mark` to `Library/Caches/atum-probe.jsonl` in
/// the app's container; at 4 MiB the file moves to `atum-probe.1.jsonl`. The
/// coordinator pulls both with `scripts/pull-probe-log.sh`. Records are
/// content-free (IDs and numbers only). Release builds compile none of this
/// file, so they never install a sink and every mark is a no-op.
final class ProbeFileSink: ProbeSink, @unchecked Sendable {
    static let fileName = "atum-probe.jsonl"
    static let rotatedFileName = "atum-probe.1.jsonl"
    static let maxBytes = 4 << 20

    private let url: URL
    private let rotatedURL: URL
    private let queue = DispatchQueue(label: "com.atum.mobile.probe-log", qos: .utility)

    init(directory: URL) {
        url = directory.appendingPathComponent(Self.fileName)
        rotatedURL = directory.appendingPathComponent(Self.rotatedFileName)
    }

    static func install() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        ProbeLog.install(ProbeFileSink(directory: caches))
    }

    func write(_ record: ProbeRecord) {
        let data = Data((record.jsonLine() + "\n").utf8)
        queue.async { [url, rotatedURL] in
            Self.append(data, to: url, rotatingTo: rotatedURL)
        }
    }

    private static func append(_ data: Data, to url: URL, rotatingTo rotatedURL: URL) {
        let files = FileManager.default
        let size = (try? files.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > maxBytes {
            try? files.removeItem(at: rotatedURL)
            try? files.moveItem(at: url, to: rotatedURL)
        }
        if !files.fileExists(atPath: url.path) {
            files.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

extension ProbeLog {
    /// G-scroll check 10: the app's physical memory footprint (the number
    /// Xcode's memory gauge shows), recorded with a label.
    static func markMemoryFootprint(label: String) {
        guard isEnabled, let bytes = physicalFootprint() else { return }
        mark(.memoryFootprint, fields: ["bytes": String(bytes), "label": label])
    }

    private static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
#endif
