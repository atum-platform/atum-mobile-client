# W4 iOS UI test hardening

## Read signals (#75)

The two `chat.send` UI tests hold the scripted receipt batch until XCTest
observes the outgoing bubble without Sending, Failed, Sent, or Seen. They
capture that state, release the batch through a per-test file, and check
Seen on the same bubble. The reader's face must appear inside that message's
`delivery.line.<displayID>`. The Debug fixture resumes forwarding in order
after release. The `showsTime` comment now describes the readers' faces.
The composer test also gives the system keyboard up to 15 seconds to appear.

## Group Info switches (#79)

Pin and Mute are SwiftUI `Toggle` controls. In the second initial run, XCTest
reported Pin as hittable at the bottom of the screen and the coordinate tap
dismissed the sheet. The test scrolls inside the sheet until each switch is
clear of the scroll edges, waits for it to be hittable and off, taps the knob,
and waits for the value to turn on. It still checks the group name, member
count, and assistant-access copy.

## Verification

The locked Debug build and focused UI runs used a single iPhone 17 simulator
on iOS 27.0. The S1 matrix used the Vietnamese light/default cell. Each run
selected only U4, S1's send/Seen test, and Group Info.

| Revision | Debug build | UI run 1 | UI run 2 |
| --- | --- | --- | --- |
| Initial receipt gate and switch waits | `0` | `0`, 3/3 | `65`, 1/3. The sheet dismissed on the Pin tap and U4's keyboard appeared after its wait. |
| With the sheet scroll margin and keyboard wait | `0` | `0`, 3/3 | `0`, 3/3 |

The first verification attempt after those fixes exited `73` at `lockf` when
the build volume detached. The existing disk image was reattached.
The simulator shutdown exited `0` after both completed verification attempts.
