# `atum.company-private-cos/1.1`

Additive asynchronous ensure response for P-T5. The frozen v1 ensure response
still means the full Matrix agent, room, executor and home binding already
exists. When provisioning is merely queued, the platform answers HTTP 202 with
this explicit schemaVersion 2 profile and a stable operation ID. Consumers must
poll GET with `Atum-Company-Wire: 1.1`; they must not fabricate a v1 preparing
binding. The v1.1 capability advertises both profiles and the required
header/value. A v1 caller receives a valid bound v1 response or HTTP 426
`update_required`.
