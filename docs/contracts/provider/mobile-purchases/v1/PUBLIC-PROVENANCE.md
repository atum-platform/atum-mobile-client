# Public d1 contract subset

Owner decision: 2026-11-10. This public directory includes the upstream
`README.md` and `contract.json` byte-for-byte, not the fixture pack.
The upstream README records historical decisions; the final pack decisions and
current integration limits are in `docs/implementation/mobile-purchases-phase1.md`.

- Source: `atum-platform/atum-platform`, `spec/mobile-purchases/v1/`, at
  `7df04652c7c1ce39f757891e01e0d14951db31bb`.
- Upstream full-pack SHA-256:
  `5f607d7ef5395dfc9a0e706eb1c1f8d7c73f2334a418467c28c548e645b9166f`.
- Full-pack verification and all original d1 fixture files remain in the private
  `atum-mobile` repository. This public repository cannot verify the full-pack
  digest because it intentionally does not contain those files.
- `PINNED-SHA256` is a public-subset checksum manifest: SHA-256 of the exact bytes
  of each named public contract file, not the upstream full-pack digest.
  Run `python3 scripts/verify-native-purchase-contract.py` from the repository root.
- The upstream `pack_files` and `fixtures` lists in `contract.json` describe the
  private pack; they are retained as contract text, not public file requirements.
- Public tests build the 24 d1 acceptance cases in Swift using plainly fake
  payloads and account tokens. They do not encode or project private fixtures.
  Server facts and state sequences are contract examples, not server validation
  or payment evidence.
