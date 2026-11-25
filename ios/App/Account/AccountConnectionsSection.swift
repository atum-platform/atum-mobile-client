import AtumDesign
import AtumNativeAPI
import Observation
import SwiftUI
import UIKit

/// The account connections read Settings › Connections and the model picker
/// share: `account_connections_read`, the desktop's one read for every
/// feature. A nil answer is a failed read; the phone has no Mac facts of its
/// own to fall back on, so it never guesses "Not connected".
struct AccountConnectionsActions {
    let read: @MainActor () async -> AccountConnections?
    /// Makes the connect sheet's poll when the sheet opens: bound to that
    /// account session, and never rotating the grant (`AccountConnectionsReadMode.poll`).
    let makePoll: @MainActor () -> @MainActor () async -> AccountConnections?
}

/// The words of a connections phrase, from the pinned export.
@MainActor
enum AccountConnectionsWords {
    static func text(_ phrase: AccountConnectionsCopy.Phrase, design: LiveDesign) -> String {
        design.text(phrase.key, arguments: phrase.arguments.map { .text($0) })
    }
}

/// A plan's mark: the provider's real mark, as the desktop draws it
/// (`connect-sheet.tsx` `AccountPlanMark` is a bare `ProviderMark`, #119).
/// ChatGPT (codex) reads as OpenAI's mark.
struct AccountPlanMark: View {
    let design: LiveDesign
    let plan: AccountPlan
    var size: CGFloat = 22

    var body: some View {
        ProviderMark(design: design, provider: plan.rawValue, label: plan.productName, size: size)
    }
}

/// The Connections page's read and its connect sheet. Owned by the page
/// (`AccountSettingsDetail`), whose one list carries the read, the refresh and
/// the sheet: a modifier on a list section can reach each of its rows.
@MainActor @Observable
final class AccountConnectionsModel {
    var load = AccountConnectionsLoad.loading
    var connecting: AccountPlanConnectRequest?
    /// Every read and every landing takes a new generation; a read applies
    /// only if nothing newer started or landed while it was in flight.
    @ObservationIgnored private var generation = 0

    func reload(_ read: @MainActor () async -> AccountConnections?) async {
        generation += 1
        let mine = generation
        let registry = await read()
        // A refresh that read "Not connected" before the sheet saw the plan
        // land must not undo that newer answer.
        guard mine == generation else { return }
        guard let registry else {
            // A failed refresh keeps the last good read, as the desktop does.
            if case .loaded = load { return }
            load = .failed
            return
        }
        load = .loaded(registry)
    }

    /// The connect sheet saw the plan land: the rows take that read, and any
    /// older read still in flight is dropped.
    func landed(_ registry: AccountConnections) {
        generation += 1
        load = .loaded(registry)
    }
}

/// Settings › Connections, Subscriptions and Data and tools (desktop
/// `AccountSubscriptionsSection` and `AccountToolsSection`, #106): every plan
/// the account can use, one row each (its mark, where it runs, at most one
/// action), the OpenCode Go key, then your chats and the home hubs. Connected
/// means every assistant and every feature can use it; nothing is listed per
/// assistant. Two sections straight in the page's list.
struct AccountConnectionsSections: View {
    let design: LiveDesign
    let actions: AccountConnectionsActions
    let model: AccountConnectionsModel

    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        Section {
            switch model.load {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .accessibilityIdentifier("account.settings.connections.loading")
            case .failed:
                failedRow
            case let .loaded(registry):
                ForEach(AccountConnectionsView.planRows(registry), id: \.plan) { row in
                    planRow(row)
                }
                openCodeGoRow(AccountConnectionsView.openCodeGoConnected(registry))
            }
        } header: {
            Text(words(AccountConnectionsCopy.subscriptions))
        }
        Section {
            ForEach(toolRows, id: \.self) { row in toolRow(row) }
        } header: {
            Text(words(AccountConnectionsCopy.dataAndTools))
        }
    }

    // Data and tools is account-wide: your chats are always there, so the
    // section draws before (and without) the read; hubs join once it answers.
    private var toolRows: [AccountToolRow] {
        guard case let .loaded(registry) = model.load else { return [.ownerChats] }
        return AccountConnectionsView.toolRows(registry)
    }

    // MARK: Rows

    private func planRow(_ row: AccountPlanRow) -> some View {
        let line = words(AccountConnectionsCopy.line(AccountConnectionsView.line(row)))
        return connectionRow(
            // The 28 pt lead column the tool glyphs share keeps the titles aligned.
            lead: AnyView(AccountPlanMark(design: design, plan: row.plan).frame(minWidth: 28)),
            title: row.plan.productName, line: line,
            identifier: "account.settings.connections.plan." + row.plan.rawValue) {
            if row.offersConnect {
                Button(words(AccountConnectionsCopy.connect)) {
                    model.connecting = AccountPlanConnectRequest(plan: row.plan)
                }
                .buttonStyle(.atumSecondary)
                .accessibilityLabel(words(AccountConnectionsCopy.sheetTitle(row.plan)))
                .accessibilityIdentifier("account.settings.connections.plan." + row.plan.rawValue + ".connect")
            }
        }
    }

    /// OpenCode Go's key is entered on the desktop; the phone shows only
    /// where it stands (follow-up: the key sheet, docs/ports/w4-e6-connections.md).
    private func openCodeGoRow(_ connected: Bool) -> some View {
        connectionRow(
            lead: AnyView(ProviderMark(design: design, provider: "opencode-go", label: "OpenCode Go", size: 22)
                .frame(minWidth: 28)),
            title: "OpenCode Go",
            line: words(connected ? AccountConnectionsCopy.inCloud : AccountConnectionsCopy.notConnected),
            identifier: "account.settings.connections.opencode-go") { EmptyView() }
    }

    @ViewBuilder private func toolRow(_ row: AccountToolRow) -> some View {
        switch row {
        case .ownerChats:
            connectionRow(lead: AnyView(glyph(.messages)),
                          title: words(AccountConnectionsCopy.ownerChatsTitle),
                          line: words(AccountConnectionsCopy.ownerChatsLine),
                          identifier: "account.settings.connections.owner-chats") { EmptyView() }
        case let .homeHub(id, name, connected):
            connectionRow(lead: AnyView(glyph(.home)), title: name,
                          line: words(AccountConnectionsCopy.homeToolsLine),
                          status: connected ? nil : words(AccountConnectionsCopy.notConnected),
                          identifier: "account.settings.connections." + id) { EmptyView() }
        }
    }

    private var failedRow: some View {
        HStack(spacing: 12) {
            Text(words(AccountConnectionsCopy.readFailed))
                .font(.body)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("account.settings.connections.failed")
            Button(words(AccountConnectionsCopy.tryAgain)) {
                model.load = .loading
                Task { await model.reload(actions.read) }
            }
            .buttonStyle(.atumSecondary)
            .accessibilityIdentifier("account.settings.connections.retry")
        }
        .frame(minHeight: 52)
    }

    /// One connection: its mark, its name, one quiet line under it, and an
    /// optional status word or action at the end. At accessibility sizes the
    /// action goes under the text instead of squeezing it.
    private func connectionRow<Control: View>(lead: AnyView, title: String, line: String,
                                              status: String? = nil, identifier: String,
                                              @ViewBuilder control: () -> Control) -> some View {
        let text = VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.body)
                .foregroundStyle(atum.color(.ink, scheme: scheme))
            Text(line)
                .font(.footnote)
                .foregroundStyle(atum.color(.soft, scheme: scheme))
                .fixedSize(horizontal: false, vertical: true)
            if let status, dynamicTypeSize.isAccessibilitySize {
                Text(status).font(.subheadline).foregroundStyle(atum.color(.soft, scheme: scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, line, status].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier(identifier)

        let control = control()
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) { lead; text }
                    control
                }
            } else {
                HStack(spacing: 12) {
                    lead
                    text
                    if let status {
                        // The row's label already says it.
                        Text(status).font(.subheadline).foregroundStyle(atum.color(.soft, scheme: scheme))
                            .accessibilityHidden(true)
                    }
                    control
                }
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 52)
    }

    private func glyph(_ glyph: AtumGlyph) -> some View {
        Image(atum.symbol(glyph))
            .font(.body)
            .foregroundStyle(atum.color(.muted, scheme: scheme))
            .frame(width: 28)
            .accessibilityHidden(true)
    }

    private func words(_ phrase: AccountConnectionsCopy.Phrase) -> String {
        AccountConnectionsWords.text(phrase, design: design)
    }
}

struct AccountPlanConnectRequest: Identifiable, Equatable {
    let plan: AccountPlan
    /// A Work plan that is already connected on a Mac: the sheet only hands
    /// off to Atum on the Mac (desktop's Allow sheet on a device without Work)
    /// and does not follow the registry, which would read it as just landed.
    var handoff = false
    var id: String { plan.rawValue }
}

/// The one connect sheet (desktop `AccountConnectSheet`, owner Q1) as a
/// device without Work shows it: the plan's mark, "Connect {Plan}" and where
/// to connect, "Open Atum on your Mac to connect.", with Close. Signing in is
/// T3's own sign-in in Work on a Mac, so the phone never starts one and never
/// shows the consent sentence ("…through this Mac"): there is no Mac here.
///
/// While the sheet is open the phone follows the account read (every 3 s, for
/// at most 10 minutes, the desktop's `ACCOUNT_CONNECT_POLL_MS` and
/// `ACCOUNT_CONNECT_WAIT_MS`). When a Mac reports the plan connected, the
/// sheet says "{Plan} is connected" with a check and leaves after a beat
/// (`ACCOUNT_CONNECT_DONE_MS`), as the desktop's title band does.
struct AccountPlanConnectSheet: View {
    static let pollInterval: Duration = .seconds(3)
    static let waitLimit: Duration = .seconds(600)
    static let doneBeat: Duration = .milliseconds(2_500)

    let design: LiveDesign
    let plan: AccountPlan
    /// Makes the poll once, when the sheet first follows; nil: no follow.
    let makePoll: (@MainActor () -> @MainActor () async -> AccountConnections?)?
    let onLanded: @MainActor (AccountConnections) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var poll: (@MainActor () async -> AccountConnections?)?
    @State private var started: ContinuousClock.Instant?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false

    private var atum: AtumVisualSystem { AtumVisualSystem(design: design) }

    var body: some View {
        VStack(spacing: 16) {
            AccountPlanMark(design: design, plan: plan, size: 44)
                .padding(.top, 8)
            Text(words(AccountConnectionsCopy.sheetTitle(plan)))
                .font(.title3.weight(.semibold))
                .foregroundStyle(atum.color(.ink, scheme: scheme))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("connections.sheet.title")
            if landed {
                HStack(spacing: 8) {
                    Image(atum.symbol(.check))
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                        .accessibilityHidden(true)
                    Text(words(AccountConnectionsCopy.done(plan)))
                        .font(.body)
                        .foregroundStyle(atum.color(.ink, scheme: scheme))
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("connections.sheet.done")
                .transition(.opacity)
            } else {
                Text(words(AccountConnectionsCopy.needsMac))
                    .font(.body)
                    .foregroundStyle(atum.color(.soft, scheme: scheme))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connections.sheet.needs-mac")
            }
            Spacer(minLength: 0)
            Button(words(AccountConnectionsCopy.close)) { dismiss() }
                .buttonStyle(.atumSecondary)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("connections.sheet.close")
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .atumDesign(design)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Follow only while the scene is active: leaving it cancels the
        // loop (and a read in flight), and coming back resumes it.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active, !landed else { return }
            await follow()
        }
    }

    @MainActor private func follow() async {
        guard let makePoll else { return }
        // Made once, for the session that was current when the sheet opened.
        if poll == nil { poll = makePoll() }
        guard let poll else { return }
        let clock = ContinuousClock()
        // The 10-minute limit counts from the first follow, across pauses.
        if started == nil { started = clock.now }
        guard let started else { return }
        while clock.now - started < Self.waitLimit {
            do { try await Task.sleep(for: Self.pollInterval) } catch { return }
            guard scenePhase == .active else { return }
            guard let registry = await poll(), !Task.isCancelled else { continue }
            if AccountConnectionsView.connectLanded(registry, plan: plan) {
                onLanded(registry)
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { landed = true }
                UIAccessibility.post(notification: .announcement, argument: words(AccountConnectionsCopy.done(plan)))
                do { try await Task.sleep(for: Self.doneBeat) } catch { return }
                dismiss()
                return
            }
        }
    }

    private func words(_ phrase: AccountConnectionsCopy.Phrase) -> String {
        AccountConnectionsWords.text(phrase, design: design)
    }
}
