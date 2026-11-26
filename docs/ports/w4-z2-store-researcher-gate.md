# W4-Z2 Store hires, skills and the Researcher wait for beta

Stacked on W4-Z1 (`docs/ports/w4-z1-beta-features.md`), which publishes
`LiveAppModel.betaFeatures`. That value is false when unknown. This lane gates
the Store and the Researcher shelf as desktop #132 does. Round r2 also applies
the flag to open confirmations and purchase or hire dispatch.

## Desktop references

These come from atum-platform/atum-desktop `main` at `4de25511`, read without
editing:

- `apps/desktop/src/matrix/store/store-card.tsx` `storeItemComingSoon` and
  `StoreCard`. The CSS is `.atum-store-card--soon` in `styles.css`, which dims
  the art and the button to 55%.
- `apps/desktop/src/matrix/store/store-detail.tsx`: `soon = done ? undefined : comingSoon`.
  It hides the recipient picker, renewal consent and balance, and shows a
  disabled `data-store-coming-soon` action.
- `apps/desktop/src/matrix/store/discover-view.tsx`. A row's `owned` comes from
  `storeOwnership`, so a skill that any assistant owns counts as owned.
- `apps/desktop/src/matrix/listing-hire.tsx` `ListingShelf` (`comingSoon`) and
  `agent-roster.tsx`.
- Tests: `store.test.tsx` "without beta features" and `listing-hire.test.tsx`
  "without beta features shows the listings as Coming soon".

## What the phone does without beta features

**Store rows** (`StoreScreen`, `StoreItemRow`). An agent or skill row that
nothing on the account owns dims its art and shows the pill "Coming soon"
instead of its price. Both are at `StoreBetaGate.dimmedOpacity`, which is 0.55
as on desktop. VoiceOver reads "Coming soon" in place of the price. Tapping the
row still opens the sheet. Pets and apps are unchanged.

A row stays as it is today in these cases:

- the row says Open;
- a delivery for it is pending;
- a skill is owned by any assistant (desktop `storeOwnership`).

`LiveStoreCommerce.ownedAnywhere` checks ownership per item, including both
Hatch IDs. The explicit catalog projection wins. Active entitlements supply
ownership when the projection is absent.

**Store sheet** (`StoreItemSheet`). The sheet gets a new phase,
`.comingSoon`. The sheet checks owned, pending and unresolved first. An
assistant-scoped skill checks ownership for the chosen assistant. That is the
first eligible assistant without the skill, because the picker is hidden. The
header, description, "What it uses" and the try line stay. A disabled primary
button labelled "Coming soon" (`store.detail.soon`) replaces the action. No
recipient picker, price rows, balance, notice, Get, top-up or Open shows. Hires
already had no native acquisition on the phone, so they only gain the disabled
action. A pending delivery or unresolved attempt for another assistant is
visible from the same detail sheet, with a link to Purchased.

**Researcher** (`AssistantNewSheet`). Ready to hire still lists the Researcher
with its face, title and summary. Its button reads "Coming soon", is disabled,
and has the identifier `home.newAssistant.listing.soon`. VoiceOver reads
"Coming soon Researcher", the same as the desktop label. The sheet's press
guard and `ListingHireFlow.press(…, betaFeatures:)` both refuse before a hire
flow exists. Without beta features nothing changes phase, the name line does
not show, and no request is sent. Make your own still works.

An open skill review or Researcher confirmation updates when the flag changes.
When access is revoked, Coming soon and Back replace Confirm, Retry and the
item-specific top-up where applicable. An in-flight request, a purchase outcome,
or a hire setting up its chat still shows its current status.
If beta access changes while the Apple account token is loading, a top-up
opened from a skill or hire returns to the Coming soon flow without starting
a StoreKit purchase. StoreKit transactions already underway still settle, and
general Proton top-ups and pet top-ups stay available under the usual checkout rules.

Store Check status from Detail, Review and Purchased shares one recovery path.
For a skill while beta is off it reads purchase history and entitlements. A
journal entry may have been written before any request reached the server. A
missing server purchase keeps its original key available for recovery when
beta access returns. A matching reversed purchase retires the saved key as a
full refresh would, allowing a fresh purchase when beta access returns.

## Wiring

- The Store, its sheet and review, and the hire shelf and confirmation read
  the SwiftUI environment value `\.atumBetaFeatures`. `AppRoot` sets it from
  `model.betaFeatures` for the Store tab, Settings › Store and Home. It
  defaults to false.
- `LiveStoreCommerce` checks the signed-in account's flag before confirming a
  skill and at transport dispatch. `LiveAppModel.hireListing` checks it before
  saving a hire intent and in its existing account and checkout dispatch gate.
  The transport evaluates both gates just before the first send and any
  replay after a 401.
- The Store item and Researcher entry scope their top-up sheet to beta access.
  The pack Buy action passes the live account flag from `ProtonTopUpContext`
  to `ApplePurchaseCoordinator`, which checks it again after resolving the
  Apple account token and before calling StoreKit.
- The scripted Debug hosts use `AtumDebugLaunch.scriptedBetaFeatures`. It is on
  by default, so existing walks are unchanged. `-AtumScriptedBetaFeatures NO`
  turns it off. The revocation walks signal the running host after an enabled
  confirmation is visible.

## Copy

The only new visible text is the existing pinned key
`desktop.atum.discover.comingSoon`, through `StoreCopyKey.comingSoon`. It has
all five locales: en "Coming soon", vi "Sắp có", ja, zh and zh-Hant. No strings
are hand-written and no keys are added. All styling uses existing Kit tokens and
components: `StoreRowPill`, `.atumPrimary` and the `bordered` capsule the
shelf already uses.

## Verification

- `StoreCommercePresentationTests` covers the gate across agent, skill and pet,
  owned and unowned, beta on and off. It also covers the row status: only a
  price becomes Coming soon, while Open and pending stay. It checks that the
  pinned key resolves in all five locales.
- `ListingHireStateTests.testWithoutBetaFeaturesAShelfPressStartsNoHireAndSendsNothing`
  checks that, without beta features, a press with or without a usable name
  creates no hire and records no run. The same press with beta features hires
  the listing, and a press with no usable name shows the name line.
- `StoreCommerceUITests`:
  - `testWithoutBetaFeaturesHiresAndSkillsAreComingSoonAndPetsStayForSale`
    covers rows and sheets in light and dark, at the default size and at AX5.
    The pet stays gettable.
  - `testWithoutBetaFeaturesOwnedItemsStayUsable` checks that an owned hire and
    skill keep their rows. Lan's sheet for the skill shows Coming soon.
- `ListingHireUITests.testWithoutBetaFeaturesTheResearcherIsComingSoonAndMakeYourOwnWorks`
  runs in en light and dark at the default size and at AX5, plus vi light and
  dark. It checks the button is disabled, that no `hire` probe line is written,
  and that Make your own stays enabled.
- The existing beta-on walks `testDetailReviewConfirmSucceedsOnce` and
  `testOwnedRecipientAndRenewalCancellation` run in the same locked batch.
- One locked batch on the iPhone 16e simulator runs `swift test`, Debug
  build-for-testing, the focused AppTests and the UI tests above. The lane
  folder is `/Volumes/AtumTestFlight/dd-w4-z2/`. The public guard and design
  lint run separately.

### Results (26 Nov 2026, iPhone 16e simulator, iOS 27)

- Run 1 (`run-1.log`, head `15fd08c`):
  - `swift test` passed: 821 tests, 0 failures.
  - Debug build-for-testing exited 0.
  - AppTests passed: 42 tests in `ListingHireStateTests` and
    `StoreCommercePresentationTests`, 0 failures (`app-tests.xcresult`).
  - All four Store UI tests passed (`ui-tests.xcresult`).
  - The Researcher walk failed at en light AX5. At AX5 the sheet opens at its
    medium height, and the lazy form had not loaded the name field. The test
    now drags the sheet up before checking Make your own.
- Run 2 (`run-2.log`): build-for-testing exited 0, and the Researcher walk
  passed in all six variants (`ui-tests-2.xcresult`).
- Captures:
  - Store rows and the Nova sheet (`U-Store-Z2-*`) show the dimmed
    "Sắp có" pill and the disabled action in light and dark, at the default
    size and at AX5.
  - The default-size Researcher captures (`hire-soon-*-default`) show
    "Coming soon" on the shelf.
  - The r1 AX5 Researcher captures show the medium sheet with the disabled
    button clipped by the bottom bar. Round r2 scrolls by frame and asserts
    that the whole button is visible before capturing.
- The public guard and design lint each exit 0.

### Round r2 verification

- AppTests cover revocation between quote and Confirm, preservation of a
  purchase already dispatched, read-only recovery when the server has no
  matching purchase, catalog ownership precedence over active entitlements,
  and Researcher Confirm and Retry after revocation.
- The native transport test covers revocation before the first Store POST
  and before a replay after 401.
- The two new UI revocation walks start at an enabled confirmation. They
  verify Coming soon and Back after the flag changes, with no Store or hire
  dispatch. The pending-skill walk opens Purchased from the detail of a
  skill whose pending delivery is for a different assistant.
- `swift test` passed all 821 tests. Design lint, its unit tests, copy-pin
  checks, the public purchase contract check, and Xcode project lint passed.
- The first Debug build caught four existing test calls missing the explicit
  beta argument. The callers now provide it and the locked batch was rerun.
- The corrected Debug build-for-testing passed in `dd-w4-z2`. On iPhone 16e
  (iOS 27), `ListingHireStateTests` passed 23 tests and
  `StoreCommercePresentationTests` passed 24 tests.
- The Researcher AX5 light and dark captures include the full button. The
  existing horizontal shelf wraps the text tightly at AX5.
- Seven of eight UI tests passed in the full run. The dark Store catalog
  variant timed out waiting for a skill detail sheet after tapping its
  visible row. The UI test helper now allows more time for the sheet and
  retries the tap once if the row is still hittable.
- The locked rerun passed that Store test in all four variants. Across the
  full run and the focused rerun, all eight UI tests passed. Results and
  captures are under `dd-w4-z2/r2/run-2` and `dd-w4-z2/r2/run-3`. Both
  batches used the same iPhone 16e simulator and shut it down at the end.

### Round r3 verification

- `ApplePurchaseCoordinatorTests` holds the account-token request open across
  beta revocation and sheet dismissal. It checks for zero StoreKit calls,
  cleared progress and a subsequent generic top-up. A second test revokes
  beta after StoreKit starts and checks that the verified transaction settles.
- `StoreCommercePresentationTests` gives beta-off Check status a reversal
  matching the saved attempt. It checks that no acquisition request is sent,
  the saved key is retired and the item can be quoted when beta returns.
- The focused Swift package suites passed 77 tests. The locked Debug
  build-for-testing passed, and the iPhone 16e simulator on iOS 27 passed all
  53 AppTests across `ListingHireStateTests`, `ProtonAmountFormatTests`, and
  `StoreCommercePresentationTests`. Design lint, its unit tests, and the
  public guard passed.

## Decisions

- The sheet also hides the price rows while the item is Coming soon. Desktop
  shows no price in that state: the card loses it, and the action that carried
  the price becomes Coming soon.
- A delivery in progress keeps its pending clock on the row and its pending
  notice in the sheet. Something already bought is not dimmed.
- The Store is embedded in the tab and in Settings via `AccountScreen`.
  Both presentations and the hire flow use the same environment flag so
  open screens follow the signed-in account's latest answer.
- In the UI test, the scripted Lan assistant's ID constant is `lanAgent`. A
  constant named after Lan alone, after a dot, matches the public guard's
  private-host pattern for LAN hostnames.
