# atum.mobile-native-api/1.1 — additive Store admission

Frozen additive amendment to atum.mobile-native-api/1 (c651192fd0b9042628c47f370b23958437a04d847cf033ed6cd34956e7c32bfd).
Every base type/message/direction/invariant/machine/route is retained and every fixture
is carried byte for byte. This supersedes only the base README§7 blanket /store/*
exclusion. It does not deploy routes or broaden authentication, scopes or custody.

Under the existing native domain grant (bearer, no cookie/Origin) admit:

| Operation | Request | Response |
|---|---|---|
| GET /store/catalog | none | atum.store/1.1 catalog.response |
| GET /store/entitlements | none | atum.store/1.1 entitlements.response |
| GET /store/purchases | none | atum.store/1.1 purchases.response |
| POST /store/purchases | atum.store/1.1 purchase.request, UUID Idempotency-Key header | atum.store/1.1 purchase.result |
| POST /store/entitlements/{id}/cancel | {} | atum.store/1.1 cancel.result |

Routes share /api/matrix/v1 base and the account derived by the existing authority;
the client never supplies principal/payer/price. The Store capability header describes
only what the phone actually delivers. Never declare agents.schedules.1 on iOS.
Excluded: all /store/topups and /store/tasks operations (tasks are desktop execution
bindings). The separately frozen mobile-purchases/1 Apple validation routes retain
their own admission and are unaffected by those exclusions. No PayOS/VietQR UI on iOS.
The acquisition amendment mobile-purchases/1.1 keeps purchase CTA off until d1 validation
and hires off until legal P5. This is the mobile handoff contract, not runtime admission
or purchase enablement. Vendors pin this directory and Store1.1 by digest and run the
same fixtures through real consumers. Check with pnpm verify:store-contracts.
