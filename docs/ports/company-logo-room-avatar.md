# Company logo: keep the room avatar through the roster projection

**Problem (2026-11-10):** the Team Space company logo never loaded on a live account. `LiveProductRoom.withRosterState` rebuilds every live room (`LiveAppModel` maps the whole room list through it, to apply pending unread/pin/mute/low-priority mutations). It didn't pass `roomAvatarURL`, so every room lost its own `m.room.avatar`, and `CompanyWorkspaceModel.logoURIs` never found a logo. The debug hosts inject logos directly, which is why captures looked right.

**Fix:** `withRosterState` passes `roomAvatarURL` through. `S2StateTests.testRosterProjectionKeepsEveryFieldItDoesNotOverride` compares a fully populated room with its no-override projection, so the next field the projection drops fails a test.

**Verified:** `AtumMobileStateTests` / `S2StateTests` (72 tests) pass on the iOS simulator. Live confirmation on the owner's account comes with the next TestFlight build.

Found by the parity audit (lane 2, private `atum-mobile` `docs/research/2026-11-10-parity-audit/lane2-team-space.md`). The circle shape for company logos is a separate UI slice (TS-1).
