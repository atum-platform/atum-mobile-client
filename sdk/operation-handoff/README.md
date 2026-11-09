# Isolated SDK operation-handoff candidate

This Apache-2.0 source correction is **not selected by the app**, is not a
TestFlight build, and does not pass full P2 notification acceptance. Its source
pack applies after the reviewed background-backup operation chain at upstream
4f7f4d49f571e613eb1cb35956e4649dc056f0af. Preserve LICENSE and upstream notices.

## Reproduced problem and candidate behavior

The retained generated Swift three-process probe refused both notification
readers while foreground encryption sync progressed. No notification HTTP ran.
The existing SDK heartbeat already releases an unused lease, but immediate
foreground reacquisition can prevent it from observing an operation boundary.
This candidate keeps the existing SQLite lease and immutable epoch fencing:

- Conditional expiry updates only the exact key/holder/generation row. It cannot
  clear a foreign or newer epoch and does not change the schema or generation.
- Renewal, explicit expiry and local acquisition share the existing attempt
  mutex through the backend transaction. A cancelled expiry waiter leaves a
  detached task owning that mutex until the queued transaction completes.
- Fixed polling uses a retry budget; an admitted backend transaction and
  heartbeat installation finish without timeout cancellation, so backend
  latency can exceed that budget. Guard clones keep the
  lease live; release is refused until all local operation guards finish.
- Foreground and retry sync yield cooperatively between completed operations.
  This is empirical admission, not a FIFO or starvation-freedom guarantee.
- Existing-only restore waits up to one second for admission; it still refuses
  absent/mismatched keys and never publishes an unready or replacement account.
- A fenced notification helper with a distinct holder has its own controller,
  epoch and Olm instance, restored from the original persistent identity under
  its lease. Same-process children retain the parent's controller and ratchets.
  Helper readiness is established before room-only fetching begins. An inherited
  parent controller is never explicitly released by helper construction.
- Detached response processing uses one-second fixed-poll admission and retains
  its acquired guard through crypto, persistence and sync-position publication.

A real Alice/Bob SDK ciphertext regression now passes with foreground HTTP
progress and overlapping notification HTTP from two logical helpers sharing
an encrypted SQLite store. It asserts decrypted body/event identity and original
Bob keys. The preceding failures and diagnostics are retained separately; no
fallback is counted as decryption. These are logical clients, not three OS
processes. The unchanged generated Swift probe is still required.

## Known limits before any runtime selection

The outer encryption-sync guard still covers long-poll HTTP. A normal slow
foreground poll can exceed the helper's one-second readiness budget. The short
mock foreground responses in the passing logical regression do not resolve or
prove that case. Do not increase the target deadline, pause foreground, share
holders, import a room key or accept generic fallback to make the probe pass.

Terminal error/ended retry arms now acquire their own guard within the original
deadline; the crypto future is never polled after exhausted admission. A real
SQLite contender regression drives both arms and asserts exclusion across await.
This proves guard lifetime, not successful message decryption on those arms.
Enabled background workers still require complete guard and lifetime review. Platform-specific bindings, actual separate-process overlap,
physical iOS Keychain/NSE/UI, APNs, live provider sign-in and owner Gate 2 are
still open. Existing review verdicts on predecessor packs do not select this
candidate. Store/Apple/cloud/deletion and full private TestFlight remain required.

## Reproduction and pinning

`source.json` pins the immutable base manifest, changed preimages, resulting
files, unchanged source inventory, patch and license. Git metadata and the generated
consumer-state `atum-source-receipt.json` are excluded from immutable SDK source. Apply the preceding
source chain first, verify preimages, then use `git apply --check` and `git apply`
with this patch. Compare every resulting digest; never edit the base copy.

Focused host checks use the locked Cargo graph and Rust 1.96.0:

```
cargo test --locked -p matrix-sdk-common --lib cross_process_lock::tests
cargo test --locked -p matrix-sdk --no-default-features \
  --features e2e-encryption,bundled-sqlite \
  --test atum_existing_device --test atum_protected_tasks
cargo test --locked -p matrix-sdk-ui --no-default-features \
  --test integration notification_client::
cargo test --locked -p matrix-sdk-ui --no-default-features --lib \
  notification_client::tests::test_atum_notification_helpers_contend_for_same_sqlite_crypto_lease
```

All fixture accounts, messages, stores and passphrases are synthetic. Raw logs
remain local; evidence stores fixed results, source hashes and limits. No
credentials, signing changes, production action or personal account data.

## Assembly review corrections and compatibility limits

H3 verification: the notification `try_sliding_sync` builder enables account_data
only, never e2ee/to_device, so its initial room-only request does not enter
`mark_all_tracked_users_as_dirty`. EncryptionSyncService explicitly enables e2ee
and to_device; its outer operation guard is still retained over request
generation and HTTP. That remaining long-poll ownership problem is unresolved.

Conditional prompt handoff is implemented for the fenced SQLite backend only.
Other backends retain default `expire_lease -> false` and are not approved for
this app's multi-process custody. The same guard API doesn't imply equivalent
operation-boundary admission on memory or IndexedDB. Retry polling is 10ms and
foreground admission can wait 60s; device battery/WAL pressure is still unmeasured.
The public run_iterations API now waits for admission per iteration; consumers
that previously used immediate deferral need compatibility review. Release SQL
latency remains bounded only by the backend's behavior, not by a safe hard
cancellation ceiling. Keep the local mutex through actual transaction completion.

Host-only recipe exploration used native route dd8bcf0c. The unchanged generated
Swift probe requires an authentic selected-source preparation/build receipt.
An arbitrary candidate artifact cannot satisfy its custody-source pin. Do not
fabricate a receipt, change the probe's limits, or select this candidate merely
to get it admitted. Exact candidate provenance needs a separately reviewed
collector adaptation that preserves every behavioral/identity/deadline assertion.
