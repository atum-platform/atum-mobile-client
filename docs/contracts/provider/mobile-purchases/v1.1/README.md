# atum.mobile-purchases/1.1 — Store acquisition text amendment

Frozen text amendment to atum.mobile-purchases/1 (5f607d7ef5395dfc9a0e706eb1c1f8d7c73f2334a418467c28c548e645b9166f); all base wire
types, messages, invariants and fixtures remain unchanged. It clarifies the base's
existing Proton-based Store acquisition for the five operations in mobile-native-api/1.1.
Direct item IAP stays outside the base's scope; the native admission amendment lifts
only mobile-native-api/1's blanket Store-route exclusion.
Store items are acquired with Protons per atum.store/1.1. On iOS Protons are sold only
through StoreKit consumables; no top-up, PayOS or VietQR affordance. Server-policy grants
are never redeemable codes (Apple3.1.1); items acquired elsewhere show on iOS because
Protons are sold by IAP (3.1.3(b)). These are the approved plan's policy requirements,
not a claim of App Review approval. No purchase CTA before d1 validation is enabled;
hires default off until the owner's legal P5 check. Future direct item IAP adds source
apple_iap in another additive Store amendment before serving it. No current schema
accepts that reserved future source. No payment validator, StoreKit client or legal
switch is implemented or enabled by this amendment. Packs are checked by
pnpm verify:store-contracts; no frozen base file was edited.
