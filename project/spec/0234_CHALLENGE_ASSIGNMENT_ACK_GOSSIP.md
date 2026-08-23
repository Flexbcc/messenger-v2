# ChallengeAssignment ACK Gossip v1

Status: `implemented locally`

## Purpose

A signed observer acknowledgement must survive failure of the Discovery that
received it. Assignment gossip (`0232`) distributes the immutable quorum
assignment; this protocol distributes the observer's signed decision without
trusting the HTTP peer.

## Append-only event

Every accepted ACK creates one immutable local event keyed by:

```text
(assignment_id, observer_node_id)
```

The event contains:

- monotonically increasing local sequence;
- canonical ACK and its SHA-256 hash;
- root-signed Operational Certificate used to verify the ACK;
- local storage time.

A second byte-identical event is idempotent. A different event for the same
assignment and observer is rejected with `409`.

## Pull replication

```text
GET  /registry/challenge-assignment-acks/gossip
POST /registry/challenge-assignment-acks/gossip
```

Pull uses independent per-peer cursors, pages of at most 100 events and at most
100 pages per cycle. Peer URLs are fixed origins without credentials,
redirects, query strings or fragments. Cursors are only transport progress;
after restart replay starts from zero and remains idempotent.

The receiver requires the corresponding locally verified quorum assignment,
then independently validates:

- ACK hash and canonical size bound;
- self-certifying Operational Certificate and NodeID;
- observer membership in the assignment;
- ACK time window, decision and Operational-Key signature;
- current local/Trust Ledger suspension or revocation state.

An ACK arriving before its assignment is not accepted; the peer cursor is not
advanced, so a later cycle can retry after assignment convergence.

## Verified behavior

- independent D3 accepts an ACK created on D2 only after verifying the D1
  quorum assignment and observer credential;
- background bounded pull applies the signed ACK;
- the eight-process loopback cluster converges a D2 portable ACK to D1 and D3;
- duplicate replay is idempotent and conflicting observer state fails closed.

## Residual work

- signed TrustObservation/completion replication is defined by `0235`;
- production deployment still requires TLS/private overlay, rate limits and
  independent Discovery operators;
- Root revocation completeness depends on TrustRecord convergence.
