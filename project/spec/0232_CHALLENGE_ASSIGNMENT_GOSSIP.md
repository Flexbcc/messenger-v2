# ChallengeAssignment Gossip v1

Status: `implemented locally / deployment opt-in`

## Purpose

A quorum-issued synthetic challenge must remain discoverable if the Discovery
that first accepted it fails. D1, D2 and D3 therefore replicate the immutable
signed `ChallengeAssignment` object using bounded pull gossip.

## Security rules

- HTTP is only transport; every replica recomputes the canonical assignment
  hash and verifies the validator quorum;
- validation uses the exact historical Authority set for `assignment.epoch`;
- assignment replication may precede local subject/observer registration;
- authenticated observer pull remains unavailable until that observer has a
  valid local Node Identity/credential;
- exact replay is idempotent;
- two valid assignments for the same `(subject, challenge_type, epoch)` freeze
  the control plane and leave the data plane available;
- pagination is limited to 100 items and 100 pages per peer cycle;
- redirects, URL credentials and environment proxies are not trusted.

## API and runtime

```text
GET /registry/challenge-assignments/gossip?after_sequence=N&limit=100
POST /registry/challenge-assignments/gossip

CHALLENGE_ASSIGNMENT_GOSSIP_ENABLED=true
CHALLENGE_ASSIGNMENT_GOSSIP_PEERS=https://d2.example,https://d3.example
CHALLENGE_ASSIGNMENT_GOSSIP_INTERVAL_SECONDS=30
CHALLENGE_ASSIGNMENT_GOSSIP_TIMEOUT_SECONDS=5
```

The sequence is a local pagination cursor, not a signed or trusted protocol
field. After restart a replica can replay from zero; persistence is idempotent.

## Verified behavior

- three independent Discovery DBs converge on the same 5-of-7 assignment;
- a replica stores it before participants register and exposes it after their
  valid local registration;
- background pull D1→D2/D3 is exercised by the eight-process loopback cluster;
- conflicting quorum gossip activates Safe Mode.

## Residual work

Portable observer pull/ACK authentication is defined by `0233`.
Signed ACK replication is defined separately by `0234`.
`ChallengeAssignmentAck` and completion `TrustObservation` state are still
local to the receiving Discovery. Their replication must not turn reliability
evidence into a route/user metadata ledger. Quorum randomness checkpoint
generation and missed-job penalty policy also remain separate work.
