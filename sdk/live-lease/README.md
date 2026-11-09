# Live SDK lease source checkpoint

Apache-2.0 source study, additive to `sdk/lease-binding`, with immutable preimage,
prototype, fixture and patch hashes in `source.json`. This is **not selected** by
the mobile SDK manifest or consumer build. Preserve `LICENSE` and upstream notices.

BaseClient activation and SDK acquisitions share one crypto lock controller.
Scoped SQLite construction binds the Olm store before bootstrap or generation
maintenance writes. Fresh epochs replace the machine; reentrant acquisitions
retain it. Old machines and Store/Deref clones retain their immutable fence.
Original identity is required after first construction. An activated raw SQLite
client cannot later enable multi-process and leave escaped raw clones unfenced.
In-process notification children share the controller, machine and epoch metadata.
The epoch metadata is only a reuse hint; the bound store validates actual writes
atomically and does not retain a guard or adopt that metadata's future value.

OAuth refresh coordination uses the existing independent lock namespace and fixed
session-hash key through narrow BaseClient methods. It does not use a bound Olm
store to acquire a second namespace's lease and exposes no general raw store.
Existing authoritative token callbacks and their privacy semantics remain required.
OAuth hash operations retain their prior manager-guard behavior; this checkpoint
does not add transactional expiry fencing to that separate control namespace.

CryptoStoreWrapper serializes save_changes from persistence through cache and
broadcast publication, preventing a delayed own-device cache clear from overtaking
a later session commit. Readers do not take this mutex. Its actual MemoryStore
fixture gates a successful first commit and uses real Olm sessions; the baseline
must fail because a later save enters persistence before the earlier publication.

Replay from a verified custody source cache:

```sh
python3 scripts/study-sdk-live-lease.py ./artifacts/local-check.json \
  --source-cache /absolute/path/to/verified/custody-source \
  --cargo /absolute/path/to/Rust-1.96.0/bin/cargo \
  --target-dir /absolute/path/to/owned/build-cache
```

The collector verifies the custody/fence/binding chain, runs two exact behavioral
red baselines, then synthetic encrypted-SQLite live A→B→A and SDK maintenance,
existing-device/OAuth, real-session publication and crypto regression checks.
It also checks SDK without E2EE and BaseClient's sticky/X.509 feature branch.
Temporary logs/stores stay private and are removed; retained evidence contains
counts, exact inputs and hashes. No server account, signing key or personal data.

Remaining before consumer selection: protected outgoing and detached-task guard
ownership, cancellation between committed persistence and publication, stale-read
and local-ratchet disposal, sync acknowledgement ordering, fair foreground/NSE
handoff, generated bindings, genuine simultaneous three-process decryption and
physical notification proof. Existing outer sync guards stay unchanged. No longer
lease, shared holder, app-owned lock, SQL repair or injected room key substitutes
for those checks. No owner gate, Apple action or TestFlight upload is authorized
by this source result.

Retained-review evidence closure is replayable without changing the source pack:

```sh
python3 scripts/check-sdk-live-review.py ./artifacts/local-check.json \
  --sdk-source /absolute/path/to/verified/live-source \
  --target-dir /absolute/path/to/owned/build-cache \
  --cargo /absolute/path/to/Rust-1.96.0/bin/cargo
```

It overlays all four source manifests before running the separate two-case review
fixture, checks exact test names, re-verifies inputs and removes the fixture. The
source proof covers same-store wrong-key refusal and renewal after nested guard
drop. The targeted context also freezes the actual private session-cache callers;
reader vector locks are released before persistence. No app selection follows.

Targeted review: F2/F3 resolved by twice-green execution and exact source; F1 has
no reachable reverse lock edge in the supplied private caller set. Its five
unchanged source files are frozen in review contexts but absent from the replay
pin map; retain that whole-source coverage limitation before final selection.
Final source-retention verdict SHIP, no confirmed blocking behavior finding.
Cancellation/task ownership and the other remaining acceptance above stay open.
