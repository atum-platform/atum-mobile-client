import AtumNativeAPI
import Foundation

/// The one formatter for every Proton amount the Store and Settings draw: the
/// Store balance chip, row prices, the item sheet and its review, Purchased,
/// the pack sheet and Settings › How Atum answers.
///
/// Desktop formats each of these with `Intl.NumberFormat(locale)` in the
/// window's language (`store/discover-view.tsx` `formatWhole`, `wallet-ui.ts`
/// `wholeProtons`/`microProtons`, `settings-revamp.tsx` `AccountPane`), so the
/// phone formats in the app's display language (`LiveDesign.locale`), never
/// the device region. One screen then shows one digit grouping: before this,
/// the chip could read "105.449" while a row read "8,000".
enum ProtonAmountFormat {
    /// A balance: whole Protons, floored and never negative, so spendable
    /// value is never overstated (desktop `wholeProtons`).
    static func balance(_ microProtons: Int64, locale: String) -> String {
        MicroProtonFormat.balance(microProtons, locale: locale)
    }

    /// A price or a charge: micro-Proton precision to the final digit, so no
    /// rounding turns one offer into another (desktop `microProtons`).
    static func price(_ microProtons: Int64, locale: String) -> String {
        MicroProtonFormat.string(microProtons, locale: locale)
    }

    @MainActor static func balance(_ microProtons: Int64, design: LiveDesign) -> String {
        balance(microProtons, locale: design.locale)
    }

    @MainActor static func price(_ microProtons: Int64, design: LiveDesign) -> String {
        price(microProtons, locale: design.locale)
    }
}
