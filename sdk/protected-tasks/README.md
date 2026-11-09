# SDK protected operation source study

This pack follows custody → lease-fence → lease-binding → live-lease on the
official Apache-2.0 Rust SDK revision pinned in source.json. It is an isolated
source correction for replay and review. It is **not selected by the mobile app**.
Keep the upstream LICENSE and notices.

Actual outgoing E2EE work owns an SDK crypto-store guard through request creation,
HTTP and crypto acknowledgement. The deliberately detached sliding-sync response
task owns another acquired guard through processing and position persistence,
including room-only sync: its position is also stored in the crypto database.
Cancellation of the waiting caller cannot drop the detached task's guard.
Same-epoch machine binding uses a read lock and rechecks under the write lock
only when replacement is needed; existing HTTP paths can retain a machine reader.
No-op reuse is a cache decision, not write authority. Every protected store write
still checks the immutable identity and live expiration transactionally.

The five-test fixture uses actual Client/SlidingSync requests, real keys/upload
acknowledgement, event-handler cancellation barriers and disposable encrypted
SQLite stores. A separate BaseClient test retains a real machine reader during
same-epoch binding. No server accounts, phone data or real tokens are used.
The collector requires all five original-source assertions to fail before all
five corrected tests pass, then checks existing-device, A/B/A binding, retained
review regressions and feature compatibility. Twelve unchanged lease, response,
cache and caller files are included in the replay's source hash map.

```sh
python3 scripts/study-sdk-protected-tasks.py ./artifacts/local-check.json \
  --source-cache /absolute/path/to/official/custody-source-cache \
  --cargo /absolute/path/to/1.96.0/bin/cargo \
  --target-dir /absolute/path/to/owned/build-cache
```