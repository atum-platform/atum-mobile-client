# iPhone live data parity

## Model choice

[Desktop #24](https://github.com/atum-platform/atum-desktop/pull/24) defines the retry and ordering rules in `apps/desktop/electron/matrix/cloud-model-choice.ts:319,420,511` and `model-destinations.ts:954,1035` at merge `3b01704c`. Platform `apps/shell/src/lib/managed-model-authority.ts:37–56` and the `spec/model-choice/v1.1/fixtures/error-{revision-conflict,policy-changed}.response.json` fixtures carry the extra revision or digest alongside the conflict reason. The existing iPhone equivalents were `LiveAppModel.readAssistantModels`, the offer, destination and subscription save actions, and `ModelWriteRequests`.

The offer and destination states fence reads by adopted writes and retain the highest revision observed. Picks bind to the current account, agent and latest intent for that state. A write retries the owner's pick once after an explicit `revision_conflict` or `policy_changed`, using a fresh request ID and the refreshed snapshot's revision and digest. The destination path reads back after a second fence conflict, as on desktop. The offer path retains the snapshot used for its retry. Other refusals end the attempt immediately. Model writes have a route-specific error decoder so the rest of the domain API keeps its closed error envelope.

The package tests exercise the provider-shaped policy and revision conflicts, changed request ID and digest, the final destination readback, an unrelated refusal, a pre-write response with the same revision, an older revision, and a superseded pick.

## Wallet projection 1.4

Platform #910 and migration `0522_hermes_live_balance.sql` define live balance in `docs/operations/wallet-live-balance.md:48–81`. The Shell validates the pair in `apps/shell/src/lib/matrix-wallet.ts:67–75`. The existing iPhone equivalents were `WalletResponse`, `NativeDomainClient.wallet()`, the product balance display and `LiveAppModel.freshWalletAvailable` for purchase checks.

The decoder accepts the legacy five-balance-key payload and the 1.4 payload. The new fields must be present together, both null or both valid safe integers, with the spendable value equal to the clamped remainder. The wallet read sends `X-Atum-Wallet-Projection: 1.4`. The product balance prefers spendable and falls back to available ledger balance when the projection is absent. Purchase affordability still reads the ledger, and StoreKit supplies the localized price. The product balance presents a single amount.

The package tests cover legacy and null fallback, a spendable zero, a reduced balance alongside its unchanged ledger amount, malformed projections, and the header on the wallet route only.

## Verification

The verification batch runs under the shared build lock with two build jobs and one iPhone 17 simulator. Logs and result bundles are kept in `/Volumes/AtumTestFlight/dd-w4-data-parity/`.
