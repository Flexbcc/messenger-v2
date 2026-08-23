# 0238 — Quorum Operational Credential Revocation

Status: implemented and verified locally, including D1/D2/D3 replication and
eight-process loopback enforcement. Production authority provisioning and
overlay/TLS deployment remain pending.

## Security boundary

`OperationalCredentialRevocation` revokes exactly one Operational Certificate:

- NodeID and Node Root remain valid;
- Level and Capability Certificates are unchanged;
- a node-wide `TrustRecord(action=revocation)` remains a separate, stronger
  action that returns the node to L0;
- Node Root compromise requires a future Root transition/recovery protocol.

This separation lets a quorum stop a stolen short-lived operational key without
turning a key incident into an implicit governance decision about the node.

## Signed object

Protocol: `ouo-operational-credential-revocation/1`.

The quorum signs:

- `revocation_id`;
- `node_id`;
- monotonic per-NodeID `revocation_epoch` and `previous_hash`;
- referenced `credential_epoch`;
- exact certificate `serial`, operational public key and SHA-256 hash of the
  complete root-signed certificate;
- historical `authority_epoch`, exact committee and threshold;
- privacy-preserving `reason_commitment` rather than incident plaintext;
- `effective_at` and `decided_at`;
- protocol/object versions.

Genesis uses a domain-separated NodeID hash. Each later object must advance
exactly one epoch and reference the complete prior revocation hash.

Version 1 requires `effective_at == decided_at`. Retroactive revocation would
require re-evaluating already accepted evidence differently on replicas and is
therefore rejected. A later protocol version may add a separately specified
reconciliation procedure.

## Validation

Each Discovery independently:

1. loads the exact Operational Credential state referenced by
   `(node_id, credential_epoch)`;
2. verifies that serial, key and full certificate hash match;
3. loads the exact Authority state at `authority_epoch`;
4. checks committee, threshold, validator validity at `decided_at` and quorum
   signatures;
5. checks the per-node revocation chain;
6. appends the immutable object and a global pull-gossip sequence.

Four of seven signatures cannot revoke a certificate; five of seven can under
the current test policy. Two valid objects at the same per-node epoch are
quorum equivocation, are retained as conflict evidence, and freeze the control
plane.

## Replication and API

- `POST /registry/operational-credential-revocations`;
- `GET /registry/operational-credential-revocations/gossip`;
- `POST /registry/operational-credential-revocations/gossip`.

Pages contain at most 100 objects and a peer cycle at most 100 pages. The same
explicit D1/D2/D3 peer origins used for NodeAdvertisement/ChallengeAssignment
gossip carry revocations. HTTP is not trusted: every replica repeats complete
certificate, historical-authority, chain and quorum validation.

## Admission semantics

`OPERATIONAL_CREDENTIAL_REVOCATION_MODE=off|report|enforce` controls policy.

In `enforce`, the exact revoked certificate is rejected at or after
`effective_at` by:

- node registration and heartbeat;
- portable observer pull, ACK and TrustObservation;
- Discovery NodeAdvertisement source/subject processing.

ACK and TrustObservation replicated later are checked at their signed
`acknowledged_at` or `observed_at`. Events before `effective_at` remain valid;
events at or after it fail closed. A newer non-revoked credential epoch can
continue to represent the same NodeID.

## Verified invariants

- exact serial/key/certificate-hash binding;
- 5-of-7 success and 4-of-7 rejection;
- no retroactive/delayed v1 effective time;
- D1→D2/D3 persistent pull convergence;
- same-epoch conflict freezes governance;
- unsigned same-epoch junk cannot trigger that freeze;
- live registration/heartbeat and portable admission reject the revoked key;
- historical ACK/TrustObservation from before the decision remain available;
- Level and capabilities are not fields of this object and are not mutated;
- the real eight-process cluster returns HTTP 403 for the old live key on D2,
  while all three Discovery replicas retain the historical ACK/observation.

## Residual work

- production validators, key custody and signing ceremony;
- mTLS or authenticated overlay for Discovery gossip plus edge rate limits;
- explicit operational recovery UX that rotates to the next root-signed
  credential state;
- Node Root transition/revocation remains a separate future protocol;
- external audit and incident-response drill before public node binaries.
