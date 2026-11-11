# Wave 3, Assistants stream (`feat/w3-assistants`)

Parity plan v2 wave 3, AS stream: AS-3 new assistant parity (lane 3 L3-S5),
AS-4 delete/rename assistant (L3-S6), AS-6 routines polish (L3-S8), and AS-5
bot handle editor (L3-S7). Base `main` `dc0634b`. Desktop reference: the Matrix
renderer, `apps/desktop/src/matrix/**` in `atum-desktop` (`c14d74a1`, the same
files the lane 3 audit read at atum-app `050ede8edf5`). Platform reference:
`atum-platform` `7df04652c`.

## What changed

### AS-3 New assistant (L3-S5, fixes lane 3 D-1)

`HomeNewAssistantView` (in `HomeScreen.swift`) is replaced by
`AssistantNewSheet` (`ios/App/Chat/Views/AssistantNewSheet.swift`), mirrored
from desktop `NewAssistantDialog` (`agent-roster.tsx:207-855`):

- Fields in desktop order: Display name (`assistantCardCopies.nameField`, with
  `nameHelper` "The name people see in chats." and desktop's placeholder
  `desktop.atum.agents.namePlaceholder`), Bot handle, Photo, Who they are, What
  they do. The phone keeps its cloud disclosure line (phone-better, lane 3).
- Bot handle: `@` + field + fixed `_bot`. It follows the name
  ("Tiếp thị" → `tiep_thi`) until the person types; a well-formed handle is
  checked 600 ms after typing pauses; a taken one offers "Use @tiep_thi42_bot".
  Rules are a port of desktop `handle-rules.ts` (`AgentHandleRules`, AtumChat).
  The field only appears when there is an assistant to check with (the
  directory answers for "an assistant of this account", as desktop's sheet).
- Photo: `PhotosPicker`, the existing `AssistantAvatarPhoto.prepare` (square
  centre crop, ≤ 2 MiB JPEG). Preview is a 48 pt circle (ruling 2).
- Name check before anything is created (`AssistantNameCheck`, AtumChat): a
  narrow subset of desktop `checkAssistantName` that refuses only what the
  platform certainly refuses: empty, over 40, a check mark, a reserved name
  (`atum`, `moon`, `ben`, `andy`, `taylor`, `admin`, `founder`, `support`, any
  `atum…`), and a duplicate of one of the owner's assistants. The script,
  look-alike and skeleton rules stay with the platform.
- D-1: a platform name refusal now shows its own line: reserved →
  `problems.reserved`, taken → `problems.duplicate`, invalid → desktop's
  `agentNameRefused` (PENDING-COPY), instead of the generic create failure.
- After Create (the durable lifecycle is unchanged: one UUID, begin/resume, no
  twin), the sheet finishes three follow-ups in desktop's order, each retried
  alone:
  1. Persona: desktop `assistantPersona` (`# Name`, `## Who you are`,
     `## What you do`, `AssistantCreatePersona`) written over the default
     definition with the same CAS as card writes (one re-read on conflict).
     The lifecycle begin carries no persona (`matrix-agent-lifecycle.ts:253`).
  2. Handle: `AgentHandleClaimWalk` (port of `claimMatrixAgentHandle`):
     current → check each candidate → claim. A reserved stem ends its group, a
     409 between check and claim moves on, a lost answer is resent with the
     same request ID. Closed / denied / missing / invalid / exhausted settle
     quietly (the card offers a handle later), as desktop.
  3. Photo: the existing avatar write.
  A failed step shows its desktop line (`handleFailed`, `photoFailed`, or the
  card's `saveFailed` for the persona) and the button becomes Retry / Retry
  photo; **Done** appears once the assistant exists and opens its chat.
- A resumed setup (a pending UUID from an earlier sheet) opens its chat as
  before; it has no answers of this sheet to apply.

### AS-4 Delete (retire) and rename (L3-S6, D-13)

- `NativeDomainClient.retireAgent(assistantID:)`: `DELETE agents/{id}` with an
  empty body (platform `matrix-authority.ts:2063-2067`, route
  `apps/shell/src/app/api/matrix/v1/agents/[assistantId]/route.ts`). The bare
  `agents/{id}` path is allow-listed for `DELETE` with an empty body only.
- `AssistantCardLayout` now ends a non-primary card with `.retire`
  (`AssistantRetirePolicy`); the primary never has it. The card draws
  desktop's "Delete {name}…" (`deleteRow`) in its own section, then an alert
  with desktop's `agentRetireTitle` / `agentRetireBody` / `agentRetireConfirm`
  / `agentCancel` (PENDING-COPY, exact desktop values in five locales).
- No half-deleted state: nothing on the phone changes until the platform
  answers. A failure keeps the card and shows `agentRetireFailed`. After
  success the model re-reads `/agents` and leaves + forgets the owner's
  one-to-one chat with it (desktop `retired-agent-rooms.ts`; a room with anyone
  else in it stays), then the host leaves the card (chat info: pop to Home;
  Settings: dismiss Account).
- Rename: the card already renames in place. `AssistantCard(startsRenaming:)`
  focuses the name field on open, the hook desktop's roster "Rename…" needs.
  The Home row long-press menu (Info, Rename…, Delete {name}) belongs to HC-7
  (row/chat menu parity) and is **not** in this branch; HC wires
  `AssistantCard(startsRenaming: true)` and `LiveAppModel.assistantRetireActions(roomID:)`.

### AS-5 Bot handle editor (L3-S7)

`AssistantHandleEditor` (`ios/App/Chat/Views/AssistantHandleEditor.swift`)
replaces the card's read-only handle line, mirrored from desktop
`MatrixHandleEditor` (`handle-editor.tsx`) as the card uses it
(`assistant-card.tsx:466-509`):

- "Bot handle" with "In use" + `@handle` + Change, or "No bot handle yet" +
  Choose a bot handle; the help line "Others type this @name…".
- Editing: the `@ … _bot` field, check as typing pauses, status lines
  (checking, available, taken, reserved, invalid, "This is the current
  handle."), the 30-day rule when there is a handle.
- Save asks first (`claimTitle` / `claimTextAgent`, or `renameTitle` /
  `renameTextAgent`), then claims or renames. A rename refused inside the 30
  days reads `tooSoon` with the date; other refusals have their own line and a
  Refresh. A change whose answer was lost is kept and offered again with
  "Check earlier change" (same request ID), and no other change is allowed
  meanwhile (desktop's `pending`).
- Client: `aliasCheck`, `aliasCurrent`, `aliasClaim`, `aliasRename`
  (`ios/Sources/AtumNativeAPI/AgentAliases.swift`), with desktop's error codes
  (`AgentAliasRefusal`, incl. `alias_claims_closed` → `closed`).
- The editor is disabled while the session is offline.

### AS-6 Routines polish (L3-S8, D-11)

`AssistantRoutinesView.swift`, against desktop `routines-panel.tsx` and
`routines-words.ts` (ported as `AssistantRoutineWords`, AtumChat):

- Rows: name, the schedule sentence ("Hằng ngày lúc 8:30", "Mon, Wed at 9:30",
  "Chủ nhật lúc 7:00"), then the next run as today / tomorrow / date, with the
  zone named only when its clock differs from the device's (Asia/Saigon and
  Asia/Ho_Chi_Minh read as one). The raw IANA caption is gone (D-11).
- Pause / Resume as a trailing swipe and in the long-press menu (the same
  update with `enabled` flipped, idempotent request ID; a conflict reloads and
  says `routineConflict`).
- Empty state: desktop's "Morning brief" suggestion opens the editor with its
  instruction filled in.
- Quota: at 64 the "+" goes and desktop's `routineQuotaReached` line shows.
- Editor: desktop's subtitle, name placeholder ("Leave empty to use the first
  words"; an empty name stores the instruction's first words,
  `matrixRoutineTitle`), the instruction placeholder (`purposePlaceholder`),
  the enabled hint, and "Save & run now" when there are unsaved changes.
  Labels sit above their fields and weekday chips use desktop's words in an
  adaptive grid, so nothing clips at AX sizes.
- Not ported: "Runs on · Cloud / this Mac" and "Move to the cloud" (cloud-only
  since 2026-11-09, so always Cloud; lane 3 P3), and the interval kind (stays
  read-only).

## Server gates

None of these slices fakes success. Every route exists on the platform and is
admitted for any native domain client:

| Use | Route | Gate |
|---|---|---|
| Delete | `DELETE /api/matrix/v1/agents/{id}` | Platform refuses the primary; phone hides the row for it. |
| Handle check / current / claim / rename | `GET aliases/check`, `GET aliases/current`, `POST aliases/claim`, `POST aliases/rename` | `not_configured` (503) when the directory is off: the editor shows `failed` + Refresh, the create sheet settles quietly and the card offers a handle later. `alias_claims_closed` (403) → `closed`. |
| Persona after create | `PUT agents/{id}/definition` | Existing. |
| Photo after create | `PUT agents/{id}/avatar` | Existing. |

Not verified against production: whether the frozen `atum.mobile-native-api`
pack lists the alias and retire routes (lane 3 §1.3 left this open). If the
pack must list them, that is an SV/contract follow-up; the client follows the
platform source above.

Desktop-side gaps noted, not ported: desktop main keeps a persistent journal
of an unanswered claim across restarts; the phone keeps it only for the life
of the sheet or card. Desktop's retired-agent room sweep on other devices
(tombstones in `/agents` `retired_agents`) is not on the phone yet: a chat with
an assistant retired elsewhere stays until removed by hand.

## PENDING-COPY

The phone reads the pin first (`design.copy.contains`), then desktop's exact
values in en, vi, ja, zh, zh-Hant. None is hand-edited into
`ios/Vendor/AtumDesign`. All need the next `export:mobile` (EX stream).

`desktop.matrixShell.*` (desktop `apps/desktop/src/i18n/{en,vi,ja,zh,zh-hant}.ts`,
`AssistantShellPendingCopy`): `agentRetireTitle`, `agentRetireBody`,
`agentRetireConfirm`, `agentRetireFailed`, `agentCancel`, `agentNameRefused`.

`src.matrix.assistant-card.copy.assistantCardCopies.*` (desktop
`assistant-card/copy.ts`, `AssistantRoutinePolishCopy`): `routineDialogSubtitle`,
`routineNamePlaceholder`, `routineEnabledHint`, `routineQuotaReached`,
`routineSuggestBrief`, `routineSuggestBriefInstruction`, `routineSaveAndRun`,
`routineDailyWords`, `routineWeeklyWords`, `routineMonthlyWords`,
`routineOnceWords`, `routineUnsupported`, `routineNextToday`,
`routineNextTomorrow`, `routineNextDate`, `routineNextZone`. Desktop's values
are functions; the phone writes them as `%1$@`/`%2$@` templates in argument
order. Vietnamese `routineWeeklyWords` has a Sunday branch ("Chủ nhật lúc …")
that the phone keeps in code; the export will need the same branch.

Weekday chip words (`routines-words.ts` `WEEKDAY_CHIP` / `WEEKDAY_WORD`) are
desktop data tables, ported as-is.

## Shared and cross-stream edits

- `ios/App/Home/HomeScreen.swift` (HC): the Start chat bottom bar now pushes
  `AssistantNewSheet`; `HomeNewAssistantView` is removed. Its
  `StartChatCopyKey` cases are left in place.
- `ios/App/LiveRosterRows.swift`: `HomeAssistantActions` gains `names`,
  `checkHandle`, `followUp`.
- `ios/App/LiveAppModel.swift`: `assistantRetireActions`, `retireAssistant`,
  `assistantHandleActions`, `newAssistantHandleCheck`, `assistantNames`,
  `assistantCreateFollowUp`.
- `ios/App/AppRoot.swift`: the Home `newAssistant` actions, and the card's
  handle/retire wiring in the chat host and Settings › Assistants.
- `ios/App/Chat/Views/ChatInfoSheet.swift`: `ChatInfoActions.assistantHandles`,
  `.assistantRetire`, `.onAssistantRetired`, passed to the card.
- `ios/App/Debug/ScriptedHomeHost.swift`, `ios/App/Chat/Views/ScriptedChatHost.swift`:
  scripted names, handle check, directory and retire
  (`-AtumScriptedOtherAssistant`, `-AtumScriptedRetireFails`).
- `ios/Sources/AtumNativeAPI/NativeDomainClient.swift`: four alias URLs and
  the retire DELETE.
- `ios/AtumMobile.xcodeproj/project.pbxproj`: three file references added by
  hand (`AssistantHandleEditor.swift`, `AssistantNewSheet.swift`,
  `AssistantsWave3UITests.swift`).

## Tests

Unit (SwiftPM):
- `Tests/AtumChat/AssistantsWave3Tests.swift`: `AgentHandleRulesTests`,
  `AssistantRoutineWordsTests`, `AssistantShellPendingCopyTests`,
  `AssistantNameCheckTests`.
- `Tests/AtumChat/AssistantCardPolicyTests.swift`: the retire row is last and
  non-primary only.
- `Tests/AgentAliasesTests.swift`: decoding invariants, refusal mapping, and
  the claim walk (existing handle, taken/reserved, 409, exhausted, lost-answer
  replay with the same request ID, failed check).
- `Tests/NativeDomainClientTests.swift`: retire is a bodiless DELETE on
  `agents/{id}` and refuses another assistant's answer; alias routes and
  bodies; `alias_claims_closed` → closed.

UI (`ios/UITests/AssistantsWave3UITests.swift`, scripted, Vietnamese):
new-assistant fields and handle-following, taken handle suggestion, duplicate
name refused before create, AX5 reachability; Delete row, confirmation,
retired → leaves, failed delete, no Delete on the primary, AX5 card; handle
choose → check → confirm → claim; routine sentence and no raw zone, swipe
Pause, editor subtitle/placeholder/empty-name save, AX5 routines.

Results: see "Verification" below.

## Verification

(filled in after the locked runs)

## Not verified

- No live platform calls were made from this session: retire, alias check,
  claim and rename are tested against the platform source and synthetic
  responses only.
- Physical iPhone, VoiceOver and the desktop side-by-side captures.
- The Home long-press "Rename…" / "Delete" entries (HC-7).
