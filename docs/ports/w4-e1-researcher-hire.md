# Hire the Researcher from the New assistant sheet (W4-E1)

Wave 4 phone catch-up, UI lane W4-E1 (tracker atum-platform/atum-mobile#47).
The phone port of desktop's D9 slice 1. Built on PR #63 (`feat/w4-copy-repin`),
which pins the wave 4 desktop copy export.

State: **built, not live.** It reuses the platform route desktop calls
(atum-platform #921, merged). As on desktop, the first live hire spends
Protons, so it needs the owner's go.

## Desktop references

- atum-platform/atum-desktop PR #100, merge `eb808c4635e3978f14f98684f2c1fd89fb415034`
  (22 Nov 2026), read from a local `main` checkout that was not edited.
- `apps/desktop/src/matrix/listing-hire.tsx`: `useOpenListings`, `useListingHire`,
  `ListingShelf`, `ListingHireView`, `listingAssistantName`, `listingText`.
- `apps/desktop/src/matrix/agent-roster.tsx`: `NewAssistantDialog` places the shelf
  and swaps in the hire view.
- `apps/desktop/electron/matrix/agent-definition.ts`: `listMatrixOpenAgents`
  (`GET /agents?catalog=open`), and `createMatrixAgent` with `listingId`.
- `apps/desktop/electron/matrix/agent-lifecycle.ts`: `hire()` resumes an unfinished
  hire of the same listing under its own request, and skips the persona write.
- `apps/desktop/electron/matrix/main.ts`: the `hireAgent` IPC, and the refusal map in
  `createLifecycle().refusal`.
- `apps/desktop/src/matrix/roster-create-copy.ts`: the six new copy keys.
- `docs/hire-researcher-ui.md`: the desktop session log, including the state table.
- Platform: `apps/shell/src/lib/matrix-authority.ts`, the `agents?catalog=open` GET
  and `listingId` on `POST /agents`; and `docs/session-logs/2026-11-22-open-researcher-hire.md`.

## What the phone does

No new screen. The existing **New assistant** sheet (`AssistantNewSheet`) shows
open listings under **Ready to hire**. The shelf sits after the intro line and
above the sheet's own form, which gets a "make your own" label. With no listings,
a failed read, or no lifecycle capability, the shelf is hidden and the sheet is
exactly what it was before.

The shelf row has a round face (the catalog emoji drawn as its Phosphor glyph:
`🔎` → `StoreMagnifyingGlass`, on the Kit surface, round like every assistant),
the title and summary in the app language, and **Hire**. Picking a listing gives
the sheet to that one hire (`ListingHireView`):

| Phase   | What shows                                                  | Actions                          |
| ------- | ----------------------------------------------------------- | -------------------------------- |
| confirm | the price once, "60,000 Protons/month", for a third+ assistant only | Hire, Back                |
| hiring  | "Hiring Researcher…"                                        | Hire (disabled, spinner), Back (disabled) |
| setting up | "Researcher is getting ready…", with a spinner, while the hired assistant's chat isn't open yet | Done (closes the sheet) |
| done    | "Researcher is in your chats."                              | Done (closes the start-chat sheet) |
| short   | "Not enough Protons. Top up to continue."                   | Top up (when checkout is open), Back |
| failed  | "Couldn't hire Researcher. Try again." or the platform's final refusal (name, limit or account) | Retry (retryable only), Back |

- **Free seat:** the first two assistants hire in one press, with no price shown.
- **Third+ assistant:** the price is shown first. A `hire_required` refusal (for
  example, from a stale catalog quote) also leads to the confirm step, at the
  platform's price.
- **Name:** the listing's title in the app language ("Nhà nghiên cứu" in
  Vietnamese), numbered when it would duplicate an existing assistant
  ("Researcher 2") or be an app's name. Duplicates compare the platform's name
  key (`assistant_name_key`, desktop `assistantNameKey`), so "Re-searcher" or
  "Researcher 🔎" counts, and accents still count ("Mãi" is not Mai). App names
  are the catalog's (each app's name in every language, its bot's name and its
  slug as words, desktop `appCatalogNames`). Like desktop, when every numbered
  name is taken the hire falls back to the catalog name for the platform to judge.
- **Leaving mid-hire:** the flow (`ListingHireFlow`) belongs to the app root, so a
  hire under way survives leaving the sheet, and reopening it shows the hire again.
  Any other state is let go when the sheet closes.
- **Account change:** a hire belongs to the account it was picked under. When the
  signed-in account changes (or signs out), the root drops the flow at once, even
  mid-hire, and ignores its late answer, so a confirmation given under one account
  never reaches another account's Retry. `hireListing` also refuses a hire whose
  account isn't the one signed in, before it reads or sends anything.
- **VoiceOver:** done, short and failed are announced.

### After the hire

`LiveAppModel.hireListing` sends `POST /api/matrix/v1/agents` with
`{requestId, displayName, listingId, hireConfirmed?, disclosureVersion?}`. That is
the route and body desktop sends. There is no persona write, so the platform's
seeded definition and skills stay. On success the model:

1. reads `/agents` again;
2. retries the new assistant's owner-room invite, including one that arrived
   before the roster knew the inviter;
3. claims a handle in the background, as for a made assistant;
4. says done only when the platform placed it (`cloud_placement: placed`, or no
   placement) and Home's own roster projection (`LiveRosterRows.rows`, checked by
   `ListingHireChat.opens`) has a joined, openable row for that assistant. A hire
   placed as `capacity` or `pending_trust` comes back before its room exists, and
   Home suppresses some rooms (duplicate plain rooms, hidden or quarantined ones):
   the sheet shows "getting ready", keeps the assistant ID, and turns to done only
   when that row appears. A hire whose client or Matrix session was replaced
   mid-POST also waits there.

Any failure in those steps is left to the assistant's card, as on desktop.

**One hire, never two.** The request UUID, name, confirmation and (after
success) the assistant ID are stored per account and listing in
`LiveListingHireStore`. It follows the Store journal (`StoreFileJournal`,
`ios/Sources/AtumNativeAPI/StoreAcquisition.swift`): one atomic file per account
under Application Support `ListingHires/<sha256 of the Matrix ID>.json`, with the
same file protection. A missing file is an empty ledger. An unreadable one is
unknown, not empty: the hire mints and sends nothing (retryable failure). The
request is written before the POST, and a failed write sends nothing. A Retry, a
confirmation or a relaunch resumes the same request.

The platform charges the seat in `matrix_agent_create_finish` (0314, idempotent
on the request), after the reservation and the MAS identity, and keeps
provisioning after that (definition seed, Hermes, owner snapshot). Any of those
later steps can still answer 400 (`matrix_invalid`), 403, 404, 409 or 503. A name
refusal doesn't prove the request was never charged either:
`matrix_agent_create_begin` (0192) checks the name before it looks the request
up. So a request that was sent is never dropped on a refusal. A name refusal
marks it `nameRefused`, and the next pick sends the same UUID under the name it is
picked with then. If the platform never stored the request, that is a new create
under the new name. If it did, a changed name is `matrix_conflict` (limit, Back
only), never a second charge. Limit and account refusals show their final line
with Back only, and picking the listing again resumes the same request. A bare 400
is shown as the retryable failure, where desktop reads it as a name refusal (see
"Phone-only rules").

After success the entry stays, now naming its assistant, until Home opens that
assistant's chat. A later pick of the listing in that window sends nothing and
shows "getting ready" for the same assistant. Once Home has the openable row, the
entry is cleared, and a later pick is a new hire (with the price step again for a
third+ assistant).

The earlier `UserDefaults` ledgers (`v1`, keyed by the 32-bit log fingerprint,
and `v2`) only ever held requests from unreleased builds; they are not read.

### Phone-only rules

- **Spend gate.** A priced seat is a Proton spend, so it follows the Store's one
  spend rule (`docs/ports/store-get-gate.md`, REL-15). A free seat can always be
  hired. A priced seat can be hired only while Apple checkout is open. While
  checkout is closed, the confirm step shows the price and "Purchases are not
  available yet" (`mobilePhoneCopy.noPurchasesTitle`) instead of Hire. Top up
  appears only while checkout is open. When the pack sheet finishes, it returns
  to the confirm step at the same price, where desktop opens a browser.
- **The gate is checked at the POST.** `hireListing` loads the stored request
  first, and a request that carries a confirmation (given now, or stored with it
  from an earlier try) goes out only while `applePurchases.checkoutOpen` is true
  (`ListingHireRequestPlan`, `ListingHireGate.allowsRequest`). Otherwise nothing is
  sent, no request is minted, and the sheet returns to the price it showed with
  the closed line. This covers Retry after checkout closed, and a shelf pick that
  restores a stored confirmation. An unconfirmed request can't spend (the
  platform answers `hire_required`), so it still goes out.
- **And again at each send.** The token read, and the forced refresh before a
  401 resend, can take a while. `createAgentPlaced(_:dispatchGate:)` asks a gate
  right before each send inside `NativeDomainClient`'s transport: the same
  client, the same signed-in account, and open checkout for a confirmed request.
  When it says no, nothing goes out (`NativeDispatchBlocked`) and the stored
  request stays as it was.
- **No real quote, no Hire.** A required hire whose price isn't a positive whole
  number (a zero or missing quote) is unavailable: no price line, the closed line,
  and no Hire, until a valid price is read. `ListingHireFlow.confirm()` refuses it
  too. A `hire_required` with no usable price is the retryable failure. Its Retry
  sends the unconfirmed request again, which can't spend and brings a fresh
  quote. The catalog's price is never substituted for a quote the platform
  didn't give.
- **A name nothing accepts.** The hired name is the listing's title, numbered
  past taken names and app names, and then the catalog name. Each one is checked.
  When none passes, the sheet shows the name line with Back and sends nothing.
- **A bare 400 is retried.** Desktop maps 400 or 422 to the name refusal. On the
  phone only the 422 name codes are a name refusal; a bare 400 can follow the
  charge, so it is the retryable failure under the same request.
- **No economic math.** Only the seat price is shown, in whole Protons. There is
  no balance meter, paid/bonus split or rate.

## Native API seams (`ios/Sources/AtumNativeAPI`)

- `OpenAgentListing` and `OpenAgentCatalog` (new): the catalog row, read as
  desktop reads it. A row the phone can't show (bad id, name or price, or a
  missing `hireRequired`) is dropped. A body that isn't a list is an empty shelf.
  Accent, visibility and revision are ignored, and at most 12 rows are kept.
- `NativeDomainClient.openAgentListings()`: `GET /agents?catalog=open`. The URL
  allowlist accepts that one fixed query on `/agents` and nothing else.
- `AgentCreateRequest` gains optional `listingId`, `hireConfirmed` (sent only as
  `true`) and `disclosureVersion`. A plain create's body is unchanged:
  `{requestId, displayName}`.
- `NativeErrorResponse.Details` also accepts `hire` and exposes
  `hirePriceProtons`. A malformed price is absent, and never turns the refusal
  into an invalid response.
- `OpenAgentHireRefusal.from(_:)`: desktop's refusal map, except a bare 400.
  `hire_required` maps to confirm, `hire_insufficient_protons` to short, other
  409s to limit, a 422 name code to name, 403 or 404 to account, and anything
  else (a bare 400 included) to retry. No refusal drops a sent request;
  `letsNameChange` is true only for name.
- `AgentCreateResponse` and `AgentCloudPlacement` (new): `POST /agents`'s agent
  with its `cloud_placement`. An unknown or malformed placement is absent and
  never fails the create. `NativeDomainClient.createAgentPlaced(_:)` returns it;
  `createAgent(_:)` is unchanged for its other callers.
- `AtumChat.AssistantNameCheck`: `key(_:)` (the platform's duplicate key),
  `fold(_:)` (its Latin skeleton) and `isCatalogName(_:apps:)`. `problem(_:others:)`
  now compares duplicates by `key`, which the platform refuses too, and takes an
  optional `apps` list. Desktop's word, role and pair rules for app names are not
  ported; the platform still applies them, and its refusal shows as the name line.

The smallest model seam outside turn state: `openAgentListings()`,
`hireListing(_:name:hireConfirmed:)` and the private `adoptHiredAssistant`, next
to `createAssistant` in `LiveAppModel.swift`. No AtumChat, model picker or Drive
code changed.

## Copy

All visible words come from the pinned export:
`roster-create-copy.{readyToHire,hirePrice,hiring,hired,hireFailed,newAssistant}`,
`mobile-copy.mobileScreensCopy.shell.{agentHireConfirm,agentHireShort,agentNameRefused,agentLimitRefused,agentAccountRefused}`,
`desktop.common.{back,retry,done}`, `mobilePhoneCopy.noPurchasesTitle` and
`launch-copy.gettingReady`.

The price is formatted with `ProtonAmountFormat.price`: "60,000" in English and
"60.000" in Vietnamese. Listing titles and summaries are catalog data from the
platform, not app copy.

**Pending key:** the "hired, chat still getting ready" line. Desktop has no such
state (its sheet shows Done at once), so it exports no key. The phone uses the
nearest exported line, `src.matrix.launch-copy.copies.gettingReady` ("%1$@ is
getting ready…" / "%1$@ đang khởi động…"), behind `ListingHireCopy.settingUp`. A
proposed desktop key is `roster-create-copy.hireSettingUp`; when it is exported,
repin and swap the key.

**Pending key:** `src.matrix.roster-create-copy.copies.makeYourOwn` ("Make your
own" / "Tự tạo trợ lý") is not in the export. Desktop's PR says none of its six
keys are in `phone-export-keys.json`, and the wave 4 repin brought in five of
them. Until it is exported, the label uses the nearest exported key,
`roster-create-copy.createAssistant` ("Create assistant" / "Tạo trợ lý"), behind
`home.newAssistant.own`. To fix it, add `makeYourOwn` to desktop's phone export,
repin, and swap the key in `AssistantNewSheet.swift`.

## Not in this slice (as on desktop)

Company hires, protected listings, a listing price separate from the seat fee,
and opening the new chat on Done: desktop only closes the sheet, and the phone
does the same.

## Verification

Every heavy step ran under the shared lock
(`lockf -k /Volumes/AtumTestFlight/.heavy-build.lock`) with `-j 2` / `-jobs 2`.
Derived data was in `/Volumes/AtumTestFlight/dd-w4-e1`. The simulator was one
iPhone 17 (`939B69F8`), shut down at the end of each run. Scripts:
`/Volumes/AtumTestFlight/dd-w4-e1/verify.sh` (full) and `verify-ui.sh` (build and
the new UI test). Following the coordinator's 23 Nov lock rule (slim runs,
behind the W4-AB fix round), later runs repeated only the build and the failing
or new test.

| Check | Run | Result |
| ----- | --- | ------ |
| `swift test` (whole package) | 1 | 735 tests, 0 failures. New `NativeDomainClientTests`: open catalog read and row dropping, non-list body, create body (a plain body is unchanged), the listing hire POST, and the refusal map |
| Debug simulator build (`build-for-testing`) | 1 | failed: a Swift 6 Sendable error in `ScriptedHomeHost` (a ternary closure), fixed with static function references |
| Debug simulator build | 2–5 | succeeded |
| AtumMobileTests: `ListingHireStateTests` (10, new) and `StoreCommercePresentationTests` (17) | 2 | 27 tests, 0 failures |
| UI: `ListingHireUITests` | 2 | not reached: the run hit the 2 h background ceiling (mostly lock wait) on a heavily loaded simulator |
| UI: `ListingHireUITests` | 3 | failed. The name field took focus on appear, and the keyboard scrolled the shelf out of sight. **Product fix:** the name field now takes focus only when there is nothing to hire |
| UI: `ListingHireUITests` | 4 | passed (454 s) |
| UI: `ListingHireUITests`, after making Retry and Done full width | 5 | passed (527 s) |
| `python3 scripts/public_guard.py --base origin/main --head HEAD` | final | exit 0 |

The UI walk covers en and vi, each in light and dark (`-atum.appearance`). In
each, the free seat goes list → hiring → error → Retry → done → Done closes, and
the priced seat goes price → closed-checkout line, no Hire → Back to the shelf.
The two `AssistantsWave3UITests` (create-sheet regression) were in run 2's
selection. One passed before the ceiling; they are left to the hosted shards
under the slim rule.

Evidence, outside the repo:

- Screenshots: `/Volumes/AtumTestFlight/dd-w4-e1/shots/hire-{en,vi}-{light,dark}-{1-list,2-hiring,3-error,4-done,5-confirm}.png`
  (20, from run 5).
- Result bundles: `/Volumes/AtumTestFlight/dd-w4-e1/ui-hire-5.xcresult`,
  `ui-hire-4.xcresult`, `app-tests-2.xcresult` and `debug-build-*.xcresult`.
  Logs: `swift-test-1.log`, `app-tests-2.log` and `ui-hire-*.log`.
- `Build/Intermediates.noindex` was deleted after the runs.

Not verified here: a live hire. It needs a deployed catalog, and its first real
hire needs the owner's go. Also unverified: VoiceOver announcements on a device,
and the Top up → confirm path with open checkout, which is covered only by
`ListingHireStateTests`.

## Review fix round (23 Nov 2026)

A read-only cross-family review of `952b5f8` found three blocking issues, two
should-fixes and a nit. All six are fixed on this branch.

| # | Finding | Fix | Test |
| - | ------- | --- | ---- |
| 1 | A paid Retry or a shelf pick could send a stored `hireConfirmed: true` after checkout closed, and a zero quote counted as free | `hireListing` builds its request with `ListingHireRequestPlan`: the stored confirmation is loaded first, and a confirmed request needs `applePurchases.checkoutOpen`. `ListingHireGate.allowsPaidHire` needs a positive price; `confirm()` refuses a zero quote | `ListingHireStateTests.testAConfirmedRequestNeverGoesOutWhileCheckoutIsClosed`, `testAClosedGateReturnsToThePriceAndAZeroQuoteCantBeConfirmed`, `testAPricedSeatFollowsTheStoreSpendGate` |
| 2 | A root-owned flow from account A could Retry under account B with A's confirmation; the ledger was keyed by the 32-bit log fingerprint | The hire records its account; `AppRoot` calls `accountChanged(to:)` on every `listingHireAccount` change; late answers for another account are ignored; `hireListing` refuses a different account; the ledger key is the full SHA-256 (`v2`) | `testAnAccountChangeLetsTheHireGoSoItsConfirmationNeverReachesAnotherAccount`, `testTheLedgerKeyIsTheAccountsFullDigest` |
| 3 | A provisioning 400 after the charge cleared the request UUID, so a later pick could buy a second seat | `OpenAgentHireRefusal`: only the 422 name refusal (before any charge) clears; a bare 400 is retried; limit and account keep the UUID. A request that fails to build keeps a stored UUID | `NativeDomainClientTests.testOnlyAPreChargeNameRefusalLetsTheHireRequestGo` |
| 4 | Done showed before a `capacity` hire's room existed | `createAgentPlaced` keeps `cloud_placement`; the new `settingUp` phase shows "getting ready" until a joined room's assistant is the hired one | `NativeDomainClientTests.testListingHireKeepsThePlatformsPlacement`, `ListingHireStateTests.testAHireWhoseChatIsntOpenYetIsSettingUpUntilItOpens`, UI walk step 6 |
| 5 | Numbering missed `Re-searcher` and app names | `AssistantNameCheck.key`, `fold`, `isCatalogName`; the sheet passes the catalog's app names | `testTheHiredNameStepsPastLookAlikesAndAppNames`, `AssistantNameCheckTests.testDuplicatesCompareThePlatformsNameKey`, `testAnAppsNameIsReserved` |
| 6 | Nit: the `keepsRequest` comment | Rewritten with the platform's charge order | — |

Also fixed while there: the lifecycle store's doc comment had been attached to
`LiveListingHireStore`.

Not changed: the make-your-own form still checks names without the catalog's app
names (it now compares duplicates by the platform key). Desktop's form checks app
names too; that is outside this fix round.

### Fix round verification

Each run went through the shared lock, from this worktree, with the same settings
as above (`-jobs 2`, derived data in `/Volumes/AtumTestFlight/dd-w4-e1`, SPM clones
in `/Volumes/AtumTestFlight/spm` with `-disableAutomaticPackageResolution`, one
simulator `939B69F8`, one test worker). The script is
`/Volumes/AtumTestFlight/dd-w4-e1/fix-verify.sh` (`all`, `swift` or `noui`).

| Check | Run | Result |
| ----- | --- | ------ |
| `swift test` (whole package) | fix1, at `3f77fb7` | failed to compile: the new placement test used `try await` inside `XCTAssert` autoclosures. Fixed by binding each answer first |
| Debug simulator build (`build-for-testing`) of the merged head plus the fixes | fix1 | succeeded |
| AtumMobileTests: `ListingHireStateTests` (16, 6 new) and `StoreCommercePresentationTests` (17) | fix1 | 33 tests, 0 failures |
| UI: `ListingHireUITests`, en and vi × light and dark, with the new capacity walk | fix1 | passed (877 s) |
| `swift test` (whole package) | fix2, at `80b042c` | 753 tests, 0 failures, including the new `testOnlyAPreChargeNameRefusalLetsTheHireRequestGo`, `testListingHireKeepsThePlatformsPlacement`, `testDuplicatesCompareThePlatformsNameKey` and `testAnAppsNameIsReserved` |
| `python3 scripts/public_guard.py --base origin/main --head HEAD` | final | exit 0 |

Screenshots (24, run fix1):
`/Volumes/AtumTestFlight/dd-w4-e1/shots-fix/ListingHireUITests.hire-{en,vi}-{light,dark}-{1-list,2-hiring,3-error,4-done,5-confirm,6-setting-up}.png`.
`6-setting-up` is the new state: "Researcher is getting ready…" / "Nhà nghiên cứu
đang khởi động…" with a spinner and Done. Logs and result bundles:
`swift-test-fix{1,2}.log`, `debug-build-fix1.*`, `app-tests-fix1.*`, `ui-hire-fix1.*`.

Not verified here: a live hire (it needs the owner's go), the account-change path
on a device (covered by `ListingHireStateTests` only), the capacity → done
transition with a real room arriving (the scripted host never opens the room), and
Top up → confirm with open checkout.

## Review fix round r3 (23 Nov 2026)

A read-only cross-family review of `e7f8487` held the branch on three money
blockers and three should-fixes. All six are fixed on this branch. Each fix
reuses an existing pattern: the Store journal, `NativeDomainClient`'s transport,
and Home's roster projection.

| # | Finding | Fix | Test |
| - | ------- | --- | ---- |
| 1 | Checkout could close (or the account change) between `hireListing`'s check and the send, while the token was read or force-refreshed before a 401 resend | `NativeDispatchGate`, asked inside `NativeDomainClient.response(...)` right before the first send and right before the 401 resend (`createAgentPlaced(_:dispatchGate:)`). `hireListing`'s gate needs the same client, the same account, and open checkout for a confirmed request. When it says no, nothing is sent (`NativeDispatchBlocked`), the stored request stays, and the sheet returns to its price | `NativeDomainClientTests.testAHireDispatchGateIsRecheckedBeforeEachSend` |
| 2 | The `UserDefaults` ledger had no fallible write before the send, read an unreadable ledger as empty, and dropped the entry as soon as the POST succeeded | `LiveListingHireStore` is now a file journal on the `StoreFileJournal` pattern (atomic, protected, throwing). An unreadable ledger refuses without minting; a failed write sends nothing; a successful hire records its assistant ID and stays until Home opens that chat, and a pick in that window sends nothing | `ListingHireStateTests.testTheRequestLedgerKeepsOneRequestPerListingUntilItsOwnAnswerClearsIt`, `testAnUnreadableOrUnwritableLedgerRefusesInsteadOfReadingEmpty`, `testTheLedgerKeyIsTheAccountsFullDigest` |
| 3 | A 422 name refusal dropped a request that may already have been charged (0192 checks the name before looking the request up) | No refusal drops a sent request. `keepsRequest` is replaced by `letsNameChange` (name only): the entry is marked `nameRefused`, and the next pick sends the same UUID under the name it is picked with | `NativeDomainClientTests.testNoRefusalLetsASentHireRequestGoAndOnlyANameRefusalRenames`, `ListingHireStateTests.testANameRefusalKeepsTheRequestAndTheNextTryRenamesIt` |
| 4 | Done could show with no openable chat: a replaced session returned `.hired` unchecked, and the readiness check accepted rooms Home suppresses | A replaced client or session returns `settingUp`. Readiness is `ListingHireChat.opens` over Home's `productRooms()`: an openable, joined, unquarantined row for that assistant | `ListingHireStateTests.testTheHireIsDoneOnlyWhenHomeOpensItsAssistantsChat` |
| 5 | `hire_required` without a usable price, and the local closed-checkout answer, fell back to the catalog price | A new `ListingHireResult.checkoutClosed` returns to the quote this hire showed (`ListingHireState.quote`; with none shown, "not available" and no Hire). A `hire_required` with no positive price is a retry, whose unconfirmed request fetches a fresh quote | `ListingHireStateTests.testAClosedCheckoutKeepsTheShownQuoteAndAMissingQuoteNeverEnablesHire`, `testAClosedGateReturnsToThePriceAndAZeroQuoteCantBeConfirmed` |
| 6 | The fallback name skipped the checker | `ListingAssistantName.name` checks the catalog name too and returns nil when nothing passes; the sheet then shows the name line (`ListingHireFlow.refuseName`) and sends nothing | `testAListingWithNoValidNameShowsTheNameLineAndSendsNothing`, `testTheHiredNameStepsPastLookAlikesAndAppNames` |

Scope kept narrow: the hire step still has no name editor. After a name
refusal the person changes the name the way they would today, by renaming the
other assistant or app it clashes with, and the next pick sends the same
request under the new name.

### r3 verification

The new lane rule (owner go, 23 Nov) allows only `swift test --filter` for the
touched package tests and the Debug app build locally. UI tests run on the hosted
PR shards. Script: `/Volumes/AtumTestFlight/dd-w4-e1/fix-verify-r3.sh`, run
detached under the shared lock. Output: `run-r3.out`, `swift-test-r3.log`, and
`debug-build-r3.{log,xcresult}`.

| Check | Run | Result |
| ----- | --- | ------ |
| `swift test --filter 'NativeDomainClientTests\|AssistantNameCheckTests'` | r3, at `0387607` | exit 1: the new `testAHireDispatchGateIsRecheckedBeforeEachSend` gave its 401 an empty body, which the transport reads as `invalidResponse`. Fixed in the test (a `matrix_401` body); no product change |
| Debug app build (`build-for-testing`, which also compiles AppTests and UITests) | r3, at `0387607` | exit 0 |
| `swift test`, same filter, with the test fix | r3b | exit 0: 106 tests (102 + 4), 0 failures |
| `python3 scripts/public_guard.py --base origin/main --head HEAD` | final | exit 0 |

Not run locally, under the lane rule: `ListingHireStateTests`, the other
AtumMobileTests, and `ListingHireUITests`. They compile in the Debug build, and
they run on the hosted PR shards. Also not verified: a live hire (it needs the
owner's go), the dispatch gate against a real slow refresh, and a real file
system that refuses a write. The last two are covered by unit tests only.
`Build/Intermediates.noindex` was deleted after the runs.
