# Crypto publication cancellation and reconstruction

This unselected Apache SDK source pack builds on the reviewed protected-task
chain. `source.json` pins the exact patch, preimages, fixtures, compiled test
files and unchanged authority boundaries. It is not the app's selected SDK.

A cancelled publication invalidates the wrapper and its bound SQLite backend.
The bound backend shares one failure token across surviving clones, refuses
cached account access and new operations, and checks that token inside the
existing fenced transaction. Cancellation can still race a worker's final
commit; reconstruction drains the actual SQLite writer before loading durable
state. BaseClient skips reuse of a failed machine even within the same epoch.
The caller keeps its operation guard throughout reconstruction; no new lease,
detached writer or authority extension is introduced.

Old session Arcs remain alive and are not repaired. The old machine/backend
refuses further work; a fresh guarded machine reloads durable state and keeps
the original identity keys. Unbound bootstrap/control stores keep upstream
behavior. A test-only Option helper preserves the SDK's shared integration-test
macro; production cached-account access remains fallible after invalidation.

## Original defect

The actual CryptoStoreWrapper on the reviewed protected-task source chain commits
both real Olm sessions to MemoryStore, then loses cache publication when its writer
is aborted at the backend's post-commit return gate. A following save completes,
but the cache still contains only one session. This is a confirmed defect, not a
selected correction or runtime acceptance.

```sh
cargo test --locked -p matrix-sdk-crypto --lib \
  store::crypto_store_wrapper::test::test_committed_save_cancellation_diverges_cached_sessions \
  -- --exact
```

The accepted baseline is exit 101, one exact named assertion failure, 0 passed and
1 failed. Compilation errors and setup panics do not count. The source wrapper
was restored byte-for-byte after the isolated test. The fixture's cache equality
and retained-Arc checks establish the old defect; a later safe disposal/refusal
solution may need separate acceptance tests rather than forcing cache repair.

No phone, server account, selected app, owner gate or TestFlight proof follows.
Other background crypto ownership, renewal-failure acknowledgement, fair handoff
and generated/physical NSE acceptance remain runtime-selection requirements.
