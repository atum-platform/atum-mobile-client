# `atum.mobile-drive/1` — native iPhone Drive provider contract

This pack freezes the provider boundary for Atum's proprietary iPhone Drive
client. It does not embed or copy the GPL OpenCloud iOS SDK. The future phone
consumer uses its existing OIDC/Keychain implementation plus a narrow
`URLSession` client for the production Drive origin.

This source outcome adds no phone UI, upload path, database migration,
production configuration change, deployment or release. It depends on the
already-frozen [`atum.drive-identity/2`](../../drive-identity/v2/README.md) and
[`atum.mobile-native-api/1`](../../mobile-native-api/v1/README.md) packs.

## 1. Three grants, one callback, separate authority

The phone keeps its existing Matrix and account/domain grants. Drive adds a
third static public MAS client:

- client ID `01M4SYXQ8KGGTZFVC9F484ZAA6`;
- name `Atum for iPhone (Drive)`;
- `client_auth_method: none`, PKCE `S256`, state and nonce;
- scope exactly `openid` (MAS still returns a rotating refresh token);
- redirect exactly `https://api.atumplatform.com/oauth/ios/callback`.

The shared HTTPS callback is transport only. Each flow owns a distinct state,
nonce, verifier, client ID and refresh chain. A code or refresh token is never
retried through another client. Revoking Drive leaves chat/account grants
unchanged, and vice versa.

The iOS account/domain bearer calls `POST /api/matrix/v1/drive/account` with an
empty JSON object. The answer is only `{state, serverUrl}`. It never returns a
MAS subject, principal, OpenCloud user ID or personal-space ID. A Drive bearer
is accepted only at `serverUrl`; the domain bearer is deliberately `wrong_client`
there.

## 2. First read-only vertical slice

After the account answer is `active`, the Drive bearer uses these existing,
default-deny ingress routes:

1. `GET /graph/v1.0/me/drives` and select exactly one `driveType=personal`.
   The returned ID is provider metadata, not authorization: the ingress still
   compares every named space/file with the server-side mapping.
2. List root or folder children with the read-only Graph children route. An
   optional `@odata.nextLink` is followed only after replacing/confirming its
   origin with `serverUrl` and re-validating the same allowed path. Each
   successful provider page becomes one `ios.drive_page`; an error never
   becomes an empty page.
3. Download a file from its same-origin `webDavUrl` with `GET`/`HEAD`, optional
   `Range` and conditional ETag headers. Bytes go to a temporary file, are
   length/ETag checked, then atomically replace the account-scoped cache entry.

`etag` is the first-slice version. Historical versions, uploads, TUS, COPY,
MOVE, delete, sharing, public links and offline edits are out of scope.

## 3. Cache and failure states for the future consumer

The phone paints its last complete account-scoped listing immediately. A
refresh is staged separately and replaces a page only after a complete valid
answer. Offline/provider failure keeps the last-good page marked stale. An
uncached file needs connectivity; a retained file opens from the cache.

The closed provider states are:

| Provider result | Phone action |
|---|---|
| `401` (`inactive`, `expired`, `wrong_client`, `wrong_scope`, `wrong_issuer`) | One same-client refresh and one retry; then Drive reauthentication. Never fall back to Matrix/domain credentials. |
| `403` (`not_allowed`, `not_provisioned`, `not_human`, `suspended`, `not_owner`, `route_not_allowed`, `public_links_disabled`) | Stop automatic retries and show the bounded denied/unavailable state. |
| `503 provisioning` + `Retry-After` | Preserve cache and retry with the server delay. |
| `503 provider_unavailable` or network loss | Preserve cache, mark stale/offline, bounded backoff. |
| `404` on a current file | Re-list its parent; never erase unrelated cached entries. |
| malformed/oversized provider bytes | Preserve cache and fail the refresh. |

Sign-out/account replacement synchronously withdraws every handle and cache key
for the outgoing `(issuer, subject, principal)` before asynchronous deletion.
Tokens remain device-only Keychain material and never appear in this contract.

## 4. Rollout and rollback

`ATUM_DRIVE_IOS_CLIENT_ID` is an explicit ingress kill switch. When absent, the
new ingress continues serving the desktop client and returns `wrong_client` to
phone Drive tokens. Registration is append-only; rollback restores MAS
`config.yaml` and deletes the now-absent static client row because MAS config
sync does not prune. A token issued before rollback is revoked through MAS.

Source/deployment order is: merge reviewed source; register the public client;
set the ingress ID and deploy the reviewed ingress together; run the disposable
real-MAS/OpenCloud proof; only then hand the exact client ID and pinned pack to
the mobile repository. Production application remains a separately authorized
operation.

## 5. Acceptance

Provider conformance proves desktop and iPhone Drive tokens independently reach
the same owner's space; Matrix/domain/browser/dynamic clients remain
`wrong_client`; two synthetic humans remain isolated; first-connect provisioning,
refresh rotation, revocation, Graph listing, WebDAV conditional/range download,
and error-as-empty refusal run against the disposable real MAS/OpenCloud stack.
The later phone slice additionally proves cold offline relaunch, retained-file
open, interrupted download, account A→B, and no Mac/agent executor running.
