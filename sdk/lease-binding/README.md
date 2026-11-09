# Immutable store binding experiment

This additive Apache-2.0 checkpoint builds on sdk/lease-fence without selecting
an application runtime. BaseClient and the installed phone candidate do not use
this binding yet. No notification is decrypted by this experiment.

An opened SQLite crypto store owns an opaque process-local identity shared by
its clones. Independent opens, including another open of the same path, receive
another identity. LockableCryptoStore forwards this identity through the existing
CryptoStore error adapters; the actual SDK guard snapshots it when acquired.
Binding refuses a foreign issuing identity even if key, holder and generation
match. The identity carries no database path, persisted value or credential.
No schema, dependency, lease timing or renewal behavior changes.

CryptoStore.bind_lease returns a new immutable erased handle. The two existing
error-erasure paths forward binding and identity. Backends which do not implement
binding return LeaseBindingUnsupported. A bound SQLite handle cannot rebind or
acquire/renew a lease. Its exact epoch reaches the existing OlmMachineBuilder,
Store wrapper, Store::Deref and all Olm clones. Example:

```rust
let guarded = raw_store.bind_lease(&guard)?;
let olm = OlmMachineBuilder::new(user_id, device_id)
    .with_crypto_store(guarded)
    .with_required_identity_keys(Some(expected_keys))
    .build().await?;
```

Keep the actual SDK guard alive through each protected operation. Binding does
not retain it or extend its lease. Discard an Olm instance and its caches after
persistence refusal. Reads and already-mutated shared ratchets remain outside
this write fence. A newer handle cannot grant an older Olm object a new epoch.

Session-cache additions and clears now happen after the underlying save returns
success. The publication invariant is tested with real Olm sessions and a test-
only forwarding MemoryStore backend whose save_changes refusal is explicitly
injected. That test does not claim a real SQLite interruption. Separate SQLite
acceptance restores actual Olm machines under A→B→A and refuses their stale sync
and Store::Deref writes while preserving the successor's batch and device keys.

Reproduce from a pinned official SDK source cache:

```sh
python3 scripts/study-sqlite-lease-binding.py /tmp/atum-binding-replay.json \
  --source-cache /path/to/pinned-official-sdk-checkout \
  --cargo /path/to/rust-1.96.0/bin/cargo \
  --target-dir /tmp/atum-binding-replay-target
```

The collector verifies the custody base, prior fence patch and all new source
hashes. It first expects two behavioral failures on the preceding implementation:
foreign-store binding and cache publication after a refused save. It restores
that source, applies the additive patch, verifies the new focused behavior,
wrapper tests, full SQLite/crypto regressions and existing SDK lock tests. A
compilation failure or absent test summary cannot produce a passing receipt.

Dependent work remains: integrate bound Olm construction into BaseClient with
safe replacement after handoff/refusal; thread actual guards through outgoing
and detached tasks and sync acknowledgements; then fair foreground/NSE handoff,
generated Swift and physical notification evidence. Do not narrow existing sync
lease scopes based only on this checkpoint.
