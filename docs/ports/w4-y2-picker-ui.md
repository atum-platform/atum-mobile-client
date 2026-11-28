# W4-Y2 Work models in the phone picker, chip and card

Owner, 28 Nov: "agents always report the default Nguyệt Thực model … even
though they are all set to different relay models on my macbook", and "we
retired the moniker - like desktop". Parity means live, rendered behaviour
(memory rule), so the phone now shows the assistant's Work (Mac plan) model
wherever desktop main does, and the owner can pick one.

Built on W4-Y1 ([w4-y-work-selection.md](w4-y-work-selection.md), branch
`fix/w4-y-work-selection-r2`) and its picker contract.

## Desktop reference (atum-desktop `origin/main` 69185d92, read only)

| Surface | Desktop now | Phone before | Phone after |
| --- | --- | --- | --- |
| Composer chip | `model-picker.tsx` `shownPlanName`: the Mac plan's model by its catalog name (`relayCurrentName`, e.g. "Claude Opus 5.5"), with the plan's mark. Ahead of the cloud choice; an Atum pick in flight holds it back (#143 b496f668). | Always the cloud choice: "Nguyệt Thực" for an Atum default even while a Work model answered. | The Work model's catalog name and the plan's mark. Falls back to the cloud choice when there is no Work selection. |
| Assistant card, Model row | Asks the picker for the same name (`trigger` as a function, #143). | The 1.1 offer's display name ("Nguyệt Thực 1.3"), even for a saved subscription. | The Work model's name; else the chip's face for the cloud destination (subscription or line-up name); else the 1.1 name as before. |
| Picker Work rows | `relayRoutes`: one group per plan ("{Plan} plan"), the plan's models selectable when the plan is published and signed in, independent of reachability (`workRelayPickerView`); a pick writes `work_selection_set` (#139). | Read-only hand-off rows, "Works in Work for now" (W4-X2). | Selectable rows per plan, from the W4-Y1 `rows` (connected and last-seen Macs). A pick calls `save(row.id)` only. |
| Selected / Current | The relay row is `current`; Atum and subscription rows are not current while a plan answers (`!relayCurrent`). | n/a | The saved Work row is checked, shaded and reads "Current"; every cloud row yields its check (`yieldingToWork`), so a tap on Atum is a real switch. |
| Saved but unlisted | Not drawn (desktop lists catalog models only). | n/a | W4-Y1 keeps the saved row with "{Plan} · {model}". |
| Offline / last-seen Mac | Readiness ignores reachability; an offline Mac keeps its last plans selectable (#131 also says so). | n/a | Same: W4-Y1 eligibility keeps last-seen Macs. |
| Save states | Pending pick shown as current; failure restores the last server answer. | n/a | The row shows a spinner ("Saving your choice…" to VoiceOver); a conflict or other failure shows the existing save-failed note. |

Desktop main still names Atum's own line-up "Nguyệt Thực 1.3" / "Nguyệt
Thực" in the chat picker and chip (`matrix-models.ts`, `atumChipName`). The
moniker is retired in Work 0.1.20 ("Real model names", `docs/work-runtime-0.1.20-1127.md`)
and wherever a plan model answers. The phone therefore stops showing it for
an assistant whose Work model answers, and keeps the line-up row names as
desktop main does. Removing the line-up name altogether would be a desktop
change first.

Desktop #131 (open, "Agent picker uses the direct T3 path") moves the desktop
picker's plan catalog to the Mac's direct T3 publication. The phone reads
the account catalog (`account_connections_read`), so #131 adds no new phone
rows. It confirms the offline rule above.

## Design decisions

- **No write on open.** The chip, the card and both pickers only call
  `reload(within:)`. A Work write happens only on a Work row's tap; a cloud
  write only on a cloud row's tap. Platform work-route v1.3 §151-153 (a cloud
  picker write clears the relay choice) is respected by never sending a cloud
  write the owner did not choose. Tests: `PhoneWorkPickerFaceTests`
  (`testOpeningReadsOnlyAndNamesTheSavedPlanModel`) and the UI tests below.
- After an explicit cloud pick lands, the picker treats the Work choice as
  cleared until its reread confirms (`cloudPickedSinceWorkRead`); the chip
  does the same (`cloudPicked`).
- The chip, card and picker each own their `PhoneModelPickerWorkSelection`
  from `makeWorkSelection`, retired on close or disappear. The app registry
  in `LiveAppModel` retires them on scope changes.
- `WorkSelectionCalls` is a small seam on W4-Y1's engine (read and write
  closures; the app binds `NativeDomainClient`). It exists so the scripted
  host can drive the real engine for captures. The engine logic is unchanged.
- Work row names use `ModelDisplayName.name(model:displayName:)`, matching
  desktop `matrixModelDisplayName` (an id-only catalog entry still reads as
  words).
- Without `makeWorkSelection` (a host with no Work writer) the W4-X2
  hand-off stays.

## Copy

Only pinned keys are used: `model-picker-copy.COPY.planAccount` ("{Plan}
plan"), `COPY.current`, `mobileDeviceCopy.modelPickerStatesSavingText` (new
in `PhoneModelPickerStateCopyKey`) and `modelPickerStatesSaveFailedText`.
Model names come from the catalog; plan names are product names.

Desktop keys a phone copy export wave would need if the phone later draws
relay greyed states (it has no publication or consent fact today, so these
are not drawn and nothing is invented):

- `src.matrix.mobile-copy.mobileScreensCopy.relay.greyed.unavailable` (desktop
  `relay-copy.ts` `greyed.unavailable`: "Plan unavailable. Connect this Mac to Atum Work.")
- `…relay.chipGreyed.unavailable` ("{plan} unavailable")
- `…relay.fixConnect` (desktop `fix.connect`: "Connect"; the phone has
  `AccountConnectionsCopy.connect` meanwhile)

## Verification

- `swift test --filter 'PhoneWorkPickerFaceTests|PhoneWorkSelectionTests|PhoneModelPickerProjectionTests|PhoneModelPickerSectionsTests'`
  (unlocked): 81 tests, 0 failures, exit 0; the 6 new tests pass alone.
- `python3 scripts/design_lint.py`: OK, exit 0.
- Locked run (queued, results in `/Volumes/AtumTestFlight/w4-y2/`):
  `locked-run.sh` builds Debug for testing, runs `PhoneModelPickerCopyTests`,
  `PhoneModelPickerWorkUITests` in light, dark and AX-XL with screenshots of
  the chip, card and picker, and the W4-X2 hand-off UI test. The app target
  is compiled only there; see `run.log` for its outcome.

New UI tests (`ios/UITests/PhoneModelPickerWorkUITests.swift`, scripted
flag `-AtumScriptedWork claude:claude-opus-5-5`):

- chip names "Claude Opus 5.5", the picker checks it, opening writes nothing,
  a Work pick writes only Work and the chip follows;
- an explicit Atum pick is the only write that clears Work;
- the card's Model row names the Work model without writing.

## Known gaps and follow-ups

- If `work_selection_read` is unavailable (migration 0552 or the Shell
  rollout missing), the phone cannot know a Work model answers and keeps the
  cloud name. The read failure is not surfaced as its own status line.
- No relay greyed or limit chip warning (desktop `relayChip`): the phone has
  no relay status facts yet; see the copy keys above.
- The Work rows sit outside the favourites and the connection filter; a
  favourites or connection filter hides them. Search matches them.
