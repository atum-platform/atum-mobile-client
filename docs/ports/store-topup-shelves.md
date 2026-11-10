# Store top-up, pack sheet and shelves (wave 2 ST-3..ST-6)

Wave 2 stream ST of the iPhone parity plan v2, on mobile main `dd26d6e`.
Desktop reference: atum-app `050ede8edf5`, `apps/desktop/src/matrix/store/**`.
Audit: lane 4 (`2026-11-10-parity-audit/lane4-store-protons.md`), slices L4-3..L4-6.

## ST-3: item-detail fixes left after #20

`feat/store-commerce` landed as #20 (`6ffaf34`). Remaining desktop item-detail
rows done here:

- **D10, primary action:** "Get · [mark] 8,000" (`mobileScreensCopy.store.getWithPrice`,
  "Get" when free) replaces the legacy "Buy · 8,000 Protons". The mark sits before
  the amount; VoiceOver reads "Get · 8,000 Protons" (`store-detail.tsx:327-333, 615-624`).
- **D5, what it uses:** one check row per requirement token the export names
  (`internet` → `desktop.atum.discover.needsInternet`, `runs-scripts` → `needsScripts`),
  as desktop `storeRequirements` (`store-copy.ts:791-793`). Unknown tokens are not shown.
- **D14, short of Protons:** see ST-5.

Not done (export dependencies, listed below): the "Skill · by Atum" kind line (D2),
the "What it uses" heading, the needs-Atum-AI note (D8), the pet portrait panel (D3, P3).

## ST-4: Proton pack sheet (`ios/App/Store/ProtonTopUp.swift`)

`ProtonTopUpSheet` over the app's single `ApplePurchaseCoordinator`:

- Title "Buy Protons" (`mobilePhoneCopy.purchaseTitle`), close X, `[.medium, .large]` detents,
  interactive dismiss locked while a purchase sheet is up.
- "Your Protons" once, whole and floored, with the mark.
- One row per pack: the mark and the **total** (`paidMicroProtons + bonusMicroProtons`,
  summed in `AppleProtonPackRow`, never shown apart), StoreKit's `displayPrice`, and Buy.
  VoiceOver: `mobilePhoneCopy.productPrice` ("100,000 Protons · 95.000 ₫").
  **No paid/bonus split, saving, rate or per-Proton figure** (owner ruling 1); no
  other payment method or external link (ruling 5).
- Per-pack states from `purchaseState(for:)`: purchasing (atom in Buy), Ask to Buy
  pending, cancelled, credit pending/retrying, credited (Done or Continue), needs
  support (with the transaction ID, selectable), other account, refunded, failed
  (`errorGeneric`, never "nothing was charged"). Catalogue states: loading, closed
  or sandbox-cap paused (`noPurchasesTitle`/`noPurchasesHelp`, rows disabled),
  unavailable (Retry → `load()`).
- Footer: `purchaseHelp` and "Recover balance" (`restorePurchases`) → `restore()`.
- `ApplePurchaseCoordinator.clearSettledOutcomes()` (new): on open and close the sheet
  forgets outcomes already seen (credited, cancelled, refunded, other account, a failed
  attempt) so the next sheet starts from the packs and Buy is available again.
  Purchasing, Ask to Buy pending, retrying, sandbox-cap and needs-support (it carries
  the transaction ID) are kept. Nothing is reloaded, credited or finished by it.
- `ios/StoreKit/ProtonPacks.storekit` descriptions now say only "100,000 Protons" /
  "500,000 Protons" (vi "100.000 Proton"), removing the paid + bonus split (audit E-P1).
  **The matching App Store Connect localizations are still unverified.**

App Store Connect IAP review screenshot: the scripted sheet (synthetic StoreKit, prices
from the local `.storekit` file, no real or sandbox purchase), captured by
`StoreCommerceUITests/testStoreBalanceOpensThePackSheet` in vi and en, medium and large
detent. Saved outside the repo (see Verification). Not uploaded anywhere.

## ST-5: top-up entry points

One reusable entry: `ProtonTopUpEntry` (content gets `present`; the entry owns the
sheet, so it works from any presentation layer) and `ProtonTopUpButton` ("Top up
Protons", `desktop.atum.discover.topUp`). It reads `\.protonTopUp`
(`ProtonTopUpContext`: the coordinator and the fresh balance), installed once in
`AppRoot`. Without a context (scripted S6 hosts, previews) no entry is drawn.

| Entry | File | Behaviour |
|---|---|---|
| Store balance chip | `Store/StoreScreen.swift` | Mark + whole Protons; a button that opens the sheet (desktop `discover-view.tsx:563-581`) |
| Item sheet, short | `Store/StoreItemSheet.swift` | Insufficient balance: primary "Top up Protons"; Continue returns to the item and re-reads catalog/wallet so it can be got (`store-detail.tsx:372-420`) |
| Review, refused short | same | Server refusal for Protons: Top up + Close; Continue pops back to the item |
| Settings › Protons | `Account/AccountSettingsDetail.swift` (AC) | "Top up Protons" row; footer becomes `purchaseHelp` instead of the "until StoreKit is ready" literal |
| Chat | `Chat/Views/ChatScreen.swift` (HC) | `ProtonTopUpChatNotice` above an assistant chat's composer: `mobilePhoneCopy.outOfProtons` + Top up, only when the fresh wallet floors to 0. The phone has no turn-level out-of-Protons signal (desktop's comes from local turn status, `app.tsx:1970-2005`) |

Shared-file edits (minimal, additive): `AppRoot.swift` (one `.environment` line),
`LiveAppModel.swift` (`protonTopUp` context and `freshWalletAvailable`).

## ST-6: Store structure

- Shelf order as desktop (`store-sidebar.tsx:14-21`): Featured, Skills, Assistants, Apps,
  Pets, then Purchased (moved from first to last). Featured items also sit in their kind's
  shelf; featured rows carry `store.featured.<id>` identifiers.
- Shelf names from the current Store copy (`mobileScreensCopy.store.*`): "Assistants",
  not the legacy "Agents".
- Assistants shelf with nothing for hire: "Coming soon" (`desktop.atum.discover.comingSoon`).
- Empty Store: `mobilePhoneCopy.storeEmpty` ("Nothing here yet.").
- **Hatch fold** (`StoreShelfPlan.listings`, desktop `hatch-listing.ts`): while the catalog
  lists `pet/hatch-first` with an offer beside `pet/hatch`, one card. It keeps the
  first-hatch item ID so a review quotes the price shown, wears the regular card's words
  and art, is featured if either is, takes the earlier position, and an owned row wins.
  A higher regular price is struck through under the first-hatch price.
- **Search:** `.searchable` with accent-, đ- and case-insensitive matching over kind,
  title and summary (apps: slug, name, subtitle), `StoreSearch` (`discover-view.tsx:60-72`).
  No match: the system `ContentUnavailableView.search`.
- **Per-item glyphs:** desktop's 49-entry emoji → Phosphor map (`store-card.tsx:24-97`)
  as `StoreGlyphs`, kind glyph fallback (skill sparkle, agent robot, pet paw). The 47 new
  Phosphor Light symbols were vendored by `scripts/generate-phosphor-symbols.py` from the
  Kit file at `050ede8edf5` (`Store*` aliases in `phosphor-map.json`); no existing symbol
  changed.

## PENDING-COPY (export dependencies)

Desktop English source in `matrix/store/store-copy.ts` unless noted.

| Missing | Desktop English | Stand-in now |
|---|---|---|
| wallet needs-support line (proposed `mobileDeviceCopy.walletStatesNeedsSupportText`) | — (phone-only, lane 4 D-3) | `purchaseCreditPending` + transaction ID |
| checkout paused for review | — (phone-only, D-10) | `noPurchasesTitle` |
| support contact / transaction-ID label | — (phone-only) | ID shown unlabelled |
| `search` | Search the store | `mobileDeviceCopy.uiSearch` ("Search") |
| `searchEmpty` | Nothing matches your search. | system `ContentUnavailableView.search` |
| `firstHatch`, `regularPrice` | First hatch / Regular price | struck price only, unlabelled |
| `whatItUses` | What it uses | rows without heading |
| `itemByAtum`, `kind.*` | Skill · by Atum / Skill, Assistant, Pet | not shown |
| `discoverLine` | {kind} · {summary} (Featured rows) | not shown |
| `agentsSoonNote` | Assistants you can hire will appear here. | heading + "Coming soon" only |
| `subtitle` | Skills, assistants and apps that give Atum new abilities. | not shown |
| `needsAtumAi` | Only assistants on Atum’s AI can use this. One on its own model isn’t listed. | not shown |
| `topUp` (short) | Top up | `desktop.atum.discover.topUp` ("Top up Protons") |

## Deferred / unverified

- Live IAP: depends on platform P1 deploy + allowlist (SV-1) and owner ASC agreements.
  No real or sandbox purchase was made; StoreKit and the server are synthetic in tests.
- ASC product localization texts still need checking for a paid/bonus split (E-P1).
- The chat notice is balance-based; a turn-level out-of-Protons signal needs a contract.
- Physical iPhone, dark mode and five-locale captures belong to the coordinator pass.

Entry hosting: `ProtonTopUpEntry` owns its sheet where the entry stays put (Store chip,
Settings row). Where the entry disappears once Protons arrive (the item's short action,
the chat notice), the sheet is hosted by `.protonTopUpSheet(...)` on a stable container;
otherwise the wallet refresh after a credit removed the button and dismissed the sheet
before Continue showed (found by the UI test, fixed).

## Verification (2026-11-11, iPhone 17 simulator, iOS 27.0)

Every heavy command ran as `TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k
/Volumes/AtumTestFlight/.heavy-build.lock …`, DerivedData `/Volumes/AtumTestFlight/dd-w2-st`,
package scratch `/Volumes/AtumTestFlight/swiftbuild-w2-st`, one simulator, shut down at exit.

| Check | Result |
|---|---|
| `swift test --package-path ios -j 2 --scratch-path …/swiftbuild-w2-st` | PASS: 1,297 tests (683 + 582 + 16 + 16), 0 failures; includes new `StoreShelvesTests` (3) and 4 coordinator/pack-row tests |
| `xcodebuild … -destination 'generic/platform=iOS Simulator' ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build-for-testing` | TEST BUILD SUCCEEDED |
| `-only-testing:AtumMobileTests/StoreCommercePresentationTests` | PASS 15/15 (6 new) |
| `-only-testing:AtumMobileTests/KitGlyphTests` | PASS 6/6 (every alias, including the 47 new Store glyphs, is a compiled symbol) |
| `-only-testing:AtumMobileUITests/StoreCommerceUITests` (`-parallel-testing-enabled NO`) | PASS 6/6, including the new top-up → credited → Continue → Get flow and the pack-sheet screenshot test (vi, en) |
| `S6SystemUITests/testU9StoreOpenPushesItsScriptedRoom` | PASS |
| `S6SystemUITests/testU8EveryStoreState` | FAIL at line 222 (`"Chưa có số dư"` in `store.partial`): pre-existing, no Swift source at `dd26d6e` renders that text. The empty-state assertion updated here passes |
| `S6SystemUITests/testU7…` | Not run (needs the external appearance runner) |
| `generate-phosphor-symbols.py --check`, `import-design-exports --verify`, `plutil -lint`, `git diff --check` | PASS |

Screenshots (not in the repo, not uploaded): `/Volumes/AtumTestFlight/w2-st-screens/`
`U-Store-13-pack-sheet-{medium,large}-light-{vi,en}.png` (ASC review candidates),
`U-Store-4-insufficient-light-vi.png`, `U-Store-12-topup-credited-light-vi.png`.
