# 0237 — Distributed Operational Credential High-Watermark

Status: implemented locally for Discovery persistence/gossip, portable
observer live admission, node-side atomic sidecar lifecycle and opt-in
registration/heartbeat renewal publication; production migration is pending.

## Problem

`OperationalCertificate v1` is root-signed and short-lived, but its UUID serial
is not ordered. A Discovery that has seen key K2 must not later accept a still
valid K1 just because another replica received requests in a different order.
Comparing local arrival time or wall-clock timestamps is not a distributed
security rule.

## Root-signed state

Protocol: `ouo-operational-credential-state/1`.

The Node Root signs:

- self-certifying `node_id`;
- monotonic `credential_epoch`, starting at zero;
- `previous_state_hash`;
- the complete root-signed `operational_certificate`;
- protocol/object/signature versions.

Genesis is anchored to a domain-separated hash of NodeID. Every later state
must have exactly `previous credential_epoch + 1` and the complete previous
signed-state hash. A state hash includes the Root signature.

## Discovery persistence and replication

Discovery persists an append-only chain per NodeID plus a global sequence for
bounded pull gossip:

- `POST /registry/operational-credential-states`;
- `GET /registry/operational-credential-states/gossip`;
- `POST /registry/operational-credential-states/gossip`.

Only already known subjects are admitted (registered identity, assigned
observer, or observed advertisement), limiting arbitrary Root-key DB growth.
Pages are limited to 100 objects and a polling cycle to 100 pages. Gossip uses
the configured D1/D2/D3 NodeAdvertisement and/or ChallengeAssignment peer set;
HTTP transport is untrusted and every state is independently verified.

Two different root-signed objects for the same `(node_id, credential_epoch)`
are cryptographic Root equivocation and freeze the control plane. A lower epoch
is a rollback and is rejected, but is not by itself evidence that the Root
equivocated.

## Live state versus historical evidence

`OPERATIONAL_CREDENTIAL_STATE_MODE=off|report|enforce` controls portable
observer pull, ACK and TrustObservation publication.

In `enforce`, a live request must attach the exact local chain head and the
certificate used by the request must equal the certificate inside that state.
An older valid certificate is rejected.

Replicated ACK/TrustObservation is historical evidence. It is verified using
the certificate validity at `acknowledged_at`/`observed_at`, not against the
current live head. Key rotation therefore neither re-authorizes K1 for new
requests nor invalidates an event that K1 validly signed before rotation.

## Verified invariants

- epoch, previous hash, certificate, NodeID and Root-signature tamper fail;
- expired state can be retained as history but cannot authenticate live;
- D1/D2/D3 converge to the same credential head;
- same-epoch Root equivocation freezes governance;
- malformed/unsigned same-epoch input is rejected before it can trigger
  equivocation freeze;
- portable pull/ACK/observation work on D2 in enforce mode and historical
  lifecycle events still converge to D1/D3;
- missing state is rejected in enforce and remains migration-compatible in
  report mode.

## Residual work

- `node_identity_credentials` atomically maintains the chain sidecar on
  certificate renewal/explicit bundle rotation and refuses silent reset when
  an existing certificate has lost its chain; all node registration workers
  expose an opt-in `NODE_OPERATIONAL_CREDENTIAL_CHAIN_PATH`; registration and
  heartbeat validate/store the exact next state in the same SQLite transaction;
- registration/heartbeat must carry the state before global enforce rollout;
- serial-specific quorum revocation is implemented in `0238`; Node Root
  transition remains separate future work;
- D1/D2/D3 still require TLS/overlay admission and external rate limits;
- a lost node-side chain file cannot safely be reset to epoch zero after the
  network has observed a higher epoch; it must be restored or recovered by a
  separately specified Root transition.
