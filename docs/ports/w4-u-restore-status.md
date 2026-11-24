# Proton top-up Restore status

A refund paused in wallet refresh could pick up another transaction’s shared success status. For purchases of the same pack, a separate refund could also replace the success shown for a credited purchase. [Issue #102](https://github.com/atum-platform/atum-mobile-client/issues/102).

## Transaction identity and feedback

- The existing StoreKit adapter supplies the verified `Transaction.id`. Direct purchases, `Transaction.updates`, and replay of `Transaction.unfinished` continue through the same coordinator. `Transaction.currentEntitlements` omits consumables, so Recover balance still refreshes the server wallet and replays unfinished consumables. [StoreKit transaction ID](https://developer.apple.com/documentation/storekit/transaction/id), [updates](https://developer.apple.com/documentation/storekit/transaction/updates), [unfinished transactions](https://developer.apple.com/documentation/storekit/transaction/unfinished), [current entitlements](https://developer.apple.com/documentation/storekit/transaction/currententitlements).
- The coordinator records acknowledgement order after validating the server transaction ID and `finish` flag. Each pack row uses its latest settled acknowledgement, with a credit taking precedence over a refund of a different transaction for the same pack. A verified StoreKit revocation replaces the original credit by transaction ID as soon as it arrives, even during the credit’s wallet refresh. It refreshes the wallet without another submission or StoreKit finish. An older credit completion or replay cannot reinstate the success.
- Done or Continue reads the sheet’s credited and already-credited results directly and disappears if its last credit gets revoked. Opening or closing the sheet clears discarded row ordering alongside settled feedback, so a refund still refreshing can appear when it lands. The sheet retains the support transaction IDs still visible on pack rows. Rebinding clears the transaction feedback and ordering.
- Buy stays disabled while a StoreKit purchase or Ask to Buy is pending, or while an admitted transaction still awaits server acknowledgement, StoreKit finish, wallet refresh, or terminal row feedback. A different transaction’s result can update the pack row without releasing that guard. The server wallet remains the source of truth for spendable Protons.

## Round 3

- StoreKit finish still deduplicates the transaction immediately. The coordinator releases Buy only after the wallet refresh returns and the terminal outcome is available, including when the wallet read fails or a refund has already replaced the credit.
- Top-up and general product wallet reads share a request sequence in `LiveAppModel`. Only the newest issued request for the active client can apply a result. A late credit response therefore cannot restore the higher balance after a refund.
- The coordinator records the pack before calling StoreKit. An approval admitted by the listener or Recover balance clears that marker. If the purchase call then returns `.pending`, it preserves the approval’s row and leaves the marker cleared. Recover balance preserves a genuine pending request until StoreKit provides a verified transaction for that pack.

## Verification

Continuation-based tests force a verified refund of the original transaction during submission and during wallet refresh, then check the same refund after settlement and replay. They also hold a same-pack submission open while two terminal results arrive, dismiss and reopen the sheet during a refund refresh, and check that the sheet prunes superseded support IDs. Round 3 adds coverage for the Buy guard after finish, approval before the pending result, and recovery of a pending approval. The app test holds two wallet responses and delivers the older credit after the refund.

- The focused `ApplePurchaseCoordinatorTests` suite passed 48 tests and `LiveAppWalletRefreshTests` passed 1 test, both with zero failures. The `AtumMobile` Debug build passed for the iPhone 17 simulator. All three ran under one shared heavy-build lock with two jobs.
- The committed revision is checked with `python3 scripts/public_guard.py --base 09850de --head HEAD` and `git diff --check`.
