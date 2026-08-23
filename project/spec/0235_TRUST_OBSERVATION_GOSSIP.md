# Assignment-bound TrustObservation Gossip v1

Status: `implemented locally`

## Purpose

An accepted ChallengeAssignment ACK is not completion evidence. Completion
requires the observer's privacy-minimized signed TrustObservation. This
protocol lets that evidence and the derived completion state survive failure of
the receiving Discovery without trusting peer telemetry.

## Portable publish

```text
POST /registry/trust-observations/portable
```

The request includes the signed observation, assignment UUID and the
root-signed observer Operational Certificate. Portable publishing is allowed
only for assignment-bound evidence. The receiver checks current suspension or
revocation state and requires the local assignment to be in `accepted` state.

## Append-only event and pull

Each verified assignment-bound observation creates one immutable event keyed
by observation UUID and `(assignment_id, observer_node_id)`:

```text
GET  /registry/trust-observations/gossip
POST /registry/trust-observations/gossip
```

The event carries a local sequence, assignment UUID, canonical observation and
hash, plus the Operational Certificate used for validation. Pull is bounded to
100 items per page and 100 pages per peer per cycle. Peer cursors are only
transport progress and may safely restart at zero.

Every receiver independently validates:

- canonical observation size and hash;
- self-certifying Operational Certificate and Operational-Key signature;
- observer membership and prior accepted ACK;
- assignment subject, challenge type and epoch linkage;
- observed/expiry windows, result and latency bucket;
- observation UUID and challenge commitment replay constraints;
- current local/Trust Ledger suspension or revocation state.

If assignment or ACK has not converged yet, ingestion fails and the peer cursor
does not advance; a later cycle retries in dependency order.

## Verified behavior

- D2 accepts assignment-bound evidence without a D1 bearer secret;
- D3 independently reconstructs `pending → accepted → completed` from signed
  assignment, ACK and observation objects;
- the eight-process loopback cluster converges D2 completion to D1 and D3;
- ordinary unassigned reliability observations remain local and are not
  incorrectly presented as scheduler completion evidence.

## Residual work

- automatic assignment scheduler, missed-job policy and signed randomness
  checkpoint are not implemented;
- scoring-policy and Security Reputation decisions remain separate work;
- production requires TLS/private overlay, rate limits and independent
  Discovery operators.
