# 0229 — Federation NodeID Enforcement

Status: implemented locally; secure compose selects enforce mode.

## Problem

Node registration already carried a self-certifying `identity_node_id`, but
inter-node request headers and signed federation payloads still used a mutable
operator alias such as `home-a`. Signature verification bound that alias to the
Discovery row, yet the data plane did not directly name the Node Root identity.

## Modes

- `legacy`: federation headers use the configured alias;
- `report` (base compose default): preserves the alias during migration while
  registration publishes Node Identity;
- `enforce` (secure compose): derives the sender identifier from the root-signed
  Operational Certificate and uses that self-certifying NodeID in request
  signatures and signed federation objects.

Enforce mode fails closed when root/certificate paths are unavailable.

## Resolution

`FederationSecurity` now separates `node_alias` from `node_id`. In enforce mode
it loads or renews the existing Operational Certificate and returns its NodeID.
The same Operational Key signs the request, so the identifier, certificate and
signature key remain bound.

Home uses this NodeID for direct delivery, delivery ACK, home-change, Relay and
Storage federation payloads. Relay uses its NodeID when authenticating the next
hop and in `forwarded_by_node_id`.

Health responses publish both `node_id` and `node_alias` for migration.

## Receiver lookup

The trust cache indexes every non-conflicting Discovery row by both:

- legacy `node_id` alias;
- verified `identity_node_id`.

If two rows claim the same identity, that identity lookup is removed fail
closed while their unrelated aliases remain visible for operator diagnosis.
Discovery registration itself prevents normal root rebinding.

## Rotation

Operational Certificate renewal preserves Node Root and NodeID. Explicit
Operational Key rotation requires process credential refresh/restart as already
specified in `0206`; the NodeID remains stable.

## Residual risks

- report/legacy modes remain migration paths and are not the target claim;
- catalog transport still needs the signed multi-source peer path for route
  selection; NodeID enforcement alone does not make one Discovery trustworthy;
- alias fields may remain in administrative logs and are not security
  identifiers.
