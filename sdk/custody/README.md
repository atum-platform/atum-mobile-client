# Pinned existing-device, recovery and notification SDK changes

This patch is a P2 implementation candidate, **not the selected app runtime**.
The iOS target still uses the original official binary pin. No live account
bridge is enabled. Upstream is the Apache-2.0 Matrix Rust SDK, not Element X.

The same candidate FFI also adds zero-I/O `prepareRecoveryKey` and strict
`validatePreparedRecoveryKey`. Preparation exports one random SDK Base58 root,
its separate key ID and canonical AES-HMAC metadata. Validation requires both
IV/MAC and checks the actual SDK MAC, avoiding upstream's missing-IV/MAC
acceptance. No client/store/network/lock is used; no publisher is added.
The root is sensitive and all exported string copies belong to the caller.
Only main-private device-only Keychain may retain it. IDs are not MAC-bound;
the durable journal's exact triple comparison preserves its original key ID.

The candidate also assigns a fresh existing Ruma TransactionId holder to every
MultipleProcesses NotificationClient. The upstream fixed holder let two separate
helpers renew/acquire the same live SQLite crypto lease. A real SQLite regression
reproduced that second acquisition before the fix and refuses it with distinct
holders afterwards. The wire connection ID remains unchanged; SingleProcess is
unchanged. No new dependency, lock, schema or FFI API is added. Same-process
independent-helper contention is not physical NSE concurrency proof.

The candidate adds `Client.restore_session_existing` (Swift
`restoreSessionExisting`) for an existing OAuth device. It requires a fresh,
multi-process client with automatic refresh disabled. It obtains the same SDK
`cross_process_lock` lease that later encryption operations use, loads the
existing account, and compares user/device and both public identity keys before
setting tokens, activating the session, or reconciling refresh hashes. Missing
accounts and key mismatches return errors. The constraint survives BaseClient
cloning and every `regenerate_olm` rebuild, preventing later silent creation.
The new restore does not schedule encryption initialization. Original APIs keep
their existing behavior.

Strict existing-device restore also refuses an unavailable authoritative token
read when its persisted token hash differs from the input snapshot. The error
is fixed and retains no opaque callback cause. Ordinary restore and refresh keep
upstream behavior. This error occurs after account/token activation: callers
must discard a failed client, and must not treat its retained fields as ready.
The actual old generated Swift binding reproduced success with stale tokens
after the delegate threw; a separate encrypted-SQLite Rust regression now passes
with the correction and preserves the original keys/latest tokens. Corrected
Apple packaging and the new generated Swift runtime are still required; the
correction does not change SDK lease scope or prove concurrent NSE decryption.

The application must still validate existing directory/file protection and the
current installation/envelope **before building a client**, and recheck the
current envelope/returned identity before allowing operations. Opening the SDK
SQLite configuration can create files: this API alone does not enforce file
presence, authorize an identity, establish Keychain custody, or refresh tokens.
Creation/prepared interruption, controlled refresh under the SDK lock, physical
shared Keychain/NSE and cross-process proof remain separate dependent work.

`source.json` pins the upstream commit, patch bytes, each source preimage and
patched file, and the unchanged Apache license. Prepare a new checkout with:

```sh
python3 scripts/prepare-matrix-sdk.py /tmp/atum-sdk-source
cd /tmp/atum-sdk-source
cargo +1.96.0 test --locked -p matrix-sdk --features bundled-sqlite --test atum_existing_device
cargo +1.96.0 test --locked -p matrix-sdk-ui --features matrix-sdk/bundled-sqlite --lib atum_notification_helpers_contend_for_same_sqlite_crypto_lease
cargo +1.96.0 check --locked -p matrix-sdk-ffi
cargo +1.96.0 test --locked -p matrix-sdk-ffi --lib atum_recovery_prepared_tests
```

The hosted conformance job runs the real encrypted SQLite path using disposable
identities and a local HTTP recorder. Tests cover fresh reopen, missing internal
account/retry, either wrong public key, wrong user/device, wrong passphrase,
corruption, contention with the existing SDK lease, automatic-refresh refusal,
already-authenticated refusal and the retained constraint during actual BaseClient
regeneration. No Keychain or server accounts are used. Failure may write ordinary
SQLite/lease metadata; the invariant is no replacement identity or initialization
traffic, with surviving account material preserved, not byte-identical databases.

An already-fetched checkout can be supplied with `--source-cache`; its origin
and exact HEAD are checked, committed objects are cloned without hard links,
and every source preimage is verified. Cache working files are never copied.
Local verification used this path after two fresh network fetches were refused;
the first official source checkout had already been fetched successfully. The
source helper bounds and terminates only its own Git transport on timeout.

After Rust tests and FFI checks pass, hosted macOS builds the two Apple arm64
slices and generated Swift through the upstream xtask. The build helper pins
its three floating `stable` invocations to Rust 1.96.0 and adds `--locked`,
retaining target selection, UniFFI generation and upstream SQLite symbol
localization. It writes an unsigned local Swift package, compiles that surface
and retains toolchain/Xcode/SDK, source and every output-file hash. It uses a
clean committed consumer source receipt. The resulting CI artifact is not an
uploaded app or a TestFlight build; the app's official SDK pin stays unchanged.

Before this replaces the one app SDK library, Rust conformance, FFI compilation,
generated Swift/Apple packaging, signed native fault tests and retained assembly
review must pass. A library swap replaces the existing runtime; it must never
link a second Rust SDK static library. SDK updates require rebasing the patch and
repeating conformance. Removing this candidate leaves the app's live bridge
disabled and returns to the original binary; no schema migration is introduced.