# iPhone Store parity: non-UI hand-off

Reference audit: desktop `467b66d7a844805b12df6be0f7988cc4a3c074e9`
(`origin/atum-main`, `apps/desktop/src/matrix/store/`), platform
`7df04652c7c1ce39f757891e01e0d14951db31bb` (`origin/main`).
Repositories fetched before inspection. The phone branch has no remote tracking ref
(`git pull --ff-only origin t3/00ef3274` reported missing remote ref); the clean
existing worktree was retained. Origin is `atum-platform/atum-mobile-client`.
No production writes, pushes, CI, payments or deployment.

The coordinator reassigned all UI/UX to Opus during implementation. All view,
layout and UI-test edits were reverted. This commit supplies the non-UI layers;
the existing Store screen remains read-only until that UI pass binds them.

## Gap list (desktop action → provider dependency → phone)

All route paths below share `/api/matrix/v1`.

| Desktop action | Platform route / frozen contract | Phone status after this commit |
| --- | --- | --- |
| Item detail, description, example | GET `/store/catalog`; `atum.store/1.1` | Typed description, example, needs, offer, ownership, deliverable and install metadata in read model; detail UI handed off |
| Acquire skill for an assistant, account-owned pet | POST `/store/purchases`; `atum.store/1.1`, `mobile-native-api/1.1`, `mobile-purchases/1.1` | API, fresh review quote, explicit confirm entry point, durable UUID replay and typed outcomes implemented; UI handed off |
| Owned and purchase state | GET `/store/entitlements`, GET `/store/purchases`; same contracts | Typed inventory/history, pending/reversed state, fresh wallet after outcomes, account-scoped recovery implemented |
| Cancel monthly entitlement | POST `/store/entitlements/{id}/cancel`, `{}`; same contracts | Typed cancellation of existing purchased active subscriptions; it does not uninstall or refund |
| Hire an assistant | Purchase route, `matrix-store.ts` desktop delivery fence | Omitted: desktop >= 0.18.3 runtime/schedule delivery required. Never forge `X-Atum-Desktop-Version` or declare `agents.schedules.1` |
| Install/uninstall free Hub skill | `install.source=hermes_hub`; desktop `hub-skill.ts` opens Skills Hub | Omitted: no frozen native MAS contract for Hub scan, confirmation, installation/removal and installed inventory. Legacy `app/atum/discover-*` components are explicitly retired; current `matrix/store` Store delegates installation to the Hub |
| Attach purchased skill | Purchase intent `assistantId`, active skill entitlement | Acquisition targets assistant. No separate attach/detach route. Paid execution still depends on platform readiness/binding |
| Attach/display pet, hatch from text/photo | Desktop companion / pet runtime | Omitted: GET/PUT `/agents/{id}/pet` exists in `matrix-pets.ts`, but no frozen native selection/preferences/package-delivery contract under `spec/` was found. `pet-chat` and `pet-intent` do not define selection. Account ownership must not be labelled installed |
| Try owned item | Desktop `store-try.tsx` opens existing assistant chat and seeds example | Target includes an existing room ID for a UI Open action. Example copy is projected. Composer draft seeding and companion/hatch destination support remain with the UI/runtime pass |
| Individual purchase status | GET `/store/purchases/{id}` exists for desktop | Omitted: not one of the five mobile-native-api/1.1 operations. Use admitted history plus the exact idempotent POST replay |
| Buy Protons | Separate Apple consumable contracts | Entirely out of scope: no top-up, checkout, payment client or payment UI |

`matrix-authority.ts` admits the configured iPhone MAS domain client through
`nativeDomainClients` and dispatches Store resources through `matrixStore`.
Requests use the existing bearer/refresh flow without cookies or browser Origin.
`Atum-Store-Capabilities: store.ownership.1` is the only declared capability:
no native claim of desktop prefix delivery, Hub installation, schedules or pet art.
The native URL allowlist admits only the five operations above, with UUID paths
for cancellation. There is no new per-purchase status, top-up or task route.

The native admission amendment is a contract, not proof of production enablement.
`mobile-purchases/1.1` records d1 validation and legal P5 rollout dependencies.
This commit neither implements nor enables Apple validation, hires, production
switches or deployment. The owner's requested existing-balance acquisition is
implemented as non-UI state; enabling its UI remains subject to the coordinator's
rollout decision. Server refusals remain authoritative.

## Contracts and fixture provenance

Verbatim upstream packs from platform commit above, including provider README,
contract, fixture bytes and original length-prefixed SHA256 pins:

| Pack | SHA256 |
| --- | --- |
| `atum.store/1.1` | `77b3dc62b8b7ab3a9332c0a8c0eb493df1035dabb76eff2b21764629dc8707f0` |
| `atum.mobile-native-api/1.1` | `aa7c9df2c736bbb0e34ccfcba4de5b5e26a4048bd3b7857c866479dbc11432ef` |
| `atum.mobile-purchases/1.1` | `6342cbb5d7b1046e93e253ffaa5a5b0895521b630fa1d4a9964676e53814a9bb` |

`mobile-purchases/1.1` is a two-file text amendment; no payment implementation or
base payment fixtures were copied. Existing base contracts remain independently
pinned. The generator verifies all three hard-coded upstream pins and projects
only Store catalog, entitlement, purchase history, intent/result and cancellation
fixtures into `ios/Tests/Fixtures/store-v1.1`, with provider commit and file hashes.
All upstream fixture identities are synthetic. Store decoding rejects protected
bodies, service secrets, receipts and internal `requires` fields recursively.

## Non-UI behavior

- `StorePurchaseAttempt` encodes only confirmed offer ID/version, optional assistant
  ID and UUID idempotency key. The Shell requires the same key in the body and
  `Idempotency-Key` header. No client payer, principal or price is sent.
- `StoreFileJournal` writes atomically before transmission in Application Support,
  uses an account-hashed filename and iOS data protection, and retains intents
  through sign-out and process restart. Corruption or write failure blocks a
  new purchase. It stores no credential. Recovery decodes/validates the intent.
- `StoreAcquisition` serializes writes, reuses the complete original intent on
  ambiguous responses/401 replay/restart, and validates response item, assistant,
  offer/version and idempotency key. Completed attempts remain durable until
  subsequent ownership/history can explain them; exact replay is still safe.
  A definite refusal or changed offer retires the intent; a new price needs a
  new user confirmation. A reversed replay retires the old intent too.
- Review requires fresh catalog, inventory and wallet. Insufficient balance
  produces no request. Server insufficient-balance refusal remains authoritative.
  Transport/decode/unknown failures after send are uncertain; no guessed refund,
  success or unchanged balance. Wallet is invalidated after an outcome and read
  again with catalog, inventory and history.
- Recipient eligibility fails closed if model choices cannot be read. All
  configured destination choices must use Atum AI. This is conservatively narrower
  than desktop's current-destination filter: a dormant own-model destination also
  excludes the assistant until an authoritative current-destination policy is
  wired. No capability header is invented to bypass protected-content readiness.
- App-model configuration scopes the observable state to the current account and
  client generation. Late responses after reset cannot repopulate another session.
  Cancellation has separate working/cancelled/uncertain/forbidden state, retains
  the entitlement/access date, and can safely be retried through the same route.

## UI hand-off

No SwiftUI views or layouts are changed. Bind to `LiveAppModel.storeCommerce`
(`LiveStoreCommerce`, `@MainActor @Observable`, no SwiftUI import).

| Screen / action | Entry points | States / obligations for the UI pass |
| --- | --- | --- |
| Catalog / balance | `refresh()`, `catalog`, `wallet`, `readState`, `ready`, `refreshing`, `journalReady`; existing `LiveProductStoreRead`/item metadata | Loading, ready, offline, forbidden, unavailable; saved listings may remain visible but cannot authorize a quote. Display `wallet` only when fresh; no top-up action |
| Item detail | Read item `detailDescription`, `tryPrompt`, `needs`, `offer`, `ownership`, `deliverable`, `install`; `owned(item, assistant:)` | Owned per selected assistant for skills; account-owned for pets; unavailable offer/delivery; pending delivery is not installed. Omit hires and unsupported Hub/pet-install actions |
| Recipient | `targets` (ID/principal/name/existing room ID), `paidTargets` | Eligible assistant selection, already owned for that assistant, no eligible assistant; never silently choose a different recipient during a purchase |
| Purchase review | `review(itemID:assistant:) -> StoreAcquireQuote`; `ReviewFailure` | Fresh immutable price/current balance/resulting balance and chosen recipient; unreadable intent storage blocks a new acquisition. Failures: unavailable, alreadyOwned, unresolvedPurchase, noEligibleAssistant, insufficientBalance. Review alone writes nothing |
| Explicit confirm | `confirm(quote)` | Show explicit confirmation of price and resulting balance before invocation. Bind `busy`, `state`, `operationItemID`, `operationAssistantID`; disable duplicate confirms. Quote must remain unchanged |
| Acquire outcome | `StoreAcquireState`, typed `StorePurchaseResult` | Idle, working, insufficient balance, offline, forbidden, unavailable, uncertain; purchased pending/granted/completed/reversed; already owned; offer changed; closed server refusals. Insufficient balance has no top-up CTA. HTTP forbidden/unavailable does not prove an earlier ambiguous attempt was uncharged; preserve recovery state |
| Recovery / Purchased | `unresolvedAttempts`, `savedAttempts`, `purchases`, `entitlements`, `retry(attempt)`, `refresh()` | Uncertain write must check/replay its original intent, including after catalog removal or loss of recipient eligibility. Never mint another key. Pending, reversed, revoked, lapsed/cancelled subscription states; failed inventory is not empty ownership |
| Subscription | `StoreEntitlement.canCancel`, `cancel(entitlement)`, `cancellationState` | Explicit renewal-cancellation confirmation; working, cancelled with access-until date, uncertain (retry/read), forbidden. Do not call this uninstall or refund |
| Try/Open | `Target.roomID`, projected example | Only an existing canonical room. Do not claim to install or send a message. Composer seed and companion flows need their own wiring |
| Synthetic host | `StoreCommerceAPI` protocol; `LiveStoreCommerce(journal:)`; `configure(account:client:targets:)` | Inject fake API/journal; no live client or production writes. Add sheet/confirmation/recipient/recovery UI tests in the Opus pass |

Copy must use `LiveDesign` / `AtumCopy` and existing five-locale exports.
Useful keys: `desktop.atum.discover.{buyFor,availableBalance,protons,owned,
insufficientProtons,offerChanged,purchaseUncertain,purchaseFailed,checkPurchase}`,
`desktop.common.{confirm,cancel,close}`, and
`src.matrix.mobile-device-copy.mobileDeviceCopy.store{Detail,Recipient,Review,
Delivery,Purchased}*`. Never use the export's demo date or demo timestamp keys.

Missing exports: a dedicated resulting-balance label, Store requirement names,
gift/visiting labels, and a dedicated monthly-cancellation action label from
`matrix/store/store-copy.ts` (its inline copy is not exported). The UI pass must
list/resolve missing keys or reuse semantically accurate existing labels; it must
not add English literals or modify `ios/Vendor/AtumDesign`. The Opus UI pass owns presentation and resolution of the missing resulting-balance
label. Pending/delivered/reversed/cancelled-access status text already exists in
the mobile-device exports.

## Verification

All final heavy builds use the coordinator's shared lock:
`TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock <command>`, with `-j 2`.
Earlier unrestricted runs were interrupted after shared disk/swap exhaustion; their
partial compile output is not test-pass evidence. The initial simulator build was
cancelled when UI scope moved to the coordinator; no simulator was booted here.
Checkpoint checks completed locally:

| Exact command | Result |
| --- | --- |
| `python3 scripts/generate-native-store-fixtures.py --check` | PASS: three provider pins, exact generated bytes; 54 fixture projections (34 accept / 20 reject) |
| `python3 scripts/import-design-exports --verify` | PASS: existing public producer pin unchanged |
| `python3 -m unittest discover -s tests -p test_import_design_exports.py` | PASS: 8 tests |
| `python3 scripts/generate-native-push-fixtures.py --check` | PASS |
| `python3 -m unittest discover -s tests -p test_native_push_projection.py` | PASS: 2 tests |
| `npm ci --ignore-scripts --prefix scripts/public-megolm-fixture` | PASS |
| `npm test --prefix scripts/public-megolm-fixture` | PASS: both public Megolm vectors |
| `swift package --package-path ios --scratch-path /Volumes/AtumTestFlight/dd-store-swift dump-package` | PASS |
| `swift package --package-path ios --scratch-path /Volumes/AtumTestFlight/dd-store-swift resolve` | PASS |
| `plutil -lint ios/AtumMobile.xcodeproj/project.pbxproj` | PASS |
| `git diff --check` | PASS |

Final required verification (exit 0):

```sh
TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock swift test --package-path ios -j 2 --scratch-path /Volumes/AtumTestFlight/dd-store-swift
```

PASS: 1,142 XCTest tests across four bundles (606 + 504 + 16 + 16), zero failures.
The new coverage includes 54 frozen Store fixture cases, 11 acquisition tests,
two contract/copy tests and three native transport tests. Acquisition coverage
includes success, insufficient local/server balance, ambiguous commit/reply loss
and process restart (one charged key), single-flight double confirmation,
offline, forbidden, journal failure/corruption, offer change, invalid recipients,
assistant-hire exclusion and mismatched replies. Transport tests verify the exact
header/body key through 401 refresh, closed admitted paths and protected metadata
rejection. Five-locale copy lookup tests use existing exported keys only.
The run log is local at `/Volumes/AtumTestFlight/store-swift-locked.log`.

The non-UI observable state also passed a separate source type-check (exit 0)
before the shared-build rule, using the package module and a temporary protocol
shim (`import AtumNativeAPI` followed by the unmodified `StoreCommerceAPI.swift`):

```sh
xcrun swiftc -typecheck -module-name StoreVMCheck -target arm64-apple-macos26.0 -I /Volumes/AtumTestFlight/dd-store-swift/out/Products/Debug /Volumes/AtumTestFlight/StoreCommerceAPI-check.swift ios/App/Store/LiveStoreCommerce.swift
```

The initial app-target command was cancelled at the UI scope change, with no
successful app build claimed:

```sh
xcodebuild -project ios/AtumMobile.xcodeproj -scheme AtumMobile -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath /Volumes/AtumTestFlight/dd-store -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm CODE_SIGNING_ALLOWED=NO build
```

The coordinator owns final app-target, UI and simulator verification under the
shared lock. No simulator was booted, no production write was called, and no
push, PR, CI, deployment or payment was performed.
UI tests and scripted-host changes are intentionally deferred by the coordinator.

## UI pass

Bound to `LiveAppModel.storeCommerce` from the Store tab (`AppRoot`) and the
Settings Store page (`AccountScreen`). Without an engine the sheet shows the item
only and offers no action.

| Surface | File | States |
| --- | --- | --- |
| Catalog rows | `ios/App/Store/StoreScreen.swift` | Every item row is a button opening its sheet; one trailing value (price, Free, Owned, pending clock). App rows use the same row: Open / Start a chat as the row action and trailing text, no capsules (design review S1); a coming-soon app says Coming soon and keeps its sidebar shortcut in a context menu and VoiceOver action. A Purchased entry leads the list once the purchase journal is readable and says when a purchase is being checked |
| Item sheet | `ios/App/Store/StoreItemSheet.swift` | Description, “Try asking”, price and fresh balance, recipient choice for skills (Owned per assistant). Loading, offline, forbidden, unavailable, not for sale, owned (Open for a skill with a room), delivery pending, unresolved purchase (Check status), no eligible assistant, insufficient balance (plain notice, no action), ready (Buy · price) |
| Review / confirm | same file, `StoreReviewView` | Immutable quote: item, recipient, price, current → resulting balance. Single-flight Confirm (busy atom, back and dismiss locked). Outcomes: delivered/already owned (Done, Open), pending/refunded (Close), uncertain (only Check status with the original key), forbidden/offline with a saved intent (Check status), offer changed (re-quoted, must confirm again), definite refusals and insufficient (Close) |
| Purchased | `ios/App/Store/StorePurchasedScreen.swift` | Unresolved attempts with Check status; owned entitlements (revoked, lapsed, cancelled renewal with date, delivery pending); purchase history with amount, date and delivery state; renewal cancellation with confirmation (working, cancelled, uncertain → retry, forbidden). A failed read is a notice with Retry, never an empty list |
| Copy / outcomes | `ios/App/Store/StoreCommercePresentation.swift` | `StoreCopyKey` (existing five-locale exports only) and the pure outcome → wording mapping |

No top-up, Proton purchase entry or placeholder anywhere (Guideline 3.1.1).
Agent hires and Hub installs show as information only.

Missing exports (shown without a dedicated label, resolve in the export):
- resulting balance (“balance after purchase”): the review shows current → resulting balance on the Protons balance row;
- dedicated “Cancel renewal” action and its confirmation question: Cancel under the Renewal heading, confirmation titled Renewal;
- Store requirement names for `needs`: not shown;
- “Skill · by Atum” kind line, gift and visiting labels: not shown.

Engine notes from this pass:
- `LiveStoreCommerce.reload` used `async let` over the main-actor client, which the app
  target (Swift 6) rejects; now sequential reads with the same results and error mapping.
- The engine commit lacks five upstream `*token*.facts.json` fixtures in
  `docs/contracts/provider/mobile-native-api/v1.1/fixtures/` because `.gitignore` has
  `*token*.json`; `generate-native-store-fixtures.py --check` fails on a clean checkout
  and passes with them restored from platform `7df04652`.
- Rebased onto `origin/main` 44e0634: one allowlist conflict in `NativeDomainClient`
  (kept main's `privateCosCapabilityURL` and the Store routes).

Scripted synthetic hosts (`App/Debug/StoreScriptedCommerce.swift`): `store.acquire`,
`store.insufficient`, `store.uncertain` (first write commits, reply lost), `store.owned`
(pet, per-assistant skill, cancellable monthly entitlement). In-memory API and journal.

### UI pass verification

All heavy commands ran under the shared lock with `timeout 900`.

| Command | Result |
| --- | --- |
| `swift test --package-path ios -j 2 --scratch-path /Volumes/AtumTestFlight/dd-storeui-swift` | PASS, 1,185 tests (618 + 535 + 16 + 16), 0 failures |
| `xcodebuild … -scheme AtumMobile -destination 'generic/platform=iOS Simulator' … ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build` | BUILD SUCCEEDED (pre-rebase tree). Without `ARCHS=arm64` the MatrixRustSDK x86_64 simulator link fails (arm64-only library) |
| `xcodebuild … -only-testing:AtumMobileTests/StoreCommercePresentationTests -only-testing:AtumMobileUITests/S6SystemUITests/testU9StoreOpenPushesItsScriptedRoom test` | PASS: 5 unit tests; S6 U9 (app row is the Open button) |
| `xcodebuild … -only-testing:AtumMobileUITests/StoreCommerceUITests test` | Not verified. `testInsufficientBalanceIsPlainWithNoTopUp` passed. The other four first failed on a real bug (outer `accessibilityIdentifier` after `safeAreaInset` replaced the action-bar buttons' identifiers), fixed by moving the identifiers onto the scroll views. Both later runs then stalled in the first test's `app.launch()` (~380 s, “does not have a process ID”) and hit the 900 s cap: a simulator/harness launch stall, handed to the coordinator |
| `python3 scripts/import-design-exports --verify`, importer and push-projection unit tests, push fixture check, `plutil -lint`, `git diff --check` | PASS |
| `python3 scripts/generate-native-store-fixtures.py --check` | FAIL on a clean checkout (missing ignored fixtures above); PASS with them temporarily restored |

A headless macOS repro (real `LiveStoreCommerce` + the scripted API) confirmed the engine
quotes: acquire 90 → 120 − 90 = 30 Protons, insufficient → `insufficientBalance`, owned →
`alreadyOwned` for the pet and a quote for the other assistant's skill.
S6 `testU7` (catalog AX5/dark) was not run: it needs the external appearance runner, and its
free-row assertion was updated to the button row label.

- 2026-11-10 (coordinator): the scripted Store assistant constant in `ios/App/Debug/StoreScriptedCommerce.swift` is now `lanAgent`. Its old short name, written after `Self.`, matched the public guard's private-hostname rule (a `.lan` suffix). The guard itself is unchanged.
