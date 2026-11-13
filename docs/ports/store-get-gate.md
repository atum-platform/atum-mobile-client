# Store Get gate (REL-15)

## Why

A public build could spend Protons on a paid Store item: nothing gated the item
sheet's Get (`StoreItemSheet.actionContent`, `.ready` → `store.detail.acquire`
→ `LiveStoreCommerce.confirm` → `NativeDomainClient.acquireStoreItem`). In-app
purchase of Protons is not live yet (first territory: Vietnam only), so the
owner approved hiding the paid Get while purchases are closed.

## Signal

No new flag. The gate reuses `ApplePurchaseCoordinator.checkoutOpen`, the
existing "purchases open" authority (`docs/implementation/mobile-purchases-phase1.md`):

- the server's `apple_checkout_enabled` switch (`checkoutOpen` on
  `GET /api/matrix/v1/store/apple/products`), which starts false;
- the device's verified StoreKit environment matching the catalogue's
  (`iap-storekit-environment-guard.md`); Xcode/unknown never matches;
- the approved products loaded with a StoreKit `displayPrice`.

It is false while loading, closed, mismatched, after a sandbox-cap or closed
reply, and wherever no `\.protonTopUp` context is installed. A Release or
TestFlight build therefore fails closed until the server opens checkout for
that account and environment. Debug scripted scenarios open it through the
synthetic Apple catalogue (`store.acquire` etc.) and close it with `store.closed`.

Territory is not decided on the phone: it follows App Store Connect
availability and the server switch.

## Behaviour

`StorePurchaseGate.allowsSpend(priceMicroProtons:checkoutOpen:)` is the one
decision: free (price 0) always, paid only while checkout is open.

In the item sheet (`StoreItemSheet`), mirrored from `checkoutOpen` via
`onReceive` (initially false):

- a paid item whose quote is ready, or which is short of Protons, becomes the
  `purchasesClosed` phase: no Get, no top-up button, no balance row, and one
  quiet line in the action's place (`store.detail.closed`), using the existing
  export `src.matrix.mobile-copy.mobilePhoneCopy.noPurchasesTitle`
  ("Purchases are not available yet"; vi "Chưa thể mua hàng") — already in all
  five locales, so no new strings;
- free items keep Get → review → Confirm; owned items keep Open; pending,
  unresolved (Check status), read failures and other blocks are unchanged;
- the review's Confirm re-checks the gate at the moment Protons would move.

The Store rows only open the item sheet; they have no Get of their own, so no
row change. No Proton paid/bonus split or rate is shown anywhere (owner rule).

## Follow-up: header entry and the settling state (owner, 2026-11-13)

The owner ruled on three points while Apple checkout is closed:

1. **The header balance drops its Proton-pack entry.** `StoreScreen.balanceChip`
   is the top-up button only when `StorePurchaseGate.showsTopUpEntry` says so,
   i.e. once the coordinator reports checkout open. Until then (settling,
   closed, mismatched, no `\.protonTopUp` context) it is the plain balance: same
   mark, same whole Protons, same `store.balance` identifier and VoiceOver
   label, no button and no sheet. It fails closed: the mirror starts at
   `.settling`.
2. **Paid prices stay visible.** No change: the rows keep their price, and
   the item sheet keeps its price rows in the closed and settling phases
   (`Phase.showsPrice`). Only Get, top-up and the balance row go.
3. **No "not available" flash on an open build.** The sheet and the header
   now mirror `StorePurchaseGate.Checkout`, derived from the coordinator's
   existing `state` and `checkoutOpen` (no coordinator change):
   - `open`: `checkoutOpen == true`;
   - `settling`: not open and the state is `idle` (no answer yet) or `loading`;
   - `closed`: any other state without `checkoutOpen` (`closed`,
     `unavailable` for a mismatch or a failed load, `sandboxCapExceeded`, …),
     and wherever no top-up context is installed.

   A paid item whose quote is ready, or which is short of Protons, shows the
   sheet's existing loading phase while settling (`store.detail.loading`:
   `AtomWait`, labelled with the existing `desktop.atum.discover.catalogLoading`
   export, no Get, no closed line), then Get once open or the closed line
   once closed (`StorePurchaseGate.paidAction`). No new strings.

The spend path is unchanged and still fails closed: Get exists only in the
`ready` phase, which needs `checkout == .open`; Confirm still re-reads
`ApplePurchaseCoordinator.checkoutOpen` itself (`allowsSpend`). Free items
keep Get in every state.

A foreground reload (`load()` sets `loading`) moves an open checkout back to
settling for its duration: the sheet shows the wait instead of Get, never the
closed line. A coordinator that stays `idle` (no account or API bound) would
keep the wait; in the app the Store is reached only signed in, where
`LiveAppModel` binds the coordinator, so this is not expected to show.

## Tests

- `AppTests/StoreCommercePresentationTests.testStoreGateHidesPaidSpendWhileCheckoutIsClosed`
  (decision table, English copy) and the five-locale key test (now includes
  `StoreCopyKey.purchasesClosed`).
- `UITests/StoreCommerceUITests.testClosedCheckoutHidesPaidGetAndTopUp` and
  `testClosedCheckoutKeepsFreeItemGettable` over `store.closed`.
- Coordinator closed/unavailable → `checkoutOpen == false` is already covered in
  `Tests/ApplePurchaseCoordinatorTests`.
- Follow-up (2026-11-13): `AppTests/StoreCommercePresentationTests.testCheckoutSettlingShowsNeitherGetNorClosedLine`
  (state → `Checkout`, `paidAction`, `showsTopUpEntry`, free spend unchanged);
  `UITests/StoreCommerceUITests.testClosedCheckoutHidesHeaderTopUpButKeepsBalanceAndPrices`
  over `store.closed`, and `testSettlingCheckoutWaitsNeutrallyThenOffersGet` and
  `testSettlingCheckoutKeepsHeaderEntryHiddenUntilOpen` over the new scripted
  scenario `store.checkout-slow` (`acquire`, but the synthetic Apple catalogue
  answers open after 20 s, long enough for the test to open an item first). `testStoreBalanceOpensThePackSheet` now waits for the
  balance *button*, which appears once checkout opens.

## Verification

One script under the shared heavy-build lock (`TMPDIR=/Volumes/AtumTestFlight/tmp
lockf -k /Volumes/AtumTestFlight/.heavy-build.lock …`), iPhone 17 simulator,
Debug, `-jobs 2`, `CODE_SIGNING_ALLOWED=NO`, 2026-11-12:

| Command | Result |
| --- | --- |
| `swift test --package-path ios -j 2 --scratch-path …/swiftbuild-storegate` | PASS, 650 tests, 0 failures |
| `xcodebuild … build-for-testing` at `55223b6` (scenario + tests, no gate) | BUILD SUCCEEDED |
| `… -only-testing:AtumMobileUITests/StoreCommerceUITests/testClosedCheckout* test-without-building` at `55223b6` | Expected red: paid test FAILS (Get "Nhận · 90" shown with checkout closed); free test passes |
| `xcodebuild … build-for-testing` at `811c032` (gate) | BUILD SUCCEEDED |
| `… -only-testing:AtumMobileTests test-without-building` | PASS, 356 tests, 0 failures |
| `… -only-testing:AtumMobileUITests/StoreCommerceUITests test-without-building` | PASS, 8 tests, 0 failures (2 new + 6 existing) |
| `python3 scripts/public_guard.py --base d21c3d4 --head feat/store-get-gate`, `import-design-exports --verify`, `plutil -lint`, `git diff --check` | PASS |

Before/after captures (local only, not committed):
`/Volumes/AtumTestFlight/store-get-gate-shots/{before,after}-StoreCommerceUITests.U-Store-1{3-paid,4-free}-checkout-closed-light-vi.png`.
The captures' `U-Store-13` prefix also appears on the existing pack-sheet captures;
the names differ after the prefix.
