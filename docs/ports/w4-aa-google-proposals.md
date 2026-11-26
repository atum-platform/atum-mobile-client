# W4-AA Google write proposal transport

Atum for iPhone reads the owner’s pending Google write proposals from Shell. The feed includes proposals from an assistant’s Matrix conversation and proposals from Work. It carries no new credential type. The desktop reference is `6bd26341` and the Shell contract is in `apps/shell/src/lib/google-proposals.ts` at platform `ea06ef82072`.

Sharing one owner feed gives both phone surfaces the same approval contract and lets one refresh reconcile a decision across both.

## Wire contract

- `GET /api/connections/google/proposals` returns a mixed list. A Work entry has `source: "work"` and null `agent` and `room`. An assistant entry carries its agent and room identifiers.
- `POST /api/connections/google/proposals/{proposalId}/{approve|decline}` sends exactly `{"digest": "..."}`. Both routes use the existing native domain bearer and host bridge header. The client retries one 401 after refreshing the bearer, with an owner-session check before each dispatch and after each answer.
- The decoder skips malformed entries independently and retains unknown kinds as unsupported. Unknown envelope and proposal fields are ignored. The phone hashes the typed draft using the platform’s canonical JSON rules. A future field covered by Shell’s draft digest keeps the card visible with decisions disabled.
- An acceptance needs HTTP 200 and a matching proposal ID, digest and action status. `confirmed` records assistant approval for the assistant to carry out. For Work, Shell handles the operation and its provider outcome goes back to Work. Acknowledgement is the only success signal presented by the phone store.
- Shell replies with a generic refusal for stale or foreign proposals. The store maps a refusal to closed for an assistant and expired for Work, following desktop. A local digest mismatch or a mismatched receipt digest is changed. If a successful list loses a proposal, the store settles it as superseded when its source slot has a replacement, closed for a disappearing assistant proposal, or expired for a disappearing Work proposal.

## R2 review fixes

- Calendar preview lines carry the destination `sourceId` and, for updates, the event ID. A missing location or description has no line, an empty string produces a typed `cleared` line, and a nonempty string produces a value line. This follows Shell's Calendar PATCH, which sends an explicit empty string to Google. Mail and draft previews preserve empty recipients, attachments and text. A Gmail compose preview is the final message, so omitted CC and BCC from Shell mean no recipients in those fields. Draft, mailbox and label previews carry their source, and draft and mailbox changes carry their target IDs. Mailbox label operations require a populated label list, and label creation requires a name on Shell.
- The store owns the decision task across caller cancellation and scene transitions. The POST timeout is 135 seconds for Shell's 120-second Work approval route. A dispatch that loses its response or receives an ambiguous response leaves the card in `reconciling`. A successful list can settle a disappeared, replaced or changed proposal. If the same approval is still listed, retry requires a successful read started at least 120 seconds after the ambiguous result, since Shell could have started processing just before the client lost the response. Failed reads keep decisions disabled. The owner/proposal guard survives client replacement.
- While the POST is active, the store records the latest successful list evidence for the original card and keeps both actions disabled. A matching receipt settles the action. An unavailable or ambiguous result applies any retained list evidence of a stale card before retry controls can return, including when the post-decision read fails.

## UI seam

`LiveAppModel.googleWriteProposals` is a main-actor observable `GoogleWriteProposalStore`. The model binds it to the current owner and domain client, clears it on sign-out or session invalidation, and supplies app focus and foreground changes. Preview data stays in memory and clears when the binding changes.

- Read `cards(for: .assistant(roomID:))` in an assistant conversation and `cards(for: .work)` in Work. Each projection carries the source, kind, typed preview lines, mailbox operation where applicable, state and `canDecide`. The preview values are plain text, timestamp strings, addresses or typed metadata. The UI supplies all display words, the time-zone presentation and attachment-size formatting from the desktop copy export under `src.matrix.google-write-card-copy.copies.*`.
- On surface appearance and disappearance, call `setVisible(_:for:session:)` with the store session captured for that presentation. Register again when `store.session` changes. A single foreground poll serves all registered surfaces every five seconds. A new visible surface and focus return also refresh the list. A failed read leaves the last projection in place.
- Call `hintAssistantMessage(roomID:session:)` for new Matrix message activity in a registered assistant room. The event serves as a refresh hint. Shell supplies the proposal and its preview.
- Call `await decide(_:cardID:)` with the ID captured from the displayed card. The session-scoped ID fences stale views. Render action availability from `canDecide`, including while the card is deciding or reconciling. The store refreshes after each decision. Consumers can also call `await refresh()` explicitly.

## Open questions

- Assistant typed approval on desktop uses a separate delivery acknowledgement after the verified card has been visible for one focused second. The phone slice exposes explicit approve and decline. A future presentation lane can decide whether the phone should also support typed approval and own that delivery timing.
- A successful pending list carries no expiry reason or exact deadline. The Work expired state can include a decision taken on another device. A status contract from Shell would be needed to distinguish those outcomes.
- The copy export and Matrix event registration belong to the presentation lanes. Live Shell deployment and owner Google writes require separate integration verification.

## Verification

- The R2 Swift package suite passed 1,970 tests, including 22 covering proposal decoding, previews, bearer-authenticated requests, receipts and store reconciliation.
- Repository design lint and its 10 tests passed.
