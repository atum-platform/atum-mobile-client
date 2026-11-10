# `atum.company-private-cos/1`

Status: frozen T5 contract for one private Chief of Staff per active
`(companyPrincipal, memberPrincipal, membershipIncarnation)`.

This pack extends existing Company AI authority, company-wallet reservation,
encrypted agent-home custody, serialized home writers and native Hermes
execution. It does not create a second agent loop, a human-DM exception, a new
core tool, a personal funding fallback or a new price.

## Identity and lazy creation

The logical pair is `(companyPrincipal, memberPrincipal)`. Each join has a new
immutable `membershipIncarnation`. A view is `uncreated` until an authenticated
member opens the reserved Chief of Staff DM row or reaches the explicitly
supported first-company-visit admission. Sidebar rendering, roster loading and
search never provision resources. The ensure request carries no member, payer,
room, home, agent or executor selector; the platform derives them.

The active incarnation owns one distinct Matrix agent, private invite-only
room, executor and encrypted home. The member and that pair's agent are the
only audience. A company switch or authority loss must discard late ensure
results rather than reclassify this room as Personal.

Native client routes:

- `GET /api/matrix/v1/companies/{companyId}/private-cos` reads only.
- `POST /api/matrix/v1/companies/{companyId}/private-cos` accepts the frozen
  ensure request and is the only provisioning entrypoint in this slice.
- `GET /api/matrix/v1/companies/{companyId}/private-cos/runs/{runId}/receipt`
  returns the requesting member's receipt.
- `GET /api/matrix/v1/companies/{companyId}/private-cos/spend` returns admin
  financial aggregates without private content.

## Greeting and lifecycle

Join records a cheap greeting intent, not a room or home. The first admitted
visit/open ensures the pair and publishes that intent with one deterministic
outbox transaction. Replay returns the same published record;
`publicationCount` remains exactly one.

Membership loss immediately retires the incarnation: access is denied,
sessions are revoked, schedules are disabled, and intake/model/tools/home
writes/outbox are fenced. Rejoining creates a fresh incarnation in `uncreated`
state. The previous room binding is tombstoned, and its home, memory and
schedules are never restored.

Private home and memory are deleted exactly 30 days after retirement. Launch
offers no user export. Financial receipts are held in the finance ledger and
are not deleted with the private home. Matrix plaintext already delivered to a
client remains outside this server-home purge guarantee.

## Restricted native Hermes boundary

The controller must present `capability: company_private_cos`, the exact pair
scope and `profile: company_private_cos_restricted` before starting native
Hermes `prompt.submit`. Only the scoped private home is mounted. The launch
profile has no inherited personal mount, grant or tool, no shell/network,
background review, schedule or company-source retrieval. Existing shared
company grants and malformed/missing profiles remain refused by the executor.

Every private run reserves from `company_wallet` under the existing model
tariff. The company daily cap and finite member-private cap both apply. There
is no member-wallet debit, personal fallback, automatic top-up or separate
private-DM price.

Cross-member admission is fail-closed before opening the home, issuing a grant
or starting the model. Owner receipts may correlate run/home/outbox state for
that member. Admin views contain only daily per-member financial totals and
closed operational categories—never prompt, answer, source names/IDs, room or
event IDs, task titles, tool data or reasoning.

## Downstream ownership

- **P-T5** consumes pair/incarnation, lazy ensure, home/retirement/purge,
  company-wallet reservation and owner/admin receipt shapes in migration 0377
  and narrow platform RPCs.
- **C-T5** consumes the scoped binding, restricted executor profile,
  cross-member refusal, greeting outbox and authority epochs at every
  intake/model/tool/home/outbox boundary.
- **A-T5** consumes capability negotiation, `uncreated|preparing|ready`, lazy
  ensure, deterministic greeting state, owner receipt and immediate denial so
  it can render the second Team Space DM row without inventing a human DM.

No consumer may widen these fixtures by accepting selectors or content fields
that this pack refuses.
