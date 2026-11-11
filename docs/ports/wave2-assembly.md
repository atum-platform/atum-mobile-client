# Wave 2 assembly (`wip/w2-assembly`)

Merges the five wave 2 streams from `dd26d6e`: AC (`d39c6b9`), AS (`34870e1`),
TS (`91c00ea`), HC (`8978b98`) and ST (`63dfc42`). Conflicts resolved at merge
time: `ChatScreen.swift` empty-chat state (HC vs TS: channel intro, assistant
greeting, "No messages yet."), Settings Top up slot (AC vs ST: the shared top-up
sheet) and Store shelf scrolling (AS vs ST).

## Verification (2026-11-11, iPhone simulator, under the build lock)

- App unit tests (`AtumMobileTests`): 325 passed.
- Full UI suite, first pass: 148 run, 4 skipped, 28 failed. 17 of the failures
  were environmental: the tests ask `scripts/sim-content-size-runner.sh` (kept
  in the private release repo) to switch appearance and text size, and no
  runner was running. Rerun the failures with that runner beside xcodebuild:
  `sim-content-size-runner.sh <UDID> <worktree>`.
- Test fixes made at assembly:
  - U10: the S6 account fixture's handle was `an`, which wave 1's handle rule
    (`^[a-z][a-z0-9_]{2,31}$`) rejects, so the card hid it. The fixture now uses
    `an_nguyen`.
  - U8: `store.partial` expected "Chưa có số dư". Current desktop
    (`discover-view.tsx`) hides the header balance until the wallet loads; that
    string belongs to the retired legacy wallet. The test now checks that the
    balance chip is absent.
