# Phone SDK 26.10.15 source patch

This is an isolated Apache-2.0 source pack for the LC4 phone
upgrade. It does not replace or rebase `sdk/custody`; that historical 26.10.02
authority and every descendant digest chain remain immutable.

The patch is deliberately narrow:

- add only empty-key `io.atum.conversation` and `io.atum.app_bot.dm` to both
  Room List Service required-state paths;
- expose one cached, read-only generic `Room.accountDataRaw(eventType:)` FFI
  accessor, with no setter, observer, token or network escape hatch; and
- classify reverse-proxy HTTP 520 through 529 as transient so a Cloudflare
  failure preserves queue order and resumes through the SDK's normal retry
  mechanism.

Prepare a fresh source tree with:

```sh
python3 scripts/prepare-matrix-sdk.py /new/private/source \
  --pack phone-26.10.15
```

The manifest checks the exact upstream revision, every changed preimage and
post-patch byte, patch digest and Apache licence. Preparation proves source
custody only. It does not compile Rust/Swift, publish a binary, select the app's
SPM dependency, migrate an encrypted store, sign an archive or authorize a
release.

## Selection gate

`.highEntropyPassphrase` is intentionally not enabled by this source patch.
That one-way store migration requires its own preparatory reader/refusal release
and recovery-first rollback proof before any live store is opened with it.
