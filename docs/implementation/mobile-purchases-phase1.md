# Apple Proton purchases: Phase 1 non-UI hand-off (2026-11-10)

Scope: frozen d1 consumer, StoreKit 2 adapter, observable coordinator, lifecycle,
synthetic tests and local StoreKit configuration. No SwiftUI view, Store/Wallet
layout, signing, entitlement, App Store Connect, deployment or payment changes.
No push, PR, remote CI or cross-agent review is part of this checkpoint.

## Contract and provenance

The runtime core is retained from the verified implementation
`bfc15f01a7c88d6e0476040826d82c139eb53b07`, applied onto public `origin/main`
without committing any of its private fixture files. `ApplePurchases`,
`ApplePurchaseCoordinator`, `StoreKitPurchaseStore`, native API routes and
`LiveAppModel` wiring are unchanged. No purchase UI was added.

Per the owner's 2026-11-10 publication decision, only the upstream `README.md`
and `contract.json` are vendored byte-for-byte from `atum-platform/atum-platform`
`7df04652c7c1ce39f757891e01e0d14951db31bb`, `spec/mobile-purchases/v1/`.
`PUBLIC-PROVENANCE.md` records the upstream full-pack SHA-256:

`5f607d7ef5395dfc9a0e706eb1c1f8d7c73f2334a418467c28c548e645b9166f`

The full pack and its digest verification remain in the private `atum-mobile`
repository. Public `PINNED-SHA256` instead lists the individual SHA-256 digests of
`README.md` and `contract.json`. `verify-native-purchase-contract.py` verifies
those exact public bytes and refuses a private fixture directory. The upstream
contract's fixture inventory describes the private pack, not files to publish.
No guard policy, gitleaks exception or identifier adjudication was added.

`ApplePurchaseTestData.swift` builds all 24 d1 acceptance cases in code: open,
closed and wrong-product catalogs; account token; transaction requests including
forbidden principal; credited, replayed, support and missing-finish responses;
notification; server facts including wrong bundle, environment and missing token;
errors including guessed outcome; refund/reversal, duplicate credit, support and
orphan sequences. Payloads such as `header.payload.sig` and the zero-filled
UUID ending in `00aa` are plainly fake; Swift amount literals use digit separators.
No private JWS, fixture bytes or projections are retained. Server-only examples
are acceptance evidence, never client authority or proof of server verification.

The public fixture projector and its Python projection test are replaced by the
contract checksum verifier and integrity/configuration tests in both public CI
lanes. Swift tests no longer load purchase JSON resources. Coordinator and native
transport tests use the same builders directly.

Final owner packs (2026-11-10):

| Product ID | Price | Paid Protons | Bonus Protons | Total |
| --- | --- | --- | --- | --- |
| `com.atum.mobile.protons.100k` | 95,000 ₫ | 95,000 | 5,000 | 100,000 |
| `com.atum.mobile.protons.500k` | 395,000 ₫ | 395,000 | 105,000 | 500,000 |

The frozen d1 sample uses `…pack_100k`, still valid d1 syntax. Public contract
examples retain that shape while coordinator tests build the two final owner
SKUs directly. Prices live in App Store Connect; the runtime still displays only
StoreKit's localized `displayPrice`. Updating this local file does not configure
App Store Connect or enable checkout.

## Behavior and trust boundaries

The three exact `/api/matrix/v1/store/apple/{products,account-token,transactions}`
operations reuse `NativeDomainClient`'s MAS domain authorization, refresh, bounded
ephemeral transport, redirect refusal and cookie isolation. Only transaction POST
accepts a body: `{signedTransaction}`. Apple 422 errors use a separate closed
error decoder without expanding every native API route's error contract. HTTP
status/envelope mismatches fail decoding. Only 2xx responses reach transaction
acknowledgment decoding.

`StoreKitPurchaseStore` loads consumables by catalog IDs and passes
`.appAccountToken(token)` to StoreKit. The token is cached in process for the
current account/environment, retained across client refresh, and discarded on an
account switch or sign-out. No bearer, account token, VerificationResult or signed
payload is logged or persisted by this implementation.

A verified purchase or update is submitted once per in-flight transaction ID.
Only a matching transaction ID in a 2xx typed response with `finish: true` permits
`transaction.finish()`. Errors, malformed replies, wrong transaction IDs and
`finish: false` leave it unfinished and retry at 2, 4, 8, …, 300 seconds (capped).
Every d1 committed state, including `needs_support`, can be finished. Credited or
already credited purchases refresh the wallet; no local amount is added.

Pending / cancelled / unverified purchase results send nothing. Approved pending
purchases arrive through `Transaction.updates`. Xcode / LocalTesting results are
excluded from deployed-server submission. There is no `currentEntitlements` or
`AppStore.sync` path for these consumables.

`LiveAppModel.observeScenePhase()` starts the long-lived listener at launch.
Binding domain authority loads products and replays `Transaction.unfinished`.
Foreground activation replays unfinished transactions. Restore refreshes the
wallet and replays unfinished transactions, even with checkout closed. Loss or
replacement of account context, replacement of domain authority, and sign-out
cancel old submission/retry tasks. Generation checks discard late old-account
replies before finish or presentation. StoreKit retains any unfinished payment.

## UI hand-off

`LiveAppModel.applePurchases` is a main-actor `ObservableObject`:

- `products`: owner-approved StoreKit IDs and **only StoreKit's `displayPrice`**.
- `packs`: the corresponding server pack IDs and paid/bonus micro-Proton amounts.
- `checkoutOpen`: effective checkout authority; false while loading, closed,
  mismatched environment or product lookup failure.
- `canPurchase`: the purchase-button gate. Do not render a purchase CTA unless it
  is true. It also prevents another attempt while payment is purchasing, pending
  or retrying. Balance display may remain available independently.
- `purchaseStates[productID]` / `purchaseState(for:)`: latest product attempt;
  absent entries return `idle`. Required cases are `idle`, `purchasing`, `pending`,
  `cancelled`, `succeeded`, and `needsSupport(transactionID)`.
- `state`: aggregate catalog/attempt presentation, also including `loading`,
  `ready`, `closed`, `unavailable`, `retrying`, `otherAccount`, and `revoked`.

Use `await purchase(productID)`, `await load()` for a deliberate catalog retry,
and `await restore()` for balance recovery. The app model already owns launch,
foreground, account binding and wallet refresh. Do not create a coordinator per
sheet. Keep the injected environment matched to the build's fixed API origin.
`needsSupport` must display its transaction ID and the approved support contact.
Never mention or link to purchasing outside the iPhone app.

Existing five-locale keys suitable for the UI:

- `src.matrix.mobile-copy.mobilePhoneCopy.purchaseTitle`
- `src.matrix.mobile-copy.mobilePhoneCopy.purchaseHelp`
- `src.matrix.mobile-copy.mobilePhoneCopy.purchasePending`
- `src.matrix.mobile-copy.mobilePhoneCopy.purchaseCreditPending`
- `src.matrix.mobile-copy.mobilePhoneCopy.purchaseCancelled`
- `src.matrix.mobile-copy.mobilePhoneCopy.purchaseComplete`
- `src.matrix.mobile-copy.mobilePhoneCopy.restorePurchases`
- `src.matrix.mobile-copy.mobilePhoneCopy.noPurchasesTitle`
- `src.matrix.mobile-copy.mobilePhoneCopy.noPurchasesHelp`
- `src.matrix.mobile-device-copy.mobileDeviceCopy.walletStatesNeedsSupportText`
- `src.matrix.mobile-device-copy.mobileDeviceCopy.walletStatesOtherAccountText`
- `src.matrix.mobile-device-copy.mobileDeviceCopy.walletStatesRefundedText`
- `desktop.atum.protons.checkout.buy`
- `src.matrix.founder.founder-copy.FOUNDER_COPY.emailSupport`

Missing export bindings: a transaction-ID label and the approved support contact
address. Suggested new producer keys (not added to Vendor or replaced by Swift
literals): `src.matrix.mobile-copy.mobilePhoneCopy.purchaseTransactionID` and
`src.matrix.mobile-copy.mobilePhoneCopy.purchaseSupportContact`. The UI owner
must request/export them in all five locales before rendering those labels/data.
The backend's transaction ID is data, not a localized string.

## Local StoreKit scenarios

`ios/StoreKit/ProtonPacks.storekit` contains only the two non-family-shareable
consumables at 95,000 ₫ and 395,000 ₫, a Vietnam storefront and Vietnamese locale.
It is excluded from app/package resources, and not enabled on the shared scheme:
internal TestFlight must use App Store Connect sandbox products, not this file.
Descriptions record the final paid and bonus Proton amounts; no UI copy is changed.

Select the file in a local Xcode test scheme. StoreKitTest's `SKTestSession`
provides the following scenario controls (confirmed in the installed Xcode SDK):

1. Success: default configuration, buy either product.
2. Pending: `askToBuyEnabled = true`; approve with
   `approveAskToBuyTransaction(identifier:)`, or decline with
   `declineAskToBuyTransaction(identifier:)`.
3. Cancel: cancel the system purchase dialog; expect no submission.
4. Interrupted: `interruptedPurchasesEnabled = true`; recover with
   `resolveIssueForTransaction(identifier:)`.
5. Refund: `refundTransaction(identifier:)`; server credit/refund proof still
   requires Sandbox notifications and the server worker's ledger implementation.

Local Xcode signed transactions never go to a deployed server. Exercise the
coordinator with its synthetic API/store seams for local end-to-end state tests.
Real StoreKit adapter, dialog and refund tests require a runnable simulator/device;
mock coordinator tests are not evidence of a real sandbox payment.

## Remaining integration gates

The existing native API origin is fixed to production. d1 O8 still leaves the
sandbox origin unnamed. The lifecycle wiring therefore uses `.production` and
makes no claim that TestFlight sandbox purchasing is ready. The coordinator/API
integration owner must establish the approved sandbox origin and MAS audience,
bind a sandbox build to that origin and `.sandbox`, deploy the server routes,
return the owner SKUs with checkout enabled, and prove the first sandbox purchase.
Do not send a TestFlight sandbox payment to the production ledger.

No App Store Connect setup, actual payment, signed sandbox JWS, server delivery,
refund notification, live wallet credit, or TestFlight installation was verified.

## Verification and coordinator hand-off

Public subset integrity, Swift tests, app compilation and public client parity
checks are run locally for this checkpoint; results are recorded below before
commit. The heavy Swift and Xcode builds use the shared lock, two jobs and the
requested time limits. No simulator is booted. No push, PR, hosted CI, deployment,
App Store operation or paid review is authorized for this implementation subtask.

Passed locally on the implementation rebased onto public main
`44e063454f99a2646d5e81b0395c381ca5fd9b5e`:

- Public-subset SHA-256 verification and 5 integrity/configuration tests.
- Design import verification and 8 tests; push projection verification and 2 tests.
- `npm ci --ignore-scripts` and `npm test` in `scripts/public-megolm-fixture`:
  both public vectors passed. The cache was on the shared test volume.
- Swift package dump/resolve, project `plutil` parsing, workflow YAML parsing,
  focused Ruff checks and `git diff --check`.
- 22 public guard regression tests. Their disposable Git repositories required
  the machine documentation hook's `ALLOW_NO_DOCS_LOG=1` exception; no repository
  hook or public guard policy was changed.
- Capped shared-lock Swift run: **1,186 tests, zero failures**, across four fresh
  test bundles (619 design/native, 535 chat, 16 drive, 16 telemetry). This includes
  4 purchase contract tests (all 24 d1 cases), 11 coordinator tests and 2 purchase
  MAS transport tests. The exact command was:

```sh
TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock \
  timeout 900 swift test --package-path ios -j 2 \
  --scratch-path /Volumes/AtumTestFlight/dd-iap2-swift
```

App build: **BUILD SUCCEEDED**, exit 0, with the capped shared-lock command:

```sh
TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock \
  timeout 1500 xcodebuild build -jobs 2 \
  -project ios/AtumMobile.xcodeproj -scheme AtumMobile \
  -destination 'generic/platform=iOS Simulator' ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath /Volumes/AtumTestFlight/dd-iap \
  -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm
```

Outbound checks: both the candidate checker and `origin/main`'s extracted checker
and policy reported `PASS: 1 new commits; raw paths/modes, ancestry, identifiers,
secrets and metadata`, with pinned gitleaks 8.30.1 and no findings. Final publication verification runs
both on the amended head with the command below (the trusted copy uses an
extracted `origin/main` script and its adjacent policy):

```sh
PATH=$HOME/.local/bin:$PATH python3 scripts/public_guard.py \
  --base $(git rev-parse origin/main) --head HEAD
```

 No purchase fixture file was included
in any implementation commit. The work remains local and unpublished.

Local build and test logs are under the shared test volume:
`iap2-public-swift.log`, `iap2-public-app-build.log` and
`iap2-public-guard-tests.log`. No build or test process from this task remains
running.

The remaining public client checks in `docs/ci-parity.md` are covered by the
mobile workflow commands above. The document's desktop/Hermes/workspace lanes
refer to the broader export; they are not lanes of this mobile repository.
Private integration and real StoreKit runtime/payment checks remain unverified.

## Publication file disposition

Relative to the supplied private-fixture implementation, both purchase fixture
directories are omitted entirely (24 upstream fixtures plus 24 projected fixtures
and their manifest). `ApplePurchaseFixtureTests.swift` is replaced by
`ApplePurchaseContractTests.swift` and `ApplePurchaseTestData.swift`.
`generate-native-purchase-fixtures.py` and `test_native_purchase_projection.py`
are replaced by `verify-native-purchase-contract.py` and
`test_native_purchase_contract.py`. The Swift package no longer registers a
purchase fixture resource. The runtime types, adapter and lifecycle wiring are
retained, and `ProtonPacks.storekit` retains the final owner packs and prices.
