# Phone: switch a cloud assistant to a subscription model

The owner wants the phone to do what the desktop does: switch an assistant
or conversation to a model from a plan they already pay for and have
connected. Before this change the phone listed a saved subscription choice
read-only (`PhoneModelPickerProjection.subscriptions`, `selectable: false`).
An earlier audit called this desktop-only because "sign-in to a provider
plan lives on the Mac". That is true of the sign-in, not of the switch. The
desktop's switch for a cloud assistant is a plain platform write, and the
platform accepts it from the phone too.

References are atum-desktop `origin/main` 583ae946 and atum-platform
`origin/main` 40638a9e.

## What the desktop does

### 1. The request it sends

A cloud assistant's picker (`cloudSubscriptions = cloud && !macAnswers`,
`apps/desktop/src/matrix/model-picker.tsx:434`) lists two subscription
sources. The list is built from the account status
(`cloudSubscriptionRoutes`, `model-picker.tsx:792-845`):

- **ChatGPT plan** (`openai-codex`). Its models come from the ChatGPT relay
  status. They can be chosen only while `relay.state === 'enabled'`
  (`cloudChatGptConnected`, `model-picker.tsx:763`).
- **OpenCode Go.** Every model the connected account serves can be chosen
  (`model-picker.tsx:823-845`).

A pick (`chooseRoute`, `model-picker.tsx:1395-1452`) calls
`modelDestinations.writeSubscription(agentPrincipal, source, model, effort)`.
That call runs `matrixSubscriptionDestinationWrite`
(`apps/desktop/electron/matrix/model-destinations.ts:516-532`) and sends:

```
PUT /api/matrix/v1/agents/{agentPrincipal}/model-destinations
{ "profile": "atum.model-choice/1.5" (chatgpt_plan) | "atum.model-choice/1.4" (opencode_go),
  "requestId": <uuid>, "expectedRevision": <snapshot.revision>,
  "policyDigest": <snapshot.policyDigest>,
  "choice": { "destination": "cloud", "source": "chatgpt_plan" | "opencode_go",
              "model": <model id>, "effort": "low" | "medium" | "high" } }
```

The effort is the model's `defaultEffort` when its levels include it, else
its first level, else `medium` (`model-picker.tsx:1412-1415`).

The account status comes from two owner GETs that native main makes
(`main.ts:23226-23239`, `subscriptionsStatus`):

- `GET /api/matrix/v1/chatgpt-relay`, profile `atum.chatgpt-relay/1`
  (`chatgpt-relay-client.ts:62-66`)
- `GET /api/matrix/v1/provider-connections`, profile
  `atum.provider-connections/1` (`provider-connections.ts:250-256`)

### 2. Whether the cloud destination accepts it

It does. The platform's write schema allows a cloud `opencode_go` choice
and a cloud `chatgpt_plan` choice, both with Atum's three levels
(`packages/protocol/src/model-choice.ts:383-389`). A cloud ChatGPT choice
is accepted only under profile 1.5 (`relay_profile_required`,
`model-choice.ts:436-447`).

The handler is `managedModelAuthority`
(`apps/shell/src/lib/managed-model-authority.ts:121-133`). Its route gate is
the same for both native clients. `nativeTransport` is computed as
`ios | desktop` (`matrix-authority.ts:1826-1827`), but the gate for
`model-destinations`, `chatgpt-relay` and `provider-connections` never reads
it (`matrix-authority.ts:1930-1948`, `1957`, `2007`). It refuses only
browsers, cookies and `x-atum-principal`.

The checks happen in the database:

- ChatGPT (1.5): an `enabled` relay for the owner, else `not_connected`. The
  model must be one the relay serves, else `model_unavailable`. The effort
  must be one the model accepts, else `effort_unavailable`
  (`supabase/migrations/0336_chatgpt_relay.sql:403-447`, checks at 434-438).
- OpenCode Go (1.4): `not_connected` and `model_unavailable`
  (`0335_provider_connections.sql:783-790`).

HTTP status: model and effort refusals return 409
(`managed-model-authority.ts:54-56`). `not_connected` is not in that list,
so it falls through to 503 `unavailable` (`managed-model-authority.ts:62`).

Where the model runs:

- **OpenCode Go** runs entirely in the cloud, on the account's key held by
  the platform.
- **ChatGPT plan.** The cloud assistant's turn calls the model through the
  relay. One of the owner's Macs is signed in and enabled the relay, and
  that Mac serves the call (`model-picker.tsx:793`: "ChatGPT plan models
  are served by the selected owner Mac"). So switching to a ChatGPT model
  works from any device, but the model only answers while that Mac's relay
  is up.

### 3. What "not ready" means on desktop

`chatgptCloudNotReady` reads "Not ready for your assistants yet"
(`model-picker-copy.ts:137`; vi `:229` "Trợ lý của bạn chưa dùng được"). It
shows when this Mac holds a ChatGPT sign-in, or the account reads as
connected, but no relay is `enabled` (`cloudChatGptPending`,
`model-picker.tsx:767-771`). In other words, the plan is linked but no owner
Mac relays it to the cloud yet. Those models stay listed but disabled, with
that reason (`model-picker.tsx:816`). When the relay is up but no models
are known, the same words appear as a note instead
(`model-picker.tsx:863-865`). It has nothing to do with the phone.

## What the phone does now

The phone mirrors the desktop's cloud picker, in both the composer sheet and
the assistant card.

- **Reads.** `NativeDomainClient.chatGPTRelayStatus()` and
  `providerConnectionsStatus()` call the same two GETs. They decode the
  closed platform shapes strictly (`SubscriptionAccount.swift`). A route
  that fails to read becomes `nil`.
- **Rows** (`PhoneModelPickerProjection.subscriptions(_:destination:account:)`).
  ChatGPT comes first, then OpenCode Go, under "Subscriptions":
  - Relay `enabled`: one row per relayed model, by its display name. Every
    row can be chosen, and the saved one is current.
  - Relay `disabled` with a saved ChatGPT choice: that model stays listed,
    cannot be chosen, and is not current. Its line reads "ChatGPT plan ·
    *not ready*".
  - OpenCode Go `connected`: every served model can be chosen.
  - OpenCode Go `disconnected` with a saved OpenCode Go choice: that model is
    listed with "OpenCode Go plan · *This connection needs you to sign in
    again.*" (`modelsSignedOut`, from the pin).
  - Status unreadable: the saved model stays current and read-only, as
    before. The phone never guesses a state.
  - Nothing connected: no subscription rows. This matches the desktop's
    cloud list, which has no Connect rows.
- **Write.** `ManagedModelSubscriptionWrite` sends the exact desktop body
  (1.5 for ChatGPT, 1.4 for OpenCode Go, `destination: cloud`).
  `writeManagedModelSubscription` PUTs it to `model-destinations`.
  - Effort: the model's default level if it accepts it (or lists no levels,
    where the server accepts only its default), else its first level. This
    differs from the desktop only for a model with no levels and a
    non-medium default. There the desktop sends `medium` and the server
    refuses it, while the phone sends the default.
  - Fences: the same revision and policy fences as the Atum write.
  - Retries: an identical retry reuses its request ID.
  - Display: only the server's snapshot moves the check.
- **Failure.** A refused write shows the picker's existing pinned
  `modelPickerStatesSaveFailedText` line. A 409 adopts the latest snapshot,
  and the account status is read again, so a relay that went down turns its
  rows "not ready".
- **Thinking.** Atum's thinking control is hidden while a subscription
  answers. Before, changing it would have silently written an Atum model.
- **Mac destinations.** Not touched. A Mac's saved plan stays read-only.

### Copy

Every string comes from the pin (`atum-design.lock`, atum-desktop c14d74a1),
except one, listed under the missing keys below.

- In the pin and used: `subscriptions`, `planAccount`, `modelsSignedOut`,
  `switchProblem.unavailable`, and the state key `modelPickerStatesSaveFailedText`.
- Missing from the pin, and also missing from the desktop export at 583ae946
  (`packages/mobile-design-exports/dist/copy-contract.json`):
  - `src.matrix.model-picker-copy.COPY.chatgptCloudNotReady`. Until an
    export carries it, a not-ready row says the pinned
    `switchProblem.unavailable` ("Couldn't choose this model for this
    assistant right now.") instead. `PhoneModelPickerCopy.unavailable`
    switches to the real key as soon as the pin has it.
  - `src.matrix.model-picker-copy.COPY.switchRefused` ("Couldn't change the
    model."). The phone keeps its pinned save-failed line instead.
  - `src.matrix.model-picker-copy.COPY.chatgptSignedOut`. Not needed: it
    depends on a local ChatGPT sign-in, which a phone never has.

## Gaps (not phone-side)

1. **Claude and Gemini plans cannot run a cloud assistant, on any client.**
   The cloud destination accepts only `atum`, `opencode_go` and
   `chatgpt_plan` (`model-choice.ts:365-390`). `own_key:*` is
   Mac-destination only. The desktop has the same limit. A cloud Claude or
   Gemini subscription would need:
   - a new destination profile, `atum.model-choice/1.6`, allowing
     `{destination: "cloud", source: "claude_plan" | "gemini_plan", model,
     effort: low|medium|high}`;
   - a status route per provider that the phone and desktop can read. That
     is either a relay like `atum.chatgpt-relay/1` (`GET
     /api/matrix/v1/<provider>-relay` with `state` and `models[]` of
     `{id, displayName, efforts, defaultEffort, contextBudget,
     outputBudget}`), or a new row in `atum.provider-connections/1`;
   - the matching `matrix_model_destination_write` branch.
2. **Connecting a plan from the phone is out of scope.**
   - ChatGPT sign-in is a Mac-local browser sign-in, and the relay runs on
     that Mac, so the phone cannot connect ChatGPT by design.
   - OpenCode Go's `POST /api/matrix/v1/provider-connections/connect`
     (`atum.provider-connections/1`, API key) is open to iOS. A phone
     connect sheet is possible later, but it is a credential-entry surface,
     so it needs its own review.
   - Today the phone shows no Connect row. The desktop's cloud list has none
     either: its rail's "Connections…" opens the Mac sign-in.

## Files

- `ios/Sources/AtumNativeAPI/SubscriptionAccount.swift` (new): the two status
  decoders and `writeEffort`.
- `ios/Sources/AtumNativeAPI/ModelChoice.swift`: `ManagedModelSubscriptionWrite`.
- `ios/Sources/AtumNativeAPI/NativeDomainClient.swift`: the two reads and the write.
- `ios/Sources/AtumNativeAPI/PhoneModelPickerProjection.swift`: the rows,
  `Row.unavailable`, `Row.subscriptionEffort` and `canSelectSubscription`.
- `ios/App/Chat/Views/PhoneModelPicker.swift`: `AssistantSubscriptionActions`
  and subscription picks in both pickers.
- `ios/App/Chat/Views/PhoneModelPickerList.swift` and `PhoneModelPickerCopy.swift`:
  the row line and the copy.
- `ios/App/LiveAppModel.swift`: wiring.
- Shared with `feat/w3-assistants`, kept minimal:
  - `ChatInfoSheet.swift`: one optional property,
    `AssistantModelDestinationActions.subscriptions`.
  - `ScriptedChatHost.swift`: a flag-gated synthetic fixture,
    `-AtumScriptedSubscriptions ready|not-ready`. Without the flag, nothing
    changes.

## Tests added

- `ios/Tests/PhoneSubscriptionModelsTests.swift` (package):
  - the relay and provider-connection shapes, including refusals for a
    leaked credential or token, a wrong policy, an enabled relay with no
    models, and a disabled relay that names a Mac;
  - `writeEffort`;
  - the 1.5 and 1.4 write bodies, and refusal of an Atum source;
  - the rows: ready and current, not ready, signed out, nothing connected,
    unreadable status, and a Mac destination;
  - `canSelectSubscription`.
- `NativeDomainClientTests.testSubscriptionStatusReadsAndThePlanWriteUseTheDesktopRoutes`:
  the exact paths and methods, the bearer, and the 1.5 PUT body.
- `PhoneModelPickerProjectionTests`: the 1.4 read-only assertion now reads
  "without the account status".
- `PhoneModelPickerCopyTests.testAnUnavailableSubscriptionSaysWhyFromThePin`
  (AppTests).
- `ComposerUITests.testTheModelSheetListsTheAccountSubscriptions` (UITests).
  It runs with `-AtumScriptedSubscriptions` and writes captures to
  `.scratch/ui-evidence`. With `ATUM_SUBSCRIPTION_DEMO=ready`, picking
  "GPT-6.1 mini" must move the check.

## Verification

**Status: pending hosted CI.** The shared local build lock was queued behind
other sessions. The coordinator asked for this commit without a local
build, so:

- **Not run locally:** `swift test`, the app build, AppTests, UI tests and
  the simulator captures (before/after, vi, light/dark).
- **Run locally:** `swiftc -parse` (syntax only, no type checking) passes on
  every changed Swift file.

GitHub-hosted CI will verify this on the coordinator's PR: the swift package
tests, the App target build with AppTests, and the hosted UI shards. Before
and after captures are still to do. Use the UI test above with `before` =
main plus the same scripted 1.5 snapshot.

Things that may not compile and should be watched in CI:

- **`ScriptedChatHost.swift`.** It now passes `subscriptions:
  scriptedSubscriptions`, a computed property, into the large `ChatScreen`
  initializer expression. That expression was already big, so watch for
  type-checker slowness.
- **`LiveAppModel.readSubscriptionAccount`.** It runs two `async let`s on
  main-actor client calls, the same pattern as
  `readAssistantModelDestinations`.
- **The memberwise `AssistantModelDestinationActions` init.** It gains a
  trailing optional `subscriptions` argument. Existing call sites
  (`ScriptedChatHost`, `LiveAppModel`, tests) rely on its implicit `nil`
  default.
