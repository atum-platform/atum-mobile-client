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
- W4-T's final chip settlement and plan warnings use that same shared account state. Its optional
  pick callback follows the returned choice when a write replay names a different model.
- Subscription rows need a ready destination read to be writable. Both pickers can project
  successful account catalogs with a missing destination snapshot. When a refresh fails over a
  previously held snapshot, the saved choice can still identify a row, with writes disabled.

## UI handoff

W4-X2 should pass `chatGPTState`, `openCodeGoState`, `accountConnectionsState` and
`destinationReadState` to the list. Show each provider's settled copy and Retry for failed reads
alongside any visible catalogs. Use the existing pinned loading, failure, unavailable and reconnect
copy. `Row.selected` drives Current and `Row.selectable` gates model actions. A destination
failure leaves successful plan catalogs visible and read-only.

`PhoneSubscriptionAccount.workPlanHandoffs` supplies read-only model groups keyed by `AccountPlan`,
with `.openOnMac` as the hand-off reason. The registry supplies the model names and keeps the
native plan identity, including when two plans report the same model ID. Use the existing Work
copy for the hand-off and the registry's read state for loading or failed copy. When ChatGPT's cloud
relay already supplies the catalog, use that catalog once. Existing Connect entries still cover
disconnected plans and plans that need attention.

The ChatGPT training confirmation covers the existing cloud ChatGPT pick. Native Work consent
requires its own plan-scoped agent and Mac grant or renewal through the native Work flow.

## Fix round 2

- Matched desktop #126's Current behavior. Both cloud plan reads keep the saved row name on failure.
  The row is Current only when a successful plan catalog contains it and the destination has
  successfully read back. OpenCode Go preserves its failed-read reason.
- The reply and timeout settle a single stream. A queued reply can win without a later clock check
  on the main actor. A controlled-clock regression advances the clock before the queued reply resumes.
- A retired picker load token cannot publish over a newer load. A retired account or assistant
  scope settles a still-owned destination load as unavailable and discards its stale snapshot.
- The live destination reader issues the destination request alone. Both pickers load the bounded
  1.1 offer alongside the destination and publish each as it answers. The card's Atum eligibility
  follows the offer. Subscription writes can use a ready destination while the offer is pending.
- Derived Mac hand-off groups from the existing Connections registry for W4-X2. The SwiftUI list
  treatment and native Work grant or renewal UI are W4-X2 work.
- Integrated W4-T at `3d3759e` before the locked verification.

## Verification

The locked verification runs the subscription, picker state and preferences, projection and sections
suites, the arm64 Debug simulator build, and the simulator-hosted picker copy suite. The
subscription suite covers partial publication, timeout,
per-source errors, read-only catalogs without destination readback, account changes, picker
retirement, a stalled offer, native hand-off rows and Connect-sheet landings. The deadline tests use
controlled reply and timer continuations, including replies that can finish after cancellation.

Round 2 passed on the assembled code at `bde82ab`. The locked run passed 101 SwiftPM tests,
the arm64 Debug simulator build and all 10 picker copy tests. The separate public guard exited 0
against `origin/main`. The logs are in `/Volumes/AtumTestFlight/w4-x1/r2-*.log`.

## Follow-ups

- Wire provider-level settled presentation and any destination retry affordance over the still-visible
  catalog in the UI lane.
- Work picker parity still depends on an owner-authorized assistant selection readback with a
  revision, as documented in [W4-Q](w4-q-picker-data.md). Provider-scoped Work reads can use the
  existing owner contract where supported. Any additional provider scope requires a platform
  contract before the phone can use it.
