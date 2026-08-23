# Portable Observer Authentication v1

Status: `implemented locally`

## Problem

The original ChallengeAssignment pull used a bearer token issued by one
Discovery. After D1 failure, the same observer could not authenticate to D2/D3
even though the quorum assignment had replicated successfully. Sharing bearer
token databases would recreate a central secret dependency.

## Pull proof

The observer now sends a short-lived `ObserverRequestProof` containing:

- self-certifying observer NodeID;
- root-signed Operational Certificate;
- action `challenge_assignment_pull`;
- UUID nonce;
- issued/expiry time, maximum five minutes;
- hash of canonical request parameters (`limit`);
- Operational Key signature over the complete proof.

Discovery validates certificate, NodeID, signature, action, parameter binding,
time window, a 32 KiB semantic proof bound and a persistent one-use nonce before
exposing assignments for that observer.

```text
POST /registry/challenge-assignments/pull
```

## Portable ACK

`ChallengeAssignmentAck` is already signed by the observer Operational Key and
bound to assignment UUID, observer NodeID, decision and timestamp. The portable
endpoint additionally receives the root-signed Operational Certificate:

```text
POST /registry/challenge-assignment-acks/portable
```

The observer need not possess a local Discovery bearer token. Assignment quorum
membership provides authorization; certificate/key ownership provides
authentication. A local suspended/compromised row or replicated latest
suspension/revocation TrustRecord rejects portable access.

With `OPERATIONAL_CREDENTIAL_STATE_MODE=enforce`, pull, ACK and portable
TrustObservation also carry the root-signed monotonic state from `0237`.
Discovery requires its exact replicated high-watermark; an older certificate
cannot regain live access. Replicated ACK/observation remains historical and is
validated at its signed event time rather than against the current live key.
With `OPERATIONAL_CREDENTIAL_REVOCATION_MODE=enforce`, the exact serial/key is
also checked according to `0238`: live access at/after `effective_at` is
rejected, while an event signed before that boundary remains valid history.

## Verified invariants

- proof tamper, parameter substitution, expiry and signature tamper fail closed;
- proof nonce replay is rejected persistently;
- D2 accepts a valid pull and signed ACK when observer/subject were never
  registered in D2's legacy node table;
- the eight-process cluster verifies D1 assignment replication followed by
  portable D2 pull, replay rejection and ACK.

## Residual risks

- Node Root transition/recovery remains separate from the implemented
  serial-specific quorum revocation;
- signed ACK state is replicated by `0234`; portable assignment-bound
  observation/completion and its replication are defined by `0235`;
- production requests require TLS and connection/rate limits in front of the
  Discovery API;
- this proof grants only assignment pull/ACK behavior, never a general session
  or infrastructure capability.
