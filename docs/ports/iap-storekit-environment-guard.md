# StoreKit environment purchase guard

## Why

An allowlisted account can receive a Sandbox catalogue and account token from
the production API. The previous production-build exception accepted that
catalogue on an App Store installation. StoreKit could charge a Production
purchase before the transaction environment check rejected delivery.

This supersedes the build-environment exception described in ST-1 in
`iap-environment-cloud-home.md`. API origin and server account allowlisting do
not establish the device's StoreKit environment.

## Behavior

`ApplePurchaseStore.purchaseEnvironment()` supplies asynchronous runtime evidence.
The live adapter awaits `AppTransaction.shared`, accepts only a verified result,
and maps its environment to Production or Sandbox. Xcode, unknown environments,
unverified results and thrown lookup errors keep the catalogue unavailable.
The installed SDK's StoreKit Swift interfaces confirm that the shared getter
is asynchronous and throwing, and that `AppStore.Environment` exposes
`production`, `sandbox` and `xcode`.

The coordinator requires an exact match before loading purchasable products or
opening checkout. It checks the cached match in `canPurchase` and again after
the account-token await, immediately before calling `store.purchase`. A mismatch
uses the existing unavailable state and copy. There are no UI or copy changes.
Tokens returned during a mismatching refresh are not cached for later checkout.
Existing transaction-environment, product, account-generation and durable server
acknowledgment checks remain in place. The server still owns crediting.

Successful Production or Sandbox reads are cached for the coordinator lifetime,
including across account changes and overlapping catalogue loads. Unknown and
failed reads are retried on the next catalogue load. Account changes still clear
catalogue authority and tokens.
Cancelled or obsolete reads cannot publish into a new account generation.

The existing initializer's `environment` label remains source compatible but
does not authorize purchases. `LiveAppModel` currently passes Production;
`LiveStoreCommerce` supplies wallet and store data, not StoreKit environment
evidence. TestFlight still uses the production API and can purchase a Sandbox
catalogue when its verified runtime environment is Sandbox. A Sandbox device
cannot purchase a Production catalogue; an App Store device cannot purchase a
Sandbox catalogue.

Custom store adapters without an environment implementation default to unknown
and cannot open checkout. This includes the existing synthetic Debug store;
its owner must supply an explicit synthetic environment to restore scripted
checkout. No live adapter may use build configuration as runtime evidence.

## Verification

Focused package checks cover the required environment matrix, lookup failure
and retry, unknown environments, asynchronous loading, cache reuse across loads
and account switches, stale lookup rejection, a catalogue change while a token
is loading, and the retained post-purchase check. Adapter checks cover exact
Production/Sandbox mapping and rejection of Xcode and future environments.
Existing purchase contract and coordinator settlement tests also run.
The TestFlight regression explicitly calls Buy and verifies Sandbox settlement
while the legacy build-environment argument is Production.

Verified on 2026-11-11: **43 tests passed, 0 failures** (34 coordinator,
6 purchase contract, 3 StoreKit adapter). Diff whitespace, new-file public text
checks and `scripts/pre-push-public` pass. The focused package command was:

```bash
TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock \
  swift test --package-path ios --scratch-path /Volumes/AtumTestFlight/swiftbuild-iap-guard \
  --cache-path /Volumes/AtumTestFlight/swiftbuild-iap-guard/cache -j 2 \
  --filter 'ApplePurchaseCoordinatorTests|ApplePurchaseContractTests|StoreKitPurchaseStoreTests' \
  > /Volumes/AtumTestFlight/iap-guard-package-tests.log 2>&1
```

Build output, SwiftPM scratch and temporary files stay on the external test
volume. Package checks run with two jobs under the required heavy-build lock.
No signing, live purchase, push, pull request, CI or deployment was performed.

## Device proof still required

- On an App Store installation with an allowlisted Sandbox catalogue, verify
  that the existing unavailable presentation replaces Buy before a payment
  sheet can open. Do not confirm a real-money purchase for this check.
- On TestFlight with a Sandbox catalogue, verify that StoreKit reports Sandbox,
  Buy is offered, and an authorized Sandbox test purchase settles and finishes.
- Verify that a Production catalogue is available only to a Production runtime,
  and that a Sandbox runtime with a Production catalogue stays unavailable.
- Verify unavailable behavior when app-transaction verification or lookup fails,
  including offline first launch, and recovery after an explicit reload.

The iOS app build was not run. Unit tests cannot prove Apple's environment reporting, payment-sheet behavior,
server allowlist configuration or real-device delivery. No physical-device or
live StoreKit purchase verification was performed by this implementation worker.

## Debug scripted store

`ScriptedApplePurchaseStore` reports Sandbox, matching its scripted catalogue, so
the scripted Store and top-up UI tests keep an open checkout under the new guard.
