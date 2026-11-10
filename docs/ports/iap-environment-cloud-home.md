# IAP environment and cloud home parity

Wave 1 ST-1 / AS-1, based on mobile main `308c5d8`.

ST-1 matches lane 4 slice 1 and defects F-1, F-9, F-10. AS-1 matches
lane 3 slice S2 / D-2 and desktop `050ede8edf5`,
`apps/desktop/shared/agent-home-cloud-only.ts:1-17`.

## Purchase behavior

The production API origin stays fixed. The authenticated account's products
response selects the coordinator's accepted transaction environment. A production
client accepts a server-selected Sandbox catalogue for an allowlisted TestFlight
or App Review account; a Sandbox client still refuses a Production catalogue.
Binding another account clears the accepted environment and cached account tokens.
Tokens are cached by account and the selected environment. StoreKit verification,
product admission, server acknowledgment and account-generation checks remain in
place; crediting remains exclusively on the server.

An admitted transaction, whether purchased now, replayed from unfinished StoreKit
transactions or received through updates, is posted only in the selected
environment. It finishes only after the matching transaction ID receives a durable
`finish: true` response. Production catalogue and credit behavior remain unchanged.
Sandbox promo-only response fields decode without turning them into local credit
or exposing economic splits in the UI.

The v1.2 `matrix_403` / `sandbox_cap_exceeded` error decodes as a refusal and
publishes `sandboxCapExceeded`. It pauses checkout and stops automatic retries,
without finishing the transaction, refreshing the wallet or guessing an outcome.
An explicit restore/replay can settle the same unfinished transaction after an
operator raises the cap. Successful restore does not independently reopen a closed
checkout; a fresh server catalogue controls that. The existing closed-checkout
retry behavior is otherwise unchanged.

Durable `needs_support`, `credited_to_other_account` and `revoked` acknowledgments
now allow another purchase in the same session, just like credited/replayed
success. Pending purchases and retrying submissions continue to block checkout.

## Cloud-only destinations

The placement sheet offers Cloud only, even when the server lists eligible Macs
or the assistant currently lives on a reachable, asleep or offline Mac. The
existing Mac home remains visible as current placement, and the existing cloud
selection, model choice, preflight/disclosure and move flow lets it leave for the
cloud. Existing copy keys are reused. No layout changes beyond removing Mac rows.
This mirrors desktop's constant policy rather than adding a new flag read.

## Fixture provenance

Five synthetic wire examples come from `atum.mobile-purchases/1.2`, frozen pack
SHA-256 `b74e996a8c35bce7cdbf6593cf20551bdc2777302910600e30d2a0acc33076bd`:
allowlisted products, Sandbox credited/replayed, Sandbox cap error, and closed
Production products. They are transcribed as Swift integer literals in
`ios/Tests/ApplePurchaseV12TestData.swift`, following the existing d1 test-data
pattern. Serializing these values emits the required integer wire tokens; the
provider values and keys are unchanged. This is a focused test subset; the
unpublished amendment has not been formally vendored as a public provider contract.
The earlier frozen contract packs remain untouched.

## Verification

Verified on 2026-11-10, using the mandatory
`TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`
batch, two jobs, dedicated `dd-w1-iap-env-cloud-home` DerivedData and the shared
SPM cache:

- Complete package `swift test -j 2`: **1,233 tests, 0 failures** (637 design/API,
  564 chat, 16 Drive, 16 telemetry). This includes **6 purchase contract tests**
  and **20 coordinator tests**, covering server-selected Sandbox, promo-only
  credit, cap refusal/recovery, environment token caching, Production admission
  and crediting, account switching, and all durable terminal states.
- `AtumMobileStateTests`, filtered to
  `AtumMobileTests/AssistantHomeDestinationTests`: **1 test, 0 failures**. It
  covers two eligible Macs with cloud and existing Mac placements across
  reachable/asleep/offline states, including the platform-not-ready waiting path.
- `AtumMobile` Debug arm64 iOS Simulator compile: **BUILD SUCCEEDED**.
- `git diff --check` and the public outbound guard: **PASS**.

The simulator was shut down at batch exit. Dedicated DerivedData and package
scratch output were removed after verification. No push, PR, CI or deployment
was performed.

Live TestFlight/App Review crediting depends on platform deployment, the server
allowlist and Apple setup. Those operations, physical iPhone checks and visual
captures belong to the coordinator; this worker does not touch servers or phones.

## PENDING-COPY

None. This slice adds no user-visible text or purchase UI. The new cap refusal is
an observable coordinator state for the later pack-sheet slice to present using
its own exported copy.
