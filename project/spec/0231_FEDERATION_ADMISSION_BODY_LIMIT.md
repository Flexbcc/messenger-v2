# Federation Admission and Body Bound v1

Status: `implemented locally`

## Security problem

The previous signed HTTP dependency called `request.body()` before checking the
sender. An anonymous client could therefore force allocation and hashing of an
unbounded body even when federation headers were missing or the NodeID was
unknown.

## Validation order

Signed Home/Relay/Storage federation now has two admission layers:

```text
ASGI header presence/shape + declared body-size check
→ ASGI bounded streaming body (before/until FastAPI parsing)
→ UUID/timestamp window + one bounded anonymous token bucket
→ trusted NodeID lookup + per-node rate/capability check
→ signature verification
→ nonce persistence
→ application handling
```

Malformed signed requests are rejected before body streaming. Unknown nodes
are rejected before application crypto; their framework-level parsed input is
strictly bounded by the ASGI limit. A missing `Content-Length` does not bypass
the bound: streamed chunks are counted and rejected as soon as the configured
budget is exceeded.

## Bound

`FEDERATION_MAX_BODY_BYTES` defaults to 1 MiB and is restricted to 1 KiB–16
MiB at startup. OUO v1 federation carries text/control envelopes; large media
objects are out of scope.

## Tests

- 1,000 malformed requests invoke neither body read, trust lookup nor crypto;
- a well-shaped unknown NodeID is denied before reading its body stream;
- an over-limit chunked request reaches neither signature verification nor
  nonce persistence;
- existing signed request, replay and live federation tests remain green.

## Residual limits

This prevents application-layer allocation/crypto amplification. It cannot
protect a physical uplink from a larger volumetric attack and does not replace
reverse-proxy connection limits, QUIC Retry/address validation or external
anti-DDoS capacity.
