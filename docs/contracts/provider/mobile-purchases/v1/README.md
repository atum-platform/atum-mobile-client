# `atum.mobile-purchases/1`: buying Proton packs with Apple in-app purchase (contract d1)

- **Contract:** d1 of the iPhone plan's contract track (atum-app
  `docs/plans/2026-10-05-atum-iphone-app.md` §9.1 and §9.4, at
  `c9da67e157095f5037736dfb35587512908bf690`). It answers atum-mobile
  `docs/contracts/d1-purchases-v1.md` at `c81c99cb4e17e1abc18a8629c1e4eb66d279d388`. CO wrote it
  on 2026-10-05.
- **Status:** provider contract v1. It is written but not deployed: no code, migration or route
  for Apple purchases exists. The names `/api/matrix/v1/store/apple/products` and
  `/api/payments/apple/notifications` answer `307` to `/login`, which is how the middleware
  answers a route that doesn't exist (`docs/evidence/2026-10-05-mobile-provider-probes.md`).
  `contract.json` uses the checker's `frozen` enum for a pin-ready pack. Once merged, the pack is
  immutable.
- **Not an M1 dependency.** M1 has no purchase call to action (plan §1). Integration is P4, and
  public v1 needs the proof in §11.
- **Named owner:** the Claude coordinator on the MacBook, session
  `21aea054-600f-49a6-9580-f389a3cd54a0`. It holds CO and wrote this contract. The build is CM's,
  and CM reads "Held by: open" in the tracker (atum-app `docs/PUBLIC-LAUNCH-CHECKLIST.md` line
  1808 at `43ffc0fe…`). It last ran as the commerce chat "Locate store launch plan". The proposal
  is a CM worker under the coordinator from P4, pending the owner's assignment.
  - **Codex (the atum-mobile executor)** builds the StoreKit 2 client. Under the owner's
    direction it drives the App Store Connect steps of plan §10.1.
- **Consumer:** the Atum iOS app.
- **Builds on**, at atum-platform main `2ee67773e1181f8b407fa166bcf373117f257bb7`:
  - `spec/proton-ledger/v1`, the only balance authority (last changed at
    `cf737e0c5319982e7344c46132bb013b611692f1`);
  - `spec/protons/v1`: 1 Proton is worth 1 đồng of spending, in a closed loop (last changed at
    `0af109f510c64d533957230764258d11f1e7aa48`);
  - migrations 0142, 0143 and 0151.

  The refund primitive `ledger.claw_back` exists only in PR #459 (`feat/store-refunds`), which
  is unmerged and still moving, so this pack pins no head. When last read, at 2026-10-05
  14:42Z, its head was `45933e0d03a512c4ad07821929e890c24233f5a8` (committed 13:53:37Z): still
  migration 0190, still revoking `claw_back` from the API roles. CM re-reads it when #459
  merges.
- **Agreement:** pending. CM reviews this pack on its PR, and Codex reviews it as the consumer.

PayOS and VietQR never appear on iOS. iOS never calls `/api/matrix/v1/store/topups`.

## 1. Scope

**In:**
- consumable Proton packs bought with StoreKit 2;
- validation and crediting on the server;
- App Store Server Notifications V2;
- reconciliation;
- refunds and their reversals;
- restore, which is the wallet balance.

**Out, for later versions:** buying Store items directly by in-app purchase; subscriptions;
Android's Play Billing; Advanced Commerce. Store items stay purchasable with Protons through the
existing Store authority.

## 2. Environments

| Apple environment | Atum stack | Ledger | Notifications V2 URL |
|---|---|---|---|
| Production | `api.atumplatform.com`, Supabase `xsmknyzrlfphocagqdpl` | production | `https://api.atumplatform.com/api/payments/apple/notifications` |
| Sandbox, which includes TestFlight | A non-production stack, to be named (O8). The candidate is the dev Supabase `aajjyhprdzzmbdukdxkl` | dev | `<sandbox stack>/api/payments/apple/notifications` |
| Xcode, and StoreKit testing | none | none | Every deployed server refuses it |

- Each server accepts exactly one Apple environment. A transaction from another one answers
  `409 environment_mismatch` and moves nothing.
- **Names.** Atum's responses use `production` and `sandbox` (`server_environment`, as in
  `apple.products.response`). Apple's signed data uses `Production` and `Sandbox`. A production
  server's environment is Apple's `Production`, and a sandbox server's is `Sandbox`; that is the
  `serverEnvironment` of `apple.transaction.facts`. `Xcode` and `LocalTesting` never equal a
  server's environment, so they always answer `409 environment_mismatch`.
- **This affects TestFlight.** TestFlight purchases are sandbox purchases. A TestFlight build
  that tests purchases points at the sandbox stack. The exception for App Review and internal
  testers against production is O3.
- The build's configuration fixes its API origin. The app never picks an environment at run time.

## 3. The catalogue (versioned)

- **Table:** `atum_private.apple_products(environment, product_id, pack_id, paid_micro_protons,
  bonus_micro_protons, enabled, catalog_version)`, keyed by `(environment, product_id)`.
- **Product IDs** are permanent in App Store Connect. The proposed form is
  `com.atum.mobile.protons.<pack>`, which the owner confirms (O1). Every product is a
  non-family-shareable Consumable.
- **Prices** live only in App Store Connect. The app shows StoreKit's localised `displayPrice`,
  never a price from Atum.
- **Route:** `GET /api/matrix/v1/store/apple/products` (`apple.products.response`):
  `{catalogVersion, environment, checkoutOpen, products: [{productId, packId, paidMicroProtons,
  bonusMicroProtons}]}`.
  - It lists enabled products only.
  - The switch `apple_checkout_enabled` starts false.
  - While it is false the route answers `checkoutOpen: false`, and the app shows no purchase
    call to action.

## 4. Authentication and account binding

- **Authority.** Every `/api/matrix/v1/*` route uses the domain authority, with the phone's
  domain grant (`atum.mobile-native-api/1`). Each new route goes on the middleware's exact
  bearer allowlist. A client never names a principal.
- **The account token.** `GET /api/matrix/v1/store/apple/account-token`
  (`apple.account_token.response`) answers `{appAccountToken}`.
  - It is a random UUIDv4 the server issues, one per principal and environment.
  - It is stored in `atum_private.apple_account_tokens` with a unique constraint.
  - The app passes it in every `product.purchase(options: [.appAccountToken(token)])`, and
    fetches it again after any account switch.
- **Who is credited.** A transaction credits the principal that owns its token, never the
  caller. No API rebinds a token.
- **After deletion,** `atum.account-deletion/1` tombstones the token. A later transaction
  carrying it is recorded as `orphaned` (the `apple_transaction` machine), which can never be
  credited; the app sees `needs_support`. The person asks Apple for a refund, and Apple decides.
- **The token is never logged,** and appears in no evidence. It isn't rotated: a new one would
  strand transactions still in flight with the old one.

## 5. What the app sends, and what the server does

`POST /api/matrix/v1/store/apple/transactions` (`apple.transaction.request`), with body
`{signedTransaction}`: the JWS, at most 16 KiB, and no other field.

For each Apple `transactionId`, in one database transaction:
1. **Verify the JWS** with the App Store Server Library's `SignedDataVerifier`. It checks
   (`apple.transaction.facts`):
   - the chain to Apple Root CA G3, pinned, with online revocation checks;
   - bundle ID `com.atum.mobile`;
   - `appAppleId` `6819235537` (the App Store Connect record, atum-mobile
     `docs/evidence/2026-10-05-apple-setup.md`);
   - an environment equal to the server's.
2. **Check the purchase:** type Consumable; `quantity` 1 (the app never asks for more); the
   product is in the catalogue and was enabled at purchase time; `appAccountToken` is present
   and known, and not tombstoned. A transaction that passed step 1 is a real payment, so failing
   any of these never answers an error: its row is recorded as `needs_support`, or as `orphaned`
   for a tombstoned token, and nothing is credited.
3. **Lock** `atum_private.apple_transactions(environment, transaction_id)`. If the signed data or
   a stored notification shows a `revocationDate`, credit nothing.
4. **Credit exactly once:**
   - the paid Protons through a new Apple top-up function (§8, change C1), keyed
     `apple:<env>:<transactionId>:paid`, with reference `apple-<env>:<transactionId>`;
   - the bonus, when there is one, through `ledger.grant_promo`, keyed
     `apple:<env>:<transactionId>:bonus`.

   `<env>` is `production` or `sandbox`. The key is the ledger call's idempotency key and the
   reference is its operation reference, so the two forms differ on purpose.

**The response** (`apple.transaction.response`, private and `no-store`):
`{transactionId, state, finish, credited: {paidMicroProtons, bonusMicroProtons} | null,
balances | null}`.

Every state is answered only after the transaction's row and its effect have committed, so
every state carries `finish: true`. Nothing the device still holds is needed afterwards: support
and reconciliation work from the row.

| `state` | Meaning | `finish` | `credited` | `balances` |
|---|---|---|---|---|
| `credited` | This request credited it, to the caller, who owns the token | true | the amounts | the caller's |
| `already_credited` | Credited earlier, to the caller | true | null | null; the app reads `/wallet` |
| `credited_to_other_account` | Credited to the principal that owns the token, who isn't the caller | true | null | null |
| `revoked` | Apple revoked it; nothing is credited | true | null | null |
| `needs_support` | Recorded, not credited: a failed purchase check (step 2), or a tombstoned token | true | null | null |

- An error (`4xx`, `5xx`) or no answer is never a `finish`. The app keeps the transaction and
  sends it again on the next launch (`Transaction.unfinished`).
- On `needs_support` the app shows the transaction ID and how to reach support.

**What the app must handle** (plan §9.4):
- **Pending purchases** (Ask to Buy, or a payment needing action) send nothing to the server.
  When approved, the transaction arrives through `Transaction.updates` and is sent then. The
  server may see it first through a notification. Both paths reach the same row.
- **A cancelled purchase** (`.userCancelled`) sends nothing.
- **The `Transaction.updates` listener** starts at launch and lives for the app's lifetime.
  Every verified transaction it yields is sent as above.
- **Unfinished transactions at launch:** the app sends each one in `Transaction.unfinished`
  again. The server answers `already_credited` with `finish: true` for one it has credited, so
  a crash between crediting and `finish()` heals on the next launch.
- A transaction whose JWS fails verification on the device is never sent, never finished and
  never credited.

## 6. App Store Server Notifications V2

`POST /api/payments/apple/notifications` (`apple.notification.request`), body `{signedPayload}`.
It has no Atum authentication; Apple signs the payload.
- The middleware bypasses this exact path.
- The server verifies the payload as in §5 step 1, and deduplicates by `notificationUUID` in
  `atum_private.apple_notifications`.
- It answers `200` only after the durable record and its effect commit, and `5xx` otherwise, so
  Apple retries.

| Notification type | Effect |
|---|---|
| `ONE_TIME_CHARGE` | The credit path of §5. Whichever path arrives first wins; the other replays |
| `REFUND` | §8 |
| `REFUND_REVERSED` | A new paid credit of exactly what the refund removed, with reference `apple-<env>:<transactionId>:reinstate:<n>`, where `<n>` counts this transaction's reversals from 1. Never for an `orphaned` row |
| `REFUND_DECLINED`, `TEST` and unknown types | Recorded; `200` |
| `CONSUMPTION_REQUEST` | Recorded. Consumption information is sent only under O5 |

A `REFUND` for a transaction never seen creates its row as `revoked`, with no credit.

## 7. Reconciliation

- **Hourly:** the App Store Server API's notification history from the stored checkpoint, each
  item through §6.
- **Daily:** the transaction info of every row that isn't terminal, and the refund history of
  transactions credited in the last 180 days.
- **Invariants:**
  - every credited Apple transaction has exactly one paid top-up operation;
  - no Apple operation exists without its transaction row;
  - every revoked transaction has its reversing operations, or a shortfall record;
  - in each environment, the Apple top-ups add up to the rows' totals.

## 8. Ledger changes and refunds (CM; none exists)

**C1, the Apple top-up source.**
- `ledger.topup(p_principal, p_amount, p_reference, p_key)` always draws from the system
  `topup` account, which belongs to PayOS (`spec/proton-ledger/v1`, "Operations").
- Apple purchases need their own system source, `topup_apple`. That takes a new ledger function
  (or a source argument), a migration, and a change to the ledger's contract text, all CM's.
- §5 calls that new function, never the four-argument `topup`.

**C2, the refund function.**
- PR #459's `ledger.claw_back(p_operation, p_amount, p_reason, p_actor, p_key)` moves at most
  the original credit, once per operation, never below zero.
- Migration 0190 there revokes it from `service_role` and doesn't grant it to
  `ledger_operator`.
- So the shell can't call it, and Apple refunds need their own `SECURITY DEFINER` function,
  `atum.apple_refund_transaction(environment, transaction_id, notification_uuid)`, with its own
  grant design. CM designs it after #459 merges.
- It claws back the bonus operation, then the paid one, each up to what is still available,
  each once.
- A shortfall goes to `atum_private.apple_refund_shortfalls`.

**Refunds:** Apple decides customer refunds. Atum's policy for refunded Protons already spent
is O2. The recommendation: Atum absorbs the shortfall; repeated shortfalls pause in-app checkout
for that account pending review; future purchases are never silently reduced.

## 9. Restore, errors, privacy

**Restore:**
- Restore is `GET /api/matrix/v1/wallet` (`atum.mobile-native-api/1`, deployed) plus resending
  unfinished transactions.
- Consumables are never credited again, and `currentEntitlements` is never relied on for them.

**Errors** (`apple.error.response`), in the native envelope
`{"error": "matrix_<status>", "details": {"reason"}}`:

| Status | `details.reason` |
|---|---|
| 400 | `invalid` |
| 401 | none: the domain grant's usual refresh (`atum.mobile-native-api/1` §7) |
| 403 | `checkout_closed` |
| 409 | `environment_mismatch` |
| 422 | `invalid_signature`, `wrong_bundle` (step 1 failed: not a verifiable transaction of this app) |
| 503 | `unavailable`: retry; never a guessed outcome |

`422` is new to the native envelope. Only these Apple routes use it.

A failed read is never shown as a zero balance.

**Secrets:** the In-App Purchase key (`.p8`), its key ID and the issuer ID live only in
Infisical, separately for production and dev. `appAppleId` is not secret.

**Logs** carry the transaction ID only, never a whole JWS.

**Expiry:** Protons bought in the app, and their bonus, never expire (App Review Guideline
3.1.1, and the Terms' §8 for purchased Protons).

## 10. Decided and open

**Decided by the owner on 2026-10-05** (the iPhone plan at `c9da67e1…`):
- in-app purchase for every digital purchase (D1);
- the bundle `com.atum.mobile`;
- no purchase call to action, and no PayOS or VietQR, in any build before this path is validated
  and switched on;
- the ledger is the only authority, and balances never go negative.

**Open:**
- **O1:** the packs, their price points and their Protons after Apple's 15–30%.
- **O2:** the policy for refunds after spending.
- **O3:** App Review's and internal testers' sandbox purchases against production. The
  recommendation is an allowlisted reviewer principal and a tagged bucket that can't be
  withdrawn.
- **O4:** the Small Business Program.
- **O5:** consent to send consumption information.
- **O6:** selling Store items directly by in-app purchase, later.
- **O7:** the legal check (P5).
- **O8:** naming the sandbox stack.
- **The CM holder** (owner).

**The owner's Apple steps** (plan §10.1): the Paid Applications Agreement with tax and banking;
the products; sandbox testers; the In-App Purchase key; the V2 notification URLs.

## 11. Acceptance and proof

**On the sandbox stack, with sandbox testers.** Each credit and reversal is recorded exactly
once, and the invariants hold after every case:
- the app is killed after payment, before `finish()`;
- the same transaction arrives through the app and V2, repeatedly;
- notifications are dropped, or arrive out of order;
- a refund before spending, a refund after spending, and a refund reversal;
- a reinstall, and restore;
- an account switch, and a stale session;
- a pending purchase that is approved later;
- a sandbox transaction sent to production answers `environment_mismatch`;
- a transaction carrying a deleted account's token is recorded as `orphaned`, answers
  `needs_support` with `finish: true`, and is never credited.

**In production:**
- the deployed commit and Vercel deployment ID;
- a V2 `TEST` notification received;
- one owner purchase on the release candidate, credited once and reconciled.

The refund path is proven in the sandbox only, and labelled so.

## 12. Conformance

`contract.json` holds:
- the products, account-token and transaction shapes;
- the notification body;
- the facts the server checks in a verified transaction;
- the errors;
- the `apple_transaction` machine;
- accept and reject fixtures.

`pnpm verify:g8-p0-contracts` checks the pack. CM's route tests produce the response fixtures
and refuse every reject fixture. The app parses every response fixture.
