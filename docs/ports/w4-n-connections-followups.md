# W4-N Connections follow-ups

## Decoder parity

The Connections registry now uses the same UTF-16 label limits as the desktop's
`apps/desktop/shared/account-connections.ts`. A model name can use up to 200
code units and a device name up to 128. An astral character uses two. The
`observedAt` field accepts integral JSON numbers such as `1.0` between zero
and JavaScript's maximum safe integer.

`AccountConnectionsTests` covers astral names at and above both limits and
integral decimals at the safe integer boundary. It also checks that fractional,
out-of-range, boolean, and string values are rejected.
