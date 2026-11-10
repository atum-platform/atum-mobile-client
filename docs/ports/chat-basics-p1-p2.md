# Phone chat basics

Invitations retain their room identity, kind and SDK avatar even when profiles are missing. Native audio/video and voice metadata survive generic file metadata; locations retain a readable body or coordinates. People discovery uses the existing authenticated SDK directory and profile reads. Direct conversations reuse eligible joined rooms using SDK membership independently of `m.direct`, and creation outcomes are retained per target for the session.

The implementation extends the current SDK adapters, roster mapping and pure chat policies. No parallel transport, new dependency, model tool, resource export or producer pin was added. Test fixtures use neutral synthetic identities.

Local validation passed all public client commands: Megolm vectors, design verification, eight importer tests, push fixture verification, two push projection tests, package parse/resolve and native project parse. All 504 Swift package tests passed, including native media fallback, projection/decryption stability and direct-room eligibility contracts. The native app invitation test is included but is outside Swift package execution. Simulator/device and live-account acceptance remain separate.

State: implemented and verified locally; publication remains pending.

Changed implementation and test files:

- `ios/App/AppRoot.swift`
- `ios/App/Chat/Media/MediaRows.swift`
- `ios/App/Chat/SDK/ItemMapper.swift`
- `ios/App/Chat/SDK/SDKValueMapping.swift`
- `ios/App/Chat/Views/MessageMenu.swift`
- `ios/App/Home/HomeScreen.swift`
- `ios/App/LiveAppModel.swift`
- `ios/App/LiveMatrixSession.swift`
- `ios/App/LiveRosterRows.swift`
- `ios/AppTests/S2StateTests.swift`
- `ios/Sources/AtumChat/ChatItem.swift`
- `ios/Sources/AtumChat/ContentRules.swift`
- `ios/Sources/AtumNativeAPI/MobileDirectRoomPolicy.swift`
- `ios/Tests/AtumChat/ContentRulesTests.swift`
- `ios/Tests/AtumChat/ProjectionTests.swift`
- `ios/Tests/MobileDirectRoomPolicyTests.swift`
