import AtumNativeAPI
import Foundation

/// Every visible word on the Store's item, review, Purchased and renewal
/// surfaces: existing five-locale exports only, never a Swift literal. Copy the
/// export does not have yet stays off screen (see `docs/ports/store-parity.md`).
enum StoreCopyKey {
    private static let device = "src.matrix.mobile-device-copy.mobileDeviceCopy."

    static let detailTitle = device + "storeDetailTitle"
    static let detailPending = device + "storeDetailStatesDeliveryPendingText"
    static let detailNoAssistant = device + "storeDetailStatesNoAssistantText"
    static let detailNoOffer = device + "storeDetailStatesNoOfferText"
    static let recipientTitle = device + "storeRecipientTitle"
    static let recipientBody = device + "storeRecipientBody"
    static let recipientOwned = device + "storeRecipientStatesAlreadyOwnedText"
    static let recipientNone = device + "storeRecipientStatesNoAssistantText"
    static let reviewTitle = device + "storeReviewTitle"
    static let reviewBody = device + "storeReviewBody"
    static let reviewItem = device + "storeReviewRows0Label"
    static let reviewRecipient = device + "storeReviewRows1Label"
    static let reviewPrice = device + "storeReviewRows2Label"
    static let walletLabel = device + "accountRowsWalletLabel"
    static let deliveryTitle = device + "storeDeliveryTitle"
    static let deliveryDelivered = device + "storeDeliveryStatesDeliveredText"
    static let deliveryPending = device + "storeDeliveryStatesDeliveryPendingText"
    static let deliveryRecorded = device + "storeDeliveryStatesRecordedText"
    static let deliveryRefunded = device + "storeDeliveryStatesRefundedText"
    static let deliveryUncertain = device + "storeDeliveryStatesUncertainText"
    static let purchasedTitle = device + "storePurchasedTitle"
    static let purchasedCancelledRenewal = device + "storePurchasedStatesCancelledRenewalText"
    static let purchasedRevoked = device + "storePurchasedStatesRevokedText"
    static let renewal = device + "uiRenewal"
    static let historyTitle = device + "walletHistoryTitle"
    static let storeUnavailable = device + "storeStatesUnavailableText"

    static let buyFor = "desktop.atum.discover.buyFor"
    static let protons = "desktop.atum.discover.protons"
    static let owned = "desktop.atum.discover.owned"
    static let ownedEmpty = "desktop.atum.discover.ownedEmpty"
    static let free = "desktop.atum.discover.free"
    static let notForSale = "desktop.atum.discover.unavailable"
    static let insufficient = "desktop.atum.discover.insufficientProtons"
    static let offerChanged = "desktop.atum.discover.offerChanged"
    static let uncertain = "desktop.atum.discover.purchaseUncertain"
    static let failed = "desktop.atum.discover.purchaseFailed"
    static let purchaseUnavailable = "desktop.atum.discover.purchaseUnavailable"
    static let checkStatus = "desktop.atum.discover.checkPurchase"
    static let tryExample = "desktop.atum.discover.tryExample"
    static let open = "desktop.atum.discover.open"
    static let comingSoon = "desktop.atum.discover.comingSoon"
    static let loading = "desktop.atum.discover.catalogLoading"
    static let confirm = "desktop.common.confirm"
    static let cancel = "desktop.common.cancel"
    static let back = "desktop.common.back"
    static let close = "desktop.common.close"
    static let done = "desktop.common.done"
    static let busy = "desktop.common.loading"
    static let retry = "src.matrix.chat-copy.copies.retry"
    static let offline = "src.matrix.chat-copy.copies.errorOffline"
    static let genericError = "src.matrix.chat-copy.copies.errorGeneric"
    static let denied = "desktop.dm.artifact.state.denied.title"

    /// Every key above, for the five-locale presence test.
    static let all: [String] = [
        detailTitle, detailPending, detailNoAssistant, detailNoOffer, recipientTitle,
        recipientBody, recipientOwned, recipientNone, reviewTitle, reviewBody, reviewItem,
        reviewRecipient, reviewPrice, walletLabel, deliveryTitle, deliveryDelivered,
        deliveryPending, deliveryRecorded, deliveryRefunded, deliveryUncertain, purchasedTitle,
        purchasedCancelledRenewal, purchasedRevoked, renewal, historyTitle, storeUnavailable,
        buyFor, protons, owned, ownedEmpty, free, notForSale, insufficient, offerChanged,
        uncertain, failed, purchaseUnavailable, checkStatus, tryExample, open, comingSoon,
        loading, confirm, cancel, back, close, done, busy, retry, offline, genericError, denied,
    ]
}

/// A notice's meaning, kept apart from SwiftUI so each outcome's wording is
/// tested: a definite refusal says nothing was charged; an unanswered write
/// never does, and keeps its original key for Check status.
struct StoreNotice: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case neutral, warning, danger, done }
    let key: String
    let tone: Tone
}

enum StoreOutcome: Equatable, Sendable {
    /// The item can be used (or is owned already): the sheet offers Done.
    case settled
    /// Delivery or a refund is still to land; nothing more to confirm.
    case recorded
    /// The original intent may have been charged: offer Check status, never a new purchase.
    case recover
    /// The offer changed: the person must confirm the new price.
    case requote
    /// Definite: nothing was sent or nothing was charged.
    case stopped
}

enum StoreOutcomePresentation {
    static func notice(for state: StoreAcquireState, kind: LiveProductStoreItemKind) -> StoreNotice? {
        switch state {
        case .idle, .working: return nil
        case .insufficientBalance: return .init(key: StoreCopyKey.insufficient, tone: .neutral)
        case .offline: return .init(key: StoreCopyKey.offline, tone: .warning)
        case .forbidden: return .init(key: StoreCopyKey.denied, tone: .danger)
        case .unavailable: return .init(key: StoreCopyKey.purchaseUnavailable, tone: .danger)
        case .uncertain: return .init(key: StoreCopyKey.uncertain, tone: .warning)
        case .result(let result):
            switch result {
            case .purchased(let purchase, _):
                return .init(key: purchaseKey(purchase.state, detail: true),
                             tone: purchase.state == .reversed || purchase.state == .deliveryPending ? .neutral : .done)
            case .alreadyOwned:
                return .init(key: kind == .skill ? StoreCopyKey.recipientOwned : StoreCopyKey.owned, tone: .done)
            case .offerChanged: return .init(key: StoreCopyKey.offerChanged, tone: .warning)
            case .refused(let code):
                switch code {
                case .insufficientProtons: return .init(key: StoreCopyKey.insufficient, tone: .neutral)
                case .offerUnavailable, .featureUnavailable:
                    return .init(key: StoreCopyKey.purchaseUnavailable, tone: .danger)
                case .forbidden, .petCreditReserved: return .init(key: StoreCopyKey.failed, tone: .danger)
                }
            }
        }
    }

    /// What the review step offers next. Forbidden and offline keep a saved
    /// intent recoverable: a denial does not prove an earlier send was uncharged.
    static func outcome(for state: StoreAcquireState, hasSavedAttempt: Bool) -> StoreOutcome? {
        switch state {
        case .idle, .working: return nil
        case .uncertain: return .recover
        case .forbidden, .offline: return hasSavedAttempt ? .recover : .stopped
        case .insufficientBalance, .unavailable: return .stopped
        case .result(let result):
            switch result {
            case .purchased(let purchase, _):
                switch purchase.state {
                case .granted, .completed: return .settled
                case .deliveryPending, .reversed: return .recorded
                }
            case .alreadyOwned: return .settled
            case .offerChanged: return .requote
            case .refused: return .stopped
            }
        }
    }

    /// One purchase record's state. The item sheet speaks of the item; the
    /// Purchased history speaks of delivery.
    static func purchaseKey(_ state: StorePurchase.State, detail: Bool = false) -> String {
        switch state {
        case .deliveryPending: detail ? StoreCopyKey.detailPending : StoreCopyKey.deliveryPending
        case .granted: detail ? StoreCopyKey.deliveryDelivered : StoreCopyKey.deliveryRecorded
        case .completed: StoreCopyKey.deliveryDelivered
        case .reversed: StoreCopyKey.deliveryRefunded
        }
    }

    /// Review gate failures: plain status, never a top-up or a way around it.
    static func notice(for failure: LiveStoreCommerce.ReviewFailure, kind: LiveProductStoreItemKind,
                       hasEligibleAssistant: Bool) -> StoreNotice {
        switch failure {
        case .unavailable: .init(key: StoreCopyKey.purchaseUnavailable, tone: .neutral)
        case .alreadyOwned: .init(key: kind == .skill ? StoreCopyKey.recipientOwned : StoreCopyKey.owned, tone: .done)
        case .unresolvedPurchase: .init(key: StoreCopyKey.deliveryUncertain, tone: .warning)
        case .noEligibleAssistant:
            .init(key: hasEligibleAssistant ? StoreCopyKey.detailNoAssistant : StoreCopyKey.recipientNone,
                  tone: .neutral)
        case .insufficientBalance: .init(key: StoreCopyKey.insufficient, tone: .neutral)
        }
    }

    /// A price in the Store's one Proton format (`ProtonAmountFormat`).
    static func protons(_ microProtons: Int64, locale: String) -> String {
        ProtonAmountFormat.price(microProtons, locale: locale)
    }

    /// Store timestamps are RFC 3339 with up to six fractional digits; a date
    /// is shown to the day, so the fraction is dropped before parsing.
    static func date(_ timestamp: NativeTimestamp) -> Date? {
        let whole = timestamp.rawValue.replacingOccurrences(of: #"\.[0-9]+"#, with: "",
                                                            options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole)
    }
}

/// Desktop storePriceParts (store-card.tsx:129–146), using the export for words.
/// Monthly keys arrive with the wave 1 copy repin (desktop `c14d74a`); until then the placeholders
/// name the missing key and retain the exact amount instead of hiding a cost.
enum StorePricePresentation {
    enum CopyKey {
        // PENDING-COPY:src.matrix.mobile-copy.mobileScreensCopy.store.monthly
        static let monthly = "src.matrix.mobile-copy.mobileScreensCopy.store.monthly"
        // PENDING-COPY:src.matrix.mobile-copy.mobileScreensCopy.store.monthlyFirst
        static let monthlyFirst = "src.matrix.mobile-copy.mobileScreensCopy.store.monthlyFirst"
        // PENDING-COPY:src.matrix.mobile-copy.mobileScreensCopy.store.monthlyFreeFirst
        static let monthlyFreeFirst = "src.matrix.mobile-copy.mobileScreensCopy.store.monthlyFreeFirst"
        // PENDING-COPY:src.matrix.mobile-copy.mobileScreensCopy.store.monthlyThen
        static let monthlyThen = "src.matrix.mobile-copy.mobileScreensCopy.store.monthlyThen"
        static let pending = [monthly, monthlyFirst, monthlyFreeFirst, monthlyThen]
    }

    static func parts(_ offer: StoreCatalogOffer, locale: String,
                      copy: (String, [String]) -> String) -> [String] {
        func amount(_ value: Int64) -> String { ProtonAmountFormat.price(value, locale: locale) }
        return offer.priceParts.map { part in
            switch part {
            case .free: return copy(StoreCopyKey.free, [])
            case .amount(let value): return copy(StoreCopyKey.protons, [amount(value)])
            case .monthly(let value):
                return copy(StoreCopyKey.protons, [amount(value)]) + " " + copy(CopyKey.monthly, [])
            case .firstMonth(let value): return copy(CopyKey.monthlyFirst, [amount(value)])
            case .freeFirstMonth: return copy(CopyKey.monthlyFreeFirst, [])
            case .thenMonthly(let value): return copy(CopyKey.monthlyThen, [amount(value)])
            }
        }
    }

    @MainActor static func text(_ offer: StoreCatalogOffer, design: LiveDesign) -> String {
        parts(offer, locale: design.locale) { key, arguments in
            if CopyKey.pending.contains(key),
               (try? design.copy.text(key, locale: design.locale,
                                      arguments: arguments.map { .text($0) })) == nil {
                return ([key] + arguments).joined(separator: " ")
            }
            return design.text(key, arguments: arguments.map { .text($0) })
        }.joined(separator: " · ")
    }
}

/// One Store row as the shelves list it: a catalog item, or the one Hatch
/// card the two hatch rows fold into. `regularOffer` is set only while the
/// first-hatch price stands in for a higher regular one (desktop
/// `hatch-listing.ts:26-47`), so the row can strike the regular price through.
struct StoreListing: Identifiable, Equatable {
    let item: LiveProductStoreItem
    var regularOffer: StoreCatalogOffer? = nil
    var id: String { item.id }
}

/// Desktop's Store shelves (`store-sidebar.tsx:14-21`, `discover-view.tsx:498-560`)
/// on one phone list: Featured, Skills, Assistants, Apps, Pets, then Purchased.
/// Featured items also sit in their kind's shelf. A query filters every shelf
/// (accent- and đ-insensitive, `StoreSearch`).
struct StoreShelfPlan: Equatable {
    static let regularHatchID = "pet/hatch"
    static let firstHatchID = "pet/hatch-first"

    /// The catalog IDs one row stands for: the folded Hatch card is both
    /// Hatch items, so ownership and pending purchases count across both.
    static func itemIDs(for id: String) -> Set<String> {
        id == firstHatchID || id == regularHatchID ? [firstHatchID, regularHatchID] : [id]
    }

    let featured: [StoreListing]
    let skills: [StoreListing]
    let assistants: [StoreListing]
    let apps: [LiveProductStoreApp]
    let pets: [StoreListing]
    let searching: Bool

    var isEmpty: Bool {
        featured.isEmpty && skills.isEmpty && assistants.isEmpty && apps.isEmpty && pets.isEmpty
    }

    init(items: [LiveProductStoreItem], apps: [LiveProductStoreApp], query: String) {
        searching = !StoreSearch.normalized(query).isEmpty
        let listings = Self.listings(items).filter { listing in
            StoreSearch.matches(query, fields: [Self.kindWord(listing.item.kind), listing.item.title,
                                                listing.item.summary])
        }
        featured = listings.filter(\.item.featured)
        skills = listings.filter { $0.item.kind == .skill }
        assistants = listings.filter { $0.item.kind == .agent }
        pets = listings.filter { $0.item.kind == .pet }
        self.apps = apps.filter { StoreSearch.matches(query, fields: [$0.slug, $0.title, $0.subtitle ?? ""]) }
    }

    /// Desktop matches the wire kind word, not a localized label.
    static func kindWord(_ kind: LiveProductStoreItemKind) -> String {
        switch kind {
        case .skill: "skill"
        case .agent: "agent"
        case .pet: "pet"
        }
    }

    /// The two hatch rows are one card while the catalog lists the first-hatch
    /// offer (the server lists it only to an account that hasn't used it). The
    /// card keeps the first-hatch item, so a review quotes the price shown, and
    /// wears the regular card's words and art; an owned row wins.
    static func listings(_ items: [LiveProductStoreItem]) -> [StoreListing] {
        guard let first = items.first(where: { $0.id == firstHatchID }), let firstOffer = first.offer,
              let regular = items.first(where: { $0.id == regularHatchID }) else {
            return items.map { StoreListing(item: $0) }
        }
        let ownership = [regular, first].first { $0.ownership?.state == .owned }?.ownership ?? first.ownership
        let card = LiveProductStoreItem(
            id: first.id, kind: regular.kind, title: regular.title, summary: regular.summary,
            glyph: regular.glyph, featured: regular.featured || first.featured, price: first.price,
            accent: regular.accent, art: regular.art ?? first.art,
            detailDescription: regular.detailDescription, tryPrompt: regular.tryPrompt,
            offer: firstOffer, ownership: ownership, deliverable: first.deliverable,
            needs: regular.needs, install: first.install)
        let regularOffer = regular.offer.flatMap { $0.priceMicroProtons > firstOffer.priceMicroProtons ? $0 : nil }
        let position = min(items.firstIndex { $0.id == first.id }!, items.firstIndex { $0.id == regular.id }!)
        var result = items.filter { $0.id != first.id && $0.id != regular.id }.map { StoreListing(item: $0) }
        result.insert(StoreListing(item: card, regularOffer: regularOffer), at: min(position, result.count))
        return result
    }
}

/// Desktop `storeRequirements` (`store-copy.ts:791-793`): the requirement
/// tokens the export can name, in catalog order; unknown tokens are not shown.
enum StoreRequirementPresentation {
    static let keys: [String: String] = [
        "internet": "desktop.atum.discover.needsInternet",
        "runs-scripts": "desktop.atum.discover.needsScripts",
    ]

    static func keys(for needs: [String]) -> [String] {
        var seen = Set<String>()
        return needs.compactMap { keys[$0] }.filter { seen.insert($0).inserted }
    }
}

/// Shelf and action words from the current desktop Store copy
/// (`store-copy.ts`, exported under `mobileScreensCopy.store`, wave 1 repin).
enum StoreShelfCopyKey {
    private static let store = "src.matrix.mobile-copy.mobileScreensCopy.store."

    static let featured = store + "featured"
    static let skills = store + "skills"
    static let assistants = store + "assistants"
    static let apps = store + "apps"
    static let pets = store + "pets"
    static let getWithPrice = store + "getWithPrice"
    static let get = store + "get"
    // PENDING-COPY: desktop `search` ("Search the store") is not exported; the
    // device "Search" word stands in.
    static let search = "src.matrix.mobile-device-copy.mobileDeviceCopy.uiSearch"
    static let empty = "src.matrix.mobile-copy.mobilePhoneCopy.storeEmpty"

    static let all: [String] = [featured, skills, assistants, apps, pets, getWithPrice, get, search, empty]
        + StoreRequirementPresentation.keys.values.sorted()
}
