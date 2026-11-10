# atum.store/1.1 — capability-gated additive Store contract

Plan2 ST-0. Base: atum.store/1, digest 21797ed1d33b1f9fa558e16809f0c5846d8ba9f58b73ee804a535c5f661c0c83. All base schemas and
fixtures are retained; new public keys are optional. The conformance test proves accepted
public wire fixtures still parse with the verbatim installed v0.18.2 validator and that
stripping ownership/source/deliverable/install yields the same valid baseline projection.
Internal assertion/readiness and ownership/header test cases are separate messages, not
desktop API responses. Rejected new metadata may be stripped by an old parser; it is
the capability-aware provider's responsibility to reject it. Runtime code lands in ST-1+.

## Capabilities and projection

Atum-Store-Capabilities applies to every /api/matrix/v1/store/* request. Tokens match
^[a-z][a-z0-9-]*([.][a-z0-9-]+)*[.][0-9]{1,3}$, maximum16 tokens and256 UTF-8 bytes.
Trim surrounding token whitespace; drop unknown tokens, deduplicate and sort. A malformed,
over-length or over-count header is absent, never a client error. Count tokens before
deduplication. An effective empty set uses the no-capability baseline, not declared delivery.
Known tokens: store.ownership.1, skills.prefix.1, agents.schedules.1, skills.hub.1, pets.art.2.
Reserved only, not accepted yet: agents.schedules.cloud.1, pets.package.1.
No-capability clients receive the unchanged v1 projection: no install/Hub items, ownership,
deliverable/source additions or requires-gated items; pets still have assistantId:null.
The existing 0.18.3 compiled delivery constant is their default. Narrow that default only
after <2% requests for14 days and two weeks of0.18.4 as the auto-update target (owner D-3).

An internal item requires array never reaches a public response. Shell hides items missing
any requirement; Marketplace refuses purchase offer_unavailable durably before any hold.
Capabilities widen understanding only, never delivery readiness, ownership, review or price.
store.ownership.1 admits ownership/source/deliverable. skills.hub.1 admits install:hermes_hub
on free skill items with offer:null; this does not add a delivery enum. Skills Hub performs
its existing scan and confirmation; no entitlement/grant/order is written for installation.
skills.prefix.1 and agents.schedules.1 denote actual Mac delivery; iOS never claims a Mac
schedule capability. No-capability clients never see these newly gated listings.

## Ownership and grants

Marketplace already_owned is authoritative and prevents holds; projection is display only.
Pets are account-owned (assistantIds:[]); skills and hires are per-assistant. Permanent
grant sources are gift (rollout_gift), compensation and promo; purchased is source:purchase.
Grant policy permits pets only, never pet/hatch*; no grant HTTP route or redeemable code.
Visits stay in Supabase and are never entitlements; visiting Gigi remains purchasable.
An active entitlement takes precedence over a visit. Failed pet display reads omit visiting
while preserving the catalog; purchase ownership checks fail closed. Old Shell absence of
ownership invokes the client's current entitlement fallback. ST-3/ST-4 backfill and verify
exact existing gifts before deleting synthetic gifts; no rollout expansion is permitted.
ownership.case fixtures are future projectOwnership conformance vectors, not a new runtime
implementation. Invalid reads are errors, never empty ownership; grants are not expires-at
rows and expiry is not an index predicate. Every gifted pet must remain owned across art
revisions; relisting preserves SKU, uses a new immutable offer version and needs owner go.

## Signed assertion and readiness

Shell emits the existing eight claims when effective caps are empty; otherwise emits a
ninth caps claim containing sorted unique valid known tokens. HMAC covers caps as part of
the unchanged base64url JSON payload, lifetime30s, no extra claims accepted. Deploy an
8-or-9-claim Marketplace verifier before Shell starts sending caps. This pack's claim data
does not itself implement verification; ST-1 proves signature tamper/expiry and mirror parity.
Shell logs only store_request caps=none|declared; no principal/header values or content.

Gateway GET /store/ready returns {body:{mode:"on"|"off",at:epoch_seconds},signature:hex}.
HMAC-SHA256 uses the existing Store service key over UTF-8
"atum.store-ready/1\0" followed by JSON.stringify({mode,at}) in that key order.
At most5s future skew; expired at at+120s. Cache for60s and never reuse an on sample
past signed expiry. Unreachable, unsigned, bad signature, expired or off fails closed:
paid skill/agent purchase refuses offer_unavailable before any hold/order. Pets unaffected.
ST-2 confirms network reachability or uses the same signed push envelope if necessary,
adds the failure alarm and exercises the real refusal and cache paths.
Readiness fixtures carry synthetic signature bytes for shape validation only; they are
not valid HMAC samples. ST-2 must generate and verify signatures with a test-only key.

## Paid execution binding — cloud join

ATUM_STORE_CLOUD_DELIVERY defaults off. An assistant with active paid skill/agent content
stays mac_only while off. Turning it on is insufficient without live store/tasks binding
evidence scoped to the principal, assistant and invocation. Cloud executor obtains the
protected revision through the broker and passes X-Atum-Store-* binding on every model call:
one hold per call, no unprotected fallback. A-PLAT owns DA admission and SQL binding,
A-APP owns controller/broker wiring; ST-11 supplies the helper/fake-controller test.
Prove an entitled cloud turn on H2 before owner flag flip and before cloud C0. Future
agents.schedules.cloud.1 remains reserved until C-MIG proves its conversion path.

## iOS and rollout

mobile-purchases/1.1 governs Store acquisition; mobile-native-api/1.1 admits the five Store
operations and keeps topups/tasks excluded. Protons are bought by StoreKit consumables
only on iOS; no PayOS/VietQR/top-up affordance, no redeemable grant code. No purchase CTA
before d1 validation; hires default off until legal P5. This frozen contract does not
authorize production deployment, migration apply, publication, grant, relist or price.
