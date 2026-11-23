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
    case hired
    case refused(OpenAgentHireRefusal)
}

enum ListingHirePhase: Equatable, Sendable {
    /// Third+ assistant: the seat price, in whole Protons, before the hire.
    case confirm(priceProtons: Int64)
    case hiring
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
        case .done: "done"
        case .short: "short"
        case .failed: "failed"
        }
    }
}

struct ListingHireState: Equatable, Sendable {
    let listing: OpenAgentListing
    let name: String
    var phase: ListingHirePhase
    var hireConfirmed: Bool
}

/// One hire at a time: the phase it is in, and the moves between phases.
/// Owned above the sheet (by the app root), so leaving the sheet mid-hire
/// never drops it; the model resumes an unfinished hire of the same listing
/// under the same request either way (desktop `useListingHire`).
@MainActor @Observable final class ListingHireFlow {
    typealias Run = @MainActor (_ listing: OpenAgentListing, _ name: String,
                                _ hireConfirmed: Bool) async -> ListingHireResult

    private(set) var hire: ListingHireState?
    @ObservationIgnored private var run: Run?
    /// Bumped by every pick and reset, so a late answer for a hire the
    /// person already left changes nothing.
    @ObservationIgnored private var generation = 0

    var isHiring: Bool { hire?.phase == .hiring }

    /// The person chose a listing: the price first when it costs, else
    /// straight to hiring. Ignored while another hire is under way.
    func pick(_ listing: OpenAgentListing, name: String, run: @escaping Run) {
        guard !isHiring else { return }
        generation += 1
        self.run = run
        hire = ListingHireState(
            listing: listing, name: name,
            phase: listing.hireRequired ? .confirm(priceProtons: listing.seatPriceProtons) : .hiring,
            hireConfirmed: false)
        if !listing.hireRequired { start(confirmed: false) }
    }

    func confirm() {
        guard case .confirm? = hire?.phase else { return }
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

    /// Back, or Done. A hire under way can't be let go (desktop disables Back).
    func reset() {
        guard !isHiring else { return }
        generation += 1
        hire = nil
        run = nil
    }

    /// The sheet went away: a hire still under way stays, so coming back
    /// shows it; any other state is let go (desktop `changeOpen`).
    func sheetClosed() {
        if !isHiring { reset() }
    }

    private func start(confirmed: Bool) {
        guard var current = hire, let run else { return }
        current.phase = .hiring
        current.hireConfirmed = current.hireConfirmed || confirmed
        hire = current
        let token = generation
        let target = current
        Task { @MainActor [weak self] in
            let result = await run(target.listing, target.name, target.hireConfirmed)
            guard let self, self.generation == token, self.hire != nil else { return }
            self.hire?.phase = Self.phase(after: result, listing: target.listing)
        }
    }

    static func phase(after result: ListingHireResult, listing: OpenAgentListing) -> ListingHirePhase {
        switch result {
        case .hired: .done
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

/// The name the hired assistant goes by: the listing's title in this
/// locale, numbered when the owner already has an assistant called that, so
/// the hire is never refused for it (desktop `listingAssistantName`). The
/// person can rename it later in conversation.
enum ListingAssistantName {
    static func name(for listing: OpenAgentListing, locale: String, others: [String]) -> String {
        let base = AssistantNameCheck.normalized(listing.title(locale: locale))
        for candidate in [base] + (2...9).map({ "\(base) \($0)" }) {
            if AssistantNameCheck.problem(candidate, others: others) == nil {
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
    static func allowsHire(priceProtons: Int64, checkoutOpen: Bool) -> Bool {
        StorePurchaseGate.allowsSpend(priceMicroProtons: priceProtons, checkoutOpen: checkoutOpen)
    }
}
