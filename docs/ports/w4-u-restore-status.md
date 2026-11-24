# Proton top-up Restore status

A refund paused in wallet refresh could pick up another transaction’s shared success status. For purchases of the same pack, a separate refund could also replace the success shown for a credited purchase. [Issue #102](https://github.com/atum-platform/atum-mobile-client/issues/102).

## Transaction identity and feedback

- The existing StoreKit adapter supplies the verified `Transaction.id`. Direct purchases, `Transaction.updates`, and replay of `Transaction.unfinished` continue through the same coordinator. `Transaction.currentEntitlements` omits consumables, so Recover balance still refreshes the server wallet and replays unfinished consumables. [StoreKit transaction ID](https://developer.apple.com/documentation/storekit/transaction/id), [updates](https://developer.apple.com/documentation/storekit/transaction/updates), [unfinished transactions](https://developer.apple.com/documentation/storekit/transaction/unfinished), [current entitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements).
- The coordinator records acknowledgement order after validating the server transaction ID and `finish` flag. It publishes the exact terminal result by transaction ID after the existing finish and wallet refresh steps. Each pack row uses the latest settled acknowledgement for that pack, with credit taking precedence when the competing result is a refund. This also covers a credit whose refresh finishes after a newer refund. The order is local to the account binding and follows the arrival of validated server replies.
- Done or Continue reads credited and already-credited transaction outcomes directly. Later row activity can change the visible notice while the completion action stays available. Opening or closing the sheet clears settled feedback through the existing lifecycle, preserving needs-support outcomes and the row ordering for in-flight work. Rebinding clears the transaction feedback and ordering.
- Server submission, StoreKit finish and deduplication, wallet refresh timing, and the shared checkout status follow their existing paths. Feedback is in memory and the server wallet remains the source of truth for spendable Protons.

## Verification

The coordinator tests hold the first transaction’s wallet refresh open with a continuation and release it after the second result settles. They cover different packs, a same-pack refund overtaken by a credit or needs-support result, and a credit overtaken by a refund. They also check a refund after a settled same-pack credit, and verify that cancelling a later purchase leaves the session’s credit available until settled feedback is cleared.

- The focused `ApplePurchaseCoordinatorTests` Swift suite passed all 39 tests under the shared heavy-build lock. The tests use synthetic StoreKit and server responses.
- The Debug `AtumMobile` `build-for-testing` passed on the iPhone 17 destination with iOS 27.0 under the same lock. Verification stopped at build-for-testing for the iOS app.
- The committed revision is checked with `python3 scripts/public_guard.py --base origin/main --head HEAD`.
