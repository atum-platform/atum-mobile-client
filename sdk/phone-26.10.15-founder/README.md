# Phone SDK 26.10.15 — additive Founder bridge candidate

This pack is **not** the selected `26.10.15-atum.1` distribution and does not
replace `sdk/phone-26.10.15`. It is an additive source candidate at the same
upstream Rust revision and Swift distribution release:

- upstream `matrix-rust-sdk@97a1589b70bd122c1d66e0d68ea008d8554076a5`
- Swift distribution source `dbdf59e13d0eade7fd9cbd01cfd564693b85b761`
  (`26.10.15`)
- the selected app pin remains
  `cf18be30f10f0a6cea89d3aae93c6799af7edcde`; do not change it from this pack.

## What the patch adds

On top of the existing candidate patch it adds only:

1. empty-key `io.atum.founder_chat` to the exact Room List Service
   `ATUM_REQUIRED_STATE` used by both the all-rooms list and room
   subscriptions (and its exact test expectations); and
2. `Room::fetch_global_account_data_raw(event_type)`, which uses the existing
   authenticated Matrix SDK client/account API to perform a network read of
   one global account-data event. It exposes no token, URL, arbitrary HTTP
   surface or raw credential path, and leaves the cached
   `Room::account_data_raw` accessor unchanged.

The method is on `Room` because the canonical post-write reconciliation always
runs with the room just created/adopted. The exact pinned upstream
(`crates/matrix-sdk/src/account.rs:1023`) takes
`GlobalAccountDataEventType` by value and returns
`Result<Option<Raw<AnyGlobalAccountDataEventContent>>>`; the patch maps that
`Option` to `Option<String>` without unwrapping. A Rust regression covers the
`Some` and `None` boundary, and the hosted source job runs it before the Apple
artifact.

## Pending generation and build

`source.json` is now generated and committed from the exact pinned upstream
checkout. It records the real patched byte hashes for the fixed patch. The
`source.pending.json` remains the bootstrap fallback for regenerating and
verifying those hashes:

```sh
python3 scripts/prepare-matrix-sdk.py /path/to/new/patched-source \
  --manifest sdk/phone-26.10.15-founder/source.json
```

To regenerate the exact source authority from a clean upstream checkout:

```sh
python3 scripts/refresh-phone-sdk-source-pin.py \
  /path/to/matrix-rust-sdk-97a1589 \
  sdk/phone-26.10.15-founder/source.pending.json \
  --output sdk/phone-26.10.15-founder/source.json
```

The generator verifies the exact upstream revision/origin, every preimage, the
pending patch digest, applies the patch in a disposable git worktree, verifies
the changed-file set, and writes the real patched byte hashes. It performs no
network or build.

The existing builder and hosted workflow now accept this additive pack while
keeping `phone-26.10.15` as the default. On the hosted builder the exact hash
gate runs before compilation:

```sh
python3 scripts/prepare-matrix-sdk.py "$RUNNER_TEMP/atum-phone-sdk-source" \
  --pack phone-26.10.15-founder \
  --manifest sdk/phone-26.10.15-founder/source.json
python3 scripts/build-phone-matrix-sdk.py "$RUNNER_TEMP/atum-phone-sdk-source" \
  "$RUNNER_TEMP/atum-phone-sdk" --pack phone-26.10.15-founder \
  --manifest sdk/phone-26.10.15-founder/source.json
```

The workflow's `pack` input selects `phone-26.10.15-founder`; the default stays
`phone-26.10.15`. The build requires both generated markers
`accountDataRaw(eventType:` and `fetchGlobalAccountDataRaw(eventType:` and the
exact required-state test/compile gates run before the Apple artifact. Until
that artifact is built, verified and selected, the phone must continue to use
the cached marker read; do not call an uncompiled method.

## Selection boundary

This pack remains `SOURCE_PATCH_CANDIDATE_NOT_DISTRIBUTED`. It is not a binary,
has no runtime selection, and proves no cross-device Founder adoption or race
parity until the source is prepared, the Apple artifact is built from it, and a
new immutable distribution is selected and verified.
