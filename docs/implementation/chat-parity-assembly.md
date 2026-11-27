# Phone chat parity assembly — 2026-11-27

Status: partly built, not live. This branch assembles notification, search/filter and trust engines from the clean main baseline. Presentation and installed-client acceptance remain open. Threads/pins precede message actions.

- Notifications: native room-mode writes and observation, quieter Team Space policy and legacy preference conversion. See `../ports/chat-parity-notifications.md`.
- Search: plain-room server search, device-only query isolation and pinned SDK local index adapter, unread/favourites policy. See `chat-parity-phone-search.md`.
- Trust: SAS and existing-identity recovery engines, gated private creation. Fresh phone-only bootstrap is unresolved; the proposed safe native route must be exercised before any SDK capability conclusion. See `chat-parity-ml5-trust.md`.

The engine changes merged without conflicts. XcodeGen regenerated the shared project to register app and test sources. Public guard passed for the first notification/search assembly. The combined focused Swift test attempt timed out acquiring the shared build lock; it executed no tests. Parsing and source/export inspection reported by individual lanes do not establish SDK linking or executable behavior. Debug compilation, runtime probes, UI integration, privacy traffic checks and cross-client acceptance remain required.

All heavy checks use the shared build lock and lane-specific derived data, package checkout and scratch directories on the build volume. The coordinator owns final verification, review and shipping. No UI or production readiness is claimed by this checkpoint.
