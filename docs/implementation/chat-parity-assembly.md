# Phone chat parity assembly — 2026-11-27

Status: partly built, not live. This branch assembles notification, search/filter and trust engines from the clean main baseline. Presentation and installed-client acceptance remain open. Threads/pins precede message actions.

- Notifications: native room-mode writes and observation, quieter Team Space policy and legacy preference conversion. See `../ports/chat-parity-notifications.md`.
- Search: plain-room server search, device-only query isolation and pinned SDK local index adapter, unread/favourites policy. See `chat-parity-phone-search.md`.
- Trust: SAS and existing-identity recovery engines, gated private creation. Fresh phone-only bootstrap is unresolved; the proposed safe native route must be exercised before any SDK capability conclusion. See `chat-parity-ml5-trust.md`.

The engine changes merged without conflicts. XcodeGen regenerated the shared project to register app and test sources. Public guard passed for the first notification/search assembly. The combined focused Swift test attempt timed out acquiring the shared build lock; it executed no tests. Parsing and source/export inspection reported by individual lanes do not establish SDK linking or executable behavior. Debug compilation, runtime probes, UI integration, privacy traffic checks and cross-client acceptance remain required.

At the combined ML1/ML2/ML3/ML5 checkpoint, the package build completed with indexing disabled and 45 selected XCTest cases passed (25 native API/recovery policy cases and 20 chat cases). Command: `swift test --package-path ios --scratch-path <build-volume>/chat-parity-assembled/scratch -j 2 --disable-index-store --filter 'GlobalChatSearchTests|ChatRoomListFilterTests|PersonalMessageSearchTests|ChatNotificationSettingsTests|ThreadMenuTests|CompanyThreadsPolicyTests|MobileDirectRoomPolicyTests|MatrixRecoveryTests|RecoveryOfferTests'`, under the shared lock. This supersedes the earlier lock timeout for these package tests only. App-level Rust adapters and `AppTests` are outside that package test build and remain unverified. The combined public guard passed. The notification UI pass is underway separately.

All heavy checks use the shared build lock and lane-specific derived data, package checkout and scratch directories on the build volume. The coordinator owns final verification, review and shipping. No UI or production readiness is claimed by this checkpoint.

Notification UI integration: 23 focused tests passed (12 menu state, 6 settings and 5 copy-contract tests), using the shared lock and existing no-index Swift scratch directory. Design lint and diff checks passed. The presentation-generation correction is app-source code and awaits Xcode compilation. The assembled Debug build uses the verified matching shared package cache under the same exclusive lock, with automatic resolution disabled and a unique assembly derived-data directory. Build result and installed notification acceptance remain pending.

Debug integration correction: the generic simulator build requested unsupported x86_64; the selected artifact contains arm64 device and simulator slices. The arm64 build then reached app compilation and found a private-DM reuse read using nonexistent RoomInfo.isEncrypted. It now uses the existing adapter for RoomInfo.encryptionState, retaining unknown-state refusal. SDK pin unchanged; arm64 Debug verification rerun required.

The next Debug pass exposed notification/handles initializer argument order in live and scripted chat hosts; both call sites now match ChatInfoActions declaration order.

The encryption-state conversion helper was nested in the roster reader, not LiveMatrixSession. The private-DM path now switches directly over encrypted/notEncrypted/unknown, preserving refusal on unknown. This corrects the preceding coordinator fix.

Debug integration: the main-actor pin reader now receives the first SDK timeline update directly through its AsyncStream iterator. This avoids passing a main-actor predicate to the concurrent first(where:) API under Swift 6, without weakening isolation or changing snapshot semantics.

The complete arm64 iOS Simulator Debug build succeeded at f90e4ed with the selected Rust artifact unchanged. This verifies compiled app adapters and notification UI linking. It does not establish runtime SDK behavior or installed acceptance. Focused LocalSearchSDKTests and MatrixSecurityTests are now queued on one existing simulator under the same lock, with automatic shutdown on exit.

Focused app SDK tests compiled but failed linking because AtumMobileTests imported MatrixRustSDK without declaring a direct package dependency. Added that dependency in project.yml and regenerated the project. No runtime test executed in the first attempt; rerun uses a fresh result bundle.

Focused app SDK tests r3 (`LocalSearchSDKTests` + `MatrixSecurityTests`): 11/11 passed on the arm64 simulator under the shared build lock. The r2 failure (`testPrivateRoomRecipeAndParticipantEvidence`, "invalidValue") was a fixture bug: the test decoded `AliasLookupResponse` with a plain `JSONDecoder`, but the strict `WireInteger` field only decodes through `NativeAPI.decode`, which attaches the raw JSON. The fixture now uses `NativeAPI.decode`, matching `HomeChatsWave3StateTests`. No app code changed.
