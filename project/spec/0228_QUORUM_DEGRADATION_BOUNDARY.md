# 0228 — Quorum Degradation Boundary

Status: implemented locally.

## Security issue

The legacy Discovery worker directly changed `trust_level` after a locally
observed heartbeat outage. That made one Discovery an authority over Trust and
mixed a reliability signal with a governance decision.

In the target protocol:

```text
offline observation -> reliability candidate -> independent evidence/quorum
                    -> signed TrustRecord -> authoritative degradation
```

A local timer never creates the last arrow.

## Modes

- `observe` (default): computes current offline candidates and does not mutate
  `trust_level` or `trust_status`;
- `off`: no degradation worker;
- `legacy`: preserves direct mutation only for an isolated migration network
  where `TRUST_LEDGER_MODE=off`. Configuration rejects legacy mode when the
  Trust Ledger is active.

The secure profile requires `observe`.

## Candidate state

Each current candidate contains:

- self-certifying subject NodeID;
- previous and proposed levels;
- last heartbeat and bounded offline duration;
- observation time;
- SHA-256 evidence commitment over canonical, metadata-minimized input.

The table is a replaceable current view, not an append-only governance ledger.
When the node recovers, its candidate disappears. Nodes without a verified
NodeID do not produce Trust candidates.

`GET /registry/trust-degradation-candidates` exposes bounded candidate data for
validators. It does not apply a state transition.

## Authority boundary

Only `POST /registry/trust-records` in `TRUST_LEDGER_MODE=enforce` can apply a
degradation after validating:

- current authority epoch;
- externally selected committee;
- quorum signatures;
- subject history and `previous_hash`;
- previous level against local applied state.

## Residual risks

- one Discovery's offline timer is not proof of malicious behavior;
- candidates must be combined with independent observers and synthetic
  challenges before validators sign a degradation;
- current candidates are not themselves signed protocol attestations; signed
  TrustObservation remains the evidence path;
- legacy mode is intentionally incompatible with an active Trust Ledger.
