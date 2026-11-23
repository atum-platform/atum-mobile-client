import AtumChat
import AtumNativeAPI
import Foundation
import Observation

/// Hiring an open listing from the New assistant sheet (desktop PR #100, D9
/// slice 1: `apps/desktop/src/matrix/listing-hire.tsx`). The sheet shows the
/// listings above its own form; picking one gives the sheet one focus at a
/// time: the price once when this is the third+ assistant, then hiring, then
/// done. The platform seeds the persona and skills, so nothing here writes a
/// definition, and the new assistant simply appears in the chats.

/// What one hire attempt answered (the model's `hireListing`).
enum ListingHireResult: Equatable, Sendable {
    /// The assistant exists and its chat is open.
    case hired
    /// The assistant exists (and its seat is paid), but its chat isn't open
    /// yet: the platform placed it as `capacity` or `pending_trust`, or its
    /// room hasn't reached this phone. The sheet waits for the chat.
    case settingUp(assistantID: NativeID)
    case refused(OpenAgentHireRefusal)
}

enum ListingHirePhase: Equatable, Sendable {
    /// Third+ assistant: the seat price, in whole Protons, before the hire.
    /// A price that isn't a positive number can't be confirmed.
    case confirm(priceProtons: Int64)
    case hiring
    /// Hired; its chat is still being set up. Done closes the sheet; the
    /// chat appears in the list once it opens.
    case settingUp(assistantID: NativeID)
    case done
    /// The wallet can't cover the seat: the short line and Top up.
    case short(priceProtons: Int64)
    /// `nil` is a retryable failure (Retry reuses the same request); the
    /// others are the platform's final answers, shown with Back only.
    case failed(Refusal?)

    enum Refusal: Equatable, Sendable { case name, limit, account }

    /// A short key for accessibility identifiers and logs.
    var kind: String {
        switch self {
        case .confirm: "confirm"
        case .hiring: "hiring"
        case .settingUp: "settingUp"
        case .done: "done"
        case .short: "short"
        case .failed: "failed"
        }
    }
}

struct ListingHireState: Equatable, Sendable {
    let listing: OpenAgentListing
    let name: String
    /// The signed-in account the hire was picked under (its Matrix ID). The
    /// hire, its confirmation and every answer belong to it alone.
    let account: String
    var phase: ListingHirePhase
    var hireConfirmed: Bool
}

/// One hire at a time: the phase it is in, and the moves between phases.
/// Owned above the sheet (by the app root), so leaving the sheet mid-hire
/// never drops it; the model resumes an unfinished hire of the same listing
/// under the same request either way (desktop `useListingHire`).
@MainActor @Observable final class ListingHireFlow {
    typealias Run = @MainActor (_ listing: OpenAgentListing, _ name: String,
                                _ hireConfirmed: Bool, _ account: String) async -> ListingHireResult

    private(set) var hire: ListingHireState?
    @ObservationIgnored private var run: Run?
    /// Bumped by every pick, reset and account change, so a late answer for
    /// a hire the person already left changes nothing.
    @ObservationIgnored private var generation = 0

    var isHiring: Bool { hire?.phase == .hiring }

    /// The person chose a listing: the price first when it costs, else
    /// straight to hiring. Ignored while another hire is under way.
    func pick(_ listing: OpenAgentListing, name: String, account: String, run: @escaping Run) {
        guard !isHiring else { return }
        generation += 1
        self.run = run
        hire = ListingHireState(
            listing: listing, name: name, account: account,
            phase: listing.hireRequired ? .confirm(priceProtons: listing.seatPriceProtons) : .hiring,
            hireConfirmed: false)
        if !listing.hireRequired { start(confirmed: false) }
    }

    /// Hire at the shown price. A price that isn't positive (a quote that
    /// couldn't be read) can't be confirmed; the model also refuses a
    /// confirmed hire while Apple checkout is closed.
    func confirm() {
        guard case let .confirm(price)? = hire?.phase, price > 0 else { return }
        start(confirmed: true)
    }

    func retry() {
        guard let hire, hire.phase == .failed(nil) else { return }
        start(confirmed: hire.hireConfirmed)
    }

    /// Protons arrived from the top-up sheet: the same price is one Hire away.
    func toppedUp() {
        guard case let .short(price)? = hire?.phase else { return }
        hire?.phase = .confirm(priceProtons: price)
    }

    /// The hired assistant's chat opened while the sheet waited for it.
    func chatAvailable() {
        guard case .settingUp? = hire?.phase else { return }
        hire?.phase = .done
    }

    /// Back, or Done. A hire under way can't be let go (desktop disables Back).
    func reset() {
        guard !isHiring else { return }
        drop()
    }

    /// The sheet went away: a hire still under way stays, so coming back
    /// shows it; any other state is let go (desktop `changeOpen`).
    func sheetClosed() {
        if !isHiring { reset() }
    }

    /// The signed-in account changed (or signed out): whatever the hire was
    /// doing, it belonged to the old account, so it is let go at once, even
    /// mid-hire. Its late answer is ignored, and its confirmation can never
    /// reach the new account's Retry. The model's own request finishes under
    /// the old account's client and ledger.
    func accountChanged(to account: String?) {
        guard let hire, hire.account != account else { return }
        drop()
    }

    private func drop() {
        generation += 1
        hire = nil
        run = nil
    }

    private func start(confirmed: Bool) {
        guard var current = hire, let run else { return }
        current.phase = .hiring
        current.hireConfirmed = current.hireConfirmed || confirmed
        hire = current
        let token = generation
        let target = current
        Task { @MainActor [weak self] in
            let result = await run(target.listing, target.name, target.hireConfirmed, target.account)
            guard let self, self.generation == token, self.hire?.account == target.account else { return }
            self.hire?.phase = Self.phase(after: result, listing: target.listing)
        }
    }

    static func phase(after result: ListingHireResult, listing: OpenAgentListing) -> ListingHirePhase {
        switch result {
        case .hired: .done
        case let .settingUp(assistantID): .settingUp(assistantID: assistantID)
        case let .refused(refusal):
            switch refusal {
            case let .hireRequired(price): .confirm(priceProtons: price ?? listing.seatPriceProtons)
            case .short: .short(priceProtons: listing.seatPriceProtons)
            case .name: .failed(.name)
            case .limit: .failed(.limit)
            case .account: .failed(.account)
            case .retry: .failed(nil)
            }
        }
    }
}

/// What the model sends for one hire attempt, decided before any POST: the
/// stored request when one is unfinished (its UUID, name and confirmation),
/// else a new one, and whether it may go out at all.
enum ListingHireRequestPlan: Equatable {
    /// POST this request; save it first, so a lost answer resumes it.
    case send(LiveListingHireStore.Pending, fresh: Bool)
    /// A confirmed hire (confirmed now, or stored with the request) can
    /// spend, and Apple checkout is closed: nothing goes out, and the sheet
    /// returns to the price with "Purchases are not available yet".
    case checkoutClosed

    static func make(earlier: LiveListingHireStore.Pending?, name: String, hireConfirmed: Bool,
                     checkoutOpen: Bool, newRequestID: () -> String?) -> ListingHireRequestPlan? {
        let confirmed = (earlier?.hireConfirmed ?? false) || hireConfirmed
        guard ListingHireGate.allowsRequest(confirmed: confirmed, checkoutOpen: checkoutOpen) else {
            return .checkoutClosed
        }
        if var pending = earlier {
            pending.hireConfirmed = confirmed
            return .send(pending, fresh: false)
        }
        guard let requestID = newRequestID() else { return nil }
        return .send(.init(requestID: requestID, name: name, hireConfirmed: confirmed), fresh: true)
    }
}

/// The name the hired assistant goes by: the listing's title in this
/// locale, numbered when the owner already has an assistant (or an app) of
/// that name, so the hire is never refused for it (desktop
/// `listingAssistantName`). Duplicates compare the platform's name key, so
/// "Re-searcher" or "Researcher 🔎" also counts. The person can rename it
/// later in conversation.
enum ListingAssistantName {
    static func name(for listing: OpenAgentListing, locale: String, others: [String],
                     apps: [String] = []) -> String {
        let base = AssistantNameCheck.normalized(listing.title(locale: locale))
        for candidate in [base] + (2...9).map({ "\(base) \($0)" }) {
            if AssistantNameCheck.problem(candidate, others: others, apps: apps) == nil {
                return AssistantNameCheck.normalized(candidate)
            }
        }
        return listing.displayName
    }
}

/// Paying for a seat is a Proton spend, so a paid hire follows the Store's
/// one spend rule (REL-15, `docs/ports/store-get-gate.md`): a free seat
/// always, a priced one only while Apple checkout is open.
enum ListingHireGate {
    /// Whether the confirm step offers Hire: a seat price read as a positive
    /// whole number, and open checkout. A zero or missing quote is not "free"
    /// here: the hire is required, so it stays unavailable until a real
    /// price is read.
    static func allowsPaidHire(priceProtons: Int64, checkoutOpen: Bool) -> Bool {
        priceProtons > 0 && checkoutOpen
    }

    /// Whether a POST may go out: one that carries a confirmation can spend,
    /// so it needs open checkout. An unconfirmed POST can't spend (the
    /// platform answers `hire_required` for a priced seat).
    static func allowsRequest(confirmed: Bool, checkoutOpen: Bool) -> Bool {
        !confirmed || checkoutOpen
    }
}
