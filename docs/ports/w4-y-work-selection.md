# W4-Y1 native Work model selection

The iPhone uses the owner bearer on `POST /api/matrix/v1/device-services` for
Work picks. `work_selection_read` returns the assistant's Work selection and
the revision from `matrix_model_choices`. Revision zero with a null selection
represents a missing row. A cleared choice can have a nonzero revision.
`work_selection_set` sends that Work revision and returns the saved plan,
model and revision. The decoder validates required fields and tolerates
additive metadata. [Platform #948](https://github.com/atum-platform/atum-platform/pull/948)

Phone eligibility follows the connected plan catalogs in W4-Q and the same
offline behavior as desktop. The existing `account_connections_read` loads
the Work subscription facts into `PhoneModelPickerAccount`. Its
`workPlanHandoffs` keeps last-seen connected Macs and excludes signed-out
plans, plans that need attention and the Codex duplicate when the legacy
ChatGPT relay is enabled. The server checks ownership, plan eligibility and
revision on every write. [W4-Q](w4-q-picker-data.md#connected-plans-and-the-missing-owner-read) ·
[Desktop #131](https://github.com/atum-platform/atum-desktop/pull/131) ·
[Desktop #139](https://github.com/atum-platform/atum-desktop/pull/139)

## Picker contract

- Create one `PhoneModelPickerWorkSelection` for the opened picker from
  `AssistantModelDestinationActions.makeWorkSelection`, passing the existing
  `PhoneModelPickerAccount`. The factory binds it to the assistant principal,
  account generation and domain client. The app retires registered pickers
  on account-scope changes and client replacement. Keep the instance in picker
  state and call `retire()` on close or assistant change.
- Start `reload(within:)` alongside the other picker reads. Its budget uses
  the same per-source deadline as the W4-X account reads. Observe `value`
  for `readState`, `snapshot` (selection and revision), and `saveState`.
  `readySnapshot` supplies Current. A cached snapshot can name the model
  during refresh or after a failure. A retired scope exposes no value.
- Render the picker's `rows` for model names, plan/model identity, `selected`
  and `selectable`. Both the rows and write dispatch use the same observed
  catalog, including updates when Connect lands. A saved model absent from
  the catalog includes the plan name in its label. No separate eligibility
  read or UI-side eligibility sync is required.
- Invoke `save(row.id)` for an eligible pick. It reads first when there is no
  ready revision. A 409 rereads and retries at most once when the revision
  advances and the pick is still live and eligible. If readback already matches
  the pick it settles without another write. A second 409 reads the winner
  and settles without another retry. If the write response fails, keep the
  last saved name, clear Current and require a fresh revision before sending
  the next write. A newer pick supersedes pending replies and retries.
  Observe `.saving(choice)`, `.failed(.conflict)` and `.failed(.other)`.
  Use the returned choice for Current after settlement.

Cloud subscriptions continue to use the model-destinations revision. Live
Work readback requires migration 0552, applied after 0551, and the Shell
rollout of `work_selection_read`. W4-Y2 owns integrating these actions
into the picker view.

## Verification

The initial shared-lock Swift package run passed 821 tests, including 13
Work selection fixtures. The arm64 Debug simulator build-for-testing passed.

Review round 2 started from `ac1af9b` on a separate local branch because
the feature branch was already checked out. The base already contained
`origin/main`. The regression tests cover a successful Work save from a
last-seen catalog, catalog replacement during authorization, observable
retirement, the saved plan label and a fresh revision following an
ambiguous write failure.

Design lint passed with its existing baseline and all 10 lint unit tests
passed. `git diff --check` passed. No local UI tests ran.
