# iPhone live data parity

## Wallet projection 1.4

Platform #910 and migration `0522_hermes_live_balance.sql` define live balance in `docs/operations/wallet-live-balance.md:48–81`. The Shell validates the pair in `apps/shell/src/lib/matrix-wallet.ts:67–75`. The existing iPhone equivalents were `WalletResponse`, `NativeDomainClient.wallet()`, the product balance display and `LiveAppModel.freshWalletAvailable` for purchase checks.

The decoder accepts the legacy five-balance-key payload and the 1.4 payload. The new fields must be present together, both null or both valid safe integers, with the spendable value equal to the clamped remainder. The wallet read sends `X-Atum-Wallet-Projection: 1.4`. The product balance prefers spendable and falls back to available ledger balance when the projection is absent. Purchase affordability still reads the ledger, and StoreKit supplies the localized price. The product balance presents a single amount.

The package tests cover legacy and null fallback, a spendable zero, a reduced balance alongside its unchanged ledger amount, malformed projections, and the header on the wallet route only.

## Verification

The verification batch runs under the shared build lock with two build jobs and one iPhone 17 simulator. Logs and result bundles are kept in `/Volumes/AtumTestFlight/dd-w4-data-parity/`.
