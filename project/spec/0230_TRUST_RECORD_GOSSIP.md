# OUO TrustRecord Gossip v1

Status: `implemented locally / deployment opt-in`

## Purpose

A quorum decision must not exist only in the Discovery process that first
received it. D1, D2 and D3 replicate the append-only `TrustRecord` chain over a
pull protocol. HTTP is treated only as transport: every receiver validates the
record's canonical hash, exact historical authority epoch, committee,
threshold and validator signatures before storing or applying it.

## API

```text
GET /registry/trust-records/gossip?after_sequence=N&limit=100
POST /registry/trust-records/gossip
```

The response contains a local append cursor, record hash and the complete
quorum-signed record. The sequence is only a pagination hint and has no trust
meaning. A receiver never accepts a decision because a peer supplied it.

## Invariants

- a 4-of-7 record is rejected independently by every Discovery;
- records are validated against the authority set for `record.epoch`, not the
  newest committee;
- an unknown subject does not prevent ledger replication;
- if the subject registers later, the already-validated chain is projected to
  its local legacy trust state in order;
- exact replay is idempotent;
- conflicting valid records for the same subject and epoch create evidence and
  freeze the control plane while leaving the data plane available;
- peer URLs are bounded origins, redirects and environment proxies are not
  trusted, and pagination is bounded to 100 records per response and 100 pages
  per cycle.

## Runtime configuration

```text
TRUST_RECORD_GOSSIP_ENABLED=true
TRUST_RECORD_GOSSIP_PEERS=https://d2.example,https://d3.example
TRUST_RECORD_GOSSIP_INTERVAL_SECONDS=30
TRUST_RECORD_GOSSIP_TIMEOUT_SECONDS=5
```

Each Discovery must list the other independent Discovery origins. Secure env
validation requires at least two configured peers when gossip is enabled.

## Residual risks

- the pull cursor is held in memory and is rebuilt idempotently after restart;
- authenticated confidentiality of the link still depends on deployment TLS;
- promotion candidate scheduling and TrustRecord creation remain separate
  control-plane work; this protocol only replicates validated decisions;
- production operator, ASN and failure-domain diversity cannot be proven by
  this local implementation.
