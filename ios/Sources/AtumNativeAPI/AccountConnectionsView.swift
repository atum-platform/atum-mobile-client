import Foundation

/// Account connections as the phone draws them: a port of the desktop's pure
/// view (`apps/desktop/src/app/connections/view.ts`, #106 `f1d10cf0`) from the
/// one registry read to rows, lines and the picker's Connect entries. The
/// phone is never a Mac, so no Mac here is "this Mac" and nothing is "here":
/// every Mac is named by its own name, and Manage (which opens the plan's
/// screen in Work on the Mac that holds it) is never offered.
public enum AccountPlanState: String, Equatable, Sendable {
    case connected, stale, notConnected, needsAttention
}

public struct AccountPlanMac: Equatable, Sendable {
    public let id: String
    public let name: String
    public let stale: Bool
}

public struct AccountPlanRow: Equatable, Sendable {
    public let plan: AccountPlan
    public let state: AccountPlanState
    public let macs: [AccountPlanMac]
    public let models: [AccountConnectionModel]

    /// Only a plan connected nowhere, or one that must sign in again, has an
    /// action on the phone: Connect, which opens the connect sheet.
    public var offersConnect: Bool { state == .notConnected || state == .needsAttention }
}

/// A plan row's one line (desktop `accountPlanLine`).
public enum AccountPlanLine: Equatable, Sendable {
    /// "On {Macs}": the Macs that reported it recently.
    case onMacs(String)
    /// "Last seen on {Macs}": every Mac it was on is stale.
    case lastSeen(String)
    case needsAttention
    case notConnected
}

/// One row of Data and tools: your chats (always), then the home hubs the
/// registry has, as it lists them.
public enum AccountToolRow: Hashable, Sendable {
    case ownerChats
    case homeHub(id: String, name: String, connected: Bool)
}

/// What the Subscriptions section shows while the read is in flight, after it
/// failed, or once it answered.
public enum AccountConnectionsLoad: Equatable, Sendable {
    case loading
    case failed
    case loaded(AccountConnections)
}

public enum AccountConnectionsView {
    /// Every plan, always, in the order the picker and Settings share:
    /// connected, then needs attention, then last seen, then the rest. The sort
    /// is stable, so plans of one state keep the desktop's plan order.
    public static func planRows(_ registry: AccountConnections?) -> [AccountPlanRow] {
        let rank: [AccountPlanState: Int] = [.connected: 0, .needsAttention: 1, .stale: 2, .notConnected: 3]
        return AccountPlan.allCases
            .map { planRow(registry, $0) }
            .enumerated()
            .sorted { (rank[$0.element.state]!, $0.offset) < (rank[$1.element.state]!, $1.offset) }
            .map(\.element)
    }

    public static func planRow(_ registry: AccountConnections?, _ plan: AccountPlan) -> AccountPlanRow {
        guard let connection = registry?.connections.first(where: { $0.kind == .plan && $0.plan == plan }) else {
            return AccountPlanRow(plan: plan, state: .notConnected, macs: [], models: [])
        }
        // Fresh Macs first, then stale ones; otherwise the registry's order.
        let macs = connection.devices
            .map { AccountPlanMac(id: $0.deviceServiceID, name: $0.displayName, stale: $0.stale) }
            .enumerated()
            .sorted { ($0.element.stale ? 1 : 0, $0.offset) < ($1.element.stale ? 1 : 0, $1.offset) }
            .map(\.element)
        let state: AccountPlanState =
            connection.status == .needsAttention ? .needsAttention
            : connection.status == .notConnected || macs.isEmpty ? .notConnected
            : macs.allSatisfy(\.stale) ? .stale
            : .connected
        return AccountPlanRow(plan: plan, state: state, macs: macs,
                              models: state == .notConnected ? [] : connection.models)
    }

    /// Where the plan runs, when it was last seen, or that it is not connected.
    /// Mac names are joined with ", " exactly as the desktop joins them.
    public static func line(_ row: AccountPlanRow) -> AccountPlanLine {
        switch row.state {
        case .connected: .onMacs(row.macs.filter { !$0.stale }.map(\.name).joined(separator: ", "))
        case .stale: .lastSeen(row.macs.map(\.name).joined(separator: ", "))
        case .needsAttention: .needsAttention
        case .notConnected: .notConnected
        }
    }

    /// OpenCode Go is an account key held in the cloud: "In the cloud" once
    /// connected, else "Not connected".
    public static func openCodeGoConnected(_ registry: AccountConnections?) -> Bool {
        registry?.connections.first(where: { $0.id == "opencode_go" })?.status == .connected
    }

    /// Desktop `accountToolRows`: owner chats always (first when the registry
    /// leaves it out), and the home hubs in the registry's order.
    public static func toolRows(_ registry: AccountConnections?) -> [AccountToolRow] {
        let rows = (registry?.connections ?? []).filter { $0.id == "owner_chats" || $0.id.hasPrefix("home_hub:") }
        let mapped: [AccountToolRow] = rows.map { row in
            row.id == "owner_chats" ? .ownerChats
                : .homeHub(id: row.id, name: homeHubName(row.id), connected: row.status == .connected)
        }
        return rows.contains(where: { $0.id == "owner_chats" }) ? mapped : [.ownerChats] + mapped
    }

    /// `home_hub:strap-hub` → "Strap hub".
    public static func homeHubName(_ id: String) -> String {
        let name = id.replacingOccurrences(of: "home_hub:", with: "", options: .anchored)
            .replacingOccurrences(of: "-", with: " ")
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }

    /// The picker's plans with nothing to pick yet (desktop `accountPickerPlans`
    /// kind `connect`): connected nowhere, or signed out. Each gets the plan's
    /// mark, "Use your {Plan} plan" and one Connect.
    public static func pickerConnectPlans(_ registry: AccountConnections?) -> [AccountPlan] {
        planRows(registry).filter(\.offersConnect).map(\.plan)
    }

    /// The connect sheet's watch: a plan has landed once any Mac reports it
    /// connected (fresh). The phone never signs in itself, so this is the
    /// owner finishing on a Mac while the sheet is open.
    public static func connectLanded(_ registry: AccountConnections?, plan: AccountPlan) -> Bool {
        planRow(registry, plan).state == .connected
    }
}

/// The exported words of Settings › Connections and the connect sheet
/// (`MS.connections.*`, wave 4c). Every key is written out in full so the
/// copy-pin check reads each one. A plan formatter is exported once per plan
/// (`….plan=codex`) and takes the plan as its one choice argument.
public enum AccountConnectionsCopy {
    public struct Phrase: Equatable, Sendable {
        public let key: String
        public let arguments: [String]

        init(_ key: String, _ arguments: [String] = []) {
            self.key = key
            self.arguments = arguments
        }
    }

    public static let subscriptions = Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.subscriptions")
    public static let dataAndTools = Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.dataAndTools")
    public static let notConnected = Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.notConnected")
    public static let inCloud = Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.inCloud")
    public static let connect = Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.connect")
    public static let ownerChatsTitle = Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.ownerChats.title")
    public static let ownerChatsLine = Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.ownerChats.line")
    public static let homeToolsLine = Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.homeTools.line")
    public static let needsMac = Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.sheet.needsMac")
    public static let close = Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.sheet.close")
    public static let tryAgain = Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.progress.tryAgain")
    /// "Works in Work for now": desktop's reason for a plan's models that run
    /// in Work on a Mac (`model-picker.tsx` `connectionWords.picker.inWork`).
    public static let pickerInWork = Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.picker.inWork")
    /// The Connections page's own "couldn't check" (the ChatGPT-with-Google
    /// row's read failure): the phone has no Mac facts to fall back on.
    public static let readFailed = Phrase("src.matrix.chatgpt-training-copy.COPY.readFailed")

    public static func line(_ line: AccountPlanLine) -> Phrase {
        switch line {
        case let .onMacs(names): Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.onMacs", [names])
        case let .lastSeen(names): Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.lastSeen", [names])
        case .needsAttention: Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.needsAttention")
        case .notConnected: notConnected
        }
    }

    /// "Connect {Plan}".
    public static func sheetTitle(_ plan: AccountPlan) -> Phrase {
        switch plan {
        case .codex: Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.sheet.title.plan=codex", ["codex"])
        case .claude: Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.sheet.title.plan=claude", ["claude"])
        case .antigravity:
            Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.sheet.title.plan=antigravity", ["antigravity"])
        }
    }

    /// "{Plan} is connected".
    public static func done(_ plan: AccountPlan) -> Phrase {
        switch plan {
        case .codex: Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.progress.done.plan=codex", ["codex"])
        case .claude: Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.progress.done.plan=claude", ["claude"])
        case .antigravity:
            Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.progress.done.plan=antigravity", ["antigravity"])
        }
    }

    /// "Use your {Plan} plan" (the picker's Connect state).
    public static func pickerUse(_ plan: AccountPlan) -> Phrase {
        switch plan {
        case .codex: Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.picker.use.plan=codex", ["codex"])
        case .claude: Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.picker.use.plan=claude", ["claude"])
        case .antigravity:
            Phrase("src.matrix.mobile-copy.mobileScreensCopy.connections.picker.use.plan=antigravity", ["antigravity"])
        }
    }
}
