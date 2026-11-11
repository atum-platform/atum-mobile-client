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
row change. The Store header's balance still opens the pack sheet, which shows
its own existing closed state. No Proton paid/bonus split or rate is shown
anywhere (owner rule).

Known trade-off: on a build with checkout open, a paid item shows the closed
line for the moment before the coordinator's catalogue load finishes (and
during a foreground reload), then Get. Fail-closed by design.

## Tests

- `AppTests/StoreCommercePresentationTests.testStoreGateHidesPaidSpendWhileCheckoutIsClosed`
  (decision table, English copy) and the five-locale key test (now includes
  `StoreCopyKey.purchasesClosed`).
- `UITests/StoreCommerceUITests.testClosedCheckoutHidesPaidGetAndTopUp` and
  `testClosedCheckoutKeepsFreeItemGettable` over `store.closed`.
- Coordinator closed/unavailable → `checkoutOpen == false` is already covered in
  `Tests/ApplePurchaseCoordinatorTests`.

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
