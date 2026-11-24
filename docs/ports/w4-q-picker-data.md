# W4-Q phone model picker data parity

The baselines were mobile `0521e76`, desktop #119 at `2365efe8bdb0`, and platform `origin/main` at `67da5642382e`. Platform references below use that Git revision because the local platform checkout predates migration 0540.

## Thinking

- Adopted the level order, labels and aliases from desktop `apps/desktop/src/matrix/model-picker-labels.json:11–37`. The phone continues to derive Thinking from the selected model's ready 1.1 offer in `ios/Sources/AtumNativeAPI/PhoneModelPickerProjection.swift:335`. Labels normalize `off`, `extra-high`, `extra_high` and `maximum`. Managed writes use the exact token the offer advertised.
- `ios/Sources/AtumNativeAPI/ModelChoice.swift:151` and `ios/Sources/AtumNativeAPI/SubscriptionAccount.swift:35` preserve the snapshot and its catalog when an unknown effort appears. A future saved level leaves Thinking unselected. The picker offers the known levels the current model advertises. A 1.1 model pick uses the known default or the first recognized level if the default is unknown. In the offer-backed conversation picker, an offer with only unknown levels stays visible and read-only.
- The assistant home's cloud picker checks the same advertised options against its own write contract. Its row projection and save use the same choice builder in `ios/Sources/AtumNativeAPI/AgentHomeCatalog.swift:238–266`.
- The four missing names use guarded pending copy for all five locales in `ios/App/Chat/Views/PhoneModelPickerCopy.swift:101`. The existing export provides help text for low, medium and high. **W4-C6 / desktop export** owns adding `COPY.efforts.none`, `.minimal`, `.xhigh` and `.max` to the mobile export. The mobile pin owner can retire the four pending entries after repinning.
- The existing 1.4 OpenCode Go and 1.5 ChatGPT subscription writes still accept low, medium and high per platform `supabase/migrations/0335_provider_connections.sql:758–765` and `0336_chatgpt_relay.sql:420–424`. The checked-in 1.1 Atum writer also currently limits its live catalog writes to those levels (`0226_managed_model_authority_provider.sql:136–142,271–278`). **Platform model authority** owns widening those server contracts when those routes begin serving additional levels.

## Claude plan identity

- The phone uses `claude-plan` for picker identity (`ios/Sources/AtumNativeAPI/AccountConnections.swift:31–52`), matching desktop `apps/desktop/src/app/connections/view.ts:135–143`. Registry decoding resolves both spellings to the same plan. Phone Settings and the Work route retain the registry and wire ID `claude` per platform `supabase/migrations/0540_work_relay_plans.sql:1,54–64,153–156`. Desktop sends the same wire ID in `apps/desktop/electron/work/surface/relay.ts:78–83`.

## Connected plans and the missing owner read

- The phone already reads owner-scoped `POST /api/matrix/v1/device-services` with `{"operation":"account_connections_read"}` (`ios/Sources/AtumNativeAPI/NativeDomainClient.swift:1198–1215`). Shell dispatches that read in platform `apps/shell/src/lib/device-services.ts:125–132` and `apps/shell/src/lib/work-route.ts:172–176`. The registry provides plan model names and Mac connection facts. The projection uses it for Connect entries.
- Shell also exposes `work_subscription_read` on that owner route. It accepts `{"operation":"work_subscription_read","provider":"claude"}` or `"antigravity"` and returns `{issuedAt,consent,facts}`, including model catalogs when a provider is explicit (`work-route.ts:188–195`, migration 0540:121–136). Connection is the platform's automatic Work authorization for eligible assistants with the Mac's assistant switch on (0540:44–51). The phone requires no new consent prompt.
- The owner write is `{"operation":"work_selection_set","agentPrincipal":"…","expectedRevision":7,"selection":{"provider":"atum-work","plan":"claude","model":"…"}}`. It uses the `matrix_model_choices` revision and returns `{provider,plan,model,revision}` (`work-route.ts:102–106`, 0540:139–184). The 1.1 owner offer carries that revision with an Atum-only choice (`0242_managed_model_lineup_policy.sql:108–119`). The phone's `model-destinations` snapshot uses a separate destination-wide revision and currently overlays the legacy ChatGPT choice (`0249_model_destination_choice.sql:47–50,90–100,148–149`, `0336_chatgpt_relay.sql:385–400`).
- **Platform Shell / Work relay** owns the missing owner-authorized readback. Expose the owned assistant's current Work selection and the exact write revision, including when the selection is empty. One compatible shape would be `POST /api/matrix/v1/device-services` with `{"operation":"work_selection_read","agentPrincipal":"…"}` returning `{revision,selection:null|{provider:"atum-work",plan,model}}`. Today the host read requires a live agent credential (`0536_work_relay_contract.sql:87–95`) and Mac sync carries selections for the enrolled Mac's entitlements (0540:187–215). Desktop reads the latter from its local Work ledger (`apps/desktop/electron/work/surface/relay.ts:54–64`) and enables its assistant card path in `apps/desktop/src/matrix/model-picker.tsx:373–399`.
- Platform Shell / Work relay also owns making a switch to a legacy subscription retire the Work choice. The Work clear trigger runs on `matrix_model_choices` (`0536_work_relay_contract.sql:13–25`). The existing subscription writers use their own tables (`0335_provider_connections.sql:799–804`, `0336_chatgpt_relay.sql:439–441`). The phone needs one authoritative current choice across these writes before offering all plans together.
- **Mobile picker** owns enabling Claude and Antigravity after that owner readback lands, using `work_subscription_read` for availability and the existing `work_selection_set` for writes. The readback supplies the current row after reopening and the fresh revision after a conflict. For the phone's existing ChatGPT path, a saved choice now uses the pinned “Loading models…” during the account read and the pinned unavailable message if the legacy relay reports disabled (`ios/Sources/AtumNativeAPI/PhoneModelPickerProjection.swift:245–250`, `ios/App/Chat/Views/PhoneModelPickerCopy.swift:80–88`). OpenCode Go continues through the existing projection and route.

## Local verification

The batch uses `TMPDIR=/Volumes/AtumTestFlight/tmp lockf -k /Volumes/AtumTestFlight/.heavy-build.lock /bin/bash -c` to run both commands under the same lock.

The final batch passed all 218 focused Swift tests (exit 0) and built Debug for the iPhone 17 simulator with code signing disabled (exit 0). `lipo -archs` confirmed an arm64 app executable.

The first concrete iPhone 17 batch passed 206 Swift tests (exit 0). Its app build caught the assistant home call site's assumption that the default effort was always known (exit 65). The follow-up covers that picker and adds its contract tests to the filter.

```bash
swift test --package-path ios --jobs 2 \
  --scratch-path /Volumes/AtumTestFlight/dd-w4-q-swift \
  --filter 'AccountConnectionsTests|AgentHomeContractTests|ModelChoiceDestinationContractTests|NativeDomainClientTests|PhoneModelPickerProjectionTests|PhoneModelPickerSectionsTests|PhoneSubscriptionModelsTests'
xcodebuild -project ios/AtumMobile.xcodeproj -scheme AtumMobile -configuration Debug \
  -destination 'platform=iOS Simulator,id=939B69F8-DA11-4E01-ACB3-FD5B3DC2AF4C' \
  -jobs 2 -derivedDataPath /Volumes/AtumTestFlight/dd-w4-q \
  -clonedSourcePackagesDirPath /Volumes/AtumTestFlight/spm \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO build
```

`python3 -m unittest discover -s tests -p test_copy_keys_in_pin.py` passed all seven tests (exit 0). A direct comparison against desktop's JSON matched all 20 pending labels.

Earlier locked attempts used the same Swift command and the generic simulator destination. The first returned Swift exit 1 for a snapshot initializer capture, which was fixed, and Xcode exit 65. The second returned Swift exit 0 and Xcode exit 65. The generic destination tried to link an x86_64 slice absent from the pinned Matrix SDK. Adding `-arch arm64` to that destination returned Swift exit 0 and Xcode exit 70 because Xcode requires a destination to supply the architecture on its own.
