# Phone approval key and enrollment API

Package-only slice 2a; no app UI, Mac changes, push or deployment.
SecureEnclavePhoneKeyStore requires a PhoneKeyNamespace bound to owner,
installation and key generation. Persist installation/generation IDs alongside
registration metadata. Rotation creates a new generation and retains the old
approval key until the server accepts the three-signature request. Missing keys
raise setupRequired; setup must be explicit. Production has no software fallback.
Approval keys use userPresence/privateKeyUsage and passcode-set device-only
protection; every sign uses a fresh LAContext with zero reuse.

PhoneEnrollment validates the iOS enrollment shape, distinct DER SPKI keys,
key bindings, empty scopes, integer ranges and rotation proof linkage before
signing. Domain-separated sorted JSON matches frozen public iOS signature proofs.
Duplicate object members are rejected before Foundation parsing. Tests generate
software private keys at runtime; frozen fixtures contain public keys/proofs only.

NativeDomainClient provides enrollPhone, rotatePhone, listPhoneRegistrations,
and revokePhone with typed records. Registry transport uses the existing funnel
and adds only collection/UUID paths; it adds no headers. Matrix failure codes
are checked against HTTP status and preserve the server reason.

PhoneRevocationQueue takes a file under Application Support (never caches).
Create it before sign-out, call signOut with owner/id/key store and a revokePhone
closure, then discard credentials. Queue persistence failure must prevent the
caller from discarding credentials. Offline transport failure retains the queue
and deletes both local keys; deletion failure is surfaced to the caller.
On the next authenticated connection call retry for the same stable owner using
fresh credentials. A 404 is already absent; other errors retain the entry.
No bearer token or signing key is written to the queue.

Slice 2b owns screens, storing registration metadata, calling these lifecycle
hooks, and triggering retry on authenticated connectivity. Physically verify
biometrics-first/passcode fallback, cancellation, unlock-then-fresh-prompt,
missing passcode and background interruption. Slice 3 needs frozen authoritative
challenge/action schemas and cancellation-as-refusal transport; enrollment
signatures cannot substitute for approval decisions.

Verification: the prescribed TMPDIR + lockf swift test -j 2 command completed
with filter PhoneApprovalKeyTests|PhoneRegistryTransportTests: **11 passed,
zero failed**, exit 0. The build reported existing package exclude/resource
warnings and a macOS deprecation warning for the noninteractive key-existence
query. Secure Enclave authentication remains a physical-iPhone verification task.
`git diff --check` passed; local public outbound preflight passed with zero leaks. Initial scanner findings were eight
generic-api-key false positives on frozen public DER values in Swift declarations;
fixtures now hold public-only JSON. No scanner exceptions or private keys added.
Public fixture DER values are stored as hex and reconstructed before verification;
this preserves exact public proof bytes without generic API-token false positives.
Body construction is available through PhoneEnrollment.body. Existing key tags
are rejected during creation so setup cannot silently append duplicate keys.
Authentication failures after signing starts are distinct from missing-key setup;
UI/decision work must treat cancelled/authenticationFailed as refusal when the
OS prompt started, and acknowledge the server denial before showing delivery.
Registry methods use the client's existing authorization/refresh seam rather
than exposing a bearer argument to UI. A 401 refresh retries the identical signed
request once; a second 401 notifies the existing authentication observer.
Golden tests also compare key IDs against the frozen response samples. Queue
coverage includes restart/offline retry, owner isolation, corrupt storage,
persistence failure, terminal 404 and retained 403.
Input limits follow the server's UTF-16 display-name length and exact lowercase
UUID text shape; SPKI values must be canonical 91-byte P-256 DER encodings.

Recovery with a missing old approval key cannot rotate: explicitly revoke the
old owner registration, then enroll a fresh ID/generation at epoch 1. Current-phone
removal must call revokePhone before deleting both local key roles; use the durable
queue if removal/sign-out can lose network access. No stale enrollment reuse.

Superseded in slice 2b (`docs/ports/phone-approvals-2b.md`): the collection
GET now sends `Atum-Device-Service-Version: 1.3` (the server's default list is
Macs only), a capability probe sends `0.0`, and the pinned controller keys are
read from `/cloud/controller-keys`. Screens, registration storage and the
lifecycle hooks described above as 2b work are implemented there.
