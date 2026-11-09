# Atomic crypto writer experiment

This additive Apache-2.0 experiment is separate from the verified custody
candidate, its Apple library and the installed phone app. It is not selected
as an application runtime and is not integrated into Olm or SlidingSync.

The unchanged SDK permits a retained raw SQLite writer to overwrite another
owner's state after a real SDK lease handoff. The baseline regression fails at
that behavioral assertion. The prototype gives each SDK guard an immutable
key/holder/generation snapshot. `SqliteCryptoStore.with_lease` creates an
explicitly bound writer clone. Clones retain their epoch and cannot rebind or
acquire a lease. Single-process and unrelated lock guards cannot bind it.

Every runtime crypto mutation on that clone enters an Immediate transaction,
checks the current lease's key, holder, generation and expiration, then writes
and commits in the same transaction. Competing lease acquisition cannot enter
between the check and commit. Both checks and acquisitions calculate the time
after obtaining the database transaction. Refusal returns a fixed typed error.
Static account data is published only after the account transaction commits.
Database worker interruption returns a fixed error without retaining its cause.
BaseClient and the backend use one shared SDK crypto lock-key constant; the
generation filter uses the SDK's named first-generation constant.
No migration, schema, dependency, app lock or lease duration changes.

The raw store remains usable for bootstrap, migrations and lease control. This
is an opt-in backend primitive; raw SDK handles are not automatically protected.
The caller must acquire the guard through the same store's SDK crypto lock and
keep it alive through the operation. A guard does not itself identify a database.
Reads and upper-layer caches are not fenced. On refusal, the eventual integration
must discard the owning Olm client and its caches.

The nine focused tests use disposable encrypted SQLite, actual SDK guards and
independent store connections. They check successor-data and original-key
preservation, all mutation entry points, cache publication, guard clones and
renewal, expiry without a successor, invalid binding, and A→B→A generation
changes. A test adapter stops renewal to model lost heartbeat while retaining a
guard; this is not operating-system suspension evidence. Another test holds a
protected transaction past expiry: real peer lease acquisition returns SQLite
Busy, then succeeds after commit. Its marker uses the actual store cipher.
No lease rows, keys or account state are repaired through SQL.
Non-empty inbound saves and backup mutations preserve the successor's sessions,
backup flags, batch state and original keys after refusal. A worker-panic test
checks error return and rollback using an independently reopened encrypted store.
The transaction commits after expiry in the deliberate long-transaction test;
the peer cannot take ownership before commit. Production closures are synchronous
and should remain short. Pure expiry without takeover is not a commit-time fence.

Reproduce the baseline refusal and all green checks:

```sh
python3 scripts/study-sqlite-lease-fence.py /tmp/atum-lease-fence-replay.json \
  --source-cache /path/to/pinned-official-sdk-checkout \
  --cargo /path/to/rust-1.96.0/bin/cargo \
  --target-dir /tmp/atum-lease-fence-replay-target
```

The runner verifies the unchanged custody manifest, additive preimages, patch,
prototype files and Apache notice. It requires the exact baseline failure,
nine focused passes, existing SQLite regression passes and all named SDK lock
tests. Private build logs and disposable source/store directories are removed;
the receipt contains hashes, commands, counts and limitations. Compilation or
test failure cannot create a passing receipt.
Each command must return exactly one test summary. Full SQLite suite counts are
observations; its single `--lib` run must pass all tests. The collector verifies
all nine focused cases and all five named lock cases individually.

Dependent work remains: forward binding through the erased store interface,
bind each old Olm instance to its immutable epoch, move wrapper session-cache
publication after successful persistence, protect outgoing/detached tasks and
shared sync acknowledgements, and implement fair foreground/NSE handoff. Then
repeat the actual three-process generated-Swift and physical notification proofs.
This experiment does not decrypt a notification or satisfy Gate 2.
