# Export compliance

`ITSAppUsesNonExemptEncryption` is `NO` (since 2026-11-10).

Atum uses only standard, published cryptography: the Matrix end-to-end
encryption in the open-source matrix-rust-sdk (Olm and Megolm: Curve25519,
Ed25519, AES-256, HMAC-SHA-256) and HTTPS/TLS from iOS. It contains no
proprietary or non-standard algorithms.

App Store Connect only accepts export compliance documentation when an app
contains proprietary cryptography, or standard third-party cryptography *and*
is distributed on the French App Store. Neither applies, so no documentation or
`ITSEncryptionExportComplianceCode` exists. The previous `YES` without a code
made App Store Connect refuse uploads ("Invalid Export Compliance Code").
Element X, which uses the same SDK, ships the same `NO` value.

Obligations that remain with the publisher:

- **France:** keep the app off the French App Store until a French encryption
  declaration is filed; then set the key to `YES` with the issued code.
- **United States:** mass-market encryption (ECCN 5D992.c) needs the annual
  self-classification report to BIS and the NSA encryption request coordinator
  (due 1 February for the previous calendar year).
- Revisit this file if any proprietary or non-standard cryptography is added.
