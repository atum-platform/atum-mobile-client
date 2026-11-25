# W4-X1 picker read settlement

Desktop PR atum-desktop#126 at `8c32f43b` bounded the picker read to eight seconds in
`apps/desktop/src/app/work/use-relay.ts`. The Work adapter in
`apps/desktop/electron/work/surface/relay.ts` gave each plan read four seconds and kept account facts
when the room gate failed. See desktop `docs/agent-picker-plan-models-1125.md` for the original
failure and acceptance notes.

## Phone decisions

- Both picker entry points start the existing ChatGPT relay, OpenCode Go and account Connections
  reads in parallel with any needed model reads. Each account source publishes on completion and
  has a four-second deadline. The initial load shares an eight-second monotonic budget with the
  offer and destination reads. A refusal refresh starts a fresh budget.
- `PhoneSubscriptionAccount` exposes `chatGPTState`, `openCodeGoState` and `accountConnectionsState`.
  `loading` means that source is in progress. `ready` means a usable catalog or a decoded registry,
  including an empty registry. `unavailable` means a missing, disabled, disconnected or empty plan
  catalog. `failed` means the read threw or timed out. Disabled and disconnected payloads keep their
  existing row treatments. A source can reuse its catalog for display during refresh. Its rows
  regain write eligibility only when that source answers successfully.
- A timeout ends the picker wait and cancels the request. A transport that finishes after
  cancellation cannot publish. The picker generation rejects superseded loads and close-time
  replies. The live scope also checks the account generation, domain client and assistant principal.
  The composer shares the picker account state and can keep settled facts to name its saved model
  after the picker closes. A Connect-sheet landing supersedes only the in-flight registry result.
- Subscription rows need a ready destination read to be writable. Both pickers can project
  successful account catalogs with a missing destination snapshot. When a refresh fails over a
  previously held snapshot, the saved choice can still identify a row, with writes disabled.

## UI handoff

Use the source-specific states when rendering status for each provider. The existing saved ChatGPT
row already consumes `.loading`, `.failed` and the disabled relay's unavailable treatment through
the pinned model strings. Go keeps its pinned reconnect treatment. `destinationReadState` in each
picker owns write eligibility independently of the account catalog. Keep the catalog list visible
with that state at `.unavailable` or `.failed`, and use `Row.selectable` for model actions.

## Follow-ups

- Wire provider-level settled presentation and any destination retry affordance over the still-visible
  catalog in the UI lane.
- Work picker parity still depends on an owner-authorized assistant selection readback with a
  revision, as documented in [W4-Q](w4-q-picker-data.md). Provider-scoped Work reads can use the
  existing owner contract where supported. Any additional provider scope requires a platform
  contract before the phone can use it.
