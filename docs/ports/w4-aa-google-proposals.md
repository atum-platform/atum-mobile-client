# W4-AA Google write proposal transport

Atum for iPhone reads the owner’s pending Google write proposals from Shell. The feed includes proposals from an assistant’s Matrix conversation and proposals from Work. It carries no new credential type. The desktop reference is `6bd26341` and the Shell contract is in `apps/shell/src/lib/google-proposals.ts` at platform `ea06ef82072`.

Sharing one owner feed gives both phone surfaces the same approval contract and lets one refresh reconcile a decision across both.

## Wire contract

- `GET /api/connections/google/proposals` returns a mixed list. A Work entry has `source: "work"` and null `agent` and `room`. An assistant entry carries its agent and room identifiers.
- `POST /api/connections/google/proposals/{proposalId}/{approve|decline}` sends exactly `{"digest": "..."}`. Both routes use the existing native domain bearer and host bridge header. The client retries one 401 after refreshing the bearer, with an owner-session check before each dispatch and after each answer.
- The decoder skips malformed entries independently and retains unknown kinds as unsupported. Unknown envelope and proposal fields are ignored. The phone hashes the typed draft using the platform’s canonical JSON rules. A future field covered by Shell’s draft digest keeps the card visible with decisions disabled.
- An acceptance needs HTTP 200 and a matching proposal ID, digest and action status. `confirmed` records assistant approval for the assistant to carry out. For Work, Shell handles the operation and its provider outcome goes back to Work. Acknowledgement is the only success signal presented by the phone store.
- Shell replies with a generic refusal for stale or foreign proposals. The store maps a refusal to closed for an assistant and expired for Work, following desktop. A local digest mismatch or a mismatched receipt digest is changed. An unavailable answer is retryable while the card remains listed. If a successful list loses a proposal, the store settles it as superseded when its source slot has a replacement, closed for a disappearing assistant proposal, or expired for a disappearing Work proposal.

## UI seam

`LiveAppModel.googleWriteProposals` is a main-actor observable `GoogleWriteProposalStore`. The model binds it to the current owner and domain client, clears it on sign-out or session invalidation, and supplies app focus and foreground changes. Preview data stays in memory and clears when the binding changes.

- Read `cards(for: .assistant(roomID:))` in an assistant conversation and `cards(for: .work)` in Work. Each projection carries the source, kind, typed preview lines, mailbox operation where applicable, state and `canDecide`. The preview values are plain text, timestamp strings, addresses or typed metadata. The UI supplies all display words, the time-zone presentation and attachment-size formatting from the desktop copy export under `src.matrix.google-write-card-copy.copies.*`.
- On surface appearance and disappearance, call `setVisible(_:for:session:)` with the store session captured for that presentation. Register again when `store.session` changes. A single foreground poll serves all registered surfaces every five seconds. A new visible surface and focus return also refresh the list. A failed read leaves the last projection in place.
- Call `hintAssistantMessage(roomID:session:)` for new Matrix message activity in a registered assistant room. The event serves as a refresh hint. Shell supplies the proposal and its preview.
- Call `await decide(_:cardID:)` with the ID captured from the displayed card. The session-scoped ID fences stale views. Both actions stay disabled while a decision for that owner and proposal is in flight, even across client replacement. The store preserves a matching acceptance across list refreshes and refreshes after each decision. Consumers can also call `await refresh()` explicitly.

## Open questions

- Assistant typed approval on desktop uses a separate delivery acknowledgement after the verified card has been visible for one focused second. The phone slice exposes explicit approve and decline. A future presentation lane can decide whether the phone should also support typed approval and own that delivery timing.
- A successful pending list carries no expiry reason or exact deadline. The Work expired state can include a decision taken on another device. A status contract from Shell would be needed to distinguish those outcomes.
- The copy export and Matrix event registration belong to the presentation lanes. Live Shell deployment and owner Google writes require separate integration verification.

## Verification

- The Swift package suite passed 1,962 tests, including 14 covering the proposal decoder, digest and previews, method and path allowlist, bearer refresh, receipts, refresh triggers, session fencing and decision outcomes.
- Repository design lint and its 10 tests passed. Swift syntax parsing of the app model and the Xcode project plist check passed.
- The shared build lock remained occupied, so the Debug simulator build remains unverified. The locked build uses a dedicated DerivedData directory.
