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
| done    | "Researcher is in your chats."                              | Done (closes the start-chat sheet) |
| short   | "Not enough Protons. Top up to continue."                   | Top up (when checkout is open), Back |
| failed  | "Couldn't hire Researcher. Try again." or the platform's final refusal (name, limit or account) | Retry (retryable only), Back |

- **Free seat:** the first two assistants hire in one press, with no price shown.
- **Third+ assistant:** the price is shown first. A `hire_required` refusal (for
  example, from a stale catalog quote) also leads to the confirm step, at the
  platform's price.
- **Name:** the listing's title in the app language ("Nhà nghiên cứu" in
  Vietnamese), numbered when it would duplicate an existing assistant
  ("Researcher 2"). It uses the same `AssistantNameCheck` as the form.
- **Leaving mid-hire:** the flow (`ListingHireFlow`) belongs to the app root, so a
  hire under way survives leaving the sheet, and reopening it shows the hire again.
  Any other state is let go when the sheet closes.
- **VoiceOver:** done, short and failed are announced.

### After the hire

`LiveAppModel.hireListing` sends `POST /api/matrix/v1/agents` with
`{requestId, displayName, listingId, hireConfirmed?, disclosureVersion?}`. That is
the route and body desktop sends. There is no persona write, so the platform's
seeded definition and skills stay. On success the model:

1. reads `/agents` again;
2. retries the new assistant's owner-room invite, including one that arrived
   before the roster knew the inviter;
3. claims a handle in the background, as for a made assistant.

Any failure in those steps is left to the assistant's card, as on desktop.

**One hire, never two.** The request UUID, name and confirmation are stored per
account and listing (`LiveListingHireStore`, `UserDefaults`, keyed by the
account's fingerprint). A Retry, a confirmation or a relaunch resumes the same
request. Only the platform's final answers clear it: success, name, limit and
account. `hire_required`, `short` and transport failures keep it.

### Phone-only rules

- **Spend gate.** A priced seat is a Proton spend, so it follows the Store's one
  spend rule (`docs/ports/store-get-gate.md`, REL-15). A free seat can always be
  hired. A priced seat can be hired only while Apple checkout is open. While
  checkout is closed, the confirm step shows the price and "Purchases are not
  available yet" (`mobilePhoneCopy.noPurchasesTitle`) instead of Hire. Top up
  appears only while checkout is open. When the pack sheet finishes, it returns
  to the confirm step at the same price, where desktop opens a browser.
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
- `OpenAgentHireRefusal.from(_:)`: desktop's refusal map. `hire_required` maps to
  confirm, `hire_insufficient_protons` to short, other 409s to limit, 400 or 422 to
  name, 403 or 404 to account, and anything else to retry.

The smallest model seam outside turn state: `openAgentListings()`,
`hireListing(_:name:hireConfirmed:)` and the private `adoptHiredAssistant`, next
to `createAssistant` in `LiveAppModel.swift`. No AtumChat, model picker or Drive
code changed.

## Copy

All visible words come from the pinned export:
`roster-create-copy.{readyToHire,hirePrice,hiring,hired,hireFailed,newAssistant}`,
`mobile-copy.mobileScreensCopy.shell.{agentHireConfirm,agentHireShort,agentNameRefused,agentLimitRefused,agentAccountRefused}`,
`desktop.common.{back,retry,done}` and `mobilePhoneCopy.noPurchasesTitle`.

The price is formatted with `ProtonAmountFormat.price`: "60,000" in English and
"60.000" in Vietnamese. Listing titles and summaries are catalog data from the
platform, not app copy.

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
