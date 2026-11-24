# Wave 4 transcript and Drive UI test reliability

## Live answer folding ([#81](https://github.com/atum-platform/atum-mobile-client/issues/81))

The local failure followed a single composer tap and a two-second wait
for the software keyboard. In hosted run 45290236233, XCTest tapped the
center of the visible Show more button and the fold label stayed unchanged
through the three-second wait. A product race remains unconfirmed.

The test now waits for a tappable input and the native keyboard, and
retries a tap only while the composer lacks focus and the keyboard is
absent. It waits for the folded toggle to be above the composer with the
transcript still following, and retries Show more only while the same
folded state is visible. The expanded layout and jump pill replace the
fixed post-tap delay. The partial stream, longer final body, fold position,
one-point anchor tolerance, detached transcript and jump pill are all
still required.

## Drive view options ([#82](https://github.com/atum-platform/atum-mobile-client/issues/82))

In hosted run 45307588980, the assertion for Kind grouping after relaunch
passed. The failure's accessibility hierarchy still had Kind group headers
and the parent View menu open after the Group tap. The test now waits for
the submenu's None option to be tappable and retries Group only when the
parent item is still tappable. It uses the localized Group title because
iOS 27 exposes that title in the native menu without the iOS 26 identifier.
It checks the restored List and Kind grouping,
waits for None to clear the grouping, and checks the folder's saved Size sort.
The recorded failure was in opening the submenu. Drive preferences still
use their existing storage.

## Verification

The first locked batch built and passed one transcript run. Drive failed
on iOS 27 at the Group identifier locator. After restoring the localized
title locator, one locked batch passed Debug build-for-testing and ran
each test three times with its own `-only-testing` invocation on iPhone 17
with iOS 27.0. Simulator shutdown exited 0.

| Test | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- |
| `testALiveLongAnswerFoldsOnceFinalAndOpensInPlace` | Pass | Pass | Pass |
| `testViewSortAndGroupAreChosenAndRemembered` | Pass | Pass | Pass |

The body top measured 364 pt before and after expansion on all three runs.
Every keyboard, Show more and Group tap succeeded on the first attempt
in the final batch. Coverage of the retry paths and hosted iOS 26.2
verification remain open. Logs and result bundles are in
`/Volumes/AtumTestFlight/dd-w4-l/verify.bv3RkO`. The public guard exited 0
with `--base origin/main --head HEAD`.
