# W4-Z2 Store hires, skills and the Researcher wait for beta

Stacked on W4-Z1 (`docs/ports/w4-z1-beta-features.md`), which publishes
`LiveAppModel.betaFeatures`. That value is false when unknown. This lane gates
two surfaces on it, as desktop #132 does. Team Space is a later lane and is
unchanged here.

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

`LiveStoreCommerce.ownedAnywhere` checks ownership. It reads active
entitlements and the catalog's `ownership`, and covers both Hatch IDs.

**Store sheet** (`StoreItemSheet`). The sheet gets a new phase,
`.comingSoon`. The sheet checks owned, pending and unresolved first. An
assistant-scoped skill checks ownership for the chosen assistant. That is the
first eligible assistant without the skill, because the picker is hidden. The
header, description, "What it uses" and the try line stay. A disabled primary
button labelled "Coming soon" (`store.detail.soon`) replaces the action. No
recipient picker, price rows, balance, notice, Get, top-up or Open shows. Hires
already had no native acquisition on the phone, so they only gain the disabled
action.

**Researcher** (`AssistantNewSheet`). Ready to hire still lists the Researcher
with its face, title and summary. Its button reads "Coming soon", is disabled,
and has the identifier `home.newAssistant.listing.soon`. VoiceOver reads
"Coming soon Researcher", the same as the desktop label. The sheet's press
guard and `ListingHireFlow.press(…, betaFeatures:)` both refuse before a hire
flow exists. Without beta features nothing changes phase, the name line does
not show, and no request is sent. Make your own still works.

With `betaFeatures` true, all three surfaces behave as before. The flag only
changes what the phone shows. The platform authorizes each acquisition and hire.

## Wiring

- The Store reads the SwiftUI environment value `\.atumBetaFeatures`. It
  defaults to false, so a Store with no account shows hires and skills as
  "Coming soon". `AppRoot` sets it from `model.betaFeatures`, which covers the
  Store tab and Settings › Store. `StoreScreen` passes it to the sheet.
- The hire shelf reads `HomeAssistantActions.betaFeatures`, which also defaults
  to false. `AppRoot` sets it from `model.betaFeatures`.
- The scripted Debug hosts use `AtumDebugLaunch.scriptedBetaFeatures`. It is on
  by default, so existing walks are unchanged. `-AtumScriptedBetaFeatures NO`
  turns it off.

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
  - The AX5 Researcher captures only show the medium sheet. The disabled
    button sat under the bottom bar but still counted as hittable, so the test
    took no drag before the capture. The AX5 shelf assertions still passed:
    the button exists, is disabled, has the right label and sends nothing.
    A follow-up should scroll by frame before that capture.
- The public guard and design lint each exit 0.

## Decisions

- The sheet also hides the price rows while the item is Coming soon. Desktop
  shows no price in that state: the card loses it, and the action that carried
  the price becomes Coming soon.
- A delivery in progress keeps its pending clock on the row and its pending
  notice in the sheet. Something already bought is not dimmed.
- The Store gets the flag through the environment because the Store is
  embedded twice: in the tab, and in Settings via `AccountScreen`. The hire
  shelf gets it through its existing capability bundle.
- No guard was added to the model's `hireListing`. The UI refuses before the
  flow starts, and the platform authorizes the hire.
- In the UI test, the scripted Lan assistant's ID constant is `lanAgent`. A
  constant named after Lan alone, after a dot, matches the public guard's
  private-host pattern for LAN hostnames.
