# Assistant card rows and routine copy (wave 2, AS-2)

Parity plan v2 slice AS-2. Audit evidence: lane 3 S3 (D-3, D-4, D-12) and lane 3 S4 (D-5, D-8), checked against desktop `050ede8edf5`.

## What changed

### 1. Pet row tells the truth (lane 3 D-3)

Desktop `assistant-card.tsx:737-752,809-836`: the Pet row exists only when there is a Store, shows the assigned pet's name or "Choose", and opens the Store's Pets shelf.

- `NativeDomainClient.agentPet(assistantID:)` reads `GET agents/{id}/pet` (desktop `requestMatrixAgentPet`) and `agentPetCatalog(assistantID:)` reads `GET agents/{id}/pets` (desktop `requestMatrixAgentPetCatalog`). Both are read-only. `pet` and `pets` are added to the client's agent path allow-list.
- `AgentPetSelection`, `AgentPetCatalog` and `AgentPetName` (`ios/Sources/AtumNativeAPI/AgentPet.swift`) decode only what the row needs and decide the name the way desktop `MatrixPets.read` decides whether a sprite exists:
  - a bundled pet (`gigi`, `cookie`, `bailey`, `mochi`) is named from desktop's asset `displayName` (`apps/desktop/assets/pets/<slug>/pet.json`), with no catalog read;
  - a personal pet is named from the fresh library (`personal[].display_name`, not deleted);
  - a hidden pet, "no companion", a catalog/petdex pet or an unknown kind says "Choose";
  - the primary with nothing saved shows Gigi only while the catalog says she is owned or visiting (desktop's stand-in).
- The catalog is fetched only when a personal pet or the primary's stand-in needs it (`AgentPetName.needsCatalog`). Any read failure leaves "Choose", as desktop's `.catch(() => {})` does.
- `AssistantDefinitionActions.pet` carries the read; `LiveAppModel.assistantDefinitionActions` fills it, so both card entries (chat info, Settings › Assistants) get it with no extra wiring.
- The row is hidden when the host has no Store (`AssistantCardLayout.showsPet(storeAvailable:)`).

Not done here: desktop's default-agent `pets/visit` activation (a write). The phone only reads, so an account that has never been visited on any device shows "Choose" on the primary until desktop has run the visit once. Choosing a pet stays AS-9 (L3-S11).

### 2. Skills row tells the truth (lane 3 D-4)

Desktop `skills-popover.tsx:13-58`: shown only with skills, the value is the count, the list prettifies names with `skillLabel`, and "Find more skills" opens the Skills shelf.

- The row is hidden at zero skills (`AssistantCardLayout.showsSkills(count:)`).
- The value is the count alone. `skillsLabel` ("Skills, 3") is now the row's accessibility label, as on desktop, instead of its visible value. This fixes "Skills … Skills, 3".
- Names go through `AssistantSkillLabel.label` (desktop `skillLabel`: "google-calendar" → "Google calendar").
- "Find more skills" sits under a divider with desktop's up-right arrow and opens the Skills shelf.

### 3. Store shelf deep link

`Router.openStore(shelf:)` selects the Store tab at its root and records `storeShelfRequest`. `StoreScreen` takes `shelfRequest` / `onShelfShown`, scrolls to the first row of that shelf once (`ScrollViewReader`), then clears the request. When the shelf is empty the Store simply opens at the top. `ChatInfoActions.openStore` and the card's `onOpenStore` now take a `StoreSectionKind`.

### 4. Offline caption (lane 3 D-12)

The card draws the exported `offline` caption ("You're offline. You can edit once you're connected.") under the header while the session shows the connection glyph (`showsConnectionGlyph`), matching desktop `assistant-card.tsx:408`.

### 5. Routines speak the app language (lane 3 D-5)

The Swift literals are gone:

| Was | Now (desktop key) |
|---|---|
| `AgentRoutinesCardValue` "Chưa có" / "N việc" | `routineCount` |
| "Đang chuẩn bị…" + a phone-only description | `routinePreparing` (desktop shows only this line) |
| "Đang chuyển lịch cũ" | `routineLegacyMoving` |
| "Không sửa được trên điện thoại" | `routineReadOnly` ("View only") |
| spinner with no words | `routineLoading` |
| card `loadFailed` ("Couldn't load X's info.") | `routineLoadFailed` |

These keys are not in the pin yet. `AssistantCardCopy.routine(_:)` / `routineCount(_:)` read the pin first (`design.copy.contains`), then `AssistantRoutinePendingCopy` (`ios/Sources/AtumChat/AssistantCardPendingCopy.swift`), which holds desktop's exact `copy.ts` values for en, vi, ja, zh and zh-Hant.

### 6. "Where it lives" has no phone literals (lane 3 D-8)

`AgentHomeCopy` (`AssistantHomeSheet.swift`) no longer switches on `vi` with English/Vietnamese literals. Each word resolves through `AgentHomeCopy.source(_:)`:

- desktop words already in the pin (`title`, `livesOn`, `moveSection`, `ready`, `noModels`, `anotherMac`, `losses.*`, `progress.*`, …);
- phone-only labels mapped to existing export words for the same thing (`desktop.common.close`, `model-picker-copy.COPY.chooseModel`, `mobileDeviceCopy.uiSelected`, card `setupRow` "Status", card `footnote` for the next-turn note, card `saveFailed`);
- desktop words the pin does not carry yet, from `AgentHomePendingCopy` (`ios/Sources/AtumChat/AgentHomePendingCopy.swift`), generated from desktop `agent-home-copy.ts` `words` for all five locales.

Wording changes that follow desktop: the move failure line is desktop's single sentence (no "· Current home: X" suffix), the primary button reads "Move" (desktop has no "Move {name}"), reachability reads Ready / Asleep / Not reachable, and a move that did not finish reads desktop's `endedFallback`.

## Missing export keys (EX stream)

All are desktop `apps/desktop/src/matrix/assistant-card/copy.ts` or `apps/desktop/src/matrix/agent-home-copy.ts` at `050ede8edf5`; the phone falls back to the exact desktop values until the next pin.

Assistant card (`src.matrix.assistant-card.copy.assistantCardCopies.*`):

| Key | en |
|---|---|
| `routineCount` (plural) | No routines / 1 routine / {n} routines |
| `routineLoading` | Loading routines… |
| `routineLoadFailed` | Couldn’t load {name}’s routines. |
| `routineLegacyMoving` | Moving old schedules. |
| `routinePreparing` | Getting ready… |
| `routineReadOnly` | View only |

Where it lives (`src.matrix.agent-home-copy.words.*`): `finding`, `unknownPlace`, `retryRead`, `unavailableFallback`, `unavailableReasons.{offline,version_unsupported,home_conflict,catalog_unavailable}`, `readinessAsleep`, `readinessUnavailable`, `acceptCheckpointLoss`, `lastCheckpoint`, `refusals.{target_unavailable,connection_unavailable,catalog_stale,not_eligible,unknown_export_class,cloud_controller_version_unsupported,model_unavailable,current_home_unreachable}`, `issues.target_unavailable`, `endedFallback`. `place("")` ("Another Mac") is a function on desktop and stays a phone table value.

## Shared and cross-stream edits

- `ios/App/LiveAppModel.swift`: the `pet:` closure in `assistantDefinitionActions` and `readAssistantPetName(roomID:)`.
- `ios/App/AppRoot.swift`: three call sites (`StoreScreen` shelf params, the Settings card's `onOpenStore`, the chat info `openStore`).
- `ios/App/Chat/Stores/Router.swift` (HC): `storeShelfRequest`, `openStore(shelf:)`, `storeShelfShown()`.
- `ios/App/Store/StoreScreen.swift` (ST): `shelfRequest`, `onShelfShown`, and a `ScrollViewReader` around the list.
- `ios/App/Chat/Views/ChatInfoSheet.swift`: `AssistantDefinitionActions.pet`, `ChatInfoActions.openStore` takes a shelf.
- `ios/Sources/AtumNativeAPI/NativeDomainClient.swift`: two read methods and two allow-listed suffixes.
- `tests/test_copy_keys_in_pin.py`: `routineCount` added to PENDING; `words.summary` and `words.waitingForMac` removed (they are pinned since the wave 1 repin, and the app no longer names them as literals).

## Verification

See the session's final report for the exact locked commands. Tests added or changed:

- `Tests/AgentPetNameTests.swift`: bundled, hidden, none, personal (fresh and deleted), unknown kind, primary stand-in.
- `Tests/NativeDomainClientTests.swift` `testAgentPetReadsUseOnlyThePetAndShelfRoutes`.
- `Tests/AtumChat/AssistantCardPendingCopyTests.swift` (renamed from `AgentRoutinesCardValueTests`): routine count per locale, no Vietnamese outside vi, no Latin words in ja/zh, `skillLabel`, row visibility; `AgentHomePendingCopyTests` for every key in every locale.
- `AppTests/AssistantRoutineStateTests.swift`: every home word is in the pin or the pending table, the card row words are pinned, routine words follow the app language.

Not verified live: the pet read against a real account (no platform calls were made from this session), and the Store shelf scroll on a device.
