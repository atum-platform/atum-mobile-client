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

    static func protons(_ microProtons: Int64) -> String {
        MicroProtonFormat.string(microProtons, locale: Locale.current.identifier)
    }

    /// Store timestamps are RFC 3339 with up to six fractional digits; a date
    /// is shown to the day, so the fraction is dropped before parsing.
    static func date(_ timestamp: NativeTimestamp) -> Date? {
        let whole = timestamp.rawValue.replacingOccurrences(of: #"\.[0-9]+"#, with: "",
                                                            options: .regularExpression)
        return ISO8601DateFormatter().date(from: whole)
    }
}
