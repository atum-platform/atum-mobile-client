/// The SDK's 11 `TimelineDiff` cases on plain values (`SDK:45556-45576`).
/// Indices are SDK list indices: the buffer stays index-aligned with the SDK
/// list, so they are applied verbatim (plan §2.3 rule 4).
public enum ChatDiff: Equatable, Sendable {
    case append([ChatItem])
    case clear
    case pushFront(ChatItem)
    case pushBack(ChatItem)
    case popFront
    case popBack
    case insert(index: Int, item: ChatItem)
    case set(index: Int, item: ChatItem)
    case remove(index: Int)
    case truncate(length: Int)
    case reset([ChatItem])
}

extension ChatDiff {
    /// The values this diff inserts or sets: the only ones that crossed the
    /// mapper (§2.3 rule 3), and the ones whose side facts (reply details,
    /// the parse cache) a batch refreshes.
    public var carriedItems: [ChatItem] {
        switch self {
        case let .append(values), let .reset(values): values
        case let .pushFront(value), let .pushBack(value), let .insert(_, value), let .set(_, value): [value]
        case .clear, .popFront, .popBack, .remove, .truncate: []
        }
    }

    /// One batch's shape for the probe log (`ProbePoint.timelineBatch`),
    /// content-free: each operation with its index and, for an item it
    /// carries, whether that item is a local `echo`, `remote` or `virtual`.
    /// Example: `insert@1:remote,set@2:echo`. Part B records it around a send
    /// to confirm where the SDK puts remote items while an echo is pending.
    public static func probeShape(_ diffs: [ChatDiff]) -> String {
        diffs.map(\.probeLabel).joined(separator: ",")
    }

    var probeLabel: String {
        func tag(_ item: ChatItem) -> String {
            item.kind.isVirtual ? "virtual" : (item.isLocalEcho ? "echo" : "remote")
        }
        switch self {
        case let .append(values): return "append×\(values.count)"
        case .clear: return "clear"
        case let .pushFront(value): return "pushFront:" + tag(value)
        case let .pushBack(value): return "pushBack:" + tag(value)
        case .popFront: return "popFront"
        case .popBack: return "popBack"
        case let .insert(index, value): return "insert@\(index):" + tag(value)
        case let .set(index, value): return "set@\(index):" + tag(value)
        case let .remove(index): return "remove@\(index)"
        case let .truncate(length): return "truncate@\(length)"
        case let .reset(values): return "reset×\(values.count)"
        }
    }
}
