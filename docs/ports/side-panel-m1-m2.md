# Phone side panel M1 + M2

Owner request (2026-11-10): port the in-flight phone panel container and
person/group info onto current public main; local commits only.
State: scoped source port committed and package-verified locally. Not live.

The existing design importer pins the public desktop producer at
`63e122d3a22fc6fdef252cf90e5a4a2e201b1e65`. Its manifest and all five
locales supply the person-info and block/unblock copy needed by this slice.
No vendored resources were edited manually. Verification: immutable import,
8 importer tests, push fixture check and 2 push projection tests passed.

## Scope and relevance

Public main `a5f474fb7bd24bf440ba40c1f6b449704f79cff4` already includes the
chat-basics, group-limit and company changes. It has no panel container,
moderation policy or low-priority projection. Apply only the client source
and test diff; retain the newer member-profile and synchronized roster paths
when adapting the session hunks. Reuse the existing design importer, Matrix
SDK, room mutation queue and roster projection. No new endpoint or dependency.
The introduced team and user fixture labels are synthetic. No private plans,
lockfile, vendored resources, history or commit metadata are transplanted.

The container opens from the title or more button, scopes itself to one
account/room, hosts navigation and uses a sheet with medium/large phone
detents. The iPad inspector column remains deferred. Person/group info shows conversation facts, shared Team Spaces,
pin/mute/low-priority controls and block/unblock. Group Members exposes
power-level-gated kick, ban and unban. SDK-backed details are read on opening.
Shared-content and app-page implementations remain outside this slice.

## Changed files

Design import: `atum-design.lock`, and `ios/Vendor/AtumDesign/` files
`Localizable.xcstrings`, `copy-contract.json`, `copy-inventory.json`, `manifest.json`.

Client wiring:
- `ios/App/AppRoot.swift`
- `ios/App/Chat/Views/ChatInfoSheet.swift`
- `ios/App/Chat/Views/ChatPanelHost.swift`
- `ios/App/Chat/Views/ChatScreen.swift`
- `ios/App/Chat/Views/ScriptedChatHost.swift`
- `ios/App/Company/CompanyWorkspaceModel.swift`
- `ios/App/LiveAppModel.swift`
- `ios/App/LiveMatrixSession.swift`
- `ios/App/LiveRosterRows.swift`
- `ios/App/Product/LiveProductModels.swift`
- `ios/AtumMobile.xcodeproj/project.pbxproj`

Pure policies and tests:
- `ios/Sources/AtumChat/ChatMemberModeration.swift`
- `ios/Sources/AtumChat/ChatPanelPolicy.swift`
- `ios/Sources/AtumChat/RosterProjection.swift`
- `ios/Tests/AtumChat/ChatPanelPolicyTests.swift`
- `ios/Tests/SidePanelCopyTests.swift`
- `ios/UITests/ChatInfoUITests.swift`
- `ios/UITests/ChatPanelUITests.swift`

This note is the remaining changed file.

## Verification limits and next steps

Native adapters/SwiftUI and UI tests are not compiled or run by the Swift
package. Native app build and simulator/device validation remain outstanding,
including sheet presentation on iPhone/iPad; no UI readiness is claimed.
No push, pull request, CI, deployment or spending is authorized in this port.

Supplemental broad Python discovery: 66 tests; 2 failures, 29 errors, 7 skips.
These concern unchanged icon assertions and tests depending on excluded scripts
or contracts. An archived public-main baseline reproduces them (and adds one
failure and one error because it lacks checkout-local Git/source cache state).
Keep these outside the scoped port. Focused public-client checks are the gate.

The current source includes the later sheet presentation and accessibility
fixes: avoid an inspector inside the chat NavigationStack and avoid applying
`.id` to its panel NavigationStack. An unrelated account-settings title
snapshot update is excluded because its wording is outside this design pin.

## Final focused verification

Mac mini, Swift 6.4 / Node 24:
- npm ci --ignore-scripts and npm test: both public Megolm vectors passed.
- Immutable D2 design import verified; 8 importer tests passed.
- Push fixture byte check passed; 2 push projection tests passed.
- 3 source copy-key checks passed.
- swift package dump-package and resolve passed; native project plutil passed.
- swift test --package-path ios --build-system native -j 2, with a unique
  temporary scratch path: 1,144 tests passed, zero failures. Includes 8 panel,
  moderation and low-priority policy tests and 3 new copy-contract tests.
- First attempt with Swift 6.4's default swiftbuild backend compiled but failed
  in its test-bundle CodeSign step (internal Code Signing subsystem error).
  The native backend retry passed without changing package/build settings.
- Successful remote source/build scratch: 409 MiB; removed and absence verified.

Local syntax parsing passed for all 17 changed Swift files. Later source-only
presentation fixes do not alter any package source; their syntax and copy keys
were rechecked locally. The temporary public desktop clone was deleted.
Outbound preflight against the public base passed for both local commits with
no path, ancestry, identifier, secret or metadata findings; policy unchanged.
