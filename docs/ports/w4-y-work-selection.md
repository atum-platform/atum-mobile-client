# W4-Y1 native Work model selection

The iPhone uses the owner bearer on `POST /api/matrix/v1/device-services` for
the same Work selection operations as desktop atum-desktop#139. Platform
atum-platform#948 adds `work_selection_read`. It returns the assistant's Work
selection and the revision from `matrix_model_choices`. Revision zero with
a null selection represents a missing row. A cleared choice can have a
nonzero revision. `work_selection_set` sends that Work revision and returns
the saved plan, model and revision. The decoder validates required fields
and tolerates additive metadata.

## Picker contract

- Create one `PhoneModelPickerWorkSelection` for the opened picker from
  `AssistantModelDestinationActions.makeWorkSelection`. The live factory
  binds it to the assistant principal, account generation and domain client.
  Keep the instance in picker state and call `retire()` on close or assistant
  change.
- Start `reload(within:)` alongside the other picker reads. Its budget uses
  the same per-source deadline as the W4-X account reads. Observe `value`
  for `readState`, `snapshot` (selection and revision), and `saveState`.
  `readySnapshot` is authoritative for Current. A cached snapshot can name
  the model during refresh or after a failure. A retired scope exposes no value.
- `PhoneModelPickerProjection.workRows(reported:state:)` supplies the model
  name, plan/model identity, `selected` and `selectable`. It can show a saved
  model absent from the reported catalog. Reported models from Connections
  or Work subscription facts supply display names. Eligibility starts at
  `.unknown`. Use `setEligibility(.known(...))` only with a future authoritative
  allowlist scoped to this assistant and retire that eligibility if it goes stale.
- Invoke `save(row.id)` for an eligible pick. It reads first when there is no
  ready revision. A 409 rereads and retries at most once when the revision
  advances and the pick is still live and eligible. If readback already matches
  the pick it settles without another write. A second 409 reads the winner
  and settles without another retry. A newer pick supersedes pending replies
  and retries. Observe `.saving(choice)` or `.failed(.conflict)` /
  `.failed(.other)`. Use the returned choice for Current after settlement.

Cloud subscriptions continue to use the model-destinations revision. Model
selection on the phone requires a platform read for assistant-level Work
eligibility. Live Work readback also requires migration 0552, applied after
0551, and the Shell rollout of `work_selection_read`.

## Verification

The shared-lock Swift package run passed 821 tests, including 13 Work
selection fixtures. The arm64 Debug simulator build-for-testing passed.
