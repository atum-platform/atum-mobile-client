# W4 iOS UI test hardening

## Read signals (#75)

The two `chat.send` UI tests hold the scripted receipt batch until XCTest
observes the outgoing bubble without Sending, Failed, Sent, or Seen. They
capture that state, release the batch through a per-test file, and check
Seen on the same bubble. The reader's face must appear inside that message's
`delivery.line.<displayID>`. The Debug fixture writes `send-receipt-held` to
the per-test probe log when it intercepts the receipt. XCTest requires that
entry before writing the release file. The fixture then resumes forwarding
in order. The `showsTime` comment now describes the readers' faces.
The composer test also gives the system keyboard up to 15 seconds to appear.

## Group Info switches (#79)

Pin and Mute are SwiftUI `Toggle` controls. In the second initial run, XCTest
reported Pin as hittable at the bottom of the screen and the coordinate tap
dismissed the sheet. The initial drag begins in the sheet's scroll view and
travels far enough to expand the medium sheet. Corrective swipes also begin
inside that scroll view. The reveal checks the switch's current
position and scrolls in either direction to bring it clear of the edges. If
that fails, the test stops before tapping. It then checks that the switch is
hittable and off, taps the knob, and waits for the value to turn on. It still
checks the group name, member count, and assistant-access copy.

## Verification

The locked Debug build and focused UI runs used a single iPhone 17 simulator
on iOS 27.0. The S1 matrix used the Vietnamese light/default cell. Each run
selected only U4, S1's send/Seen test, and Group Info.

| Revision | Debug build | UI run 1 | UI run 2 |
| --- | --- | --- | --- |
| Initial receipt gate and switch waits | `0` | `0`, 3/3 | `65`, 1/3. The sheet dismissed on the Pin tap and U4's keyboard appeared after its wait. |
| With the sheet scroll margin and keyboard wait | `0` | `0`, 3/3 | `0`, 3/3 |
| Review follow-up with short sheet gestures | `0` | `65`, 2/3. The medium sheet stayed in place and Pin failed the reveal before any tap. | `0`, 3/3 |
| Review follow-up with the longer opening drag | `0` | `0`, 3/3 | `0`, 3/3 |

The first verification attempt after the initial fixes exited `73` at `lockf` when
the build volume detached. The existing disk image was reattached.
The simulator shutdown exited `0` after each completed verification attempt.
All four send tests in the final two runs recorded a hold before release.

## PhoneApprovalsUITests set-up/remove flake (24 Nov, coordinator)

`testSetUpWithFaceIDThenRemove` failed on two unrelated hosted heads at two different points:
- PR #95 `ae84aad`, line 76: the transient "Setting up…" label wasn't seen within 3 s.
- PR #97 `3e16c86`, line 84: the Remove confirmation never opened.

Neither PR touches approvals code. Remove is `.disabled(model.busy != nil)`, so on a slow runner a tap right after set-up finishes can land on a disabled row and open nothing. The test now:
- accepts either the progress label or the finished "On · since" state as proof that set-up started;
- waits up to 10 s for Remove to be enabled before tapping it;
- gives the confirmation 5 s.

The test-only change is syntax-checked with `swiftc -parse`. The hosted PR shard is the evidence.
