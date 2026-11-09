# `atum.agent-home/2.5`

This minimal amendment authorizes the four owner writes with the authenticated MAS bearer and its derived phone or desktop surface, matching every other owner action. The accepted bearer-only metadata is exactly requestId, surface and authenticatedChannel. A retry of one logical operation reuses both requestId and the operation idempotency key; authentication metadata is excluded from effect identity, while a changed effect conflicts.

An owner_client signature is optional, never ignored. When present, its complete 2.4 metadata is verified under the inherited device-service/3 domain against an ACTIVE enrolled device-service identity key belonging to the same bearer owner. Unknown, revoked, other-owner and invalid keys refuse as bad_signature; an invalid signing window refuses as signature_expired.

Desktop keeps signing with its enrolled Mac identity key. Phone sends the bearer-only metadata and owns no new key. The deferred safeguard is an owner-key binding for bearer-only writes once a phone owner-key enrollment, rotation and recovery lifecycle exists; 2.5 deliberately adds none of that machinery.

Cloud placement bootstraps selectedGeneration from the exact committed cloud HomeStore generation. A move-drain checkpoint names that selected generation as its parent; its committed generation is the portable lineage and the move commit's selected generation. Catalogs use N/null outside a move; only the target republishes N+1/moveId during a move, while every other Mac remains N/null. Freshness is an admission check, not a long-move commit timeout.

The accepted preflight freezes conversationOverrideCount. The participant clears that disclosed count before commit. clearConversationOverrides is not part of home.move.commit and must not be sent as an extra commit field.

Every 2.4 fixture remains byte-identical.
